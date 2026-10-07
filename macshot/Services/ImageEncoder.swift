import Cocoa
import UniformTypeIdentifiers
import ImageIO

/// Shared image encoding with user-configurable format, quality, and resolution.
enum ImageEncoder {

    enum Format: String, CaseIterable, Sendable {
        case png = "png"
        case jpeg = "jpeg"
        case heic = "heic"
        case avif = "avif"

        nonisolated var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .avif: return "avif"
            }
        }

        nonisolated var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .avif: return UTType("public.avif") ?? .image
            }
        }

        nonisolated var hasQuality: Bool {
            switch self {
            case .png: return false
            case .jpeg, .heic, .avif: return true
            }
        }

        nonisolated var displayName: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .avif: return "AVIF"
            }
        }
    }

    static var format: Format {
        if let raw = UserDefaults.standard.string(forKey: "imageFormat"),
           let fmt = Format(rawValue: raw),
           isFormatAvailable(fmt) {
            return fmt
        }
        return .png
    }

    /// Lossy quality 0.0–1.0 (used for JPEG, HEIC and AVIF)
    static var quality: CGFloat {
        if let q = UserDefaults.standard.object(forKey: "imageQuality") as? Double {
            return q.isFinite ? CGFloat(max(0.1, min(1.0, q))) : 0.85
        }
        return 0.85
    }

    /// Whether to downscale Retina (2x) screenshots to standard (1x) resolution.
    static var downscaleRetina: Bool {
        UserDefaults.standard.bool(forKey: "downscaleRetina")
    }

    static var fileExtension: String { format.fileExtension }
    static var utType: UTType { format.utType }

    nonisolated static var availableFormats: [Format] {
        Format.allCases.filter { isFormatAvailable($0) }
    }

    nonisolated static func isFormatAvailable(_ format: Format) -> Bool {
        switch format {
        case .png, .jpeg, .heic:
            return true
        case .avif:
            // AVIF encoding is provided by ImageIO. Only offer it when ImageIO can write it.
            let identifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
            return identifiers.contains("public.avif")
        }
    }

    /// Owns immutable pixels and settings from the instant the user requests
    /// output. AppKit stays on the main actor; encoding can run on a worker.
    struct PreparedImage: Sendable {
        let image: HistoryImageSnapshot.Image
        let format: Format
        let quality: CGFloat
        let downscaleRetina: Bool

        @MainActor init(_ source: NSImage) throws {
            image = try HistoryImageSnapshot.Image(source)
            format = ImageEncoder.format
            quality = ImageEncoder.quality
            downscaleRetina = ImageEncoder.downscaleRetina
        }

        nonisolated func pixelsForEncoding() throws -> CGImage {
            let pixels = image.pixels
            guard downscaleRetina, Double(pixels.width) > image.pointSize.width,
                  Double(pixels.height) > image.pointSize.height else { return pixels }
            // Clamp before converting to Int; malformed point sizes must not
            // trap, overflow a row stride or allocate an enormous bitmap.
            let width = max(1, Int(min(Double(pixels.width), image.pointSize.width)))
            let height = max(1, Int(min(Double(pixels.height), image.pointSize.height)))
            return try HistoryImageSnapshot.Image.render(pixels, width: width, height: height)
        }

        nonisolated func encode() -> Data? {
            guard let pixels = try? pixelsForEncoding() else { return nil }
            return encode(pixels: pixels)
        }

        nonisolated func encode(pixels: CGImage) -> Data? {
            switch format {
            case .png: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.png", lossyQuality: nil)
            case .jpeg: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.jpeg", lossyQuality: quality)
            case .heic: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.heic", lossyQuality: quality)
            case .avif: return ImageEncoder.encodeWithCGImageDestination(cgImage: pixels, type: "public.avif", lossyQuality: quality)
            }
        }
    }

    static func encode(_ image: NSImage) -> Data? {
        (try? PreparedImage(image))?.encode()
    }

    /// Generic CGImageDestination encoder — embeds the source color profile.
    /// The CGImage already carries its display's ICC profile (e.g. Display P3).
    /// CGImageDestination embeds it automatically — no pixel conversion needed.
    nonisolated static func encodeWithCGImageDestination(cgImage: CGImage, type: String, lossyQuality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }

        var properties: [String: Any] = [:]
        if let q = lossyQuality {
            properties[kCGImageDestinationLossyCompressionQuality as String] = q
        }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: - Clipboard

    private static let clipboardGenerationLock = NSLock()
    private static var clipboardGeneration = 0

    /// No file URL: it points into our sandbox, which Teams/RDP/web apps prefer but can't read (#309, #393).
    /// Opt-in: also offer the configured format (e.g. AVIF) to apps that read it (#373).
    static var clipboardIncludesImageFormat: Bool {
        UserDefaults.standard.bool(forKey: "clipboardIncludesImageFormat")
    }

    static func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        let generation = beginClipboardCopy()
        let changeCount = pasteboard.changeCount
        let includeFormat = clipboardIncludesImageFormat
        guard let prepared = try? PreparedImage(image) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let representations = clipboardRepresentations(for: prepared, includeConfiguredFormat: includeFormat)
            guard !representations.isEmpty else { return }

            DispatchQueue.main.async {
                guard isCurrentClipboardCopy(generation), pasteboard.changeCount == changeCount else { return }
                writeImagePasteboard(pasteboard, representations: representations)
            }
        }
    }

    /// Pasteboard flavors in preference order. PNG and TIFF are always present
    /// so apps that only read those (Teams, browsers, RDP) keep working; the
    /// configured format goes first when opted in so apps that read it get the
    /// smaller file. Returns nothing only if PNG encoding fails.
    nonisolated static func clipboardRepresentations(for prepared: PreparedImage,
                                                     includeConfiguredFormat: Bool) -> [(type: NSPasteboard.PasteboardType, data: Data)] {
        guard let pixels = try? prepared.pixelsForEncoding(),
              let pngData = encodeWithCGImageDestination(cgImage: pixels, type: "public.png", lossyQuality: nil) else {
            return []
        }
        var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
        if includeConfiguredFormat, prepared.format != .png,
           let data = prepared.encode(pixels: pixels) {
            representations.append((NSPasteboard.PasteboardType(prepared.format.utType.identifier), data))
        }
        representations.append((.png, pngData))
        if let tiffData = encodeWithCGImageDestination(cgImage: pixels, type: "public.tiff", lossyQuality: nil) {
            representations.append((.tiff, tiffData))
        }
        return representations
    }

    private static func beginClipboardCopy() -> Int {
        clipboardGenerationLock.lock()
        defer { clipboardGenerationLock.unlock() }
        clipboardGeneration += 1
        return clipboardGeneration
    }

    private static func isCurrentClipboardCopy(_ generation: Int) -> Bool {
        clipboardGenerationLock.lock()
        defer { clipboardGenerationLock.unlock() }
        return generation == clipboardGeneration
    }

    static func writeImagePasteboard(
        _ pasteboard: NSPasteboard,
        representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    ) {
        pasteboard.clearContents()
        pasteboard.declareTypes(representations.map(\.type), owner: nil)
        for representation in representations {
            pasteboard.setData(representation.data, forType: representation.type)
        }
    }
}
