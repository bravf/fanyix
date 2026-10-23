import AppKit
import SwiftUI
import TranslationCore

private final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 仅标题区域响应原生拖动，按钮保持可点击，窗口始终不成为输入焦点。
struct OverlayDragHandle: NSViewRepresentable {
    let onDragEnd: () -> Void
    func makeNSView(context: Context) -> DragView { DragView(onDragEnd: onDragEnd) }
    func updateNSView(_ view: DragView, context: Context) { view.onDragEnd = onDragEnd }
    final class DragView: NSView {
        var onDragEnd: () -> Void
        init(onDragEnd: @escaping () -> Void) { self.onDragEnd = onDragEnd; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
            onDragEnd()
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

@MainActor
final class TranslationOverlay: ObservableObject {
    enum Phase { case idle, progress, retained, success, error, cancelled }
    enum Mode { case simple, expanded }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: Mode = .simple
    @Published private(set) var title = "翻译记录"
    @Published private(set) var detail = ""
    @Published private(set) var translation = ""
    @Published private(set) var canCancel = true
    @Published private(set) var expandedContentHeight: CGFloat = 556
    @Published var selectedID: UUID?
    @Published private(set) var focusedRequestID: UUID?
    let history: TranslationHistoryModel
    var onCancel: (() -> Void)?
    var onCopy: ((String) -> Void)?
    var onSettings: (() -> Void)?
    var onInteract: (() -> Void)?
    private var panel: TranslationPanel?
    private var delayed: Task<Void, Never>?
    private var interactionMonitor: Any?
    private let positionDefaults: UserDefaults?
    private var position: [String: Double]?
    private var dismissed = false
    static let positionKey = "translationOverlayPosition"

    init(history: TranslationHistoryModel? = nil, persistPosition: Bool = true) {
        self.history = history ?? TranslationHistoryModel(file: nil)
        positionDefaults = persistPosition ? .standard : nil
        position = positionDefaults?.dictionary(forKey: Self.positionKey) as? [String: Double]
    }
    deinit { if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) } }
    var displaySize: NSSize { mode == .expanded ? NSSize(width: 460, height: 600) : NSSize(width: 292, height: 44) }
    var isTranslating: Bool { phase == .progress }
    var simpleTitle: String {
        switch phase {
        case .idle: return "翻译记录"
        case .progress: return "正在翻译…"
        case .retained: return "译文已保留"
        case .success: return "翻译完成"
        case .error: return "翻译失败"
        case .cancelled: return "已取消翻译"
        }
    }
    func beginRequest() {
        delayed?.cancel()
        // 关闭历史后，下一次请求从简单模式开始，不沿用隐藏窗口的展开状态。
        if panel?.isVisible != true { mode = .simple }
        dismissed = false
    }
    func progress(title: String, detail: String, anchor: NSRect? = nil, reposition: Bool = false, cancellable: Bool = true) {
        delayed?.cancel(); phase = .progress; self.title = title; self.detail = detail; translation = ""
        canCancel = cancellable
        if reposition { dismissed = false }
        if !dismissed { present() }
    }
    func retain(_ translation: String, title: String, detail: String = "译文已保留，当前输入未被替换。") {
        delayed?.cancel(); phase = .retained; self.title = title; self.translation = translation; self.detail = detail
        if !dismissed { present() }
    }
    func complete() {
        delayed?.cancel(); phase = .success; title = "翻译完成"; detail = "原文与译文已存入本机历史。"
        if mode == .simple { hide() } else if !dismissed { present() }
    }
    func message(_ title: String, detail: String = "", phase: Phase, dismissAfter: Double? = nil) {
        delayed?.cancel(); self.phase = phase; self.title = title; self.detail = detail; translation = ""
        if phase == .success { complete(); return }
        if !dismissed { present() }
        if let dismissAfter, mode == .simple {
            delayed = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(dismissAfter * 1_000_000_000))
                guard !Task.isCancelled, let self, self.mode == .simple else { return }; self.hide()
            }
        }
    }
    func expand() {
        interact(); delayed?.cancel(); dismissed = false; mode = .expanded
        if selectedID == nil { selectedID = history.records.first?.id }
        present()
    }
    func collapse() { interact(); delayed?.cancel(); mode = .simple; dismissed = false; present() }
    func showHistory(resetStatus: Bool = false) {
        if resetStatus { phase = .idle; title = "翻译记录"; detail = ""; translation = ""; canCancel = false }
        expand()
    }
    func focusRequest(_ id: UUID) {
        selectedID = id
        focusedRequestID = id
    }
    /// 系统展示只读翻译，不属于用户点击历史，不触发交互回调。
    func revealRequest(_ id: UUID) {
        focusRequest(id); delayed?.cancel(); dismissed = false; mode = .expanded
        present()
    }
    func select(_ id: UUID) { interact(); selectedID = id }
    func interact() { if isTranslating { onInteract?() } }
    func copyText(_ text: String) { interact(); onCopy?(text) }
    func removeSelected() {
        interact()
        guard let id = selectedID else { return }
        history.remove(id); selectedID = history.records.first?.id
    }
    func clearHistory() { interact(); history.clearCompleted(); selectedID = history.records.first?.id }
    func hide() { delayed?.cancel(); delayed = nil; dismissed = true; panel?.orderOut(nil) }
    func rememberPosition() {
        interact()
        guard let panel, let screen = panel.screen else { return }
        let visible = screen.visibleFrame
        position = ["screen": screenNumber(screen), "right": visible.maxX - panel.frame.maxX, "bottom": panel.frame.minY - visible.minY]
        positionDefaults?.set(position, forKey: Self.positionKey)
        present()
    }
    private func screenNumber(_ screen: NSScreen) -> Double {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.doubleValue ?? 0
    }
    func diagnosticState() -> [String: Any] {
        guard let panel else { return ["visible": false] }
        return ["visible": panel.isVisible, "isKey": panel.isKeyWindow, "canBecomeKey": panel.canBecomeKey,
                "nonactivating": panel.styleMask.contains(.nonactivatingPanel), "expanded": mode == .expanded,
                "withinScreen": NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) },
                "draggable": panel.isMovable, "width": panel.frame.width, "height": panel.frame.height]
    }
    private func present() {
        if panel == nil {
            let window = TranslationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .floating; window.isFloatingPanel = true; window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = true; window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.isMovable = true; window.setAccessibilityLabel("FanyiX翻译浮层")
            window.contentView = NSHostingView(rootView: TranslationOverlayView(model: self))
            panel = window
            // 在事件分发前停止自动替换，覆盖点击、滚动和标题拖动。
            interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged]) { [weak self] event in
                if let self, event.window === self.panel { self.interact() }
                return event
            }
        }
        let size = displaySize
        let savedScreen = position.flatMap { saved in NSScreen.screens.first { screenNumber($0) == saved["screen"] } }
        let currentScreen = panel?.isVisible == true ? panel?.screen : nil
        let screen = savedScreen ?? currentScreen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let fittedSize = NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        if mode == .expanded { expandedContentHeight = max(0, fittedSize.height - 44) }
        var origin = NSPoint(x: screen.visibleFrame.maxX - (position?["right"] ?? 24) - fittedSize.width,
                             y: screen.visibleFrame.minY + (position?["bottom"] ?? 24))
        origin.x = max(visible.minX, min(origin.x, visible.maxX - fittedSize.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - fittedSize.height))
        panel?.setFrame(NSRect(origin: origin, size: fittedSize), display: true)
        panel?.orderFrontRegardless()
    }
}

