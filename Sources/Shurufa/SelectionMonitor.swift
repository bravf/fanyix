import AppKit
import ApplicationServices

/// AX 通知捕捉瞬时变化；轮询兜底，不读取键盘输入，不使用剪贴板。
@MainActor
final class SelectionMonitor {
    private var observer: AXObserver?
    private var registrations: [(AXUIElement, CFString)] = []
    private var activation: NSObjectProtocol?
    private var polling: Task<Void, Never>?
    private var changed = false
    private var snapshot: SelectionSnapshot?
    private var onChange: (() -> Void)?
    private var generation = UUID()
    private var clipboardUnchanged: (() -> Bool)?

    func start(_ snapshot: SelectionSnapshot, clipboardUnchanged: (() -> Bool)? = nil, onChange: @escaping () -> Void) {
        stop()
        guard snapshot.supportsVerification || (snapshot.clipboardCompatibility && clipboardUnchanged != nil) else { onChange(); return }
        changed = false; self.snapshot = snapshot; self.onChange = onChange
        self.clipboardUnchanged = clipboardUnchanged
        let generation = self.generation
        let callback: AXObserverCallback = { incoming, _, _, context in
            guard let context else { return }
            let monitor = Unmanaged<SelectionMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak monitor] in
                guard let monitor, monitor.snapshot != nil, let active = monitor.observer, CFEqual(incoming, active) else { return }
                monitor.invalidate()
            }
        }
        var created: AXObserver?
        if snapshot.supportsVerification, let element = snapshot.element,
           AXObserverCreate(snapshot.pid, callback, &created) == .success, let created {
            observer = created
            let app = AXUIElementCreateApplication(snapshot.pid)
            for (element, name) in [(element, kAXValueChangedNotification), (element, kAXSelectedTextChangedNotification),
                                    (app, kAXFocusedUIElementChangedNotification), (element, kAXUIElementDestroyedNotification)] {
                if AXObserverAddNotification(created, element, name as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success {
                    registrations.append((element, name as CFString))
                }
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let monitor = self else { return }
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor [weak monitor] in
                guard let monitor, monitor.generation == generation, let original = monitor.snapshot, let pid, pid != original.pid else { return }
                monitor.invalidate()
            }
        }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, self?.generation == generation else { return }; self?.check()
            }
        }
        check()
    }
    private func check() {
        guard !changed, let snapshot else { return }
        if snapshot.clipboardCompatibility {
            if clipboardUnchanged?() != true || !SelectionAccess.clipboardTargetUnchanged(snapshot) { invalidate() }
        } else if !SelectionAccess.unchanged(snapshot) { invalidate() }
    }
    private func invalidate() {
        guard !changed else { return }; changed = true; onChange?()
    }
    func stop() {
        generation = UUID()
        polling?.cancel(); polling = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }; activation = nil
        if let observer {
            for (element, name) in registrations { AXObserverRemoveNotification(observer, element, name) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        registrations = []; observer = nil; snapshot = nil; onChange = nil; clipboardUnchanged = nil
    }
}
