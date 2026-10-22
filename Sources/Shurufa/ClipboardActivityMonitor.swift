import AppKit
import CoreGraphics
import TranslationCore

/// 仅在微信兼容请求期间观察是否发生操作，不读取/保存按键文字。
/// 硬件计数补充异步通知，自己的 Cmd+C/V 使用私有事件源和标记排除。
@MainActor
final class ClipboardActivityMonitor {
    private var global: Any?
    private var local: Any?
    private var baseline: [UInt32] = []
    private var invalidated = false
    private var generation = UUID()
    private(set) var isMonitoring = false
    private static let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]

    static func supports(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.tencent.xinWeChat"
    }

    func startIfNeeded() {
        stop()
        guard Self.supports(NSWorkspace.shared.frontmostApplication?.bundleIdentifier), AXIsProcessTrusted() else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        baseline = counters()
        invalidated = false
        let generation = self.generation
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != CommandShortcut.eventMarker else { return }
            Task { @MainActor [weak self] in
                guard self?.generation == generation else { return }; self?.invalidated = true
            }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != CommandShortcut.eventMarker {
                Task { @MainActor [weak self] in
                    guard self?.generation == generation else { return }; self?.invalidated = true
                }
            }
            return event
        }
        isMonitoring = global != nil && local != nil
        if !isMonitoring { stop() }
    }

    var unchanged: Bool {
        guard isMonitoring, !invalidated else { return false }
        if counters() != baseline { invalidated = true }
        return !invalidated
    }

    private func counters() -> [UInt32] {
        Self.types.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
    }

    func stop() {
        generation = UUID()
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil; local = nil; baseline = []; isMonitoring = false; invalidated = true
    }
}
