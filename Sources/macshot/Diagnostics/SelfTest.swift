#if DEBUG
import Cocoa

/// Development checks that need the window server, which the unit tests do not use.
///
/// `macshot --self-test` (`make self-test`) opens the editor in a real window, draws with
/// each tool through mouse events, edits text and then undoes through the window's undo
/// manager, saves a file, writes and reopens a history entry, and opens every Settings tab
/// and the About panel. It never captures the screen, so it needs no Screen Recording
/// permission. It uses a temporary data folder, and it puts the UserDefaults domain of the
/// debug binary back as it was.
///
/// Release builds do not contain this code.
enum Diagnostics {
    /// Returns true when a diagnostic started. It calls `exit` when it ends.
    static func startIfRequested(_ arguments: [String]) -> Bool {
        if arguments.contains("--self-test") {
            Task { exit(await SelfTest().run() ? 0 : 1) }
            return true
        }
        return false
    }

    /// A folder that the caller deletes.
    static func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "macshot-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Four solid quadrants, drawn through CGContext so the pixels do not depend on the
    /// screen scale.
    static func fixtureImage(width: Int, height: Int) -> NSImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        let quadrants: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: 0, width: w, height: h), CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1)),
            (CGRect(x: w, y: 0, width: w, height: h), CGColor(srgbRed: 0.2, green: 0.8, blue: 0.3, alpha: 1)),
            (CGRect(x: 0, y: h, width: w, height: h), CGColor(srgbRed: 0.2, green: 0.3, blue: 0.9, alpha: 1)),
            (CGRect(x: w, y: h, width: w, height: h), CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)),
        ]
        for (rect, color) in quadrants {
            context.setFillColor(color)
            context.fill(rect)
        }
        guard let pixels = context.makeImage() else { return NSImage(size: NSSize(width: width, height: height)) }
        return NSImage(cgImage: pixels, size: NSSize(width: width, height: height))
    }
}

final class SelfTest {
    private var passes = 0
    private var failures = 0

