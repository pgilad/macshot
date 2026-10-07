import Cocoa
import Testing
@testable import macshot

/// Captures and settings written by older builds must keep loading. Swift's
/// synthesized `init(from:)` demands a key for every non-optional property even
/// when it has a default, so before `LenientDecoding.swift` existed, adding one
/// field to a persisted model silently discarded every annotation in older
/// captures — and, for the history index, every entry at once.
final class LegacyDecodingTests {

    // MARK: - Annotations

    /// Exactly the fields `CodableAnnotation` required at its first version.
    private let oldestAnnotationJSON = """
    [{"tool":3,"startX":10,"startY":20,"endX":110,"endY":80,"colorRGBA":[1,0,0,1],"strokeWidth":4}]
    """

    @Test func testCaptureFromTheOldestFormatStillLoads() throws {
        let annotations = try #require(AnnotationSerializer.decode(Data(oldestAnnotationJSON.utf8)), "a capture written before later fields existed must still open with its annotations")
        #expect(annotations.count == 1)
        let ann = annotations[0]
        #expect(ann.tool == .rectangle)
        #expect(ann.startPoint == NSPoint(x: 10, y: 20))
        #expect(ann.endPoint == NSPoint(x: 110, y: 80))
        #expect(ann.strokeWidth == 4)
        // Fields that didn't exist yet fall back to today's defaults.
        #expect(ann.fontSize == 20)
        #expect(abs(ann.dimOpacity - (0.55)) <= 0.0001)
        #expect(ann.loupeMagnification == 2.0)
        #expect(ann.censorMode == .pixelate)
        #expect(ann.lineStyle == .solid)
    }

    @Test func testEveryFieldMayBeAbsentExceptTool() throws {
        let annotations = try #require(AnnotationSerializer.decode(Data("""
        [{"tool":0}]
        """.utf8)), "only the tool is genuinely required to draw an annotation")
        #expect(annotations.first?.tool == .pencil)
    }

    @Test func testAnnotationWithoutAToolIsSkipped() {
        #expect(AnnotationSerializer.decode(Data("""
        [{"startX":1,"startY":2,"endX":3,"endY":4,"colorRGBA":[0,0,0,1],"strokeWidth":1}]
        """.utf8)) == nil, "an annotation with no tool can't be drawn, so it's dropped")
    }

    @Test func testOneCorruptAnnotationDoesNotDiscardTheOthers() throws {
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":5,"endY":5,"colorRGBA":[1,0,0,1],"strokeWidth":1},
         {"tool":"not-a-number"},
         {"tool":3,"startX":9,"startY":9,"endX":19,"endY":19,"colorRGBA":[0,1,0,1],"strokeWidth":2}]
        """
        let annotations = try #require(AnnotationSerializer.decode(Data(json.utf8)))
        #expect(annotations.count == 2, "a corrupt entry should cost one annotation, not the whole capture")
        #expect(annotations.map(\.tool) == [.pencil, .rectangle])
    }

