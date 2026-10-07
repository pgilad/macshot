import Cocoa
import ImageIO
import Testing
@testable import macshot

/// Guards the three places an `Annotation` property has to be wired up:
/// the declaration, `clone()`, and `CodableAnnotation` (toCodable + fromCodable).
/// The compiler can't catch a field missing from the last two — annotations just
/// silently lose data on clone or history reload — so the census below does.
final class AnnotationPersistenceTests {

    /// How a property is expected to survive copying.
    enum Survival {
        /// Preserved by both `clone()` and a codable round-trip.
        case persisted
        /// Preserved by `clone()` only — legacy fields not written to history.
        case clonedOnly
        /// Deliberately dropped by both: caches and drawing-time scratch state.
        case transient
    }

    /// Every stored property of `Annotation`. Adding a property without adding
    /// it here fails `testPropertyCensusCoversEveryStoredProperty`.
    static let census: [String: Survival] = [
        // Core
        "tool": .persisted,
        "startPoint": .persisted,
        "endPoint": .persisted,
        "color": .persisted,
        "strokeWidth": .persisted,
        // Text
        "text": .persisted,
        "attributedText": .persisted,
        "fontSize": .persisted,
        "isBold": .persisted,
        "isItalic": .persisted,
        "isUnderline": .persisted,
        "isStrikethrough": .persisted,
        "textImage": .persisted,
        "textDrawRect": .persisted,
        "textBgColor": .persisted,
        "textOutlineColor": .persisted,
        "textGlyphStrokeColor": .persisted,
        "textAlignment": .persisted,
        "fontFamilyName": .persisted,
        // Number
        "number": .persisted,
        "numberFormat": .persisted,
        // Geometry
        "points": .persisted,
        "pressures": .persisted,
        "controlPoint": .persisted,
        "anchorPoints": .persisted,
        "rotation": .persisted,
        // Shape style
        "rectCornerRadius": .persisted,
        "lineStyle": .persisted,
        "arrowStyle": .persisted,
        "arrowReversed": .persisted,
        "rectFillStyle": .persisted,
        "outlineColor": .persisted,
        "isRounded": .clonedOnly,   // legacy flag, superseded by rectCornerRadius
        // Stamp
        "stampImage": .persisted,
        "isCaptureStamp": .persisted,
        // Censor / loupe
        "bakedBlurNSImage": .persisted,
        "censorMode": .persisted,
        "loupeMagnification": .persisted,
        "loupeSourceRect": .persisted,
        "loupeOutlineEnabled": .persisted,
        // Misc
        "measureInPoints": .persisted,
        "groupID": .persisted,
        "randomSeed": .persisted,
        "dimOpacity": .persisted,
        // Intentionally not copied
        "sourceImage": .transient,        // drawing-time reference, cleared after bake
        "sourceImageBounds": .transient,  // paired with sourceImage
        "outlineGlowImage": .transient,   // selection-highlight cache
        "outlineGlowRect": .transient,    // paired with outlineGlowImage
    ]

    // MARK: - Fixtures

