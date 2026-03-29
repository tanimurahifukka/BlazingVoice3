import Cocoa

@MainActor
final class StatusBarMenu {
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Version + Engine
        let titleItem = NSMenuItem(title: "BlazingVoice3 v\(AppVersion.full)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let engineLabel: String
        if let desc = appDelegate?.engineDescription, desc != "Not loaded" {
            engineLabel = "Engine: \(desc)"
        } else if appDelegate?.pipelineState == .loading {
            engineLabel = "Engine: 読込中..."
        } else {
            engineLabel = "Engine: 未ロード"
        }
        let engineItem = NSMenuItem(title: engineLabel, action: nil, keyEquivalent: "")
        engineItem.isEnabled = false
        menu.addItem(engineItem)

        menu.addItem(NSMenuItem.separator())

        // Recording button
        let state = appDelegate?.pipelineState ?? .idle
        switch state {
        case .recording:
            let stopItem = NSMenuItem(
                title: "⏹ 停止",
                action: #selector(AppDelegate.menuStopRecording),
                keyEquivalent: ""
            )
            stopItem.target = appDelegate
            menu.addItem(stopItem)
        case .processing:
            let procItem = NSMenuItem(title: "⏳ 処理中...", action: nil, keyEquivalent: "")
            procItem.isEnabled = false
            menu.addItem(procItem)
        default:
            let startItem = NSMenuItem(
                title: "🎙 録音開始 (左Shift×2)",
                action: #selector(AppDelegate.menuStartRecording),
                keyEquivalent: ""
            )
            startItem.target = appDelegate
            menu.addItem(startItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Mode selection (normal first)
        let currentMode = appDelegate?.currentMode ?? .normal
        for mode in VoiceMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(AppDelegate.menuSelectMode(_:)),
                keyEquivalent: ""
            )
            item.target = appDelegate
            item.tag = VoiceMode.allCases.firstIndex(of: mode) ?? 0
            item.state = (mode == currentMode) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // History
        if let history = appDelegate?.sessionHistory, !history.sessions.isEmpty {
            let historyItem = NSMenuItem(title: "履歴 (\(history.sessions.count))", action: nil, keyEquivalent: "")
            historyItem.isEnabled = false
            menu.addItem(historyItem)

            for session in history.sessions.prefix(3) {
                let text = String(session.generatedText.prefix(35))
                let item = NSMenuItem(title: "  \(text)...", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            menu.addItem(NSMenuItem.separator())
        }

        // Settings
        let settingsItem = NSMenuItem(title: "設定...", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        settingsItem.target = appDelegate
        menu.addItem(settingsItem)

        // Quit
        let quitItem = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }
}
