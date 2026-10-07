import Cocoa
import Testing
@testable import macshot

/// The overlay canvas is the surface every annotation is drawn on. It builds
/// and draws fine without a window, so the coordinate rules and the undo stack
/// — the two things that quietly corrupt a capture when they're wrong — can be
/// tested directly.
@MainActor
final class OverlayCanvasTests {

    private func makeOverlay(width: CGFloat = 400, height: CGFloat = 300) -> OverlayView {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.screenshotImage = ImageProbe.quadrantImage(width: Int(width), height: Int(height))
        return view
    }

    private func annotation(_ tool: AnnotationTool = .rectangle,
                            from start: NSPoint = NSPoint(x: 10, y: 10),
                            to end: NSPoint = NSPoint(x: 100, y: 80)) -> Annotation {
        Annotation(tool: tool, startPoint: start, endPoint: end, color: .red, strokeWidth: 3)
    }

    // MARK: - Coordinate rules

    @Test func testCaptureDrawRectIsTheWholeViewInOverlayMode() {
        let view = makeOverlay()
        #expect(!view.isEditorMode)
        #expect(view.captureDrawRect == view.bounds, "the overlay draws the screenshot across the whole screen")
    }

    @Test func testCanvasAndViewCoordinatesAgreeAtDefaultZoom() {
        let view = makeOverlay()
        let point = NSPoint(x: 123.5, y: 67.25)
        #expect(view.viewToCanvas(point) == point)
        #expect(view.canvasToView(point) == point)
    }

    @Test func testCoordinateConversionRoundTripsWhileZoomed() {
        let view = makeOverlay()
        view.zoomLevel = 2.5
        view.zoomAnchorCanvas = NSPoint(x: 120, y: 90)
        view.zoomAnchorView = NSPoint(x: 200, y: 150)

        for point in [NSPoint(x: 0, y: 0), NSPoint(x: 200, y: 150),
                      NSPoint(x: 399, y: 299), NSPoint(x: -40, y: 500)] {
            let roundTripped = view.canvasToView(view.viewToCanvas(point))
            #expect(abs(roundTripped.x - (point.x)) <= 0.0001, "x drifted for \(point)")
            #expect(abs(roundTripped.y - (point.y)) <= 0.0001, "y drifted for \(point)")
        }
    }

    @Test func testTheZoomAnchorStaysPutWhileZooming() {
        let view = makeOverlay()
        let anchorCanvas = NSPoint(x: 50, y: 60)
        let anchorView = NSPoint(x: 150, y: 160)
        view.zoomAnchorCanvas = anchorCanvas
        view.zoomAnchorView = anchorView

        for zoom in [1.0, 1.5, 4.0, 8.0] as [CGFloat] {
            view.zoomLevel = zoom
            let mapped = view.canvasToView(anchorCanvas)
            #expect(abs(mapped.x - (anchorView.x)) <= 0.0001, "anchor moved at \(zoom)x")
            #expect(abs(mapped.y - (anchorView.y)) <= 0.0001, "anchor moved at \(zoom)x")
        }
    }

    @Test func testZoomingScalesDistancesFromTheAnchor() {
        let view = makeOverlay()
        view.zoomAnchorCanvas = NSPoint(x: 100, y: 100)
        view.zoomAnchorView = NSPoint(x: 100, y: 100)
        view.zoomLevel = 2

        let mapped = view.canvasToView(NSPoint(x: 150, y: 100))
        #expect(abs(mapped.x - (200)) <= 0.0001, "50pt from the anchor should land 100pt away at 2x")
    }

    @Test func testClearingTheZoomAnchorsReturnsToIdentity() {
        let view = makeOverlay()
        view.zoomLevel = 3
        view.zoomAnchorCanvas = NSPoint(x: 10, y: 20)
        view.zoomAnchorView = NSPoint(x: 30, y: 40)

        view.zoomLevel = 1
        view.zoomAnchorCanvas = .zero
        view.zoomAnchorView = .zero

        let point = NSPoint(x: 77, y: 88)
        #expect(view.viewToCanvas(point) == point)
        #expect(view.canvasToView(point) == point)
    }

    // MARK: - Composited output

    @Test func testCompositedImageMatchesTheCaptureRectNotTheViewBounds() throws {
        let view = makeOverlay(width: 420, height: 260)
        let image = try #require(view.compositedImage())
        #expect(image.size == view.captureDrawRect.size)
    }

