import Foundation

/// `Meter=TextEdit`: interactive or bang-driven single-line / multiline text input meter (Rainmeter 5.0).
///
/// Clean-room implementation from the public manual only (`https://docs-v5.rainmeter.net/manual/meters/textedit/`):
/// - Supports standard String formatting options (`FontFace`, `FontSize`, `FontColor`, `FontWeight`, `StringAlign`,
///   `StringStyle`, `StringEffect`, `FontEffectColor`, `ClipString`, `ClipStringW`, `ClipStringH`, `StringCase`,
///   and `InlineSetting` / `InlinePattern`). Does not use `Text`; uses `InitialText` and `PlaceholderText`.
/// - `InitialText` sets the starting text at initialization and on `!TextEdit:Reset` (not modified by `!SetOption`).
/// - `PlaceholderText` (with `PlaceholderFontColor`, `PlaceholderFontFace`, `PlaceholderFontSize`,
///   `PlaceholderStringStyle`) is displayed when the current input text is empty.
/// - `Multiline` (default `0`), `SubmitOnEnter` (default `1` when single-line, `0` when multiline), `MaxLength`
///   (default `0` = unlimited), `InputCase` (`None|Upper|Lower|Proper|Sentence`), `Password` (default `0`, masks
///   displayed text with `●`), `ReadOnly` (default `0`), `InputFilter` (`None|Integer|Decimal|Numeric|RegExp`),
///   `InputRegExp`.
/// - Actions `OnFocusAction`, `OnSubmitAction`, `OnDismissAction` populate `[$Input]` and `[$Input:MatchN]` while
///   running.
/// - Bangs: `!TextEdit:Focus`, `!TextEdit:Dismiss`, `!TextEdit:Submit`, `!TextEdit:Clear`, `!TextEdit:Reset`,
///   `!TextEdit:SetText`, `!TextEdit:ScrollByLine`, `!TextEdit:ResetScroll`, `!TextEdit:SelectAll`,
///   `!TextEdit:Select`.
public final class TextEditMeter: Meter {
    public enum InputFilterMode: String, Equatable, Sendable {
        case none
        case integer
        case decimal
        case numeric
        case regExp
    }

    /// The current unmasked input text (excluding placeholder text).
    public private(set) var inputText = ""
    /// The final displayed text (either placeholder text, or masked/cased/inline-formatted `inputText`).
    public private(set) var text = ""
    /// The resolved style for `text` (includes placeholder overrides when showing placeholder, or inline spans).
    public private(set) var style = TextStyle()

    public private(set) var multiline = false
    public private(set) var submitOnEnter = true
    public private(set) var placeholderText = ""
    public private(set) var caretColor: RGBA = .white
    public private(set) var selectionColor = RGBA(r: 0, g: 60, b: 107, a: 255)
    public private(set) var focusBorderWidth = 0.0
    public private(set) var focusBorderColor: RGBA = .black
    public private(set) var maxLength = 0
    public private(set) var password = false
    public private(set) var readOnly = false
    public private(set) var inputFilter: InputFilterMode = .none
    public private(set) var inputRegExp = ""

    public private(set) var onFocusAction = ""
    public private(set) var onSubmitAction = ""
    public private(set) var onDismissAction = ""

    public private(set) var isFocused = false
    public private(set) var selectionRange: Range<Int> = 0..<0
    public private(set) var scrollLineOffset = 0

    public var isShowingPlaceholder: Bool {
        inputText.isEmpty && !placeholderText.isEmpty
    }

    private var baseStyle = TextStyle()
    private var placeholderFontColor: RGBA?
    private var placeholderFontFace: String?
    private var placeholderFontSize: Double?
    private var placeholderStringStyle: String?
    private var stringCase: InlineCase?
    private var inputCase: InlineCase?
    private var clipStringW: Double?
    private var clipStringH: Double?
    private var inlineRules: [StringMeter.InlineRule] = []
    private var inlineCache: (source: String, rules: [StringMeter.InlineRule], text: String, spans: [InlineSpan])?
    private var loggedPatterns: Set<String> = []
    private var loggedSettings: Set<String> = []
    private var initializedInitialText = false
    private var composed = false

    private lazy var fontFolder = skin.resourcesDirectory.appendingPathComponent("Fonts", isDirectory: true).path

    public override var handlesMouseItself: Bool { true }

    // MARK: - Options

