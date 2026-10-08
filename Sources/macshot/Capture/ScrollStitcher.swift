import CoreGraphics
import Darwin

/// Joins the frames of a scroll capture into one tall image.
///
/// Kept free of capture state, ScreenCaptureKit and permissions, like
/// `ScrollFrameAnalyzer`, so it can be tested and timed on plain images
/// (`make perf` runs `PerformanceTests`). `ScrollCaptureController` decides how
/// far each frame scrolled and whether a frozen header is pinned; this owns the
/// pixels.
///
/// The pixels live in one buffer that grows geometrically, and each strip is
/// drawn into it in place, so a strip costs its own rows. Copying the whole
/// image into a new bitmap for each strip made a capture cost the square of its
/// height. The draw calls are the ones that copy made, into a bitmap of the
/// same size and format that already holds the existing rows, so the pixels are
/// the same: `ScrollStitcherTests` compares the two.
nonisolated final class ScrollStitcher {

    private(set) var width: Int
    private(set) var height: Int
    /// Once a strip is added, `makePreview()` is at most this many pixels wide.
    let previewWidth: Int

    /// The image while `canvas` holds nothing: the first frame, or what
    /// `makeImage()` returned.
    private var base: CGImage?
    private var canvas: StitchCanvas?
    /// The image downscaled to `previewWidth`, drawn strip by strip. Nil when
    /// the image is no wider than that.
    private var preview: StitchCanvas?

    init(firstFrame: CGImage, previewWidth: Int) {
        base = firstFrame
        width = firstFrame.width
        height = firstFrame.height
        self.previewWidth = max(1, previewWidth)
    }

    var pixelSize: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// Adds the `newRows` rows that scrolled into view at the bottom of `frame`.
    ///
    /// By default the whole frame goes at the bottom of the image, so where the
    /// two overlap, the newer pixels win. With `onlyNewRows` (the controller
    /// found a frozen header) only the frame's bottom `newRows` rows are added,
    /// so the header is not stitched in again with every strip.
    ///
    /// A row count below one or above the frame's height changes nothing.
    func append(_ frame: CGImage, newRows: Int, onlyNewRows: Bool) {
        guard newRows > 0, newRows <= frame.height else { return }
        let frameWidth = frame.width
        let existingHeight = height
        let totalHeight = existingHeight + newRows

        let context: CGContext
        var restartedFrom: CGImage?
        if let canvas, canvas.width == frameWidth {
            guard let grown = canvas.grow(to: totalHeight) else { return }
            context = grown
        } else {
            // The first strip, or a frame of another width: draw the image so
            // far into a new canvas, scaled to the frame's width.
            guard let existing = makeImage() else { return }
            let colorSpace = existing.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let fresh = StitchCanvas(width: frameWidth, colorSpace: colorSpace)
            guard let grown = fresh.grow(to: totalHeight) else { return }
            // CGContext has a bottom-left origin, so the top of the image is the highest y.
            grown.draw(existing, in: CGRect(x: 0, y: newRows, width: frameWidth, height: existingHeight))
            context = grown
            canvas = fresh
            base = nil
            width = frameWidth
            preview = frameWidth > previewWidth ? StitchCanvas(width: previewWidth, colorSpace: colorSpace) : nil
            restartedFrom = existing
        }

        // The image rows from `top` down are what this strip drew.
        var drawn: (image: CGImage, top: Int)?
        if onlyNewRows {
            if let strip = frame.cropping(to: CGRect(
                x: 0, y: frame.height - newRows, width: frameWidth, height: newRows)) {
                context.draw(strip, in: CGRect(x: 0, y: 0, width: frameWidth, height: newRows))
                drawn = (strip, existingHeight)
            }
        } else {
            context.draw(frame, in: CGRect(x: 0, y: 0, width: frameWidth, height: frame.height))
            drawn = (frame, totalHeight - frame.height)
        }
        height = totalHeight
        updatePreview(restartedFrom: restartedFrom, existingHeight: existingHeight, drawn: drawn)
    }

    /// The stitched image. It takes over the canvas's pixels without copying
    /// them, and the next `append` copies them into a new canvas, so call it
    /// when a capture ends, not after each strip: `makePreview()` is for that.
    func makeImage() -> CGImage? {
        if let base { return base }
        guard let canvas, let image = canvas.takeImage() ?? canvas.copyImage() else { return nil }
        base = image
        self.canvas = nil
        return image
    }

    /// The stitched image for a live preview: until a strip is added, the
    /// first frame, and then at most `previewWidth` pixels wide. Show it at
    /// `pixelSize`: rounding can make its aspect differ from the image's by
    /// part of a pixel.
    func makePreview() -> CGImage? {
        if let preview { return preview.copyImage() }
        if let canvas { return canvas.copyImage() }
        return base
    }

    /// Draws what the strip added into the preview, scaled down. A new canvas
    /// starts the preview again from the whole image so far.
    private func updatePreview(restartedFrom existing: CGImage?, existingHeight: Int,
                               drawn: (image: CGImage, top: Int)?) {
        guard let preview else { return }
        let scale = Double(preview.width) / Double(width)
        // Strips go to whole preview rows, so neighbours share an edge and
        // leave no half-covered row between them.
        func previewRow(_ row: Int) -> Int { Int((Double(row) * scale).rounded()) }
        let previewHeight = max(1, previewRow(height))
        guard let context = preview.grow(to: previewHeight) else {
            // Out of memory for the preview: show copies of the full image instead.
            self.preview = nil
            return
        }
        context.interpolationQuality = .high
        if let existing {
            let existingRows = previewRow(existingHeight)
            context.draw(existing, in: CGRect(x: 0, y: previewHeight - existingRows,
                                              width: preview.width, height: existingRows))
        }
        if let drawn {
            context.draw(drawn.image, in: CGRect(x: 0, y: 0, width: preview.width,
                                                 height: previewHeight - previewRow(drawn.top)))
        }
    }
}