    @Test func testCompositedImageIncludesAnnotations() throws {
        let view = makeOverlay(width: 200, height: 200)
        let before = try #require(view.compositedImage())

        let redaction = annotation(.filledRectangle, from: NSPoint(x: 0, y: 0), to: NSPoint(x: 200, y: 200))
        redaction.color = .black
        view.annotations.append(redaction)
        view.cachedCompositedImage = nil
        let after = try #require(view.compositedImage())

        #expect(FieldDescriber.describe(after) != FieldDescriber.describe(before), "an annotation covering the whole capture has to change the output")
    }

    @Test func testCompositedImageIsStableWhenNothingChanges() throws {
        let view = makeOverlay(width: 120, height: 90)
        view.annotations.append(annotation(.arrow))
        let first = try #require(view.compositedImage())
        let second = try #require(view.compositedImage())
        #expect(FieldDescriber.describe(first) == FieldDescriber.describe(second))
    }

    // MARK: - Undo / redo

    @Test func testSavedUndoIdentitySurvivesRedoButNotADifferentEditAtTheSameDepth() {
        let view = makeOverlay()
        let first = annotation(.arrow)
        view.annotations.append(first)
        view.undoStack.append(.added(first))
        let saved = view.undoStateIdentity
        view.undo()
        #expect(view.undoStateIdentity != saved)
        view.redo()
        #expect(view.undoStateIdentity == saved)
        view.undo()
        let replacement = annotation(.ellipse)
        view.annotations.append(replacement)
        view.undoStack.append(.added(replacement))
        view.redoStack.removeAll()
        #expect(view.undoStack.count == 1)
        #expect(view.undoStateIdentity != saved)
        let branch = view.undoStateIdentity
        view.undo()
        view.redo()
        #expect(view.undoStateIdentity == branch)
    }

    @Test func testGroupedUndoAndRedoRestoreSavedIdentity() {
        let view = makeOverlay()
        let group = UUID()
        let annotations = [annotation(.arrow), annotation(.ellipse)]
        for annotation in annotations { annotation.groupID = group }
        view.annotations = annotations
        let initial = view.undoStateIdentity
        view.undoStack.append(contentsOf: annotations.map { .added($0) })
        let saved = view.undoStateIdentity
        view.undo()
        #expect(view.undoStateIdentity == initial)
        view.redo()
        #expect(view.undoStateIdentity == saved)
    }

    @Test func testUndoRemovesTheLastAnnotationAndRedoPutsItBack() {
        let view = makeOverlay()
        let ann = annotation()
        view.annotations.append(ann)
        view.undoStack.append(.added(ann))

        view.undo()
        #expect(view.annotations.isEmpty)
        #expect(view.redoStack.count == 1)

        view.redo()
        #expect(view.annotations.count == 1)
        #expect(view.annotations.first === ann, "redo must restore the same annotation, not a copy")
        #expect(view.redoStack.isEmpty)
    }

    @Test func testUndoOnAnEmptyStackDoesNothing() {
        let view = makeOverlay()
        view.undo()
        view.redo()
        #expect(view.annotations.isEmpty)
        #expect(view.undoStack.isEmpty)
        #expect(view.redoStack.isEmpty)
    }

    @Test func testUndoRestoresADeletedAnnotationInItsOriginalPlace() {
        let view = makeOverlay()
        let first = annotation(.pencil)
        let middle = annotation(.arrow)
        let last = annotation(.text)
        view.annotations = [first, last]
        view.undoStack.append(.deleted(middle, 1))

        view.undo()
        #expect(view.annotations.count == 3)
        #expect(view.annotations[1] === middle, "z-order matters: it has to come back where it was")
    }

    @Test func testUndoingADeletionAtAStaleIndexDoesNotCrash() {
        let view = makeOverlay()
        view.annotations = [annotation()]
        view.undoStack.append(.deleted(annotation(.arrow), 99))  // index from a longer list

        view.undo()
        #expect(view.annotations.count == 2, "a stale index must clamp, not trap")
    }

    @Test func testABatchOfAnnotationsUndoesTogether() {
        // Auto-redact adds one annotation per detected match, all sharing a
        // group id; a single undo has to take the whole batch.
        let view = makeOverlay()
        let group = UUID()
        let batch = (0..<4).map { index -> Annotation in
            let ann = annotation(.filledRectangle,
                                 from: NSPoint(x: index * 10, y: 0),
                                 to: NSPoint(x: index * 10 + 8, y: 8))
            ann.groupID = group
            return ann
        }
        view.annotations = batch
        for ann in batch { view.undoStack.append(.added(ann)) }

        view.undo()
        #expect(view.annotations.isEmpty, "the whole redaction pass should disappear at once")

        view.redo()
        #expect(view.annotations.count == 4, "and come back at once")
    }

