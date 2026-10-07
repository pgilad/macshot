import Cocoa
import Testing
@testable import macshot

/// The preset list drives the selection-size popover. A mislabelled ratio locks
/// the selection to proportions that don't match what the menu says.
final class ResolutionPresetTests {

    @Test func testEveryRatioLabelMatchesItsValue() throws {
        for preset in ResolutionPresetCatalog.ratios {
            guard case .ratio(let label, let value) = preset else { continue }
            let parts = label.split(separator: ":").map {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            let width = try #require(parts.first ?? nil, "unparseable ratio label \(label)")
            let height = try #require(parts.last ?? nil, "unparseable ratio label \(label)")
            #expect(abs(Double(value) - (width / height)) <= 0.0001, "\"\(label)\" locks the selection to \(value)")
        }
    }

    @Test func testEveryResolutionLabelMatchesItsPixels() throws {
        for preset in ResolutionPresetCatalog.resolutions {
            guard case .resolution(let label, let w, let h) = preset else { continue }
            let digits = label.split(whereSeparator: { !$0.isNumber }).map(String.init)
            #expect(digits.count == 2, "unparseable resolution label \(label)")
            #expect(Int(digits[0]) == w, "\"\(label)\" would set width \(w)")
            #expect(Int(digits[1]) == h, "\"\(label)\" would set height \(h)")
        }
    }

    @Test func testFreeformComesFirstAndLocksNothing() {
        guard case .freeform = ResolutionPresetCatalog.ratios.first else {
            Issue.record("Freeform should head the ratio list"); return
        }
        #expect(ResolutionPresetCatalog.ratios.first?.aspectValue == nil)
    }

    @Test func testRatiosAreDistinct() {
        let values = ResolutionPresetCatalog.ratios.compactMap(\.aspectValue)
        #expect(Set(values.map { Double($0) }).count == values.count, "two presets lock the same proportions")
    }

    @Test func testResolutionsArePositiveAndDistinct() {
        var seen = Set<String>()
        for preset in ResolutionPresetCatalog.resolutions {
            guard case .resolution(let label, let w, let h) = preset else { continue }
            #expect(w > 0, "\(label)")
            #expect(h > 0, "\(label)")
            #expect(seen.insert("\(w)x\(h)").inserted, "\(label) is listed twice")
        }
    }

    @Test func testEveryPresetHasALabel() {
        for preset in ResolutionPresetCatalog.ratios + ResolutionPresetCatalog.resolutions {
            #expect(!preset.label.isEmpty)
        }
    }

    @Test func testPortraitAndLandscapePairsAreBothOffered() {
        // 16:9 and 9:16 (and 4:3 / 3:4) should both be there, or rotating a
        // selection means leaving the menu.
        let values = ResolutionPresetCatalog.ratios.compactMap(\.aspectValue).map { Double($0) }
        for pair in [(16.0 / 9.0, 9.0 / 16.0), (4.0 / 3.0, 3.0 / 4.0)] {
            #expect(values.contains { abs($0 - pair.0) < 0.001 }, "missing \(pair.0)")
            #expect(values.contains { abs($0 - pair.1) < 0.001 }, "missing \(pair.1)")
        }
    }
}
