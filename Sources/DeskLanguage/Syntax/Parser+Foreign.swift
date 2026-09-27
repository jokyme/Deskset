import Foundation

/// One line recognised as another language's (§2.11 rule 5, §6.4 level 3).
struct ForeignLineMatch {
    var kind: ForeignKind
    /// Token range of the line, with the brace-matched block of a line that opens one.
    var start: Int
    var end: Int
    var diagnostic: DiagnosticID
    var severity: Severity
    var arguments: [String: DiagnosticArgument] = [:]
    /// The line's own exact fix-it, when the parser can write it without the catalog.
    var fixTitle: String? = nil
    var fixEdits: [TextEdit] = []

    var family: ForeignFamily { kind.family }
    var isComment: Bool {
        switch kind {
        case .rainmeterComment, .hashComment, .htmlComment: return true
        default: return false
        }
    }
}

/// Names of families in DK9015 ("this looks like a {language} file").
extension ForeignFamily {
    var languageName: LocalizedText {
        switch self {
        case .rainmeter: return LocalizedText("Rainmeter", "Rainmeter")
        case .swift: return LocalizedText("SwiftUI", "SwiftUI")
        case .html: return LocalizedText("HTML", "HTML")
        case .css: return LocalizedText("CSS", "CSS")
        case .other: return LocalizedText("another language", "其他语言")
        }
    }
}

extension Parser {
    // MARK: - Lines

    /// The end (exclusive token index) of the physical line that starts at token `j`.
    func physicalLineEnd(from j: Int) -> Int {
        var m = j + 1
        while m < limit && !nl(m) { m += 1 }
        return min(m, limit)
    }

    /// Extends a line's token range over the blocks it opens, so their `}` is never left over.
    func extendOverBlocks(_ start: Int, _ end: Int) -> Int {
        var stop = end
        var j = start
        while j < stop {
            if tokens[j].kind == .lBrace, let close = braces.closes[j] {
                switch close {
                case .token(let c) where c + 1 > stop:
                    stop = physicalLineEnd(from: min(c, limit - 1))
                    stop = max(stop, min(c + 1, limit))
                case .virtual(let v) where v > stop:
                    stop = min(v, limit)
                default:
                    break
                }
            }
            j += 1
        }
        return min(stop, limit)
    }

    /// The line's text from its first token to the end of its last token, for simple pattern tests.
    func lineText(_ start: Int, _ end: Int) -> String {
        guard start < end else { return "" }
        return String(decoding: bytes[starts[start]..<textEnd(end - 1)], as: UTF8.self)
    }

    // MARK: - Detection

    /// Whether the line at token `j` is foreign. Lines that can never be Desk (comments of other languages, INI
    /// sections, HTML tags, Swift declarations…) are matched before parsing; `Key=Value` and CSS declarations,
    /// which sometimes parse as Desk, only after the line failed to parse (`afterFailure`).
    func foreignMatch(at j: Int, firstInBlock: Bool, owner: BlockOwner?, afterFailure: Bool) -> ForeignLineMatch? {
        guard j < limit else { return nil }
        let lineEnd = physicalLineEnd(from: j)
        let first = tokens[j]
        switch first.kind {
        case .foreignRainmeterComment:
            return commentMatch(j, kind: .rainmeterComment, id: .semicolonComment, prefixLength: 1)
        case .foreignHashComment:
            return commentMatch(j, kind: .hashComment, id: .hashComment, prefixLength: 1)
        case .htmlComment:
            return htmlCommentMatch(j)
        case .lBracket:
            return iniSectionMatch(j, lineEnd)
        case .less, .lessSlash:
            guard isNameLike(j + 1), tokens[j].trailingTrivia.isEmpty, sameLine(j + 1) else { return nil }
            let end = extendOverBlocks(j, lineEnd)
            return ForeignLineMatch(kind: .htmlTag, start: j, end: end, diagnostic: .htmlTag, severity: .error,
                                    arguments: ["tag": .code(tokens[j + 1].text)])
        case .at:
            guard isNameLike(j + 1), sameLine(j + 1) else { return nil }
            if kind(j + 2) == .equal && sameLine(j + 2) {
                return ForeignLineMatch(kind: .rainmeterOption, start: j, end: lineEnd, diagnostic: .rainmeterOption,
                                        severity: .error, arguments: ["name": .code("@" + tokens[j + 1].text)])
            }
            return propertyWrapperMatch(j, lineEnd)
        case .hash:
            guard isNameLike(j + 1), (j..<lineEnd).contains(where: { tokens[$0].kind == .lBrace }) else { return nil }
            let end = extendOverBlocks(j, lineEnd)
            return ForeignLineMatch(kind: .cssSelector, start: j, end: end, diagnostic: .cssSelector, severity: .error,
                                    arguments: ["name": .code(tokens[j + 1].text)])
        case .ifKeyword:
            guard kind(j + 1) == .identifier, ["let", "var"].contains(tokens[j + 1].name), sameLine(j + 1) else { return nil }
            return ifLetMatch(j, lineEnd)
        case .identifier:
            if let match = swiftLineMatch(j, lineEnd) { return match }
            if firstInBlock, let match = closureParameterMatch(j, lineEnd, owner: owner) { return match }
            if afterFailure {
                if let match = iniOptionMatch(j, lineEnd, requireCapital: true) { return match }
                if let match = cssDeclarationMatch(j, lineEnd) { return match }
            }
            return nil
        default:
            return nil
        }
    }

