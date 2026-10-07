import AppKit

/// Renders plain clipboard text to an image, so it can be pinned like a screenshot.
enum ClipboardTextPinRenderer {

    private static let padding = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
    private static let plainFont = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
    private static let maxPointArea: CGFloat = 24_000_000

    /// A pin is a screenshot of some text, not a document viewer. Laying out a
    /// copied log file or JSON blob costs Text Kit a pass over every glyph on
    /// the main thread, which beachballs the app (and the global hotkeys with
    /// it). Far more than fits on screen is pointless anyway.
    static let maxCharacters = 20_000

    /// Truncates text that is too long to lay out, marking the cut so the pin
    /// doesn't look like the content simply ended.
    static func truncatedForPinning(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n…"
    }

    static func plainAttributedString(_ string: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left

        return NSAttributedString(
            string: truncatedForPinning(string),
            attributes: [
                .font: plainFont,
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ]
        )
    }

    /// Draws the text as dark text on white, wrapped to a width that fits the screen.
    static func render(_ attributed: NSAttributedString) -> NSImage? {
        guard attributed.length > 0 else { return nil }

        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxContentWidth = max(320, min(980, screenFrame.width * 0.72))
        let maxImageHeight = max(240, screenFrame.height * 0.82)

        let contentSize = measuredSize(for: attributed, maxWidth: maxContentWidth)
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0 else { return nil }

        var imageWidth = ceil(contentSize.width + padding.left + padding.right)
        var imageHeight = ceil(contentSize.height + padding.top + padding.bottom)

        if imageHeight > maxImageHeight {
            imageHeight = maxImageHeight
        }

        if imageWidth * imageHeight > maxPointArea {
            let scale = sqrt(maxPointArea / (imageWidth * imageHeight))
            imageWidth = max(320, floor(imageWidth * scale))
            imageHeight = max(180, floor(imageHeight * scale))
        }

        let imageSize = NSSize(width: imageWidth, height: imageHeight)
        let drawRect = NSRect(
            x: padding.left,
            y: padding.top,
            width: max(1, imageWidth - padding.left - padding.right),
            height: max(1, imageHeight - padding.top - padding.bottom)
        )

        return NSImage(size: imageSize, flipped: true) { rect in
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()

            attributed.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            return true
        }
    }

    private static func measuredSize(for attributed: NSAttributedString, maxWidth: CGFloat) -> NSSize {
        let rect = attributed.boundingRect(
            with: NSSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}
