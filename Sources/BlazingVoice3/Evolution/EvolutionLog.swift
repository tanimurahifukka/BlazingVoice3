import Foundation

/// Tracks pipeline execution history and user feedback for prompt evolution.
@MainActor
final class EvolutionLog: ObservableObject {
    struct LogEntry: Identifiable, Codable {
        let id: UUID
        let date: Date
        let rawText: String
        let correctedText: String
        let generatedText: String
        let promptUsed: String
        let mode: String
        let qualityScore: Double
        var feedback: String?
        var feedbackDate: Date?

        init(result: AgentOrchestrator.PipelineResult, promptUsed: String) {
            self.id = UUID()
            self.date = Date()
            self.rawText = result.rawText
            self.correctedText = result.correctedText
            self.generatedText = result.generatedText
            self.promptUsed = promptUsed
            self.mode = result.mode.rawValue
            self.qualityScore = result.qualityScore
            self.feedback = nil
            self.feedbackDate = nil
        }
    }

    @Published var entries: [LogEntry] = []

    private let maxEntries = 100
    private var storageURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BlazingVoice3/Evolution")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pipeline_log.json")
    }

    init() {
        load()
    }

    func log(result: AgentOrchestrator.PipelineResult, promptUsed: String) {
        let entry = LogEntry(result: result, promptUsed: promptUsed)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func addFeedback(entryId: UUID, feedback: String) {
        if let idx = entries.firstIndex(where: { $0.id == entryId }) {
            entries[idx].feedback = feedback
            entries[idx].feedbackDate = Date()
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: storageURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) else {
            return
        }
        entries = decoded
    }
}
