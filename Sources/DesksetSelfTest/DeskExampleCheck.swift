import Foundation
import DeskLanguage

/// A small check of the catalog's examples while Desk has no parser in this build: the text is split into tokens
/// (strings with their `{…}` interpolations, numbers with units, names, punctuation) and checked for balanced
/// brackets, closed strings, known units, no foreign operators, and names the catalog knows — components and
/// controls, modifiers after an element, global functions, data paths through namespaces, records and value types
/// (`weather.now.temperature`, `month.days`, `d.name` in `for d in disks`), and built-in choices. Once the parser and
/// checker exist, the catalog test parses and checks every example in its context instead (§9.7).
struct DeskExampleCheck {
    let catalog: DeskCatalog

    /// Names the example harness declares (§9.7): variables, the computed `month`, options and element names.
    static let harnessValues: [String: DeskType?] = [
        "page": .plainNumber, "seconds": .plainNumber, "plays": .plainNumber, "dice": .plainNumber,
        "flags": .plainNumber, "monthsFromNow": .plainNumber, "note": .string, "month": .record("MonthGrid"),
        "title": nil, "details": nil, "toast": nil,
    ]
    static let harnessOptions: [String: DeskType] = [
        "weekStart": .enumeration("Weekday"), "highlight": .color, "showSeconds": .bool, "city": .string,
        "folder": .folderPath, "apiKey": .secret,
    ]

    enum Tok: Equatable {
        case name(String)
        case number(String, unit: String)
        case string
        case punct(String)
        case newline
        case interpolationStart, interpolationEnd
    }

