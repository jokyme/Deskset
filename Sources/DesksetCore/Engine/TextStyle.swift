import Foundation

// Text styling shared by the String meter (DesksetCore) and the host's text renderer.
//
// Clean-room implementation from the public manual only:
//   https://docs.rainmeter.net/manual/meters/string/          (String meter options)
//   https://docs.rainmeter.net/manual/meters/string/inline/   (InlineSetting / InlinePattern)
//   https://docs.rainmeter.net/manual/skins/rainmeter-section/ (AccurateText)
// Places where the manual is silent are marked "Judgment:".

public enum HorizontalTextAlign: Hashable { case left, center, right }
public enum VerticalTextAlign: Hashable { case top, center, bottom }
public enum StringEffect: Hashable { case none, shadow, border }

/// Everything the host needs to measure and draw a String meter's text. The host must measure exactly what it
/// draws: `SkinHost.textSize` and the renderer both work from this value.
public struct TextStyle: Hashable {
    public var fontFace: String = "Arial"
    /// Rainmeter font size in points at 96 DPI; the host converts to screen points. 0 = invisible text.
    public var fontSize: Double = 10
    /// `FontWeight=` (1…999); nil when unset (StringStyle decides).
    public var fontWeight: Int?
    public var bold = false
    public var italic = false
    public var color = RGBA.black
    public var effect = StringEffect.none
    public var effectColor = RGBA.black
    public var horizontalAlign = HorizontalTextAlign.left
    public var verticalAlign = VerticalTextAlign.top
    /// Effective `ClipString` mode: 0 none, 1 clip with ellipsis, 2 auto (wrap on spaces, clip long words).
    /// The String meter already turns mode 1 without `W` into 0 (there is no width to clip to).
    public var clip = 0
    /// Rotation in radians (`Angle=`), around the StringAlign anchor point; positive is clockwise on screen.
    public var angle: Double = 0
    public var antiAlias = false

    /// `AccurateText` of the `[Rainmeter]` section. When false the host adds GDI+-like horizontal padding
    /// (see `TextStyle.gdiPaddingFactor`) to the measured width and insets the text by it when drawing.
    public var accurateText = false
    /// `TrailingSpaces=1`: trailing spaces at the end of a paragraph count in the measured width.
    /// (The String meter also stops trimming the `Text` option.)
    public var trailingSpaces = false
    /// Wrap lines at the available width (ClipString=1 with both W and H, ClipString=2 with W or ClipStringW).
    public var wrap = false
    /// When wrapping, a word wider than the line may be broken (ClipString=1). ClipString=2 "will always wrap on
    /// word boundaries (spaces or tabs)" and clips a word that is too long instead.
    public var breakLongWords = true
    /// Resolved `InlineSetting` / `InlinePattern` ranges, in option order (later spans win where they overlap
    /// with the same kind of setting). Ranges are UTF-16 offsets into the meter's final text.
    public var inlineSpans: [InlineSpan] = []
    /// The skin's `@Resources/Fonts` folder. "TrueType (.ttf) or OpenType (.otf) fonts in the @Resources\Fonts
    /// folder are automatically loaded and can be used with the FontFace option" (manual: @Resources folder), so
    /// the host loads the fonts there before it resolves `fontFace` / inline `Face`. Nil when unknown.
    public var fontFolder: String?

    public init() {}

    /// Horizontal padding added on each side when `AccurateText=0`, as a fraction of the font's em size in pixels.
    /// The history page says that with AccurateText=0 "D2D adds padding to the text similar to GDI+"; GDI+ pads
    /// every measured / drawn string by 1/6 em at each end. Judgment: no vertical padding (GDI+ does not add any).
    public static let gdiPaddingFactor = 1.0 / 6.0

    /// Font size in pixels (skin points): Rainmeter font sizes are points at 96 DPI.
    public static func pixelSize(points: Double) -> Double { points * 96.0 / 72.0 }

    /// Distance between default tab stops, in pixels. Judgment: the manual says nothing about tabs; Rainmeter lays
    /// text out with DirectWrite, whose default incremental tab stop is 4 × the font size (the Mac text system's
    /// default of 28 points would make tab-aligned columns much narrower).
    public var tabInterval: Double { TextStyle.pixelSize(points: fontSize) * 4 }
}

// MARK: - Line breaking

