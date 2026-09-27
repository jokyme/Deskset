import Foundation

// Text (§4.11, §6.4 level 4): interpolations and their format options, patterns (DK1018, DK4027), date patterns
// (DK4026, DK4050, DK9308), Rainmeter placeholders and section variables in text (DK9310, DK9305), braces around
// known data (DK9011), Windows paths (DK9307, DK1012), direction marks in commands (DK8207), and the string table
// for translations (§8.6).

extension Checker {
    func inferString(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let string = StringLiteralSyntax(unchecked: node)
        let segments = string.segments
        var v = Val(.string)
        v.isConstant = true
        var interpolations: [InterpolationSyntax] = []
        var textParts: [(token: PositionedToken, cooked: String)] = []
        for segment in segments {
            switch segment {
            case .text(let token, let cooked): textParts.append((token, cooked))
            case .interpolation(let i): interpolations.append(i)
            case .foreign: break
            }
        }
        let role = context.param?.role
        // Interpolations: each value is shown as text (§4.11).
        var onlyOptions = true
        for interpolation in interpolations {
            var inner = context
            inner.display = true
            inner.param = context.param.map { p in var q = p; q.type = .any; q.role = .display; return q }
            let value = interpolation.value.node
            // DK1018: `{3}` in a pattern would put in a number.
            if role == .pattern, value.kind == .numberLiteral, interpolation.formatOptions.isEmpty,
               NumberLiteralSyntax(unchecked: value).unit == nil {
                reportNumberInPattern(string, interpolation)
                v.error = true
                continue
            }
            var val = inferValue(value, inner, expected: nil)
            if !val.error {
                if case .list = val.type {
                    let t = text(value)
                    report(.notDisplayable, range(value), ["text": .code(t), "type": .type(val.type),
                                                           "hint": hintText(.notDisplayable, "joinList"),
                                                           "fixed": .code(t + ".joined(\", \")")],
                           fixIts: [fix("append", [edit(range(value).upperBound..<range(value).upperBound, ".joined(\", \")")],
                                        ["text": .code(".joined(\", \")")])])
                    val.error = true
                }
                if val.secret && ![.command, .webAddress].contains(role) {
                    report(.secretShown, range(value))
                }
                if let slot = val.open { recordDisplayUse(slot, range(value)) }
            }
            checkFormatOptions(interpolation, value: val, context)
            v.deps.formUnion(val.deps)
            v.secret = v.secret || val.secret
            if !val.deps.allSatisfy({ if case .option = $0 { return true }; return false }) || val.deps.isEmpty && !val.isConstant {
                onlyOptions = false
            }
            if val.deps.contains(where: { if case .data = $0 { return true }; return false }) { v.canBeMissing = true }
            if mute == 0 { dependencies[id(value)] = val.deps }
        }
        if !interpolations.isEmpty {
            v.isTemplate = true
            v.isConstant = false
            v.templateOfOptions = onlyOptions
            v.deps.insert(.language)
        } else if let value = string.literalValue {
            v.stringLiteral = value
            v.templateOfOptions = true
        }
        if string.isRaw { return v }
        // Text scans (ordinary strings only).
        if mute == 0 {
            scanText(textParts, string: string, node: node, context)
            if string.isWindowsPath { reportWindowsPath(string, node: node, context) }
            if [.command, .webAddress, .folderPath, .place].contains(role) { reportDirectionMarks(node, role: role!) }
            recordStringEntry(node, string: string, context)
        }
        return v
    }

    /// DK1018: an interpolation that is only a whole number, in a pattern.
    func reportNumberInPattern(_ string: StringLiteralSyntax, _ interpolation: InterpolationSyntax) {
        let r = range(interpolation.node)
        let whole = text(string.node)
        let inner = String(whole.dropFirst().dropLast())
        let raw = "#\"" + StringLiteralSyntax.cook(inner.replacingOccurrences(of: "{{", with: "\u{0}").replacingOccurrences(of: "}}", with: "\u{1}"))
            .replacingOccurrences(of: "\u{0}", with: "{").replacingOccurrences(of: "\u{1}", with: "}") + "\"#"
        let escaped = "{" + text(r) + "}"
        report(.numberInPattern, r, ["text": .code(text(r)), "raw": .code(raw), "escaped": .code(escaped)],
               fixIts: [fix("writeAsRaw", [edit(range(string.node), raw)]),
                        fix("replaceWith", [edit(r, escaped)], ["text": .code(escaped)])])
    }

    // MARK: - Format options

