import Cocoa
import Testing
@testable import macshot

/// Exercises the production post-OCR decisions, including settings and geometry.
/// The card numbers are public test fixtures, not real payment details.
final class PIIRedactionPlannerTests {
    private typealias Line = PIIRedactionPlanner.Line

    private func line(_ text: String, x: CGFloat = 0, y: CGFloat = 100, width: CGFloat = 40) -> Line {
        Line(text: text, bounds: CGRect(x: x, y: y, width: width, height: 20))
    }

    private func row(_ groups: [String], gap: CGFloat = 10) -> [Line] {
        var x: CGFloat = 0
        return groups.map { text in
            let result = line(text, x: x, width: CGFloat(text.count) * 10)
            x += result.bounds.width + gap
            return result
        }
    }

    private func selected(_ lines: [Line], types: [String]? = nil) -> Set<Int> {
        Set(PIIRedactionPlanner.matches(in: lines, enabledTypes: types).map(\.lineIndex))
    }

    @Test func testOrdinaryPairsAndLabelsStayVisibleWhenOCRSplitsThem() {
        for groups in [["2026", "2026"], ["1024", "768"], ["1234", "5678"],
                       ["1920", "1080", "60"], ["Total 1234", "Total 5678", "Total 9012"]] {
            #expect(selected(row(groups)).isEmpty, "Unexpected redaction: \(groups)")
        }
    }

    @Test func testAdjacentCardGroupsAreCoveredWithUnevenOCRSplits() {
        for groups in [["4111", "1111", "1111", "1111"], ["3782", "822463", "10005"],
                       ["4111", "1111", "1111", "111"], ["4111 1111", "1111 1111"]] {
            #expect(selected(row(groups), types: ["credit_card"]) == Set(groups.indices), "\(groups)")
        }
    }

    @Test func testDistantColumnsAndDifferentRowsDoNotFormCards() {
        #expect(selected(row(["4111", "1111", "1111", "1111"], gap: 200)).isEmpty)
        let lines = [line("4111", y: 0), line("1111", x: 50, y: 30),
                     line("1111", x: 100, y: 60), line("1111", x: 150, y: 90)]
        #expect(selected(lines).isEmpty)
    }

    @Test func testEmptyOrUnrelatedSelectionsDisableAllCardContextPasses() {
        let lines = row(["4111", "1111", "1111", "1111", "123"]) +
            [line("12/26", y: 60), line("CVV", y: 20), line("456", x: 50, y: 20)]
        for types in [[], ["email"], ["unknown"]] {
            #expect(selected(lines, types: types).isEmpty, "\(types)")
        }
        let expiryOnly = PIIRedactionPlanner.matches(in: lines, enabledTypes: ["expiry"])
        #expect(expiryOnly.map(\.lineIndex) == [5])
        #expect(expiryOnly.map(\.type) == ["expiry"])
    }

    @Test func testSelectingCardsDoesNotAlsoSelectCVVOrExpiry() {
        for code in ["123", "1234"] {
            let lines = row(["4111", "1111", "1111", "1111", code]) + [line("12/26", y: 60)]
            let matches = PIIRedactionPlanner.matches(in: lines, enabledTypes: ["credit_card"])
            #expect(Set(matches.map(\.lineIndex)) == [0, 1, 2, 3])
            #expect(Set(matches.map(\.type)) == ["credit_card"])
        }
    }

    @Test func testCVVSelectionUsesNearbyCardButDoesNotCoverCardGroups() {
        let lines = row(["4111", "1111", "1111", "1111", "123"]) +
            [line("2026", x: 700), line("456", y: -200)]
        let matches = PIIRedactionPlanner.matches(in: lines, enabledTypes: ["cvv"])
        #expect(matches.map(\.lineIndex) == [4])
        #expect(matches.map(\.type) == ["cvv"])
    }

    @Test func testEmailDoesNotMakeNearbyOrdinaryNumbersIntoCVVs() {
        let lines = [line("user@example.com", width: 180), line("123", x: 190),
                     line("2026", y: 60), line("456", x: 800)]
        #expect(selected(lines) == [0])
    }

    @Test func testSeparateCVVLabelWorksWithoutCardNumberAndHonorsSelection() {
        for label in ["CVV", " cvc: ", "CSC", "CCV"] {
            let lines = [line(label), line(" 1234 ", x: 50), line("2026", x: 500)]
            #expect(selected(lines, types: ["cvv"]) == [1])
            #expect(selected(lines, types: ["credit_card"]).isEmpty)
        }
    }

    @Test func testGroupingKeepsUnicodeRangesAndUsesTextSizeForProximity() {
        let lines = row(["٤١١١", "١١١١", "١١١١", "١١١١"])
        for scale: CGFloat in [0.25, 1, 4] {
            let scaled = lines.map { Line(text: $0.text, bounds: $0.bounds.applying(CGAffineTransform(scaleX: scale, y: scale))) }
            let matches = PIIRedactionPlanner.matches(in: scaled, enabledTypes: ["credit_card"])
            #expect(Set(matches.map(\.lineIndex)) == [0, 1, 2, 3])
            for match in matches { #expect(String(scaled[match.lineIndex].text[match.range]) == scaled[match.lineIndex].text) }
        }
        let sentence = [line("Contact 📨 user@example.com today", width: 350)]
        let matches = PIIRedactionPlanner.matches(in: sentence, enabledTypes: ["email"])
        #expect((matches.map { String(sentence[$0.lineIndex].text[$0.range]) }) == ["user@example.com"])
    }

    @Test func testInvalidOCRBoundsDoNotProduceInvalidAnnotationsOrContext() {
        let lines = [Line(text: "user@example.com", bounds: .zero),
                     Line(text: "4111 1111 1111 1111", bounds: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 20)),
                     line("123")]
        #expect(selected(lines).isEmpty)
    }
}
