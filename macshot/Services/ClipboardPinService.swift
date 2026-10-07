import AppKit

enum ClipboardPinResult {
    case image(NSImage)
    case unsupported
}

enum ClipboardPinService {

    static func image(from item: NSPasteboardItem) -> ClipboardPinResult {
        if let image = imageFromItem(item) {
            return .image(image)
        }
        if let image = textImageFromItem(item) {
            return .image(image)
        }
        return .unsupported
    }

    private static func imageFromItem(_ item: NSPasteboardItem) -> NSImage? {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
        ]

        for type in imageTypes {
            guard let data = item.data(forType: type),
                  let image = NSImage(data: data),
                  isUsable(image) else { continue }
            return image
        }

        if let fileURL = fileURLFromItem(item),
           let image = NSImage(contentsOf: fileURL),
           isUsable(image) {
            return image
        }

        return nil
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

    private static func isUsable(_ image: NSImage) -> Bool {
        image.isValid && image.size.width.isFinite && image.size.height.isFinite
            && image.size.width > 0 && image.size.height > 0
    }
}
