import Foundation

struct ShiftDoubleTapDetector {
    private let interval: TimeInterval
    private var lastShiftTapTime: TimeInterval = 0
    private var shiftWasDown = false

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func register(keyCode: Int, shiftDown: Bool, now: TimeInterval) -> Bool {
        guard keyCode == 56 else { return false }

        defer {
            shiftWasDown = shiftDown
        }

        guard shiftDown, !shiftWasDown else { return false }

        if (now - lastShiftTapTime) < interval {
            lastShiftTapTime = 0
            return true
        }

        lastShiftTapTime = now
        return false
    }
}