/// Premultiplied BGRA rows, top row first, in memory that grows geometrically,
/// so adding rows costs the new rows, not the ones already there.
nonisolated private final class StitchCanvas {
    /// The format every stitched image has had.
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    let width: Int
    let bytesPerRow: Int
    let colorSpace: CGColorSpace
    private(set) var rows = 0
    private var capacity = 0
    private var storage: UnsafeMutableRawPointer?

    init(width: Int, colorSpace: CGColorSpace) {
        self.width = width
        self.bytesPerRow = width * 4
        self.colorSpace = colorSpace
    }

    deinit {
        free(storage)
    }

    /// Grows to `count` rows, the new ones transparent, and returns a context
    /// over all of them: the bitmap a new context of that size would be, with
    /// the existing rows already drawn. Nil, and unchanged, when it cannot.
    func grow(to count: Int) -> CGContext? {
        guard count >= rows, count > 0 else { return nil }
        if count > capacity {
            let newCapacity = max(count, capacity * 2)
            let (bytes, overflow) = newCapacity.multipliedReportingOverflow(by: bytesPerRow)
            guard !overflow, let grown = realloc(storage, bytes) else { return nil }
            storage = grown
            capacity = newCapacity
        }
        guard let storage, let context = CGContext(
            data: storage, width: width, height: count, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: Self.bitmapInfo) else { return nil }
        // realloc leaves new memory as it was; a new context starts transparent.
        memset(storage + rows * bytesPerRow, 0, (count - rows) * bytesPerRow)
        rows = count
        return context
    }

    /// An image of a copy of the rows.
    func copyImage() -> CGImage? {
        guard let storage, rows > 0,
              let data = CFDataCreate(nil, storage.assumingMemoryBound(to: UInt8.self), rows * bytesPerRow),
              let provider = CGDataProvider(data: data) else { return nil }
        return image(provider)
    }

    /// An image that takes over the rows without copying them. The canvas is
    /// empty afterwards, unless it returns nil.
    func takeImage() -> CGImage? {
        guard let storage, rows > 0 else { return nil }
        let size = rows * bytesPerRow
        // Give back the capacity that the image does not use.
        if let shrunk = realloc(storage, size) {
            self.storage = shrunk
            capacity = rows
        }
        guard let pixels = self.storage, let provider = CGDataProvider(
            dataInfo: nil, data: pixels, size: size,
            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }) else { return nil }
        // The provider frees the pixels when the last image that uses them goes.
        let image = image(provider)
        self.storage = nil
        capacity = 0
        rows = 0
        return image
    }

    private func image(_ provider: CGDataProvider) -> CGImage? {
        CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
