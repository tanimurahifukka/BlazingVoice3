import AppKit
import Foundation
import Speech

/// CLI test mode: runs the full pipeline without GUI
/// Usage: BlazingVoice3 --test [audio-file-path]
enum CLITest {
    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--test")
    }

    @MainActor
    static func run() async {
        let args = CommandLine.arguments
        let testIdx = args.firstIndex(of: "--test")!
        let audioPath = (testIdx + 1 < args.count) ? args[testIdx + 1] : nil

        print("=== BlazingVoice3 CLI Test ===")

        // 1. Load engine
        print("\n[1/4] Loading engine...")
        let settings = AppSettings()
        let modelManager = ModelManager()

        let model = modelManager.availableModels.first(where: { $0.id == settings.selectedModelId })
            ?? modelManager.availableModels.first(where: { $0.recommended })
            ?? modelManager.availableModels.first(where: { $0.isDownloaded })

        guard let model else {
            print("Error: No model available")
            exit(1)
        }

        print("  Model: \(model.name) (\(model.backend.rawValue))")

        let engine: any InferenceEngine
        do {
            engine = try await modelManager.createEngine(
                for: model,
                slotCount: settings.slotCount,
                kvQuantize: settings.kvQuantizeMode,
                maxMemoryGB: settings.effectiveMaxMemoryGB
            )
            print("  Engine loaded: \(engine.modelDescription)")
        } catch {
            print("Error: Engine load failed: \(error)")
            exit(1)
        }

        // 2. STT
        print("\n[2/4] Transcribing...")
        var rawText: String

        if let audioPath, FileManager.default.fileExists(atPath: audioPath) {
            print("  Audio file: \(audioPath)")
            do {
                rawText = try await transcribeFile(path: audioPath)
                print("  STT result: \(rawText.prefix(100))")
            } catch {
                print("  STT failed (\(error)), using dummy text")
                rawText = dummyText()
            }
        } else {
            print("  No audio file, using dummy text")
            rawText = dummyText()
        }

        // 3. Pipeline
        print("\n[3/4] Running pipeline (dictation mode)...")
        let dictionary = UserDictionary()
        let orchestrator = AgentOrchestrator(engine: engine, dictionary: dictionary)

        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let result = try await orchestrator.process(rawText: rawText, mode: .dictation)
            let elapsed = CFAbsoluteTimeGetCurrent() - t0

            print("  Time: \(String(format: "%.2f", elapsed))s")
            print("  Quality: \(String(format: "%.0f%%", result.qualityScore * 100))")
            if !result.qualityNotes.isEmpty {
                print("  Notes: \(result.qualityNotes.joined(separator: ", "))")
            }
            print("\n--- SOAP Output ---")
            print(result.generatedText)
            print("--- End ---")

            // 4. Clipboard
            print("\n[4/4] Clipboard...")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.generatedText, forType: .string)

            if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
                print("  OK (\(clip.count) chars)")
            } else {
                print("  FAILED")
                _exit(1)
            }
        } catch {
            print("Error: Pipeline failed: \(error)")
            _exit(1)
        }

        print("\n=== Test PASSED ===")
        fflush(stdout)
        _exit(0)
    }

    private static func dummyText() -> String {
        "今日は顔の湿疹で来ました。2週間前から両頬に赤いブツブツが出てきて、かゆみがあります。アトピーの既往があります。リンデロンVGを1日2回塗っていましたが改善しません。両頬に径5ミリ大の紅色丘疹が散在、一部に鱗屑を伴う。アトピー性皮膚炎の増悪と考えます。ステロイド外用のランクアップとプロトピック軟膏への切り替えを提案。2週間後に再診。"
    }

    private static func transcribeFile(path: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")),
              recognizer.isAvailable else {
            throw BlazingError.noSpeechResult
        }

        let url = URL(fileURLWithPath: path)
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}
