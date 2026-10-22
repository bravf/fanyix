import AppKit
import Carbon

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    static let titles = ["⌘⌥E", "⌃⌥E", "⌘⇧E"]

    func register(choice: Int) -> Bool {
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { owner.action?() }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            if status != noErr { return false }
        }
        let options = [UInt32(cmdKey | optionKey), UInt32(controlKey | optionKey), UInt32(cmdKey | shiftKey)]
        let modifiers = options[options.indices.contains(choice) ? choice : 0]
        let id = EventHotKeyID(signature: 0x53485246, id: 1)
        return RegisterEventHotKey(UInt32(kVK_ANSI_E), modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
