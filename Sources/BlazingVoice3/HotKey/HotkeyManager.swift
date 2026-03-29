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
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var advancedBindings: [HotkeyBinding] = []
    var isSuspended = false
    private var usingEventTap = false

    // Double-tap detection for modifier keys (Shift, etc.)
    private var doubleTapInterval: Double = 0.4
    private var shiftDetector = ShiftDoubleTapDetector(interval: 0.4)

    func configure(with settings: AppSettings) {
        doubleTapInterval = settings.doubleTapInterval
        shiftDetector = ShiftDoubleTapDetector(interval: settings.doubleTapInterval)

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
        stopMonitoring()

        let trusted = AXIsProcessTrusted()
        NSLog("[HotKey] Accessibility trusted: %d", trusted ? 1 : 0)

        usingEventTap = trusted && installEventTap()

        // keyDown monitors (for advanced per-mode hotkeys)
        if !usingEventTap {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.handleKeyEvent(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if self.usingEventTap {
                return self.matchesAdvancedBinding(flags: event.modifierFlags, keyCode: Int(event.keyCode)) ? nil : event
            }
            if self.handleKeyEvent(event) == true { return nil }
            return event
        }

        // flagsChanged monitors (for Left Shift double-tap) — always registered
        // CGEventTap handles keyDown only; flagsChanged goes through NSEvent monitors
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        NSLog("[HotKey] Monitoring started (eventTap=%d)", usingEventTap ? 1 : 0)
    }

    func restartMonitoring() {
        NSLog("[HotKey] Restarting monitors")
        startMonitoring()
    }

    /// Detect Left Shift double-tap via flagsChanged events
    private func handleFlagsChanged(_ event: NSEvent) {
        handleFlagsChanged(keyCode: Int(event.keyCode), flags: event.modifierFlags)
    }

    private func handleFlagsChanged(keyCode: Int, flags: NSEvent.ModifierFlags) {
        guard !isSuspended else { return }

        let shiftDown = flags.contains(.shift)
        if shiftDetector.register(
            keyCode: keyCode,
            shiftDown: shiftDown,
            now: ProcessInfo.processInfo.systemUptime
        ) {
            NSLog("[HotKey] Double-tap Left Shift!")
            onDoubleTap?()
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard !isSuspended else { return false }

        return matchesAdvancedBinding(flags: event.modifierFlags, keyCode: Int(event.keyCode), trigger: true)
    }

    private func matchesAdvancedBinding(flags: NSEvent.ModifierFlags, keyCode: Int, trigger: Bool = false) -> Bool {
        let normalizedFlags = flags.intersection(.deviceIndependentFlagsMask)
        for binding in advancedBindings {
            let bindingFlags = NSEvent.ModifierFlags(rawValue: UInt(binding.modifierFlags))
                .intersection(.deviceIndependentFlagsMask)
            if normalizedFlags == bindingFlags && keyCode == binding.keyCode {
                if trigger {
                    NSLog("[HotKey] Advanced: %@ (key=%d)", binding.mode.rawValue, keyCode)
                    onHotkeyPress?(binding.mode)
                }
                return true
            }
        }
        return false
    }

    private func installEventTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            manager.handleEventTap(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            NSLog("[HotKey] Failed to create CGEvent tap")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                NSLog("[HotKey] Re-enabling CGEvent tap")
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        case .keyDown:
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            _ = matchesAdvancedBinding(flags: flags, keyCode: keyCode, trigger: true)
        default:
            break
        }
    }

    func stopMonitoring() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m); globalFlagsMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        usingEventTap = false
    }
}

extension HotkeyManager: HotkeyManaging {}
