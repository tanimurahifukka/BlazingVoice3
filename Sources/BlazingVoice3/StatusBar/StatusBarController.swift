import Cocoa

@MainActor
final class StatusBarController: StatusBarControlling {
    private var statusItem: NSStatusItem?
    private var pulseTimer: Timer?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateState(.idle)
    }

    func updateState(_ state: StatusBarVisualState) {
        pulseTimer?.invalidate()
        pulseTimer = nil

        guard let button = statusItem?.button else { return }
        button.alphaValue = 1.0
        button.contentTintColor = nil

        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "BlazingVoice3")
            button.image?.isTemplate = true
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.contentTintColor = .systemRed
            startPulse(button)
        case .processing:
            button.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Processing")
            button.contentTintColor = .systemBlue
            startPulse(button)
        case .done:
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
            button.contentTintColor = .systemGreen
        case .error:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
            button.contentTintColor = .systemOrange
        }
    }

    func setMenu(_ menu: NSMenu) {
        statusItem?.menu = menu
    }

    private func startPulse(_ button: NSStatusBarButton) {
        var on = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            button.alphaValue = on ? 1.0 : 0.4
            on.toggle()
        }
    }
}
