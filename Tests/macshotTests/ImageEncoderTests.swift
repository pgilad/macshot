import Cocoa
import UniformTypeIdentifiers
import Testing
@testable import macshot

/// Encoding is the last step before a capture reaches the user's disk or
/// clipboard, so a silent failure here loses the screenshot itself.
final class ImageEncoderTests {

    private func encode(format: ImageEncoder.Format, quality: Double? = nil,
                        downscale: Bool = false, image: NSImage) throws -> Data {
        var defaults: [String: Any?] = [
            "imageFormat": format.rawValue,
            "downscaleRetina": downscale,
        ]
        defaults["imageQuality"] = quality
        var data: Data?
        withDefaults(defaults) {
            data = ImageEncoder.encode(image)
        }
        return try #require(data, "\(format) produced no data")
    }

    // MARK: - Every format encodes something a decoder accepts

    @Test func testEveryAvailableFormatProducesADecodableImage() throws {
        let source = ImageProbe.quadrantImage(width: 64, height: 48)
        for format in ImageEncoder.availableFormats {
            let data = try encode(format: format, image: source)
            #expect(!data.isEmpty, "\(format) encoded to an empty file")

            let decoded = try #require(NSImage(data: data), "\(format) produced data macOS can't read back")
            let bitmap = try #require(ImageProbe.bitmap(from: decoded))
            #expect(bitmap.pixelsWide == 64, "\(format) changed the width")
            #expect(bitmap.pixelsHigh == 48, "\(format) changed the height")
        }
    }

    @Test func testUnavailableFormatsAreNeverOffered() {
        for format in ImageEncoder.Format.allCases where !ImageEncoder.availableFormats.contains(format) {
            #expect(!ImageEncoder.isFormatAvailable(format))
        }
        #expect(ImageEncoder.availableFormats.contains(.png), "PNG must always be available")
    }

    @Test func testFormatFallsBackToPNGForAnUnknownSetting() {
        withDefaults(["imageFormat": "tga-from-the-future"]) {
            #expect(ImageEncoder.format == .png)
            #expect(ImageEncoder.fileExtension == "png")
        }
    }

    @Test func testFileExtensionAndTypeMatchTheSelectedFormat() {
        let expected: [ImageEncoder.Format: (String, UTType)] = [
            .png: ("png", .png),
            .jpeg: ("jpg", .jpeg),
            .heic: ("heic", .heic),
        ]
        for (format, (ext, type)) in expected {
            withDefaults(["imageFormat": format.rawValue]) {
                #expect(ImageEncoder.fileExtension == ext)
                #expect(ImageEncoder.utType == type)
            }
        }
    }

    @Test func testOnlyLossyFormatsExposeAQualitySlider() {
        #expect(!ImageEncoder.Format.png.hasQuality, "PNG is lossless — showing a quality slider would be a lie")
        for format in ImageEncoder.Format.allCases where format != .png {
            #expect(format.hasQuality, "\(format) is a lossy codec and needs a quality control")
        }
    }

    // MARK: - PNG is exact

    @Test func testPNGPreservesPixelsExactly() throws {
        let source = ImageProbe.quadrantImage(width: 40, height: 40)
        let data = try encode(format: .png, image: source)
        let decoded = try #require(NSImage(data: data))

        // Probe coordinates count from the top: red is the bottom-left
        // quadrant, white the top-right one.
        let red = try #require(ImageProbe.pixelColor(decoded, x: 5, y: 35))
        #expect(abs(red.redComponent - (1)) <= 0.01)
        #expect(abs(red.greenComponent - (0)) <= 0.01)

        let white = try #require(ImageProbe.pixelColor(decoded, x: 35, y: 5))
        #expect(abs(white.redComponent - (1)) <= 0.01)
        #expect(abs(white.blueComponent - (1)) <= 0.01)
    }

    @Test func testPNGIgnoresTheQualitySetting() throws {
        let source = ImageProbe.quadrantImage()
        let low = try #require(NSImage(data: try encode(format: .png, quality: 0.1, image: source)))
        let high = try #require(NSImage(data: try encode(format: .png, quality: 1.0, image: source)))
        // Compare pixels rather than byte counts: PNG is lossless, so the
        // quality slider must not change what comes back, while file size can
        // legitimately differ by embedded metadata.
        #expect(FieldDescriber.describe(low) == FieldDescriber.describe(high), "PNG is lossless — quality must not change the image")
    }

    // MARK: - Quality

    @Test func testLowerQualityMakesSmallerJPEGs() throws {
        // A photo-ish gradient, since flat colors compress the same at any quality.
        let source = gradientImage(width: 120, height: 120)
        let low = try encode(format: .jpeg, quality: 0.1, image: source)
        let high = try encode(format: .jpeg, quality: 1.0, image: source)
        #expect(low.count < high.count, "the quality slider has to actually change the file size")
    }

