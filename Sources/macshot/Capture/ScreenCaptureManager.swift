import Cocoa
import ScreenCaptureKit

struct ScreenCapture {
    let screen: NSScreen
    let image: CGImage
}

class ScreenCaptureManager {

    // MARK: - SCShareableContent cache

    /// Cached shareable content to avoid repeated (slow) enumeration.
    private static var cachedContent: SCShareableContent?
    private static var cachedContentTime: Date = .distantPast
    /// Cache is valid for 2 seconds — long enough to survive the hotkey→capture gap,
    /// short enough that display changes are picked up.
    private static let cacheTTL: TimeInterval = 2.0

    /// Fetch shareable content, using a short-lived cache to avoid redundant enumeration.
    private static func shareableContent() async throws -> SCShareableContent {
        if let cached = cachedContent, Date().timeIntervalSince(cachedContentTime) < cacheTTL {
            return cached
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        cachedContent = content
        cachedContentTime = Date()
        return content
    }

    /// Pre-warm the shareable content cache so the next capture is instant.
    /// Call this when the menu bar opens or a hotkey is pressed — before the actual capture starts.
    static func prewarm() {
        Task {
            _ = try? await shareableContent()
        }
    }

    /// Captures every display and hands each capture to `onCapture` the moment it
    /// lands, the display under the pointer first.
    ///
    /// Uses the rect-based screenshot API first. It avoids enumerating
    /// SCShareableContent in the hot path and freezes the trigger-time pixels
    /// before the overlay is ordered front. Displays that it cannot capture are
    /// captured again through a content filter with fresh shareable content, so
    /// transient UI present at hotkey time (open menus, Spotlight or Raycast
    /// panels) is in the window list. ScreenCaptureKit never paints the cursor
    /// when `showsCursor` is false, so the "Capture mouse cursor" setting also
    /// applies to the enlarged shake-to-find pointer.
    ///
    /// Returns the captures that succeeded, which can be fewer than the displays.
    static func captureAllScreensImmediately(
        priorityScreen: NSScreen? = nil,
        timing: (@Sendable (String) -> Void)? = nil,
        onCapture: ((ScreenCapture) -> Void)? = nil
    ) async -> [ScreenCapture] {
        let showsCursor = UserDefaults.standard.bool(forKey: "captureCursor")
        var captures = await captureScreensWithRect(
            showsCursor: showsCursor,
            priorityScreen: priorityScreen,
            timing: timing,
            onCapture: onCapture)

        let missing = NSScreen.screens.filter { screen in !captures.contains { $0.screen === screen } }
        guard !missing.isEmpty else { return captures }

        timing?("SCK filter fallback: shareable content begin missing=\(missing.count)")
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        else {
            timing?("SCK filter fallback: shareable content failed")
            return captures
        }

        // Capture sequentially: replayd serialises concurrent screenshot requests anyway.
        for screen in missing {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                timing?("SCK filter fallback: no display for screen")
                continue
            }
            // Capture the whole display, excluding nothing: transient UI must be
            // preserved. The cursor is controlled by showsCursor, not by the window list.
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = Int(screen.backingScaleFactor)
            config.width = display.width * scale
            config.height = display.height * scale
            config.showsCursor = showsCursor
            config.captureResolution = .best
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            else {
                timing?("SCK filter fallback: capture failed display=\(display.displayID)")
                continue
            }
            timing?("SCK filter fallback: capture end display=\(display.displayID) pixels=\(image.width)x\(image.height)")
            let capture = ScreenCapture(screen: screen, image: image)
            captures.append(capture)
            onCapture?(capture)
        }
        return captures
    }

