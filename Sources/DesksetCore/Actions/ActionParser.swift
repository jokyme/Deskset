import Foundation

// Action option parsing (`LeftMouseUpAction=[!SetOption M Text "Hi"][!Redraw]`).
//
// Clean-room implementation based only on the public manual:
//   https://docs.rainmeter.net/manual/bangs/
//   https://docs.rainmeter.net/manual/skins/option-types/#Action
//   https://docs.rainmeter.net/history/ (legacy !Execute / PLAY / magic quote notes)
//
// Rules implemented (manual wording paraphrased):
// - One bang may be written bare (`!HideMeter SomeMeter`) or bracketed (`[!HideMeter SomeMeter]`); several bangs are
//   written as consecutive bracketed items (`[!A][!B]`). Whitespace between items is ignored.
// - Arguments are separated by whitespace; arguments containing spaces are "double quoted"; arguments containing
//   double quotes use """magic quotes""", whose content is taken strictly literally (including `[` and `]`).
// - A bracketed item that is not a bang runs an external command / opens a URL or file: `["https://…"]`,
//   `["C:\Windows\Notepad.exe" MyFile.txt]`.
// - `!Execute` (deprecated) is an optional wrapper around a list of actions; `!RainmeterXxx` is an alias of `!Xxx`.
// - `Play` / `PlayLoop` / `PlayStop` are commands written without `!` (history: `PLAY file.wav` also works in upper
//   case), so they are returned as bangs named `play` / `playloop` / `playstop`.
// - `!Execute [""]` does nothing (history), so an execute item whose target is empty yields no action.
//
// Judgment calls where the manual is silent (documented here, mirrored in tests):
// - Bang names are matched case-insensitively (the manual's own examples mix `!execute` / `!Execute`).
// - A double quote only starts a quoted argument at the beginning of an argument; a `"` in the middle of a word is a
//   literal character. A quoted argument ends at the next `"`. Quote characters without a partner are literal.
// - Magic quotes: a run of three or more quotes closes the argument; the *last* three quotes of the run are the
//   delimiter, so `"""say "hi""""` → `say "hi"`.
// - Inside double quotes and magic quotes `[` / `]` do not count as brackets (`[!Log "a]b"]` is one bang).
// - Outside quotes, `[` … `]` groups nested inside an argument (section variables such as `[Measure]`,
//   `[&Script:Func('a b')]`, `[#Var]`) are kept intact, including any spaces inside them, and do not end the bang.
// - Text between bracketed items that is not itself bracketed is ignored (it cannot be an action in that position).
// - An item missing its closing `]` extends to the end of the text (lenient).
// - `[]`, `[ ]`, `[""]`, `[!]` and empty text produce no action.
// - A bracketed item whose content is itself a list of bracketed items (`[[!A][!B]]`, `[["https://…"]]`) is parsed
//   as that list. A nested `[` that does not start with `!`, `"` or `[` is a section variable used as the command
//   (`[[MeasureLink]]` ≡ the manual's `["[MeasureLink]"]`) and is kept with its brackets.

/// One bang, e.g. `[!SetOption MeterClock Text "Hello World"]`.
public struct Bang: Equatable {
    /// Canonical name: lowercased, without the leading `!` and without the legacy `Rainmeter` prefix
    /// (`!RainmeterRefresh` → `refresh`, `!SetOption` → `setoption`).
    public var name: String
    /// Arguments with quoting removed (`"a b"` → `a b`, `"""say "hi""""` → `say "hi"`).
    public var args: [String]

    public init(name: String, args: [String] = []) {
        self.name = name
        self.args = args
    }
}

public enum SkinAction: Equatable {
    case bang(Bang)
    /// A bracketed item that is not a bang: open a URL / file / run a program, e.g. `["https://example.com"]`.
    /// `target` is the program / URL / path (quotes removed); `arguments` the remaining parameters.
    case execute(target: String, arguments: [String])
}

/// How one argument was written.
public enum ArgumentQuoting: Equatable {
    /// Bare word (`SomeMeter`, `[Measure]`).
    case none
    /// `"double quoted"`.
    case quoted
    /// `"""magic quoted"""`: the manual says everything inside is "treated strictly literal", so the engine should not
    /// resolve `[SectionVariables]` or `(formulas)` in it.
    case magic
}

/// An action together with how each of its arguments was quoted (see `ActionParser.parseDetailed`).
public struct ParsedAction: Equatable {
    public var action: SkinAction
    /// One entry per argument: for `.bang` aligned with `args`; for `.execute` the target first, then `arguments`.
    public var quoting: [ArgumentQuoting]

    public init(action: SkinAction, quoting: [ArgumentQuoting]) {
        self.action = action
        self.quoting = quoting
    }
}

