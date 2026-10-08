import Cocoa
import Testing
import UniformTypeIdentifiers
@testable import macshot

/// A small file can declare a huge pixel size, and AppKit decodes the whole image the
/// first time it draws it. Images that the user brings in are checked before that.
final class ImportedImageTests {

    /// Imported images come from data, files or the pasteboard, so their representations
    /// are bitmaps decoded from data. (An NSImage made from a CGImage reports its pixel
    /// size times the screen scale.)
    private func importedImage(width: Int, height: Int) throws -> NSImage {
        try #require(NSImage(data: try pngData(width: width, height: height)))
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let image = ImageProbe.solidImage(width: width, height: height)
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try #require(ImageEncoder.encodeWithCGImageDestination(
            cgImage: pixels, type: UTType.png.identifier, lossyQuality: nil))
    }

    @Test func testAnImageWithinTheLimitIsAccepted() throws {
        let image = try importedImage(width: 40, height: 25)
        let accepted = try ImportedImage.checked(image, maximumPixels: 1000).get()
        #expect(accepted === image)
    }

    @Test func testAnImageOverTheLimitIsRejectedWithItsPixelSize() throws {
        let image = try importedImage(width: 40, height: 26)
        #expect(ImportedImage.checked(image, maximumPixels: 1000) == .failure(.tooLarge(width: 40, height: 26)))
    }

    @Test func testTheLargestRepresentationCountsNotThePointSize() throws {
        let image = try importedImage(width: 100, height: 100)
        image.size = NSSize(width: 10, height: 10)
        #expect(ImportedImage.checked(image, maximumPixels: 1000) == .failure(.tooLarge(width: 100, height: 100)))
    }

    @Test func testNoImageOrAnEmptyImageIsUnreadable() {
        #expect(ImportedImage.checked(nil) == .failure(.unreadable))
        #expect(ImportedImage.checked(NSImage(size: .zero)) == .failure(.unreadable))
    }

    @Test func testATooLargeClipboardImageIsReportedAndItsTextIsNotPinned() throws {
        let item = NSPasteboardItem()
        item.setData(try pngData(width: 40, height: 26), forType: .png)
        item.setString("a caption that came with the image", forType: .string)
        guard case .rejected(.tooLarge(width: 40, height: 26)) = ClipboardPinService.image(from: item, maximumPixels: 1000) else {
            Issue.record("a too-large image must be reported, not replaced by its text"); return
        }
        guard case .image = ClipboardPinService.image(from: item) else {
            Issue.record("the same image is pinnable within the limit"); return
        }
    }

    @Test func testTheCustomBackgroundIsStoredScaledDown() throws {
        let width = CustomBeautifyBackground.maximumPixelSize * 2
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try pngData(width: width, height: 10).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try withDefaults([CustomBeautifyBackground.defaultsKey: nil]) {
            _ = try CustomBeautifyBackground.store(contentsOf: url).get()
            let stored = try #require(UserDefaults.standard.data(forKey: CustomBeautifyBackground.defaultsKey))
            let rep = try #require(NSBitmapImageRep(data: stored))
            #expect(rep.pixelsWide == CustomBeautifyBackground.maximumPixelSize)
            #expect(rep.pixelsHigh == 5)
            #expect(CustomBeautifyBackground.load() != nil)
        }
    }
}
