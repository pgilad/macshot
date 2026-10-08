import Cocoa
import Testing
@testable import macshot

/// Scroll capture joins each frame below the image it has so far. A seam one
/// row off repeats or drops a line of text, and a frozen header stitched in
/// again shows up once per strip.
final class ScrollStitcherTests {

    /// One pixel row of a fixture, as 8-bit sRGB samples.
    private struct Row: Equatable, CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int
        var description: String { "(\(red),\(green),\(blue))" }
    }

    private let header = Row(red: 250, green: 250, blue: 250)

    /// Row `p` of a page taller than the frame. Red and blue hold `p`, so a
    /// stitched row tells which page row it shows; green holds `tag`, which
    /// tells which frame drew it.
    private func pageRow(_ p: Int, tag: Int = 0) -> Row {
        Row(red: p % 256, green: tag, blue: p / 256)
    }

    /// A frame of `rows`, top first, each row one colour.
    private func frame(rows: [Row], width: Int = 8) throws -> CGImage {
        let height = rows.count
        return try #require(ImageProbe.makeCGImage(width: width, height: height) { context in
            for (index, row) in rows.enumerated() {
                context.setFillColor(CGColor(srgbRed: CGFloat(row.red) / 255, green: CGFloat(row.green) / 255,
                                             blue: CGFloat(row.blue) / 255, alpha: 1))
                // The context has a bottom-left origin, and image row 0 is the top.
                context.fill(CGRect(x: 0, y: height - 1 - index, width: width, height: 1))
            }
        })
    }

    /// A frame that shows page rows from `top`, below `headerRows` rows of a
    /// fixed header colour that does not scroll.
    private func frame(top: Int, height: Int = 20, tag: Int = 0, headerRows: Int = 0) throws -> CGImage {
        try frame(rows: (0..<height).map { $0 < headerRows ? header : pageRow(top + $0, tag: tag) })
    }

    /// Most tests use frames wider than the preview, so every append also
    /// draws the preview.
    private func stitcher(_ first: CGImage) -> ScrollStitcher {
        ScrollStitcher(firstFrame: first, previewWidth: 4)
    }

    private func image(_ stitcher: ScrollStitcher) throws -> CGImage {
        try #require(stitcher.makeImage())
    }

    /// The colour of each row, top first, read in the middle column.
    private func rows(of image: CGImage) throws -> [Row] {
        let size = NSSize(width: image.width, height: image.height)
        let bitmap = try #require(ImageProbe.bitmap(from: NSImage(cgImage: image, size: size)))
        let byte = { (value: CGFloat) in Int((value * 255).rounded()) }
        return try (0..<bitmap.pixelsHigh).map { y in
            let colour = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y))
            return Row(red: byte(colour.redComponent), green: byte(colour.greenComponent),
                       blue: byte(colour.blueComponent))
        }
    }

    // MARK: - Seams

    @Test func testTheFirstFrameIsTheImageUntilAFrameIsAppended() throws {
        let first = try frame(top: 0)
        let stitcher = stitcher(first)
        #expect(stitcher.makeImage() === first)
        #expect(stitcher.makePreview() === first)
        #expect(stitcher.pixelSize == CGSize(width: 8, height: 20))
    }

    @Test func testAWholeFrameGoesAtTheBottomAndWinsWhereItOverlaps() throws {
        let stitcher = stitcher(try frame(top: 0, tag: 1))
        // The page moved 6 rows, but only 5 are added, as the controller does:
        // the newer frame then covers one more row of the older one.
        stitcher.append(try frame(top: 6, tag: 2), newRows: 5, onlyNewRows: false)

        #expect(stitcher.pixelSize == CGSize(width: 8, height: 25))
        let expected = (0..<5).map { pageRow($0, tag: 1) } + (0..<20).map { pageRow(6 + $0, tag: 2) }
        #expect(try rows(of: image(stitcher)) == expected)
    }

    @Test func testOnlyNewRowsKeepsAFrozenHeaderAtTheTopOnly() throws {
        let stitcher = stitcher(try frame(top: 0, tag: 1, headerRows: 4))
        stitcher.append(try frame(top: 5, tag: 2, headerRows: 4), newRows: 5, onlyNewRows: true)

        #expect(stitcher.pixelSize == CGSize(width: 8, height: 25))
        let firstFrame = (0..<20).map { $0 < 4 ? header : pageRow($0, tag: 1) }
        let newRows = (20..<25).map { pageRow($0, tag: 2) }
        #expect(try rows(of: image(stitcher)) == firstFrame + newRows)
    }

    @Test func testRowCountsOutsideTheFrameChangeNothing() throws {
        let first = try frame(top: 0)
        let stitcher = stitcher(first)
        for newRows in [0, -1, 21] {
            stitcher.append(try frame(top: 3), newRows: newRows, onlyNewRows: false)
            stitcher.append(try frame(top: 3), newRows: newRows, onlyNewRows: true)
        }
        #expect(stitcher.makeImage() === first)
        #expect(stitcher.height == 20)
    }

    /// Strips of every size, a whole frame included, rebuild the page row for
    /// row in both modes when each frame moved by the rows it adds.
    @Test func testStripsOfAnySizeRebuildThePage() throws {
        for onlyNewRows in [false, true] {
            var top = 0
            let stitcher = stitcher(try frame(top: 0))
            for shift in [1, 7, 20, 13, 2, 19] {
                top += shift
                stitcher.append(try frame(top: top), newRows: shift, onlyNewRows: onlyNewRows)
            }
            #expect(stitcher.height == 20 + top)
            #expect(try rows(of: image(stitcher)) == (0..<(20 + top)).map { pageRow($0) },
                    "onlyNewRows: \(onlyNewRows)")
        }
    }

    /// `makeImage()` hands its pixels to the image. Strips after it must go to
    /// new memory, not into the image the controller already delivered.
    @Test func testAnImageStaysTheSameWhenMoreStripsFollow() throws {
        let stitcher = stitcher(try frame(top: 0))
        stitcher.append(try frame(top: 7), newRows: 7, onlyNewRows: false)
        let delivered = try image(stitcher)
        let deliveredBytes = try pixelBytes(delivered)

        stitcher.append(try frame(top: 19), newRows: 12, onlyNewRows: false)
        stitcher.append(try frame(top: 30), newRows: 11, onlyNewRows: true)

        #expect(try pixelBytes(delivered) == deliveredBytes)
        #expect(try rows(of: image(stitcher)) == (0..<50).map { pageRow($0) })
    }

    // MARK: - Same pixels as merging into a new bitmap

    /// The stitcher once merged each strip by drawing the whole image into a
    /// new bitmap. It now draws into one buffer that grows, and must give the
    /// same image: the same bytes, format and attributes. This is that merge.
    private struct CopyingStitcher {
        private(set) var image: CGImage

        init(firstFrame: CGImage) {
            image = firstFrame
        }

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

    /// A reproducible random sequence, so a failure can be replayed.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Byte layouts a frame can come in, with where red, green, blue and
    /// alpha go in each pixel. ScreenCaptureKit delivers the first one.
    private let layouts: [(info: UInt32, order: [Int], premultiplied: Bool)] = [
        (CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue, [2, 1, 0, 3], true),
        (CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue, [0, 1, 2, 3], true),
        (CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue, [2, 1, 0, 3], false),
    ]

    /// Random pixels in rows padded past the width, as the window server pads
    /// them. Some pixels are translucent, so blending at the seams counts too.
    private func randomFrame(width: Int, height: Int, layout: Int, space: CGColorSpace,
                             using generator: inout SplitMix64) throws -> CGImage {
        let (info, order, premultiplied) = layouts[layout]
        let bytesPerRow = width * 4 + 12
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let alpha: UInt8 = !premultiplied || Int.random(in: 0..<4, using: &generator) > 0
                    ? 255 : UInt8.random(in: 0...255, using: &generator)
                let colour = (0..<3).map { _ in UInt8.random(in: 0...alpha, using: &generator) }
                let offset = y * bytesPerRow + x * 4
                for channel in 0..<3 { bytes[offset + order[channel]] = colour[channel] }
                bytes[offset + order[3]] = alpha
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    /// The pixel bytes without row padding.
    private func pixelBytes(_ image: CGImage) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data)
        let start = try #require(CFDataGetBytePtr(data))
        let rowBytes = image.width * image.bitsPerPixel / 8
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rowBytes * image.height)
        for y in 0..<image.height {
            bytes.append(contentsOf: UnsafeBufferPointer(start: start + y * image.bytesPerRow, count: rowBytes))
        }
        return bytes
    }

    private func expectSameImage(_ actual: CGImage?, _ expected: CGImage, _ label: String) throws {
        let actual = try #require(actual, "\(label): no image")
        #expect(actual.width == expected.width && actual.height == expected.height,
                "\(label): \(actual.width)x\(actual.height), expected \(expected.width)x\(expected.height)")
        #expect(actual.bitsPerComponent == expected.bitsPerComponent && actual.bitsPerPixel == expected.bitsPerPixel)
        #expect(actual.bitmapInfo == expected.bitmapInfo, "\(label)")
        #expect(actual.colorSpace == expected.colorSpace, "\(label)")
        #expect(actual.shouldInterpolate == expected.shouldInterpolate, "\(label)")
        #expect(actual.renderingIntent == expected.renderingIntent, "\(label)")
        let actualBytes = try pixelBytes(actual)
        let expectedBytes = try pixelBytes(expected)
        guard actualBytes.count == expectedBytes.count else { return }
        if let index = actualBytes.indices.first(where: { actualBytes[$0] != expectedBytes[$0] }) {
            let rowBytes = expected.width * 4
            Issue.record("\(label): first different byte at row \(index / rowBytes), byte \(index % rowBytes)")
        }
    }

    @Test func testStripsGiveTheSameImageAsMergingIntoANewBitmap() throws {
        var generator = SplitMix64(state: 0x5EED)
        let spaces = try [CGColorSpace.sRGB, CGColorSpace.displayP3].map { try #require(CGColorSpace(name: $0)) }
        for sequence in 0..<18 {
            let layout = sequence % layouts.count
            let space = spaces[sequence / layouts.count % spaces.count]
            let width = [7, 33, 64].randomElement(using: &generator)!
            let frameHeight = [9, 40].randomElement(using: &generator)!
            let first = try randomFrame(width: width, height: frameHeight, layout: layout, space: space,
                                        using: &generator)
            var reference = CopyingStitcher(firstFrame: first)
            let stitcher = ScrollStitcher(firstFrame: first, previewWidth: 5)

            for step in 0..<40 {
                let frame = try randomFrame(width: width, height: frameHeight, layout: layout, space: space,
                                            using: &generator)
                // Row counts outside the frame are in the range on purpose.
                let newRows = Int.random(in: 0...(frameHeight + 1), using: &generator)
                // Header detection can finish in the middle of a capture.
                let onlyNewRows = Bool.random(using: &generator)
                reference.append(frame, newRows: newRows, onlyNewRows: onlyNewRows)
                stitcher.append(frame, newRows: newRows, onlyNewRows: onlyNewRows)
                _ = stitcher.makePreview()
                // The controller can ask for the image mid-capture; strips continue after it.
                if Int.random(in: 0..<12, using: &generator) == 0 {
                    try expectSameImage(stitcher.makeImage(), reference.image, "sequence \(sequence), step \(step)")
                }
            }
            #expect(stitcher.height == reference.image.height)
            try expectSameImage(stitcher.makeImage(), reference.image, "sequence \(sequence)")
        }
    }

    /// ScreenCaptureKit sends frames of the configured size, so this does not
    /// happen in a capture, but the old merge scaled the image to a new frame
    /// width and clipped a frame taller than the image, and so does the stitcher.
    @Test func testFramesOfOtherSizesGiveTheSameImageAsMergingIntoANewBitmap() throws {
        var generator = SplitMix64(state: 0xF00D)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let first = try randomFrame(width: 20, height: 9, layout: 0, space: space, using: &generator)
        var reference = CopyingStitcher(firstFrame: first)
        let stitcher = ScrollStitcher(firstFrame: first, previewWidth: 6)
        for step in 0..<30 {
            let width = step < 10 ? 20 : step < 20 ? 31 : 12
            let height = Int.random(in: 5...60, using: &generator)
            let frame = try randomFrame(width: width, height: height, layout: step % layouts.count, space: space,
                                        using: &generator)
            let newRows = Int.random(in: 1...height, using: &generator)
            let onlyNewRows = Bool.random(using: &generator)
            reference.append(frame, newRows: newRows, onlyNewRows: onlyNewRows)
            stitcher.append(frame, newRows: newRows, onlyNewRows: onlyNewRows)
            _ = stitcher.makePreview()
        }
        try expectSameImage(stitcher.makeImage(), reference.image, "frames of other sizes")
    }

    // MARK: - Preview

    /// Bands of 32 rows in eight colours, so a quarter-size preview still has
    /// rows of each band's own colour, out of the downscaling filter's reach
    /// of the neighbouring bands.
    private func bandRow(_ p: Int) -> Row {
        let band = p / 32 % 8
        return Row(red: band * 30, green: 255 - band * 30, blue: band % 2 == 0 ? 40 : 200)
    }

    @Test func testThePreviewIsTheImageScaledDownToThePreviewWidth() throws {
        for onlyNewRows in [false, true] {
            let bandFrame = { (top: Int) in try self.frame(rows: (0..<48).map { self.bandRow(top + $0) }, width: 64) }
            let stitcher = ScrollStitcher(firstFrame: try bandFrame(0), previewWidth: 16)
            for step in 1...13 {
                stitcher.append(try bandFrame(step * 16), newRows: 16, onlyNewRows: onlyNewRows)
            }
            let height = 48 + 13 * 16
            let preview = try #require(stitcher.makePreview())
            #expect(preview.width == 16 && preview.height == height / 4, "\(preview.width)x\(preview.height)")

            // A band's two middle preview rows show only that band.
            let previewRows = try rows(of: preview)
            for bandTop in stride(from: 0, to: height, by: 32) {
                for row in [bandTop / 4 + 3, bandTop / 4 + 4] {
                    let expected = bandRow(bandTop)
                    let actual = previewRows[row]
                    let distance = max(abs(actual.red - expected.red), abs(actual.green - expected.green),
                                       abs(actual.blue - expected.blue))
                    #expect(distance <= 2, "onlyNewRows: \(onlyNewRows), preview row \(row): \(actual), expected \(expected)")
                }
            }
        }
    }

    @Test func testACaptureNoWiderThanThePreviewHasAFullSizePreview() throws {
        let stitcher = ScrollStitcher(firstFrame: try frame(top: 0), previewWidth: 8)
        stitcher.append(try frame(top: 9), newRows: 9, onlyNewRows: false)
        stitcher.append(try frame(top: 14), newRows: 5, onlyNewRows: true)
        let preview = try #require(stitcher.makePreview())
        #expect(try pixelBytes(preview) == pixelBytes(image(stitcher)))
    }
}
