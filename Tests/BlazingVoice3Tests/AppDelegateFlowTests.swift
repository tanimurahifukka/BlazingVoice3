import AppKit
import XCTest
@testable import BlazingVoice3

@MainActor
final class AppDelegateFlowTests: XCTestCase {
    private enum TestError: Error {
        case timedOut
    }

    private struct Harness {
        let appDelegate: AppDelegate
        let permissions: TestPermissionManager
        let audioRecorder: TestAudioRecorder
        let statusBar: TestStatusBarController
        let overlay: TestOverlayPresenter
        let hotkeys: TestHotkeyManager
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testMenuFlowStartsAndStopsDictation() async throws {
        let previousClipboard = NSPasteboard.general.string(forType: .string)
        defer { restoreClipboard(previousClipboard) }

        let harness = makeHarness()
        harness.appDelegate.bootstrapForTesting()
        harness.appDelegate.currentMode = .dictation

        XCTAssertTrue(menuTitles(harness.statusBar.latestMenu).contains("🎙 録音開始 (左Shift×2)"))

        harness.appDelegate.menuStartRecording()
        try await waitUntil { harness.appDelegate.pipelineState == .recording }

        XCTAssertEqual(harness.audioRecorder.startCount, 1)
        XCTAssertEqual(harness.statusBar.latestState, .recording)
        XCTAssertTrue(menuTitles(harness.statusBar.latestMenu).contains("⏹ 停止"))

        harness.audioRecorder.stopResult = .success("メニュー録音確認")
        harness.appDelegate.menuStopRecording()

        try await waitUntil { self.isDone(harness.appDelegate.pipelineState) }

        XCTAssertEqual(harness.audioRecorder.stopCount, 1)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "メニュー録音確認")
        XCTAssertTrue(harness.overlay.messages.contains(where: { $0.contains("Cmd+V") }))
    }

    func testRealtimeModeRequestsAccessibilityBeforeStarting() async throws {
        let harness = makeHarness(accessibilityGranted: false)
        harness.appDelegate.bootstrapForTesting()
        harness.appDelegate.currentMode = .normal

        harness.appDelegate.menuStartRecording()
        try await waitUntil { harness.permissions.requestAccessibilityCount == 1 }

        XCTAssertEqual(harness.audioRecorder.startCount, 0)
        XCTAssertEqual(harness.appDelegate.pipelineState, .idle)
        XCTAssertTrue(harness.overlay.messages.contains("アクセシビリティを許可してください"))
    }

    func testHotkeyDrivenRealtimeFlowPastesFinalText() async throws {
        let previousClipboard = NSPasteboard.general.string(forType: .string)
        defer { restoreClipboard(previousClipboard) }

        let collector = PasteCollector()
        await TextInjector.setTestPasteHandler { text in
            await collector.append(text)
        }

        let harness = makeHarness()
        harness.appDelegate.bootstrapForTesting()
        harness.appDelegate.currentMode = .normal

        harness.hotkeys.simulateDoubleTap()
        try await waitUntil { harness.appDelegate.pipelineState == .recording }

        harness.audioRecorder.stopResult = .success("こんにちは")
        harness.hotkeys.simulateDoubleTap()
        try await waitUntil { self.isDone(harness.appDelegate.pipelineState) }

        XCTAssertEqual(harness.audioRecorder.startCount, 1)
        XCTAssertEqual(harness.audioRecorder.stopCount, 1)
        let pastedTexts = await collector.snapshot()
        XCTAssertEqual(pastedTexts, ["こんにちは"])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "こんにちは")
        await TextInjector.setTestPasteHandler(nil)
    }

    private func makeHarness(accessibilityGranted: Bool = true) -> Harness {
        let permissions = TestPermissionManager(
            micGranted: true,
            speechGranted: true,
            accessibilityGranted: accessibilityGranted
        )
        let audioRecorder = TestAudioRecorder()
        let statusBar = TestStatusBarController()
        let overlay = TestOverlayPresenter()
        let hotkeys = TestHotkeyManager()
        let appDelegate = AppDelegate(
            settings: AppSettings(),
            modelManager: ModelManager(),
            sessionHistory: SessionHistory(),
            evolutionLog: EvolutionLog(),
            permissions: permissions,
            audioRecorder: audioRecorder,
            statusBarControllerFactory: { statusBar },
            overlayFactory: { overlay },
            hotkeyManagerFactory: { hotkeys },
            launchOptions: .uiSmoke
        )

        return Harness(
            appDelegate: appDelegate,
            permissions: permissions,
            audioRecorder: audioRecorder,
            statusBar: statusBar,
            overlay: overlay,
            hotkeys: hotkeys
        )
    }

    private func waitUntil(
        timeoutSeconds: Double = 2.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for expected AppDelegate state")
        throw TestError.timedOut
    }

    private func isDone(_ state: AppDelegate.PipelineState) -> Bool {
        if case .done = state {
            return true
        }
        return false
    }

    private func menuTitles(_ menu: NSMenu?) -> [String] {
        menu?.items.map(\.title) ?? []
    }

    private func restoreClipboard(_ previousValue: String?) {
        NSPasteboard.general.clearContents()
        if let previousValue {
            NSPasteboard.general.setString(previousValue, forType: .string)
        }
    }
}
