import XCTest
@testable import BlazingVoice3

final class CLITestModeTests: XCTestCase {
    func testPrefersUISmokeMode() {
        let mode = CLITest.mode(arguments: ["BlazingVoice3", "--ui-smoke", "--startup-smoke"])
        XCTAssertEqual(mode, .uiSmoke)
    }

    func testPrefersStartupSmokeMode() {
        let mode = CLITest.mode(arguments: ["BlazingVoice3", "--startup-smoke"])
        XCTAssertEqual(mode, .startupSmoke)
    }

    func testParsesFullPipelineModeWithoutAudioFile() {
        let mode = CLITest.mode(arguments: ["BlazingVoice3", "--test"])
        XCTAssertEqual(mode, .fullPipeline(audioPath: nil))
    }

    func testParsesFullPipelineModeWithAudioFile() {
        let mode = CLITest.mode(arguments: ["BlazingVoice3", "--test", "/tmp/sample.wav"])
        XCTAssertEqual(mode, .fullPipeline(audioPath: "/tmp/sample.wav"))
    }
}
