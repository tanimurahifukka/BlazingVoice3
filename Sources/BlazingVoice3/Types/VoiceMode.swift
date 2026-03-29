import Foundation

/// BlazingVoice3 supports multiple voice input modes.
/// Normal mode is the default and primary mode.
enum VoiceMode: String, CaseIterable, Codable, Sendable {
    /// Realtime transcription with filler removal (default)
    case normal = "normal"
    /// SOAP format medical record generation
    case dictation = "dictation"
    /// Bullet-point summary generation
    case conversation = "conversation"
    /// Cluster-distributed inference mode
    case cluster = "cluster"

    var displayName: String {
        switch self {
        case .normal: return "通常モード (リアルタイム)"
        case .dictation: return "口述モード (SOAP)"
        case .conversation: return "会話モード (箇条書き)"
        case .cluster: return "クラスターモード"
        }
    }

    var description: String {
        switch self {
        case .normal: return "フィラー除去+整文して文字起こし"
        case .dictation: return "音声をSOAP形式の医療記録に変換"
        case .conversation: return "会話内容を箇条書きに要約"
        case .cluster: return "複数ノードで分散推論"
        }
    }

    var requiresLLM: Bool { true }

    var usesCluster: Bool { self == .cluster }
}
