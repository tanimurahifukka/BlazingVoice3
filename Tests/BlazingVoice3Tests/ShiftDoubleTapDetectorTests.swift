import XCTest
@testable import BlazingVoice3

final class ShiftDoubleTapDetectorTests: XCTestCase {
    func testDetectsDoubleTapWithinInterval() {
        var detector = ShiftDoubleTapDetector(interval: 0.4)

        XCTAssertFalse(detector.register(keyCode: 56, shiftDown: true, now: 1.0))
        XCTAssertFalse(detector.register(keyCode: 56, shiftDown: false, now: 1.05))
        XCTAssertTrue(detector.register(keyCode: 56, shiftDown: true, now: 1.2))
    }

    func testIgnoresSlowDoubleTap() {
        var detector = ShiftDoubleTapDetector(interval: 0.4)

        XCTAssertFalse(detector.register(keyCode: 56, shiftDown: true, now: 1.0))
        XCTAssertFalse(detector.register(keyCode: 56, shiftDown: false, now: 1.05))
        XCTAssertFalse(detector.register(keyCode: 56, shiftDown: true, now: 1.5))
    }

    func testIgnoresRightShiftAndHeldKeyRepeats() {
        var detector = ShiftDoubleTapDetector(interval: 0.4)

        XCTAssertFalse(detector.register(keyCode: 60, shiftDown: true, now: 1.0))
        XCTAssertFalse(detector.register(keyCode: 56, shiftDown: true, now: 2.0))
        XCTAssertFalse(detector.register(keyCode: 56, shiftDown: true, now: 2.1))
        XCTAssertFalse(detector.register(keyCode: 56, shiftDown: false, now: 2.2))
        XCTAssertTrue(detector.register(keyCode: 56, shiftDown: true, now: 2.3))
    }
}
