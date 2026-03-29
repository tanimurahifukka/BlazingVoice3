import Cocoa

/// Injects text at cursor position via a serialized clipboard + paste flow.
enum TextInjector {
    private static let coordinator = Coordinator()

    static func paste(_ text: String) async {
        await coordinator.paste(text)
    }

    static func setTestPasteHandler(_ handler: (@Sendable (String) async -> Void)?) async {
        await coordinator.setTestPasteHandler(handler)
    }

    private actor Coordinator {
        private var testPasteHandler: (@Sendable (String) async -> Void)?

        func setTestPasteHandler(_ handler: (@Sendable (String) async -> Void)?) {
            testPasteHandler = handler
        }

        func paste(_ text: String) async {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let testPasteHandler {
                await testPasteHandler(text)
                return
            }

            let snapshot = await MainActor.run { TextInjector.capturePasteboard() }
            let clipboardWritten = await MainActor.run { TextInjector.writePasteboard(text) }
            guard clipboardWritten else { return }

            try? await Task.sleep(for: .milliseconds(40))

            let pasted = TextInjector.pasteViaCGEvent() || TextInjector.pasteViaAppleScript()
            NSLog("[TextInjector] Paste %@ (%d chars)", pasted ? "succeeded" : "failed", text.count)

            if pasted {
                try? await Task.sleep(for: .milliseconds(150))
            }

            await MainActor.run { TextInjector.restorePasteboard(snapshot) }
        }
    }

    private struct PasteboardSnapshot: Sendable {
        struct Item: Sendable {
            struct Entry: Sendable {
                let type: String
                let data: Data
            }

            let entries: [Entry]
        }

        let items: [Item]
    }

    @MainActor
    private static func capturePasteboard() -> PasteboardSnapshot {
        let items: [PasteboardSnapshot.Item] = NSPasteboard.general.pasteboardItems?.map { item in
            let entries = item.types.compactMap { type -> PasteboardSnapshot.Item.Entry? in
                guard let data = item.data(forType: type) else { return nil }
                return PasteboardSnapshot.Item.Entry(type: type.rawValue, data: data)
            }
            return PasteboardSnapshot.Item(entries: entries)
        } ?? []

        return PasteboardSnapshot(items: items)
    }

    @MainActor
    private static func writePasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        let wrote = NSPasteboard.general.setString(text, forType: .string)
        let verified = NSPasteboard.general.string(forType: .string) == text
        NSLog("[TextInjector] Clipboard set: %d chars", text.count)
        return wrote && verified
    }

    @MainActor
    private static func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        NSPasteboard.general.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let restoredItems = snapshot.items.map { item -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for entry in item.entries {
                pasteboardItem.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return pasteboardItem
        }
        _ = NSPasteboard.general.writeObjects(restoredItems)
    }

    private static func pasteViaCGEvent() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        usleep(20_000)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }

    private static func pasteViaAppleScript() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"]
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("[TextInjector] osascript failed: %@", "\(error)")
            return false
        }
    }
}