    func checkFormatOptions(_ interpolation: InterpolationSyntax, value: Val, _ context: ExprContext) {
        var seen = Set<String>()
        for option in interpolation.formatOptions {
            let label = option.label.name
            let labelRange = range(option.label.node)
            let valueNode = option.value.node
            if !seen.insert(label).inserted {
                report(.duplicateLabel, labelRange, ["label": .code(label)],
                       fixIts: [fix("removeOne", [edit(option.node.range.lowerBound..<range(option.node).upperBound, "")])])
                continue
            }
            guard let rows = index.formatOptions[label] else {
                _ = speculate { infer(valueNode, context, expected: nil) }
                let labels = Array(Set(catalog.formatOptions.map(\.label))).sorted()
                let suggestion = DidYouMean.suggest(label, candidates: labels)
                var fixIts: [FixIt] = []
                if let best = suggestion.names.first, suggestion.fixable {
                    fixIts.append(fix("didYouMean", [edit(labelRange, best)], ["text": .code(best)]))
                }
                report(.formatOptionNotApplicable, labelRange, ["label": .code(label), "type": .type(value.type),
                                                                "list": .list(applicableFormatLabels(value.type).map { .code($0 + ":") }, joiner: .or)],
                       fixIts: fixIts)
                continue
            }
            // The row whose `appliesTo` covers the value's type.
            let row = rows.first { formatOptionApplies($0, to: value) }
            guard let spec = row else {
                _ = speculate { infer(valueNode, context, expected: nil) }
                if !value.error {
                    report(.formatOptionNotApplicable, labelRange, ["label": .code(label), "type": .type(value.type),
                                                                    "list": .list(applicableFormatLabels(value.type).map { .code($0 + ":") }, joiner: .or)])
                }
                continue
            }
            var inner = context
            inner.display = label == "missing"
            inner.param = label == "missing" ? context.param : nil
            inner.modifier = nil
            if label == "format" {
                checkDateFormat(valueNode, inner)
                continue
            }
            let val = inferValue(valueNode, inner, expected: spec.type)
            if val.error { continue }
            if label == "unit", valueNode.kind == .stringLiteral, let s = val.stringLiteral {
                reportQuotedChoice(valueNode, s, expected: spec.type)
                continue
            }
            _ = coerce(val, valueNode, to: spec.type, what: .code(label + ":"), inner, range: spec.range)
        }
    }

    func formatOptionApplies(_ spec: FormatOptionSpec, to value: Val) -> Bool {
        if value.error || value.isJson || value.open != nil { return true }
        for t in spec.appliesTo {
            switch t {
            case .any: return true
            case .anyNumber: if value.isNumber { return true }
            case .number(let d): if value.dimension == d { return true }
            default: if value.type.sameKind(as: t) { return true }
            }
        }
        return false
    }

    func applicableFormatLabels(_ type: DeskType) -> [String] {
        var v = Val(type)
        v.error = false
        var labels: [String] = []
        for spec in catalog.formatOptions where formatOptionApplies(spec, to: v) && !labels.contains(spec.label) {
            labels.append(spec.label)
        }
        return labels
    }

    /// `format:` of a date: a preset, or a Unicode date pattern (DK4026, DK4050, DK9308).
    func checkDateFormat(_ node: PositionedNode, _ context: ExprContext) {
        if node.kind == .implicitMemberExpr {
            _ = inferValue(node, context, expected: .enumeration("DatePreset"))
            return
        }
        let val = inferValue(node, context, expected: .string)
        guard let pattern = val.stringLiteral else {
            if !val.error && val.type != .string && !val.isTemplate {
                _ = coerce(val, node, to: .oneOf([.string, .enumeration("DatePreset")]), what: .code("format:"), context)
            }
            return
        }
        let r = range(node)
        if pattern.contains("%") {
            let fixed = Checker.convertRainmeterDateFormat(pattern)
            report(.rainmeterDateFormat, r, ["text": .code(pattern), "fixed": .code(fixed)],
                   fixIts: [fix("replace", [edit(r, "\"" + fixed + "\"")])])
            return
        }
        if let reason = Checker.datePatternProblem(pattern) {
            report(.invalidDatePattern, r, ["pattern": .code(pattern), "reason": .text(reason)])
            return
        }
        if let fixed = Checker.monthForMinutes(pattern) {
            report(.monthInTimePattern, r, fixIts: [fix("replaceWith", [edit(r, "\"" + fixed + "\"")], ["text": .code(fixed)])])
        }
    }