    func run() async -> Bool {
        // Inside the app bundle, the UserDefaults domain is the real app's.
        guard Bundle.main.bundleIdentifier == nil else {
            print("FAIL run the self-test from the debug binary (make self-test), not from an app bundle")
            return false
        }
        let directory = Diagnostics.temporaryDirectory("selftest")
        setenv("MACSHOT_DATA_DIR", directory.appending(path: "data").path, 1)
        let domain = ProcessInfo.processInfo.processName
        let savedDefaults = UserDefaults.standard.persistentDomain(forName: domain)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer {
            if let savedDefaults {
                UserDefaults.standard.setPersistentDomain(savedDefaults, forName: domain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let image = Diagnostics.fixtureImage(width: 640, height: 400)
        await checkEditor(image: image)
        await checkSave(image: image, directory: directory)
        await checkHistory(image: image, directory: directory)
        await checkSettings()
        await checkAboutPanel()
        checkMenuImageVisibility()

        print("\nSelf-test: \(passes) passed, \(failures) failed")
        return failures == 0
    }

    // MARK: - Editor

    private func checkEditor(image: NSImage) async {
        DetachedEditorWindowController.open(image: image)
        await settle()
        guard let window = NSApp.windows.first(where: { $0.isVisible && Self.editorView(in: $0) != nil }),
              let editor = Self.editorView(in: window) else {
            check(false, "the editor opens in a window")
            return
        }
        check(true, "the editor opens in a window")
        check(NSApp.activationPolicy() == .regular, "an open editor makes macshot a regular app")
        let strips = Self.descendants(of: window.contentView, ofType: ToolbarStripView.self)
        check(!strips.isEmpty && strips.allSatisfy { !$0.isDescendant(of: editor) },
              "the editor's toolbars are in the window, outside the canvas")

        for tool in editor.toolHandlers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            editor.annotations = []
            editor.selectedAnnotations = []
            editor.currentTool = tool
            let area = editor.selectionRect
            let start = NSPoint(x: area.minX + area.width * 0.2, y: area.minY + area.height * 0.25)
            let end = NSPoint(x: area.minX + area.width * 0.6, y: area.minY + area.height * 0.7)
            drag(in: editor, from: start, to: end)
            check(editor.annotations.count == 1, "\(tool) draws an annotation from mouse events")
        }
        editor.cachedCompositedImage = nil
        check(editor.compositedImage()?.size == editor.captureDrawRect.size,
              "the editor composites at the size of the capture")

        await checkTextAndUndo(in: editor, window: window)

        window.close()
        await settle()
        check(Self.editorView(in: window) == nil, "closing the editor releases its canvas")
    }

    /// A disposable text view that registers undo on the window's undo manager leaves
    /// entries that point at a released view, and the next ⌘Z crashes. A crash here ends
    /// the self-test with a failure.
    private func checkTextAndUndo(in editor: OverlayView, window: NSWindow) async {
        editor.annotations = []
        editor.selectedAnnotations = []
        editor.currentTool = .text
        let area = editor.selectionRect
        click(in: editor, at: NSPoint(x: area.minX + area.width * 0.3, y: area.midY))
        guard let textView = editor.textEditor.textView else {
            check(false, "a click with the text tool starts a text session")
            return
        }
        check(true, "a click with the text tool starts a text session")
        window.makeFirstResponder(textView)
        textView.insertText("self-test", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.commitTextFieldIfNeeded()
        check(editor.annotations.contains { $0.tool == .text && ($0.attributedText?.string ?? $0.text) == "self-test" },
              "typed text becomes a text annotation")
        await settle()
        var steps = 0
        while let undoManager = window.undoManager, undoManager.canUndo, steps < 20 {
            undoManager.undo()
            steps += 1
        }
        check(true, "⌘Z after a closed text session does not crash")
        editor.undo()
        check(editor.annotations.isEmpty, "the editor's undo removes the text annotation")
    }

    // MARK: - Saving and history

    private func checkSave(image: NSImage, directory: URL) async {
        let folder = directory.appending(path: "saved", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = await withCheckedContinuation { continuation in
            ImageSaveService.writeImageForTesting(image, toDirectory: folder, filename: "self-test.png",
                                                  copyPathToClipboard: false) { continuation.resume(returning: $0) }
        }
        let file = folder.appending(path: "self-test.png")
        let reopened = try? ImportedImage.checked(NSImage(contentsOf: file)).get()
        check(saved && reopened != nil, "a save writes a file that opens again")
    }

    private func checkHistory(image: NSImage, directory: URL) async {
        let history = ScreenshotHistory(directory: directory.appending(path: "history", directoryHint: .isDirectory))
        let annotation = Annotation(tool: .rectangle, startPoint: NSPoint(x: 20, y: 20),
                                    endPoint: NSPoint(x: 200, y: 120), color: .systemRed, strokeWidth: 4)
        let added = await withCheckedContinuation { continuation in
            history.add(image: image, rawImage: image, annotations: [annotation]) { continuation.resume(returning: $0) }
        }
        let capture = history.entries.first.flatMap { history.loadEditableCapture(for: $0) }
        check(added && capture?.annotations.count == 1, "history reopens a capture with its annotations")
    }

    // MARK: - Windows

    private func checkSettings() async {
        let settings = SettingsWindowController()
        settings.showWindow()
        await settle()
        guard let window = settings.window, let items = window.toolbar?.items, !items.isEmpty else {
            check(false, "Settings opens with its tabs")
            return
        }
        for item in items {
            guard let action = item.action else { continue }
            NSApp.sendAction(action, to: item.target, from: item)
            check(window.title.hasSuffix(item.label), "Settings shows the \(item.label) tab")
        }
        window.close()
        await settle()
    }

    private func checkAboutPanel() async {
        NSApp.orderFrontStandardAboutPanel(options: [:])
        await settle()
        let about = NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.level == .normal }
        check(about != nil, "the About panel opens")
        about?.close()
    }

    private func checkMenuImageVisibility() {
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            let item = NSMenuItem(title: "Thumbnail", action: nil, keyEquivalent: "")
            item.keepImageVisible()
            check(item.preferredImageVisibility == .visible, "capture thumbnails stay visible in macOS 27 menus")
        }
        #endif
    }

    // MARK: - Helpers

    private func check(_ condition: Bool, _ name: String) {
        if condition {
            passes += 1
            print("PASS \(name)")
        } else {
            failures += 1
            print("FAIL \(name)")
        }
    }

    /// Lets queued main-queue work and window updates run.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func drag(in view: NSView, from start: NSPoint, to end: NSPoint) {
        let middle = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        send(.leftMouseDown, at: start, to: view)?.mouseDown()
        send(.leftMouseDragged, at: middle, to: view)?.mouseDragged()
        send(.leftMouseDragged, at: end, to: view)?.mouseDragged()
        send(.leftMouseUp, at: end, to: view)?.mouseUp()
    }

    private func click(in view: NSView, at point: NSPoint) {
        send(.leftMouseDown, at: point, to: view)?.mouseDown()
        send(.leftMouseUp, at: point, to: view)?.mouseUp()
    }

    private struct Delivery {
        let view: NSView
        let event: NSEvent
        func mouseDown() { view.mouseDown(with: event) }
        func mouseDragged() { view.mouseDragged(with: event) }
        func mouseUp() { view.mouseUp(with: event) }
    }

    /// An event at `point` in `view`'s coordinates.
    private func send(_ type: NSEvent.EventType, at point: NSPoint, to view: NSView) -> Delivery? {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        return Delivery(view: view, event: event)
    }

    private static func editorView(in window: NSWindow) -> EditorView? {
        descendants(of: window.contentView, ofType: EditorView.self).first
    }

    private static func descendants<T: NSView>(of view: NSView?, ofType type: T.Type) -> [T] {
        guard let view else { return [] }
        return view.subviews.flatMap { subview -> [T] in
            let match: [T] = (subview as? T).map { [$0] } ?? []
            return match + descendants(of: subview, ofType: type)
        }
    }
}
#endif
