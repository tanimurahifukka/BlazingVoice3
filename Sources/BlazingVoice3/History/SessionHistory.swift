import Foundation

@MainActor
final class SessionHistory: ObservableObject {
    struct Session: Identifiable {
        let id = UUID()
        let rawText: String
        let generatedText: String
        let mode: VoiceMode
        let qualityScore: Double
        let date: Date
    }

    @Published var sessions: [Session] = []

    private let maxSessions = 50

    func addSession(_ result: AgentOrchestrator.PipelineResult) {
        let session = Session(
            rawText: result.rawText,
            generatedText: result.generatedText,
            mode: result.mode,
            qualityScore: result.qualityScore,
            date: Date()
        )
        sessions.insert(session, at: 0)
        if sessions.count > maxSessions {
            sessions = Array(sessions.prefix(maxSessions))
        }
    }

    func clear() {
        sessions.removeAll()
    }
}
