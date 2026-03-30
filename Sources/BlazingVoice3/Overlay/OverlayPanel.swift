import Cocoa

@MainActor
final class OverlayPanel {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var messageLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var detailLabel: NSTextField?

    func show(message: String, duration: TimeInterval = 2.0) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if let existingPanel = panel, let label = messageLabel {
            // Reuse existing panel — just update text
            label.stringValue = message
            progressBar?.isHidden = true
            detailLabel?.isHidden = true
            existingPanel.orderFront(nil)
            scheduleHide(after: duration)
            return
        }

        hide()
        createPanel(message: message, showProgress: false)
        scheduleHide(after: duration)
    }

    func showProgress(message: String, detail: String = "", progress: Double = -1) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if let existingPanel = panel, let label = messageLabel {
            // Update existing panel in place
            label.stringValue = message

            if let bar = progressBar {
                bar.isHidden = false
                if progress < 0 {
                    bar.isIndeterminate = true
                    bar.startAnimation(nil)
                } else {
                    bar.isIndeterminate = false
                    bar.stopAnimation(nil)
                    bar.doubleValue = progress * 100
                }
            }

            if let dl = detailLabel {
                dl.isHidden = detail.isEmpty
                dl.stringValue = detail
            }

            existingPanel.orderFront(nil)
            return
        }

        hide()
        createPanel(message: message, showProgress: true, detail: detail, progress: progress)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.close()
        panel = nil
        messageLabel = nil
        progressBar = nil
        detailLabel = nil
    }

    // MARK: - Private

    private func createPanel(message: String, showProgress: Bool, detail: String = "", progress: Double = -1) {
        guard let screen = NSScreen.main else { return }

        let panelHeight: CGFloat = showProgress ? 100 : 64

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: panelHeight),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let contentView = panel.contentView!

        // Message label
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        if showProgress {
            label.frame = NSRect(x: 16, y: panelHeight - 32, width: 328, height: 20)
        } else {
            label.frame = NSRect(x: 10, y: 12, width: 340, height: 40)
        }
        contentView.addSubview(label)
        messageLabel = label

        if showProgress {
            // Progress bar
            let bar = NSProgressIndicator(frame: NSRect(x: 24, y: panelHeight - 58, width: 312, height: 14))
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 100
            if progress < 0 {
                bar.isIndeterminate = true
                bar.startAnimation(nil)
            } else {
                bar.isIndeterminate = false
                bar.doubleValue = progress * 100
            }
            contentView.addSubview(bar)
            progressBar = bar

            // Detail label (e.g. "1.2 GB / 2.7 GB")
            let dl = NSTextField(labelWithString: detail)
            dl.font = .systemFont(ofSize: 11, weight: .regular)
            dl.textColor = NSColor.white.withAlphaComponent(0.7)
            dl.alignment = .center
            dl.frame = NSRect(x: 16, y: 8, width: 328, height: 16)
            dl.isHidden = detail.isEmpty
            contentView.addSubview(dl)
            detailLabel = dl
        }

        let x = (screen.frame.width - 360) / 2
        let y = screen.frame.height * 0.25
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFront(nil)
        self.panel = panel
    }

    private func scheduleHide(after duration: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.hide() }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

extension OverlayPanel: OverlayPresenting {}