    public override func readMeterOptions() {
        var s = TextStyle()
        let face = string("FontFace", "Arial").trimmingCharacters(in: .whitespaces)
        s.fontFace = face.isEmpty ? "Arial" : face
        let size = double("FontSize", 10)
        s.fontSize = size.isFinite ? size.clamped(0, StringMeter.maximumFontSize) : 10
        s.fontWeight = optionalDouble("FontWeight").flatMap { $0.isFinite ? Int($0.clamped(1, 999).rounded()) : nil }
        applyStringStyle(string("StringStyle", "Normal"), to: &s)
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
        s.trailingSpaces = true

        clipStringW = optionalDouble("ClipStringW").flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        clipStringH = optionalDouble("ClipStringH").flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        switch int("ClipString", 0) {
        case 1:
            s.clip = widthOption == nil ? 0 : 1
            s.wrap = widthOption != nil && heightOption != nil
            s.breakLongWords = true
        case 2:
            s.clip = 2
            s.wrap = (widthOption ?? clipStringW) != nil
            s.breakLongWords = false
        default:
            s.clip = 0
        }

        multiline = bool("Multiline", false)
        if let explicitSubmit = optionalDouble("SubmitOnEnter"), explicitSubmit.isFinite {
            submitOnEnter = Int(explicitSubmit) != 0
        } else {
            submitOnEnter = !multiline
        }

        placeholderText = string("PlaceholderText")
        placeholderFontColor = option("PlaceholderFontColor").flatMap(OptionValue.color)
        let pFace = string("PlaceholderFontFace").trimmingCharacters(in: .whitespaces)
        placeholderFontFace = pFace.isEmpty ? nil : pFace
        placeholderFontSize = optionalDouble("PlaceholderFontSize").flatMap {
            $0.isFinite ? $0.clamped(0, StringMeter.maximumFontSize) : nil
        }
        let pStyle = string("PlaceholderStringStyle").trimmingCharacters(in: .whitespaces)
        placeholderStringStyle = pStyle.isEmpty ? nil : pStyle

        caretColor = color("CaretColor", .white)
        selectionColor = color("SelectionColor", RGBA(r: 0, g: 60, b: 107, a: 255))
        let fbw = double("FocusBorderWidth", 0)
        focusBorderWidth = fbw.isFinite ? max(0, fbw) : 0
        focusBorderColor = color("FocusBorderColor", .black)
        maxLength = max(0, int("MaxLength", 0))
        password = bool("Password", false)
        readOnly = bool("ReadOnly", false)

        stringCase = Self.parseCase(string("StringCase", "None"))
        inputCase = Self.parseCase(string("InputCase", "None"))

        switch string("InputFilter", "None").trimmingCharacters(in: .whitespaces).lowercased() {
        case "integer": inputFilter = .integer
        case "decimal": inputFilter = .decimal
        case "numeric": inputFilter = .numeric
        case "regexp": inputFilter = .regExp
        default: inputFilter = .none
        }
        inputRegExp = string("InputRegExp")

        onFocusAction = actionOption("OnFocusAction")
        onSubmitAction = actionOption("OnSubmitAction")
        onDismissAction = actionOption("OnDismissAction")

        inlineRules = readInlineRules()
        baseStyle = s

        if !initializedInitialText {
            initializedInitialText = true
            inputText = normalizedInput(readInitialText(), checkFilter: false)
        } else {
            inputText = normalizedInput(inputText, checkFilter: false)
        }
        clampSelection()
        composeDisplayedText()
    }

