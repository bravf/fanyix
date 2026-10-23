import AppKit
import SwiftUI
import TranslationCore

/// 只渲染应用自己的视图，不读取桌面、不调用 Agent，也不修改用户配置。
@MainActor
enum UIPreview {
    static func render(to directory: URL) async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppDelegate(historyFile: nil)
        for (index, page) in SettingsPage.allCases.enumerated() {
            try await save(SettingsView(model: model, initialPage: page, loadsModels: false), size: NSSize(width: 760, height: 640), to: directory.appendingPathComponent("settings-\(index + 1).png"))
        }
        for style in ReplacementStyle.allCases {
            model.configuration.replacementStyle = style
            try await save(SettingsView(model: model, initialPage: .translation, loadsModels: false), size: NSSize(width: 760, height: 640), to: directory.appendingPathComponent("replacement-" + style.rawValue + ".png"))
        }
        let history = TranslationHistoryModel(file: nil)
        let overlay = TranslationOverlay(history: history, persistPosition: false)
        overlay.progress(title: "正在翻译…", detail: "可以继续编辑。")
        try await save(TranslationOverlayView(model: overlay), size: overlay.displaySize, to: directory.appendingPathComponent("toolbar-progress.png"))
        overlay.retain("I might be a little late today.", title: "原文或选区已变化，未替换")
        try await save(TranslationOverlayView(model: overlay), size: overlay.displaySize, to: directory.appendingPathComponent("toolbar-retained.png"))
        overlay.showHistory()
        try await save(TranslationOverlayView(model: overlay), size: overlay.displaySize, to: directory.appendingPathComponent("history-empty.png"))
        let now = Date()
        let records = [
            TranslationRecord(createdAt: now, source: "我今天可能会晚点到。我们可以改到明天上午十点吗？", backend: .codex, model: "默认模型", translation: "I might be a little late today. Could we reschedule for ten tomorrow morning?", notes: [
                TranslationNote(term: "might be", kind: "情态动词", explain: "表示不确定的推测，比 will be 更委婉；这里是「可能会」。"),
                TranslationNote(term: "a little", kind: "固定搭配", explain: "修饰形容词表示程度，相当于「有点」；a little late 即「有点晚」。"),
                TranslationNote(term: "reschedule for", kind: "固定搭配", explain: "把安排改到某个时间，后接时间点；比 change to 更正式。")
            ], status: .retained, detail: "原文或选区已变化，未自动替换。译文已保留，可复制。", completedAt: now),
            TranslationRecord(createdAt: now.addingTimeInterval(-900), source: "真冷呀", backend: .claude, model: "默认模型", translation: "It's so cold.", status: .pasted, detail: "已向微信粘贴翻译结果。", completedAt: now),
            TranslationRecord(createdAt: now.addingTimeInterval(-86_400), source: "收到，谢谢！", backend: .pi, model: "默认模型", translation: "Got it, thanks!", status: .replaced, completedAt: now)
        ]
        history.seedPreview(records); overlay.select(records[0].id)
        try await save(TranslationOverlayView(model: overlay), size: overlay.displaySize, to: directory.appendingPathComponent("history-details.png"))
        overlay.select(records[1].id)
        let newestID = UUID()
        history.begin(id: newestID, source: "这条是刚刚选中的聊天记录。", configuration: Configuration())
        overlay.progress(title: "正在翻译，完成后供复制", detail: "只读文字翻译")
        overlay.revealRequest(newestID)
        history.finish(id: newestID, translation: "This is the chat message I just selected.", status: .retained, detail: "只读文字翻译完成，可在历史中查看与复制。")
        overlay.retain("This is the chat message I just selected.", title: "译文已完成，请复制")
        try await save(TranslationOverlayView(model: overlay), size: overlay.displaySize, to: directory.appendingPathComponent("history-new-request.png"))
        let running = TranslationRecord(source: "这是正在翻译的一句话。", backend: .codex, model: "默认模型")
        history.seedPreview([running] + records); overlay.select(running.id)
        overlay.progress(title: "正在翻译…", detail: "正在查看历史，完成后保留译文。")
        try await save(TranslationOverlayView(model: overlay), size: overlay.displaySize, to: directory.appendingPathComponent("history-progress.png"))
        let long = TranslationRecord(source: String(repeating: "这是一段较长的原文，需要在详情区域滚动查看。\n", count: 12), backend: .codex, model: "默认模型", translation: String(repeating: "This is a longer translation, available by scrolling in the details.\n", count: 12), status: .retained)
        history.seedPreview([long] + records); overlay.select(long.id)
        try await save(TranslationOverlayView(model: overlay), size: overlay.displaySize, to: directory.appendingPathComponent("history-long.png"))
        overlay.message("未能完成翻译", detail: "Agent 连接失败，请检查当前 Agent 与模型设置。", phase: .error)
        try await save(TranslationOverlayView(model: overlay), size: overlay.displaySize, to: directory.appendingPathComponent("history-error.png"))
        overlay.hide()
        print("UI 预览已渲染：" + directory.path)
    }

    private static func save<Content: View>(_ view: Content, size: NSSize, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "UIPreview", code: 1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "UIPreview", code: 2) }
        try png.write(to: url)
        window.close()
    }
}
