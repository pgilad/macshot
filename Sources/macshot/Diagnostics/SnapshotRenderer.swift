#if DEBUG
import Cocoa

/// `macshot --render-snapshots <dir>` (`make snapshots`) opens the editor with a sample
/// capture and annotations made through mouse events, and writes the window to PNG files
/// in light and dark mode. `make readme-images` copies them to docs/images for the README.
/// It never captures the screen.
enum SnapshotRenderer {
    static func render(to directory: URL) async -> Bool {
        await Diagnostics.isolated("snapshots") { _ in await renderEditor(to: directory) } ?? false
    }

    private static func renderEditor(to directory: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DetachedEditorWindowController.open(image: sampleCapture(), tool: .arrow, color: .systemRed, strokeWidth: 5)
        await DiagnosticInput.settle()
        guard let window = NSApp.windows.first(where: { $0.isVisible && DiagnosticInput.editorView(in: $0) != nil }),
              let editor = DiagnosticInput.editorView(in: window) else {
            print("FAIL the editor did not open")
            return false
        }
        annotate(editor, in: window)

        var ok = true
        for (name, appearance) in [("editor-light.png", NSAppearance.Name.aqua), ("editor-dark.png", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            ok = await save(window, to: directory.appending(path: name)) && ok
        }
        window.close()
        return ok
    }

    /// The annotations that the README shows, drawn the way a user draws them.
    private static func annotate(_ editor: OverlayView, in window: NSWindow) {
        let area = editor.selectionRect
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: area.minX + area.width * x, y: area.minY + area.height * y)
        }
        // The redaction keeps the default censor mode (solid), in black.
        editor.currentColor = .black
        editor.handleToolbarAction(.tool(.pixelate))
        DiagnosticInput.drag(in: editor, from: point(0.015, 0.655), to: point(0.195, 0.715))
        editor.currentColor = .systemRed
        editor.handleToolbarAction(.tool(.rectangle))
        DiagnosticInput.drag(in: editor, from: point(0.225, 0.785), to: point(0.57, 0.895))
        editor.handleToolbarAction(.tool(.number))
        // A click on an annotation's border selects it, so the badges stay clear of them.
        DiagnosticInput.click(in: editor, at: point(0.195, 0.84))
        DiagnosticInput.click(in: editor, at: point(0.65, 0.685))
        editor.handleToolbarAction(.tool(.text))
        DiagnosticInput.click(in: editor, at: point(0.68, 0.70))
        if let textView = editor.textEditor.textView {
            window.makeFirstResponder(textView)
            textView.insertText("Up 24%", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        editor.handleToolbarAction(.tool(.arrow))
        DiagnosticInput.drag(in: editor, from: point(0.77, 0.68), to: point(0.855, 0.575))
        editor.selectedAnnotations = []
        editor.needsDisplay = true
    }

    private static func save(_ window: NSWindow, to url: URL) async -> Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        window.display()
        await DiagnosticInput.settle()
        // The frame view includes the title bar.
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            print("FAIL \(url.lastPathComponent)")
            return false
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else {
            print("FAIL \(url.lastPathComponent)")
            return false
        }
        print("Wrote \(url.path)")
        return true
    }

    /// A made-up app window: a sidebar, a heading, text lines and a bar chart.
    private static func sampleCapture() -> NSImage {
        let size = NSSize(width: 1000, height: 620)
        let width = Int(size.width), height = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: size)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let gray = NSColor(srgbRed: 0.55, green: 0.57, blue: 0.62, alpha: 1)
        let light = NSColor(srgbRed: 0.88, green: 0.89, blue: 0.92, alpha: 1)
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Title bar with window buttons.
        NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: size.height - 44, width: size.width, height: 44).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 18 + CGFloat(index) * 22, y: size.height - 29, width: 13, height: 13)).fill()
        }

        // Sidebar.
        NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 200, height: size.height - 44).fill()
        let rowFont = NSFont.systemFont(ofSize: 15, weight: .medium)
        for (index, title) in ["Overview", "Revenue", "Customers", "contact@example.com", "Settings"].enumerated() {
            (title as NSString).draw(at: NSPoint(x: 24, y: size.height - 92 - CGFloat(index) * 38),
                                     withAttributes: [.font: rowFont, .foregroundColor: index == 1 ? NSColor.systemBlue : gray])
        }

        // Heading and text lines.
        ("Quarterly revenue" as NSString).draw(at: NSPoint(x: 240, y: size.height - 110), withAttributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor(white: 0.12, alpha: 1),
        ])
        light.setFill()
        for (index, fraction) in [0.62, 0.48, 0.55].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 240, y: size.height - 150 - CGFloat(index) * 24,
                                             width: (size.width - 280) * fraction, height: 10),
                         xRadius: 5, yRadius: 5).fill()
        }

        // Bar chart.
        let values: [CGFloat] = [0.35, 0.48, 0.42, 0.58, 0.66, 0.9]
        for (index, value) in values.enumerated() {
            (index == values.count - 1 ? NSColor.systemBlue : NSColor.systemBlue.withAlphaComponent(0.45)).setFill()
            NSBezierPath(roundedRect: NSRect(x: 260 + CGFloat(index) * 115, y: 60, width: 70, height: 300 * value),
                         xRadius: 6, yRadius: 6).fill()
        }

        guard let pixels = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: pixels, size: size)
    }
}
#endif
