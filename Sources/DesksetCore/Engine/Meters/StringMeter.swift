import Foundation

/// `Meter=String`: text from `Text` / bound measures, styled with the Font* options, StringAlign, ClipString and
/// inline options. Measuring and drawing are done by the host from `text` + `style` (see `TextStyle`).
///
/// Clean-room implementation from the public manual only (https://docs.rainmeter.net/manual/meters/string/ and
/// …/string/inline/, the general meter options and the release notes). Rules implemented here:
/// - `Text` (default `%1` when `MeasureName` is given, otherwise empty; an empty value counts as not set) with
///   `%1…%N` replaced by the string values of `MeasureName…MeasureNameN`; `Prefix` / `Postfix` around it; then
///   `StringCase`. The result is capped at `maximumTextLength` UTF-16 units.
/// - Numbers of bound measures use `NumOfDecimals`, `Scale`, `AutoScale`, `Percentual` (formulas allowed).
/// - `TrailingSpaces=0` (default) trims leading / trailing spaces of the `Text` option; `1` keeps them.
/// - `StringAlign`: X / Y are the anchor. Right / Center shift the meter box left by its full / half width,
///   Bottom / Center shift it up by its full / half height (W / H included when given), so e.g. X=50, Y=50,
///   W=100, H=100, StringAlign=CenterCenter centers the text in the 0…100 box. `[Meter:X]` is the shifted box;
///   the next meter's `r` / `R` are relative to the anchor (see `Meter`).
/// - An empty text has no size, except when a bound measure has no value on the Mac (see `emptyTextSize`).
/// - `ClipString` 1 clips with an ellipsis at W (wrapping while H allows more lines); 2 wraps on spaces/tabs at
///   W or ClipStringW, grows to the text size up to ClipStringW / ClipStringH, and clips words that do not fit.
/// - `Angle` does not change size or position (the box stays where the horizontal text would be).
/// - Inline options: `InlineSettingN` + `InlinePatternN` (PCRE, default `.*`); capture groups select what is
///   formatted, otherwise the whole match; every match counts; applied to the final displayed string.
public final class StringMeter: Meter {
    /// The final displayed text (after Prefix/Postfix, StringCase and inline Case settings).
    public private(set) var text = ""
    public private(set) var style = TextStyle()

    private var template: String?
    private var prefix = ""
    private var postfix = ""
    private var numberFormat = NumberFormatOptions()
    private var stringCase: InlineCase?
    /// `MeasureNameN` index → measure (nil when the name is set but no such measure exists).
    private var boundMeasures: [Int: Measure?] = [:]
    private var clipStringW: Double?
    private var clipStringH: Double?
    private var inlineRules: [InlineRule] = []
    private var inlineCache: (source: String, rules: [InlineRule], text: String, spans: [InlineSpan])?
    private var loggedPatterns: Set<String> = []
    /// Unsupported `InlineSettingN=value` already reported (options are re-read on every update when dynamic).
    private var loggedSettings: Set<String> = []
    /// `@Resources/Fonts` of the root config (see `TextStyle.fontFolder`).
    private lazy var fontFolder = skin.resourcesDirectory.appendingPathComponent("Fonts", isDirectory: true).path

    struct InlineRule: Hashable {
        var setting: InlineSetting
        var pattern: String
    }

    /// Judgment: longer texts are cut (keeps layout and inline matching bounded for runaway measure values).
    static let maximumTextLength = 32_768
    /// Judgment: at most this many inline ranges per meter.
    static let maximumInlineSpans = 4_096
    /// Judgment: FontSize is clamped to 0…1000 points.
    static let maximumFontSize = 1000.0

    // MARK: Options

