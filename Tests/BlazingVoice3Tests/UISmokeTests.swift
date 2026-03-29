import Foundation
import XCTest

final class UISmokeTests: XCTestCase {
    func testExecutableLaunchesInUISmokeMode() throws {
        let executableURL = try resolveExecutableURL()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--ui-smoke"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("=== UI Smoke PASSED ==="), output)
    }

    private func resolveExecutableURL() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let candidates = [
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/BlazingVoice3"),
            packageRoot.appendingPathComponent(".build/debug/BlazingVoice3"),
        ]

        if let executableURL = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return executableURL
        }

        throw XCTSkip("BlazingVoice3 executable was not found in .build")
    }
}
