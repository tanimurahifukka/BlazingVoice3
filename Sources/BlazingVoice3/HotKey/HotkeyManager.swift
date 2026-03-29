import Cocoa
import Carbon

final class HotkeyManager {
    struct HotkeyBinding {
        let mode: VoiceMode
        let modifierFlags: Int
        let keyCode: Int
    }

    /// Primary trigger: double-tap Left Shift to start/stop
    var onDoubleTap: (() -> Void)?
    /// Advanced: per-mode hotkey
    var onHotkeyPress: ((VoiceMode) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var advancedBindings: [HotkeyBinding] = []
    var isSuspended = false

    // Double-tap detection for modifier keys (Shift, etc.)
    private var lastShiftTapTime: TimeInterval = 0
    private var shiftWasDown = false
    private var doubleTapInterval: Double = 0.4

    func configure(with settings: AppSettings) {
        doubleTapInterval = settings.doubleTapInterval

        advancedBindings = [
            HotkeyBinding(mode: .dictation,
                         modifierFlags: settings.hotkeyModifierFlags,
                         keyCode: settings.hotkeyKeyCode),
            HotkeyBinding(mode: .conversation,
                         modifierFlags: settings.bulletHotkeyModifierFlags,
                         keyCode: settings.bulletHotkeyKeyCode),
            HotkeyBinding(mode: .normal,
                         modifierFlags: settings.normalHotkeyModifierFlags,
                         keyCode: settings.normalHotkeyKeyCode),
            HotkeyBinding(mode: .cluster,
                         modifierFlags: settings.clusterHotkeyModifierFlags,
                         keyCode: settings.clusterHotkeyKeyCode),
        ]

        NSLog("[HotKey] Trigger: double-tap Left Shift (interval=%.2fs)", doubleTapInterval)
    }

    func startMonitoring() {
        let trusted = AXIsProcessTrusted()
        NSLog("[HotKey] Accessibility trusted: %d", trusted ? 1 : 0)

        // keyDown monitors (for advanced per-mode hotkeys)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if self?.handleKeyEvent(event) == true { return nil }
            return event
        }

        // flagsChanged monitors (for Left Shift double-tap)
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        NSLog("[HotKey] Monitoring started")
    }

    /// Detect Left Shift double-tap via flagsChanged events
    private func handleFlagsChanged(_ event: NSEvent) {
        guard !isSuspended else { return }

        // keyCode 56 = Left Shift
        let isLeftShift = event.keyCode == 56
        let shiftDown = event.modifierFlags.contains(.shift)

        if isLeftShift {
            if shiftDown && !shiftWasDown {
                // Shift pressed down
                let now = ProcessInfo.processInfo.systemUptime
                if (now - lastShiftTapTime) < doubleTapInterval {
                    NSLog("[HotKey] Double-tap Left Shift!")
                    lastShiftTapTime = 0
                    onDoubleTap?()
                } else {
                    lastShiftTapTime = now
                }
            }
            shiftWasDown = shiftDown
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard !isSuspended else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = Int(event.keyCode)

        for binding in advancedBindings {
            let bindingFlags = NSEvent.ModifierFlags(rawValue: UInt(binding.modifierFlags))
                .intersection(.deviceIndependentFlagsMask)
            if flags == bindingFlags && keyCode == binding.keyCode {
                NSLog("[HotKey] Advanced: %@ (key=%d)", binding.mode.rawValue, keyCode)
                onHotkeyPress?(binding.mode)
                return true
            }
        }
        return false
    }

    func stopMonitoring() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m); globalFlagsMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
    }
}