/// Line-breaking rules the host's text layout applies on top of the typesetter's suggestions (Foundation only,
/// so they can be tested without a font system). Offsets are UTF-16 code units.
public enum TextWrapRules {
    public static func isNewline(_ u: UInt16) -> Bool {
        u == 0x0A || u == 0x0D || u == 0x0B || u == 0x0C || u == 0x85 || u == 0x2028 || u == 0x2029
    }

    public static func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 }

    /// ClipString=2 "will always wrap on word boundaries (spaces or tabs). Any single word that is longer than the
    /// defined or maximum width will clip that line, rather than breaking the word in two."
    ///
    /// `count` is the typesetter's suggested line length from `start`; returns the length to use instead:
    /// - a break after spaces / tabs or at a hard line break is kept (spaces the typesetter left for the next line
    ///   are pulled onto this one);
    /// - Judgment: scripts written without spaces between words (CJK ideographs, kana, Hangul; Thai, Lao, Khmer,
    ///   Myanmar) have word boundaries between their characters, so the typesetter's break next to them is kept
    ///   (otherwise a Chinese or Japanese sentence could never wrap);
    /// - a break inside a word moves back to the previous boundary; when the word alone is wider than the line it
    ///   moves forward to the end of that word (the renderer clips the overflow).
    public static func wordBoundaryBreak(_ units: [UInt16], start: Int, count: Int) -> Int {
        let n = units.count
        guard start >= 0, start < n, count > 0 else { return max(min(count, n - start), 1) }
        var end = min(start + count, n)
        // Never between the two halves of a surrogate pair.
        if end < n, (0xDC00...0xDFFF).contains(units[end]), (0xD800...0xDBFF).contains(units[end - 1]) { end += 1 }
        if end >= n || isNewline(units[end - 1]) || isSpace(units[end - 1]) || isNewline(units[end]) {
            return end - start
        }
        if isSpace(units[end]) {
            var e = end
            while e < n, isSpace(units[e]) { e += 1 }
            if e < n, isNewline(units[e]) { e += 1 }
            return e - start
        }
        if breaksWithoutSpaces(units, end - 1) || breaksWithoutSpaces(units, end) { return end - start }
        var back = end - 1
        while back > start, !isBoundary(units, back) { back -= 1 }
        if back > start { return back - start }
        var forward = end
        while forward < n, !isSpace(units[forward]), !isNewline(units[forward]), !isBoundary(units, forward) {
            forward += 1
        }
        while forward < n, isSpace(units[forward]) { forward += 1 }
        if forward < n, isNewline(units[forward]) { forward += 1 }
        return forward - start
    }

    /// A word boundary between `units[p - 1]` and `units[p]` (0 < p < count): after spaces / tabs, or next to an
    /// ideographic character — but never inside a surrogate pair, before closing punctuation or after opening
    /// punctuation.
    static func isBoundary(_ units: [UInt16], _ p: Int) -> Bool {
        guard p > 0, p < units.count else { return false }
        let before = units[p - 1], after = units[p]
        if isSpace(before) { return true }
        if (0xDC00...0xDFFF).contains(after) || closesLine(after) { return false }
        // After CJK closing punctuation (、。，…) a new word may start.
        if before >= 0x3000, closesLine(before) { return true }
        guard isIdeographic(units, p - 1) || isIdeographic(units, p) else { return false }
        return !opensLine(before)
    }

    /// CJK ideographs (including extensions in planes 2–3), kana and Hangul syllables.
    static func isIdeographic(_ units: [UInt16], _ i: Int) -> Bool {
        guard i >= 0, i < units.count else { return false }
        switch units[i] {
        case 0x3040...0x309F, 0x30A0...0x30FB, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
             0xD840...0xD8BF:
            return true
        case 0xDC00...0xDFFF:
            return i > 0 && (0xD840...0xD8BF).contains(units[i - 1])
        default:
            return false
        }
    }

    /// Characters next to which the typesetter's own line break is a word boundary: ideographic text, CJK
    /// punctuation / full-width forms, and the scripts that break by dictionary (Thai, Lao, Myanmar, Khmer).
    static func breaksWithoutSpaces(_ units: [UInt16], _ i: Int) -> Bool {
        guard i >= 0, i < units.count else { return false }
        switch units[i] {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3000...0x303F, 0xFF00...0xFFEF:
            return true
        default:
            return isIdeographic(units, i)
        }
    }

    /// Punctuation that may not start a line.
    private static func closesLine(_ u: UInt16) -> Bool {
        switch u {
        case 0x21, 0x29, 0x2C, 0x2E, 0x3A, 0x3B, 0x3F, 0x5D, 0x7D,
             0x3001, 0x3002, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0x3017, 0x3019, 0x301B, 0x30FC,
             0xFF01, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF3D, 0xFF5D:
            return true
        default:
            return false
        }
    }

    /// Punctuation that may not end a line.
    private static func opensLine(_ u: UInt16) -> Bool {
        switch u {
        case 0x28, 0x5B, 0x7B, 0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0x3018, 0x301A,
             0xFF08, 0xFF3B, 0xFF5B:
            return true
        default:
            return false
        }
    }
}

