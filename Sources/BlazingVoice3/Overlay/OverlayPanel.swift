import Cocoa

@MainActor
final class OverlayPanel {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(message: String, duration: TimeInterval = 2.0) {
        hide()

        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 10, y: 12, width: 300, height: 40)
        panel.contentView?.addSubview(label)

        let x = (screen.frame.width - 320) / 2
        let y = screen.frame.height * 0.25
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFront(nil)
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.hide() }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.close()
        panel = nil
    }
}
