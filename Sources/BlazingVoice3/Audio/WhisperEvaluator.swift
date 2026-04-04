import AVFoundation
import Foundation

/// Runs whisper-cli on a saved recording and returns the transcription result.
final class WhisperEvaluator: Sendable {
    struct WhisperResult: Sendable {
        let text: String
        let processingTime: TimeInterval
    }

    let whisperCLIPath: String
    let modelPath: String

    init(whisperCLIPath: String, modelPath: String) {
        self.whisperCLIPath = whisperCLIPath
        self.modelPath = modelPath
    }

    /// Evaluate a CAF recording with whisper-cli. Converts to 16kHz mono WAV first.
    func evaluate(recordingURL: URL) async throws -> WhisperResult {
        let wavURL = try await convertToWAV(recordingURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let t0 = CFAbsoluteTimeGetCurrent()
        let text = try await runWhisperCLI(wavURL: wavURL)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        return WhisperResult(text: text, processingTime: elapsed)
    }

    // MARK: - CAF → WAV conversion

    private func convertToWAV(_ inputURL: URL) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")

        let sourceFile = try AVAudioFile(forReading: inputURL)
        let sourceFormat = sourceFile.processingFormat

        let targetSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let targetFormat = AVAudioFormat(settings: targetSettings)!

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw WhisperError.conversionFailed("Cannot create audio converter")
        }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: targetSettings)

        let bufferCapacity: AVAudioFrameCount = 4096
        guard let convertBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: bufferCapacity) else {
            throw WhisperError.conversionFailed("Cannot create PCM buffer")
        }

        var isDone = false
        while !isDone {
            let status = try converter.convert(to: convertBuffer, error: nil) { _, outStatus in
                guard let readBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: bufferCapacity
                ) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try sourceFile.read(into: readBuffer)
                    if readBuffer.frameLength == 0 {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return readBuffer
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            switch status {
            case .haveData:
                try outputFile.write(from: convertBuffer)
            case .endOfStream, .inputRanDry:
                isDone = true
            case .error:
                throw WhisperError.conversionFailed("Converter returned error status")
            @unknown default:
                isDone = true
            }
        }

        return outputURL
    }

    // MARK: - whisper-cli execution

    private func runWhisperCLI(wavURL: URL) async throws -> String {
        try await Task.detached { [whisperCLIPath, modelPath] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: whisperCLIPath)
            process.arguments = [
                "-m", modelPath,
                "-l", "ja",
                "--no-timestamps",
                "-f", wavURL.path,
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw WhisperError.processError(
                    "whisper-cli exited with code \(process.terminationStatus)"
                )
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                throw WhisperError.processError("Cannot decode whisper-cli output")
            }

            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

enum WhisperError: LocalizedError {
    case conversionFailed(String)
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .conversionFailed(let msg): "音声変換エラー: \(msg)"
        case .processError(let msg): "whisper-cliエラー: \(msg)"
        }
    }
}
