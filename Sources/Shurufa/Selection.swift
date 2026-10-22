import AppKit
import ApplicationServices
import Carbon
import TranslationCore

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func textRange(_ element: AXUIElement) -> CFRange? {
    guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return range
}

private func focusedElement(pid: pid_t? = nil) -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    let roots = [system] + (pid.map { [AXUIElementCreateApplication($0)] } ?? [])
    for root in roots {
        guard let value = attribute(root, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
        let element = value as! AXUIElement
        if let pid {
            var actual: pid_t = 0
            guard AXUIElementGetPid(element, &actual) == .success, actual == pid else { continue }
        }
        return element
    }
    return nil
}

private func focusedWindow(pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        if let value = attribute(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }
    }
    return nil
}

struct SelectionSnapshot {
    let pid: pid_t
    let element: AXUIElement?
    let range: CFRange?
    let fullText: String?
    let source: String
    let anchor: NSRect?
    let window: AXUIElement?
    let clipboardCompatibility: Bool
    var readOnly = false
    var supportsVerification: Bool { !readOnly && element != nil && range != nil }
}

@MainActor
private struct SavedClipboard {
    let items: [[NSPasteboard.PasteboardType: Data]]
    init() {
        items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
            return values
        }
    }
    func restore(ifUnchanged count: Int) {
        let board = NSPasteboard.general
        guard board.changeCount == count else { return }
        board.clearContents()
        let objects = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !objects.isEmpty { board.writeObjects(objects) }
    }
}

@MainActor
enum SelectionAccess {
    enum ReplacementResult { case confirmed, submitted, clipboardSubmitted }
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func key(_ code: CGKeyCode) throws {
        for event in try CommandShortcut.events(key: code) { event.post(tap: .cgSessionEventTap) }
    }

