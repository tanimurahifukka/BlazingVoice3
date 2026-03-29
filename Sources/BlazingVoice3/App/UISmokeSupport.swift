import AppKit
import Foundation

@MainActor
final class TestPermissionManager: PermissionManaging {
    var micGranted: Bool
    var speechGranted: Bool
    var accessibilityGranted: Bool
    var onAccessibilityGranted: (() -> Void)?

    private(set) var refreshCount = 0
    private(set) var requestMicrophoneCount = 0
    private(set) var requestSpeechCount = 0
    private(set) var requestAccessibilityCount = 0

    init(
        micGranted: Bool = true,
        speechGranted: Bool = true,
        accessibilityGranted: Bool = true
    ) {
        self.micGranted = micGranted
        self.speechGranted = speechGranted
        self.accessibilityGranted = accessibilityGranted
    }

    func refresh() {
        refreshCount += 1
    }

    func requestMicrophone() {
        requestMicrophoneCount += 1
    }

    func requestSpeech() {
        requestSpeechCount += 1
    }

    func requestAccessibility() {
        requestAccessibilityCount += 1
    }

    func grantAccessibility() {
        accessibilityGranted = true
        onAccessibilityGranted?()
    }
}

final class TestAudioRecorder: AudioRecording, @unchecked Sendable {
    var onAutoStop: ((Result<String, Error>) -> Void)?
    var onPartialResult: ((String) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?
    var stopResult: Result<String, Error> = .success("テスト入力")

    func startRecording(maxDuration: TimeInterval) throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func stopRecordingAndTranscribe() async throws -> String {
        stopCount += 1
        return try stopResult.get()
    }

    func emitPartial(_ text: String) {
        onPartialResult?(text)
    }
}

@MainActor
final class TestStatusBarController: StatusBarControlling {
    private(set) var states: [StatusBarVisualState] = []
    private(set) var menus: [NSMenu] = []

    var latestMenu: NSMenu? { menus.last }
    var latestState: StatusBarVisualState? { states.last }

    func setup() {}

    func updateState(_ state: StatusBarVisualState) {
        states.append(state)
    }

    func setMenu(_ menu: NSMenu) {
        menus.append(menu)
    }
}

@MainActor
final class TestOverlayPresenter: OverlayPresenting {
    private(set) var messages: [String] = []

    func show(message: String, duration: TimeInterval) {
        messages.append(message)
    }

    func hide() {}
}

@MainActor
final class TestHotkeyManager: HotkeyManaging {
    var onDoubleTap: (() -> Void)?
    var onHotkeyPress: ((VoiceMode) -> Void)?

    private(set) var startMonitoringCount = 0
    private(set) var restartMonitoringCount = 0
    private(set) var stopMonitoringCount = 0
    private(set) var configureCount = 0

    func configure(with settings: AppSettings) {
        configureCount += 1
    }

    func startMonitoring() {
        startMonitoringCount += 1
    }

    func restartMonitoring() {
        restartMonitoringCount += 1
    }

    func stopMonitoring() {
        stopMonitoringCount += 1
    }

    func simulateDoubleTap() {
        onDoubleTap?()
    }

    func simulateHotkey(mode: VoiceMode) {
        onHotkeyPress?(mode)
    }
}

@MainActor
enum UISmokeHarness {
    private enum HarnessError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case .failed(let message):
                return message
            }
        }
    }

    private static func waitUntil(
        timeoutSeconds: Double = 2.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw HarnessError.failed("Timed out waiting for expected UI state")
    }

    private static func menuTitles(_ menu: NSMenu?) -> [String] {
        menu?.items.map(\.title) ?? []
    }

    private static func restoreClipboard(_ previousValue: String?) {
        NSPasteboard.general.clearContents()
        if let previousValue {
            NSPasteboard.general.setString(previousValue, forType: .string)
        }
    }

    static func run() async {
        print("=== UI Smoke ===")

        let previousClipboard = NSPasteboard.general.string(forType: .string)
        let permissions = TestPermissionManager()
        let audioRecorder = TestAudioRecorder()
        let statusBar = TestStatusBarController()
        let overlay = TestOverlayPresenter()
        let hotkeys = TestHotkeyManager()
        let appDelegate = AppDelegate(
            settings: AppSettings(),
            modelManager: ModelManager(),
            sessionHistory: SessionHistory(),
            evolutionLog: EvolutionLog(),
            permissions: permissions,
            audioRecorder: audioRecorder,
            statusBarControllerFactory: { statusBar },
            overlayFactory: { overlay },
            hotkeyManagerFactory: { hotkeys },
            launchOptions: .uiSmoke
        )

        var failureMessage: String?

        do {
            appDelegate.bootstrapForTesting()
            guard menuTitles(statusBar.latestMenu).contains("🎙 録音開始 (左Shift×2)") else {
                throw HarnessError.failed("Status menu did not expose the start item")
            }

            appDelegate.currentMode = .dictation
            hotkeys.simulateDoubleTap()
            try await waitUntil { appDelegate.pipelineState == .recording }
            guard audioRecorder.startCount == 1 else {
                throw HarnessError.failed("Dictation start was not triggered by hotkey")
            }
            guard menuTitles(statusBar.latestMenu).contains("⏹ 停止") else {
                throw HarnessError.failed("Status menu did not switch to the stop item")
            }

            audioRecorder.stopResult = .success("口述モード確認")
            hotkeys.simulateDoubleTap()
            try await waitUntil {
                if case .done = appDelegate.pipelineState {
                    return true
                }
                return false
            }
            guard NSPasteboard.general.string(forType: .string) == "口述モード確認" else {
                throw HarnessError.failed("Dictation flow did not update the clipboard")
            }

            appDelegate.currentMode = .normal
            permissions.accessibilityGranted = false
            appDelegate.menuStartRecording()
            try await waitUntil(timeoutSeconds: 0.5) {
                permissions.requestAccessibilityCount == 1
            }
            guard audioRecorder.startCount == 1 else {
                throw HarnessError.failed("Realtime mode should not start without accessibility permission")
            }

            let pastedTextStore = PasteCollector()
            await TextInjector.setTestPasteHandler { text in
                await pastedTextStore.append(text)
            }

            permissions.accessibilityGranted = true
            audioRecorder.stopResult = .success("こんにちは")
            appDelegate.menuStartRecording()
            try await waitUntil { appDelegate.pipelineState == .recording }

            appDelegate.menuStopRecording()
            try await waitUntil {
                if case .done = appDelegate.pipelineState {
                    return true
                }
                return false
            }

            let pastedTexts = await pastedTextStore.snapshot()
            guard pastedTexts == ["こんにちは"] else {
                throw HarnessError.failed("Realtime flow did not emit the final pasted text")
            }
            guard NSPasteboard.general.string(forType: .string) == "こんにちは" else {
                throw HarnessError.failed("Realtime flow did not publish the final clipboard text")
            }
        } catch {
            failureMessage = "\(error)"
        }

        await TextInjector.setTestPasteHandler(nil)
        restoreClipboard(previousClipboard)

        if let failureMessage {
            fputs("=== UI Smoke FAILED ===\n\(failureMessage)\n", stderr)
            fflush(stderr)
            _exit(1)
        }

        print("=== UI Smoke PASSED ===")
        fflush(stdout)
        _exit(0)
    }
}

actor PasteCollector {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}
