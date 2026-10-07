import Cocoa

/// A toast at the top center of the screen that reports a failure the user
/// cannot otherwise see, such as a capture that could not be saved.
class ErrorToastController {

    private var window: NSPanel?
    private var dismissTask: DispatchWorkItem?
    var onDismiss: (() -> Void)?

    private let toastWidth: CGFloat = 380
    private let cornerRadius: CGFloat = 14

    func show(message: String) {
        guard let screen = NSScreen.preferred else { return }
        let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let maxLabelWidth = toastWidth - 66  // 50 left pad + 16 right pad
        let textSize = (message as NSString).boundingRect(
            with: NSSize(width: maxLabelWidth, height: 200),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: labelFont]
        ).size
        let toastHeight = max(56, ceil(textSize.height) + 28)
        let topPadding: CGFloat = 12

        // Top-center, just below the menu bar
        let x = screen.frame.midX - toastWidth / 2
        let startY = screen.visibleFrame.maxY + 10
        let finalY = screen.visibleFrame.maxY - toastHeight - topPadding

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: startY, width: toastWidth, height: toastHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let contentView = ToastBackgroundView(frame: NSRect(origin: .zero, size: NSSize(width: toastWidth, height: toastHeight)))
        contentView.cornerRadius = cornerRadius
        contentView.onClicked = { [weak self] in self?.animateOut() }
        panel.contentView = contentView

        let icon = NSImageView(frame: NSRect(x: 14, y: (toastHeight - 28) / 2, width: 28, height: 28))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(icon)

        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = NSRect(
            x: 50, y: (toastHeight - ceil(textSize.height)) / 2,
            width: maxLabelWidth, height: ceil(textSize.height) + 2)
        label.font = labelFont
        label.textColor = .systemRed
        label.isSelectable = false
        contentView.addSubview(label)

        window = panel
        panel.orderFrontRegardless()

        // Animate in from top
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(x: x, y: finalY, width: toastWidth, height: toastHeight),
                display: true
            )
        }

        scheduleDismiss(seconds: 6)
    }

    private func scheduleDismiss(seconds: Double) {
        dismissTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.animateOut()
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        onDismiss?()
        onDismiss = nil
    }

    private func animateOut() {
        guard let window = window else { return }
        let frame = window.frame
        guard let screen = NSScreen.preferred else { dismiss(); return }
        let offscreenY = screen.visibleFrame.maxY + 10

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(
                NSRect(x: frame.minX, y: offscreenY, width: frame.width, height: frame.height),
                display: true
            )
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }
}

// MARK: - Background view (mimics macOS notification appearance)

private class ToastBackgroundView: NSView {

    var cornerRadius: CGFloat = 14
    var onClicked: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClicked?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)

        // Use the system visual effect material colors for a native feel
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(white: 0.18, alpha: 0.92).setFill()
        } else {
            NSColor(white: 0.98, alpha: 0.95).setFill()
        }
        path.fill()

        // Subtle border
        NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 0.5
        border.stroke()
    }
}
