import Foundation

/// SpeechRecognizer backed by whisper-cli. Records audio to a file and
/// transcribes it after the recording stops. Not a realtime backend.
final class WhisperCLIRecognizer: SpeechRecognizer, @unchecked Sendable {
    let isRealtime = false

    var onAutoStop: ((Result<String, Error>) -> Void)?
    /// Whisper has no streaming partials; assignments are retained but never fired.
    var onPartialResult: ((String) -> Void)?
    var lastRecordingURL: URL? { recorder.lastRecordingURL }

    private let recorder: AudioRecorder
    private let evaluator: WhisperEvaluator

    init(cliPath: String, modelPath: String, recorder: AudioRecorder = AudioRecorder()) {
        self.recorder = recorder
        self.evaluator = WhisperEvaluator(whisperCLIPath: cliPath, modelPath: modelPath)
        self.recorder.onAutoStop = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let text = try await self.transcribeLastRecording()
                        self.onAutoStop?(.success(text))
                    } catch {
                        self.onAutoStop?(.failure(error))
                    }
                }
            case .failure(let error):
                self.onAutoStop?(.failure(error))
            }
        }
    }

    func start(maxDuration: TimeInterval) throws {
        try recorder.startRecordingOnly(maxDuration: maxDuration)
    }

    func finish() async throws -> String {
        let url = try recorder.stopRecording()
        let result = try await evaluator.evaluate(recordingURL: url)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeLastRecording() async throws -> String {
        guard let url = recorder.lastRecordingURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw BlazingError.noSpeechResult
        }
        let result = try await evaluator.evaluate(recordingURL: url)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
