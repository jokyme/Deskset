import Foundation
import DesksetCore

// InputText plugin logic without AppKit (unit-tested): command parsing, per-command option overrides,
// ExecuteBatch ranges, $UserInput$ substitution, input filtering and the batch sequence.
//
// Clean-room from the public manual only: https://docs.rainmeter.net/manual/plugins/inputtext/
// Judgment calls are marked and listed in docs/compat/media-ui.md.

/// Options of one input box (the measure's options, overridden by the running command's `Option="Value"` pairs).
struct InputTextSettings: Equatable {
    var x = 0.0
    var y = 0.0
    /// nil = not set (see `InputTextBox.frame`).
    var width: Double?
    var height: Double?
    var solidColor = RGBA(r: 255, g: 255, b: 255, a: 255)
    var fontColor = RGBA(r: 0, g: 0, b: 0, a: 255)
    var fontFace = "Arial"
    var fontSize = 10.0
    var bold = false
    var italic = false
    var align = HorizontalTextAlign.left
    var defaultValue = ""
    var password = false
    var inputLimit = 0
    var inputNumber = false
    /// nil = follow the skin's z-position; true = above all windows; false = normal windows may cover it.
    var topMost: Bool?
    var focusDismiss = true
    var onDismissAction = ""

    /// Option names the settings read (lowercased): only these are taken as overrides at the end of a command.
    static let optionNames: Set<String> = [
        "x", "y", "w", "h", "solidcolor", "fontcolor", "fontface", "fontsize", "stringstyle", "stringalign",
        "defaultvalue", "password", "inputlimit", "inputnumber", "topmost", "focusdismiss", "ondismissaction",
        "antialias",
    ]

    /// Reads the settings through `lookup` (resolved option text by name, nil when missing).
    static func read(_ lookup: (String) -> String?) -> InputTextSettings {
        var s = InputTextSettings()
        func value(_ key: String) -> String? {
            guard let v = lookup(key), !v.muiTrimmed.isEmpty else { return nil }
            return v
        }
        func number(_ key: String) -> Double? { value(key).flatMap(OptionValue.number).flatMap { $0.isFinite ? $0 : nil } }
        func flag(_ key: String) -> Bool? { value(key).flatMap(OptionValue.bool) }
        s.x = number("X") ?? 0
        s.y = number("Y") ?? 0
        s.width = number("W").map { max($0, 0) }
        s.height = number("H").map { max($0, 0) }
        if let c = value("SolidColor").flatMap(OptionValue.color) { s.solidColor = c }
        if let c = value("FontColor").flatMap(OptionValue.color) { s.fontColor = c }
        if let f = value("FontFace") { s.fontFace = f.muiTrimmed }
        if let size = number("FontSize") { s.fontSize = min(max(size, 1), 400) }
        switch value("StringStyle")?.muiTrimmed.lowercased() {
        case "bold": s.bold = true
        case "italic": s.italic = true
        case "bolditalic": s.bold = true; s.italic = true
        default: break
        }
        switch value("StringAlign")?.muiTrimmed.lowercased() {
        case let a? where a.hasPrefix("right"): s.align = .right
        case let a? where a.hasPrefix("center"): s.align = .center
        default: s.align = .left
        }
        s.defaultValue = lookup("DefaultValue") ?? ""
        s.password = flag("Password") ?? false
        s.inputLimit = Int(min(max(number("InputLimit") ?? 0, 0), 1_000_000))
        s.inputNumber = flag("InputNumber") ?? false
        s.topMost = flag("TopMost")
        s.focusDismiss = flag("FocusDismiss") ?? true
        s.onDismissAction = lookup("OnDismissAction") ?? ""
        return s
    }
}

/// One `CommandN` option: the action and its `Option="Value"` overrides.
struct InputTextCommand: Equatable {
    var action: String
    /// Lowercased option name → value.
    var overrides: [String: String] = [:]

    /// True when the action asks for input.
    var needsInput: Bool { action.range(of: InputTextCommand.macro, options: .caseInsensitive) != nil }

    static let macro = "$UserInput$"

    /// The action with every `$UserInput$` replaced by `input`. Judgment: one input box per command, even when the
    /// macro appears several times in it (the manual: "If the macro string $UserInput$ is repeated in a command
    /// series, multiple input boxes will be created in sequence").
    func substituted(_ input: String) -> String {
        action.replacingOccurrences(of: InputTextCommand.macro, with: input, options: .caseInsensitive)
    }

    /// Splits `[!Bang …][…] Y=40 DefaultValue="Text"` (or a bare `!Bang … Y=40`) into the action and the trailing
    /// option overrides. Only known InputText option names count as overrides, so `!SetVariable A B=C` keeps its
    /// argument. Judgment: overrides are recognised only after the action (the manual's examples all put them there).
    static func parse(_ text: String) -> InputTextCommand {
        let t = text.muiTrimmed
        guard !t.isEmpty else { return InputTextCommand(action: "") }
        var tokens = tokenize(t)
        var overrides: [String: String] = [:]
        var cut = t.endIndex
        // Bracketed actions are single tokens (the tokenizer keeps `[…]` together), so they are never overrides.
        while tokens.count > 1, let last = tokens.last, let (key, value) = option(last.text) {
            if overrides[key] == nil { overrides[key] = value }
            cut = last.range.lowerBound
            tokens.removeLast()
        }
        let action = String(t[..<cut]).muiTrimmed
        return InputTextCommand(action: action, overrides: overrides)
    }

