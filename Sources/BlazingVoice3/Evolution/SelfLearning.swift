import Foundation

/// Orchestrates batch re-evaluation of past recordings with a larger
/// Whisper model and feeds the improvements into the dictionary and
/// prompt evolution pipeline.
///
/// Flow:
///   1. Pick recent EvolutionLog entries that have a recording URL
///   2. Re-transcribe each recording with WhisperEvaluator (large model)
///   3. Store the Whisper output as feedback on each entry
///   4. Run PromptEvolver to extract dictionary additions + prompt suggestions
///   5. Apply dictionary additions to UserDictionary
actor SelfLearning {
    struct Progress: Sendable {
        let current: Int
        let total: Int
        let currentFile: String
    }

    struct Result: Sendable {
        let entriesProcessed: Int
        let dictionaryAdditions: [(from: String, to: String)]
        let promptSuggestion: String?
        let summary: String
    }

    private let engine: any InferenceEngine
    private let whisperCLIPath: String
    private let whisperModelPath: String

    init(engine: any InferenceEngine, whisperCLIPath: String, whisperModelPath: String) {
        self.engine = engine
        self.whisperCLIPath = whisperCLIPath
        self.whisperModelPath = whisperModelPath
    }

    /// Run self-learning on up to `limit` recent entries.
    /// `onProgress` is called before each re-transcription starts.
    func run(
        entries: [EvolutionLog.LogEntry],
        currentDictionaryCSV: String,
        currentPrompt: String,
        limit: Int = 5,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Result {
        let evaluator = WhisperEvaluator(
            whisperCLIPath: whisperCLIPath,
            modelPath: whisperModelPath
        )

        // Filter entries that have a recording on disk and no existing feedback.
        let candidates = entries.filter { entry in
            guard entry.feedback == nil || entry.feedback?.isEmpty == true,
                  let url = entry.recordingURL,
                  FileManager.default.fileExists(atPath: url.path) else {
                return false
            }
            return true
        }
        let batch = Array(candidates.prefix(limit))

        guard !batch.isEmpty else {
            return Result(
                entriesProcessed: 0,
                dictionaryAdditions: [],
                promptSuggestion: nil,
                summary: "再評価対象のエントリが見つかりませんでした（録音ファイルが存在しないか、既にフィードバック済み）"
            )
        }

        // Step 1: Re-transcribe each recording with Whisper.
        var feedbackPairs: [(entryId: UUID, whisperText: String)] = []
        for (i, entry) in batch.enumerated() {
            guard let url = entry.recordingURL else { continue }
            onProgress?(Progress(
                current: i + 1,
                total: batch.count,
                currentFile: url.lastPathComponent
            ))

            do {
                let whisperResult = try await evaluator.evaluate(recordingURL: url)
                let whisperText = whisperResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !whisperText.isEmpty else { continue }

                // Only use as feedback if the Whisper output differs from the original STT.
                if whisperText != entry.rawText {
                    feedbackPairs.append((entryId: entry.id, whisperText: whisperText))
                }
            } catch {
                NSLog("[SelfLearning] Whisper failed for %@: %@", url.lastPathComponent, "\(error)")
                continue
            }
        }

        guard !feedbackPairs.isEmpty else {
            return Result(
                entriesProcessed: batch.count,
                dictionaryAdditions: [],
                promptSuggestion: nil,
                summary: "\(batch.count)件を再評価しましたが、大型モデルの結果は元のSTTと同じでした。改善不要です。"
            )
        }

        // Step 2: Build synthetic feedback entries for the evolver.
        // We construct LogEntry-like objects where feedback = whisper transcription.
        let syntheticEntries: [EvolutionLog.LogEntry] = feedbackPairs.compactMap { pair in
            guard var entry = entries.first(where: { $0.id == pair.entryId }) else { return nil }
            entry.feedback = pair.whisperText
            entry.feedbackDate = Date()
            return entry
        }

        // Step 3: Run PromptEvolver to extract dictionary additions and prompt improvements.
        let evolver = PromptEvolver(engine: engine)
        let evolutionResult = try await evolver.evolve(
            feedbackEntries: syntheticEntries,
            currentDictionaryCSV: currentDictionaryCSV,
            currentPrompt: currentPrompt
        )

        return Result(
            entriesProcessed: batch.count,
            dictionaryAdditions: evolutionResult.dictionaryAdditions,
            promptSuggestion: evolutionResult.promptSuggestion,
            summary: """
            \(batch.count)件の録音を大型Whisperモデルで再評価。\
            \(feedbackPairs.count)件で改善を検出。\
            辞書追加: \(evolutionResult.dictionaryAdditions.count)件。\
            \(evolutionResult.summary)
            """
        )
    }
}