    @Test func testAnUngroupedAnnotationIsNotSweptUpByABatchUndo() {
        let view = makeOverlay()
        let manual = annotation(.arrow)
        let group = UUID()
        let redaction = annotation(.filledRectangle)
        redaction.groupID = group

        view.annotations = [manual, redaction]
        view.undoStack = [.added(manual), .added(redaction)]

        view.undo()
        #expect(view.annotations.count == 1)
        #expect(view.annotations.first === manual, "an unrelated annotation must survive")
    }

    @Test func testUndoingAPropertyChangeRestoresTheOldStyle() {
        let view = makeOverlay()
        let ann = annotation(.rectangle)
        ann.strokeWidth = 3
        ann.color = .red
        let snapshot = ann.clone()

        ann.strokeWidth = 12
        ann.color = .blue
        view.annotations = [ann]
        view.undoStack.append(.propertyChange(annotation: ann, snapshot: snapshot))

        view.undo()
        #expect(ann.strokeWidth == 3)
        #expect(FieldDescriber.describe(ann.color) == FieldDescriber.describe(NSColor.red))

        view.redo()
        #expect(ann.strokeWidth == 12, "redo has to put the new style back")
    }

    @Test func testNumberingCountsBackDownWhenUndone() {
        let view = makeOverlay()
        view.numberCounter = 3
        let third = annotation(.number)
        third.number = 3
        view.annotations = [third]
        view.undoStack.append(.added(third))

        view.undo()
        #expect(view.numberCounter == 2, "the next badge should reuse the number that was undone")
    }

    @Test func testRepeatedUndoAndRedoConvergeOnTheSameState() {
        let view = makeOverlay()
        let annotations = [annotation(.pencil), annotation(.arrow), annotation(.text)]
        view.annotations = annotations
        view.undoStack = annotations.map { .added($0) }

        for _ in 0..<5 { view.undo() }   // more undos than entries
        #expect(view.annotations.isEmpty)

        for _ in 0..<5 { view.redo() }   // more redos than entries
        #expect(view.annotations.count == 3)
        #expect(view.annotations.map(\.tool) == annotations.map(\.tool), "order must be preserved")
    }

    @Test func testUndoingAnImageTransformRestoresThePreviousImage() throws {
        let view = makeOverlay(width: 100, height: 100)
        let original = try #require(view.screenshotImage)
        let flipped = ImageProbe.solidImage(width: 60, height: 40)

        view.undoStack.append(.imageTransform(previousImage: original, previousSnappedWindowImage: nil, annotationOffsets: []))
        view.screenshotImage = flipped

        view.undo()
        #expect(view.screenshotImage?.size == original.size)

        view.redo()
        #expect(view.screenshotImage?.size == flipped.size)
    }

    // MARK: - Selection

    @Test func testApplySelectionStoresTheRect() {
        let view = makeOverlay()
        view.applySelection(NSRect(x: 20, y: 30, width: 120, height: 90))
        #expect(view.selectionRect == NSRect(x: 20, y: 30, width: 120, height: 90))
    }

    // MARK: - Drawing every tool

    @Test func testEveryToolDrawsWithoutCrashing() throws {
        // Annotations draw themselves; a degenerate shape must not trap.
        let view = makeOverlay(width: 200, height: 160)
        let geometries: [(NSPoint, NSPoint)] = [
            (NSPoint(x: 20, y: 20), NSPoint(x: 150, y: 120)),   // normal
            (NSPoint(x: 50, y: 50), NSPoint(x: 50, y: 50)),     // zero size
            (NSPoint(x: 150, y: 120), NSPoint(x: 20, y: 20)),   // reversed
            (NSPoint(x: -500, y: -500), NSPoint(x: 900, y: 900)), // far outside
        ]

        for tool in AnnotationTool.allCases {
            for (start, end) in geometries {
                let ann = Annotation(tool: tool, startPoint: start, endPoint: end,
                                     color: .systemBlue, strokeWidth: 4)
                ann.text = "sample"
                ann.number = 1
                ann.points = [start, NSPoint(x: (start.x + end.x) / 2, y: end.y), end]
                view.annotations = [ann]
                view.cachedCompositedImage = nil
                #expect(view.compositedImage() != nil, "\(tool) failed to render at \(start)–\(end)")
            }
        }
    }

    @Test func testAnnotationsWithHugeStrokeWidthsStillRender() throws {
        let view = makeOverlay(width: 100, height: 100)
        for width in [0, 1, 200, 5000] as [CGFloat] {
            let ann = annotation(.rectangle)
            ann.strokeWidth = width
            view.annotations = [ann]
            view.cachedCompositedImage = nil
            #expect(view.compositedImage() != nil, "stroke width \(width) failed to render")
        }
    }
}
