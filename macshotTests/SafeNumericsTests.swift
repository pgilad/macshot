import XCTest

/// `Int(someDouble)` traps on NaN and infinity. Image sizes and time intervals
/// are not guaranteed to be finite, and both reach an Int conversion on
/// ordinary user paths.
final class SafeNumericsTests: XCTestCase {

    func testOrdinaryValuesConvertNormally() {
        XCTAssertEqual(SafeNumerics.int(3.4), 3)
        XCTAssertEqual(SafeNumerics.int(3.6), 4)
        XCTAssertEqual(SafeNumerics.int(-2.5), -3, "rounds to nearest, ties away from zero")
        XCTAssertEqual(SafeNumerics.int(0.0), 0)
    }

    func testNonFiniteValuesUseTheFallbackInsteadOfTrapping() {
        for value in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            XCTAssertEqual(SafeNumerics.int(value, fallback: 7), 7, "\(value)")
        }
    }

    func testValuesBeyondIntRangeAreClamped() {
        XCTAssertEqual(SafeNumerics.int(1e300), Int.max)
        XCTAssertEqual(SafeNumerics.int(-1e300), Int.min)
    }

    func testCGFloatOverloadBehavesTheSame() {
        XCTAssertEqual(SafeNumerics.int(CGFloat.nan, fallback: 5), 5)
        XCTAssertEqual(SafeNumerics.int(CGFloat(29.7)), 30)
    }
}