// MARK: - Inline options

/// One `InlineSettingN` applied to a UTF-16 range of the meter text.
public struct InlineSpan: Hashable {
    public var location: Int
    public var length: Int
    public var setting: InlineSetting

    public init(location: Int, length: Int, setting: InlineSetting) {
        self.location = location
        self.length = length
        self.setting = setting
    }

    public var end: Int { location + length }
}

public struct GradientStop: Hashable {
    public var color: RGBA
    /// 0…1 along the gradient.
    public var position: Double

    public init(color: RGBA, position: Double) {
        self.color = color
        self.position = position
    }
}

public struct InlineGradient: Hashable {
    /// Degrees; 0 = right to left, 90 = bottom to top, 180 = left to right, 270 = top to bottom (the angle points
    /// at the start of the gradient, measured clockwise from "directly to the right").
    public var angle: Double
    /// At least two stops, sorted by position.
    public var stops: [GradientStop]
    /// `GradientColor1`: "interpolates the gradient using an alternative method of handling gamma correction".
    /// Judgment: the host interpolates in linear light instead of sRGB.
    public var linearGamma: Bool

    public init(angle: Double, stops: [GradientStop], linearGamma: Bool = false) {
        self.angle = angle
        self.stops = stops
        self.linearGamma = linearGamma
    }
}

public enum InlineCase: Hashable {
    case lower, upper, proper, sentence
}

/// A parsed `InlineSetting` value (`Name | param | param…`).
public enum InlineSetting: Hashable {
    case face(String)
    /// Rainmeter points (96 DPI), like FontSize.
    case size(Double)
    case color(RGBA)
    /// 1…999.
    case weight(Int)
    /// Applied to the text by the String meter itself (never present in `TextStyle.inlineSpans`).
    case textCase(InlineCase)
    /// DIP (= skin points). Missing / `*` parameters are 0.
    case characterSpacing(leading: Double, trailing: Double, minimumAdvance: Double)
    case italic
    case oblique
    case underline
    case strikethrough
    /// Offsets and blur in pixels; the color's alpha is multiplied with the text's alpha.
    case shadow(offsetX: Double, offsetY: Double, blur: Double, color: RGBA)
    /// 1 (ultra-condensed) … 5 (normal) … 9 (ultra-expanded).
    case stretch(Int)
    /// OpenType feature tag (`smcp`, `onum`, `ss01`…) and value (index, default 1).
    case typography(feature: String, value: Int)
    case gradient(InlineGradient)
    /// `None`: no effect (used to switch a setting off with !SetOption).
    case none

    /// Largest accepted inline Size (Rainmeter points). Judgment: bounds glyph and layout sizes.
    public static let maximumSize = 1000.0