    /// Rainmeter's `Format=` (strftime) → a Unicode date pattern.
    static func convertRainmeterDateFormat(_ pattern: String) -> String {
        let map: [String: String] = ["%H": "HH", "%#H": "H", "%M": "mm", "%S": "ss", "%I": "hh", "%#I": "h", "%p": "a",
                                     "%A": "EEEE", "%a": "EEE", "%d": "dd", "%#d": "d", "%B": "MMMM", "%b": "MMM",
                                     "%m": "MM", "%#m": "M", "%Y": "yyyy", "%y": "yy", "%#M": "m", "%j": "D"]
        var out = ""
        var i = pattern.startIndex
        while i < pattern.endIndex {
            if pattern[i] == "%" {
                for length in [3, 2] {
                    guard let end = pattern.index(i, offsetBy: length, limitedBy: pattern.endIndex) else { continue }
                    if let repl = map[String(pattern[i..<end])] {
                        out += repl
                        i = end
                        break
                    }
                }
                if i < pattern.endIndex, pattern[i] == "%" { out.append("%"); i = pattern.index(after: i) }
                continue
            }
            let c = pattern[i]
            if c.isLetter { out += "'\(c)'" } else { out.append(c) }
            i = pattern.index(after: i)
        }
        return out
    }

    /// Why a Unicode date pattern is invalid, or nil.
    static func datePatternProblem(_ pattern: String) -> LocalizedText? {
        let valid = Set("GyYuUrQqMLlwWdDFgEecabBhHKkjJCmsSAzZOvVXx")
        var inQuote = false
        for c in pattern {
            if c == "'" { inQuote.toggle(); continue }
            if inQuote { continue }
            if c.isASCII && c.isLetter && !valid.contains(c) {
                return LocalizedText("“\(c)” is not a date letter; put words in single quotes", "“\(c)” 不是日期格式里的字母；文字要放在单引号里")
            }
        }
        if inQuote { return LocalizedText("a quote is not closed", "单引号没有配对") }
        return nil
    }

    /// `HH:MM` → `HH:mm` (DK4050), or nil.
    static func monthForMinutes(_ pattern: String) -> String? {
        let scalars = Array(pattern)
        var out = scalars
        var changed = false
        var i = 0
        while i < scalars.count {
            if scalars[i] == "M" {
                var j = i
                while j < scalars.count, scalars[j] == "M" { j += 1 }
                let run = j - i
                let before = i >= 2 ? String(scalars[i - 2...i - 1]) : ""
                let afterColonSeconds = j + 2 < scalars.count + 1 && j + 1 < scalars.count && scalars[j] == ":" && scalars[j + 1] == "s"
                if run <= 2, (before.last == ":" && ["H", "h", "k", "K"].contains(before.first ?? " ")) || afterColonSeconds {
                    for k in i..<j { out[k] = "m" }
                    changed = true
                }
                i = j
                continue
            }
            i += 1
        }
        return changed ? String(out) : nil
    }

    // MARK: - Text scans

    /// Rainmeter placeholders (`%1`, `#Name#`, DK9310), section variables (`[MeasureCPU]`, DK9305) and braces around
    /// known data (`{{ cpu.usage }}`, DK9011).
    func scanText(_ parts: [(token: PositionedToken, cooked: String)], string: StringLiteralSyntax, node: PositionedNode,
                  _ context: ExprContext) {
        let role = context.param?.role
        let isCode = [.pattern, .datePattern, .command, .webAddress, .folderPath, .pathData].contains(role)
        for (token, _) in parts {
            let raw = token.token.text
            let base = token.textStart
            if !isCode {
                scanPlaceholders(raw, base: base, string: string)
                scanSectionVariables(raw, base: base)
            }
            scanDoubleBraces(raw, base: base, context)
        }
    }