    @Test func testWrongTypedFieldFallsBackInsteadOfDiscardingTheAnnotation() throws {
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":5,"endY":5,"colorRGBA":[1,0,0,1],"strokeWidth":"thick",
          "fontSize":"big","isBold":"yes","rotation":null}]
        """
        let ann = try #require(AnnotationSerializer.decode(Data(json.utf8))?.first)
        #expect(ann.strokeWidth == 3, "a non-numeric stroke width falls back to the default")
        #expect(ann.fontSize == 20)
        #expect(!ann.isBold)
        #expect(ann.rotation == 0)
    }

    @Test func testUnknownFutureFieldsAreIgnored() throws {
        // A capture written by a newer build must still open in an older one.
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":5,"endY":5,"colorRGBA":[1,0,0,1],"strokeWidth":2,
          "somethingAddedLater":{"nested":true},"anotherNewField":[1,2,3]}]
        """
        let ann = try #require(AnnotationSerializer.decode(Data(json.utf8))?.first)
        #expect(ann.tool == .pencil)
        #expect(ann.strokeWidth == 2)
    }

    @Test func testTodaysFormatStillRoundTripsAfterTheLenientDecoder() throws {
        let ann = AnnotationPersistenceTests.fullyPopulated(tool: .arrow)
        let data = try #require(AnnotationSerializer.encode([ann]))
        let decoded = try #require(AnnotationSerializer.decode(data)?.first)
        #expect(decoded.arrowStyle == ann.arrowStyle)
        #expect(decoded.randomSeed == ann.randomSeed)
        #expect(abs(decoded.dimOpacity - (ann.dimOpacity)) <= 0.0001)
    }

    // MARK: - Capture edit state

    @Test func testEditStateFromAnOlderBuildStillLoads() throws {
        // Written before the blur/window-snap/custom-background fields existed.
        let json = """
        {"effectsPresetRaw":0,"effectsBrightness":0.2,"effectsContrast":1.1,
         "effectsSaturation":0.9,"effectsSharpness":0.3,"beautifyEnabled":true,
         "beautifyModeRaw":1,"beautifyStyleIndex":4,"beautifyPadding":64,
         "beautifyCornerRadius":16,"beautifyShadowRadius":30}
        """
        let state = try #require(try? JSONDecoder().decode(CaptureEditState.self, from: Data(json.utf8)), "beautify settings saved by an older build must survive an update")
        #expect(state.beautifyEnabled)
        #expect(state.beautifyStyleIndex == 4)
        #expect(state.beautifyPadding == 64)
        #expect(state.beautifyBackgroundBlur == 0, "a field added later takes its default")
        #expect(!state.beautifyIsWindowSnap)
        #expect(state.customBeautifyBackgroundPNG == nil)
        #expect(abs(state.effectsBrightness - (0.2)) <= 0.0001)
    }

    @Test func testEmptyEditStateObjectDecodesToDefaults() throws {
        let state = try #require(try? JSONDecoder().decode(CaptureEditState.self, from: Data("{}".utf8)))
        #expect(state == CaptureEditState())
    }

    @Test func testEditStateRoundTrips() throws {
        var state = CaptureEditState()
        state.beautifyEnabled = true
        state.beautifyStyleIndex = 7
        state.beautifyPadding = 100
        state.beautifyBackgroundBlur = 12
        state.effectsSaturation = 1.4
        state.customBeautifyBackgroundPNG = ImageProbe.quadrantImage(width: 8, height: 8)
            .tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CaptureEditState.self, from: data)
        #expect(decoded == state)
    }

    @Test func testEditStateBoundsValuesBeforePassingThemToRendering() throws {
        let data = Data("""
        {"effectsBrightness":3,"effectsContrast":-2,"effectsSaturation":5,"effectsSharpness":-1,
         "beautifyPadding":-10,"beautifyCornerRadius":-5,"beautifyShadowRadius":120,"beautifyBackgroundBlur":75}
        """.utf8)
        let state = try JSONDecoder().decode(CaptureEditState.self, from: data)
        #expect(state.effectsBrightness == 0.5)
        #expect(state.effectsContrast == 0.5)
        #expect(state.effectsSaturation == 2)
        #expect(state.effectsSharpness == 0)
        #expect(state.beautifyPadding == 0)
        #expect(state.beautifyCornerRadius == 0)
        #expect(state.beautifyShadowRadius == 100)
        #expect(state.beautifyBackgroundBlur == 50)
        var inMemory = CaptureEditState()
        inMemory.effectsBrightness = .nan
        inMemory.beautifyPadding = .infinity
        #expect(inMemory.effectsConfig.brightness == 0)
        #expect(inMemory.beautifyConfig().padding == 48)
        let overlay = OverlayView()
        overlay.applyCaptureEditState(inMemory)
        #expect(overlay.effectsBrightness == 0)
        #expect(overlay.beautifyPadding == 48)
    }

    // MARK: - History index

    @Test func testHistoryIndexRowsSurviveMissingAndCorruptFields() throws {
        // Row 1: oldest format. Row 2: corrupt. Row 3: current format.
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","fileExtension":"png","timestamp":0,"pixelWidth":100,"pixelHeight":50},
         {"nope":true},
         {"id":"00000000-0000-0000-0000-000000000003","fileExtension":"jpg","timestamp":1000,"pixelWidth":10,"pixelHeight":20,
          "hasAnnotations":true,"lastEditedAt":2000}]
        """
        let rows = try #require(LenientArrayDecoder.decode(ScreenshotHistory.IndexEntry.self, from: Data(json.utf8)), "one bad row must not wipe the user's whole capture history")
        #expect(rows.map(\.id) == ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000003"])
        #expect(rows[0].pixelWidth == 100)
        #expect(rows[0].hasAnnotations == nil)
        #expect(rows[1].hasAnnotations == true)
        #expect(rows[1].fileExtension == "jpg")
    }

    @Test func testHistoryRowMissingEverythingButIdStillLoads() throws {
        let rows = try #require(LenientArrayDecoder.decode(ScreenshotHistory.IndexEntry.self, from: Data("""
            [{"id":"00000000-0000-0000-0000-000000000004"}]
            """.utf8)))
        #expect(rows.count == 1)
        #expect(rows[0].fileExtension == "png", "a row with no extension falls back to the original format")
    }

    // MARK: - LenientArrayDecoder itself

    @Test func testLenientArrayDecoderReturnsNilForNonArrayData() {
        #expect(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data("{}".utf8)) == nil)
        #expect(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data("garbage".utf8)) == nil)
    }

    @Test func testLenientArrayDecoderReturnsNilWhenEveryElementIsCorrupt() {
        #expect(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data("[{},{},{}]".utf8)) == nil)
    }

    @Test func testLenientArrayDecoderKeepsOrder() throws {
        let json = "[" + (0..<5).map { #"{"tool":\#($0),"startX":\#($0)}"# }.joined(separator: ",") + "]"
        let decoded = try #require(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data(json.utf8)))
        #expect(decoded.map(\.tool) == [0, 1, 2, 3, 4])
    }
}