struct TranslationOverlayView: View {
    @ObservedObject var model: TranslationOverlay
    @ObservedObject private var history: TranslationHistoryModel
    @State private var confirmingClear = false
    @State private var lastScrolledRequestID: UUID?
    init(model: TranslationOverlay) { self.model = model; self.history = model.history }
    var body: some View {
        VStack(spacing: 0) {
            header
            // 保持挂载，收起展开保留列表与详情的滚动位置。
            expandedContent
                .frame(height: model.expandedContentHeight)
                .frame(height: model.mode == .expanded ? model.expandedContentHeight : 0, alignment: .top)
                .clipped().opacity(model.mode == .expanded ? 1 : 0)
                .allowsHitTesting(model.mode == .expanded).accessibilityHidden(model.mode != .expanded)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(FloatingPanelSurface())
    }
    private var header: some View {
        HStack(spacing: 8) {
            TranslationToolbar(title: model.mode == .expanded ? "翻译记录" : model.simpleTitle, spinning: model.isTranslating, symbol: symbol)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlay(OverlayDragHandle { model.rememberPosition() }).help("拖动调整位置")
            if model.isTranslating {
                if model.canCancel { iconButton("stop", label: "取消本次翻译") { model.onCancel?() } }
                else { Image(systemName: "ellipsis").frame(width: 23).accessibilityLabel("正在完成替换") }
            }
            iconButton(model.mode == .expanded ? "chevron.down" : "chevron.up", label: model.mode == .expanded ? "收起为简单模式" : "展开翻译历史") {
                if model.mode == .expanded { model.collapse() } else { model.expand() }
            }
            if model.mode == .expanded || !model.isTranslating { iconButton("xmark", label: "关闭浮层") { model.interact(); model.hide() } }
        }.padding(.horizontal, 12).frame(height: 44).help(model.detail)
    }
    private var expandedContent: some View {
        VStack(spacing: 0) {
            SettingsDivider()
            if !history.storageError.isEmpty {
                Text(history.storageError).font(.system(size: 11)).foregroundStyle(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.phase == .error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    Text(model.detail.isEmpty ? model.title : model.detail).font(.system(size: 11)).lineLimit(3)
                    Spacer(minLength: 0)
                    Button("设置") { model.onSettings?() }.buttonStyle(QuietButtonStyle())
                }.padding(12)
                SettingsDivider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if history.records.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "clock").font(.system(size: 24)).foregroundStyle(AppTheme.secondary)
                            Text("还没有翻译记录").font(.system(size: 13))
                            Text("选中文字，按快捷键开始翻译").font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 35)
                    } else {
                        ForEach(Array(history.records.enumerated()), id: \.element.id) { index, record in
                            if index == 0 || !Calendar.current.isDate(record.createdAt, inSameDayAs: history.records[index - 1].createdAt) {
                                Text(dayTitle(record.createdAt)).font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.secondary).padding(.horizontal, 10).padding(.top, 8)
                            }
                            recordRow(record).id(record.id)
                        }
                    }
                }.padding(8)
                }.frame(height: 190)
                    .task(id: model.mode == .expanded ? model.focusedRequestID : nil) {
                        guard model.mode == .expanded, let id = model.focusedRequestID,
                              model.selectedID == id, lastScrolledRequestID != id else { return }
                        // 新记录插入并完成布局后定位；仅收起再展开不重置手动滚动位置。
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(id, anchor: .top)
                        lastScrolledRequestID = id
                    }
            }
            SettingsDivider()
            detailContent
            SettingsDivider()
            footer
        }.contentShape(Rectangle()).simultaneousGesture(TapGesture().onEnded { model.interact() })
    }
    private func recordRow(_ record: TranslationRecord) -> some View {
        Button { model.select(record.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.source).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(record.translation.isEmpty ? (record.status == .translating ? "正在翻译…" : record.detail) : record.translation)
                        .font(.system(size: 12)).foregroundStyle(AppTheme.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(record.createdAt, style: .time).font(.system(size: 10)).foregroundStyle(AppTheme.secondary)
                    Text(record.status.title).font(.system(size: 10, weight: .medium)).foregroundStyle(statusColor(record.status))
                }
            }.padding(10).background(model.selectedID == record.id ? AppTheme.green.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(record.source + "，" + record.status.title)
    }
    @ViewBuilder private var detailContent: some View {
        if let record = history.records.first(where: { $0.id == model.selectedID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("翻译详情").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(record.status.title).font(.system(size: 11)).foregroundStyle(statusColor(record.status))
                        iconButton("trash", label: "删除此条记录") { model.removeSelected() }.disabled(record.status == .translating)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.backend.title + " · " + (record.model.isEmpty ? "默认模型" : record.model)).font(.system(size: 10)).foregroundStyle(AppTheme.secondary)
                        Text(record.createdAt, style: .date).font(.system(size: 10)).foregroundStyle(AppTheme.secondary)
                    }
                    textSection("原文", text: record.source, prominent: false)
                    SettingsDivider()
                    if !record.translation.isEmpty { textSection("译文", text: record.translation, prominent: true) }
                    else { Text(record.status == .translating ? "Agent 正在翻译…" : "本次未生成译文").font(.system(size: 13)).foregroundStyle(AppTheme.secondary) }
                    if !englishNotes(record.notes).isEmpty {
                        SettingsDivider()
                        notesSection(englishNotes(record.notes))
                    }
                    if !record.detail.isEmpty { Text(record.detail).font(.system(size: 11)).foregroundStyle(AppTheme.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(16).id(record.id)
            }.id(record.id).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.system(size: 26)).foregroundStyle(AppTheme.secondary)
                Text(model.phase == .error ? model.title : "选择一条记录查看详情").font(.system(size: 13))
                if model.phase == .error {
                    Text(model.detail).font(.system(size: 11)).foregroundStyle(AppTheme.secondary).multilineTextAlignment(.center)
                    Button("打开设置") { model.onSettings?() }.buttonStyle(QuietButtonStyle())
                }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func textSection(_ title: String, text: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                Spacer()
                Button("复制" + title) { model.copyText(text) }.buttonStyle(QuietButtonStyle(prominent: prominent))
            }
            Text(text).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func englishNotes(_ notes: [TranslationNote]) -> [TranslationNote] {
        notes.filter(\.isEnglish)
    }
    private func notesSection(_ notes: [TranslationNote]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("英文注释").font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                Text(String(notes.count)).font(.system(size: 9, weight: .medium)).foregroundStyle(AppTheme.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(AppTheme.canvas, in: Capsule())
                Spacer()
            }
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(note.term).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                        if !note.kind.isEmpty {
                            Text(note.kind).font(.system(size: 9, weight: .medium)).foregroundStyle(AppTheme.green)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(AppTheme.green.opacity(0.10), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    if !note.explain.isEmpty {
                        Text(note.explain).font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                            .lineSpacing(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 10) {
            if confirmingClear {
                Text("清空已完成的记录？").font(.system(size: 11))
                Spacer()
                Button("取消") { confirmingClear = false }.buttonStyle(.plain)
                Button("清空") { model.clearHistory(); confirmingClear = false }.buttonStyle(.plain).foregroundStyle(.red)
            } else {
                Image(systemName: "internaldrive").font(.system(size: 10)).foregroundStyle(AppTheme.secondary)
                Text("仅存本机 · " + String(history.records.count) + " 条记录").font(.system(size: 10)).foregroundStyle(AppTheme.secondary)
                Spacer()
                Button("清空历史") { model.interact(); confirmingClear = true }.buttonStyle(.plain).font(.system(size: 11))
                    .disabled(!history.records.contains { $0.status != .translating })
            }
        }.font(.system(size: 11)).padding(.horizontal, 16).frame(height: 36)
    }
    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    private func statusColor(_ status: TranslationRecordStatus) -> Color {
        switch status { case .replaced, .pasted: return AppTheme.green; case .failed: return .red; default: return AppTheme.secondary }
    }
    private var symbol: String {
        switch model.phase {
        case .idle: return "clock"
        case .progress: return "arrow.triangle.2.circlepath"
        case .retained: return "doc.on.clipboard"
        case .success: return "checkmark"
        case .error: return "exclamationmark.circle"
        case .cancelled: return "minus.circle"
        }
    }
    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 23, height: 27).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(AppTheme.secondary).help(label).accessibilityLabel(label)
    }
}