    /// A line that continues a run of the given family: matched by pattern alone, even when it would parse as
    /// Desk (an INI `X=10` inside a pasted skin).
    func continuationMatch(at j: Int, family: ForeignFamily) -> ForeignLineMatch? {
        guard j < limit, nl(j) else { return nil }
        let lineEnd = physicalLineEnd(from: j)
        switch family {
        case .rainmeter:
            switch tokens[j].kind {
            case .foreignRainmeterComment:
                return commentMatch(j, kind: .rainmeterComment, id: .semicolonComment, prefixLength: 1)
            case .lBracket:
                return iniSectionMatch(j, lineEnd)
            case .at:
                guard isNameLike(j + 1), kind(j + 2) == .equal else { return nil }
                return ForeignLineMatch(kind: .rainmeterOption, start: j, end: lineEnd, diagnostic: .rainmeterOption,
                                        severity: .error, arguments: ["name": .code("@" + tokens[j + 1].text)])
            case .identifier:
                return iniOptionMatch(j, lineEnd, requireCapital: false)
            default:
                return nil
            }
        case .swift:
            guard kind(j) == .identifier || kind(j) == .at else { return nil }
            if kind(j) == .at { return foreignMatch(at: j, firstInBlock: false, owner: nil, afterFailure: false) }
            return swiftLineMatch(j, lineEnd)
        case .html:
            switch tokens[j].kind {
            case .less, .lessSlash:
                return foreignMatch(at: j, firstInBlock: false, owner: nil, afterFailure: false)
            case .htmlComment:
                return htmlCommentMatch(j)
            default:
                return nil
            }
        case .css:
            if kind(j) == .hash || kind(j) == .dot {
                guard isNameLike(j + 1), (j..<lineEnd).contains(where: { tokens[$0].kind == .lBrace }) else { return nil }
                let end = extendOverBlocks(j, lineEnd)
                return ForeignLineMatch(kind: .cssSelector, start: j, end: end, diagnostic: .cssSelector,
                                        severity: .error, arguments: ["name": .code(tokens[j + 1].text)])
            }
            return kind(j) == .identifier ? cssDeclarationMatch(j, lineEnd) : nil
        case .other:
            if kind(j) == .foreignHashComment {
                return commentMatch(j, kind: .hashComment, id: .hashComment, prefixLength: 1)
            }
            return nil
        }
    }

    // MARK: Comments

    /// `; note` (Rainmeter) and `# note`: still comments, reported as warnings with a fix-it to `//` (D2, D118).
    func commentMatch(_ j: Int, kind: ForeignKind, id: DiagnosticID, prefixLength: Int) -> ForeignLineMatch {
        let tokenText = tokens[j].text
        let body = String(tokenText.dropFirst(prefixLength)).trimmingCharacters(in: .whitespaces)
        let prefixRange = starts[j]..<(starts[j] + prefixLength)
        let lineEnd = physicalLineEnd(from: j)
        return ForeignLineMatch(kind: kind, start: j, end: lineEnd, diagnostic: id, severity: .warning,
                                arguments: ["text": .code(body)], fixTitle: "replaceWith",
                                fixEdits: [edit(prefixRange, "//")])
    }

