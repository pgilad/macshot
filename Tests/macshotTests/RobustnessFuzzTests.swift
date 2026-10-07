import Cocoa
import Testing
@testable import macshot

/// Randomized passes over the paths that handle whatever a capture happens to
/// contain. They don't check exact values — they check that nothing traps,
/// hangs, or loses data, which is what actually breaks in the field when an
/// annotation lands somewhere unusual.
@MainActor
final class RobustnessFuzzTests {

    /// Fixed seed: a failure has to be reproducible from the test name alone.
    private var random = SeededGenerator(seed: 0xC0FFEE_D15_0DED)

    init() {
        random = SeededGenerator(seed: 0xC0FFEE_D15_0DED)
    }

    // MARK: - Random annotation

    private func randomPoint(spread: CGFloat = 2000) -> NSPoint {
        NSPoint(x: CGFloat.random(in: -spread...spread, using: &random),
                y: CGFloat.random(in: -spread...spread, using: &random))
    }

    private func randomAnnotation() -> Annotation {
        let tool = AnnotationTool.allCases.randomElement(using: &random) ?? .pencil
        let ann = Annotation(
            tool: tool,
            startPoint: randomPoint(),
            endPoint: randomPoint(),
            color: NSColor(srgbRed: .random(in: 0...1, using: &random),
                           green: .random(in: 0...1, using: &random),
                           blue: .random(in: 0...1, using: &random),
                           alpha: .random(in: 0...1, using: &random)),
            strokeWidth: .random(in: 0...400, using: &random))

        if Bool.random(using: &random) { ann.text = randomText() }
        if Bool.random(using: &random) { ann.number = Int.random(in: -50...5000, using: &random) }
        if Bool.random(using: &random) {
            ann.points = (0..<Int.random(in: 0...40, using: &random)).map { _ in randomPoint() }
        }
        if Bool.random(using: &random) {
            ann.anchorPoints = (0..<Int.random(in: 0...6, using: &random)).map { _ in randomPoint() }
        }
        if Bool.random(using: &random) { ann.controlPoint = randomPoint() }
        if Bool.random(using: &random) { ann.rotation = .random(in: -20...20, using: &random) }
        if Bool.random(using: &random) { ann.rectCornerRadius = .random(in: -10...200, using: &random) }
        if Bool.random(using: &random) { ann.fontSize = .random(in: 0...400, using: &random) }
        if Bool.random(using: &random) { ann.loupeMagnification = .random(in: -5...50, using: &random) }
        if Bool.random(using: &random) { ann.dimOpacity = .random(in: -1...5, using: &random) }
        if Bool.random(using: &random) {
            ann.loupeSourceRect = NSRect(origin: randomPoint(),
                                         size: CGSize(width: .random(in: -50...500, using: &random),
                                                      height: .random(in: -50...500, using: &random)))
        }
        if Bool.random(using: &random) { ann.textDrawRect = NSRect(origin: randomPoint(), size: CGSize(width: 120, height: 40)) }
        ann.lineStyle = LineStyle.allCases.randomElement(using: &random) ?? .solid
        ann.arrowStyle = ArrowStyle.allCases.randomElement(using: &random) ?? .single
        ann.rectFillStyle = RectFillStyle.allCases.randomElement(using: &random) ?? .stroke
        ann.numberFormat = NumberFormat.allCases.randomElement(using: &random) ?? .decimal
        ann.censorMode = CensorMode.allCases.randomElement(using: &random) ?? .pixelate
        return ann
    }

    private func randomText() -> String {
        let pieces = ["hello", "", "🎉👨‍👩‍👧‍👦", "line1\nline2", "\t tabbed", "العربية", "日本語",
                      String(repeating: "x", count: Int.random(in: 0...500, using: &random)),
                      "\"quoted\"", "back\\slash", "null\0byte"]
        return pieces.randomElement(using: &random) ?? ""
    }

    // MARK: - Passes

    @Test func testRandomAnnotationsSurviveASaveAndReload() throws {
        for iteration in 0..<300 {
            let original = randomAnnotation()
            guard let data = AnnotationSerializer.encode([original]) else {
                Issue.record("iteration \(iteration): encoding produced nothing for \(original.tool)")
                continue
            }
            guard let decoded = AnnotationSerializer.decode(data)?.first else {
                Issue.record("iteration \(iteration): \(original.tool) could not be read back")
                continue
            }
            #expect(decoded.tool == original.tool, "iteration \(iteration)")
            #expect(abs(decoded.startPoint.x - (original.startPoint.x)) <= 0.001)
            #expect((decoded.points?.count ?? 0) == (original.points?.count ?? 0))
            // Values that must stay inside their documented range whatever went in.
            #expect((0...1).contains(decoded.dimOpacity), "iteration \(iteration): dim \(decoded.dimOpacity)")
        }
    }

