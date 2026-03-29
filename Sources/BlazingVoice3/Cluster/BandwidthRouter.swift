import Foundation

struct BandwidthSnapshot: Sendable {
    let nodeId: String
    let isLocal: Bool
    let ewmaTokPerSec: Double
    let activeRequests: Int
    let totalRequests: Int
    let totalTokens: Int
}

final class NodeBandwidthTracker: @unchecked Sendable {
    let nodeId: String
    let isLocal: Bool
    private(set) var ewmaTokPerSec: Double
    private(set) var activeRequests: Int = 0
    private(set) var totalRequests: Int = 0
    private(set) var totalTokens: Int = 0
    private(set) var consecutiveFailures: Int = 0
    private let alpha: Double = 0.3
    private let lock = NSLock()

    init(nodeId: String, isLocal: Bool, initialBandwidth: Double) {
        self.nodeId = nodeId
        self.isLocal = isLocal
        self.ewmaTokPerSec = initialBandwidth
    }

    func requestStarted() {
        lock.lock()
        activeRequests += 1
        totalRequests += 1
        lock.unlock()
    }

    func requestCompleted(tokens: Int, durationSec: Double) {
        lock.lock()
        activeRequests = max(0, activeRequests - 1)
        totalTokens += tokens
        consecutiveFailures = 0
        if durationSec > 0 && tokens > 0 {
            let measured = Double(tokens) / durationSec
            ewmaTokPerSec = alpha * measured + (1 - alpha) * ewmaTokPerSec
        }
        lock.unlock()
    }

    func requestFailed() {
        lock.lock()
        activeRequests = max(0, activeRequests - 1)
        consecutiveFailures += 1
        ewmaTokPerSec *= 0.5
        lock.unlock()
    }

    func snapshot() -> BandwidthSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return BandwidthSnapshot(
            nodeId: nodeId,
            isLocal: isLocal,
            ewmaTokPerSec: ewmaTokPerSec,
            activeRequests: activeRequests,
            totalRequests: totalRequests,
            totalTokens: totalTokens
        )
    }
}

/// Bandwidth-first routing (Uzu) for BlazingVoice3 cluster.
final class BandwidthRouter: @unchecked Sendable {
    private var trackers: [String: NodeBandwidthTracker] = [:]
    private let spilloverThreshold: Double
    private let localSlots: Int
    private let lock = NSLock()

    init(spilloverThreshold: Double = 0.8, localSlots: Int = 4) {
        self.spilloverThreshold = spilloverThreshold
        self.localSlots = localSlots
    }

    func registerNode(id: String, isLocal: Bool, initialBandwidth: Double) {
        lock.lock()
        if trackers[id] == nil {
            trackers[id] = NodeBandwidthTracker(
                nodeId: id, isLocal: isLocal, initialBandwidth: initialBandwidth
            )
            print("[Uzu] Registered node \(id) (local=\(isLocal), initial=\(initialBandwidth) tok/s)")
        }
        lock.unlock()
    }

    func removeNode(id: String) {
        lock.lock()
        trackers.removeValue(forKey: id)
        lock.unlock()
    }

    func selectNode(excluding: Set<String> = []) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let available = trackers.values.filter { !excluding.contains($0.nodeId) }
        guard !available.isEmpty else {
            return trackers.values.first(where: { $0.isLocal })?.nodeId
        }

        let best = available
            .filter { $0.consecutiveFailures < 5 }
            .max { a, b in
                let aEff = a.ewmaTokPerSec / Double(1 + a.activeRequests)
                let bEff = b.ewmaTokPerSec / Double(1 + b.activeRequests)
                return aEff < bEff
            }

        return best?.nodeId ?? trackers.values.first(where: { $0.isLocal })?.nodeId
    }

    func recordStart(nodeId: String) {
        lock.lock()
        let tracker = trackers[nodeId]
        lock.unlock()
        tracker?.requestStarted()
    }

    func recordCompletion(nodeId: String, tokens: Int, durationSec: Double) {
        lock.lock()
        let tracker = trackers[nodeId]
        lock.unlock()
        tracker?.requestCompleted(tokens: tokens, durationSec: durationSec)
    }

    func recordFailure(nodeId: String) {
        lock.lock()
        let tracker = trackers[nodeId]
        lock.unlock()
        tracker?.requestFailed()
    }

    func allSnapshots() -> [BandwidthSnapshot] {
        lock.lock()
        let all = trackers.values.map { $0.snapshot() }
        lock.unlock()
        return all.sorted { $0.nodeId < $1.nodeId }
    }
}
