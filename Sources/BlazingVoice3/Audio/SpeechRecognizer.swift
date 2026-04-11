import Foundation

/// Abstraction over speech-to-text backends
/// (Apple SFSpeechRecognizer, whisper-cli, ...).
protocol SpeechRecognizer: AnyObject, Sendable {
    /// True if the backend produces partial results while recording.
    /// Required for realtime / breath-pause chunked processing.
    var isRealtime: Bool { get }

    /// Fired when the recording stops on its own (max-duration timer).
    /// The payload is the final transcript, or an error.
    var onAutoStop: ((Result<String, Error>) -> Void)? { get set }

    /// Fired on each partial recognition result. Realtime backends only.
    var onPartialResult: ((String) -> Void)? { get set }

    /// URL of the most recent audio recording, if one exists.
    /// Used by session history to keep the raw audio alongside the transcript.
    var lastRecordingURL: URL? { get }

    /// Begin recording and recognition.
    func start(maxDuration: TimeInterval) throws

    /// Stop recording and return the final transcript.
    func finish() async throws -> String
}