    static func waitForModifiersReleased() async throws -> Bool {
        var releasedSamples = 0
        for _ in 0..<40 {
            try Task.checkCancellation()
            releasedSamples = CommandShortcut.physicalModifiersPressed ? 0 : releasedSamples + 1
            if releasedSamples >= 2 { return true }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    static func capture() async throws -> SelectionSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        guard AXIsProcessTrusted() else {
            requestPermission()
            throw TranslationError.message("系统尚未识别FanyiX的辅助功能权限。请在设置中授权；若开关已打开，请退出并重开，仍无效时移除旧条目，再添加当前这份FanyiX应用。")
        }
        let element = focusedElement(pid: app.processIdentifier)
        let window = focusedWindow(pid: app.processIdentifier)
        let role = element.flatMap { attribute($0, kAXRoleAttribute) as? String }
        let subrole = element.flatMap { attribute($0, kAXSubroleAttribute) as? String }
        guard role != kAXSecureTextFieldSubrole && subrole != kAXSecureTextFieldSubrole else { throw TranslationError.message("密码输入框不支持翻译。") }
        // 系统安全输入启用时，即使目标不暴露 AX 节点也不尝试复制。
        guard !IsSecureEventInputEnabled() else { throw TranslationError.message("系统安全输入已启用，暂不读取选中文字。") }
        let wechat = ClipboardActivityMonitor.supports(app.bundleIdentifier)
        var range = element.flatMap { textRange($0) }
        var fullText = element.flatMap { attribute($0, kAXValueAttribute) as? String }
        var source = element.flatMap { attribute($0, kAXSelectedTextAttribute) as? String }
        let editableRole = ["AXTextArea", "AXTextField", "AXComboBox"].contains(role ?? "")
            && (element.flatMap { attribute($0, "AXEditable") as? Bool } != false)
        var writableText = DarwinBoolean(false)
        if let element { _ = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writableText) }
        if SelectionCapturePolicy.emptyRangeOpensHistory(wechat: wechat, editableTarget: editableRole || writableText.boolValue, rangeLength: range?.length, selectedText: source) { return nil }
        let copied = SelectionCapturePolicy.needsFreshCopy(wechat: wechat, selectedText: source)
        if copied {
            do { source = try await copySelectedText() }
            catch SelectionCaptureError.noSelection { source = nil }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw TranslationError.message("读取期间目标应用变化，请重试。") }
        }
        guard !SelectionShortcut.opensHistory(selectedText: source), let source else { return nil }
        // 原生菜单的剪切状态提供微信是否处于可编辑选区的证据；聊天气泡不能剪切。
        let readOnly = SelectionCapturePolicy.isReadOnly(wechat: wechat, editableRole: editableRole,
            writableText: writableText.boolValue, cutEnabled: wechat ? cutMenuEnabled(pid: app.processIdentifier) : nil)
        if copied && !readOnly, let element {
            guard let current = focusedElement(pid: app.processIdentifier), CFEqual(current, element) else { throw TranslationError.message("读取期间输入焦点变化，请重试。") }
            let currentRange = textRange(element)
            let currentText = attribute(element, kAXValueAttribute) as? String
            if let range, currentRange?.location != range.location || currentRange?.length != range.length { throw TranslationError.message("读取期间选区变化，请重试。") }
            if let fullText, currentText != fullText { throw TranslationError.message("读取期间文字变化，请重试。") }
            range = currentRange; fullText = currentText
        }
        _ = try TranslationPrompt.make(source)
        let compatibility = !readOnly && (element == nil || range == nil || range?.length == 0) && window != nil && wechat
        return SelectionSnapshot(pid: app.processIdentifier, element: element, range: range, fullText: fullText, source: source,
            anchor: element.flatMap { bounds($0, range: range) }, window: window, clipboardCompatibility: compatibility, readOnly: readOnly)
    }

    private static func cutMenuEnabled(pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        guard let root = attribute(app, kAXMenuBarAttribute), CFGetTypeID(root) == AXUIElementGetTypeID(),
              let menus = attribute(root as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
              let edit = menus.first(where: { ["编辑", "編輯", "Edit"].contains(attribute($0, kAXTitleAttribute) as? String ?? "") }) else { return nil }
        var queue: [(AXUIElement, Int)] = [(edit, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 60 {
            let (item, depth) = queue.removeFirst(); visited += 1
            let identifier = attribute(item, kAXIdentifierAttribute) as? String
            let title = attribute(item, kAXTitleAttribute) as? String
            if identifier == "cut:" || ["剪切", "Cut"].contains(title ?? "") {
                return attribute(item, kAXEnabledAttribute) as? Bool
            }
            if depth < 3, let children = attribute(item, kAXChildrenAttribute) as? [AXUIElement] {
                queue += children.map { ($0, depth + 1) }
            }
        }
        return nil
    }

    static func copySelectedText(allowed: () -> Bool = { true }) async throws -> String {
        guard try await waitForModifiersReleased() else { throw TranslationError.message("请松开 Command、Option、Control 和 Shift 后重试。") }
        guard allowed() else { throw TranslationError.message("输入或焦点已变化，未自动替换。译文已保留。") }
        let saved = SavedClipboard()
        let board = NSPasteboard.general
        let before = board.changeCount
        try key(8) // Cmd+C
        // 只读取本次复制产生的内容，绝不把旧剪贴板当作选中文字。
        for _ in 0..<20 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 30_000_000)
            if board.changeCount != before {
                let count = board.changeCount
                let text = board.string(forType: .string)
                saved.restore(ifUnchanged: count)
                guard let text, !text.isEmpty else { throw SelectionCaptureError.noSelection }
                return text
            }
        }
        throw SelectionCaptureError.noSelection
    }

    static func integrity(_ snapshot: SelectionSnapshot) -> SelectionIntegrity {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return .changed }
        guard let element = snapshot.element else { return .unverifiable }
        guard let current = focusedElement(pid: snapshot.pid), CFEqual(current, element) else { return .changed }
        let original = snapshot.range.map { NSRange(location: $0.location, length: $0.length) }
        let range = textRange(current).map { NSRange(location: $0.location, length: $0.length) }
        return SelectionIntegrity.evaluate(sameTarget: true, originalRange: original, currentRange: range, originalText: snapshot.fullText,
                                           currentText: attribute(current, kAXValueAttribute) as? String, source: snapshot.source,
                                           selectedText: attribute(current, kAXSelectedTextAttribute) as? String)
    }
    static func unchanged(_ snapshot: SelectionSnapshot) -> Bool { integrity(snapshot) == .matches }

    /// 微信没有选区范围时仍须确认同一进程、窗口和可读取的焦点元素。
    static func clipboardTargetUnchanged(_ snapshot: SelectionSnapshot) -> Bool {
        guard !snapshot.readOnly, snapshot.clipboardCompatibility, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
              let originalWindow = snapshot.window, let currentWindow = focusedWindow(pid: snapshot.pid),
              CFEqual(originalWindow, currentWindow) else { return false }
        if let original = snapshot.element {
            guard let current = focusedElement(pid: snapshot.pid), CFEqual(original, current) else { return false }
            let role = attribute(current, kAXRoleAttribute) as? String
            let subrole = attribute(current, kAXSubroleAttribute) as? String
            guard role != kAXSecureTextFieldSubrole, subrole != kAXSecureTextFieldSubrole else { return false }
        }
        return true
    }

    static func replaceClipboardSelection(_ snapshot: SelectionSnapshot, with translation: String,
        allowed: () -> Bool, beforeWrite: () -> Void) async throws -> ReplacementResult {
        try Task.checkCancellation()
        guard allowed(), clipboardTargetUnchanged(snapshot) else {
            throw TranslationError.message("输入、选区或窗口已变化，未自动替换。译文已保留。")
        }
        // 仅兼容路径重新复制；不会在正常 AX/浏览器路径引入复制通知误拦截。
        let copied = try await copySelectedText(allowed: { allowed() && clipboardTargetUnchanged(snapshot) })
        guard ClipboardSelectionIntegrity.matches(sameTarget: clipboardTargetUnchanged(snapshot),
            inputUnchanged: allowed(), source: snapshot.source, copiedSelection: copied) else {
            throw TranslationError.message("微信当前选中文字与原文不一致，未自动替换。译文已保留。")
        }
        guard cutMenuEnabled(pid: snapshot.pid) == true else {
            throw TranslationError.message("当前微信选区无法确认可编辑，未自动替换。译文已保留。")
        }
        try Task.checkCancellation()
        guard try await waitForModifiersReleased(), allowed(), clipboardTargetUnchanged(snapshot) else {
            throw TranslationError.message("输入、选区或窗口已变化，未自动替换。译文已保留。")
        }
        let saved = SavedClipboard()
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(translation, forType: .string) else { throw TranslationError.message("无法写入剪贴板。") }
        let count = board.changeCount
        defer { saved.restore(ifUnchanged: count) }
        // 从最后一次核验到发出粘贴没有 await；不切换窗口、不发送 Return。
        guard allowed(), clipboardTargetUnchanged(snapshot) else {
            throw TranslationError.message("输入或窗口已变化，未自动替换。译文已保留。")
        }
        beforeWrite()
        try key(CGKeyCode(kVK_ANSI_V))
        // 微信不暴露可回读的结果，不冒充 confirmed。等待它消费剪贴板。
        try? await Task.sleep(nanoseconds: 600_000_000)
        return .clipboardSubmitted
    }

    private static func isWebEditor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<16 {
            guard let node = current else { break }
            if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" { return true }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return false
    }

    private static func verifyReplacement(_ snapshot: SelectionSnapshot, translation: String) async -> ReplacementVerification {
        var result = ReplacementVerification.unverifiable
        var sawExpectedText = false
        var invalidated = false
        // 等目标应用消费写入并稳定，避免网页状态回滚后仍显示成功。
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 75_000_000)
            if invalidated { continue }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
                  let original = snapshot.element, let current = focusedElement(pid: snapshot.pid), CFEqual(current, original) else { invalidated = true; continue }
            result = ReplacementVerification.evaluate(originalText: snapshot.fullText,
                range: snapshot.range.map { NSRange(location: $0.location, length: $0.length) },
                source: snapshot.source, translation: translation, currentText: attribute(current, kAXValueAttribute) as? String)
            if result == .changed || (sawExpectedText && result == .unchanged) { invalidated = true }
            if result == .confirmed { sawExpectedText = true }
        }
        return invalidated ? .changed : result
    }

    private static func bounds(_ element: AXUIElement, range: CFRange?) -> NSRect? {
        var rect = CGRect.zero
        if var range, let parameter = AXValueCreate(.cfRange, &range) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
               let value, CFGetTypeID(value) == AXValueGetTypeID() { _ = AXValueGetValue(value as! AXValue, .cgRect, &rect) }
        }
        if rect.isEmpty {
            var point = CGPoint.zero; var size = CGSize.zero
            if let position = attribute(element, kAXPositionAttribute), let dimensions = attribute(element, kAXSizeAttribute),
               CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID(),
               AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(dimensions as! AXValue, .cgSize, &size) {
                rect = CGRect(origin: point, size: size)
            }
        }
        guard !rect.isEmpty, rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite, let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func replace(_ snapshot: SelectionSnapshot, with translation: String, allowed: () -> Bool = { true }, beforeWrite: () -> Void = {}, writeFailed: () -> Void = {}) async throws -> ReplacementResult {
        try Task.checkCancellation()
        guard !snapshot.readOnly, allowed(), let element = snapshot.element, unchanged(snapshot) else { throw TranslationError.message("无法确认原输入框与选区，未自动替换。译文已保留，可手动复制。") }
        var settable: DarwinBoolean = false
        // 网页编辑器优先走真实粘贴，让页面收到正常的编辑事件。
        if !isWebEditor(element), AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            beforeWrite()
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, translation as CFString)
            switch await verifyReplacement(snapshot, translation: translation) {
            case .confirmed: return .confirmed
            case .unverifiable: return .submitted
            case .changed: throw TranslationError.message("写入后输入框内容或焦点变化，无法确认替换结果。译文已保留，可手动复制。")
            case .unchanged: break
            }
            writeFailed()
        }
        try Task.checkCancellation()
        guard allowed(), unchanged(snapshot) else { throw TranslationError.message("选区已变化，译文已保留，可手动复制。") }
        // unchanged 已核对同一输入框、范围与原文；不再发送额外的 Cmd+C。
        // 浏览器处理复制时可能发出焦点/选区通知，导致监听器误将自己的操作判为用户编辑。
        try Task.checkCancellation()
        guard try await waitForModifiersReleased() else {
            throw TranslationError.message("仍有修饰键按住，未自动粘贴。请松开快捷键后重试；译文已保留。")
        }
        // 等待按键释放后再核验，期间选区有变化仍然禁止覆盖。
        guard allowed(), unchanged(snapshot) else { throw TranslationError.message("选区已变化，译文已保留，可手动复制。") }
        beforeWrite()
        let saved = SavedClipboard()
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(translation, forType: .string) else { throw TranslationError.message("无法写入剪贴板。") }
        let count = board.changeCount
        do { try key(9) } catch { saved.restore(ifUnchanged: count); throw error } // Cmd+V，绝不发送 Return
        // 粘贴由目标应用异步消费；期间用户复制新内容时不覆盖新剪贴板。
        let verification = await verifyReplacement(snapshot, translation: translation)
        saved.restore(ifUnchanged: count)
        switch verification {
        case .confirmed: return .confirmed
        case .unchanged: throw TranslationError.message("输入框文字未改变，粘贴未生效。译文已保留，可手动复制。")
        case .changed: throw TranslationError.message("粘贴后内容或焦点变化，无法确认替换结果。译文已保留，可手动复制。")
        case .unverifiable: return .submitted
        }
    }
}