    private static func captureScreensWithRect(
        showsCursor: Bool,
        priorityScreen: NSScreen?,
        timing: (@Sendable (String) -> Void)?,
        onCapture: ((ScreenCapture) -> Void)?
    ) async -> [ScreenCapture] {
        let screens = NSScreen.screens

        timing?("SCK rect immediate: begin screens=\(screens.count)")
        // SCScreenshotManager.captureScreenshot(rect:) takes CoreGraphics display
        // space: origin at the TOP-left of the primary display, y down. NSScreen
        // frames are AppKit space: origin at the BOTTOM-left of the primary, y up.
        // The two only coincide for the primary display — non-primary screens
        // captured with the raw AppKit frame come back vertically shifted with a
        // black stripe where the rect fell off the display (#291, #294).
        guard let primaryScreen = screens.first else { return [] }
        let primaryHeight = primaryScreen.frame.maxY
        // NOTE: capture displays SEQUENTIALLY, not concurrently.
        // On macOS 26 replayd serialises concurrent SCScreenshotManager requests
        // anyway, and charges ~1.3s per queued request instead of ~380ms. On a
        // 4-display Mac that is 3.9s concurrent vs 1.5s sequential (2.5x).
        // Capture the cursor's display first and hand each capture back through
        // onCapture the moment it lands, so the overlay on the display the user
        // is looking at goes interactive after ONE capture, not after all of them.
        var order = Array(screens.enumerated())
        if let priority = priorityScreen,
           let hit = order.firstIndex(where: { $0.element === priority }), hit != 0 {
            let entry = order.remove(at: hit)
            order.insert(entry, at: 0)
            timing?("SCK rect: prioritised cursor display index=\(entry.offset)")
        }
        var captures: [ScreenCapture] = []
        for (index, screen) in order {
            let appKitFrame = screen.frame
            let rect = CGRect(
                x: appKitFrame.origin.x,
                y: primaryHeight - appKitFrame.maxY,
                width: appKitFrame.width,
                height: appKitFrame.height)
            let config = SCScreenshotConfiguration()
            config.width = Int(rect.width * screen.backingScaleFactor)
            config.height = Int(rect.height * screen.backingScaleFactor)
            config.showsCursor = showsCursor
            // Rectangle screenshots omit window framing by default on
            // macOS 26. Preserve the shadows visible on the desktop.
            config.ignoreShadows = false
            config.displayIntent = .local
            config.dynamicRange = .sdr
            timing?("SCK rect capture begin screen=\(index) rect=\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))")
            let result = await captureScreenshotOutput(rect: rect, configuration: config)
            guard
                result.error == nil,
                let output = result.output,
                let image = output.sdrImage ?? output.hdrImage
            else {
                let reason = result.error?.localizedDescription ?? "no image returned"
                timing?("SCK rect capture failed screen=\(index) error=\(reason)")
                continue
            }
            timing?("SCK rect capture end screen=\(index) pixels=\(image.width)x\(image.height)")
            let capture = ScreenCapture(screen: screen, image: image)
            captures.append(capture)
            onCapture?(capture)
        }

        timing?("SCK rect immediate: end captures=\(captures.count)/\(screens.count)")
        return captures
    }

    private static func captureScreenshotOutput(
        rect: CGRect,
        configuration: SCScreenshotConfiguration
    ) async -> (output: SCScreenshotOutput?, error: Error?) {
        await withCheckedContinuation { continuation in
            SCScreenshotManager.captureScreenshot(rect: rect, configuration: configuration) {
                output,
                error in
                continuation.resume(returning: (output, error))
            }
        }
    }

