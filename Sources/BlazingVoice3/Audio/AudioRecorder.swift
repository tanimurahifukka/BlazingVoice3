import AVFoundation
import Speech

final class AudioRecorder: @unchecked Sendable {
    var onAutoStop: ((Result<String, Error>) -> Void)?
    /// Called on each partial STT result (for real-time streaming mode)
    var onPartialResult: ((String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var autoStopTimer: Timer?
    private var audioFile: AVAudioFile?
    private(set) var lastRecordingURL: URL?

    private var transcribedText = ""
    private var recognitionFinished = false

    var isRecording: Bool {
        audioEngine?.isRunning ?? false
    }

    var isModelLoaded: Bool {
        speechRecognizer?.isAvailable ?? false
    }

    init() {}

    private func ensureRecognizer() {
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
        }
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let speechAuth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status)
            }
        }
        guard speechAuth == .authorized else { return false }
        let micAuth = await AVCaptureDevice.requestAccess(for: .audio)
        return micAuth
    }

    // MARK: - Recording

    func startRecording(maxDuration: TimeInterval = 300) throws {
        NSLog("[Audio] startRecording called")

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            NSLog("[Audio] mic not authorized: %d", micStatus.rawValue)
            throw BlazingError.microphoneNotAuthorized
        }

        ensureRecognizer()
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            NSLog("[Audio] speech recognizer not available")
            throw BlazingError.whisperKitUnavailable
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        transcribedText = ""
        recognitionFinished = false

        let engine = AVAudioEngine()
        audioEngine = engine

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.recognitionRequest = request

        let inputNode = engine.inputNode

        let recordingURL = Self.newRecordingURL()
        lastRecordingURL = recordingURL
        let tapFormat = inputNode.outputFormat(forBus: 0)
        do {
            audioFile = try AVAudioFile(forWriting: recordingURL, settings: tapFormat.settings)
        } catch {
            NSLog("[Audio] could not create audio file: %@", "\(error)")
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            request.append(buffer)
            try? self?.audioFile?.write(from: buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.transcribedText = result.bestTranscription.formattedString
                // Notify partial result for real-time streaming
                self.onPartialResult?(self.transcribedText)
                if result.isFinal {
                    NSLog("[Audio] Recognition final: %@", String(self.transcribedText.prefix(80)))
                    self.recognitionFinished = true
                }
            }
            if let error {
                NSLog("[Audio] Recognition error: %@", "\(error)")
                self.recognitionFinished = true
            }
        }

        engine.prepare()
        try engine.start()
        NSLog("[Audio] Recording started")

        autoStopTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await self.stopRecordingAndTranscribe()
                    self.onAutoStop?(.success(text))
                } catch {
                    self.onAutoStop?(.failure(error))
                }
            }
        }
    }

    func stopRecordingAndTranscribe() async throws -> String {
        NSLog("[Audio] stopRecordingAndTranscribe called")

        autoStopTimer?.invalidate()
        autoStopTimer = nil

        // Stop audio input
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        audioEngine = nil
        audioFile = nil

        NSLog("[Audio] Audio stopped, waiting for final recognition...")

        // Wait for recognition to finish (up to 5 seconds)
        for _ in 0..<50 {
            if recognitionFinished { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        NSLog("[Audio] Recognition done. Text length: %d", transcribedText.count)

        // Clean up
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let text = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSLog("[Audio] No speech result")
            throw BlazingError.noSpeechResult
        }

        NSLog("[Audio] Transcribed: %@", String(text.prefix(100)))
        return text
    }

    // MARK: - File

    static func recordingsDirectory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/BlazingVoice3/Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = formatter.string(from: Date())
        return recordingsDirectory().appendingPathComponent("\(name).caf")
    }
}

extension AudioRecorder: AudioRecording {}
