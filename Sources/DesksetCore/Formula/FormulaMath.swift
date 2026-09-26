import Foundation

/// One-argument operations (unary operators and one-argument functions).
enum FormulaUnary: Equatable {
    case negate, bitNot
    case cos, sin, tan, acos, asin, atan, rad, deg, abs, neg, exp, log, ln, sqrt, sgn, frac, trunc, floor, ceil
    case round
}

/// Two-argument operations (binary operators and two-argument functions).
enum FormulaBinary: Equatable {
    case add, subtract, multiply, divide, remainder, power
    case bitAnd, bitOr, bitXor
    case equal, notEqual, less, greater, lessEqual, greaterEqual
    case logicalAnd, logicalOr
    case atan2, min, max, round
}

/// The numeric semantics of every operator and function. Used both at run time and for compile-time
/// constant folding, so the two can never disagree. None of these can trap.
///
/// Where the manual (docs.rainmeter.net/manual/formulas) is silent we chose:
/// - `x / 0` and `x % 0` evaluate to 0 (a skin like `(Used / Total)` must not blow up while Total is still 0).
/// - `%` is the C `fmod` remainder: the sign follows the dividend (`-7 % 3 = -1`), and it works on fractions
///   (`5.5 % 2 = 1.5`).
/// - Bitwise `& | ^ ~` work on the operands truncated toward zero to 64-bit signed integers (NaN → 0,
///   out-of-range values saturate): `5.7 & 3 = 1`, `~5 = -6`, `-1 & 0xFF = 255`.
/// - Comparisons and `&& ||` produce 1 or 0. "True" means non-zero and not NaN.
/// - `Round(x)` rounds half away from zero; `Round(x, n)` rounds to n decimals (n truncated; negative n rounds
///   to tens/hundreds…), correctly rounded (see `round(_:decimals:)`).
/// - `Frac(x) = x - Trunc(x)` (so `Frac(-1.5) = -0.5`); `Sgn(NaN) = 0`.
/// - Other domain errors (`Sqrt(-1)`, `Log(0)`, `Acos(2)`, overflow) follow IEEE arithmetic internally; the
///   final result of a formula is made finite by `FormulaMath.finite` (NaN/±∞ → 0, -0 → +0).
enum FormulaMath {
    @inline(__always) static func truthy(_ x: Double) -> Bool { x != 0 && !x.isNaN }

    @inline(__always) static func bool(_ b: Bool) -> Double { b ? 1 : 0 }

    /// The final result of a formula: NaN/±∞ become 0, and -0 becomes +0. IEEE arithmetic readily produces
    /// -0 (`Round(-0.4)`, `Ceil(-0.5)`, `Trunc(-0.5)`, `-x` or `x * -1` with x = 0), which number formatting then
    /// shows as "-0" in a String meter; the manual never distinguishes the two zeros, so normalize.
    @inline(__always) static func finite(_ x: Double) -> Double { x.isFinite ? (x == 0 ? 0 : x) : 0 }

    /// Truncates toward zero into Int64 without trapping.
    @inline(__always) static func toInt64(_ x: Double) -> Int64 {
        if x.isNaN { return 0 }
        if x >= 9_223_372_036_854_775_807.0 { return .max }
        if x <= -9_223_372_036_854_775_808.0 { return .min }
        return Int64(x)
    }

    static func apply(_ op: FormulaUnary, _ x: Double) -> Double {
        switch op {
        case .negate, .neg: return -x
        case .bitNot: return Double(~toInt64(x))
        case .cos: return Foundation.cos(x)
        case .sin: return Foundation.sin(x)
        case .tan: return Foundation.tan(x)
        case .acos: return Foundation.acos(x)
        case .asin: return Foundation.asin(x)
        case .atan: return Foundation.atan(x)
        case .rad: return x * .pi / 180
        case .deg: return x * 180 / .pi
        case .abs: return Swift.abs(x)
        case .exp: return Foundation.exp(x)
        case .log: return Foundation.log10(x)
        case .ln: return Foundation.log(x)
        case .sqrt: return Foundation.sqrt(x)
        case .sgn: return x > 0 ? 1 : (x < 0 ? -1 : 0)
        case .frac: return x - Foundation.trunc(x)
        case .trunc: return Foundation.trunc(x)
        case .floor: return Foundation.floor(x)
        case .ceil: return Foundation.ceil(x)
        case .round: return x.rounded(.toNearestOrAwayFromZero)
        }
    }

