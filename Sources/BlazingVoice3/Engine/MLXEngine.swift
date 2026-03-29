import Foundation
import MLX
import MLXLLM
import MLXLMCommon

final class MLXEngine: InferenceEngine, @unchecked Sendable {
    private let modelContainer: ModelContainer
    private let scheduler: MLXBatchScheduler
    private let memoryMonitor: MemoryMonitor
    let modelDescription: String
    private let initialSlotCount: Int

    var slotCount: Int { scheduler.currentSlotCount }

    init(modelId: String, slotCount: Int = 4, maxMemoryGB: Double? = nil, maxContext: Int? = nil) async throws {
        self.initialSlotCount = slotCount

        let configuration = ModelConfiguration(id: modelId)

        print("[MLX] Downloading/loading model: \(modelId)")
        self.modelContainer = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration,
            progressHandler: { progress in
                if progress.fractionCompleted < 1.0 {
                    print("[MLX] Progress: \(Int(progress.fractionCompleted * 100))%")
                }
            }
        )

        if let gb = maxMemoryGB {
            let bytes = Int(gb * 1024 * 1024 * 1024)
            Memory.memoryLimit = bytes
            Memory.cacheLimit = min(256 * 1024 * 1024, bytes / 10)
            Memory.clearCache()
            print("[MLX] Memory limit: \(gb)GB")
        }

        self.modelDescription = "MLX \(modelId)"
        self.scheduler = MLXBatchScheduler(modelContainer: modelContainer, slotCount: slotCount, maxContext: maxContext)

        let sched = self.scheduler
        self.memoryMonitor = MemoryMonitor(activeSlots: { [weak sched] in
            sched?.activeSlotCount ?? 0
        })

        let initSlots = slotCount
        self.memoryMonitor.onPressureChange = { [weak sched] pressure, info in
            guard let sched else { return }
            let current = sched.currentSlotCount

            switch pressure {
            case .normal:
                if current < initSlots {
                    sched.adjustSlots(to: current + 1)
                }
            case .low:
                break
            case .critical:
                if current > MLXBatchScheduler.minimumSlots {
                    sched.adjustSlots(to: current - 1)
                }
                Memory.clearCache()
            case .emergency:
                sched.adjustSlots(to: MLXBatchScheduler.minimumSlots)
                Memory.clearCache()
                print("[MLX] EMERGENCY: memory critically low, forced to \(MLXBatchScheduler.minimumSlots) slot(s)")
            }
        }

        self.memoryMonitor.start()
        print("[MLX] Model loaded successfully (batch scheduler + memory monitor active)")
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Float,
        priority: SlotPriority
    ) async throws -> GenerationResult {
        let mlxMessages: [[String: String]] = messages.map {
            ["role": $0.role, "content": $0.content]
        }

        return try await withCheckedThrowingContinuation { continuation in
            let job = MLXGenerationJob(
                messages: mlxMessages,
                maxTokens: maxTokens,
                temperature: temperature,
                priority: priority,
                continuation: continuation
            )
            scheduler.submit(job)
        }
    }

    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)] {
        scheduler.slotSummary()
    }

    func memoryInfo() -> EngineMemoryInfo? {
        let info = memoryMonitor.latestInfo
        let pressure = memoryMonitor.currentPressure
        return EngineMemoryInfo(
            totalPhysical: info.totalPhysical,
            rssBytes: info.rssBytes,
            freeEstimate: info.freeEstimate,
            activeSlots: info.activeSlots,
            pressure: pressure.rawValue
        )
    }
}
