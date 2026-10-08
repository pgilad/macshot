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

    /// A frame that shows page rows from `top`, below `headerRows` rows of a
    /// fixed header colour that does not scroll.
    private func frame(top: Int, height: Int = 20, tag: Int = 0, headerRows: Int = 0) throws -> CGImage {
        let width = 8
        let rows = (0..<height).map { $0 < headerRows ? header : pageRow(top + $0, tag: tag) }
        return try #require(ImageProbe.makeCGImage(width: width, height: height) { context in
            for (index, row) in rows.enumerated() {
                context.setFillColor(CGColor(srgbRed: CGFloat(row.red) / 255, green: CGFloat(row.green) / 255,
                                             blue: CGFloat(row.blue) / 255, alpha: 1))
                // The context has a bottom-left origin, and image row 0 is the top.
                context.fill(CGRect(x: 0, y: height - 1 - index, width: width, height: 1))
            }
        })
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

    @Test func testTheFirstFrameIsTheImageUntilAFrameIsAppended() throws {
        let first = try frame(top: 0)
        let stitcher = ScrollStitcher(firstFrame: first)
        #expect(stitcher.image === first)
        #expect(stitcher.pixelSize == CGSize(width: 8, height: 20))
    }

    @Test func testAWholeFrameGoesAtTheBottomAndWinsWhereItOverlaps() throws {
        var stitcher = ScrollStitcher(firstFrame: try frame(top: 0, tag: 1))
        // The page moved 6 rows, but only 5 are added, as the controller does:
        // the newer frame then covers one more row of the older one.
        stitcher.append(try frame(top: 6, tag: 2), newRows: 5, onlyNewRows: false)

        #expect(stitcher.pixelSize == CGSize(width: 8, height: 25))
        let expected = (0..<5).map { pageRow($0, tag: 1) } + (0..<20).map { pageRow(6 + $0, tag: 2) }
        #expect(try rows(of: stitcher.image) == expected)
    }

    @Test func testOnlyNewRowsKeepsAFrozenHeaderAtTheTopOnly() throws {
        var stitcher = ScrollStitcher(firstFrame: try frame(top: 0, tag: 1, headerRows: 4))
        stitcher.append(try frame(top: 5, tag: 2, headerRows: 4), newRows: 5, onlyNewRows: true)

        #expect(stitcher.pixelSize == CGSize(width: 8, height: 25))
        let firstFrame = (0..<20).map { $0 < 4 ? header : pageRow($0, tag: 1) }
        let newRows = (20..<25).map { pageRow($0, tag: 2) }
        #expect(try rows(of: stitcher.image) == firstFrame + newRows)
    }

    @Test func testRowCountsOutsideTheFrameChangeNothing() throws {
        let first = try frame(top: 0)
        var stitcher = ScrollStitcher(firstFrame: first)
        for newRows in [0, -1, 21] {
            stitcher.append(try frame(top: 3), newRows: newRows, onlyNewRows: false)
            stitcher.append(try frame(top: 3), newRows: newRows, onlyNewRows: true)
        }
        #expect(stitcher.image === first)
        #expect(stitcher.height == 20)
    }

    /// Strips of every size, a whole frame included, rebuild the page row for
    /// row in both modes when each frame moved by the rows it adds.
    @Test func testStripsOfAnySizeRebuildThePage() throws {
        for onlyNewRows in [false, true] {
            var top = 0
            var stitcher = ScrollStitcher(firstFrame: try frame(top: 0))
            for shift in [1, 7, 20, 13, 2, 19] {
                top += shift
                stitcher.append(try frame(top: top), newRows: shift, onlyNewRows: onlyNewRows)
            }
            #expect(stitcher.height == 20 + top)
            #expect(try rows(of: stitcher.image) == (0..<(20 + top)).map { pageRow($0) },
                    "onlyNewRows: \(onlyNewRows)")
        }
    }
}