public enum ActionParser {
    /// Parses an action option value (`LeftMouseUpAction`, `IfTrueAction`, `OnUpdateAction`, …).
    /// Supports `[!A …][!B …]` sequences, a single bare `!Bang …` without brackets, nested brackets inside
    /// arguments, double quotes and triple quotes, and non-bang `[…]` items. Malformed input never crashes.
    public static func parse(_ text: String) -> [SkinAction] {
        parseDetailed(text).map(\.action)
    }

    /// Same as `parse`, plus how every argument was quoted, so the engine can leave `"""magic quoted"""` arguments
    /// unresolved as the manual requires (`[!SetVariable X """(1+1) [NotAMeasure]"""]` sets the literal text).
    public static func parseDetailed(_ text: String) -> [ParsedAction] {
        var actions: [ParsedAction] = []
        ActionScanner(Array(text.unicodeScalars)).parseList(depth: 0, into: &actions)
        return actions
    }

    /// Splits the arguments of one bang the same way `parse` does (quotes removed, nested `[…]` kept), e.g. for a
    /// bang assembled from pieces at run time. `ActionParser.arguments(#"M Text "a b""#)` → `["M", "Text", "a b"]`.
    public static func arguments(_ text: String) -> [String] {
        let scanner = ActionScanner(Array(text.unicodeScalars))
        var i = 0
        var args: [String] = []
        while let token = scanner.readToken(&i, bracketed: false) { args.append(token.text) }
        return args
    }

    /// Maximum nesting of legacy `!Execute [...]` wrappers / `[[...]]` lists that is unwrapped.
    static let maxNesting = 8
}

// MARK: - Scanner

private struct ActionToken {
    var text: String
    var quoting: ArgumentQuoting
    var quoted: Bool { quoting != .none }
}

private struct ActionScanner {
    private let s: [Unicode.Scalar]
    private let n: Int
    /// For every `[`, the index of its matching `]` (plain bracket counting, quotes ignored), or -1.
    /// Stack matching only depends on the text *after* the `[`, so this is valid from any starting point.
    private let closingBracket: [Int]

    init(_ scalars: [Unicode.Scalar]) {
        s = scalars
        n = scalars.count
        var match = [Int](repeating: -1, count: scalars.count)
        var stack: [Int] = []
        for (index, c) in scalars.enumerated() {
            if c == "[" {
                stack.append(index)
            } else if c == "]", let open = stack.popLast() {
                match[open] = index
            }
        }
        closingBracket = match
    }

    // MARK: Lists and items

    /// Parses the whole text as an action list: either bracketed items or one bare item.
    func parseList(depth: Int, into out: inout [ParsedAction]) {
        var i = 0
        skipWhitespace(&i)
        guard i < n else { return }
        guard s[i] == "[" else {
            parseItem(&i, bracketed: false, depth: depth, into: &out)
            return
        }
        while i < n {
            skipWhitespace(&i)
            guard i < n else { break }
            if s[i] == "[" {
                i += 1
                parseItem(&i, bracketed: true, depth: depth, into: &out)
            } else {
                // Stray text between bracketed items is not an action; skip to the next item.
                while i < n && s[i] != "[" { i += 1 }
            }
        }
    }

    /// Parses one item. When `bracketed`, `i` is just after the opening `[` and the item ends at its closing `]`
    /// (which is consumed); otherwise the item extends to the end of the text.
    private func parseItem(_ i: inout Int, bracketed: Bool, depth: Int, into out: inout [ParsedAction]) {
        skipWhitespace(&i)
        guard i < n else { return }

        if s[i] == "!" {
            var j = i + 1
            while j < n && Self.isNameCharacter(s[j]) { j += 1 }
            let rawName = text(i + 1 ..< j)
            i = j
            let contentStart = i
            var args: [String] = []
            var quoting: [ArgumentQuoting] = []
            var contentEnd = i
            while let token = readToken(&i, bracketed: bracketed) {
                args.append(token.text)
                quoting.append(token.quoting)
                contentEnd = i
            }
            closeItem(&i, bracketed: bracketed)
            guard !rawName.isEmpty else { return }
            let name = BangCatalog.canonicalName(rawName)
            if name == "execute" {
                // Deprecated `!Execute [!A][!B]` / `!Execute ["program"]`: the rest is itself an action list.
                if depth < ActionParser.maxNesting && contentEnd > contentStart {
                    ActionScanner(Array(s[contentStart ..< contentEnd])).parseList(depth: depth + 1, into: &out)
                }
                return
            }
            out.append(ParsedAction(action: .bang(Bang(name: name, args: args)), quoting: quoting))
            return
        }

        if bracketed && s[i] == "[" && depth < ActionParser.maxNesting && startsNestedList(at: i) {
            // `[[!A][!B]]`: a bracketed list inside an item.
            let contentStart = i
            var contentEnd = i
            while readToken(&i, bracketed: true) != nil { contentEnd = i }
            closeItem(&i, bracketed: true)
            ActionScanner(Array(s[contentStart ..< contentEnd])).parseList(depth: depth + 1, into: &out)
            return
        }

        var tokens: [ActionToken] = []
        while let token = readToken(&i, bracketed: bracketed) { tokens.append(token) }
        closeItem(&i, bracketed: bracketed)
        guard let first = tokens.first else { return }
        let rest = tokens.dropFirst().map(\.text)
        if !first.quoted, let command = Self.playCommand(first.text) {
            out.append(ParsedAction(action: .bang(Bang(name: command, args: rest)),
                                    quoting: tokens.dropFirst().map(\.quoting)))
            return
        }
        // `[""]` → no action (history: `!Execute [""]` "results in no action now").
        guard !first.text.isEmpty else { return }
        out.append(ParsedAction(action: .execute(target: first.text, arguments: rest), quoting: tokens.map(\.quoting)))
    }

