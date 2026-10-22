import AppKit
import SwiftUI
import ApplicationServices
import TranslationCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var configuration = Configuration.load()
    @Published var status = "选中文字后按 ⌘⌥E，即可翻译并替换。"
    @Published var busy = false
    @Published var lastSource = ""
    @Published var lastTranslation = ""
    @Published var availableModels: [String: [AgentModel]] = [:]
    @Published var loadingModels = false
    @Published var modelStatus = ""
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private var permissionTimer: Timer?
    private var modelTask: Task<Void, Never>?
    private var modelRequest: UUID?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let hotKey = HotKey()
    private let agentClient = AgentClient()
    private let captureSelection: () async throws -> SelectionSnapshot?
    private let translateText: ((String, Configuration) async throws -> String)?
    private let translationHistory: TranslationHistoryModel
    private lazy var overlay = TranslationOverlay(history: translationHistory)
    private let selectionMonitor = SelectionMonitor()
    private let clipboardActivity = ClipboardActivityMonitor()
    private var interaction = TranslationInteraction()
    private var slowTask: Task<Void, Never>?
    private var replacementInProgress = false
    private var terminationSignal: DispatchSourceSignal?
    private var task: Task<Void, Never>?

    init(historyFile: URL? = TranslationHistory.file,
         captureSelection: @escaping () async throws -> SelectionSnapshot? = { try await SelectionAccess.capture() },
         translateText: ((String, Configuration) async throws -> String)? = nil) {
        self.captureSelection = captureSelection
        self.translateText = translateText
        translationHistory = TranslationHistoryModel(file: historyFile)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        refreshAccessibilityPermission()
        permissionTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(refreshAccessibilityPermission), userInfo: nil, repeats: true)
        print("Accessibility permission at launch: \(accessibilityTrusted); app: \(Bundle.main.bundleURL.path)")
        fflush(stdout)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = FanyiXIcon.image(size: 18, template: true)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = ""
        hotKey.action = { [weak self] in self?.translateSelection() }
        registerShortcut()
        updateMenu()
        overlay.onCancel = { [weak self] in self?.cancelTranslation() }
        overlay.onCopy = { [weak self] text in self?.copy(text) }
        overlay.onInteract = { [weak self] in self?.protectSelectionForHistory() }
        overlay.onSettings = { [weak self] in self?.showSettings() }
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApp.terminate(nil) }
        terminationSignal?.resume()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--settings") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { permissionTimer?.invalidate(); task?.cancel(); slowTask?.cancel(); selectionMonitor.stop(); clipboardActivity.stop(); overlay.hide(); modelTask?.cancel(); agentClient.close() }
    func applicationDidBecomeActive(_ notification: Notification) { refreshAccessibilityPermission() }

    @objc func refreshAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        guard trusted != accessibilityTrusted else { return }
        accessibilityTrusted = trusted
        print("Accessibility permission changed: \(trusted)")
        fflush(stdout)
    }

    func revealApplicationForPermission() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, "翻译历史", #selector(showResult))
        add(menu, "设置", #selector(showSettings))
        add(menu, "退出", #selector(quit), key: "q")
        return menu
    }

    private func updateMenu() {
        guard let statusItem else { return }
        statusItem.menu = makeStatusMenu()
        statusItem.button?.title = busy ? "…" : ""
        statusItem.button?.toolTip = status
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, enabled: Bool = true, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = enabled; menu.addItem(item)
    }

    func saveSettings(resetAgent: Bool = false) {
        do { try configuration.save(); if resetAgent { agentClient.close() }; registerShortcut(); updateMenu() }
        catch { status = "设置保存失败：" + error.localizedDescription }
    }

    var currentModels: [AgentModel] { availableModels[configuration.backend.rawValue] ?? [] }

    func selectModel(_ id: String) {
        if id.isEmpty { configuration.models.removeValue(forKey: configuration.backend.rawValue) }
        else { configuration.models[configuration.backend.rawValue] = id }
        saveSettings(resetAgent: true)
    }

    func agentSettingsChanged() { saveSettings(resetAgent: true); refreshModels() }

    @objc func resetSession() {
        guard !busy else { return }
        agentClient.close()
        status = "翻译会话已重置，下次翻译会创建新会话。"
        updateMenu()
    }

    func openTranslationRules() {
        do {
            try AgentWorkspace.prepare()
            NSWorkspace.shared.activateFileViewerSelecting([AgentWorkspace.instructionsFile])
        } catch { status = "打开翻译规则失败：" + error.localizedDescription; updateMenu() }
    }

    func refreshModels() {
        modelTask?.cancel()
        let id = UUID(); modelRequest = id
        var config = configuration; config.timeout = min(config.timeout, 30)
        loadingModels = true; modelStatus = "正在向 " + config.backend.title + " 获取模型列表…"
        modelTask = Task { @MainActor in
            let catalog = NativeAgent()
            defer { catalog.close() }
            do {
                let models = try await catalog.listModels(configuration: config)
                guard !Task.isCancelled, modelRequest == id else { return }
                availableModels[config.backend.rawValue] = models
                modelStatus = models.isEmpty ? "Agent 返回空列表。可使用默认模型或手动填写模型 ID。" : "已从 Agent 获取 " + String(models.count) + " 个模型；账号可用性以实际翻译响应为准。"
            } catch {
                guard !Task.isCancelled, modelRequest == id else { return }
                modelStatus = "获取失败：" + error.localizedDescription + " 可重试或手动填写模型 ID。"
            }
            loadingModels = false; modelTask = nil
        }
    }

    private func registerShortcut() {
        if !hotKey.register(choice: configuration.shortcut) {
            status = "快捷键注册失败，可能已被其他应用占用，请在设置中切换。"
        } else { status = "选中文字后按 " + HotKey.titles[safe: configuration.shortcut, default: 0] + "，即可翻译并替换；未选中文字时打开历史。" }
    }

    @objc func translateSelection() {
        // 已经提交粘贴时只等待剪贴板恢复，不再撤回已发生的替换。
        if replacementInProgress { return }
        let previous = task
        previous?.cancel(); selectionMonitor.stop(); clipboardActivity.stop(); slowTask?.cancel()
        let id = interaction.begin()
        busy = true
        status = "正在读取选中文字…"
        updateMenu()
        overlay.beginRequest()
        let config = configuration
        task = Task { @MainActor in
            var recordTranslation = ""
            var recordOutcome: TranslationRecordStatus = .failed
            var recordDetail = "翻译未完成。"
            defer {
                translationHistory.finish(id: id, translation: recordTranslation,
                    status: Task.isCancelled ? .cancelled : recordOutcome,
                    detail: Task.isCancelled ? "本次翻译已取消。" : recordDetail)
            }
            // 等旧请求彻底结束，避免它的取消清理关闭新请求的 Agent。
            if let previous { await previous.value }
            guard interaction.owns(id) else { return }
            do {
                try Task.checkCancellation()
                // 等待触发快捷键的修饰键释放，避免 Cmd+C/V 与仍按住的 Option 叠加。
                guard try await SelectionAccess.waitForModifiersReleased() else { throw TranslationError.message("请松开快捷键后重试。") }
                try Task.checkCancellation()
                // 在第一次复制前开始保护，覆盖读取选区与 Agent 响应的整个间隔。
                clipboardActivity.startIfNeeded()
                let captured = try await captureSelection()
                try Task.checkCancellation()
                guard interaction.owns(id) else { return }
                guard let snapshot = captured, !SelectionShortcut.opensHistory(selectedText: snapshot.source) else {
                    interaction.finish(id)
                    selectionMonitor.stop(); clipboardActivity.stop(); slowTask?.cancel(); slowTask = nil
                    busy = false; task = nil
                    status = "翻译历史"
                    overlay.showHistory(resetStatus: true)
                    updateMenu()
                    return
                }
                translationHistory.begin(id: id, source: snapshot.source, configuration: config)
                overlay.focusRequest(id)
                let useClipboard = !snapshot.readOnly && snapshot.clipboardCompatibility && clipboardActivity.isMonitoring
                if !useClipboard { clipboardActivity.stop() }
                status = "正在通过 " + config.backend.title + " 翻译…"
                if snapshot.supportsVerification || useClipboard {
                    overlay.progress(title: useClipboard ? "正在翻译，完成后自动替换" : "正在翻译…", detail: useClipboard ? "微信兼容模式；期间输入、点击或切换窗口将停止自动替换。" : "可以继续编辑；再次按快捷键翻译新选区。", anchor: snapshot.anchor, reposition: true)
                    selectionMonitor.start(snapshot, clipboardUnchanged: useClipboard ? { self.clipboardActivity.unchanged } : nil) { [weak self] in
                        guard let self, self.interaction.invalidate(id) else { return }
                        self.status = "输入或选区已变化，译文完成后供复制。"
                        self.overlay.progress(title: "继续翻译，完成后供复制", detail: "原选区已变化或无法确认，不会自动替换。")
                        self.updateMenu()
                    }
                } else {
                    interaction.invalidate(id)
                    status = "正在通过 " + config.backend.title + " 翻译，完成后可复制译文。"
                    overlay.progress(title: "正在翻译，完成后供复制", detail: "当前应用未提供可核验的选区信息，译文将保留供复制。", anchor: snapshot.anchor, reposition: true)
                    if snapshot.readOnly { overlay.revealRequest(id) }
                }
                slowTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard !Task.isCancelled, let self, self.interaction.owns(id) else { return }
                    self.overlay.progress(title: "仍在翻译…", detail: self.interaction.canReplace(id) ? "Agent 正在响应，可继续编辑或取消。" : "不会自动替换，完成后可复制译文。")
                }
                updateMenu()
                let translated: String
                if let translateText { translated = try await translateText(snapshot.source, config) }
                else { translated = try await agentClient.translate(snapshot.source, configuration: config) }
                try Task.checkCancellation()
                guard interaction.owns(id) else { return }
                slowTask?.cancel(); slowTask = nil
                lastSource = snapshot.source
                lastTranslation = translated
                recordTranslation = translated; recordOutcome = .retained
                let replacementText = config.replacementStyle.replacement(source: snapshot.source, translation: translated)
                if useClipboard {
                    do {
                        _ = try await SelectionAccess.replaceClipboardSelection(snapshot, with: replacementText, allowed: {
                            self.interaction.canReplace(id) && self.clipboardActivity.unchanged && !Task.isCancelled
                        }, beforeWrite: {
                            self.selectionMonitor.stop(); self.clipboardActivity.stop(); self.replacementInProgress = true
                            self.overlay.progress(title: "正在替换…", detail: "正在粘贴到微信原选区。", cancellable: false)
                            self.updateMenu()
                        })
                        guard interaction.owns(id) else { return }
                        status = "已向微信粘贴翻译结果；微信不提供可回读的结果，请以输入框内容为准。"
                        recordOutcome = .pasted
                        overlay.complete()
                    } catch {
                        guard interaction.owns(id), !Task.isCancelled else { throw CancellationError() }
                        selectionMonitor.stop(); status = error.localizedDescription
                        overlay.retain(translated, title: "未自动替换，译文已保留", detail: status)
                    }
                } else if !snapshot.supportsVerification {
                    selectionMonitor.stop()
                    status = snapshot.readOnly ? "只读文字翻译完成，可在历史中查看与复制。" : "翻译已完成；当前应用无法核验选区，请复制译文后手动粘贴。"
                    overlay.retain(translated, title: "译文已完成，请复制", detail: status)
                } else if !interaction.canReplace(id) || !SelectionAccess.unchanged(snapshot) {
                    selectionMonitor.stop()
                    status = "原文或选区已变化，未自动替换。译文已保留，可复制。"
                    overlay.retain(translated, title: "原文或选区已变化，未替换")
                } else {
                    do {
                        let replacement = try await SelectionAccess.replace(snapshot, with: replacementText, allowed: {
                            self.interaction.canReplace(id) && !Task.isCancelled
                        }, beforeWrite: {
                            self.selectionMonitor.stop(); self.replacementInProgress = true
                            self.overlay.progress(title: "正在替换…", detail: "正在将翻译结果写回原选区。", cancellable: false)
                            self.updateMenu()
                        }, writeFailed: {
                            self.replacementInProgress = false
                            self.selectionMonitor.start(snapshot) { [weak self] in self?.interaction.invalidate(id) }
                        })
                        guard interaction.owns(id) else { return }
                        if replacement == .confirmed {
                            status = "已按所选方式替换。可从菜单查看原文与译文。"
                            recordOutcome = .replaced
                            overlay.complete()
                        } else {
                            status = "已尝试替换，无法读取结果，请确认输入框中的文字。"
                            overlay.retain(translated, title: "请确认输入框，译文已保留", detail: "目标应用未提供可读取的结果；译文仍可复制。")
                        }
                    } catch {
                        guard interaction.owns(id), !Task.isCancelled else { throw CancellationError() }
                        selectionMonitor.stop(); status = error.localizedDescription
                        overlay.retain(translated, title: "请确认输入框，译文已保留", detail: status)
                    }
                }
                recordDetail = status
            } catch {
                recordDetail = error.localizedDescription
                guard interaction.owns(id) else { return }
                if Task.isCancelled || error is CancellationError {
                    status = "本次翻译已取消。"
                    overlay.message("已取消翻译", phase: .cancelled, dismissAfter: 1.2)
                } else {
                    status = error.localizedDescription
                    overlay.message("未能完成翻译", detail: status, phase: .error)
                }
            }
            guard interaction.finish(id) else { return }
            selectionMonitor.stop(); clipboardActivity.stop(); slowTask?.cancel(); slowTask = nil
            replacementInProgress = false; busy = false; task = nil; updateMenu()
        }
    }

    @objc func cancelTranslation() {
        guard busy, !replacementInProgress else { return }
        if let id = interaction.requestID { interaction.invalidate(id) }
        task?.cancel(); selectionMonitor.stop(); clipboardActivity.stop(); slowTask?.cancel()
        status = "正在取消…"; overlay.progress(title: "正在取消…", detail: "原文保持不变。", cancellable: false); updateMenu()
    }

    /// 离线回归检查：注入无选区，不读取桌面、不调用 Agent。
    func checkEmptyShortcut() async -> Bool {
        let count = translationHistory.records.count
        translateSelection()
        if let pending = task { await pending.value }
        let state = overlay.diagnosticState()
        let passed = !busy && task == nil && interaction.requestID == nil
            && translationHistory.records.count == count && state["visible"] as? Bool == true
            && state["expanded"] as? Bool == true && !overlay.isTranslating
        overlay.hide()
        return passed
    }

    /// 注入只读选区与翻译结果，覆盖快捷键到新记录详情的完整流程。
    func checkReadOnlyShortcut() async -> Bool {
        let old = UUID()
        translationHistory.begin(id: old, source: "上一条记录", configuration: configuration)
        translationHistory.finish(id: old, translation: "Previous record", status: .retained, detail: "")
        overlay.focusRequest(old); overlay.showHistory(); overlay.hide()
        translateSelection()
        if let pending = task { await pending.value }
        let record = translationHistory.records.first
        let passed = !busy && task == nil && interaction.requestID == nil
            && translationHistory.records.count == 2 && record?.id != old
            && record?.source == "只读聊天记录" && record?.translation == "Read-only chat message"
            && record?.status == .retained && overlay.selectedID == record?.id
            && overlay.focusedRequestID == record?.id && overlay.mode == .expanded
            && overlay.phase == .retained && overlay.diagnosticState()["visible"] as? Bool == true
        overlay.hide()
        return passed
    }

    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 " + configuration.backend.title + " 可执行文件"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.isExecutableFile(atPath: url.path) else { status = "所选文件不可执行。"; return }
            configuration.executablePaths[configuration.backend.rawValue] = url.path
            agentSettingsChanged()
        }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
            window.title = "FanyiX · 设置"
            window.level = .floating; window.isFloatingPanel = true; window.hidesOnDeactivate = false
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.isMovable = true; window.isMovableByWindowBackground = false
            window.setAccessibilityLabel("FanyiX设置")
            window.contentView = NSHostingView(rootView: SettingsView(model: self))
            window.isReleasedWhenClosed = false; window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func closeSettings() { settingsWindow?.close() }

    private func protectSelectionForHistory() {
        guard busy, !replacementInProgress, let id = interaction.requestID, interaction.invalidate(id) else { return }
        status = "正在查看翻译历史，本次完成后保留译文，不自动替换。"
        overlay.progress(title: "继续翻译，完成后供复制", detail: status)
        updateMenu()
    }

    @objc func showResult() { protectSelectionForHistory(); overlay.showHistory() }

    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    @objc func quit() { NSApp.terminate(nil) }
}