    /// An annotation with every property set away from its default, so a
    /// dropped field shows up as a difference rather than a coincidence.
    static func fullyPopulated(tool: AnnotationTool = .rectangle) -> Annotation {
        let ann = Annotation(
            tool: tool,
            startPoint: NSPoint(x: 12.5, y: 34.25),
            endPoint: NSPoint(x: 210.75, y: 180.5),
            color: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.8),
            strokeWidth: 7.5
        )
        ann.text = "hello annotation"
        ann.attributedText = NSAttributedString(
            string: "hello annotation",
            attributes: [.font: NSFont.systemFont(ofSize: 18)]
        )
        ann.fontSize = 27.5
        ann.isBold = true
        ann.isItalic = true
        ann.isUnderline = true
        ann.isStrikethrough = true
        ann.textImage = ImageProbe.quadrantImage(width: 20, height: 16)
        // A committed text annotation's box always matches its corner points;
        // `reRenderTextImage()` re-syncs them, so an inconsistent fixture would
        // fail the round-trip for reasons that can't happen in the app.
        ann.textDrawRect = tool == .text
            ? NSRect(x: 12.5, y: 34.25, width: 198.25, height: 146.25)
            : NSRect(x: 3, y: 4, width: 120, height: 42)
        ann.textBgColor = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 0.5)
        ann.textOutlineColor = NSColor(srgbRed: 0.1, green: 0.9, blue: 0.3, alpha: 1)
        ann.textGlyphStrokeColor = NSColor(srgbRed: 0.3, green: 0.2, blue: 0.9, alpha: 0.75)
        ann.textAlignment = .right
        ann.fontFamilyName = "Helvetica"
        ann.number = 42
        ann.numberFormat = .roman
        ann.points = [NSPoint(x: 1, y: 2), NSPoint(x: 3.5, y: 4.25), NSPoint(x: 9, y: 11)]
        ann.pressures = [0.25, 0.5, 1.0]
        ann.controlPoint = NSPoint(x: 55, y: 66)
        ann.anchorPoints = [NSPoint(x: 0, y: 0), NSPoint(x: 10, y: 20), NSPoint(x: 30, y: 40)]
        ann.rotation = 0.7853981633974483  // 45°
        ann.rectCornerRadius = 12
        ann.lineStyle = .dotted
        ann.arrowStyle = .sketchy
        ann.arrowReversed = true
        ann.rectFillStyle = .strokeAndFill
        ann.outlineColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        ann.isRounded = true
        ann.stampImage = ImageProbe.quadrantImage(width: 32, height: 32)
        ann.isCaptureStamp = true
        ann.bakedBlurNSImage = ImageProbe.quadrantImage(width: 24, height: 24)
        ann.censorMode = .erase
        ann.loupeMagnification = 3.5
        ann.loupeSourceRect = NSRect(x: 5, y: 6, width: 70, height: 70)
        ann.loupeOutlineEnabled = true
        ann.measureInPoints = true
        ann.groupID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        ann.randomSeed = 123_456_789
        ann.dimOpacity = 0.42
        // Transient fields set too, to prove they're dropped on purpose.
        ann.sourceImage = ImageProbe.solidImage()
        ann.sourceImageBounds = NSRect(x: 1, y: 2, width: 3, height: 4)
        ann.outlineGlowImage = ImageProbe.solidImage()
        ann.outlineGlowRect = NSRect(x: 5, y: 6, width: 7, height: 8)
        return ann
    }

    // MARK: - Census

    @Test func testPropertyCensusCoversEveryStoredProperty() {
        let declared = Set(Reflect.propertyNames(of: Self.fullyPopulated()))
        let known = Set(Self.census.keys)

        let untracked = declared.subtracting(known).sorted()
        #expect(untracked.isEmpty, """
            New Annotation propert\(untracked.count == 1 ? "y" : "ies") \(untracked.joined(separator: ", ")) \
            found. Wire each one into clone(), CodableAnnotation (toCodable + fromCodable), \
            then set it in AnnotationPersistenceTests.fullyPopulated() and add it to the census.
            """)

        let stale = known.subtracting(declared).sorted()
        #expect(stale.isEmpty, "Census lists propert\(stale.count == 1 ? "y" : "ies") \(stale.joined(separator: ", ")) that no longer exist on Annotation.")
    }

    @Test func testFullyPopulatedFixtureLeavesNothingAtItsDefault() {
        // A property left at its default value would make the round-trip tests
        // pass even if the property were dropped entirely.
        let populated = Reflect.describedProperties(of: Self.fullyPopulated(tool: .rectangle))
        let fresh = Reflect.describedProperties(of: Annotation(
            tool: .pencil, startPoint: .zero, endPoint: .zero, color: .red, strokeWidth: 0))
        var unchanged: [String] = []
        for (name, value) in populated where fresh[name] == value {
            // randomSeed is random per instance; equality here would be a lottery win.
            if name == "randomSeed" { continue }
            unchanged.append(name)
        }
        #expect(unchanged.isEmpty, "fullyPopulated() leaves \(unchanged.sorted()) at the default value, so a dropped field wouldn't be noticed.")
    }

    // MARK: - clone()

    @Test func testCloneCopiesEveryClonedProperty() {
        let original = Self.fullyPopulated()
        let copy = original.clone()

        let originalProps = Reflect.describedProperties(of: original)
        let copyProps = Reflect.describedProperties(of: copy)

        for (name, survival) in Self.census {
            guard let expected = originalProps[name], let actual = copyProps[name] else {
                Issue.record("property \(name) missing from reflection")
                continue
            }
            switch survival {
            case .persisted, .clonedOnly:
                #expect(actual == expected, "clone() dropped or altered `\(name)`")
            case .transient:
                continue  // asserted below
            }
        }
    }

    @Test func testCloneDropsTransientCaches() {
        let copy = Self.fullyPopulated().clone()
        #expect(copy.outlineGlowImage == nil, "a clone must not inherit the selection-glow cache")
        #expect(copy.outlineGlowRect == .zero)
    }

    @Test func testCloneIsIndependentOfTheOriginal() {
        let original = Self.fullyPopulated()
        let copy = original.clone()
        copy.startPoint = NSPoint(x: -1, y: -1)
        copy.color = .black
        copy.points?.append(NSPoint(x: 99, y: 99))

        #expect(original.startPoint == NSPoint(x: 12.5, y: 34.25))
        #expect(original.points?.count == 3)
        #expect(FieldDescriber.describe(original.color) != FieldDescriber.describe(copy.color))
    }

    // MARK: - Codable round-trip

    @Test func testCodableRoundTripPreservesEveryPersistedProperty() {
        for tool in AnnotationTool.allCases {
            let original = Self.fullyPopulated(tool: tool)
            guard let data = AnnotationSerializer.encode([original]),
                  let decoded = AnnotationSerializer.decode(data)?.first else {
                Issue.record("round-trip failed for tool \(tool)")
                continue
            }

            let originalProps = Reflect.describedProperties(of: original)
            let decodedProps = Reflect.describedProperties(of: decoded)

            for (name, survival) in Self.census where survival == .persisted {
                // The loupe re-bakes from the editor's source image on load, so
                // its baked result is deliberately not written to history.
                if name == "bakedBlurNSImage" && tool == .loupe { continue }
                // Text annotations with a glyph stroke re-render their cached
                // image on decode (legacy stroke normalization), which also
                // resizes the box — covered by the stability test below.
                if (name == "textImage" || name == "textDrawRect") && tool == .text { continue }
                #expect(decodedProps[name] == originalProps[name], "codable round-trip dropped or altered `\(name)` for tool \(tool)")
            }
        }
    }

    /// Opening a capture from history, saving it, and opening it again must not
    /// keep changing the annotation. A field that shifts on every load drifts
    /// further with each round-trip.
    @Test func testRoundTripIsStableAcrossRepeatedSaves() throws {
        for tool in AnnotationTool.allCases {
            let original = Self.fullyPopulated(tool: tool)
            let firstInput = try #require(AnnotationSerializer.encode([original]))
            let first = try #require(AnnotationSerializer.decode(firstInput)?.first)
            let secondInput = try #require(AnnotationSerializer.encode([first]))
            let second = try #require(AnnotationSerializer.decode(secondInput)?.first)
            let thirdInput = try #require(AnnotationSerializer.encode([second]))
            let third = try #require(AnnotationSerializer.decode(thirdInput)?.first)

            let firstProps = Reflect.describedProperties(of: first)
            let secondProps = Reflect.describedProperties(of: second)
            let thirdProps = Reflect.describedProperties(of: third)

            for (name, survival) in Self.census where survival == .persisted {
                if name == "bakedBlurNSImage" && tool == .loupe { continue }
                #expect(secondProps[name] == firstProps[name], "`\(name)` changed on the second load for tool \(tool) — it drifts every time a capture is reopened")
                #expect(thirdProps[name] == secondProps[name], "`\(name)` keeps changing on each load for tool \(tool)")
            }
        }
    }

    @Test func testTextAnnotationWithoutGlyphStrokeKeepsItsBoxExactly() throws {
        let ann = Self.fullyPopulated(tool: .text)
        ann.textGlyphStrokeColor = nil  // no legacy stroke: nothing to re-render
        let decodedInput = try #require(AnnotationSerializer.encode([ann]))
        let decoded = try #require(AnnotationSerializer.decode(decodedInput)?.first)
        #expect(decoded.textDrawRect == ann.textDrawRect, "plain text must reload in exactly the same box")
    }

    @Test func testLoupeBakedImageIsNotPersisted() throws {
        let loupe = Self.fullyPopulated(tool: .loupe)
        let data = try #require(AnnotationSerializer.encode([loupe]))
        let decoded = try #require(AnnotationSerializer.decode(data)?.first)
        #expect(decoded.bakedBlurNSImage == nil, "loupe must re-bake from the editor's source image instead of restoring a stale bake")
    }

    @Test func testRoundTripSurvivesManyAnnotationsInOrder() {
        let annotations = AnnotationTool.allCases.map { Self.fullyPopulated(tool: $0) }
        guard let data = AnnotationSerializer.encode(annotations),
              let decoded = AnnotationSerializer.decode(data) else {
            Issue.record("serializer failed"); return
        }
        #expect(decoded.count == annotations.count)
        #expect(decoded.map(\.tool.rawValue) == annotations.map(\.tool.rawValue))
    }

    @Test func testMinimalAnnotationRoundTrips() {
        let ann = Annotation(tool: .pencil, startPoint: .zero, endPoint: NSPoint(x: 1, y: 1),
                             color: .red, strokeWidth: 3)
        guard let data = AnnotationSerializer.encode([ann]),
              let decoded = AnnotationSerializer.decode(data)?.first else {
            Issue.record("round-trip failed"); return
        }
        #expect(decoded.tool == .pencil)
        #expect(decoded.text == nil)
        #expect(decoded.points == nil)
        #expect(decoded.strokeWidth == 3)
    }

    // MARK: - Decoding hostile or legacy data

    @Test func testDecodeRejectsGarbageData() {
        #expect(AnnotationSerializer.decode(Data("not json".utf8)) == nil)
        #expect(AnnotationSerializer.decode(Data()) == nil)
    }

    @Test func testDecodeRejectsUnknownToolRawValue() throws {
        let unknownTool = AnnotationTool.allCases.count + 50
        let json = """
        [{"tool":\(unknownTool),"startX":0,"startY":0,"endX":1,"endY":1,"colorRGBA":[1,0,0,1],"strokeWidth":2}]
        """
        #expect(AnnotationSerializer.decode(Data(json.utf8)) == nil, "an annotation with a tool this build doesn't know must be skipped, not crash")
    }

    /// Tool raw values are written to history, `enabledTools` and `lastUsedTool`.
    /// Renumbering a case would reload old annotations as a different tool.
    @Test func testToolRawValuesNeverChange() {
        let expected: [AnnotationTool: Int] = [
            .pencil: 0, .line: 1, .arrow: 2, .rectangle: 3, .filledRectangle: 4,
            .ellipse: 5, .marker: 6, .text: 7, .number: 8, .pixelate: 9, .blur: 10,
            .measure: 11, .loupe: 12, .select: 13, .crop: 15, .colorSampler: 16,
            .stamp: 17, .highlight: 18,
        ]
        #expect(expected.count == AnnotationTool.allCases.count, "pin the raw value of every new tool here")
        for tool in AnnotationTool.allCases {
            #expect(tool.rawValue == expected[tool], "\(tool) changed its persisted raw value")
        }
        #expect(AnnotationTool(rawValue: 14) == nil, "14 belonged to the removed translate overlay")
    }

    @Test func testCaptureWithRemovedTranslateOverlayStillLoads() throws {
        let json = """
        [{"tool":14,"startX":0,"startY":0,"endX":40,"endY":12,"colorRGBA":[1,1,1,1],"strokeWidth":0,"text":"hola","fontSize":9},
         {"tool":3,"startX":5,"startY":5,"endX":20,"endY":20,"colorRGBA":[1,0,0,1],"strokeWidth":2}]
        """
        let decoded = try #require(AnnotationSerializer.decode(Data(json.utf8)))
        #expect(decoded.map(\.tool) == [.rectangle], "the removed tool is skipped, the rest of the capture loads")
        #expect(AnnotationSerializer.decode(Data(json.utf8), requireAll: true) == nil, "editable reopen must fall back to the flattened capture, which still shows the translation")
    }

    @Test func testDecodeSurvivesMalformedPointArrays() throws {
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":1,"endY":1,"colorRGBA":[1,0,0,1],"strokeWidth":2,
          "points":[[1,2],[3],[4,5,6],[7,8]],
          "anchorPoints":[[0,0],[1]],
          "controlPointXY":[9],
          "textDrawRect":[1,2,3],
          "loupeSourceRect":[1,2]}]
        """
        let decoded = try #require(AnnotationSerializer.decode(Data(json.utf8))?.first)
        #expect(decoded.points?.count == 2, "malformed point pairs should be dropped, not crash")
        #expect(decoded.anchorPoints?.count == 1)
        #expect(decoded.controlPoint == nil)
        #expect(decoded.textDrawRect == .zero)
        #expect(decoded.loupeSourceRect == nil)
    }

    @Test func testDecodeToleratesShortColorArray() throws {
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":1,"endY":1,"colorRGBA":[1,0],"strokeWidth":2}]
        """
        let decoded = try #require(AnnotationSerializer.decode(Data(json.utf8))?.first)
        #expect(decoded.color.cgColor.numberOfComponents > 0, "a truncated color must fall back, not crash")
    }

    @Test func testLegacyCaptureWithoutSeedGetsAFreshSeed() throws {
        let json = """
        [{"tool":2,"startX":0,"startY":0,"endX":10,"endY":10,"colorRGBA":[1,0,0,1],"strokeWidth":2,"randomSeed":0}]
        """
        let decoded = try #require(AnnotationSerializer.decode(Data(json.utf8))?.first)
        #expect(decoded.randomSeed != 0, "seed 0 means legacy data; a fresh seed keeps sketchy rendering deterministic")
    }

    @Test func testLegacyCaptureWithoutDimOpacityUsesDefault() throws {
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":10,"endY":10,"colorRGBA":[1,0,0,1],"strokeWidth":2}]
        """
        let decoded = try #require(AnnotationSerializer.decode(Data(json.utf8))?.first)
        #expect(abs(decoded.dimOpacity - (0.55)) <= 0.0001)
    }

    @Test func testDimOpacityIsClampedOnDecode() throws {
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":1,"endY":1,"colorRGBA":[1,0,0,1],"strokeWidth":2,"dimOpacity":7.5},
         {"tool":0,"startX":0,"startY":0,"endX":1,"endY":1,"colorRGBA":[1,0,0,1],"strokeWidth":2,"dimOpacity":-3}]
        """
        let decoded = try #require(AnnotationSerializer.decode(Data(json.utf8)))
        #expect(abs(decoded[0].dimOpacity - (1.0)) <= 0.0001, "dim over 1 would paint the capture black")
        #expect(abs(decoded[1].dimOpacity - (0.55)) <= 0.0001, "a negative dim falls back to the default")
    }

    @Test func testUnrepresentableCanvasGeometryIsRejectedBeforeRendering() throws {
        let json = """
        [{"tool":0,"startX":-1e18,"startY":1e18,"endX":1e18,"endY":-1e18,"colorRGBA":[1,0,0,1],"strokeWidth":1e9}]
        """
        #expect(AnnotationSerializer.decode(Data(json.utf8)) == nil)
    }

    @Test func testSavedValuesAreFiniteAndPressuresStayAligned() throws {
        var saved = CodableAnnotation(tool: AnnotationTool.pencil.rawValue,
            startX: 0, startY: 0, endX: 100, endY: 100, colorRGBA: [2, -1, 0.5, 3], strokeWidth: .nan)
        saved.fontSize = .infinity
        saved.rotation = .nan
        saved.loupeMagnification = .nan
        saved.points = [[1, 2], [3], [5, 6]]
        saved.pressures = [0.2, 0.7, 0.9]
        saved.textDrawRect = [0, 0, -1, 40]
        let annotation = try #require(Annotation.fromCodable(saved))
        #expect(annotation.strokeWidth == 3)
        #expect(annotation.fontSize == 20)
        #expect(annotation.rotation == 0)
        #expect(annotation.loupeMagnification == 2)
        #expect(annotation.pressures == [0.2, 0.9])
        #expect(annotation.textDrawRect == .zero)
        let color = try #require(annotation.color.usingColorSpace(.sRGB))
        #expect(color.redComponent == 1)
        #expect(color.greenComponent == 0)
        #expect(color.alphaComponent == 1)
    }

    @Test func testEditableDecodeRequiresEveryAnnotationButSalvageRemainsAvailable() throws {
        let first = CodableAnnotation(tool: AnnotationTool.rectangle.rawValue,
            startX: 0, startY: 0, endX: 100, endY: 100, colorRGBA: [1, 0, 0, 1], strokeWidth: 3)
        var second = first
        second.stampImagePNG = Data("unreadable image".utf8)
        let data = try JSONEncoder().encode([first, second])
        #expect(AnnotationSerializer.decode(data)?.count == 1)
        #expect(AnnotationSerializer.decode(data, requireAll: true) == nil)
        #expect(AnnotationSerializer.decode(Data("[]".utf8), requireAll: true)?.count == 0)
    }

    @Test func testEmbeddedImagePreservesRetinaSizeAndChecksPixelBudget() throws {
        let image = ImageProbe.quadrantImage(width: 32, height: 24)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        CGImageDestinationAddImage(destination, pixels,
            [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let restored = try #require(SavedCaptureValidation.image(data as Data))
        #expect(abs(restored.size.width - (16)) <= 0.01)
        #expect(abs(restored.size.height - (12)) <= 0.01)
        #expect(restored.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 32)
        #expect(SavedCaptureValidation.image(data as Data, maximumPixels: 100) == nil)
        #expect(SavedCaptureValidation.image(Data("unreadable".utf8)) == nil)
    }

    @Test func testTextRenderRefusesAnInvalidSizeBeforeChangingCachedImage() {
        let annotation = Self.fullyPopulated(tool: .text)
        let previous = annotation.textImage
        annotation.textDrawRect.size.width = .nan
        #expect(!annotation.reRenderTextImage())
        #expect(annotation.textImage === previous)
    }

    @Test func testEmptyArrayDecodesToNil() {
        let data = try? JSONEncoder().encode([CodableAnnotation]())
        #expect(AnnotationSerializer.decode(data ?? Data()) == nil, "an empty capture has no annotations to restore")
    }

    // MARK: - copyProperties (used by undo of a style/geometry edit)

    @Test func testCopyPropertiesRestoresStyleAndGeometry() {
        let source = Self.fullyPopulated(tool: .rectangle)
        let target = Annotation(tool: .rectangle, startPoint: .zero, endPoint: NSPoint(x: 1, y: 1),
                                color: .black, strokeWidth: 1)
        target.copyProperties(from: source)

        #expect(target.startPoint == source.startPoint)
        #expect(target.endPoint == source.endPoint)
        #expect(target.rotation == source.rotation)
        #expect(target.strokeWidth == source.strokeWidth)
        #expect(target.rectCornerRadius == source.rectCornerRadius)
        #expect(target.lineStyle == source.lineStyle)
        #expect(target.arrowStyle == source.arrowStyle)
        #expect(target.textAlignment == source.textAlignment)
        #expect(FieldDescriber.describe(target.color) == FieldDescriber.describe(source.color))
    }
}
