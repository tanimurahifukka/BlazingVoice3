import Foundation

/// Multi-agent pipeline orchestrator for quality-controlled voice-to-record processing.
///
/// Pipeline stages:
/// 1. STT Agent: Audio -> Raw text
/// 2. Dictionary Agent: Raw text -> Corrected text
/// 3. LLM Agent: Corrected text -> Structured output (SOAP/Bullet)
/// 4. Quality Agent: Validates structure, terminology, completeness
/// 5. Output Agent: Final formatting and delivery
actor AgentOrchestrator {
    let engine: any InferenceEngine
    let clusterEngine: ClusterEngine?
    let dictionary: UserDictionary

    struct PipelineResult: Sendable {
        let rawText: String
        let correctedText: String
        let generatedText: String
        let qualityScore: Double
        let qualityNotes: [String]
        let mode: VoiceMode
        let processingTime: TimeInterval
    }

    init(engine: any InferenceEngine, clusterEngine: ClusterEngine? = nil, dictionary: UserDictionary) {
        self.engine = engine
        self.clusterEngine = clusterEngine
        self.dictionary = dictionary
    }

    // MARK: - Full Pipeline

    func process(rawText: String, mode: VoiceMode, customPrompt: String? = nil) async throws -> PipelineResult {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Stage 1: Dictionary correction
        let correctedText = await dictionaryCorrection(rawText)

        // Stage 2: LLM generation (skip for normal mode)
        let generatedText: String
        if mode.requiresLLM {
            guard let systemPrompt = PromptTemplate.systemPrompt(for: mode, customPrompt: customPrompt) else {
                throw BlazingError.agentPipelineFailed("No system prompt for mode \(mode)")
            }
            let messages = PromptTemplate.buildMessages(systemPrompt: systemPrompt, userInput: correctedText)

            let activeEngine: any InferenceEngine = mode.usesCluster ? (clusterEngine ?? engine) : engine
            let result = try await activeEngine.generate(
                messages: messages,
                maxTokens: 2048,
                temperature: 0.3,
                priority: .high
            )
            generatedText = result.text
        } else {
            generatedText = correctedText
        }

        // Stage 3: Quality validation
        let (qualityScore, qualityNotes) = await qualityCheck(
            generated: generatedText,
            mode: mode
        )

        // Stage 4: Auto-retry if quality is too low
        var finalText = generatedText
        var finalQualityScore = qualityScore
        var finalQualityNotes = qualityNotes
        if qualityScore < 0.5 && mode.requiresLLM {
            print("[Agent] Quality score \(qualityScore) below threshold, retrying...")
            let retryPrompt = """
前回の出力品質が不十分でした。以下の点に注意して再生成してください：
\(qualityNotes.joined(separator: "\n"))

入力テキスト：
\(correctedText)
"""
            let systemPrompt = PromptTemplate.systemPrompt(for: mode, customPrompt: customPrompt) ?? ""
            let messages = PromptTemplate.buildMessages(systemPrompt: systemPrompt, userInput: retryPrompt)
            let retryEngine: any InferenceEngine = mode.usesCluster ? (clusterEngine ?? engine) : engine
            let retryResult = try await retryEngine.generate(
                messages: messages,
                maxTokens: 2048,
                temperature: 0.2,
                priority: .high
            )
            finalText = retryResult.text
            (finalQualityScore, finalQualityNotes) = await qualityCheck(
                generated: finalText,
                mode: mode
            )
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        return PipelineResult(
            rawText: rawText,
            correctedText: correctedText,
            generatedText: finalText,
            qualityScore: finalQualityScore,
            qualityNotes: finalQualityNotes,
            mode: mode,
            processingTime: elapsed
        )
    }

    // MARK: - Dictionary Agent

    private func dictionaryCorrection(_ text: String) async -> String {
        await dictionary.applyReplacements(to: text)
    }

    // MARK: - Quality Agent

    private func qualityCheck(generated: String, mode: VoiceMode) async -> (Double, [String]) {
        var score: Double = 1.0
        var notes: [String] = []

        switch mode {
        case .dictation, .cluster:
            // Check SOAP structure
            let requiredSections = ["【S】", "【O】", "【A】", "【P】"]
            for section in requiredSections {
                if !generated.contains(section) {
                    score -= 0.25
                    notes.append("Missing section: \(section)")
                }
            }

            // Check for unwanted AI commentary
            let unwantedPhrases = ["情報が不足", "推測", "確認が必要", "不明"]
            for phrase in unwantedPhrases {
                if generated.contains(phrase) {
                    score -= 0.1
                    notes.append("Contains unwanted phrase: \(phrase)")
                }
            }

        case .conversation:
            // Check bullet point structure
            if !generated.contains("・") && !generated.contains("-") {
                score -= 0.3
                notes.append("No bullet points found")
            }

        case .normal:
            // Check filler removal quality
            let fillers = ["えー", "あの", "えっと", "うーん", "そのー", "なんか", "まあ"]
            for filler in fillers {
                if generated.contains(filler) {
                    score -= 0.1
                    notes.append("Filler残存: \(filler)")
                }
            }
        }

        // Check for empty output
        if generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score = 0
            notes.append("Empty output")
        }

        // Check minimum length
        if generated.count < 20 && mode.requiresLLM {
            score -= 0.2
            notes.append("Output too short (\(generated.count) chars)")
        }

        return (max(0, score), notes)
    }
}
