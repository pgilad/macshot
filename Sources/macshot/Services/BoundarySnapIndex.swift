import Cocoa

/// Image-edge index for "boundary snap" — snapping the capture selection's
/// dragged edges to strong color boundaries (UI lines, window borders, table
/// rows, etc.) in the captured screenshot, like CleanShot X + PixelSnap.
///
/// Built ONCE per screenshot (off the main thread). During a resize drag the
/// lookup is a cheap scan over a small ±radius window, scored only across the
/// selection's perpendicular span so it snaps to edges that actually run along
/// the dragged side — not unrelated lines elsewhere on screen.
///
/// All "boundary" indices are between-pixel positions: vertical boundary `b`
/// (0…width) sits between pixel columns `b-1` and `b`; horizontal boundary `b`
/// (0…height) sits between rows `b-1` and `b`. Boundary 0 and width/height are
/// the image edges (no diff), so the usable range is 1…dim-1.
struct BoundarySnapIndex {
    let width: Int
    let height: Int
    /// drawRect the screenshot was drawn into (overlay-space). Used to map
    /// view points ↔ image pixels.
    let drawRect: NSRect

    /// Per-pixel vertical edge strength: difference between column x-1 and x,
    /// at `storageScale`. Indexed `[y * (width + 1) + xBoundary]`, xBoundary in
    /// 1…width-1.
    let verticalDiff: [UInt8]
    /// Per-pixel horizontal edge strength: difference between row y-1 and y,
    /// at `storageScale`. Indexed `[yBoundary * width + x]`, yBoundary in
    /// 1…height-1.
    let horizontalDiff: [UInt8]

    /// A qualifying snap target.
    struct Hit {
        let viewPosition: CGFloat   // overlay-space coordinate to snap the edge to
        let pixelBoundary: Int
        let strength: Float
    }

    // Tuning. An edge qualifies when its mean color difference along the
    // selection span clears `minMeanDiff` AND it's covered along a good fraction
    // of that span (so a single stray high-contrast pixel doesn't count).
    private static let minMeanDiff: Float = 28      // 0…~441 (RGB euclidean)
    private static let minSupportFraction: Float = 0.55

    /// The diffs are stored at half scale, one byte each: the largest RGB
    /// distance, √(3·255²) ≈ 442, becomes 221. A 6K capture (20 MP) needs
    /// 2 × 20 MB instead of 2 × 81 MB as Float.
    private static let storageScale: Float = 0.5
    private static let minStoredDiff = UInt8((minMeanDiff * storageScale).rounded())

    /// Rows converted to RGBA8 at a time. The temporary pixel buffer holds
    /// one band (plus one row of overlap), not the whole screenshot.
    static let defaultBandRows = 256

    // MARK: - Build

