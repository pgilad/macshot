import AppKit

enum ClipboardPinResult {
    case image(NSImage)
    /// The clipboard has an image that is too large (see `ImportedImage`). Its text, if
    /// any, is not pinned instead.
    case rejected(ImportedImage.Rejection)
    case unsupported
}

enum ClipboardPinService {

    static func image(
        from item: NSPasteboardItem,
        maximumPixels: Int = SavedCaptureValidation.maximumImagePixels
    ) -> ClipboardPinResult {
        switch imageFromItem(item, maximumPixels: maximumPixels) {
        case .success(let image):
            return .image(image)
        case .failure(let rejection) where rejection != .unreadable:
            return .rejected(rejection)
        case .failure:
            break
        }
        if let image = textImageFromItem(item) {
            return .image(image)
        }
        return .unsupported
    }

    /// The first usable image flavor. When none is usable, the first rejection that is
    /// not `.unreadable`, so a too-large image is reported.
    private static func imageFromItem(
        _ item: NSPasteboardItem,
        maximumPixels: Int
    ) -> Result<NSImage, ImportedImage.Rejection> {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
        ]

        var candidates: [() -> NSImage?] = imageTypes.compactMap { type in
            item.data(forType: type).map { data in { NSImage(data: data) } }
        }
        if let fileURL = fileURLFromItem(item) {
            candidates.append { NSImage(contentsOf: fileURL) }
        }

        var rejection = ImportedImage.Rejection.unreadable
        for candidate in candidates {
            switch ImportedImage.checked(candidate(), maximumPixels: maximumPixels) {
            case .success(let image):
                return .success(image)
            case .failure(let reason):
                if rejection == .unreadable { rejection = reason }
            }
        }
        return .failure(rejection)
    }

    /// Plain text only. Rich text and HTML are not read: their importers are
    /// large parsers, and the HTML one is WebKit.
    private static func textImageFromItem(_ item: NSPasteboardItem) -> NSImage? {
        guard let string = item.string(forType: .string),
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ClipboardTextPinRenderer.render(ClipboardTextPinRenderer.plainAttributedString(string))
    }

    private static func fileURLFromItem(_ item: NSPasteboardItem) -> URL? {
        if let value = item.string(forType: .fileURL),
           let url = URL(string: value),
           url.isFileURL {
            return url
        }

        let urlTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("NSURLPboardType"),
        ]
        for type in urlTypes {
            if let value = item.string(forType: type),
               let url = URL(string: value),
               url.isFileURL {
                return url
            }
        }

        return nil
    }

}