    func scanPlaceholders(_ raw: String, base: Int, string: StringLiteralSyntax) {
        let bytes = Array(raw.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 1 < bytes.count, (0x31...0x39).contains(bytes[i + 1]) {
                // `%1`…`%9`.
                let r = (base + i)..<(base + i + 2)
                let t = String(decoding: bytes[i..<(i + 2)], as: UTF8.self)
                report(.rainmeterPlaceholderInText, r, ["text": .code(t), "fixed": .code("{…}")])
                i += 2
                continue
            }
            if bytes[i] == 0x23 {
                var j = i + 1
                while j < bytes.count, (bytes[j] >= 0x30 && bytes[j] <= 0x39) || (bytes[j] | 0x20 >= 0x61 && bytes[j] | 0x20 <= 0x7A) || bytes[j] == 0x5F { j += 1 }
                if j < bytes.count, bytes[j] == 0x23, j > i + 1 {
                    let name = String(decoding: bytes[(i + 1)..<j], as: UTF8.self)
                    let r = (base + i)..<(base + j + 1)
                    let lower = name.prefix(1).lowercased() + name.dropFirst()
                    var fixed = "{…}"
                    var fixIts: [FixIt] = []
                    if options[lower] != nil || options[name] != nil {
                        let optionName = options[lower] != nil ? lower : name
                        fixed = "{options.\(optionName)}"
                        fixIts.append(fix("replaceWith", [edit(r, fixed)], ["text": .code(fixed)]))
                    } else if decls[lower] != nil {
                        fixed = "{\(lower)}"
                        fixIts.append(fix("replaceWith", [edit(r, fixed)], ["text": .code(fixed)]))
                    }
                    report(.rainmeterPlaceholderInText, r, ["text": .code("#\(name)#"), "fixed": .code(fixed)], fixIts: fixIts)
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
    }

    func scanSectionVariables(_ raw: String, base: Int) {
        let bytes = Array(raw.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x5B {
                var j = i + 1
                while j < bytes.count, bytes[j] != 0x5D, bytes[j] != 0x5B { j += 1 }
                if j < bytes.count, bytes[j] == 0x5D {
                    let inner = String(decoding: bytes[(i + 1)..<j], as: UTF8.self)
                    let name = inner.hasPrefix("&") ? String(inner.dropFirst()) : inner
                    let measure = name.hasPrefix("Measure") || name.hasPrefix("measure")
                    if measure, Checker.isIdentifier(name.components(separatedBy: ":").first ?? name) {
                        let desk = rainmeterMeasureGuess(name)
                        report(.rainmeterSectionVariable, (base + i)..<(base + j + 1), ["name": .code(inner), "desk": .code(desk)])
                    }
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
    }

    /// The Desk data a Rainmeter measure name most likely meant (`MeasureCPU` → `{cpu.usage}`).
    func rainmeterMeasureGuess(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("cpu") { return "{cpu.usage}" }
        if lower.contains("mem") || lower.contains("ram") { return "{memory.used}" }
        if lower.contains("time") || lower.contains("clock") { return "{time.now}" }
        if lower.contains("disk") { return "{disk.free}" }
        if lower.contains("net") { return "{network.download}" }
        if lower.contains("bat") { return "{battery.level}" }
        return "{cpu.usage}"
    }

    /// `{{ x }}` shows braces; when `x` is known data it was meant as an interpolation (DK9011).
    func scanDoubleBraces(_ raw: String, base: Int, _ context: ExprContext) {
        var search = raw[...]
        while let open = search.range(of: "{{") {
            guard let close = search[open.upperBound...].range(of: "}}") else { break }
            let inner = String(search[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            if isKnownDataPath(inner) {
                let startOffset = raw.utf8.distance(from: raw.utf8.startIndex, to: open.lowerBound.samePosition(in: raw.utf8) ?? raw.utf8.startIndex)
                let endOffset = raw.utf8.distance(from: raw.utf8.startIndex, to: close.upperBound.samePosition(in: raw.utf8) ?? raw.utf8.endIndex)
                let r = (base + startOffset)..<(base + endOffset)
                let fixed = "{\(inner)}"
                report(.doubleBraces, r, ["text": .code("{\(inner)}"), "fixed": .code(fixed)],
                       fixIts: [fix("rewrite", [edit(r, fixed)])])
            }
            search = search[close.upperBound...]
        }
    }

    /// A data path, declaration, option (`options.x`), loop variable or `event` field.
    func isKnownDataPath(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, !first.isEmpty, parts.allSatisfy({ Checker.isIdentifier($0) }) else { return false }
        if decls[first] != nil || loopStack.contains(where: { $0.name == first }) { return parts.count == 1 || true }
        if first == "options" { return parts.count == 2 && options[parts[1]] != nil }
        if first == "event" { return parts.count == 2 }
        if parts.count >= 2, catalog.member(path: parts.prefix(2).joined(separator: ".")) != nil { return true }
        if parts.count == 1, catalog.namespace(named: first)?.value != nil { return true }
        return false
    }

    /// A string that looks like a Windows path: DK9307 where a path or program is meant, DK1012 in text people read.
    func reportWindowsPath(_ string: StringLiteralSyntax, node: PositionedNode, _ context: ExprContext) {
        let r = range(node)
        let value = string.literalValue ?? text(node)
        let callee = context.callee ?? ""
        let pathLike = [ParamRole.command, .folderPath].contains(context.param?.role)
            || ["open", "run", "command", "files", "folder", "disk.at", "Image"].contains(callee)
        if pathLike {
            let fileName = value.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? value
            let isProgram = fileName.lowercased().hasSuffix(".exe")
            let app = String(fileName.dropLast(isProgram ? 4 : 0))
            var fixIts: [FixIt] = []
            if isProgram && callee == "open" { fixIts.append(fix("replaceWith", [edit(r, "\"\(app)\"")], ["text": .code("\"\(app)\"")])) }
            report(.windowsPath, r, ["hint": hintText(.windowsPath, isProgram ? "program" : "file"), "app": .code(app),
                                     "file": .code(fileName)], fixIts: fixIts)
        } else {
            let raw = text(node)
            let doubled = raw.replacingOccurrences(of: "\\", with: "\\\\")
            report(.invalidEscape, r, ["c": .code("")], fixIts: [fix("showBackslash", [edit(r, doubled)])])
        }
    }

    /// DK8207: an invisible direction mark in a command, web address or folder path (replaces the lexer's DK1019).
    func reportDirectionMarks(_ node: PositionedNode, role: ParamRole) {
        let r = range(node)
        for d in tree.diagnostics where d.id == .directionMark && r.contains(d.range.lowerBound) {
            droppedParserDiagnostics.insert(diagnosticKey(d))
            let what: String
            switch role {
            case .command: what = "construct:action"
            default: what = "slot:string"
            }
            report(.directionMarkInCommand, d.range, ["what": .text(role == .command ? LocalizedText("command", "命令")
                                                                    : role == .webAddress ? LocalizedText("web address", "网址")
                                                                    : LocalizedText("folder path", "文件夹路径"))],
                   fixIts: [fix("remove", [edit(d.range, "")])])
            _ = what
        }
    }

    // MARK: - String table

    /// Records a string literal that reaches a translatable parameter (§8.6, D104).
    func recordStringEntry(_ node: PositionedNode, string: StringLiteralSyntax, _ context: ExprContext) {
        guard context.param?.translatable == true || context.translatableField else { return }
        let key = translationKey(string)
        guard !key.isEmpty else { return }
        stringTable.append(StringEntry(range: range(node), node: id(node), key: key, translatable: true))
    }

    /// The canonical key of a string: its text segments as written and each interpolation as its tokens, printed the
    /// formatter's way (§8.6).
    func translationKey(_ string: StringLiteralSyntax) -> String {
        var key = ""
        for segment in string.segments {
            switch segment {
            case .text(let token, _): key += token.token.text
            case .interpolation(let i): key += "{" + Checker.canonicalTokens(i.node.tokens.dropFirst().dropLast()) + "}"
            case .foreign(let n): key += text(n)
            }
        }
        return key
    }

    /// Tokens printed with the formatter's spacing (F6): a space around binary operators, `and`, `or`, `?` and a
    /// ternary's `:`, after `,` and a label's `:`, between two words; none elsewhere.
    static func canonicalTokens<S: Sequence>(_ tokens: S) -> String where S.Element == PositionedToken {
        let binary: Set<TokenKind> = [.plus, .minus, .star, .slash, .percent, .equalEqual, .bangEqual, .less, .lessEqual,
                                      .greater, .greaterEqual, .andKeyword, .orKeyword, .question, .equal]
        func wordish(_ k: TokenKind) -> Bool { k == .identifier || k.isKeyword || k == .number || k == .invalidIdentifier }
        var out = ""
        var previous: TokenKind?
        var previousWasPrefix = false
        var openQuestions = 0
        for t in tokens where !t.token.isMissing {
            var k = t.kind
            let ternaryColon = k == .colon && openQuestions > 0
            if ternaryColon { openQuestions -= 1 }
            if k == .question { openQuestions += 1 }
            let isPrefix = (k == .minus || k == .notKeyword) && (previous == nil || binary.contains(previous!) && !previousWasPrefix
                || [.lParen, .lBracket, .comma, .colon].contains(previous!))
            if let p = previous {
                var space = false
                if p == .comma || (p == .colon) { space = true }
                if ternaryColon { space = true }
                if binary.contains(k) && !isPrefix { space = true }
                if binary.contains(p) && !previousWasPrefix { space = true }
                if p == .notKeyword { space = true }
                if wordish(p) && wordish(k) { space = true }
                if k == .colon && !ternaryColon { space = false }
                if [.lParen, .lBracket, .dot].contains(p) || [.rParen, .rBracket, .dot, .comma, .lParen].contains(k) && !(k == .lParen && binary.contains(p)) {
                    if !(k == .lParen && (binary.contains(p) || p == .comma || p == .colon)) { space = false }
                }
                if space { out += " " }
            }
            out += t.token.text
            if k == .colon && ternaryColon { k = .question }
            previous = k
            previousWasPrefix = isPrefix
        }
        return out
    }
}
