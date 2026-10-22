import Foundation

/// `Meter=TextEdit`: interactive or bang-driven single-line / multiline text input meter (Rainmeter 5.0).
///
/// Clean-room implementation from the public manual only (`https://docs-v5.rainmeter.net/manual/meters/textedit/`):
/// - Supports standard String formatting options (`FontFace`, `FontSize`, `FontColor`, `FontWeight`, `StringAlign`,
///   `StringStyle`, `StringEffect`, `FontEffectColor`, `ClipString`, `ClipStringW`, `ClipStringH`, `StringCase`,
///   and `InlineSetting` / `InlinePattern`). Does not use `Text`; uses `InitialText` and `PlaceholderText`.
/// - `InitialText` follows dynamic variables until focus, and again after `!TextEdit:Reset` until the next focus
///   (not modified by `!SetOption`).
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
    /// Caret and anchor are extended grapheme-cluster offsets in the unmasked input.
    public private(set) var caretPosition = 0
    public private(set) var selectionAnchor = 0
    public var selectionRange: Range<Int> {
        min(caretPosition, selectionAnchor)..<max(caretPosition, selectionAnchor)
    }
    public private(set) var scrollLineOffset = 0
    public private(set) var scrollOffset = SkinPoint()
    public private(set) var isSelecting = false
    public private(set) var caretVisible = true
    public var canUndo: Bool { !readOnly && !undoHistory.isEmpty }

    private struct EditingState {
        var text: String
        var caret: Int
        var anchor: Int
        var caretLine: Int?
        var scroll: SkinPoint
    }
    private var undoHistory: [EditingState] = []
    private var preferredNavigationX: Double?
    private var caretLineAffinity: Int?
    private var displayedBoundaries: [Int] = [0]
    private var lastEditingLayout: TextEditLayout?

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
    private var lastInitialText: String?
    private var initialTextLocked = false
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

        let configuredCase = option("StringCase")
        stringCase = Self.parseCase(configuredCase ?? "None")
        inputCase = configuredCase == nil ? Self.parseCase(string("InputCase", "None")) : stringCase

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

        let previousText = inputText
        if lastInitialText == nil || (dynamicVariables && !initialTextLocked) {
            let initialText = readInitialText()
            // An unchanged default must not overwrite an explicit SetText or Clear on each update.
            if initialText != lastInitialText {
                inputText = initialText
                lastInitialText = initialText
            }
        }
        inputText = normalizedInput(inputText, checkFilter: false)
        if inputText != previousText {
            clearHistory()
            preferredNavigationX = nil
            caretLineAffinity = nil
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
        rebuildDisplayedBoundaries()
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
        caretPosition = min(max(0, caretPosition), count)
        selectionAnchor = min(max(0, selectionAnchor), count)
    }

    // MARK: - Bangs & Interaction

    public func focus() {
        guard !isFocused else { return }
        initialTextLocked = true
        for case let other as TextEditMeter in skin.meters where other !== self && other.isFocused {
            other.dismiss()
        }
        isFocused = true
        composeDisplayedText()
        revealCaret()
        noteDrawChange()
        if !onFocusAction.isEmpty {
            skin.executeWithTextEditInput(from: self, action: onFocusAction)
        }
    }

    public func dismiss() {
        guard isFocused else { return }
        isFocused = false
        caretPosition = 0
        selectionAnchor = 0
        isSelecting = false
        preferredNavigationX = nil
        caretLineAffinity = nil
        composeDisplayedText()
        noteDrawChange()
        if !onDismissAction.isEmpty {
            skin.executeWithTextEditInput(from: self, action: onDismissAction)
        }
    }

    public func submit() {
        isFocused = false
        caretPosition = 0
        selectionAnchor = 0
        isSelecting = false
        preferredNavigationX = nil
        caretLineAffinity = nil
        composeDisplayedText()
        noteDrawChange()
        if !onSubmitAction.isEmpty {
            skin.executeWithTextEditInput(from: self, action: onSubmitAction)
        }
    }

    public func clear() {
        inputText = ""
        caretPosition = 0
        selectionAnchor = 0
        resetScrollState()
        clearHistory()
        composeDisplayedText()
        noteDrawChange()
    }

    public func reset() {
        let initialText = readInitialText()
        lastInitialText = initialText
        initialTextLocked = false
        inputText = normalizedInput(initialText, checkFilter: false)
        caretPosition = 0
        selectionAnchor = 0
        resetScrollState()
        clearHistory()
        composeDisplayedText()
        noteDrawChange()
    }

    public func setText(_ newText: String) {
        let candidate = normalizedInput(newText, checkFilter: true)
        if candidate != inputText {
            clearHistory()
            preferredNavigationX = nil
            caretLineAffinity = nil
        }
        inputText = candidate
        clampSelection()
        composeDisplayedText()
        revealCaret()
        noteDrawChange()
    }

    /// ScrollByLine is a multiline-only operation; a positive count moves toward the end.
    public func scrollByLine(_ delta: Int) {
        guard multiline else { return }
        let layout = editingLayout()
        lastEditingLayout = layout
        let index = layout.lineIndex(at: displayedOffset(for: caretPosition))
        let lineHeight = layout.lines.indices.contains(index) ? layout.lines[index].bounds.height : 0
        guard lineHeight > 0, lineHeight.isFinite else { return }
        scrollOffset.y += Double(delta) * lineHeight
        clampScroll(to: layout)
        noteDrawChange()
    }

    public func resetScroll() {
        scrollOffset = SkinPoint()
        scrollLineOffset = 0
        lastEditingLayout = editingLayout()
        noteDrawChange()
    }

    public func selectAll() {
        selectionAnchor = 0
        caretPosition = inputText.count
        preferredNavigationX = nil
        caretLineAffinity = nil
        revealCaret()
        noteDrawChange()
    }

    public func select(start: Int, length: Int) {
        let count = inputText.count
        selectionAnchor = min(max(0, start), count)
        if length < 0 {
            caretPosition = count
        } else {
            // Avoid an overflow for an untrusted bang argument such as Int.max.
            caretPosition = selectionAnchor + min(length, count - selectionAnchor)
        }
        preferredNavigationX = nil
        caretLineAffinity = nil
        revealCaret()
        noteDrawChange()
    }

    public enum Navigation: Equatable, Sendable {
        case left, right, wordLeft, wordRight
        case lineStart, lineEnd, documentStart, documentEnd
        case up, down, pageUp, pageDown
    }

    public enum KeyInput: Equatable, Sendable {
        case insert(String)
        case backspace
        case deleteForward
        case deleteWordBackward
        case deleteWordForward
        case enter
        case escape
        case selectAll
        case move(Navigation, selecting: Bool)
        case undo
    }

    @discardableResult
    public func handleKeyInput(_ key: KeyInput) -> Bool {
        guard isFocused else { return false }
        switch key {
        case .escape:
            dismiss()
        case .enter:
            if submitOnEnter {
                submit()
            } else if multiline && !readOnly {
                replaceSelection(with: "\n")
            }
        case .selectAll:
            selectAll()
        case .move(let direction, let selecting):
            moveCaret(direction, selecting: selecting)
        case .undo:
            undo()
        case .backspace, .deleteForward, .deleteWordBackward, .deleteWordForward:
            guard !readOnly else { return true }
            let before = editingState
            if selectionRange.isEmpty {
                let end: Int
                switch key {
                case .backspace: end = max(0, caretPosition - 1)
                case .deleteForward: end = min(inputText.count, caretPosition + 1)
                case .deleteWordBackward: end = wordBoundary(from: caretPosition, forward: false)
                default: end = wordBoundary(from: caretPosition, forward: true)
                }
                selectionAnchor = end
            }
            replaceSelection(with: "", previousState: before)
        case .insert(let chars):
            guard !readOnly, !chars.isEmpty else { return true }
            replaceSelection(with: chars)
        }
        return true
    }

    /// Password fields never export their input; selection and navigation remain available.
    public var clipboardText: String? {
        guard !password, !selectionRange.isEmpty else { return nil }
        let chars = Array(inputText)
        return String(chars[selectionRange])
    }

    /// Returns the text only when the corresponding edit is permitted and performed.
    @discardableResult
    public func cutSelection() -> String? {
        guard isFocused, !readOnly, let copied = clipboardText else { return nil }
        replaceSelection(with: "")
        return copied
    }

    @discardableResult
    public func paste(_ value: String) -> Bool {
        guard isFocused else { return false }
        guard !readOnly, !value.isEmpty else { return true }
        replaceSelection(with: value)
        return true
    }

    public func undo() {
        guard isFocused, !readOnly, let previous = undoHistory.popLast() else { return }
        restore(previous)
    }

    private var editingState: EditingState {
        EditingState(text: inputText, caret: caretPosition, anchor: selectionAnchor,
                     caretLine: caretLineAffinity, scroll: scrollOffset)
    }

    private func clearHistory() {
        undoHistory.removeAll(keepingCapacity: true)
    }

    private func restore(_ state: EditingState) {
        inputText = state.text
        caretPosition = state.caret
        selectionAnchor = state.anchor
        scrollOffset = state.scroll
        preferredNavigationX = nil
        caretLineAffinity = state.caretLine
        clampSelection()
        composeDisplayedText()
        revealCaret()
        noteDrawChange()
    }

    private func replaceSelection(with replacement: String, previousState: EditingState? = nil) {
        guard !readOnly else { return }
        clampSelection()
        let chars = Array(inputText)
        let range = selectionRange
        let prefix = String(chars[..<range.lowerBound])
        let suffix = String(chars[range.upperBound...])
        var inserted = replacement
        if !multiline {
            inserted = inserted.replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        }
        // Limit the insertion rather than dropping the existing suffix when pasting in the middle.
        let retainedCount = chars.count - range.count
        if maxLength > 0 {
            inserted = String(inserted.prefix(max(0, maxLength - retainedCount)))
        }
        inserted = StringMeter.truncated(inserted, maximumUTF16: StringMeter.maximumTextLength)
        func normalizedCandidate(_ addition: String) -> String {
            let raw = prefix + addition + suffix
            return inputCase.map { StringMeter.applyCase($0, to: raw, preserveLength: false) } ?? raw
        }
        func fits(_ candidate: String) -> Bool {
            (maxLength == 0 || candidate.count <= maxLength)
                && candidate.utf16.count <= StringMeter.maximumTextLength
        }
        var candidate = normalizedCandidate(inserted)
        if !fits(candidate) {
            // Case conversion can expand input. Find a bounded insertion while preserving both sides.
            let additions = Array(inserted)
            var low = 0, high = additions.count
            while low < high {
                let mid = low + (high - low + 1) / 2
                if fits(normalizedCandidate(String(additions.prefix(mid)))) { low = mid }
                else { high = mid - 1 }
            }
            inserted = String(additions.prefix(low))
            candidate = normalizedCandidate(inserted)
            guard fits(candidate) else { return }
        }
        guard replacement.isEmpty || matchesInputFilter(candidate) else { return }
        let changedText = candidate != inputText
        let before = previousState ?? editingState
        inputText = candidate
        var beforeCaret = prefix + inserted
        if let inputCase {
            beforeCaret = StringMeter.applyCase(inputCase, to: beforeCaret, preserveLength: false)
        }
        caretPosition = min(beforeCaret.count, inputText.count)
        selectionAnchor = caretPosition
        preferredNavigationX = nil
        caretLineAffinity = nil
        if changedText {
            undoHistory.append(before)
            // Bound retained snapshots even for skins which accept long, continuously edited input.
            if undoHistory.count > 100 { undoHistory.removeFirst(undoHistory.count - 100) }
        }
        composeDisplayedText()
        revealCaret()
        noteDrawChange()
    }

    private func moveCaret(_ direction: Navigation, selecting: Bool) {
        clampSelection()
        let previous = caretPosition
        let destination: Int
        let vertical: Bool
        var destinationLine: Int?
        switch direction {
        case .left:
            destination = !selecting && !selectionRange.isEmpty ? selectionRange.lowerBound : max(0, previous - 1)
            vertical = false
        case .right:
            destination = !selecting && !selectionRange.isEmpty ? selectionRange.upperBound : min(inputText.count, previous + 1)
            vertical = false
        case .wordLeft:
            destination = wordBoundary(from: previous, forward: false)
            vertical = false
        case .wordRight:
            destination = wordBoundary(from: previous, forward: true)
            vertical = false
        case .documentStart:
            destination = 0
            vertical = false
        case .documentEnd:
            destination = inputText.count
            vertical = false
        case .lineStart, .lineEnd:
            let layout = editingLayout()
            let line = layout.lineIndex(at: displayedOffset(for: previous), preferredLine: caretLineAffinity)
            destinationLine = line
            if layout.lines.indices.contains(line) {
                let geometry = layout.lines[line]
                let endpoint = direction == .lineStart ? geometry.range.lowerBound
                    : (geometry.caretStops.last?.offset ?? geometry.range.upperBound)
                destination = inputOffset(for: endpoint)
            } else { destination = previous }
            vertical = false
        case .up, .down, .pageUp, .pageDown:
            let layout = editingLayout()
            let offset = displayedOffset(for: previous)
            let line = layout.lineIndex(at: offset, preferredLine: caretLineAffinity)
            let caret = layout.caretRect(at: offset, preferredLine: caretLineAffinity)
            let x = preferredNavigationX ?? caret.x
            preferredNavigationX = x
            let height = max(1, caret.height)
            let page = max(1, Int((max(0, contentFrame.height) / height).rounded(.down)))
            let delta = direction == .up ? -1 : direction == .down ? 1 : direction == .pageUp ? -page : page
            let targetLine = min(max(0, line + delta), max(0, layout.lines.count - 1))
            destinationLine = targetLine
            destination = inputOffset(for: layout.offset(onLine: targetLine, preferredX: x))
            vertical = true
        }
        caretPosition = min(max(0, destination), inputText.count)
        if !selecting { selectionAnchor = caretPosition }
        if !vertical { preferredNavigationX = nil }
        caretLineAffinity = destinationLine
        revealCaret()
        noteDrawChange()
    }

    private func wordBoundary(from position: Int, forward: Bool) -> Int {
        let chars = Array(inputText)
        func category(_ ch: Character) -> Int {
            if ch.isWhitespace { return 0 }
            if ch.isLetter || ch.isNumber || ch == "_" { return 1 }
            return 2
        }
        var at = min(max(0, position), chars.count)
        if forward {
            if at < chars.count {
                let kind = category(chars[at])
                while at < chars.count && category(chars[at]) == kind { at += 1 }
            }
            while at < chars.count && category(chars[at]) == 0 { at += 1 }
        } else {
            while at > 0 && category(chars[at - 1]) == 0 { at -= 1 }
            if at > 0 {
                let kind = category(chars[at - 1])
                while at > 0 && category(chars[at - 1]) == kind { at -= 1 }
            }
        }
        return at
    }

    /// Pointer coordinates are skin coordinates. A captured drag may continue outside the meter.
    public func beginSelection(at point: SkinPoint, extending: Bool = false) {
        focus()
        guard isFocused else { return }
        let position = pointerPosition(at: point)
        caretPosition = position.offset
        if !extending { selectionAnchor = position.offset }
        isSelecting = true
        preferredNavigationX = nil
        caretLineAffinity = position.line
        revealCaret()
        noteDrawChange()
    }

    public func extendSelection(to point: SkinPoint) {
        guard isFocused, isSelecting else { return }
        let position = pointerPosition(at: point)
        caretPosition = position.offset
        preferredNavigationX = nil
        caretLineAffinity = position.line
        revealCaret()
        noteDrawChange()
    }

    public func endSelection() { isSelecting = false }

    private func pointerPosition(at point: SkinPoint) -> (offset: Int, line: Int) {
        let layout = editingLayout()
        let local = SkinPoint(x: point.x - contentFrame.x + scrollOffset.x,
                              y: point.y - contentFrame.y + scrollOffset.y)
        let line = layout.lines.firstIndex { local.y < $0.bounds.maxY } ?? max(0, layout.lines.count - 1)
        return (inputOffset(for: layout.hitTest(local)), line)
    }

    public override func handleMouse(_ kind: MouseEventKind, x: Double, y: Double) -> Bool {
        handleMouse(kind, x: x, y: y, extendingSelection: false)
    }

    public func handleMouse(_ kind: MouseEventKind, x: Double, y: Double, extendingSelection: Bool) -> Bool {
        switch kind {
        case .leftDown:
            guard hitTest(x: x, y: y) else { return false }
            beginSelection(at: SkinPoint(x: x, y: y), extending: extendingSelection)
            return effectiveMouseAction(kind) == nil
        case .leftUp:
            guard isSelecting || hitTest(x: x, y: y) else { return false }
            if isSelecting { extendSelection(to: SkinPoint(x: x, y: y)) }
            endSelection()
            return effectiveMouseAction(.leftUp) == nil
        case .scrollUp, .scrollDown:
            guard hitTest(x: x, y: y), effectiveMouseAction(kind) == nil else { return false }
            scrollByLine(kind == .scrollUp ? -1 : 1)
            return true
        default:
            return false
        }
    }

    // MARK: - Display Geometry

    /// Selection/caret offsets passed to the renderer are UTF-16 offsets in displayed text.
    public var displayedCaretOffset: Int { displayedOffset(for: caretPosition) }
    public var displayedSelectionRange: Range<Int> {
        displayedOffset(for: selectionRange.lowerBound)..<displayedOffset(for: selectionRange.upperBound)
    }

    private var editingText: String { inputText.isEmpty ? "" : text }
    private var editingStyle: TextStyle { inputText.isEmpty ? baseStyle : style }

    private func editingLayout() -> TextEditLayout {
        let viewport = SkinRect(width: max(0, contentFrame.width), height: max(0, contentFrame.height))
        return skin.host?.textEditLayout(editingText, style: editingStyle, viewport: viewport,
                                        multiline: multiline, for: skin)
            ?? TextEditLayout.fallback(text: editingText, style: editingStyle, viewport: viewport, multiline: multiline)
    }

    private func displayedOffset(for inputOffset: Int) -> Int {
        let index = min(max(0, inputOffset), max(0, displayedBoundaries.count - 1))
        return min(displayedBoundaries[index], editingText.utf16.count)
    }

    private func inputOffset(for displayOffset: Int) -> Int {
        let target = max(0, displayOffset)
        var low = 0, high = displayedBoundaries.count
        while low < high {
            let mid = low + (high - low) / 2
            if displayedBoundaries[mid] < target { low = mid + 1 } else { high = mid }
        }
        guard low > 0, low < displayedBoundaries.count else {
            return min(low, max(0, displayedBoundaries.count - 1))
        }
        let previous = displayedBoundaries[low - 1]
        return target - previous < displayedBoundaries[low] - target ? low - 1 : low
    }

    private func rebuildDisplayedBoundaries() {
        displayedBoundaries = [0]
        displayedBoundaries.reserveCapacity(inputText.count + 1)
        var offset = 0
        var wordStart = true, sentenceStart = true, afterTerminator = false
        for ch in inputText {
            var shown = String(ch)
            if password { shown = "\u{25CF}" }
            else if let stringCase {
                switch stringCase {
                case .upper: shown = shown.uppercased()
                case .lower: shown = shown.lowercased()
                case .proper:
                    if ch.isWhitespace { wordStart = true }
                    else if ch.isLetter { shown = wordStart ? shown.uppercased() : shown.lowercased(); wordStart = false }
                    else if ch.isNumber { wordStart = false }
                case .sentence:
                    if ch.isLetter {
                        shown = sentenceStart ? shown.uppercased() : shown.lowercased()
                        sentenceStart = false
                        afterTerminator = false
                    } else if ch == "." || ch == "!" || ch == "?" { afterTerminator = true }
                    else if ch.isWhitespace { if afterTerminator { sentenceStart = true } }
                    else { if ch.isNumber { sentenceStart = false }; afterTerminator = false }
                }
            }
            offset += shown.utf16.count
            displayedBoundaries.append(offset)
        }
    }

    private func resetScrollState() {
        scrollOffset = SkinPoint()
        scrollLineOffset = 0
        preferredNavigationX = nil
        caretLineAffinity = nil
    }

    private func clampScroll(to layout: TextEditLayout) {
        let width = max(0, contentFrame.width), height = max(0, contentFrame.height)
        let maxX = max(0, layout.contentSize.width - width + 1)
        let maxY = multiline ? max(0, layout.contentSize.height - height) : 0
        scrollOffset.x = scrollOffset.x.isFinite ? scrollOffset.x.clamped(0, maxX) : 0
        scrollOffset.y = scrollOffset.y.isFinite ? scrollOffset.y.clamped(0, maxY) : 0
        scrollLineOffset = layout.lines.lastIndex(where: { $0.bounds.y <= scrollOffset.y }) ?? 0
    }

    @discardableResult
    public func toggleCaretBlink() -> Bool {
        guard isFocused else { return false }
        caretVisible.toggle()
        noteDrawChange()
        return true
    }

    private func revealCaret(in capturedLayout: TextEditLayout? = nil) {
        caretVisible = true
        let layout = capturedLayout ?? editingLayout()
        lastEditingLayout = layout
        let caret = layout.caretRect(at: displayedCaretOffset, preferredLine: caretLineAffinity)
        let width = max(0, contentFrame.width), height = max(0, contentFrame.height)
        if caret.x < scrollOffset.x { scrollOffset.x = caret.x }
        else if width > 0, caret.maxX > scrollOffset.x + width { scrollOffset.x = caret.maxX - width }
        if multiline {
            if caret.y < scrollOffset.y { scrollOffset.y = caret.y }
            else if height > 0, caret.maxY > scrollOffset.y + height { scrollOffset.y = caret.maxY - height }
        }
        clampScroll(to: layout)
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
        let layout = editingLayout()
        if layout != lastEditingLayout, isFocused { revealCaret(in: layout) }
        else { clampScroll(to: layout) }
        lastEditingLayout = layout
        return TextDraw(text: text, style: style, frame: frame, contentFrame: contentFrame,
                        anchor: SkinPoint(x: anchor.x, y: anchor.y),
                        editing: TextEditingDraw(isFocused: isFocused, caretVisible: caretVisible,
                                                 caretOffset: displayedCaretOffset, caretLine: caretLineAffinity,
                                                 selectionRange: displayedSelectionRange, scroll: scrollOffset,
                                                 caretColor: caretColor, selectionColor: selectionColor,
                                                 focusBorderWidth: focusBorderWidth, focusBorderColor: focusBorderColor,
                                                 multiline: multiline, layoutText: editingText, layoutStyle: editingStyle))
    }
}
