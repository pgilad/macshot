import Cocoa
import Testing
@testable import macshot

/// `Int(someDouble)` traps on NaN and infinity. Image sizes and time intervals
/// are not guaranteed to be finite, and both reach an Int conversion on
/// ordinary user paths.
final class SafeNumericsTests {

    @Test func testOrdinaryValuesConvertNormally() {
        #expect(SafeNumerics.int(3.4) == 3)
        #expect(SafeNumerics.int(3.6) == 4)
        #expect(SafeNumerics.int(-2.5) == -3, "rounds to nearest, ties away from zero")
        #expect(SafeNumerics.int(0.0) == 0)
    }

    @Test func testNonFiniteValuesUseTheFallbackInsteadOfTrapping() {
        for value in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            #expect(SafeNumerics.int(value, fallback: 7) == 7, "\(value)")
        }
    }

    @Test func testValuesBeyondIntRangeAreClamped() {
        #expect(SafeNumerics.int(1e300) == Int.max)
        #expect(SafeNumerics.int(-1e300) == Int.min)
    }

    @Test func testCGFloatOverloadBehavesTheSame() {
        #expect(SafeNumerics.int(CGFloat.nan, fallback: 5) == 5)
        #expect(SafeNumerics.int(CGFloat(29.7)) == 30)
    }
}
