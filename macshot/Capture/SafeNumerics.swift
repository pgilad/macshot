import Foundation

/// `Int(someDouble)` traps when the value is NaN or infinite. Image sizes and
/// time intervals are not guaranteed to be finite, and each reaches an
/// `Int(...)` on a normal user path, so the conversions go through here instead.
enum SafeNumerics {

    /// Rounds to an Int, substituting `fallback` for a non-finite value and
    /// clamping anything outside Int's range.
    static func int(_ value: Double, fallback: Int = 0) -> Int {
        guard value.isFinite else { return fallback }
        let rounded = value.rounded()
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }

    static func int(_ value: CGFloat, fallback: Int = 0) -> Int {
        int(Double(value), fallback: fallback)
    }
}