    static func makeDisplayPreviewImage(from image: CGImage, maxPixelDimension: Int = 1400) -> CGImage {
        let maxDimension = max(image.width, image.height)
        guard maxDimension > maxPixelDimension else { return image }

        let scale = CGFloat(maxPixelDimension) / CGFloat(maxDimension)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func captureAllScreens(
        excludingWindowNumbers: [CGWindowID] = [],
        timing: (@Sendable (String) -> Void)? = nil,
        completion: @escaping ([ScreenCapture]) -> Void
    ) {
        Task {
            do {
                timing?("captureAllScreens Task entered")
                // When excluding windows, fetch fresh content so newly-created
                // windows (e.g. thumbnails spawned after the cache was built) are
                // present in the window list and can actually be excluded.
                let content: SCShareableContent
                if !excludingWindowNumbers.isEmpty {
                    timing?("SCShareableContent fresh begin")
                    content = try await SCShareableContent.excludingDesktopWindows(
                        true, onScreenWindowsOnly: true)
                    timing?("SCShareableContent fresh end displays=\(content.displays.count) windows=\(content.windows.count)")
                } else {
                    timing?("SCShareableContent cached begin")
                    content = try await shareableContent()
                    timing?("SCShareableContent cached end displays=\(content.displays.count) windows=\(content.windows.count)")
                }
                let displays = content.displays
                timing?("captureAllScreens NSScreen.screens begin")
                let screens = NSScreen.screens
                timing?("captureAllScreens NSScreen.screens end count=\(screens.count)")

                // Resolve window numbers to SCWindow objects for exclusion
                timing?("resolve excluded windows begin count=\(excludingWindowNumbers.count)")
                let excludedSCWindows: [SCWindow] = excludingWindowNumbers.compactMap { wid in
                    content.windows.first(where: { CGWindowID($0.windowID) == wid })
                }
                timing?("resolve excluded windows end matched=\(excludedSCWindows.count)")

                // Build display-screen pairs
                timing?("build display-screen pairs begin displays=\(displays.count)")
                var pairs: [(SCDisplay, NSScreen)] = []
                for display in displays {
                    if let screen = screens.first(where: { $0.displayID == display.displayID }) {
                        pairs.append((display, screen))
                    }
                }
                timing?("build display-screen pairs end pairs=\(pairs.count)")

                // Capture all displays concurrently
                timing?("SCScreenshot capture group begin pairs=\(pairs.count)")
                let captures = await withTaskGroup(
                    of: ScreenCapture?.self, returning: [ScreenCapture].self
                ) { group in
                    for (index, pair) in pairs.enumerated() {
                        let (display, screen) = pair
                        group.addTask {
                            // SCScreenshotManager: single-shot API, no stream overhead
                            timing?("SCScreenshotManager capture begin display=\(index)")
                            let filter = SCContentFilter(
                                display: display, excludingWindows: excludedSCWindows)
                            let config = SCStreamConfiguration()
                            let scale = Int(screen.backingScaleFactor)
                            config.width = display.width * scale
                            config.height = display.height * scale
                            config.showsCursor = UserDefaults.standard.bool(
                                forKey: "captureCursor")
                            config.captureResolution = .best

                            guard
                                let image = try? await SCScreenshotManager.captureImage(
                                    contentFilter: filter, configuration: config
                                )
                            else {
                                timing?("SCScreenshotManager capture failed display=\(index)")
                                return nil
                            }
                            timing?("SCScreenshotManager capture end display=\(index) pixels=\(image.width)x\(image.height)")
                            return ScreenCapture(screen: screen, image: image)
                        }
                    }
                    var results: [ScreenCapture] = []
                    for await capture in group {
                        if let capture = capture {
                            results.append(capture)
                        }
                    }
                    return results
                }
                timing?("SCScreenshot capture group end captures=\(captures.count)")

                await MainActor.run { completion(captures) }
            } catch {
                timing?("captureAllScreens error \(error.localizedDescription)")
                #if DEBUG
                    NSLog("macshot: screen capture error: \(error.localizedDescription)")
                #endif
                await MainActor.run { completion([]) }
            }
        }
    }

    // MARK: - Single window capture (with transparency)

    /// Captures a single window by its CGWindowID with a `desktopIndependentWindow`
    /// filter, so the corners outside the window shape stay transparent.
    static func captureWindow(windowID: CGWindowID, screen: NSScreen) async -> CGImage? {
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true),
            let scWindow = content.windows.first(where: { CGWindowID($0.windowID) == windowID })
        else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let scale = Int(screen.backingScaleFactor)
        config.width = Int(scWindow.frame.width) * scale
        config.height = Int(scWindow.frame.height) * scale
        config.showsCursor = false
        config.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

extension NSScreen {
    /// The CoreGraphics display ID of this screen.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