    private func applyStringStyle(_ raw: String, to style: inout TextStyle) {
        style.bold = false
        style.italic = false
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "bold": style.bold = true
        case "italic": style.italic = true
        case "bolditalic": style.bold = true; style.italic = true
        default: break
        }
    }

    private static func parseCase(_ raw: String) -> InlineCase? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "upper": return .upper
        case "lower": return .lower
        case "proper": return .proper
        case "sentence": return .sentence
        default: return nil
        }
    }

    /// Reads `InitialText` from the section definition, ignoring `!SetOption` overrides (`InitialText` cannot be
    /// altered with `!SetOption`).
    private func readInitialText() -> String {
        guard let raw = fileOption("InitialText") else { return "" }
        return skin.resolve(raw, in: self, sectionVariables: dynamicVariables)
    }

    private func readInlineRules() -> [StringMeter.InlineRule] {
        var rules: [StringMeter.InlineRule] = []
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
            rules.append(StringMeter.InlineRule(setting: setting, pattern: pattern.isEmpty ? ".*" : pattern))
        }
        return rules
    }

    // MARK: - Update & Composition

    public override func updateMeter() {
        composed = true
        composeDisplayedText()
    }

    public override func prepareProvisionalLayout() {
        if !composed { updateMeter() }
    }

    private func composeDisplayedText() {
        if isShowingPlaceholder {
            var pStyle = baseStyle
            if let c = placeholderFontColor { pStyle.color = c }
            if let f = placeholderFontFace { pStyle.fontFace = f }
            if let sz = placeholderFontSize { pStyle.fontSize = sz }
            if let st = placeholderStringStyle { applyStringStyle(st, to: &pStyle) }
            pStyle.inlineSpans = []
            style = pStyle
            text = StringMeter.truncated(placeholderText, maximumUTF16: StringMeter.maximumTextLength)
            return
        }

        var shown = inputText
        if password {
            shown = String(repeating: "\u{25CF}", count: shown.count)
        } else if let stringCase {
            shown = StringMeter.applyCase(stringCase, to: shown, preserveLength: false)
        }
        shown = StringMeter.truncated(shown, maximumUTF16: StringMeter.maximumTextLength)

        var activeStyle = baseStyle
        if inlineRules.isEmpty {
            activeStyle.inlineSpans = []
            text = shown
        } else if let cache = inlineCache, cache.source == shown, cache.rules == inlineRules {
            activeStyle.inlineSpans = cache.spans
            text = cache.text
        } else {
            let result = StringMeter.inlineSpans(for: shown, rules: inlineRules) { [weak self] pattern in
                guard let self, self.loggedPatterns.count < 64, self.loggedPatterns.insert(pattern).inserted else { return }
                self.skin.log("[\(self.name)] invalid InlinePattern: \(pattern)", level: .warning)
            }
            inlineCache = (shown, inlineRules, result.text, result.spans)
            activeStyle.inlineSpans = result.spans
            text = result.text
        }
        style = activeStyle
    }

    // MARK: - Input Filtering & Normalization

    private func normalizedInput(_ raw: String, checkFilter: Bool) -> String {
        var result = raw
        if !multiline {
            result = result.replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
        }
        if let inputCase {
            result = StringMeter.applyCase(inputCase, to: result, preserveLength: false)
        }
        if maxLength > 0, result.count > maxLength {
            result = String(result.prefix(maxLength))
        }
        if checkFilter, !result.isEmpty, !matchesInputFilter(result) {
            return inputText
        }
        return StringMeter.truncated(result, maximumUTF16: StringMeter.maximumTextLength)
    }

    public func matchesInputFilter(_ candidate: String) -> Bool {
        if candidate.isEmpty { return true }
        switch inputFilter {
        case .none:
            return true
        case .numeric:
            return candidate.allSatisfy { $0.isASCII && $0.isNumber }
        case .integer:
            let body = candidate.hasPrefix("-") ? candidate.dropFirst() : Substring(candidate)
            return body.allSatisfy { $0.isASCII && $0.isNumber }
        case .decimal:
            let body = candidate.hasPrefix("-") ? candidate.dropFirst() : Substring(candidate)
            var dots = 0
            for ch in body {
                if ch == "." {
                    dots += 1
                    if dots > 1 { return false }
                } else if !(ch.isASCII && ch.isNumber) {
                    return false
                }
            }
            return true
        case .regExp:
            guard !inputRegExp.isEmpty else { return true }
            guard let match = PCRE.allMatches(inputRegExp, in: candidate)?.first else { return false }
            return match.range.location == 0 && match.range.length == (candidate as NSString).length
        }
    }

    /// Value exposed as `[$Input]` and matched against `InputRegExp` for `[$Input:MatchN]` during actions.
    public var actionInputValue: String {
        if !password, let stringCase {
            return StringMeter.applyCase(stringCase, to: inputText, preserveLength: false)
        }
        return inputText
    }

    /// Computes capture groups for `[$Input:Match0]`, `[$Input:Match1]`, ... from `InputRegExp`.
    public func actionInputMatches(for value: String) -> [String] {
        guard !inputRegExp.isEmpty, let match = PCRE.allMatches(inputRegExp, in: value)?.first else { return [] }
        let ns = value as NSString
        var groups: [String] = []
        groups.reserveCapacity(match.numberOfRanges)
        for i in 0..<match.numberOfRanges {
            let r = match.range(at: i)
            if r.location != NSNotFound, r.location + r.length <= ns.length {
                groups.append(ns.substring(with: r))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    private func clampSelection() {
        let count = inputText.count
        let lower = min(max(0, selectionRange.lowerBound), count)
        let upper = min(max(lower, selectionRange.upperBound), count)
        selectionRange = lower..<upper
    }

    // MARK: - Bangs & Interaction

    public func focus() {
        for case let other as TextEditMeter in skin.meters where other !== self && other.isFocused {
            other.dismiss()
        }
        isFocused = true
        composeDisplayedText()
        noteDrawChange()
        if !onFocusAction.isEmpty {
            skin.executeWithTextEditInput(from: self, action: onFocusAction)
        }
    }

    public func dismiss() {
        guard isFocused else { return }
        isFocused = false
        selectionRange = 0..<0
        composeDisplayedText()
        noteDrawChange()
        if !onDismissAction.isEmpty {
            skin.executeWithTextEditInput(from: self, action: onDismissAction)
        }
    }

    public func submit() {
        isFocused = false
        selectionRange = 0..<0
        composeDisplayedText()
        noteDrawChange()
        if !onSubmitAction.isEmpty {
            skin.executeWithTextEditInput(from: self, action: onSubmitAction)
        }
    }

    public func clear() {
        inputText = ""
        selectionRange = 0..<0
        scrollLineOffset = 0
        composeDisplayedText()
        noteDrawChange()
    }

    public func reset() {
        inputText = normalizedInput(readInitialText(), checkFilter: false)
        selectionRange = 0..<0
        scrollLineOffset = 0
        composeDisplayedText()
        noteDrawChange()
    }

    public func setText(_ newText: String) {
        inputText = normalizedInput(newText, checkFilter: true)
        clampSelection()
        composeDisplayedText()
        noteDrawChange()
    }

    public func scrollByLine(_ delta: Int) {
        scrollLineOffset = max(0, scrollLineOffset + delta)
        noteDrawChange()
    }

    public func resetScroll() {
        scrollLineOffset = 0
        noteDrawChange()
    }

    public func selectAll() {
        selectionRange = 0..<inputText.count
        noteDrawChange()
    }

    public func select(start: Int, length: Int) {
        let count = inputText.count
        let clampedStart = min(max(0, start), count)
        let end: Int
        if length < 0 {
            end = count
        } else {
            end = min(count, clampedStart + length)
        }
        selectionRange = clampedStart..<max(clampedStart, end)
        noteDrawChange()
    }

    public override func handleMouse(_ kind: MouseEventKind, x: Double, y: Double) -> Bool {
        if kind == .leftUp {
            focus()
            // Allow any LeftMouseUpAction defined on the meter to run as well if present.
            return effectiveMouseAction(.leftUp) == nil
        }
        return false
    }

    // MARK: - Layout & Lowering

    public override func naturalSize() -> (width: Double, height: Double) {
        guard !text.isEmpty else { return emptyFieldSize() }
        guard let host = skin.host else {
            let px = TextStyle.pixelSize(points: style.fontSize)
            return (Double(text.count) * px * 0.6, px * 1.2)
        }
        switch style.clip {
        case 2:
            let maxWidth = widthOption ?? clipStringW
            var size = host.textSize(text, style: style, wrapWidth: maxWidth, for: skin)
            if let maxWidth { size.width = min(size.width, maxWidth) }
            if heightOption == nil, let maxHeight = clipStringH { size.height = min(size.height, maxHeight) }
            return size
        default:
            return host.textSize(text, style: style, wrapWidth: nil, for: skin)
        }
    }

    private func emptyFieldSize() -> (width: Double, height: Double) {
        guard style.fontSize > 0 else { return (0, 0) }
        guard let host = skin.host else { return (0, TextStyle.pixelSize(points: style.fontSize) * 1.2) }
        var probe = baseStyle
        probe.inlineSpans = []
        return (0, host.textSize("X", style: probe, wrapWidth: nil, for: skin).height)
    }

    public override func anchorOffset(width: Double, height: Double) -> (dx: Double, dy: Double) {
        let dx: Double
        switch style.horizontalAlign {
        case .left, .justify: dx = 0
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

    public var anchorPoint: (x: Double, y: Double) { (anchorX, anchorY) }

    public func lower() -> TextDraw {
        skin.assertOwned()
        let anchor = anchorPoint
        return TextDraw(text: text, style: style, frame: frame, contentFrame: contentFrame,
                        anchor: SkinPoint(x: anchor.x, y: anchor.y))
    }
}
