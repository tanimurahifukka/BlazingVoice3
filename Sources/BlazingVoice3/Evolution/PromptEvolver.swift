import Foundation

/// Analyzes user feedback on past outputs and auto-evolves the dictionary and prompt.
actor PromptEvolver {
    private let engine: any InferenceEngine

    init(engine: any InferenceEngine) {
        self.engine = engine
    }

    struct EvolutionResult: Sendable {
        let dictionaryAdditions: [(from: String, to: String)]
        let promptSuggestion: String?
        let summary: String
    }

    /// Analyze feedback entries and generate improvements to dictionary and prompt.
    func evolve(
        feedbackEntries: [EvolutionLog.LogEntry],
        currentDictionaryCSV: String,
        currentPrompt: String
    ) async throws -> EvolutionResult {
        // Limit to most recent 3 entries to fit in context window (4096 tokens)
        let recentEntries = Array(feedbackEntries.prefix(3))

        let feedbackText = recentEntries.map { entry in
            // Truncate each field to keep total prompt compact
            let raw = String(entry.rawText.prefix(200))
            let generated = String(entry.generatedText.prefix(300))
            let fb = String((entry.feedback ?? "").prefix(300))
            return """
            [入力]: \(raw)
            [AI出力]: \(generated)
            [修正案]: \(fb)
            """
        }.joined(separator: "\n---\n")

        let systemPrompt = """
        医療記録AIの自己改善エージェント。フィードバックを分析しJSON出力。

        分析観点:
        1. 辞書追加: 音声認識の誤認識→正しい医学用語のペア
        2. プロンプト改善: 出力品質の問題→追加ルール提案
        3. 要約

        出力形式(JSONのみ):
        {"dictionary_additions":[{"from":"誤認識","to":"正表記"}],"prompt_addition":"追加ルール","summary":"要約"}
        """

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: feedbackText)
        ]

        let result = try await engine.generate(
            messages: messages,
            maxTokens: 512,
            temperature: 0.3,
            priority: .high
        )

        return parseEvolutionResult(result.text)
    }

    private func parseEvolutionResult(_ text: String) -> EvolutionResult {
        // Extract JSON from response (might be wrapped in ```json ... ```)
        let jsonText: String
        if let jsonStart = text.range(of: "{"),
           let jsonEnd = text.range(of: "}", options: .backwards) {
            jsonText = String(text[jsonStart.lowerBound...jsonEnd.upperBound])
        } else {
            return EvolutionResult(dictionaryAdditions: [], promptSuggestion: nil, summary: "解析失敗: JSONが見つかりません")
        }

        guard let data = jsonText.data(using: .utf8) else {
            return EvolutionResult(dictionaryAdditions: [], promptSuggestion: nil, summary: "解析失敗: エンコードエラー")
        }

        struct RawResult: Decodable {
            let dictionary_additions: [DictEntry]?
            let prompt_addition: String?
            let summary: String?

            struct DictEntry: Decodable {
                let from: String
                let to: String
            }
        }

        do {
            let raw = try JSONDecoder().decode(RawResult.self, from: data)
            let additions = (raw.dictionary_additions ?? []).map { ($0.from, $0.to) }
            let promptSuggestion = raw.prompt_addition?.isEmpty == false ? raw.prompt_addition : nil
            return EvolutionResult(
                dictionaryAdditions: additions,
                promptSuggestion: promptSuggestion,
                summary: raw.summary ?? "改善案を生成しました"
            )
        } catch {
            return EvolutionResult(dictionaryAdditions: [], promptSuggestion: nil, summary: "JSON解析失敗: \(error.localizedDescription)")
        }
    }
}
