/// Per-node memory status for cluster reporting.
struct EngineMemoryInfo: Sendable {
    let totalPhysical: UInt64
    let rssBytes: UInt64
    let freeEstimate: UInt64
    let activeSlots: Int
    let pressure: String          // "normal", "low", "critical", "emergency"
}

/// Unified inference engine protocol.
/// All backends (llama.cpp, MLX, cluster) conform to this protocol.
protocol InferenceEngine: Sendable {
    var modelDescription: String { get }
    var slotCount: Int { get }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Float,
        priority: SlotPriority
    ) async throws -> GenerationResult

    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)]

    /// Returns current memory status. Default implementation returns basic info.
    func memoryInfo() -> EngineMemoryInfo?
}

extension InferenceEngine {
    func memoryInfo() -> EngineMemoryInfo? { nil }
}