    /// Parses `Name | params`. Names are case-insensitive; returns nil for unknown names or unusable parameters.
    ///
    /// Judgment calls (the manual only documents well-formed values):
    /// - `Size` must be > 0 (the history mentions a "work-around for when InlineSetting=Size is 0 or negative";
    ///   such a setting is ignored). Numbers may be formulas in parentheses.
    /// - `Weight` is clamped to 1…999, `Stretch` to 1…9.
    /// - `Shadow`: missing offsets / blur are 0, a missing color is black; blur is at least 0.
    /// - `GradientColor`: a stop without a percentage is spread evenly between its neighbours' positions (first
    ///   0, last 1); positions are clamped to 0…1 and sorted. Fewer than two stops → ignored.
    /// - `Typography`: the code must be 1–4 ASCII letters / digits (OpenType tag); the index defaults to 1.
    public static func parse(_ raw: String) -> InlineSetting? {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let name = parts.first?.lowercased(), !name.isEmpty else { return nil }
        let params = Array(parts.dropFirst())
        func param(_ i: Int) -> String { i < params.count ? params[i] : "" }
        func number(_ i: Int) -> Double? {
            let p = param(i)
            guard !p.isEmpty, p != "*", let v = OptionValue.number(p), v.isFinite else { return nil }
            return v
        }

        switch name {
        case "face":
            let face = unquoted(param(0))
            return face.isEmpty ? nil : .face(face)
        case "size":
            guard let v = number(0), v > 0 else { return nil }
            return .size(min(v, maximumSize))
        case "color":
            return OptionValue.color(param(0)).map { .color($0) }
        case "weight":
            guard let v = number(0) else { return nil }
            return .weight(Int(v.clamped(1, 999).rounded()))
        case "case":
            switch param(0).lowercased() {
            case "lower": return .textCase(.lower)
            case "upper": return .textCase(.upper)
            case "proper": return .textCase(.proper)
            case "sentence": return .textCase(.sentence)
            default: return nil
            }
        case "characterspacing":
            return .characterSpacing(leading: (number(0) ?? 0).clamped(-1000, 1000),
                                     trailing: (number(1) ?? 0).clamped(-1000, 1000),
                                     minimumAdvance: (number(2) ?? 0).clamped(0, 1000))
        case "italic": return .italic
        case "oblique": return .oblique
        case "underline": return .underline
        case "strikethrough": return .strikethrough
        case "shadow":
            let color = OptionValue.color(param(3)) ?? .black
            return .shadow(offsetX: (number(0) ?? 0).clamped(-1000, 1000), offsetY: (number(1) ?? 0).clamped(-1000, 1000),
                           blur: (number(2) ?? 0).clamped(0, 1000), color: color)
        case "stretch":
            guard let v = number(0) else { return nil }
            return .stretch(Int(v.clamped(1, 9).rounded()))
        case "typography":
            let tag = param(0)
            guard (1...4).contains(tag.count), tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else { return nil }
            let index = number(1).map { Int($0.clamped(0, 65535).rounded()) } ?? 1
            return .typography(feature: tag, value: index)
        case "gradientcolor", "gradientcolor1":
            return parseGradient(params, linearGamma: name == "gradientcolor1").map { .gradient($0) }
        case "none":
            return InlineSetting.none
        default:
            return nil
        }
    }

    private static func unquoted(_ s: String) -> String {
        if s.count >= 2, let f = s.first, f == s.last, f == "\"" || f == "'" {
            return String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    private static func parseGradient(_ params: [String], linearGamma: Bool) -> InlineGradient? {
        guard let first = params.first, let angle = OptionValue.number(first), angle.isFinite else { return nil }
        var colors: [RGBA] = []
        var positions: [Double?] = []
        for stop in params.dropFirst().prefix(256) {
            let pieces = stop.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let colorText = pieces.first, let color = OptionValue.color(colorText) else { continue }
            colors.append(color)
            let position = pieces.count > 1 ? OptionValue.number(pieces[1]).flatMap { $0.isFinite ? $0 : nil } : nil
            positions.append(position.map { $0.clamped(0, 1) })
        }
        guard colors.count >= 2 else { return nil }
        // Fill in missing positions by spreading evenly between known neighbours.
        if positions[0] == nil { positions[0] = 0 }
        if positions[positions.count - 1] == nil { positions[positions.count - 1] = 1 }
        var i = 0
        while i < positions.count {
            if positions[i] == nil {
                let lo = i - 1
                var hi = i
                while positions[hi] == nil { hi += 1 }
                let a = positions[lo] ?? 0, b = positions[hi] ?? 1
                for k in i..<hi { positions[k] = a + (b - a) * Double(k - lo) / Double(hi - lo) }
                i = hi
            }
            i += 1
        }
        let stops = zip(colors, positions).enumerated()
            .map { (offset: $0.offset, stop: GradientStop(color: $0.element.0, position: $0.element.1 ?? 0)) }
            .sorted { $0.stop.position != $1.stop.position ? $0.stop.position < $1.stop.position : $0.offset < $1.offset }
            .map(\.stop)
        let normalizedAngle = angle.truncatingRemainder(dividingBy: 360)
        return InlineGradient(angle: normalizedAngle < 0 ? normalizedAngle + 360 : normalizedAngle, stops: stops,
                              linearGamma: linearGamma)
    }
}