    /// The problems found in `example`, as short sentences; empty when it looks right. `alongside`: Desk text the
    /// example harness places next to it (its context's declarations and siblings), whose names it may use.
    func problems(in example: String, alongside: [String] = []) -> [String] {
        var problems: [String] = []
        let lines = example.split(separator: "\n", omittingEmptySubsequences: false)
        if example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ["empty"] }
        if lines.count > 3 { problems.append("more than three lines") }
        var tokens: [Tok] = []
        tokenize(Array(example.unicodeScalars), into: &tokens, problems: &problems)
        var context: [Tok] = []
        var ignored: [String] = []
        for text in alongside {
            tokenize(Array(text.unicodeScalars), into: &context, problems: &ignored)
            context.append(.newline)
        }
        problems += checkBrackets(tokens)
        problems += checkNames(tokens, context: context)
        return problems
    }

    // MARK: Tokens

    private static let punctuation = ["...", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "++", "--", "??",
                                      "?.", "=>", "->", "(", ")", "{", "}", "[", "]", ",", ":", ";", ".", "=", "<", ">",
                                      "+", "-", "*", "/", "%", "?", "!", "&", "|", "^", "~", "@", "$", "#", "\\"]

    private func isNameStart(_ c: Unicode.Scalar) -> Bool { c.isASCII && (c.properties.isAlphabetic || c == "_") }
    private func isNameChar(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || ("0"..."9").contains(c) }
    private func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }

    /// Tokens of `s` from `start`; stops after the `}` that closes an interpolation when `inInterpolation`.
    @discardableResult
    private func tokenize(_ s: [Unicode.Scalar], from start: Int = 0, inInterpolation: Bool = false,
                          into tokens: inout [Tok], problems: inout [String]) -> Int {
        var i = start
        var depth = 0
        while i < s.count {
            let c = s[i]
            if c == "\n" { tokens.append(.newline); i += 1; continue }
            if c == " " || c == "\t" { i += 1; continue }
            if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if c == "#", i + 1 < s.count, s[i + 1] == "\"" {
                // A raw string: up to the first `"#` on the line.
                var j = i + 2
                while j + 1 < s.count, !(s[j] == "\"" && s[j + 1] == "#"), s[j] != "\n" { j += 1 }
                if j + 1 >= s.count || s[j] == "\n" { problems.append("unclosed raw string"); return s.count }
                tokens.append(.string)
                i = j + 2
                continue
            }
            if c == "\"" {
                i = scanString(s, from: i + 1, into: &tokens, problems: &problems)
                continue
            }
            if isDigit(c) {
                var j = i
                while j < s.count, isDigit(s[j]) { j += 1 }
                if j + 1 < s.count, s[j] == ".", isDigit(s[j + 1]) {
                    j += 1
                    while j < s.count, isDigit(s[j]) { j += 1 }
                }
                let digits = String(String.UnicodeScalarView(s[i..<j]))
                var k = j
                if k < s.count, s[k] == "%" {
                    k += 1
                } else if k < s.count, s[k].properties.isAlphabetic || s[k] == "°" {
                    while k < s.count, s[k].properties.isAlphabetic || s[k] == "°" { k += 1 }
                    if k + 1 < s.count, s[k] == "/", s[k + 1] == "s" || s[k + 1] == "h",
                       !(k + 2 < s.count && isNameChar(s[k + 2])) {
                        k += 2
                    }
                }
                tokens.append(.number(digits, unit: String(String.UnicodeScalarView(s[j..<k]))))
                i = k
                continue
            }
            if isNameStart(c) {
                var j = i
                while j < s.count, isNameChar(s[j]) { j += 1 }
                tokens.append(.name(String(String.UnicodeScalarView(s[i..<j]))))
                i = j
                continue
            }
            if inInterpolation {
                if c == "{" || c == "(" || c == "[" { depth += 1 }
                if c == ")" || c == "]" { depth -= 1 }
                if c == "}" {
                    if depth == 0 { tokens.append(.interpolationEnd); return i + 1 }
                    depth -= 1
                }
            }
            if let p = DeskExampleCheck.punctuation.first(where: { p in
                let ps = Array(p.unicodeScalars)
                return i + ps.count <= s.count && Array(s[i..<(i + ps.count)]) == ps
            }) {
                tokens.append(.punct(p))
                i += p.unicodeScalars.count
                continue
            }
            problems.append("character \(String(c)) outside text")
            i += 1
        }
        if inInterpolation { problems.append("unclosed {…} in text") }
        return i
    }

    /// Scans an ordinary string after its opening quote; returns the index after the closing quote.
    private func scanString(_ s: [Unicode.Scalar], from start: Int, into tokens: inout [Tok],
                            problems: inout [String]) -> Int {
        var i = start
        tokens.append(.string)
        while i < s.count {
            let c = s[i]
            if c == "\n" { problems.append("text runs past the end of its line"); return i }
            if c == "\\" { i += 2; continue }
            if c == "\"" { return i + 1 }
            if c == "{" {
                if i + 1 < s.count, s[i + 1] == "{" { i += 2; continue }
                tokens.append(.interpolationStart)
                i = tokenize(s, from: i + 1, inInterpolation: true, into: &tokens, problems: &problems)
                continue
            }
            if c == "}" {
                if i + 1 < s.count, s[i + 1] == "}" { i += 2; continue }
                problems.append("a lone } in text")
            }
            i += 1
        }
        problems.append("unclosed text")
        return i
    }

    // MARK: Brackets

    private func checkBrackets(_ tokens: [Tok]) -> [String] {
        var stack: [String] = []
        let pairs = [")": "(", "]": "[", "}": "{"]
        for t in tokens {
            guard case .punct(let p) = t else { continue }
            if ["(", "[", "{"].contains(p) { stack.append(p) }
            if let open = pairs[p] {
                if stack.last == open { stack.removeLast() } else { return ["unbalanced \(p)"] }
            }
        }
        return stack.isEmpty ? [] : ["unclosed \(stack.last!)"]
    }

    // MARK: Names

    private func checkNames(_ tokens: [Tok], context: [Tok]) -> [String] {
        var problems: [String] = []
        let c = catalog
        let foreignOperators: Set<String> = ["&&", "||", "+=", "-=", "*=", "/=", "++", "--", "??", "?.", "=>", "->", "!", "&",
                                             "|", "^", "~", "@", "$", "\\"]

        // Names the example declares, and the choices of its Pickers.
        var own: [String: DeskType?] = DeskExampleCheck.harnessValues
        var options = DeskExampleCheck.harnessOptions.mapValues { Optional($0) }
        var localChoices = Set<String>()
        var styles = Set<String>()
        for (i, t) in (context + [.newline] + tokens).enumerated() {
            let all = context + [.newline] + tokens
            if t == .name("style"), i + 2 < all.count, case .name(let n) = all[i + 1], all[i + 2] == .punct("{") {
                styles.insert(n)
            }
            if case .name("name") = t, i >= 1, all[i - 1] == .punct("."), i + 2 < all.count, all[i + 1] == .punct("("),
               case .name(let n) = all[i + 2] {
                own[n] = .some(nil)
            }
        }
        for (i, t) in tokens.enumerated() {
            if t == .name("for"), i + 3 < tokens.count, case .name(let variable) = tokens[i + 1], tokens[i + 2] == .name("in") {
                if case .list(let element)? = pathType(tokens, from: i + 3, own: own).type {
                    own[variable] = .some(element)
                } else {
                    own[variable] = .some(nil)
                }
            }
            if case .name(let word) = t, ["variable", "saved", "computed"].contains(word), i + 1 < tokens.count,
               case .name(let declared) = tokens[i + 1] {
                own[declared] = resolveInitializer(tokens, from: i + 3, own: own)
            }
            if case .name("Picker") = t, i + 1 < tokens.count, tokens[i + 1] == .punct("(") {
                var depth = 0
                var j = i + 1
                while j < tokens.count {
                    if tokens[j] == .punct("(") || tokens[j] == .punct("[") { depth += 1 }
                    if tokens[j] == .punct(")") || tokens[j] == .punct("]") { depth -= 1; if depth == 0 { break } }
                    if tokens[j] == .punct("."), j + 1 < tokens.count, case .name(let n) = tokens[j + 1] { localChoices.insert(n) }
                    j += 1
                }
            }
            if case .name(let n) = t, i + 2 < tokens.count, tokens[i + 1] == .punct("="), case .name(let control) = tokens[i + 2],
               c.control(named: control) != nil, i == 0 || [Tok.newline, .punct("{"), .punct(";")].contains(tokens[i - 1]) {
                options[n] = .some(nil)
            }
            if case .name("name") = t, i >= 1, tokens[i - 1] == .punct("."), i + 2 < tokens.count, tokens[i + 1] == .punct("("),
               case .name(let n) = tokens[i + 2] {
                own[n] = .some(nil)
            }
        }

        var parenDepth = 0
        var expression = false        // after `=` in a statement, until the statement ends
        var statementStart = true
        var interpolation = 0
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            let previous: Tok? = i > 0 ? tokens[i - 1] : nil
            let next: Tok? = i + 1 < tokens.count ? tokens[i + 1] : nil
            defer { i += 1 }
            switch t {
            case .newline, .punct(";"):
                if parenDepth == 0 && interpolation == 0 { expression = false; statementStart = true }
                continue
            case .punct("{"), .punct("}"):
                if parenDepth == 0 && interpolation == 0 { expression = false }
                statementStart = t == .punct("{")
                continue
            case .punct("("), .punct("["):
                parenDepth += 1
            case .punct(")"), .punct("]"):
                parenDepth -= 1
            case .interpolationStart:
                interpolation += 1
            case .interpolationEnd:
                interpolation -= 1
            case .punct(let p):
                if foreignOperators.contains(p) { problems.append("operator \(p)") }
                if p == "=" && parenDepth == 0 && interpolation == 0 {
                    // An option declaration: the control is a call statement with modifiers, not an expression.
                    if case .name(let n)? = next, n.first?.isUppercase == true { expression = false } else { expression = true }
                }
                if p == "." {
                    if case .name(let n)? = next {
                        let modifierPlace = parenDepth == 0 && interpolation == 0 && !expression
                            && (statementStart || previous == .punct(")") || previous == .punct("}"))
                        let afterValue: Bool
                        switch previous {
                        case .name?, .punct(")")?, .punct("]")?, .string?: afterValue = true
                        default: afterValue = false
                        }
                        if modifierPlace {
                            if c.modifier(named: n) == nil { problems.append("no modifier .\(n)") }
                        } else if !afterValue {
                            // An implicit member: a case or named value of some type, or a Picker's own choice.
                            if c.index.implicitMembers[n] == nil && !localChoices.contains(n) {
                                problems.append("no built-in choice .\(n)")
                            }
                        }
                    }
                }
            case .number(_, let unit):
                if !unit.isEmpty && c.unit(spelling: unit) == nil { problems.append("unknown unit \(unit)") }
            case .name(let n):
                if previous == .punct(".") { break }
                if n.first!.isUppercase {
                    if next == .punct("(") || next == .punct("{") {
                        if c.component(named: n) == nil && c.control(named: n) == nil {
                            problems.append("no component \(n)")
                        }
                    } else if next == .punct(".") {
                        if c.enumeration(n) == nil && !["Color", "Paint"].contains(n) { problems.append("no type \(n)") }
                    }
                    break
                }
                if ["variable", "saved", "computed", "for", "in", "if", "else", "and", "or", "not", "true", "false"]
                    .contains(n) { break }
                if next == .punct("(") {
                    if own[n] == nil && c.function(named: n) == nil {
                        problems.append("no function \(n)")
                    } else if c.function(named: n)?.data != nil {
                        // A function that reads data (`files(…)`, `command(…)`): its record's fields follow.
                        problems += pathType(tokens, from: i, own: own).problems
                    }
                    break
                }
                if next == .punct(":") || next == .punct("=") { break }
                // `.style(name)`: one of the widget's styles.
                if previous == .punct("("), i >= 3, tokens[i - 2] == .name("style"), tokens[i - 3] == .punct(".") {
                    if !styles.contains(n) { problems.append("no style \(n)") }
                    break
                }
                problems += checkPath(tokens, from: i, own: own, options: options)
                i = skipPath(tokens, from: i) - 1
            case .string:
                break
            }
            statementStart = false
        }
        return problems
    }

    /// The type of a declaration's initializer when it is a plain data path; nil (unknown) otherwise.
    private func resolveInitializer(_ tokens: [Tok], from start: Int, own: [String: DeskType?]) -> DeskType? {
        guard start < tokens.count, case .name = tokens[start] else { return nil }
        return pathType(tokens, from: start, own: own).type
    }

    /// Checks the data path starting at `start` (`cpu.usage`, `month.days`, `options.city`, `event.xPercent`);
    /// `for x in path` binds `x` to the path's element type.
    private func checkPath(_ tokens: [Tok], from start: Int, own: [String: DeskType?],
                           options: [String: DeskType?]) -> [String] {
        guard case .name(let head) = tokens[start] else { return [] }
        if head == "options" {
            guard start + 2 < tokens.count, tokens[start + 1] == .punct("."), case .name(let n) = tokens[start + 2] else {
                return ["options without a name"]
            }
            return options[n] == nil ? ["no option \(n)"] : []
        }
        if own[head] == nil && head != "event" && catalog.namespace(named: head) == nil {
            // Loop variables bind themselves; any other bare name is unknown.
            if start >= 1, tokens[start - 1] == .name("for") { return [] }
            return ["no name \(head)"]
        }
        return pathType(tokens, from: start, own: own).problems
    }

    private func skipPath(_ tokens: [Tok], from start: Int) -> Int {
        var i = start + 1
        while i + 1 < tokens.count, tokens[i] == .punct("."), case .name = tokens[i + 1] {
            i += 2
            if i < tokens.count, tokens[i] == .punct("(") { i = skipArguments(tokens, from: i) }
        }
        return i
    }

    private func skipArguments(_ tokens: [Tok], from open: Int) -> Int {
        var depth = 0
        var i = open
        while i < tokens.count {
            if tokens[i] == .punct("(") { depth += 1 }
            if tokens[i] == .punct(")") { depth -= 1; if depth == 0 { return i + 1 } }
            i += 1
        }
        return i
    }

    /// Walks `head.member.member…` through namespaces, records and value types.
    private func pathType(_ tokens: [Tok], from start: Int, own: [String: DeskType?]) -> (type: DeskType?, problems: [String]) {
        guard case .name(let head) = tokens[start] else { return (nil, []) }
        var i = start + 1
        var type: DeskType?
        var namespacePath: String?
        if let known = own[head] {
            guard let t = known else { return (nil, []) }
            type = t
        } else if head == "event" {
            type = .record("Event")
        } else if let f = catalog.function(named: head), i < tokens.count, tokens[i] == .punct("(") {
            guard let data = f.data else { return (nil, []) }
            type = data.type
            i = skipArguments(tokens, from: i)
        } else {
            namespacePath = head
            type = catalog.namespace(named: head)?.valueType
        }
        while i + 1 < tokens.count, tokens[i] == .punct("."), case .name(let n) = tokens[i + 1] {
            let call = i + 2 < tokens.count && tokens[i + 2] == .punct("(")
            if let ns = namespacePath {
                if catalog.namespace(named: "\(ns).\(n)") != nil {
                    namespacePath = "\(ns).\(n)"
                } else if let m = catalog.member(path: "\(ns).\(n)") {
                    namespacePath = nil
                    type = m.kind == .action ? nil : m.type
                } else if let t = type, let m = catalog.member(n, of: t, call: call) {
                    namespacePath = nil
                    type = m.type
                } else {
                    return (nil, ["no \(ns).\(n)"])
                }
            } else if let t = type {
                switch t {
                case .any, .json, .typeVar: return (nil, [])
                default: break
                }
                guard let m = catalog.member(n, of: t, call: call) else { return (nil, ["no .\(n) on \(t)"]) }
                type = m.type
            } else {
                return (nil, [])
            }
            i += 2
            if call { i = skipArguments(tokens, from: i) }
        }
        if namespacePath != nil, type == nil { return (nil, []) }
        return (type, [])
    }
}