    private struct Token {
        var text: String
        var range: Range<String.Index>
    }

    /// Whitespace-separated tokens; quotes, brackets and parentheses keep their content together (an override such as
    /// `X=(#W# - 10)` is one token).
    private static func tokenize(_ t: String) -> [Token] {
        var tokens: [Token] = []
        var i = t.startIndex
        while i < t.endIndex {
            while i < t.endIndex, t[i] == " " || t[i] == "\t" { i = t.index(after: i) }
            guard i < t.endIndex else { break }
            let start = i
            var depth = 0
            var inQuote = false
            while i < t.endIndex {
                let c = t[i]
                if c == "\"" { inQuote.toggle() } else if !inQuote {
                    if c == "[" || c == "(" { depth += 1 } else if c == "]" || c == ")" { depth = max(depth - 1, 0) }
                    else if (c == " " || c == "\t") && depth == 0 { break }
                }
                i = t.index(after: i)
            }
            tokens.append(Token(text: String(t[start..<i]), range: start..<i))
        }
        return tokens
    }

    /// `Key=Value` / `Key="Value with spaces"` with a known option name → (lowercased key, value).
    private static func option(_ token: String) -> (String, String)? {
        guard let eq = token.firstIndex(of: "=") else { return nil }
        let key = token[..<eq].lowercased()
        guard InputTextSettings.optionNames.contains(key) else { return nil }
        var value = String(token[token.index(after: eq)...])
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        return (key, value)
    }
}

/// `!CommandMeasure` arguments.
enum InputTextBang: Equatable {
    /// `ExecuteBatch All`.
    case all
    /// `ExecuteBatch N` / `ExecuteBatch N-M` (1-based, inclusive).
    case range(ClosedRange<Int>)
    /// Anything else: Judgment: run the argument itself as one command (older skins pass the bang directly).
    case command(String)

    static func parse(_ text: String) -> InputTextBang? {
        let t = text.muiTrimmed
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        guard lower.hasPrefix("executebatch") else { return .command(t) }
        let rest = t.dropFirst("executebatch".count).muiTrimmed
        if rest.lowercased() == "all" || rest.isEmpty { return .all }
        let parts = rest.split(separator: "-", maxSplits: 1).map { String($0).muiTrimmed }
        guard let a = parts.first.flatMap({ Int($0) }) else { return nil }
        let b = parts.count > 1 ? (Int(parts[1]) ?? a) : a
        let lo = max(min(a, b), 1), hi = min(max(a, b), 10_000)
        guard lo <= hi else { return nil }
        return .range(lo...hi)
    }
}

/// Filtering of typed text: InputNumber and InputLimit.
enum InputTextFilter {
    /// InputNumber: "only numeric input will be allowed. A single - can be the first character, and a single . can
    /// be at any position in the input." InputLimit: at most that many characters (0 = unlimited).
    static func sanitize(_ text: String, number: Bool, limit: Int) -> String {
        var result = text
        if number {
            var out = ""
            var seenDot = false
            for c in text {
                if c.isASCII, c.isNumber {
                    out.append(c)
                } else if c == "-" && out.isEmpty {
                    out.append(c)
                } else if c == "." && !seenDot {
                    seenDot = true
                    out.append(c)
                }
            }
            result = out
        }
        if limit > 0 && result.count > limit { result = String(result.prefix(limit)) }
        return result
    }
}

/// One ExecuteBatch run: asks for the inputs one after another, then runs the commands.
///
/// Rules (manual: "When all input has been submitted, the commands are carried out"): every command whose action
/// contains `$UserInput$` shows an input box (with that command's overrides); Enter submits it and moves on;
/// Escape or a dismissing click cancels the whole batch — no command runs — and OnDismissAction runs. Commands run
/// in order once all inputs are in, each with its own input substituted. The measure's string value becomes each
/// input as it is submitted, so `[MeasureName]` in a later command is the latest input.
final class InputTextBatch {
    struct Step: Equatable {
        var index: Int
        var command: InputTextCommand
    }

    let steps: [Step]
    private(set) var inputs: [Int: String] = [:]
    private var next = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    /// The next step that needs input, or nil when all inputs are in.
    func nextPrompt() -> Step? {
        while next < steps.count {
            let step = steps[next]
            if step.command.needsInput && inputs[step.index] == nil { return step }
            next += 1
        }
        return nil
    }

    func submit(_ input: String, for step: Step) {
        inputs[step.index] = input
        next += 1
    }

    /// The actions to execute, in order, with the inputs substituted (commands with an empty action are skipped).
    func actions() -> [String] {
        steps.compactMap { step in
            let action = step.command.needsInput ? step.command.substituted(inputs[step.index] ?? "") : step.command.action
            return action.muiTrimmed.isEmpty ? nil : action
        }
    }
}
