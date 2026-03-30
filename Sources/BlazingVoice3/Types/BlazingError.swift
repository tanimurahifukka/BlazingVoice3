import Foundation

enum BlazingError: Error, CustomStringConvertible {
    // Engine errors
    case modelLoadFailed(String)
    case vocabLoadFailed
    case contextCreationFailed
    case samplerCreationFailed
    case decodeFailed
    case tokenizationFailed
    case templateFailed
    case noSlotsAvailable
    case contextExceeded
    case remoteNodeFailed

    // Audio errors
    case microphoneNotAuthorized
    case whisperModelNotLoaded
    case audioEngineError
    case noSpeechResult
    case whisperKitUnavailable

    // Model management errors
    case modelNotFound(String)
    case downloadFailed(String)
    case insufficientMemory

    // Agent errors
    case agentPipelineFailed(String)
    case qualityCheckFailed(String)

    var description: String {
        switch self {
        case .modelLoadFailed(let path): "Failed to load model: \(path)"
        case .vocabLoadFailed: "Failed to get vocabulary"
        case .contextCreationFailed: "Failed to create context"
        case .samplerCreationFailed: "Failed to create sampler"
        case .decodeFailed: "llama_decode failed"
        case .tokenizationFailed: "Tokenization failed"
        case .templateFailed: "Chat template application failed"
        case .noSlotsAvailable: "All KV cache slots are occupied"
        case .contextExceeded: "Prompt + max_tokens exceeds slot context size"
        case .remoteNodeFailed: "Remote cluster node failed to respond"
        case .microphoneNotAuthorized: "Microphone access not authorized"
        case .whisperModelNotLoaded: "Whisper model not loaded"
        case .audioEngineError: "Audio engine failed to start"
        case .noSpeechResult: "No speech was recognized"
        case .whisperKitUnavailable: "WhisperKit is not available"
        case .modelNotFound(let name): "Model not found: \(name)"
        case .downloadFailed(let msg): "Download failed: \(msg)"
        case .insufficientMemory: "Insufficient memory for model"
        case .agentPipelineFailed(let msg): "Agent pipeline failed: \(msg)"
        case .qualityCheckFailed(let msg): "Quality check failed: \(msg)"
        }
    }

    var userMessage: String {
        switch self {
        case .modelLoadFailed(let path): "モデル読込失敗: \(path)"
        case .vocabLoadFailed: "語彙データの取得に失敗"
        case .contextCreationFailed: "コンテキスト作成失敗"
        case .samplerCreationFailed: "サンプラー作成失敗"
        case .decodeFailed: "LLM推論エラー"
        case .tokenizationFailed: "トークナイズ失敗"
        case .templateFailed: "テンプレート適用失敗"
        case .noSlotsAvailable: "処理スロットが満杯です"
        case .contextExceeded: "入力が長すぎます"
        case .remoteNodeFailed: "クラスターノード応答なし"
        case .microphoneNotAuthorized: "マイク権限がありません"
        case .whisperModelNotLoaded: "Whisperモデル未読込"
        case .audioEngineError: "オーディオエンジンエラー"
        case .noSpeechResult: "音声が検出されませんでした"
        case .whisperKitUnavailable: "WhisperKit利用不可"
        case .modelNotFound(let name): "モデル未検出: \(name)"
        case .downloadFailed(let msg): "ダウンロード失敗: \(msg)"
        case .insufficientMemory: "メモリ不足"
        case .agentPipelineFailed(let msg): "\(msg)"
        case .qualityCheckFailed: "品質チェック失敗"
        }
    }
}