    @Test func testQualityIsClampedToAUsableRange() {
        withDefaults(["imageQuality": 5.0]) { #expect(ImageEncoder.quality == 1.0) }
        withDefaults(["imageQuality": -2.0]) { #expect(ImageEncoder.quality == 0.1) }
        withDefaults(["imageQuality": nil]) { #expect(ImageEncoder.quality == 0.85) }
        withDefaults(["imageQuality": Double.nan]) { #expect(ImageEncoder.quality == 0.85) }
    }

    @Test func testPreparedImageOwnsPixelsFormatAndResolutionBeforeBackgroundEncoding() async throws {
        let image = retinaImage(logicalWidth: 20, logicalHeight: 15, scale: 2)
        var prepared: ImageEncoder.PreparedImage?
        try withDefaults(["imageFormat": "png", "imageQuality": 0.2, "downscaleRetina": true]) {
            prepared = try ImageEncoder.PreparedImage(image)
        }
        // Simulate the editor changing while a save panel/worker is pending.
        for representation in image.representations { image.removeRepresentation(representation) }
        image.size = NSSize(width: 5, height: 5)
        let replacement = ImageProbe.solidImage(width: 5, height: 5)
        for representation in replacement.representations { image.addRepresentation(representation) }
        let request = try #require(prepared)
        let data = try await MediaExportIO.perform { try #require(request.encode()) }
        #expect(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let decoded = try #require(NSImage(data: data))
        let bitmap = try #require(ImageProbe.bitmap(from: decoded))
        #expect(bitmap.pixelsWide == 20)
        #expect(bitmap.pixelsHigh == 15)
        let red = try #require(ImageProbe.pixelColor(decoded, x: 2, y: 12))
        #expect(abs(red.redComponent - (1)) <= 0.01)
        #expect(abs(red.greenComponent - (0)) <= 0.01)
    }

    @Test func testEveryAvailableFormatCanEncodePreparedPixelsOnAWorker() async throws {
        let source = ImageProbe.quadrantImage(width: 32, height: 24)
        for format in ImageEncoder.availableFormats {
            var prepared: ImageEncoder.PreparedImage?
            try withDefaults(["imageFormat": format.rawValue]) { prepared = try ImageEncoder.PreparedImage(source) }
            let request = try #require(prepared)
            let data = try await MediaExportIO.perform { try #require(request.encode()) }
            let decoded = try #require(NSImage(data: data), "Worker encoding failed for \(format)")
            #expect((try #require(ImageProbe.bitmap(from: decoded)).pixelsWide) == 32)
        }
    }

    // MARK: - Clipboard flavors (#309, #373, #393)

    private func clipboardTypes(format: ImageEncoder.Format, optIn: Bool) throws -> [NSPasteboard.PasteboardType] {
        var prepared: ImageEncoder.PreparedImage?
        try withDefaults(["imageFormat": format.rawValue]) {
            prepared = try ImageEncoder.PreparedImage(ImageProbe.quadrantImage(width: 16, height: 12))
        }
        let representations = ImageEncoder.clipboardRepresentations(for: try #require(prepared), includeConfiguredFormat: optIn)
        for representation in representations {
            #expect(NSImage(data: representation.data) != nil, "\(representation.type.rawValue) must decode")
        }
        return representations.map(\.type)
    }

    @Test func testClipboardDefaultsToPNGAndTIFFOnlyForEveryFormat() throws {
        for format in ImageEncoder.availableFormats {
            #expect((try clipboardTypes(format: format, optIn: false)) == [.png, .tiff], "\(format)")
        }
    }

    @Test func testClipboardOptInPutsConfiguredFormatFirstAndKeepsPNGAndTIFF() throws {
        for format in ImageEncoder.availableFormats where format != .png {
            let expected = NSPasteboard.PasteboardType(format.utType.identifier)
            #expect((try clipboardTypes(format: format, optIn: true)) == [expected, .png, .tiff], "\(format)")
        }
        #expect((try clipboardTypes(format: .png, optIn: true)) == [.png, .tiff], "PNG is never listed twice")
    }

    @Test func testClipboardWriteKeepsFlavorOrderAndDataWithoutAFileURL() throws {
        var prepared: ImageEncoder.PreparedImage?
        try withDefaults(["imageFormat": "jpeg"]) {
            prepared = try ImageEncoder.PreparedImage(ImageProbe.quadrantImage(width: 16, height: 12))
        }
        let representations = ImageEncoder.clipboardRepresentations(for: try #require(prepared), includeConfiguredFormat: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macshot.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("stale", forType: .string)
        ImageEncoder.writeImagePasteboard(pasteboard, representations: representations)
        // AppKit adds legacy aliases (e.g. "Apple PNG pasteboard type"); the UTIs keep our order.
        let utis = (pasteboard.types ?? []).filter { $0.rawValue.hasPrefix("public.") }
        #expect(utis == [NSPasteboard.PasteboardType("public.jpeg"), .png, .tiff])
        #expect(pasteboard.string(forType: .fileURL) == nil, "a sandbox file URL breaks Teams and RDP paste")
        for representation in representations {
            #expect(pasteboard.data(forType: representation.type) == representation.data)
        }
    }

    // MARK: - Retina downscaling

    @Test func testRetinaDownscaleHalvesATwoTimesCapture() throws {
        let retina = retinaImage(logicalWidth: 50, logicalHeight: 40, scale: 2)
        let bitmap = try #require(ImageProbe.bitmap(from: retina))
        #expect(bitmap.pixelsWide == 100, "fixture should be 2x")

        let data = try encode(format: .png, downscale: true, image: retina)
        let decodedInput = try #require(NSImage(data: data))
        let decoded = try #require(ImageProbe.bitmap(from: decodedInput))
        #expect(decoded.pixelsWide == 50)
        #expect(decoded.pixelsHigh == 40)
    }

    @Test func testRetinaDownscaleLeavesANonRetinaCaptureAlone() throws {
        let plain = ImageProbe.quadrantImage(width: 30, height: 20)
        let data = try encode(format: .png, downscale: true, image: plain)
        let decodedInput = try #require(NSImage(data: data))
        let decoded = try #require(ImageProbe.bitmap(from: decodedInput))
        #expect(decoded.pixelsWide == 30, "a 1x capture must not be shrunk further")
        #expect(decoded.pixelsHigh == 20)
    }

    @Test func testDownscaleOffKeepsEveryPixel() throws {
        let retina = retinaImage(logicalWidth: 50, logicalHeight: 40, scale: 2)
        let data = try encode(format: .png, downscale: false, image: retina)
        let decodedInput = try #require(NSImage(data: data))
        let decoded = try #require(ImageProbe.bitmap(from: decodedInput))
        #expect(decoded.pixelsWide == 100)
    }

    // MARK: - Degenerate input

    @Test func testEmptyImageDoesNotCrashTheEncoder() {
        let empty = NSImage(size: .zero)
        withDefaults(["imageFormat": "png"]) {
            // Either nil or empty data is acceptable; a crash is not.
            _ = ImageEncoder.encode(empty)
        }
    }

    @Test func testOnePixelImageEncodes() throws {
        let dot = ImageProbe.solidImage(width: 1, height: 1, color: CGColor(gray: 0, alpha: 1))
        let data = try encode(format: .png, image: dot)
        let decodedInput = try #require(NSImage(data: data))
        let decoded = try #require(ImageProbe.bitmap(from: decodedInput))
        #expect(decoded.pixelsWide == 1)
        #expect(decoded.pixelsHigh == 1)
    }

    @Test func testTransparencySurvivesPNGAndIsFlattenedByJPEG() throws {
        let transparent = ImageProbe.transparentImage(width: 10, height: 10)

        let png = try #require(NSImage(data: try encode(format: .png, image: transparent)))
        let pngPixel = try #require(ImageProbe.pixelColor(png, x: 5, y: 5))
        #expect(abs(pngPixel.alphaComponent - (0)) <= 0.01, "PNG must keep the alpha channel")

        let jpeg = try #require(NSImage(data: try encode(format: .jpeg, image: transparent)))
        let jpegPixel = try #require(ImageProbe.pixelColor(jpeg, x: 5, y: 5))
        #expect(abs(jpegPixel.alphaComponent - (1)) <= 0.01, "JPEG has no alpha, so it flattens")
    }

    // MARK: - Fixtures

    private func gradientImage(width: Int, height: Int) -> NSImage {
        ImageProbe.makeImage(width: width, height: height) { context in
            for x in 0..<width {
                for y in stride(from: 0, to: height, by: 4) {
                    context.setFillColor(CGColor(srgbRed: CGFloat(x) / CGFloat(width),
                                                 green: CGFloat(y) / CGFloat(height),
                                                 blue: CGFloat((x * y) % 255) / 255,
                                                 alpha: 1))
                    context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 4))
                }
            }
        }
    }

    /// An image whose pixel buffer is `scale`x its logical size — what a capture
    /// from a Retina display looks like.
    private func retinaImage(logicalWidth: Int, logicalHeight: Int, scale: Int) -> NSImage {
        let pixels = ImageProbe.quadrantImage(width: logicalWidth * scale, height: logicalHeight * scale)
        guard let cgImage = pixels.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return pixels }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: logicalWidth, height: logicalHeight))
        return image
    }
}