    /// `<!-- note -->`: a comment written the HTML way (DK9014).
    func htmlCommentMatch(_ j: Int) -> ForeignLineMatch {
        let tokenText = tokens[j].text
        var fixEdits: [TextEdit] = []
        if !tokenText.contains("\n") && !tokenText.contains("\r") && tokenText.hasSuffix("-->") {
            let inner = tokenText.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
            fixEdits = [edit(textRange(j), "// " + inner)]
        }
        return ForeignLineMatch(kind: .htmlComment, start: j, end: physicalLineEnd(from: j), diagnostic: .hashComment,
                                severity: .warning, arguments: ["text": .code(tokenText)],
                                fixTitle: fixEdits.isEmpty ? nil : "replaceWith", fixEdits: fixEdits)
    }

    // MARK: Rainmeter

    /// `[Section]` (DK9302) or `[!Bang …]` (DK9304) at the start of a line.
    func iniSectionMatch(_ j: Int, _ lineEnd: Int) -> ForeignLineMatch? {
        // The line must hold a matching `]`.
        var close: Int?
        var depth = 0
        for m in j..<lineEnd {
            switch tokens[m].kind {
            case .lBracket: depth += 1
            case .rBracket:
                depth -= 1
                if depth == 0 && close == nil { close = m }
            default: break
            }
        }
        guard let closeIndex = close, closeIndex > j + 1 else { return nil }
        let inner = String(decoding: bytes[textEnd(j)..<starts[closeIndex]], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        if kind(j + 1) == .bang || kind(j + 1) == .bangEqual {
            let bang = inner.dropFirst().prefix { $0.isLetter || $0.isNumber }
            return ForeignLineMatch(kind: .rainmeterBang, start: j, end: lineEnd, diagnostic: .rainmeterBang,
                                    severity: .error, arguments: ["bang": .code(String(bang))])
        }
        // A section name is one word, possibly with spaces or dots (`[Meter CPU]`, `[Variables]`).
        guard inner.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic || ("0"..."9").contains($0)
            || $0 == " " || $0 == "_" || $0 == "." || $0 == "-" || $0 == "@" }) else { return nil }
        return ForeignLineMatch(kind: .rainmeterSection, start: j, end: lineEnd, diagnostic: .rainmeterSection,
                                severity: .error, arguments: ["name": .code(inner)])
    }

    /// `Key=Value` (DK9301). Outside a run, only a capitalised key after the line failed to parse: Desk's own
    /// names start with a small letter, and `FontColor = ColorPicker(…)` in `options` parses and is DK3016.
    func iniOptionMatch(_ j: Int, _ lineEnd: Int, requireCapital: Bool) -> ForeignLineMatch? {
        guard kind(j) == .identifier, kind(j + 1) == .equal, sameLine(j + 1) else { return nil }
        let key = tokens[j].name
        if requireCapital {
            guard let firstScalar = key.unicodeScalars.first, ("A"..."Z").contains(firstScalar) else { return nil }
        }
        let valueText = j + 2 < lineEnd ? lineText(j + 2, lineEnd) : ""
        return ForeignLineMatch(kind: .rainmeterOption, start: j, end: lineEnd, diagnostic: .rainmeterOption,
                                severity: .error, arguments: ["name": .code(key), "value": .code(valueText)])
    }

    // MARK: CSS

    /// `flex-direction: row;`, `font-size: 13px;` (DK9202): a property, a colon, a value, maybe a `;`.
    func cssDeclarationMatch(_ j: Int, _ lineEnd: Int) -> ForeignLineMatch? {
        var m = j
        var property = tokens[j].text
        var hyphenated = false
        m += 1
        while m + 1 < lineEnd, kind(m) == .minus, kind(m + 1) == .identifier,
              tokens[m].leadingTrivia.isEmpty, tokens[m - 1].trailingTrivia.isEmpty, tokens[m].trailingTrivia.isEmpty {
            property += "-" + tokens[m + 1].text
            hyphenated = true
            m += 2
        }
        guard m < lineEnd, kind(m) == .colon else { return nil }
        let endsWithSemicolon = lineEnd - 1 > m && kind(lineEnd - 1) == .semicolon
        guard hyphenated || endsWithSemicolon else { return nil }
        guard property.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || $0 == "-" }) else { return nil }
        return ForeignLineMatch(kind: .cssDeclaration, start: j, end: lineEnd, diagnostic: .cssDeclaration,
                                severity: .error, arguments: ["property": .code(property)])
    }

    // MARK: Swift and other languages

    /// Swift, JavaScript and Python statement patterns that are never Desk (§1.5 "diagnosed patterns").
    func swiftLineMatch(_ j: Int, _ lineEnd: Int) -> ForeignLineMatch? {
        guard kind(j) == .identifier else { return nil }
        let word = tokens[j].name
        let nextIsName = isNameLike(j + 1) && sameLine(j + 1)
        // `let = 3`, `state: 1`: own names that happen to be these words.
        if kind(j + 1) == .equal || kind(j + 1) == .colon || kind(j + 1) == .dot || kind(j + 1) == .lParen
            || kind(j + 1) == .plusEqual || kind(j + 1) == .minusEqual {
            return nil
        }
        switch word {
        case "let", "var", "const", "state":
            guard nextIsName else { return nil }
            if word == "var" && tokens[j + 1].name == "body" && kind(j + 2) == .colon {
                let end = extendOverBlocks(j, lineEnd)
                return ForeignLineMatch(kind: .swiftStructure, start: j, end: end, diagnostic: .swiftStructure,
                                        severity: .error)
            }
            guard kind(j + 2) == .equal || kind(j + 2) == .colon else { return nil }
            return swiftDeclarationMatch(j, lineEnd, keyword: word)
        case "struct", "class", "enum", "protocol", "extension":
            guard nextIsName else { return nil }
            let end = extendOverBlocks(j, lineEnd)
            return ForeignLineMatch(kind: .swiftStructure, start: j, end: end, diagnostic: .swiftStructure,
                                    severity: .error, arguments: ["keyword": .code(word)])
        case "import":
            guard nextIsName else { return nil }
            return ForeignLineMatch(kind: .swiftStructure, start: j, end: lineEnd, diagnostic: .swiftStructure,
                                    severity: .error, arguments: ["keyword": .code(word)], fixTitle: "remove",
                                    fixEdits: [edit(removalRange(j, lineEnd - 1), "")])
        case "export", "return":
            let end = extendOverBlocks(j, lineEnd)
            return ForeignLineMatch(kind: .swiftStructure, start: j, end: end, diagnostic: .swiftStructure,
                                    severity: .error, arguments: ["keyword": .code(word)])
        case "func", "def", "fn", "function":
            guard nextIsName else { return nil }
            let end = extendOverBlocks(j, lineEnd)
            return ForeignLineMatch(kind: .functionSyntax, start: j, end: end, diagnostic: .functionSyntax,
                                    severity: .error, arguments: ["keyword": .code(word)])
        case "while", "switch", "guard", "repeat":
            guard (j..<lineEnd).contains(where: { tokens[$0].kind == .lBrace }) || word == "guard" else { return nil }
            let end = extendOverBlocks(j, lineEnd)
            return ForeignLineMatch(kind: .functionSyntax, start: j, end: end, diagnostic: .functionSyntax,
                                    severity: .error, arguments: ["keyword": .code(word)])
        default:
            return nil
        }
    }

    /// `let x = 1` → `computed x = 1`, `var x = 0` → `variable x = 0` (DK9104), a type annotation removed.
    func swiftDeclarationMatch(_ j: Int, _ lineEnd: Int, keyword: String) -> ForeignLineMatch {
        let desk = (keyword == "let" || keyword == "const") ? "computed" : "variable"
        var edits = [edit(textRange(j), desk)]
        var annotationRange: Range<Int>?
        if kind(j + 2) == .colon {
            // `var x: Int = 0`: drop `: Int` when a simple type name is followed by `=`.
            var m = j + 3
            while m < lineEnd, kind(m) != .equal { m += 1 }
            if m < lineEnd {
                annotationRange = textEnd(j + 1)..<textEnd(m - 1)
                edits.append(edit(annotationRange!, ""))
            } else {
                edits = []
            }
        }
        var deskLine = desk + " " + tokens[j + 1].text
        if let valueStart = (j..<lineEnd).first(where: { kind($0) == .equal }), valueStart + 1 < lineEnd {
            deskLine += " = " + lineText(valueStart + 1, lineEnd)
        }
        return ForeignLineMatch(kind: .swiftDeclaration, start: j, end: extendOverBlocks(j, lineEnd),
                                diagnostic: .swiftDeclaration, severity: .error,
                                arguments: ["keyword": .code(keyword), "desk": .code(deskLine)],
                                fixTitle: edits.isEmpty ? nil : "replaceWith", fixEdits: edits)
    }

    /// `@State var page = 0` → `variable page = 0`; `@AppStorage("k") var x = ""` → `saved x = ""` (DK9103).
    func propertyWrapperMatch(_ j: Int, _ lineEnd: Int) -> ForeignLineMatch {
        let wrapper = tokens[j + 1].text
        var desk: String?
        switch wrapper {
        case "State", "StateObject", "ObservedObject": desk = "variable"
        case "AppStorage", "SceneStorage": desk = "saved"
        default: desk = nil
        }
        // Find `var` / `let` after the wrapper (and its arguments).
        var m = j + 2
        if kind(m) == .lParen {
            var depth = 0
            while m < lineEnd {
                if kind(m) == .lParen { depth += 1 }
                if kind(m) == .rParen { depth -= 1; if depth == 0 { m += 1; break } }
                m += 1
            }
        }
        var arguments: [String: DiagnosticArgument] = ["name": .code(wrapper)]
        var edits: [TextEdit] = []
        if let desk, m < lineEnd, kind(m) == .identifier, ["var", "let"].contains(tokens[m].name),
           isNameLike(m + 1) {
            edits = [edit(starts[j]..<textEnd(m), desk)]
            var deskLine = desk + " " + tokens[m + 1].text
            if let eq = (m..<lineEnd).first(where: { kind($0) == .equal }), eq + 1 < lineEnd {
                deskLine += " = " + lineText(eq + 1, lineEnd)
            }
            arguments["desk"] = .code(deskLine)
        }
        return ForeignLineMatch(kind: .swiftPropertyWrapper, start: j, end: extendOverBlocks(j, lineEnd),
                                diagnostic: .swiftPropertyWrapper, severity: .error, arguments: arguments,
                                fixTitle: edits.isEmpty ? nil : "replaceWith", fixEdits: edits)
    }

    /// `if let t = music.title { Text(t) }` → `if not music.title.isMissing { Text(music.title) }` (DK9110).
    func ifLetMatch(_ j: Int, _ lineEnd: Int) -> ForeignLineMatch? {
        let end = extendOverBlocks(j, lineEnd)
        guard isNameLike(j + 2), kind(j + 3) == .equal else {
            return ForeignLineMatch(kind: .swiftIfLet, start: j, end: end, diagnostic: .swiftIfLet, severity: .error)
        }
        let name = tokens[j + 2].text
        guard let brace = (j + 4..<lineEnd).first(where: { kind($0) == .lBrace }), brace > j + 4 else {
            return ForeignLineMatch(kind: .swiftIfLet, start: j, end: end, diagnostic: .swiftIfLet, severity: .error)
        }
        let valueText = text(j + 4, brace - 1)
        let isPath = (j + 4..<brace).allSatisfy { kind($0) == .identifier || kind($0) == .dot || kind($0).isKeyword }
        let fixed = "if not \(valueText).isMissing { … }"
        var edits: [TextEdit] = []
        if isPath {
            edits.append(edit(starts[j + 1]..<textEnd(brace - 1), "not \(valueText).isMissing"))
            var m = brace + 1
            while m < end {
                if kind(m) == .identifier, tokens[m].text == name, !(m > 0 && kind(m - 1) == .dot) {
                    edits.append(edit(textRange(m), valueText))
                }
                m += 1
            }
        }
        return ForeignLineMatch(kind: .swiftIfLet, start: j, end: end, diagnostic: .swiftIfLet, severity: .error,
                                arguments: ["fixed": .code(fixed)], fixTitle: edits.isEmpty ? nil : "rewrite",
                                fixEdits: edits)
    }

    /// `{ newValue in … }` at the start of a block (DK9111). After `.onChange(of: x)` the fix-it removes the
    /// parameters and uses `x` in their place.
    func closureParameterMatch(_ j: Int, _ lineEnd: Int, owner: BlockOwner?) -> ForeignLineMatch? {
        var m = j
        var names: [String] = []
        while m < lineEnd, kind(m) == .identifier {
            names.append(tokens[m].text)
            m += 1
            if kind(m) == .comma { m += 1 } else { break }
        }
        guard !names.isEmpty, m < lineEnd, kind(m) == .inKeyword else { return nil }
        let end = m + 1
        var arguments: [String: DiagnosticArgument] = ["name": .code(names.joined(separator: ", "))]
        var edits: [TextEdit] = []
        if let owner, owner.modifierName == "onChange", let of = owner.ofArgument, names.count == 1 {
            let value = text(of.lowerBound, of.upperBound)
            arguments["value"] = .code(value)
            // Remove `name in` (and the blank after it), then use the value for the name in the block.
            let removeEnd = end < tokens.count && sameLine(end) ? starts[end] : textEnd(m)
            edits.append(edit(starts[j]..<removeEnd, ""))
            var k = end
            while k < limit {
                if kind(k) == .identifier, tokens[k].text == names[0], !(kind(k - 1) == .dot) {
                    edits.append(edit(textRange(k), value))
                }
                k += 1
            }
        }
        return ForeignLineMatch(kind: .closureParameter, start: j, end: end, diagnostic: .closureParameter,
                                severity: .error, arguments: arguments,
                                fixTitle: edits.isEmpty ? nil : "removeClosureParameter", fixEdits: edits)
    }

    // MARK: - Runs

    /// Wraps the matched line, and the following lines of the same family, in one `foreignConstruct` node with one
    /// diagnostic whose per-line fix-its form one "Fix all" group. Past the first 20 foreign lines of the file, a
    /// single DK9015 stands for the rest and runs get no diagnostics of their own.
    mutating func consumeForeignRun(_ first: ForeignLineMatch) -> SyntaxNode {
        var matches = [first]
        var children: [SyntaxChild] = []
        while i < first.end { children.append(take()) }
        // A closure parameter list never merges with what follows it.
        if first.kind != .closureParameter {
            while i < limit, let next = continuationMatch(at: i, family: first.family), next.end > i {
                matches.append(next)
                while i < next.end { children.append(take()) }
            }
        }
        let firstToken = first.start
        let lastToken = i - 1
        // Count the lines of the run that hold tokens.
        var lineIndexes: [Int] = []
        var previousLine = -1
        for j in firstToken...lastToken {
            let line = lineIndex(ofToken: j)
            if line != previousLine { lineIndexes.append(line); previousLine = line }
        }
        let countBefore = foreignLineCount
        foreignLineCount += lineIndexes.count
        foreignRunRanges.append(starts[firstToken]..<textEnd(lastToken))
        let lead = matches.first(where: { !$0.isComment }) ?? matches[0]
        if countBefore < SyntaxLimits.foreignLinesBeforeSummary {
            let group = "foreign-\(starts[firstToken])"
            var fixIts: [FixIt] = []
            for match in matches where !match.fixEdits.isEmpty {
                var arguments: [String: DiagnosticArgument] = [:]
                if match.fixTitle == "replaceWith", match.fixEdits.count == 1 {
                    arguments["text"] = .code(match.fixEdits[0].replacement)
                }
                fixIts.append(FixIt(titleKey: match.fixTitle ?? "rewrite", titleArguments: arguments,
                                    edits: match.fixEdits, group: matches.count > 1 ? group : nil))
            }
            let severity: Severity = matches.allSatisfy(\.isComment) ? .warning : lead.severity
            report(lead.diagnostic, severity, starts[firstToken]..<textEnd(lastToken), lead.arguments,
                   fixIts: fixIts)
        }
        if foreignLineCount > SyntaxLimits.foreignLinesBeforeSummary && !foreignFileReported {
            foreignFileReported = true
            // At the first foreign line past the 20th.
            let offset = max(0, SyntaxLimits.foreignLinesBeforeSummary - countBefore)
            let line = lineIndexes[min(offset, lineIndexes.count - 1)]
            let range = lines.starts[line]..<lines.contentEnd(ofLine: line)
            var arguments: [String: DiagnosticArgument] = ["language": .text(first.family.languageName)]
            if first.family == .rainmeter {
                arguments["hint"] = .text(LocalizedText(
                    "Install it as a Rainmeter skin, or open it with the converter.",
                    "请把它当作 Rainmeter 皮肤安装，或者用转换器打开。"))
            }
            report(.foreignFile, .error, range, arguments)
        }
        return SyntaxNode(kind: .foreignConstruct, children: children, foreignKind: lead.kind)
    }
}