    public override func readMeterOptions() {
        var s = TextStyle()
        let face = string("FontFace", "Arial").trimmingCharacters(in: .whitespaces)
        // "Arial is now the default font when FontFace is not specified or errors occur."
        s.fontFace = face.isEmpty ? "Arial" : face
        let size = double("FontSize", 10)
        // "FontSize=0 (invisible) is now valid"; negative sizes count as 0.
        s.fontSize = size.isFinite ? size.clamped(0, StringMeter.maximumFontSize) : 10
        s.fontWeight = optionalDouble("FontWeight").flatMap { $0.isFinite ? Int($0.clamped(1, 999).rounded()) : nil }
        switch string("StringStyle", "Normal").trimmingCharacters(in: .whitespaces).lowercased() {
        case "bold": s.bold = true
        case "italic": s.italic = true
        case "bolditalic": s.bold = true; s.italic = true
        default: break
        }
        s.color = color("FontColor", .black)
        let align = StringMeter.parseAlign(string("StringAlign", "Left"))
        s.horizontalAlign = align.horizontal
        s.verticalAlign = align.vertical
        switch string("StringEffect", "None").trimmingCharacters(in: .whitespaces).lowercased() {
        case "shadow": s.effect = .shadow
        case "border": s.effect = .border
        default: s.effect = .none
        }
        s.effectColor = color("FontEffectColor", .black)
        let angle = double("Angle", 0)
        s.angle = angle.isFinite ? angle.truncatingRemainder(dividingBy: 2 * .pi) : 0
        s.antiAlias = antiAlias
        s.accurateText = skin.settings.accurateText
        s.fontFolder = fontFolder
        s.trailingSpaces = bool("TrailingSpaces", false)

        // ClipStringW / ClipStringH: Judgment: values <= 0 count as "not set".
        clipStringW = optionalDouble("ClipStringW").flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        clipStringH = optionalDouble("ClipStringH").flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        switch int("ClipString", 0) {
        case 1:
            // Clipping needs a width; with H as well, text wraps until H is reached.
            s.clip = widthOption == nil ? 0 : 1
            s.wrap = widthOption != nil && heightOption != nil
            s.breakLongWords = true
        case 2:
            s.clip = 2
            s.wrap = (widthOption ?? clipStringW) != nil
            s.breakLongWords = false
        default:
            // Judgment: any other value behaves like 0.
            s.clip = 0
        }

        template = option("Text")
        // An empty value is "not set" (the !SetOption guide: setting "" removes the option), so `Text=` or
        // `[!SetOption Meter Text ""]` shows the bound measure again.
        if template?.isEmpty == true { template = nil }
        if let t = template, !s.trailingSpaces {
            template = t.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        prefix = string("Prefix")
        postfix = string("Postfix")
        numberFormat = numberFormatOptions()
        switch string("StringCase", "None").trimmingCharacters(in: .whitespaces).lowercased() {
        case "upper": stringCase = .upper
        case "lower": stringCase = .lower
        case "proper": stringCase = .proper
        default: stringCase = nil
        }

        boundMeasures = [:]
        for entry in numberedOptions("MeasureName") {
            let measureName = entry.value.trimmingCharacters(in: .whitespaces)
            boundMeasures[entry.index] = measureName.isEmpty ? .some(nil) : .some(skin.measure(named: measureName))
        }
        inlineRules = readInlineRules()
        s.inlineSpans = style.inlineSpans
        style = s
    }

    /// `InlineSetting`, `InlineSetting2`… with their patterns. "There may not be missing N number postfixes in
    /// InlineSetting, which start with 2", and an empty value "removes" the option, after which "all subsequent
    /// ones will be ignored" — so the list ends at the first missing or empty entry, `InlineSetting` itself
    /// included. A missing or empty `InlinePatternN` means `.*` (the whole string).
    private func readInlineRules() -> [InlineRule] {
        var rules: [InlineRule] = []
        for i in 1...1000 {
            let suffix = i == 1 ? "" : String(i)
            let value = option("InlineSetting\(suffix)")?.trimmingCharacters(in: .whitespaces) ?? ""
            if value.isEmpty { break }
            guard let setting = InlineSetting.parse(value) else {
                let message = "[\(name)] InlineSetting\(suffix)=\(value) is not supported"
                if loggedSettings.count < 64, loggedSettings.insert(message).inserted {
                    skin.log(message, level: .warning)
                }
                continue
            }
            let pattern = option("InlinePattern\(suffix)") ?? ""
            rules.append(InlineRule(setting: setting, pattern: pattern.isEmpty ? ".*" : pattern))
        }
        return rules
    }

    static func parseAlign(_ raw: String) -> (horizontal: HorizontalTextAlign, vertical: VerticalTextAlign) {
        let key = raw.lowercased().filter { !$0.isWhitespace }
        let horizontal: HorizontalTextAlign
        var rest: Substring
        if key.hasPrefix("left") {
            horizontal = .left
            rest = key.dropFirst(4)
        } else if key.hasPrefix("right") {
            horizontal = .right
            rest = key.dropFirst(5)
        } else if key.hasPrefix("center") {
            horizontal = .center
            rest = key.dropFirst(6)
        } else {
            // Judgment: unknown values use the default (LeftTop).
            return (.left, .top)
        }
        if rest.isEmpty { rest = "top" }
        switch rest {
        case "center": return (horizontal, .center)
        case "bottom": return (horizontal, .bottom)
        default: return (horizontal, .top)
        }
    }

    // MARK: Update

    public override func updateMeter() {
        composed = true
        var result = prefix + composeBody() + postfix
        if let stringCase { result = StringMeter.applyCase(stringCase, to: result, preserveLength: false) }
        result = StringMeter.truncated(result, maximumUTF16: StringMeter.maximumTextLength)
        applyInlineRules(to: result)
    }

    /// Whether `text` has been composed (by an update, or for a provisional layout).
    private var composed = false

    /// Before its first update the meter has no text; a provisional layout (`Skin.ensureMeterGeometry`) measures
    /// the text composed from the options and the bound measures' current values. Composing has no side effects
    /// beyond `text` / the inline spans, which the first update composes again.
    public override func prepareProvisionalLayout() {
        if !composed { updateMeter() }
    }

    /// Cuts `text` to at most `maximumUTF16` UTF-16 units, at a scalar boundary (a Character can be arbitrarily
    /// long — e.g. a letter with thousands of combining marks — so counting Characters would not bound the size).
    static func truncated(_ text: String, maximumUTF16: Int) -> String {
        guard text.utf16.count > maximumUTF16 else { return text }
        var out = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let length = scalar.value > 0xFFFF ? 2 : 1
            if used + length > maximumUTF16 { break }
            out.append(scalar)
            used += length
        }
        return String(out)
    }