    /// Whether the `[` at `start` (first thing inside an item) opens a nested action list (`[[!A][!B]]`,
    /// `[["https://…"]]`) rather than a section variable used as the command (`[[MeasureLink]]`, `[[#URL]]`,
    /// `[[&Script:Url()]]`). The manual's WebParser example `["[MeasureRSSItemLink]"]` needs its quotes only for
    /// spaces, so `[[MeasureRSSItemLink]]` must keep the brackets for the engine to resolve the measure.
    private func startsNestedList(at start: Int) -> Bool {
        // An unterminated `[` cannot be a section variable (malformed input keeps the list reading).
        guard closingBracket[start] > start else { return true }
        var j = start + 1
        skipWhitespace(&j)
        guard j < n else { return true }
        return s[j] == "!" || s[j] == "\"" || s[j] == "["
    }

    private func closeItem(_ i: inout Int, bracketed: Bool) {
        if bracketed && i < n && s[i] == "]" { i += 1 }
    }

    // MARK: Tokens

    /// Reads the next argument, or returns nil at the end of the item (`]` when bracketed, or end of text).
    func readToken(_ i: inout Int, bracketed: Bool) -> ActionToken? {
        skipWhitespace(&i)
        guard i < n else { return nil }
        if bracketed && s[i] == "]" { return nil }
        if s[i] == "\"" {
            if let token = readMagicQuoted(&i) { return token }
            if let close = indexOfQuote(from: i + 1) {
                let token = ActionToken(text: text(i + 1 ..< close), quoting: .quoted)
                i = close + 1
                return token
            }
            // A quote without a partner is an ordinary character.
        }
        return readUnquoted(&i, bracketed: bracketed)
    }

    /// `"""…"""`: everything up to the next run of three or more quotes is literal; the last three quotes of that
    /// run close the argument.
    private func readMagicQuoted(_ i: inout Int) -> ActionToken? {
        guard i + 2 < n, s[i + 1] == "\"", s[i + 2] == "\"" else { return nil }
        var j = i + 3
        while j + 2 < n {
            if s[j] == "\"" && s[j + 1] == "\"" && s[j + 2] == "\"" {
                var k = j + 3
                while k < n && s[k] == "\"" { k += 1 }
                let token = ActionToken(text: text(i + 3 ..< k - 3), quoting: .magic)
                i = k
                return token
            }
            j += 1
        }
        return nil
    }

    private func readUnquoted(_ i: inout Int, bracketed: Bool) -> ActionToken {
        let start = i
        while i < n {
            let c = s[i]
            if Self.isWhitespace(c) { break }
            if bracketed && c == "]" { break }
            if c == "[", closingBracket[i] > i {
                // Nested `[…]` (section variable etc.) is part of the argument, spaces included.
                i = closingBracket[i] + 1
                continue
            }
            i += 1
        }
        return ActionToken(text: text(start ..< i), quoting: .none)
    }

    private func indexOfQuote(from start: Int) -> Int? {
        var j = start
        while j < n {
            if s[j] == "\"" { return j }
            j += 1
        }
        return nil
    }

    // MARK: Helpers

    private func skipWhitespace(_ i: inout Int) {
        while i < n && Self.isWhitespace(s[i]) { i += 1 }
    }

    private func text(_ range: Range<Int>) -> String {
        guard range.lowerBound < range.upperBound else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[range])
        return String(view)
    }

    private static func isWhitespace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\r" || c == "\n"
    }

    private static func isNameCharacter(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_"
    }

    /// `Play`, `PlayLoop`, `PlayStop` are commands without `!` (manual: Application bangs).
    private static func playCommand(_ word: String) -> String? {
        switch word.lowercased() {
        case "play": return "play"
        case "playloop": return "playloop"
        case "playstop": return "playstop"
        default: return nil
        }
    }
}
