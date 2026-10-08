import Cocoa
import Vision

/// Handles PII auto-redaction: regex pattern matching + Vision OCR to find sensitive text,
/// creates redaction annotations (filled rect, blur, or pixelate).
enum AutoRedactor {

    // MARK: - Sensitive patterns

    static let redactTypeNames: [(key: String, label: String)] = [
        ("email", "Emails"),
        ("phone", "Phone Numbers"),
        ("ssn", "SSN"),
        ("credit_card", "Credit Cards"),
        ("cvv", "CVV Codes"),
        ("expiry", "Expiry Dates"),
        ("ipv4", "IP Addresses"),
        ("aws_key", "AWS Keys"),
        ("secret_assignment", "Secrets/Tokens"),
        ("hex_key", "Hex Keys"),
        ("bearer", "Bearer Tokens"),
    ]

    private static let sensitivePatterns: [(name: String, pattern: NSRegularExpression)] = {
        let patterns: [(String, String)] = [
            ("email", #"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#),
            ("phone", #"(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}"#),
            ("ssn", #"\b\d{3}[-\s]\d{2}[-\s]\d{4}\b"#),
            ("credit_card", #"\d{4}[-\s]*\d{4}[-\s]*\d{4}[-\s]*\d{1,7}"#),
            ("credit_card", #"\d{4}[-\s]*\d{6}[-\s]*\d{5}"#),
            // Space-separated card groups that the two patterns above miss.
            // Three groups minimum, four digits each: two groups of three
            // digits matched things like "2026 2026", "1024 768" and
            // "Total 1234 5678", covering ordinary content with a black box.
            // Cards split across adjacent OCR observations are also checked by
            // PIIRedactionPlanner, using the same patterns and enabled types.
            ("credit_card", #"\d{4,6}(?:\s+\d{4,6}){2,4}"#),
            ("cvv", #"(?:CVV|CVC|CSC|CCV)\s*:?\s*\d{3,4}"#),
            ("expiry", #"\b(?:\d{2}[/\-]\d{2,4}|\d{4}[/\-]\d{2})\b"#),
            ("ipv4", #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
            ("aws_key", #"\b(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b"#),
            ("secret_assignment", #"(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)\s*[:=]\s*\S+"#),
            ("hex_key", #"\b[0-9a-fA-F]{32,}\b"#),
            ("bearer", #"Bearer\s+[A-Za-z0-9\-._~+/]+=*"#),
        ]
        return patterns.compactMap { (name, pat) in
            guard let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return nil }
            return (name, regex)
        }
    }()

    /// Ranges of `text` that match an enabled sensitive pattern, with the name
    /// of the pattern that matched. This is the whole of the regex layer: OCR
    /// hands it a recognized line, and every range that comes back gets covered.
    ///
    /// `enabledTypes` defaults to the user's selection in settings; nil means
    /// every pattern is active.
    static func sensitiveMatches(
        in text: String,
        enabledTypes: [String]? = UserDefaults.standard.array(forKey: "enabledRedactTypes") as? [String]
    ) -> [(name: String, range: Range<String.Index>)] {
        let active = sensitivePatterns.filter { enabledTypes == nil || enabledTypes!.contains($0.name) }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var found: [(name: String, range: Range<String.Index>)] = []
        for (name, regex) in active {
            for match in regex.matches(in: text, options: [], range: fullRange) {
                guard let range = Range(match.range, in: text) else { continue }
                found.append((name, range))
            }
        }
        return found
    }

    /// Whether any enabled pattern matches — the question a redaction pass asks
    /// of each OCR line.
    static func containsSensitiveText(_ text: String, enabledTypes: [String]? = nil) -> Bool {
        !sensitiveMatches(in: text, enabledTypes: enabledTypes).isEmpty
    }

    // MARK: - Public API

    /// Redact PII patterns in the selected region. Runs OCR off the main thread, calls completion with annotations.
    static func redactPII(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect,
        completion: @escaping ([Annotation]) -> Void
    ) {
        let enabledTypes = UserDefaults.standard.array(forKey: "enabledRedactTypes") as? [String]
        redact(screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
               redactTool: redactTool, color: color, sourceImage: sourceImage,
               sourceImageBounds: sourceImageBounds, padding: 2, completion: completion) { cgImage in
            let observations = await VisionOCR.recognizeText(in: cgImage)
            return piiBoxes(in: observations, selectionSize: selectionRect.size, enabledTypes: enabledTypes)
        }
    }

    /// Redact ALL text in the selected region (not just PII). Runs OCR, calls completion with annotations.
    static func redactAllText(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect,
        completion: @escaping ([Annotation]) -> Void
    ) {
        redact(screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
               redactTool: redactTool, color: color, sourceImage: sourceImage,
               sourceImageBounds: sourceImageBounds, padding: 2, completion: completion) { cgImage in
            await VisionOCR.recognizeText(in: cgImage).map(\.boundingBox)
        }
    }

    // MARK: - Face redaction

    /// Detect faces in the selected region and create blur/pixelate/filled-rect annotations over each face.
    static func redactFaces(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect,
        completion: @escaping ([Annotation]) -> Void
    ) {
        redact(screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
               redactTool: redactTool, color: color, sourceImage: sourceImage,
               sourceImageBounds: sourceImageBounds, padding: 4, completion: completion) { cgImage in
            await detectFaces(in: cgImage)
        }
    }

    /// Detect human bodies in the selected region and create blur/pixelate/filled-rect annotations over each person.
    static func redactPeople(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect,
        completion: @escaping ([Annotation]) -> Void
    ) {
        redact(screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
               redactTool: redactTool, color: color, sourceImage: sourceImage,
               sourceImageBounds: sourceImageBounds, padding: 4, completion: completion) { cgImage in
            await detectPeople(in: cgImage)
        }
    }

    // MARK: - Helpers

    /// Finds the boxes to cover in the selection and turns them into one
    /// undo group of redactions. `findBoxes` returns normalized Vision boxes
    /// (0…1, origin bottom-left of the selection). The Vision work runs off
    /// the main thread; the annotations are made on the main actor, which owns
    /// them. `completion` always runs on the main actor. Internal so that tests can pass
    /// `findBoxes`.
    static func redact(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect,
        padding: CGFloat,
        completion: @escaping ([Annotation]) -> Void,
        findBoxes: @escaping (CGImage) async -> [CGRect]
    ) {
        let cgImage = cropToCGImage(screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect)
        guard let cgImage = cgImage else { completion([]); return }
        // The same default as the censor tool: solid, because pixelated or blurred text
        // can sometimes be read back.
        let censorMode = CensorMode.current

        Task {
            let boxes = await findBoxes(cgImage)
            let groupID = UUID()
            let annotations = boxes.map { box in
                let viewX = selectionRect.origin.x + box.origin.x * selectionRect.width - padding
                let viewY = selectionRect.origin.y + box.origin.y * selectionRect.height - padding
                let viewW = box.width * selectionRect.width + padding * 2
                let viewH = box.height * selectionRect.height + padding * 2
                let ann = Annotation(tool: redactTool,
                    startPoint: NSPoint(x: viewX, y: viewY),
                    endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                    color: color, strokeWidth: 0)
                ann.groupID = groupID
                if redactTool == .rectangle { ann.rectFillStyle = .fill } else if redactTool == .blur || redactTool == .pixelate {
                    ann.sourceImage = sourceImage
                    ann.sourceImageBounds = sourceImageBounds
                }
                ann.censorMode = censorMode
                ann.bakePixelate()
                return ann
            }
            completion(annotations)
        }
    }

    @concurrent
    private nonisolated static func detectFaces(in cgImage: CGImage) async -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    @concurrent
    private nonisolated static func detectPeople(in cgImage: CGImage) async -> [CGRect] {
        let request = VNDetectHumanRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    private static func cropToCGImage(screenshot: NSImage, selectionRect: NSRect, captureDrawRect: NSRect) -> CGImage? {
        let regionImage = NSImage(size: selectionRect.size, flipped: false) { _ in
            screenshot.draw(in: NSRect(x: -selectionRect.origin.x, y: -selectionRect.origin.y,
                                        width: captureDrawRect.width, height: captureDrawRect.height),
                            from: .zero, operation: .copy, fraction: 1.0)
            return true
        }
        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.cgImage
    }

    /// Normalized boxes of the sensitive text in the recognized lines.
    private static func piiBoxes(
        in observations: [OCRTextObservation],
        selectionSize: NSSize,
        enabledTypes: [String]?
    ) -> [CGRect] {
        let lines = observations.map { observation in
            let box = observation.boundingBox
            return PIIRedactionPlanner.Line(text: observation.text,
                bounds: CGRect(x: box.minX * selectionSize.width, y: box.minY * selectionSize.height,
                               width: box.width * selectionSize.width, height: box.height * selectionSize.height))
        }
        return PIIRedactionPlanner.matches(in: lines, enabledTypes: enabledTypes).map { match in
            let observation = observations[match.lineIndex]
            // If Vision can't return a substring box, cover the recognized line
            // rather than silently leaving detected sensitive text exposed.
            return observation.boundingBox(for: match.range) ?? observation.boundingBox
        }
    }
}
