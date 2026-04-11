import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Tracks system memory usage at 1-second intervals and triggers
/// threshold-based callbacks for dynamic slot management.
final class MemoryMonitor: @unchecked Sendable {
    struct MemoryInfo: Sendable {
        let totalPhysical: UInt64
        let rssBytes: UInt64
        let freeEstimate: UInt64
        let activeSlots: Int

        var totalGB: Double { Double(totalPhysical) / 1_073_741_824 }
        var rssGB: Double { Double(rssBytes) / 1_073_741_824 }
        var freeGB: Double { Double(freeEstimate) / 1_073_741_824 }
    }

    enum MemoryPressure: String, Sendable {
        case normal
        case low
        case critical
        case emergency
    }

    var onPressureChange: (@Sendable (MemoryPressure, MemoryInfo) -> Void)?

    private let lock = NSLock()
    private var _latestInfo: MemoryInfo
    private var _currentPressure: MemoryPressure = .normal
    private var monitorTask: Task<Void, Never>?

    var latestInfo: MemoryInfo {
        lock.lock()
        defer { lock.unlock() }
        return _latestInfo
    }

    var currentPressure: MemoryPressure {
        lock.lock()
        defer { lock.unlock() }
        return _currentPressure
    }

    private let activeSlotsFn: @Sendable () -> Int

    init(activeSlots: @escaping @Sendable () -> Int) {
        self.activeSlotsFn = activeSlots
        let total = ProcessInfo.processInfo.physicalMemory
        let rss = Self.currentRSS()
        let free = total > rss ? total - rss : 0
        self._latestInfo = MemoryInfo(
            totalPhysical: total,
            rssBytes: rss,
            freeEstimate: free,
            activeSlots: activeSlots()
        )
    }

    func start() {
        stop()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func tick() {
        let total = ProcessInfo.processInfo.physicalMemory
        let rss = Self.currentRSS()
        let free = total > rss ? total - rss : 0
        let slots = activeSlotsFn()

        let info = MemoryInfo(
            totalPhysical: total,
            rssBytes: rss,
            freeEstimate: free,
            activeSlots: slots
        )

        let pressure = Self.classifyPressure(freeBytes: free)

        let previousPressure: MemoryPressure
        lock.lock()
        previousPressure = _currentPressure
        _latestInfo = info
        _currentPressure = pressure
        lock.unlock()

        if pressure != previousPressure {
            print("[Memory] Pressure: \(previousPressure.rawValue) -> \(pressure.rawValue) " +
                  "(free: \(String(format: "%.1f", info.freeGB))GB, RSS: \(String(format: "%.1f", info.rssGB))GB)")
            onPressureChange?(pressure, info)
        }
    }

    private static func classifyPressure(freeBytes: UInt64) -> MemoryPressure {
        let freeGB = Double(freeBytes) / 1_073_741_824
        if freeGB < 1.0 { return .emergency }
        if freeGB < 2.0 { return .critical }
        if freeGB < 4.0 { return .low }
        return .normal
    }

    static func currentRSS() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), ptr, &count)
            }
        }
        if result == KERN_SUCCESS {
            return UInt64(info.resident_size)
        }
        #endif
        return ProcessInfo.processInfo.physicalMemory / 2
    }
}
