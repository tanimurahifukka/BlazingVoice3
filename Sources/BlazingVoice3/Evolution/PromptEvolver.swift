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
        let feedbackText = feedbackEntries.map { entry in
            """
            --- エントリ (モード: \(entry.mode)) ---
            [音声認識テキスト]: \(entry.rawText)
            [辞書補正後]: \(entry.correctedText)
            [AI出力]: \(entry.generatedText)
            [ユーザー修正案]: \(entry.feedback ?? "(なし)")
            [品質スコア]: \(String(format: "%.0f%%", entry.qualityScore * 100))
            """
        }.joined(separator: "\n\n")

        let systemPrompt = """
        あなたは医療記録AIシステムの自己改善エージェントです。
        ユーザーから音声認識→AI変換パイプラインの実行結果とフィードバック（修正案）が提供されます。
        これらを分析し、システムを改善するための具体的な提案をJSON形式で出力してください。

        ## 分析の観点
        1. **辞書追加**: 音声認識の誤認識パターンを特定し、辞書エントリ（from→to）を提案する
           - 例: 音声認識が「ぶてな」→「布地」と誤認識しているが正しくは「ブテナフィン」
        2. **プロンプト改善**: AI出力の品質問題を特定し、プロンプトの改善提案をする
           - 例: 指導内容が省略されている → プロンプトに「〜を必ず記載」を追加
        3. **要約**: 何を改善したかの日本語要約

        ## 現在の辞書 (CSV形式、一部抜粋)
        \(String(currentDictionaryCSV.prefix(2000)))

        ## 現在のプロンプト (一部抜粋)
        \(String(currentPrompt.prefix(1500)))

        ## 出力形式 (厳密にこのJSON形式で出力)
        ```json
        {
          "dictionary_additions": [
            {"from": "誤認識テキスト", "to": "正しい医学用語"}
          ],
          "prompt_addition": "プロンプトに追加すべきルール（不要なら空文字）",
          "summary": "改善内容の日本語要約"
        }
        ```

        JSONのみを出力してください。前置き・説明は不要です。
        """

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: "以下のフィードバックを分析して改善案を出力してください:\n\n\(feedbackText)")
        ]

        let result = try await engine.generate(
            messages: messages,
            maxTokens: 2048,
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
