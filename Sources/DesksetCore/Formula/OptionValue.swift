import Foundation

// Typed option readers — clean-room implementation of docs.rainmeter.net/manual/skins/option-types/
// (Number, Color and Path options) and the X/Y/Padding/TransformationMatrix notes of
// /manual/meters/general-options/. String options need no reader; Action and Regular-expression options are
// parsed by the Actions / TextTransforms modules.

/// A color with components on Rainmeter's 0…255 scale.
public struct RGBA: Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let white = RGBA(r: 255, g: 255, b: 255)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
}

/// A meter `X=` / `Y=` value.
public struct PositionValue: Equatable {
    public enum Mode: Equatable {
        /// `X=10` — relative to the skin origin.
        case absolute
        /// `X=10r` — relative to the previous meter's X (or Y).
        case relativeToPreviousStart
        /// `X=10R` — relative to the previous meter's X+W (or Y+H).
        case relativeToPreviousEnd
    }

    public var value: Double
    public var mode: Mode

    public init(value: Double, mode: Mode = .absolute) {
        self.value = value
        self.mode = mode
    }
}

/// Typed readers for option values (already variable-resolved). All are total: bad input → nil / empty, never a crash.
public enum OptionValue {
    /// `R,G,B[,A]` in decimal (components may be formulas) or hex `RRGGBB[AA]`.
    ///
    /// Manual (Option Types → Color options): decimal `RRR,GGG,BBB,AAA` with 0–255 components, "Formulas can
    /// also be used in place of the numbers"; hexadecimal `RRGGBBAA`; alpha is optional and defaults to 255.
    /// Judgment calls where the manual is silent:
    /// - Components are clamped to 0…255 and may be fractional (`(255 * 0.5)` = 127.5).
    /// - Hex is case-insensitive and must be exactly 6 or 8 hex digits, optionally after a C-style `0x` / `0X`
    ///   prefix (`0x0F0F2F`, see `hexColor`); a `#` prefix is not accepted.
    /// - Decimal needs at least 3 components; extra components after the 4th are ignored; trailing empty
    ///   components are dropped (`255,255,255,` — a trailing comma once crashed Rainmeter, it must not here);
    ///   an empty component in the middle reads as 0; a component that is not a number/formula makes the
    ///   whole color nil (caller uses its default). Commas inside parentheses do not split
    ///   (`(Clamp(x,0,255)),0,0`).
    /// - Empty value → nil.
    public static func color(_ s: String) -> RGBA? {
        let t = OptionText.trim(s)
        guard !t.isEmpty else { return nil }
        if !t.utf8.contains(0x2C) { return hexColor(t) }

        var parts = OptionText.splitTopLevel(t, separator: 0x2C).map(OptionText.trim)
        while let last = parts.last, last.isEmpty { parts.removeLast() }
        guard parts.count >= 3 else { return nil }
        var c: [Double] = []
        c.reserveCapacity(4)
        for part in parts.prefix(4) {
            if part.isEmpty {
                c.append(0)
            } else if let v = Formula.number(trimmed: part) {
                c.append(clampComponent(v))
            } else {
                return nil
            }
        }
        return RGBA(r: c[0], g: c[1], b: c[2], a: c.count > 3 ? c[3] : 255)
    }

    private static func clampComponent(_ v: Double) -> Double {
        v.isNaN ? 0 : Swift.min(Swift.max(v, 0), 255)
    }

    private static func hexColor(_ t: Substring) -> RGBA? {
        var bytes = Array(t.utf8)
        // Judgment call (docs/compat/engine.md): a C-style `0x` prefix (`0x0F0F2F`) is accepted; skins in the wild use
        // it and C hex parsing accepts it.
        if bytes.count == 8 || bytes.count == 10, bytes[0] == 0x30, bytes[1] == 0x78 || bytes[1] == 0x58 {
            bytes.removeFirst(2)
        }
        guard bytes.count == 6 || bytes.count == 8 else { return nil }
        var comps: [Double] = []
        var k = 0
        while k < bytes.count {
            guard let hi = NumericLiteral.digitValue(bytes[k], base: 16),
                  let lo = NumericLiteral.digitValue(bytes[k + 1], base: 16) else { return nil }
            comps.append(Double(hi * 16 + lo))
            k += 2
        }
        return RGBA(r: comps[0], g: comps[1], b: comps[2], a: comps.count > 3 ? comps[3] : 255)
    }

    /// `10`, `-5`, `10r`, `10R`, `(5+5)R`, `(#A#*2)`.
    ///
    /// Manual (General Meter Options → X, Y): "If the value is appended with `r`, the position is relative to
    /// the top/left edge of the previous meter. If the value is appended with `R`, the position is relative
    /// to the bottom/right edge of the previous meter." The suffix is case-sensitive; spaces before it are
    /// allowed (`10 R`). A bare `r`/`R` reads as `0r`/`0R` (judgment call). The number part follows
    /// `Formula.number`.
    public static func position(_ s: String) -> PositionValue? {
        let t = OptionText.trim(s)
        guard let last = t.utf8.last else { return nil }
        if last == 0x72 || last == 0x52 { // r / R
            let mode: PositionValue.Mode = last == 0x72 ? .relativeToPreviousStart : .relativeToPreviousEnd
            let body = OptionText.trim(t.dropLast())
            if body.isEmpty { return PositionValue(value: 0, mode: mode) }
            return Formula.number(trimmed: body).map { PositionValue(value: $0, mode: mode) }
        }
        return Formula.number(trimmed: t).map { PositionValue(value: $0, mode: .absolute) }
    }

