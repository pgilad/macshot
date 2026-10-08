import CoreGraphics

/// Joins the frames of a scroll capture into one tall image.
///
/// Kept free of capture state, ScreenCaptureKit and permissions, like
/// `ScrollFrameAnalyzer`, so it can be tested and timed on plain images
/// (`make perf` runs `PerformanceTests`). `ScrollCaptureController` decides how
/// far each frame scrolled and whether a frozen header is pinned; this owns the
/// pixels.
nonisolated struct ScrollStitcher {

    /// The stitched image so far. Until a frame is appended, the first frame itself.
    private(set) var image: CGImage

    init(firstFrame: CGImage) {
        image = firstFrame
    }

    var height: Int { image.height }

    var pixelSize: CGSize {
        CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
    }

    /// Adds the `newRows` rows that scrolled into view at the bottom of `frame`.
    ///
    /// By default the whole frame goes at the bottom of the image, so where the
    /// two overlap, the newer pixels win. With `onlyNewRows` (the controller
    /// found a frozen header) only the frame's bottom `newRows` rows are added,
    /// so the header is not stitched in again with every strip.
    ///
    /// A row count below one or above the frame's height changes nothing.
    mutating func append(_ frame: CGImage, newRows: Int, onlyNewRows: Bool) {
        let width = frame.width
        let existingHeight = image.height
        guard newRows > 0, newRows <= frame.height else { return }
        let totalHeight = existingHeight + newRows

        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: totalHeight,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return }

        // CGContext has a bottom-left origin, so the top of the image is the highest y.
        context.draw(image, in: CGRect(x: 0, y: newRows, width: width, height: existingHeight))

        if onlyNewRows {
            if let strip = frame.cropping(to: CGRect(
                x: 0, y: frame.height - newRows, width: width, height: newRows)) {
                context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: newRows))
            }
        } else {
            context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: frame.height))
        }

        guard let merged = context.makeImage() else { return }
        image = merged
    }
}
