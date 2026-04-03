import SwiftUI

struct EvolutionSettingsView: View {
    @EnvironmentObject var evolutionLog: EvolutionLog
    @EnvironmentObject var dictionary: UserDictionary
    @EnvironmentObject var settings: AppSettings

    @State private var selectedEntry: EvolutionLog.LogEntry?
    @State private var feedbackText = ""
    @State private var isEvolving = false
    @State private var evolutionStatus = ""
    @State private var showEvolutionResult = false
    @State private var lastEvolutionSummary = ""

    var body: some View {
        HSplitView {
            // Left: Entry list
            entryListView
                .frame(minWidth: 200, idealWidth: 220)

            // Right: Detail + feedback
            detailView
                .frame(minWidth: 300)
        }
        .padding(8)
        .alert("進化結果", isPresented: $showEvolutionResult) {
            Button("OK") {}
        } message: {
            Text(lastEvolutionSummary)
        }
    }

    // MARK: - Entry List

    private var entryListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("パイプライン履歴")
                    .font(.headline)
                Spacer()
                Text("\(evolutionLog.entries.count)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            List(evolutionLog.entries, selection: $selectedEntry) { entry in
                entryRow(entry)
                    .tag(entry)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedEntry = entry }
            }
            .listStyle(.plain)
        }
    }

    private func entryRow(_ entry: EvolutionLog.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                modeIcon(entry.mode)
                Text(entry.date, style: .date)
                    .font(.caption2)
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                qualityBadge(entry.qualityScore)
            }
            Text(entry.generatedText.prefix(50))
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            if entry.feedback != nil {
                HStack(spacing: 2) {
                    Image(systemName: "text.bubble.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text("修正案あり")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail View

    private var detailView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry = selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Header
                        HStack {
                            modeIcon(entry.mode)
                            Text(modeDisplayName(entry.mode))
                                .font(.headline)
                            Spacer()
                            qualityBadge(entry.qualityScore)
                            Text(entry.date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        // Raw text
                        sectionBox("音声認識テキスト", text: entry.rawText, color: .orange)

                        // Corrected text (if different)
                        if entry.correctedText != entry.rawText {
                            sectionBox("辞書補正後", text: entry.correctedText, color: .purple)
                        }

                        // Generated text
                        sectionBox("AI出力", text: entry.generatedText, color: .green)

                        Divider()

                        // Feedback section
                        feedbackSection(entry)
                    }
                    .padding(12)
                }
            } else {
                VStack {
                    Spacer()
                    Text("左の履歴から項目を選択してください")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func sectionBox(_ title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(color)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.05))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.2)))
        }
    }

    // MARK: - Feedback & Evolution

    private func feedbackSection(_ entry: EvolutionLog.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("修正案・フィードバック")
                .font(.caption.bold())

            if let existing = entry.feedback {
                Text(existing)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(6)

                if let fbDate = entry.feedbackDate {
                    Text("送信日時: \(fbDate.formatted())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $feedbackText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Text("正しいSOAP出力やメモを入力してください。AI出力全体をコピペ修正するのが最も効果的です。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("修正案を保存") {
                    guard !feedbackText.isEmpty else { return }
                    evolutionLog.addFeedback(entryId: entry.id, feedback: feedbackText)
                    feedbackText = ""
                    // Refresh selection
                    if let updated = evolutionLog.entries.first(where: { $0.id == entry.id }) {
                        selectedEntry = updated
                    }
                }
                .disabled(feedbackText.isEmpty)

                Spacer()

                Button(action: { Task { await runEvolution() } }) {
                    HStack(spacing: 4) {
                        if isEvolving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isEvolving ? "進化中..." : "修正案から進化実行")
                    }
                }
                .disabled(isEvolving || entriesWithFeedback.isEmpty)
                .buttonStyle(.borderedProminent)
            }

            if !evolutionStatus.isEmpty {
                Text(evolutionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Show count of entries with feedback
            if !entriesWithFeedback.isEmpty {
                Text("修正案あり: \(entriesWithFeedback.count)件 → 進化実行で辞書・プロンプトを自動改善")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
    }

    private var entriesWithFeedback: [EvolutionLog.LogEntry] {
        evolutionLog.entries.filter { $0.feedback != nil }
    }

    @MainActor
    private func runEvolution() async {
        let feedbackEntries = entriesWithFeedback
        guard !feedbackEntries.isEmpty else { return }

        isEvolving = true
        evolutionStatus = "フィードバックを分析中..."

        // Get engine from AppDelegate (via notification or shared state)
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let engine = appDelegate.engineForMode(.dictation) else {
            evolutionStatus = "エラー: エンジンが読み込まれていません"
            isEvolving = false
            return
        }

        let evolver = PromptEvolver(engine: engine)
        let currentCSV = dictionary.exportCSV()
        let currentPrompt = settings.effectiveSOAPPrompt

        do {
            evolutionStatus = "LLMで改善案を生成中..."
            let result = try await evolver.evolve(
                feedbackEntries: feedbackEntries,
                currentDictionaryCSV: currentCSV,
                currentPrompt: currentPrompt
            )

            // Apply dictionary additions
            for (from, to) in result.dictionaryAdditions {
                dictionary.addEntry(from: from, to: to)
            }

            // Apply prompt suggestion
            if let suggestion = result.promptSuggestion {
                let current = settings.customSOAPPrompt
                if current.isEmpty {
                    settings.customSOAPPrompt = suggestion
                } else {
                    settings.customSOAPPrompt = current + "\n\n" + suggestion
                }
            }

            let dictCount = result.dictionaryAdditions.count
            let promptChanged = result.promptSuggestion != nil
            evolutionStatus = "完了: 辞書+\(dictCount)件\(promptChanged ? " / プロンプト更新" : "")"
            lastEvolutionSummary = result.summary
                + "\n\n辞書追加: \(dictCount)件"
                + (promptChanged ? "\nプロンプト: 更新済" : "")
            showEvolutionResult = true

            NSLog("[Evolution] %@", result.summary)
        } catch {
            evolutionStatus = "エラー: \(error.localizedDescription)"
            NSLog("[Evolution] Error: %@", "\(error)")
        }

        isEvolving = false
    }

    // MARK: - Helpers

    private func modeIcon(_ mode: String) -> some View {
        let (icon, color): (String, Color) = switch mode {
        case "dictation": ("stethoscope", .blue)
        case "conversation": ("list.bullet", .green)
        case "normal": ("waveform", .orange)
        case "cluster": ("server.rack", .purple)
        default: ("questionmark", .gray)
        }
        return Image(systemName: icon)
            .font(.caption)
            .foregroundStyle(color)
    }

    private func modeDisplayName(_ mode: String) -> String {
        switch mode {
        case "dictation": "口述 (SOAP)"
        case "conversation": "会話 (箇条書き)"
        case "normal": "通常 (リアルタイム)"
        case "cluster": "クラスター"
        default: mode
        }
    }

    private func qualityBadge(_ score: Double) -> some View {
        let color: Color = score >= 0.8 ? .green : score >= 0.5 ? .orange : .red
        return Text("\(Int(score * 100))%")
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(4)
    }
}
