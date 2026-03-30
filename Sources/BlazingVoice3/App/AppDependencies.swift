import Cocoa

enum StatusBarVisualState {
    case idle
    case recording
    case processing
    case done
    case error
}

@MainActor
protocol PermissionManaging: AnyObject {
    var micGranted: Bool { get }
    var speechGranted: Bool { get }
    var accessibilityGranted: Bool { get }
    var onAccessibilityGranted: (() -> Void)? { get set }

    func refresh()
    func requestMicrophone()
    func requestSpeech()
    func requestAccessibility()
}

protocol AudioRecording: AnyObject, Sendable {
    var onAutoStop: ((Result<String, Error>) -> Void)? { get set }
    var onPartialResult: ((String) -> Void)? { get set }

    func startRecording(maxDuration: TimeInterval) throws
    func stopRecordingAndTranscribe() async throws -> String
}

@MainActor
protocol StatusBarControlling: AnyObject {
    func setup()
    func updateState(_ state: StatusBarVisualState)
    func setMenu(_ menu: NSMenu)
}

@MainActor
protocol OverlayPresenting: AnyObject {
    func show(message: String, duration: TimeInterval)
    func showProgress(message: String, detail: String, progress: Double)
    func hide()
}

extension OverlayPresenting {
    func show(message: String) {
        show(message: message, duration: 2.0)
    }
    func showProgress(message: String, detail: String = "", progress: Double = -1) {
        showProgress(message: message, detail: detail, progress: progress)
    }
}

@MainActor
protocol HotkeyManaging: AnyObject {
    var onDoubleTap: (() -> Void)? { get set }
    var onHotkeyPress: ((VoiceMode) -> Void)? { get set }

    func configure(with settings: AppSettings)
    func startMonitoring()
    func restartMonitoring()
    func stopMonitoring()
}

struct AppLaunchOptions {
    var requestPermissionsOnLaunch = true
    var loadEnginesOnLaunch = true
    var startHotkeyMonitoring = true

    static let live = Self()
    static let uiSmoke = Self(
        requestPermissionsOnLaunch: false,
        loadEnginesOnLaunch: false,
        startHotkeyMonitoring: false
    )
}
