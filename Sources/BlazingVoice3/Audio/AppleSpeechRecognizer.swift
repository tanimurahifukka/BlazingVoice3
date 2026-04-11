import Foundation

/// SpeechRecognizer backed by Apple's SFSpeechRecognizer via AudioRecorder.
/// Produces streaming partial results, so it can drive realtime mode.
final class AppleSpeechRecognizer: SpeechRecognizer, @unchecked Sendable {
    let isRealtime = true

    var onAutoStop: ((Result<String, Error>) -> Void)?
    var onPartialResult: ((String) -> Void)?
    var lastRecordingURL: URL? { recorder.lastRecordingURL }

    private let recorder: AudioRecorder

    init(recorder: AudioRecorder = AudioRecorder()) {
        self.recorder = recorder
        self.recorder.onAutoStop = { [weak self] result in
            self?.onAutoStop?(result)
        }
        self.recorder.onPartialResult = { [weak self] text in
            self?.onPartialResult?(text)
        }
    }

    func start(maxDuration: TimeInterval) throws {
        try recorder.startRecording(maxDuration: maxDuration)
    }

    func finish() async throws -> String {
        try await recorder.stopRecordingAndTranscribe()
    }
}