    private func composeBody() -> String {
        let highest = boundMeasures.keys.max() ?? 0
        guard let template = template ?? (boundMeasures[1] != nil ? "%1" : nil) else { return "" }
        guard highest > 0, template.contains("%") else { return template }
        return StringMeter.substitute(template, count: highest) { index in
            guard let bound = boundMeasures[index] else { return nil }
            return bound?.text(numberFormat: numberFormat) ?? ""
        }
    }

    /// Replaces `%N` with `value(N)`. Digits are read greedily but only as far as they form an index ≤ `count`
    /// (so `%12` with two measures is `%1` followed by "2"); unbound indices (value nil) stay literal. Single pass:
    /// measure values are never scanned for `%N` again.
    static func substitute(_ template: String, count: Int, value: (Int) -> String?) -> String {
        func digit(_ c: Unicode.Scalar) -> Int? {
            c.value >= 48 && c.value <= 57 ? Int(c.value - 48) : nil
        }
        var out = ""
        let chars = Array(template.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%" {
                var number = 0
                var j = i + 1
                while j < chars.count, let d = digit(chars[j]), number * 10 + d <= count {
                    number = number * 10 + d
                    j += 1
                }
                if number >= 1, let v = value(number) {
                    out += v
                    i = j
                    continue
                }
            }
            out.unicodeScalars.append(c)
            i += 1
        }
        return out
    }

    private func applyInlineRules(to source: String) {
        if inlineRules.isEmpty {
            text = source
            if !style.inlineSpans.isEmpty { style.inlineSpans = [] }
            return
        }
        if let cache = inlineCache, cache.source == source, cache.rules == inlineRules {
            text = cache.text
            style.inlineSpans = cache.spans
            return
        }
        let result = StringMeter.inlineSpans(for: source, rules: inlineRules) { [weak self] pattern in
            // Bounded: a dynamic pattern built from changing values could otherwise log (and remember) forever.
            guard let self, self.loggedPatterns.count < 64, self.loggedPatterns.insert(pattern).inserted else { return }
            self.skin.log("[\(self.name)] invalid InlinePattern: \(pattern)", level: .warning)
        }
        inlineCache = (source, inlineRules, result.text, result.spans)
        text = result.text
        style.inlineSpans = result.spans
    }

    /// Matches every rule against `text`. Case settings are applied to the text (length-preserving, so the other
    /// ranges stay valid); everything else becomes a span. Invalid patterns are reported through `invalid`.
    static func inlineSpans(for text: String, rules: [InlineRule],
                            invalid: (String) -> Void = { _ in }) -> (text: String, spans: [InlineSpan]) {
        var spans: [InlineSpan] = []
        var caseOps: [(NSRange, InlineCase)] = []
        rules: for rule in rules {
            if case .none = rule.setting { continue }
            guard let matches = PCRE.allMatches(rule.pattern, in: text) else {
                invalid(rule.pattern)
                continue
            }
            for match in matches {
                var ranges: [NSRange] = []
                if match.numberOfRanges > 1 {
                    for group in 1..<match.numberOfRanges {
                        let r = match.range(at: group)
                        if r.location != NSNotFound, r.length > 0 { ranges.append(r) }
                    }
                } else if match.range.location != NSNotFound, match.range.length > 0 {
                    ranges.append(match.range)
                }
                for r in ranges {
                    if spans.count + caseOps.count >= maximumInlineSpans { break rules }
                    if case .textCase(let mode) = rule.setting {
                        caseOps.append((r, mode))
                    } else {
                        spans.append(InlineSpan(location: r.location, length: r.length, setting: rule.setting))
                    }
                }
            }
        }
        guard !caseOps.isEmpty else { return (text, spans) }
        let mutable = NSMutableString(string: text)
        for (range, mode) in caseOps where range.location + range.length <= mutable.length {
            let sub = mutable.substring(with: range)
            let transformed = applyCase(mode, to: sub, preserveLength: true)
            if transformed != sub { mutable.replaceCharacters(in: range, with: transformed) }
        }
        return (mutable as String, spans)
    }

    /// Case conversion. `proper`: the first letter of each word (words are separated by whitespace) upper case,
    /// the rest lower case; `sentence`: the first letter of each sentence (after `.`, `!` or `?` followed by
    /// whitespace) upper case, the rest lower case. With `preserveLength`, a character whose conversion would
    /// change its UTF-16 length (e.g. ß → SS) is kept as is (inline ranges must stay valid).
    static func applyCase(_ mode: InlineCase, to text: String, preserveLength: Bool) -> String {
        func convert(_ c: Character, upper: Bool) -> String {
            let s = String(c)
            let t = upper ? s.uppercased() : s.lowercased()
            return !preserveLength || t.utf16.count == s.utf16.count ? t : s
        }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        switch mode {
        case .upper, .lower:
            if !preserveLength { return mode == .upper ? text.uppercased() : text.lowercased() }
            for c in text { out += convert(c, upper: mode == .upper) }
        case .proper:
            var wordStart = true
            for c in text {
                if c.isWhitespace {
                    wordStart = true
                    out.append(c)
                } else if c.isLetter {
                    out += convert(c, upper: wordStart)
                    wordStart = false
                } else {
                    if c.isNumber { wordStart = false }
                    out.append(c)
                }
            }
        case .sentence:
            var sentenceStart = true
            var afterTerminator = false
            for c in text {
                if c.isLetter {
                    out += convert(c, upper: sentenceStart)
                    sentenceStart = false
                    afterTerminator = false
                } else {
                    if c == "." || c == "!" || c == "?" {
                        afterTerminator = true
                    } else if c.isWhitespace {
                        if afterTerminator { sentenceStart = true }
                    } else {
                        if c.isNumber { sentenceStart = false }
                        afterTerminator = false
                    }
                    out.append(c)
                }
            }
        }
        return out
    }

    // MARK: Layout

    public override func naturalSize() -> (width: Double, height: Double) {
        guard !text.isEmpty else { return emptyTextSize() }
        guard let host = skin.host else {
            let px = TextStyle.pixelSize(points: style.fontSize)
            return (Double(text.count) * px * 0.6, px * 1.2)
        }
        switch style.clip {
        case 2:
            let maxWidth = widthOption ?? clipStringW
            var size = host.textSize(text, style: style, wrapWidth: maxWidth)
            // A word longer than the (maximum) width is clipped, the meter does not grow past it.
            if let maxWidth { size.width = min(size.width, maxWidth) }
            if heightOption == nil, let maxHeight = clipStringH { size.height = min(size.height, maxHeight) }
            return size
        default:
            return host.textSize(text, style: style, wrapWidth: nil)
        }
    }

    /// Size of a meter whose text is empty.
    ///
    /// Rainmeter: an empty string has no size (history, 3.0: "Fixed an issue with Direct2D where a string meter
    /// with an empty string would still have a width and height"). Mac: when the text is empty only because a
    /// bound measure cannot provide its value here (`Measure.valueUnavailable`: a Windows-only plugin such as
    /// CoreTemp, a registry value that is not emulated…), the meter keeps the height of one line of its font and
    /// width 0. On Windows that measure has a value, so rows stacked below it with `Y=5R` (FluentDash11's CPU / GPU
    /// panels: "CPU Name:", "CPU Speed:"…) keep their spacing instead of collapsing onto each other.
    private func emptyTextSize() -> (width: Double, height: Double) {
        guard style.fontSize > 0, boundMeasures.values.contains(where: { $0?.valueUnavailable == true })
        else { return (0, 0) }
        guard let host = skin.host else { return (0, TextStyle.pixelSize(points: style.fontSize) * 1.2) }
        var probe = style
        probe.inlineSpans = []
        // Any one-line text has the line height of the font; its width is not used.
        return (0, host.textSize("X", style: probe, wrapWidth: nil).height)
    }

    public override func anchorOffset(width: Double, height: Double) -> (dx: Double, dy: Double) {
        let dx: Double
        switch style.horizontalAlign {
        case .left: dx = 0
        case .center: dx = -width / 2
        case .right: dx = -width
        }
        let dy: Double
        switch style.verticalAlign {
        case .top: dy = 0
        case .center: dy = -height / 2
        case .bottom: dy = -height
        }
        return (dx, dy)
    }

    /// The StringAlign anchor (the resolved X / Y position) in skin coordinates; `Angle` rotates around it.
    public var anchorPoint: (x: Double, y: Double) { (anchorX, anchorY) }
}