extension Array {
    subscript(safe index: Int, default fallback: Int) -> Element { self[indices.contains(index) ? index : fallback] }
}

@main
enum ShurufaApp {
    static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--ui-preview") {
            guard index + 1 < CommandLine.arguments.count else { print("用法：--ui-preview 输出目录"); exit(1) }
            do { try await UIPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)) }
            catch { print("UI 预览失败：" + error.localizedDescription); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--overlay-smoke") {
            await overlaySmoke(); return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let config = Configuration.load()
            var paths: [String: String] = [:]
            for backend in Backend.allCases { paths[backend.rawValue] = (try? AgentLaunch.resolve(backend, override: config.executablePaths[backend.rawValue] ?? "").executable.path) ?? "未找到" }
            let diagnostics: [String: Any] = ["accessibilityTrusted": AXIsProcessTrusted(), "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown", "transport": "native-stdio", "executables": paths]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: .sortedKeys) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        if CommandLine.arguments.contains("--smoke") {
            let args = CommandLine.arguments
            let index = args.firstIndex(of: "--smoke")!
            let backend = index + 1 < args.count ? Backend(rawValue: args[index + 1]) : .codex
            guard let backend else { print("用法：--smoke codex|claude|pi"); exit(1) }
            let agent = NativeAgent()
            defer { agent.close() }
            var config = Configuration.load(); config.backend = backend
            if index + 2 < args.count { config.models[backend.rawValue] = args[index + 2] }
            var pid: Int32?
            do {
                for source in ["我今天可能会晚点到。", "Could we meet at ten tomorrow morning?"] {
                    let start = Date()
                    let output = try await agent.translate(source, configuration: config)
                    if let pid, pid != agent.processIdentifier { throw TranslationError.message("Agent 进程未复用。") }
                    pid = agent.processIdentifier
                    let result: [String: Any] = ["backend": backend.rawValue, "translation": output, "seconds": Date().timeIntervalSince(start), "pid": pid ?? 0, "executable": agent.executablePath ?? ""]
                    let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                    print(String(decoding: data, as: UTF8.self))
                }
            } catch { print("冒烟验证失败：" + error.localizedDescription); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--models") {
            let args = CommandLine.arguments
            guard index + 1 < args.count, let backend = Backend(rawValue: args[index + 1]) else { print("用法：--models codex|claude|pi"); exit(1) }
            let agent = NativeAgent(); defer { agent.close() }
            var config = Configuration.load(); config.backend = backend; config.timeout = 30
            do {
                let models = try await agent.listModels(configuration: config)
                print(String(decoding: try JSONEncoder().encode(models), as: UTF8.self))
            } catch { print("获取模型失败：" + error.localizedDescription); exit(1) }
            return
        }
        runApplication()
    }

    @MainActor
    static func overlaySmoke() async {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let history = TranslationHistoryModel(file: nil)
        let overlay = TranslationOverlay(history: history, persistPosition: false)
        let id = UUID()
        history.begin(id: id, source: "浮层检查", configuration: Configuration())
        overlay.selectedID = id
        var protected = false
        overlay.onInteract = { protected = true }
        var states: [[String: Any]] = []
        var checks: [String: Bool] = [:]
        overlay.beginRequest()
        overlay.progress(title: "正在翻译…", detail: "不读取选区，不调用 Agent。", reposition: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        states.append(overlay.diagnosticState())
        checks["simpleVisible"] = states.last?["visible"] as? Bool == true
        overlay.expand()
        checks["historyProtectsInput"] = protected
        states.append(overlay.diagnosticState())
        checks["expanded"] = states.last?["expanded"] as? Bool == true
        overlay.collapse(); overlay.expand()
        checks["selectionPreserved"] = overlay.selectedID == id
        let newest = UUID()
        history.begin(id: newest, source: "新的网页选区", configuration: Configuration())
        overlay.focusRequest(newest)
        checks["expandedNewRequestSelectsNewest"] = overlay.selectedID == newest && overlay.focusedRequestID == newest
        protected = false
        overlay.revealRequest(newest)
        checks["systemRevealDoesNotProtectInput"] = !protected
        history.finish(id: newest, translation: "New webpage selection", status: .retained, detail: "")
        overlay.complete()
        history.finish(id: id, translation: "Overlay check", status: .replaced, detail: "测试")
        states.append(overlay.diagnosticState())
        checks["expandedCompletionStays"] = states.last?["visible"] as? Bool == true
        overlay.collapse(); overlay.complete()
        states.append(overlay.diagnosticState())
        checks["simpleCompletionHides"] = states.last?["visible"] as? Bool == false
        overlay.beginRequest(); overlay.progress(title: "正在翻译…", detail: "")
        overlay.hide(); overlay.progress(title: "仍在翻译…", detail: "")
        checks["closedStaysClosed"] = overlay.diagnosticState()["visible"] as? Bool == false
        overlay.beginRequest(); overlay.progress(title: "正在翻译…", detail: "")
        overlay.retain("The translation is kept.", title: "译文已保留")
        states.append(overlay.diagnosticState())
        checks["retainedStaysSimple"] = states.last?["expanded"] as? Bool == false && states.last?["visible"] as? Bool == true
        overlay.message("未能完成翻译", detail: "检查错误提示。", phase: .error)
        states.append(overlay.diagnosticState())
        overlay.showHistory(); overlay.hide()
        protected = false
        overlay.beginRequest()
        overlay.progress(title: "正在翻译…", detail: "关闭历史后的下一次翻译。", reposition: true)
        let afterClosedHistory = overlay.diagnosticState()
        states.append(afterClosedHistory)
        checks["closedHistoryNextRequestStartsSimple"] = afterClosedHistory["visible"] as? Bool == true
            && afterClosedHistory["expanded"] as? Bool == false
            && overlay.displaySize == NSSize(width: 292, height: 44)
        checks["resetHiddenHistoryDoesNotProtectInput"] = !protected
        checks["resetHiddenHistoryPreservesSelection"] = overlay.selectedID == newest
        overlay.complete()
        checks["replacementAfterClosedHistoryHides"] = overlay.diagnosticState()["visible"] as? Bool == false
        overlay.showHistory()
        overlay.beginRequest(); overlay.progress(title: "正在翻译…", detail: "仍在查看历史时保持展开。")
        checks["visibleHistoryRemainsExpanded"] = overlay.mode == .expanded && overlay.diagnosticState()["visible"] as? Bool == true
        overlay.hide()
        overlay.beginRequest(); overlay.progress(title: "正在翻译…", detail: "只读文字自动展示结果。")
        overlay.revealRequest(newest)
        checks["readOnlyCanRevealAfterClosedHistory"] = overlay.mode == .expanded && overlay.selectedID == newest
            && overlay.diagnosticState()["visible"] as? Bool == true
        let unchanged = frontmost == NSWorkspace.shared.frontmostApplication?.processIdentifier
        checks["frontmostUnchanged"] = unchanged
        checks["nonactivatingWithinScreen"] = states.allSatisfy { $0["isKey"] as? Bool == false && $0["nonactivating"] as? Bool == true && $0["withinScreen"] as? Bool == true && $0["draggable"] as? Bool == true }
        let delegate = AppDelegate(historyFile: nil, captureSelection: { nil })
        checks["emptyShortcutOpensHistory"] = await delegate.checkEmptyShortcut()
        checks["onlyThreeMenuItems"] = delegate.makeStatusMenu().items.map(\.title) == ["翻译历史", "设置", "退出"]
        let blankDelegate = AppDelegate(historyFile: nil, captureSelection: {
            SelectionSnapshot(pid: 0, element: nil, range: nil, fullText: nil, source: " \n\t　", anchor: nil, window: nil, clipboardCompatibility: false)
        })
        checks["blankShortcutOpensHistory"] = await blankDelegate.checkEmptyShortcut()
        var translatedCount = 0
        let readOnlySnapshot = SelectionSnapshot(pid: 0, element: nil, range: CFRange(location: 0, length: 0),
            fullText: nil, source: "只读聊天记录", anchor: nil, window: nil, clipboardCompatibility: true, readOnly: true)
        checks["readOnlyNeverAuthorizesAXReplacement"] = !readOnlySnapshot.supportsVerification
        checks["readOnlyNeverAuthorizesClipboardReplacement"] = !SelectionAccess.clipboardTargetUnchanged(readOnlySnapshot)
        let readOnlyDelegate = AppDelegate(historyFile: nil, captureSelection: { readOnlySnapshot }, translateText: { _, _ in
            translatedCount += 1
            return "Read-only chat message"
        })
        checks["readOnlyShortcutShowsNewestResult"] = await readOnlyDelegate.checkReadOnlyShortcut() && translatedCount == 1
        let settings = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        checks["settingsAcceptsTextInput"] = settings.canBecomeKey && !settings.canBecomeMain
        settings.close()
        let okay = checks.values.allSatisfy { $0 }
        overlay.hide()
        let result: [String: Any] = ["passed": okay, "checks": checks, "states": states]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys) { print(String(decoding: data, as: UTF8.self)) }
        if !okay { exit(1) }
    }

    @MainActor
    static func runApplication() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
