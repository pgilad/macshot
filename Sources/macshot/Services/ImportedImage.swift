import Cocoa
import ImageIO
import UniformTypeIdentifiers

/// Images that the user brings in: Open Image and Finder, the clipboard, custom stamps,
/// paste in the editor and the custom beautify background.
///
/// A small file can declare a huge pixel size, and AppKit decodes the whole image the
/// first time it draws it. Creating the NSImage and reading the pixel size of its
/// representations only reads the header, so the size is checked before anything draws.
enum ImportedImage {
    enum Rejection: Error, Equatable {
        case unreadable
        case tooLarge(width: Int, height: Int)

        var message: String {
            switch self {
            case .unreadable:
                return "macshot cannot read this image."
            case .tooLarge(let width, let height):
                return "This image is too large to open in macshot (\(width) × \(height) pixels)."
            }
        }
    }

    /// The allocation limit of saved captures (`SavedCaptureValidation`) applies here too.
    static func checked(
        _ image: NSImage?,
        maximumPixels: Int = SavedCaptureValidation.maximumImagePixels
    ) -> Result<NSImage, Rejection> {
        guard let image, image.isValid else { return .failure(.unreadable) }
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return .failure(.unreadable)
        }
        // A vector image (PDF) has no pixels of its own; it draws at its point size.
        var largest = (width: Double(size.width), height: Double(size.height))
        for rep in image.representations {
            let width = Double(rep.pixelsWide), height = Double(rep.pixelsHigh)
            if width * height > largest.width * largest.height {
                largest = (width, height)
            }
        }
        // Doubles, so a crafted size cannot overflow the product.
        guard largest.width * largest.height <= Double(maximumPixels) else {
            return .failure(.tooLarge(width: Int(largest.width.rounded()), height: Int(largest.height.rounded())))
        }
        return .success(image)
    }

    /// The image at `url` as PNG data, scaled down so that its longer side is at most
    /// `maxPixelSize`. ImageIO scales while it decodes, so memory follows the output size.
    nonisolated static func downsampledPNGData(contentsOf url: URL, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: UTType.png.identifier, lossyQuality: nil)
    }
}