    @Test func testRandomAnnotationsCloneFaithfully() {
        for iteration in 0..<300 {
            let original = randomAnnotation()
            let copy = original.clone()
            let originalProps = Reflect.describedProperties(of: original)
            let copyProps = Reflect.describedProperties(of: copy)
            for (name, survival) in AnnotationPersistenceTests.census
            where survival == .persisted || survival == .clonedOnly {
                #expect(copyProps[name] == originalProps[name], "iteration \(iteration): clone lost `\(name)` for \(original.tool)")
            }
        }
    }

    @Test func testRandomAnnotationsDrawWithoutTrapping() {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 180)
        view.screenshotImage = ImageProbe.quadrantImage(width: 240, height: 180)

        for iteration in 0..<200 {
            view.annotations = [randomAnnotation()]
            view.cachedCompositedImage = nil
            #expect(view.compositedImage() != nil, "iteration \(iteration) failed to render")
        }
    }

    @Test func testRandomAnnotationsHitTestAndMoveWithoutTrapping() {
        for _ in 0..<500 {
            let ann = randomAnnotation()
            _ = ann.hitTest(point: randomPoint())
            _ = ann.boundingRect
            ann.move(dx: .random(in: -500...500, using: &random), dy: .random(in: -500...500, using: &random))
            #expect(ann.boundingRect.origin.x.isFinite, "moving produced a non-finite box")
        }
    }

    @Test func testRandomFilenameTemplatesAlwaysProduceAUsableName() {
        let fragments = ["{date}", "{time}", "{window}", "{index}", "{random}", "{unix}", "{nope}",
                         "/", ":", "..", "\0", "\n", "  ", "🎉", "a", String(repeating: "z", count: 300)]
        for _ in 0..<500 {
            let template = (0..<Int.random(in: 0...6, using: &random))
                .compactMap { _ in fragments.randomElement(using: &random) }
                .joined()
            let name = FilenameFormatter.format(
                template: template,
                windowTitle: Bool.random(using: &random) ? randomText() : nil,
                index: Bool.random(using: &random) ? Int.random(in: 0...99, using: &random) : nil)

            #expect(!name.isEmpty, "template \(template.debugDescription) produced no filename")
            #expect(!name.contains("/"), "template \(template.debugDescription) produced a path separator")
            #expect(!name.contains("\0"))
            #expect(name.utf8.count <= 200)
            #expect(name == name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test func testRandomTextIsNeverMisreadAsACredential() {
        // Guard against a pattern so loose that ordinary words get covered.
        let words = ["report", "screenshot", "version", "2026", "hello world", "Chapter 3",
                     "Total: 42", "v4.2.1", "step 1 of 3", "€19.99"]
        for _ in 0..<200 {
            let text = (0..<Int.random(in: 1...4, using: &random))
                .compactMap { _ in words.randomElement(using: &random) }
                .joined(separator: " ")
            let matches = AutoRedactor.sensitiveMatches(in: text, enabledTypes: nil)
            #expect(matches.isEmpty, "\"\(text)\" was redacted as \(matches.map(\.name))")
        }
    }

    @Test func testRandomJSONDoesNotCrashTheAnnotationDecoder() {
        let fragments = ["{}", "[]", "null", "\"tool\"", "{\"tool\":0}", "{\"tool\":\"x\"}",
                         "{\"points\":[[1]]}", "{\"colorRGBA\":[]}", "1e400", "-0", "\u{FFFD}"]
        for _ in 0..<500 {
            let body = (0..<Int.random(in: 1...5, using: &random))
                .compactMap { _ in fragments.randomElement(using: &random) }
                .joined(separator: ",")
            _ = AnnotationSerializer.decode(Data("[\(body)]".utf8))
            _ = AnnotationSerializer.decode(Data(body.utf8))
        }
    }

    @Test func testRandomHistoryIndexRowsDecodeOrAreSkipped() {
        let fragments = ["{\"id\":\"00000000-0000-0000-0000-000000000001\"}", "{}", "null", "[]", "{\"id\":123}",
                         "{\"id\":\"00000000-0000-0000-0000-000000000002\",\"pixelWidth\":\"wide\"}", "\"string\""]
        for _ in 0..<300 {
            let body = (0..<Int.random(in: 1...4, using: &random))
                .compactMap { _ in fragments.randomElement(using: &random) }
                .joined(separator: ",")
            let rows = LenientArrayDecoder.decode(ScreenshotHistory.IndexEntry.self, from: Data("[\(body)]".utf8))
            for row in rows ?? [] {
                #expect(UUID(uuidString: row.id) != nil, "a row must name a capture UUID")
            }
        }
    }
}

/// Deterministic RNG so a failing fuzz run reproduces exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}
