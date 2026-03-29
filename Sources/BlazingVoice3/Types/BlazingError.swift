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
}
