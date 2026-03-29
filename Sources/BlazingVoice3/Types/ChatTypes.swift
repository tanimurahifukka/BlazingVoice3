import Foundation

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct GenerationResult: Sendable {
    let text: String
    let promptTokens: Int
    let completionTokens: Int
}

enum SlotPriority: Int, Comparable, Sendable {
    case low = 0
    case high = 1

    static func < (lhs: SlotPriority, rhs: SlotPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(string: String?) {
        switch string?.lowercased() {
        case "high", "realtime": self = .high
        default: self = .low
        }
    }
}

enum SlotState: String, Sendable {
    case idle
    case promptEval
    case generating
}
