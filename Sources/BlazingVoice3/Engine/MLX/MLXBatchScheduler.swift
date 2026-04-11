import Foundation
import MLX
import MLXLMCommon

// MARK: - MLXGenerationJob

final class MLXGenerationJob: @unchecked Sendable {
    let messages: [[String: String]]
    let maxTokens: Int
    let temperature: Float
    let priority: SlotPriority
    let continuation: CheckedContinuation<GenerationResult, Error>

    init(
        messages: [[String: String]],
        maxTokens: Int,
        temperature: Float,
        priority: SlotPriority,
        continuation: CheckedContinuation<GenerationResult, Error>
    ) {
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.priority = priority
        self.continuation = continuation
    }
}

// MARK: - AsyncSemaphore

final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int
    private var totalPermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        self.count = count
        self.totalPermits = count
    }

    func adjustPermits(to newTotal: Int) {
        lock.lock()
        let delta = newTotal - totalPermits
        totalPermits = newTotal
        if delta > 0 {
            var toWake = min(delta, waiters.count)
            var woken: [CheckedContinuation<Void, Never>] = []
            while toWake > 0 {
                woken.append(waiters.removeFirst())
                toWake -= 1
            }
            let remaining = delta - woken.count
            count += remaining
            lock.unlock()
            for w in woken { w.resume() }
        } else if delta < 0 {
            count += delta
            lock.unlock()
        } else {
            lock.unlock()
        }
    }

    var currentTotal: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalPermits
    }

    func wait() async {
        if tryAcquire() { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.parkOrResume(c)
        }
    }

    private nonisolated func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if count > 0 {
            count -= 1
            return true
        }
        return false
    }

    private nonisolated func parkOrResume(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if count > 0 {
            count -= 1
            lock.unlock()
            c.resume()
        } else {
            waiters.append(c)
            lock.unlock()
        }
    }

    func signal() {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume()
        } else {
            count += 1
            lock.unlock()
        }
    }
}

// MARK: - MLXBatchScheduler

final class MLXBatchScheduler: @unchecked Sendable {
    private let modelContainer: ModelContainer
    private var maxSlots: Int
    private let maxContext: Int?
    let semaphore: AsyncSemaphore

    private let lock = NSLock()
    private var slotStates: [SlotState]

    static let minimumSlots = 1
    static let maximumSlots = 8

    init(modelContainer: ModelContainer, slotCount: Int, maxContext: Int? = nil) {
        self.modelContainer = modelContainer
        self.maxSlots = slotCount
        self.maxContext = maxContext
        self.slotStates = Array(repeating: .idle, count: slotCount)
        self.semaphore = AsyncSemaphore(count: slotCount)
    }

    func submit(_ job: MLXGenerationJob) {
        Task {
            await self.runJob(job)
        }
    }

    var currentSlotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slotStates.count
    }

    var activeSlotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slotStates.filter { $0 != .idle }.count
    }

    func adjustSlots(to newCount: Int) {
        let clamped = max(Self.minimumSlots, min(Self.maximumSlots, newCount))

        lock.lock()
        let oldCount = slotStates.count
        guard clamped != oldCount else {
            lock.unlock()
            return
        }

        if clamped > oldCount {
            slotStates.append(contentsOf: Array(repeating: SlotState.idle, count: clamped - oldCount))
        } else {
            var removed = 0
            while slotStates.count > clamped && removed < (oldCount - clamped) {
                if let lastIdleIdx = slotStates.lastIndex(of: .idle) {
                    slotStates.remove(at: lastIdleIdx)
                    removed += 1
                } else {
                    break
                }
            }
        }
        let actualNew = slotStates.count
        maxSlots = actualNew
        lock.unlock()

        semaphore.adjustPermits(to: actualNew)
        print("[MLX] Slots adjusted: \(oldCount) -> \(actualNew)")
    }

    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)] {
        lock.lock()
        let states = slotStates
        lock.unlock()
        return states.enumerated().map { (i, state) in
            (index: i, state: state.rawValue, priority: "low", pos: 0)
        }
    }

    // MARK: - Job Execution

    private func runJob(_ job: MLXGenerationJob) async {
        await semaphore.wait()
        let slotIndex = acquireSlotIndex()

        do {
            setSlot(slotIndex, .promptEval)
            let userInput = UserInput(messages: job.messages)
            let lmInput = try await modelContainer.prepare(input: userInput)

            setSlot(slotIndex, .generating)
            let params = GenerateParameters(
                maxTokens: job.maxTokens,
                maxKVSize: maxContext,
                temperature: job.temperature
            )
            let stream = try await modelContainer.generate(
                input: lmInput,
                parameters: params
            )

            var text = ""
            var promptTokens = 0
            var completionTokens = 0

            for try await generation in stream {
                switch generation {
                case .chunk(let chunk):
                    text += chunk
                case .info(let info):
                    promptTokens = info.promptTokenCount
                    completionTokens = info.generationTokenCount
                case .toolCall:
                    break
                }
            }

            setSlot(slotIndex, .idle)
            semaphore.signal()
            Memory.clearCache()

            job.continuation.resume(returning: GenerationResult(
                text: text,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            ))
        } catch {
            setSlot(slotIndex, .idle)
            semaphore.signal()
            Memory.clearCache()
            job.continuation.resume(throwing: error)
        }
    }

    private func acquireSlotIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let idx = slotStates.firstIndex(of: .idle) {
            slotStates[idx] = .promptEval
            return idx
        }
        return 0
    }

    private nonisolated func setSlot(_ index: Int, _ state: SlotState) {
        lock.lock()
        if index < slotStates.count { slotStates[index] = state }
        lock.unlock()
    }
}