    /// Build the index from a screenshot CGImage drawn into `drawRect`.
    /// Returns nil for degenerate images. Safe to call off the main thread.
    nonisolated static func build(from cgImage: CGImage, drawRect: NSRect,
                                  bandRows: Int = defaultBandRows) -> BoundarySnapIndex? {
        let w = cgImage.width
        let h = cgImage.height
        guard w >= 2, h >= 2, drawRect.width > 0, drawRect.height > 0, bandRows >= 1 else { return nil }
        // The arrays are O(pixels): 2 bytes per pixel. Bail only if absurd.
        guard w * h <= 40_000_000 else { return nil }

        // Render a band at a time into a known RGBA8 buffer so component access
        // is predictable. Row 0 of the buffer is the top row of the band.
        let bytesPerRow = w * 4
        let bufferRows = min(h, bandRows + 1)
        var pixels = [UInt8](repeating: 0, count: bufferRows * bytesPerRow)
        var vDiff = [UInt8](repeating: 0, count: h * (w + 1))
        var hDiff = [UInt8](repeating: 0, count: h * w)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Each band measures image rows bandStart..<bandEnd (top-down). It also
        // renders the row above it, for the horizontal boundary at bandStart.
        var bandStart = 0
        while bandStart < h {
            let firstRow = max(0, bandStart - 1)
            let bandEnd = min(h, bandStart + bandRows)
            let rows = bandEnd - firstRow
            let rendered = pixels.withUnsafeMutableBytes { ptr -> Bool in
                guard let ctx = CGContext(
                    data: ptr.baseAddress, width: w, height: rows,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                // Place the image so its row `firstRow` is the top of the context.
                ctx.draw(cgImage, in: CGRect(x: 0, y: rows + firstRow - h, width: w, height: h))
                return true
            }
            guard rendered else { return nil }

            pixels.withUnsafeBufferPointer { buf in
                let p = buf.baseAddress!
                for y in bandStart..<bandEnd {
                    let row = (y - firstRow) * bytesPerRow
                    // Vertical boundaries: |column x - column x-1| in row y.
                    let vBase = y * (w + 1)
                    for x in 1..<w {
                        vDiff[vBase + x] = storedDist(p, row + (x - 1) * 4, row + x * 4)
                    }
                    // Horizontal boundary: |row y - row y-1| per column.
                    guard y >= 1 else { continue }
                    let rowAbove = row - bytesPerRow
                    let hBase = y * w
                    for x in 0..<w {
                        hDiff[hBase + x] = storedDist(p, rowAbove + x * 4, row + x * 4)
                    }
                }
            }
            bandStart = bandEnd
        }

        return BoundarySnapIndex(
            width: w, height: h, drawRect: drawRect,
            verticalDiff: vDiff, horizontalDiff: hDiff)
    }

    @inline(__always)
    private nonisolated static func storedDist(_ p: UnsafePointer<UInt8>, _ a: Int, _ b: Int) -> UInt8 {
        let dr = Float(Int(p[a]) - Int(p[b]))
        let dg = Float(Int(p[a + 1]) - Int(p[b + 1]))
        let db = Float(Int(p[a + 2]) - Int(p[b + 2]))
        return UInt8(((dr * dr + dg * dg + db * db).squareRoot() * storageScale).rounded())
    }

    // MARK: - Coordinate mapping

    private var scaleX: CGFloat { CGFloat(width) / drawRect.width }
    private var scaleY: CGFloat { CGFloat(height) / drawRect.height }

    /// overlay-space X → pixel boundary (rounded, clamped to 0…width).
    private func pixelX(_ viewX: CGFloat) -> Int {
        max(0, min(width, Int((((viewX - drawRect.minX) * scaleX)).rounded())))
    }
    /// overlay-space Y → pixel boundary (Y flipped; rounded, clamped 0…height).
    private func pixelY(_ viewY: CGFloat) -> Int {
        max(0, min(height, Int((((drawRect.maxY - viewY) * scaleY)).rounded())))
    }
    private func viewXOf(boundary b: Int) -> CGFloat { drawRect.minX + CGFloat(b) / scaleX }
    private func viewYOf(boundary b: Int) -> CGFloat { drawRect.maxY - CGFloat(b) / scaleY }

    // MARK: - Lookup

    /// Find the nearest strong VERTICAL image boundary to `viewX`, scoring edge
    /// strength along the selection's [yMinView, yMaxView] span. `radiusPoints`
    /// is the snap radius in overlay points.
    func nearestVertical(toViewX viewX: CGFloat, yMinView: CGFloat, yMaxView: CGFloat,
                         radiusPoints: CGFloat) -> Hit? {
        let center = pixelX(viewX)
        let radiusPx = max(1, Int((radiusPoints * scaleX).rounded()))
        var y0 = pixelY(max(yMinView, yMaxView))   // larger view-Y → smaller pixel-Y
        var y1 = pixelY(min(yMinView, yMaxView))
        if y0 > y1 { swap(&y0, &y1) }
        y0 = max(0, y0); y1 = min(height - 1, y1)
        guard y1 >= y0 else { return nil }
        let span = y1 - y0 + 1

        var best: Hit?
        var bestDist = Int.max
        let lo = max(1, center - radiusPx)
        let hi = min(width - 1, center + radiusPx)
        guard lo <= hi else { return nil }
        for b in lo...hi {
            var sum = 0
            var support = 0
            for y in y0...y1 {
                let d = verticalDiff[y * (width + 1) + b]
                sum += Int(d)
                if d >= Self.minStoredDiff { support += 1 }
            }
            let mean = Float(sum) / Self.storageScale / Float(span)
            let supportFrac = Float(support) / Float(span)
            guard mean >= Self.minMeanDiff, supportFrac >= Self.minSupportFraction else { continue }
            // Prefer a true local maximum (sharper than its neighbours).
            let dist = abs(b - center)
            if dist < bestDist {
                bestDist = dist
                best = Hit(viewPosition: viewXOf(boundary: b), pixelBoundary: b, strength: mean)
            }
        }
        return best
    }

    /// Find the nearest strong HORIZONTAL image boundary to `viewY`, scoring edge
    /// strength along the selection's [xMinView, xMaxView] span.
    func nearestHorizontal(toViewY viewY: CGFloat, xMinView: CGFloat, xMaxView: CGFloat,
                           radiusPoints: CGFloat) -> Hit? {
        let center = pixelY(viewY)
        let radiusPx = max(1, Int((radiusPoints * scaleY).rounded()))
        var x0 = pixelX(min(xMinView, xMaxView))
        var x1 = pixelX(max(xMinView, xMaxView))
        x0 = max(0, x0); x1 = min(width - 1, x1)
        guard x1 >= x0 else { return nil }
        let span = x1 - x0 + 1

        var best: Hit?
        var bestDist = Int.max
        let lo = max(1, center - radiusPx)
        let hi = min(height - 1, center + radiusPx)
        guard lo <= hi else { return nil }
        for b in lo...hi {
            var sum = 0
            var support = 0
            let base = b * width
            for x in x0...x1 {
                let d = horizontalDiff[base + x]
                sum += Int(d)
                if d >= Self.minStoredDiff { support += 1 }
            }
            let mean = Float(sum) / Self.storageScale / Float(span)
            let supportFrac = Float(support) / Float(span)
            guard mean >= Self.minMeanDiff, supportFrac >= Self.minSupportFraction else { continue }
            let dist = abs(b - center)
            if dist < bestDist {
                bestDist = dist
                best = Hit(viewPosition: viewYOf(boundary: b), pixelBoundary: b, strength: mean)
            }
        }
        return best
    }
}
