import Cocoa
import AVFoundation
import Speech

@MainActor
final class PermissionHelper: ObservableObject {
    @Published var micGranted = false
    @Published var speechGranted = false
    @Published var accessibilityGranted = false
    var onAccessibilityGranted: (() -> Void)?

    private var pollTimer: Timer?
    private var hasPromptedForAccessibilityThisSession = false

    /// Whether running inside an .app bundle with Info.plist (safe for TCC requests)
    private var hasInfoPlist: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    init() {
        // Only check status (not request) — safe even without Info.plist
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        // SFSpeechRecognizer.authorizationStatus() is safe to call without Info.plist
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        updateAccessibilityStatus(AXIsProcessTrusted())
    }

    var allGranted: Bool {
        micGranted && speechGranted && accessibilityGranted
    }

    // MARK: - Microphone

    func requestMicrophone() {
        guard hasInfoPlist else {
            NSLog("[Permissions] No Info.plist — cannot request mic (SPM debug build)")
            // Check if already authorized from a previous .app run
            refresh()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.micGranted = granted
            }
        }
    }

    // MARK: - Speech Recognition

    func requestSpeech() {
        guard hasInfoPlist else {
            NSLog("[Permissions] No Info.plist — cannot request speech (SPM debug build)")
            refresh()
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.speechGranted = (status == .authorized)
            }
        }
    }

    // MARK: - Accessibility

    func requestAccessibility() {
        refresh()
        guard !accessibilityGranted else { return }

        if !hasPromptedForAccessibilityThisSession {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            let _ = AXIsProcessTrustedWithOptions(options)
            hasPromptedForAccessibilityThisSession = true
            openAccessibilitySettings()
        }
        startPollingAccessibility()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func startPollingAccessibility() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if AXIsProcessTrusted() {
                    self.updateAccessibilityStatus(true)
                    NSLog("[Permissions] Accessibility granted!")
                }
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func updateAccessibilityStatus(_ granted: Bool) {
        let becameGranted = !accessibilityGranted && granted
        accessibilityGranted = granted
        if granted {
            stopPolling()
        }
        if becameGranted {
            onAccessibilityGranted?()
        }
    }

    // MARK: - Sequential request (only in .app bundle)

    func requestAll() async {
        guard hasInfoPlist else {
            NSLog("[Permissions] Skipping requestAll — no Info.plist")
            refresh()
            if !accessibilityGranted { requestAccessibility() }
            return
        }

        if !micGranted {
            requestMicrophone()
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(200))
                refresh()
                if micGranted { break }
            }
        }

        if !speechGranted {
            requestSpeech()
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(200))
                refresh()
                if speechGranted { break }
            }
        }

        if !accessibilityGranted {
            requestAccessibility()
        }
    }
}

extension PermissionHelper: PermissionManaging {}