    /// Plain number or parenthesized formula (see `Formula.number`).
    public static func number(_ s: String) -> Double? { Formula.number(s) }

    /// `number` truncated toward zero. Out-of-range values saturate at `Int.min` / `Int.max` instead of trapping.
    public static func int(_ s: String) -> Int? {
        number(s).map { v in
            if v >= 9_223_372_036_854_775_807.0 { return Int.max }
            if v <= -9_223_372_036_854_775_808.0 { return Int.min }
            return Int(v)
        }
    }

    /// Numeric non-zero → true, zero → false; nil when not a number.
    public static func bool(_ s: String) -> Bool? { number(s).map { $0 != 0 } }

    /// Comma-separated numbers, each may be a formula: `Padding=5,5,5,5`, `SolidColor`-style rects…
    ///
    /// Commas inside parentheses do not split (`(Max(1,2)),3` → [2, 3]). Empty value → []. Trailing empty
    /// items are dropped (`5,5,` → [5, 5]); an empty or unreadable item in the middle reads as 0 so later
    /// items keep their positions (`5,,5` → [5, 0, 5]).
    public static func numbers(_ s: String) -> [Double] {
        numbers(s, separator: ",")
    }

    /// Like `numbers(_:)` with another ASCII separator, e.g. `;` for
    /// `TransformationMatrix=1; 0; 0; 1; 0; 0`. A non-ASCII separator yields [].
    public static func numbers(_ s: String, separator: Character) -> [Double] {
        guard let sep = separator.asciiValue else { return [] }
        let t = OptionText.trim(s)
        if t.isEmpty { return [] }
        var parts = OptionText.splitTopLevel(t, separator: sep).map(OptionText.trim)
        while let last = parts.last, last.isEmpty { parts.removeLast() }
        return parts.map { $0.isEmpty ? 0 : (Formula.number(trimmed: $0) ?? 0) }
    }

    /// `A | B | C` → ["A", "B", "C"] (trimmed, empties dropped). Used by MeterStyle and Group.
    ///
    /// Pipes inside parentheses do not split, so a formula using `||` (or `|`) stays one item — a fix the
    /// Rainmeter version history lists for pipe-separated options.
    public static func list(_ s: String) -> [String] {
        OptionText.splitTopLevel(Substring(s), separator: 0x7C)
            .map { String(OptionText.trim($0)) }
            .filter { !$0.isEmpty }
    }

    /// Splits at an ASCII `separator` outside parentheses and trims every item (empties kept).
    /// A non-ASCII separator returns the whole trimmed value as one item.
    public static func split(_ s: String, separator: Character) -> [String] {
        guard let sep = separator.asciiValue else { return [String(OptionText.trim(s))] }
        return OptionText.splitTopLevel(Substring(s), separator: sep).map { String(OptionText.trim($0)) }
    }

    /// Path option (Option Types → Path options): a file or folder path, absolute or relative to
    /// `directory` (normally the current skin folder, `#CURRENTPATH#`).
    ///
    /// - Windows `\` separators become `/`; `.` and `..` components are resolved and repeated `/` collapsed
    ///   (so `..\lolcat.png` works); `..` never climbs above `/`.
    /// - `/…` is absolute; `~` / `~/…` expands to the home folder.
    /// - A trailing separator is kept (folder paths).
    /// - Windows-only absolute forms that cannot exist on macOS — drive letters (`C:\…`) and UNC paths
    ///   (`\\server\share`) — return nil, as does an empty value.
    public static func path(_ s: String, relativeTo directory: String) -> String? {
        var p = String(OptionText.trim(s)).replacingOccurrences(of: "\\", with: "/")
        if p.isEmpty || isWindowsAbsolute(p) { return nil }
        if p == "~" || p.hasPrefix("~/") {
            p = NSHomeDirectory() + String(p.dropFirst())
        } else if !p.hasPrefix("/") {
            let base = directory.replacingOccurrences(of: "\\", with: "/")
            if !base.isEmpty { p = (base.hasSuffix("/") ? base : base + "/") + p }
            if isWindowsAbsolute(p) { return nil } // a Windows-style base folder cannot be resolved either
        }
        return normalizePath(p)
    }

    /// `C:…` (drive letter) or `//server…` (UNC, after `\` → `/`).
    private static func isWindowsAbsolute(_ p: String) -> Bool {
        if p.hasPrefix("//") { return true }
        let u = Array(p.utf8.prefix(2))
        return u.count == 2 && u[1] == 0x3A && (u[0] | 0x20) >= 0x61 && (u[0] | 0x20) <= 0x7A
    }

    private static func normalizePath(_ p: String) -> String {
        let absolute = p.hasPrefix("/")
        let trailingSlash = p.hasSuffix("/")
        var out: [Substring] = []
        for comp in p.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." {
                if let last = out.last, last != ".." {
                    out.removeLast()
                } else if !absolute {
                    out.append(comp)
                }
                continue
            }
            out.append(comp)
        }
        var result = (absolute ? "/" : "") + out.joined(separator: "/")
        if trailingSlash && !out.isEmpty { result += "/" }
        if result.isEmpty { result = "." }
        return result
    }
}
