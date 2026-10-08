import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import macshot

/// Run with `make perf` to time scroll capture stitching in a release build. It
/// stitches strips until the image is as tall as the default height limit, as
/// auto-scroll does. The limits are about four times the times on an M-series
/// Mac, so they catch a large slowdown; the commit that set them gives the
/// measured times.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACSHOT_PERF"] == "1"))
struct PerformanceTests {

    /// A full-width capture of a 14-inch MacBook Pro display at 2x.
    static let frameWidth = 3024
    static let frameHeight = 1200
    /// The controller ignores a shift below a tenth of the frame height, so
    /// this is the smallest strip it stitches: the most steps to the limit.
    static let newRows = frameHeight / 10
    /// The preview width that the controller asks for at 2x.
    static let previewWidth = Int(ScrollCapturePreviewPanel.previewWidth) * 2

    @Test func stitchingToTheHeightLimit() throws {
        let limit = ScrollCaptureController.defaultMaxHeight
        let pixels = try #require(Self.framePixels())
        let clock = ContinuousClock()

        // A frozen header first: only the new rows are drawn. Then whole frames.
        for onlyNewRows in [true, false] {
            let stitcher = ScrollStitcher(firstFrame: try Self.frame(pixels), previewWidth: Self.previewWidth)
            var steps: [Duration] = []
            while stitcher.height < limit {
                let frame = try Self.frame(pixels)
                let start = clock.now
                stitcher.append(frame, newRows: Self.newRows, onlyNewRows: onlyNewRows)
                // The controller updates the preview after each strip.
                _ = stitcher.makePreview()
                steps.append(clock.now - start)
            }
            let finalStart = clock.now
            let image = try #require(stitcher.makeImage())
            let finalTime = clock.now - finalStart
            #expect(image.height == stitcher.height)

            let total = steps.reduce(Duration.zero, +)
            let lastTenth = steps.suffix(max(1, steps.count / 10))
            let nearLimit = lastTenth.reduce(Duration.zero, +) / lastTenth.count
            let slowest = steps.max() ?? .zero
            print("""
                stitch \(onlyNewRows ? "new rows" : "whole frames"): \(steps.count) strips \
                to \(Self.frameWidth)x\(stitcher.height) px in \(Self.ms(total)), \
                \(Self.ms(total / max(1, steps.count))) per strip, \(Self.ms(nearLimit)) near the limit, \
                slowest \(Self.ms(slowest)), final image \(Self.ms(finalTime)), \
                peak memory so far \(Self.peakResidentMegabytes()) MB
                """)
            #expect(total < .seconds(3), "total \(Self.ms(total))")
            #expect(nearLimit < .milliseconds(15), "near the limit \(Self.ms(nearLimit))")
        }
    }

    /// Frame pixels as ScreenCaptureKit delivers them: premultiplied BGRA, opaque.
    private static func framePixels() -> CGDataProvider? {
        let bytesPerRow = frameWidth * 4
        let bytes = [UInt8](unsafeUninitializedCapacity: bytesPerRow * frameHeight) { buffer, count in
            for y in 0..<frameHeight {
                for x in 0..<frameWidth {
                    let offset = y * bytesPerRow + x * 4
                    buffer[offset] = UInt8(truncatingIfNeeded: x &+ y)
                    buffer[offset + 1] = UInt8(truncatingIfNeeded: x &* 3)
                    buffer[offset + 2] = UInt8(truncatingIfNeeded: y)
                    buffer[offset + 3] = 255
                }
            }
            count = bytesPerRow * frameHeight
        }
        return CGDataProvider(data: Data(bytes) as CFData)
    }

    /// A new image for each strip, as each capture is: Core Graphics cannot
    /// reuse what it cached for an earlier frame.
    private static func frame(_ pixels: CGDataProvider) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return try #require(CGImage(
            width: frameWidth, height: frameHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: frameWidth * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: pixels, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    /// The largest resident size of the test process so far.
    private static func peakResidentMegabytes() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Int(usage.ru_maxrss) / 1_048_576  // bytes on macOS
    }

    private static func ms(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.1f ms", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
    }
}