    static func apply(_ op: FormulaBinary, _ a: Double, _ b: Double) -> Double {
        switch op {
        case .add: return a + b
        case .subtract: return a - b
        case .multiply: return a * b
        case .divide: return b == 0 ? 0 : a / b
        case .remainder: return b == 0 ? 0 : fmod(a, b)
        case .power: return Foundation.pow(a, b)
        case .bitAnd: return Double(toInt64(a) & toInt64(b))
        case .bitOr: return Double(toInt64(a) | toInt64(b))
        case .bitXor: return Double(toInt64(a) ^ toInt64(b))
        case .equal: return bool(a == b)
        case .notEqual: return bool(a != b)
        case .less: return bool(a < b)
        case .greater: return bool(a > b)
        case .lessEqual: return bool(a <= b)
        case .greaterEqual: return bool(a >= b)
        case .logicalAnd: return bool(truthy(a) && truthy(b))
        case .logicalOr: return bool(truthy(a) || truthy(b))
        case .atan2: return Foundation.atan2(a, b)
        case .min: return Foundation.fmin(a, b)
        case .max: return Foundation.fmax(a, b)
        case .round: return round(a, decimals: b)
        }
    }

    static func clamp(_ x: Double, _ low: Double, _ high: Double) -> Double {
        // Manual: "Restricts value x to low and high limits." With low > high we apply low first, then high.
        Foundation.fmin(Foundation.fmax(x, low), high)
    }

    /// `Round(x, n)`: x rounded half away from zero to n decimals (n truncated toward zero; a negative n rounds to
    /// tens, hundreds, …). The result is correctly rounded: the double nearest to the exact decimal rounding of x's
    /// binary value — what C's `printf("%.*f")` prints, except that exact ties go away from zero.
    ///
    /// The textbook `(x * 10^n).rounded() / 10^n` is not: the product is itself rounded, and near a tie that
    /// error decides the result (`Round(4281.6, 12)` gave 4281.600000000001), and once `x * 10^n` passes 2^53 the
    /// round trip only adds error (`Round(484624701830849.06, 4)` gave 484624701830849.0). Here `fma` recovers the
    /// exact error of the scaling, which settles exactly the ties that rounding the product created.
    /// There is no fixed upper limit on n: a large n still rounds a tiny x (`Round(1.23456789e-10, 16)`).
    static func round(_ x: Double, decimals: Double) -> Double {
        guard x.isFinite else { return x }
        let n = decimals.isNaN ? 0 : Foundation.trunc(decimals)
        if n == 0 { return x.rounded(.toNearestOrAwayFromZero) }
        if n < -308 { return 0 }
        let m = Foundation.pow(10, Swift.abs(n)) // exact for |n| <= 22; +inf for n > 308 (then x is returned)
        if n > 0 {
            let s = x * m
            // |s| >= 2^53 (or ∞/NaN): x has no binary digits left beyond the n-th decimal, so it is already rounded.
            guard Swift.abs(s) < twoPow53 else { return x }
            return roundHalfAwayFromZero(s, error: Foundation.fma(x, m, -s)) / m
        }
        let s = x / m
        guard Swift.abs(s) < twoPow53 else { return x }
        // fma(-s, m, x) is the exact remainder x - s * m, so it has the sign of the exact quotient's error.
        let r = roundHalfAwayFromZero(s, error: Foundation.fma(-s, m, x) / m) * m
        return r.isFinite ? r : x // Round(1.7976931348623157e308, -308) would be 2e308
    }

    private static let twoPow53 = 9_007_199_254_740_992.0

    /// Rounds the exact value `s + error` (s = a rounded double, |error| <= ulp(s)/2, |s| < 2^53) to an integer,
    /// half away from zero. Only two situations differ from rounding s itself: s is exactly halfway (then the
    /// error decides), or s is an integer >= 2^52 and the exact value is exactly halfway above it.
    @inline(__always) private static func roundHalfAwayFromZero(_ s: Double, error e: Double) -> Double {
        var k = s.rounded(.toNearestOrAwayFromZero)
        let d = s - k // exact
        if d == 0.5 || d == -0.5 {
            // Rounding went away from zero; if the exact value lies on the zero side of s it is below halfway.
            if e != 0 && (e > 0) != (s > 0) { k = s.rounded(.towardZero) }
        } else if d == 0 && (e == 0.5 || e == -0.5) && (e > 0) == (s > 0) {
            k = s + (s > 0 ? 1 : -1)
        }
        return k
    }
}
