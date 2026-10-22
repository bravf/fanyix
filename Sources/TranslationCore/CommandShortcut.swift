import CoreGraphics
import Carbon

/// 只查询硬件按键，避免把本应用发出的 Command+C 当成用户仍按着 Command。
public enum CommandShortcut {
    /// 仅用于区分本应用的复制/粘贴事件，不包含用户输入。
    public static let eventMarker: Int64 = 0x53485552554641

    public static var physicalModifiersPressed: Bool {
        [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
         kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl].contains {
            CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0))
        }
    }

    /// 使用私有事件源，并发送完整按下/释放序列，不遗留 Command 状态。
    /// 构造与发送分开，测试不会往用户输入框发送按键。
    public static func events(key: CGKeyCode) throws -> [CGEvent] {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw TranslationError.message("无法创建键盘事件源，译文已保留。")
        }
        let sequence: [(CGKeyCode, Bool, CGEventFlags)] = [
            (CGKeyCode(kVK_Command), true, .maskCommand),
            (key, true, .maskCommand),
            (key, false, .maskCommand),
            (CGKeyCode(kVK_Command), false, [])
        ]
        return try sequence.map { code, down, flags in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                throw TranslationError.message("无法创建键盘事件，译文已保留。")
            }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            return event
        }
    }
}
