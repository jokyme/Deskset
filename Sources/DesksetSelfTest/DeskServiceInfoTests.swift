import Foundation
@testable import DeskLanguage

// Semantic tokens, hover cards and signature help of the language service. Properties on every file of the corpus
// and every catalog example, golden results on the acceptance widgets and small snippets.
//
// `DESK_TOKENS_DUMP=path/to/file.desk` prints the semantic tokens of a file (to write goldens).

/// `line:column text type[modifiers]` for each token (1-based).
func deskTokenLines(_ snapshot: DeskSnapshot, _ tokens: [DeskSemanticToken]) -> [String] {
    let text = snapshot.text as NSString
    return tokens.map { token in
        let covered = token.range.end.offset <= text.length ? text.substring(with: token.range.nsRange) : "?"
        return "\(token.range.start) \(covered) \(token.type)" + (token.modifiers.isEmpty ? "" : "[\(token.modifiers)]")
    }
}

func runDeskServiceInfoTests(_ t: TestRunner) {
    if let path = ProcessInfo.processInfo.environment["DESK_TOKENS_DUMP"] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); return }
        let snapshot = deskNavService(text, file: (path as NSString).lastPathComponent).snapshot
        for line in deskTokenLines(snapshot, snapshot.semanticTokens().tokens) { print(line) }
        return
    }
    if ProcessInfo.processInfo.environment["DESK_CATALOG_LEAKS"] != nil {
        for line in deskCatalogProseLeaks() { print(line) }
        return
    }
    if let path = ProcessInfo.processInfo.environment["DESK_HOVER_DUMP"] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); return }
        let language: DiagnosticLanguage = ProcessInfo.processInfo.environment["DESK_HOVER_ZH"] != nil ? .simplifiedChinese : .english
        let snapshot = deskNavService(text, file: (path as NSString).lastPathComponent).snapshot
        var seen = Set<DeskRange>()
        for token in deskNavTokenStarts(snapshot.tree) {
            let position = snapshot.index.position(utf8: token.lowerBound)
            if let hover = snapshot.hover(at: position), seen.insert(hover.range).inserted {
                print("=== \(position)")
                print(hover.markdown(language))
            }
            if let help = snapshot.signatureHelp(at: position) {
                print("--- signature help at \(position): active \(help.activeSignature) parameter \(help.activeParameter.map(String.init) ?? "none")")
                print(help.markdown(language))
            }
        }
        return
    }
    runDeskSemanticTokenTests(t)
    runDeskHoverTests(t)
    runDeskSignatureHelpTests(t)
    runDeskSignatureHelpGoldens(t)
    runDeskServiceInfoLatency(t)
}

/// A service for one harness text (every catalog example is checked in one).
func deskInfoHarnessSnapshot(_ text: String) -> DeskSnapshot {
    DeskLanguageService(openFile: DeskFileID(path: "Harness.desk"), files: [DeskFileID(path: "Harness.desk"): text],
                        resources: DeskFakeResources()).snapshot
}

/// The problems of one file's semantic tokens: out of order, overlapping, outside the text, a lexical token only
/// partly covered or covered by pieces with gaps, a token that is not inside one lexical token or comment, and an
/// encoding that does not decode back to the tokens.
func deskSemanticTokenProblems(_ snapshot: DeskSnapshot, _ result: DeskSemanticTokens) -> [String] {
    var problems: [String] = []
    let tokens = result.tokens
    let length = snapshot.index.utf16Count
    for (k, token) in tokens.enumerated() {
        if token.range.isEmpty { problems.append("empty \(token)") }
        if token.range.end.offset > length { problems.append("outside \(token)") }
        if k > 0, tokens[k - 1].range.end.offset > token.range.start.offset { problems.append("overlap \(tokens[k - 1]) \(token)") }
    }
    // Lexical tokens and comments, in UTF-16.
    var pieces: [(range: Range<Int>, kind: TokenKind?, text: String)] = []
    snapshot.tree.root.walkTokens { token, at in
        var offset = at
        for trivia in token.leadingTrivia {
            if trivia.isComment { pieces.append((snapshot.index.utf16Range(ofUTF8: offset..<(offset + trivia.utf8Length)), nil, trivia.text)) }
            offset += trivia.utf8Length
        }
        if !token.isMissing, !token.text.isEmpty, token.kind != .eof {
            pieces.append((snapshot.index.utf16Range(ofUTF8: offset..<(offset + token.text.utf8.count)), token.kind, token.text))
        }
        offset += token.text.utf8.count
        for trivia in token.trailingTrivia {
            if trivia.isComment { pieces.append((snapshot.index.utf16Range(ofUTF8: offset..<(offset + trivia.utf8Length)), nil, trivia.text)) }
            offset += trivia.utf8Length
        }
        return true
    }
    var t = 0
    for piece in pieces {
        while t < tokens.count, tokens[t].range.end.offset <= piece.range.lowerBound {
            problems.append("token outside any lexical token: \(tokens[t])")
            t += 1
        }
        var covering: [DeskSemanticToken] = []
        while t < tokens.count, tokens[t].range.start.offset < piece.range.upperBound {
            covering.append(tokens[t])
            t += 1
        }
        if covering.isEmpty {
            let punctuation: Bool = {
                guard let kind = piece.kind else { return false }
                switch kind {
                case .lParen, .rParen, .lBrace, .rBrace, .lBracket, .rBracket, .comma, .colon, .semicolon, .dot, .ellipsis,
                     .equal, .equalEqual, .bangEqual, .less, .lessEqual, .greater, .greaterEqual, .plus, .minus, .star,
                     .slash, .percent, .question:
                    return true
                default:
                    return false
                }
            }()
            if !punctuation { problems.append("not covered: \(piece.kind.map(\.rawValue) ?? "comment") \(piece.text.prefix(30))") }
            continue
        }
        var reached = piece.range.lowerBound
        for token in covering {
            if token.range.start.offset != reached || token.range.end.offset > piece.range.upperBound {
                problems.append("\(piece.kind.map(\.rawValue) ?? "comment") \(piece.text.prefix(30)) covered by \(covering)")
                break
            }
            reached = token.range.end.offset
        }
        if reached != piece.range.upperBound, !problems.last!.contains("covered by") {
            problems.append("\(piece.kind.map(\.rawValue) ?? "comment") \(piece.text.prefix(30)) partly covered by \(covering)")
        }
        if piece.kind == nil, covering.contains(where: { $0.type != .comment }) { problems.append("comment typed \(covering)") }
    }
    while t < tokens.count {
        problems.append("token outside any lexical token: \(tokens[t])")
        t += 1
    }
    // The encoding decodes to the tokens, split at line breaks.
    var decoded: [(line: Int, column: Int, length: Int, type: Int, modifiers: UInt32)] = []
    var line = 0
    var column = 0
    var k = 0
    while k + 4 < result.data.count {
        let d = result.data
        line += Int(d[k])
        column = d[k] == 0 ? column + Int(d[k + 1]) : Int(d[k + 1])
        decoded.append((line, column, Int(d[k + 2]), Int(d[k + 3]), d[k + 4]))
        k += 5
    }
    var expected: [(line: Int, column: Int, length: Int, type: Int, modifiers: UInt32)] = []
    for token in tokens {
        for l in token.range.start.line...token.range.end.line {
            let content = snapshot.index.utf16ContentRange(ofLine: l)
            let from = max(content.lowerBound, token.range.start.offset)
            let to = min(content.upperBound, token.range.end.offset)
            guard from < to else { continue }
            let position = snapshot.index.position(utf16: from)
            expected.append((position.line, position.column, to - from, token.type.rawValue, token.modifiers.rawValue))
        }
    }
    if decoded.count != expected.count || zip(decoded, expected).contains(where: { $0 != $1 }) {
        problems.append("the encoding decodes to \(decoded.count) pieces, expected \(expected.count)")
    }
    return problems
}

func runDeskSemanticTokenTests(_ t: TestRunner) {
    t.suite("Desk: service — semantic tokens, every file") {
        var files = 0
        var tokens = 0
        var ranges = 0
        for (label, file, texts) in deskNavSweepTexts() {
            var folder: [DeskFileID: String] = [:]
            for (path, text) in texts { folder[DeskFileID(path: path)] = text }
            let snapshot = DeskLanguageService(openFile: DeskFileID(path: file), files: folder).snapshot
            // A range request before the whole file is classified, then the whole file.
            let length = snapshot.index.utf16Count
            let early = snapshot.semanticTokens(in: snapshot.index.range(utf16: (length / 3)..<(2 * length / 3)))
            let all = snapshot.semanticTokens()
            files += 1
            tokens += all.tokens.count
            for problem in deskSemanticTokenProblems(snapshot, all).prefix(5) { t.check(false, "\(label): \(problem)") }
            // Range requests equal the whole result filtered to the range.
            func filtered(_ range: DeskRange) -> [DeskSemanticToken] {
                let upper = max(range.end.offset, range.start.offset + 1)
                return all.tokens.filter { $0.range.end.offset > range.start.offset && $0.range.start.offset < upper }
            }
            var requests = [snapshot.index.range(utf16: (length / 3)..<(2 * length / 3))]
            for line in stride(from: 0, to: snapshot.index.lineCount, by: max(1, snapshot.index.lineCount / 7)) {
                requests.append(snapshot.index.range(utf16: snapshot.index.utf16Range(ofLine: line)))
            }
            requests.append(snapshot.index.range(utf16: 0..<length))
            requests.append(snapshot.index.range(utf16: (length / 2)..<(length / 2)))
            t.equal(early.tokens, filtered(requests[0]), "\(label): a range before the whole file")
            // A fresh snapshot of the same text answers from its blocks alone.
            let fresh = DeskLanguageService(openFile: DeskFileID(path: file), files: folder).snapshot
            for range in requests {
                ranges += 1
                let part = fresh.semanticTokens(in: range)
                if part.tokens != filtered(range) { t.check(false, "\(label): range \(range) differs") }
                if snapshot.semanticTokens(in: range).tokens != filtered(range) { t.check(false, "\(label): cached range \(range) differs") }
            }
        }
        print("    \(tokens) semantic tokens in \(files) files, \(ranges) range requests")
    }

    t.suite("Desk: service — semantic tokens, every catalog example") {
        let harness = DeskExampleHarness(catalog: .current)
        var examples = 0
        for item in DeskCatalog.current.documentedItems() where !item.doc.example.isEmpty {
            examples += 1
            let built = harness.build(item.doc.example, context: item.doc.exampleContext)
            let snapshot = deskInfoHarnessSnapshot(built.text)
            let range = snapshot.index.range(utf8: built.exampleRange)
            let tokens = snapshot.semanticTokens(in: range).tokens.filter {
                $0.range.start.offset >= range.start.offset && $0.range.end.offset <= range.end.offset
            }
            let invalid = tokens.filter { $0.type == .invalid || $0.type == .foreign }
            if !invalid.isEmpty { t.check(false, "\(item.path): \(deskTokenLines(snapshot, invalid))") }
            for problem in deskSemanticTokenProblems(snapshot, snapshot.semanticTokens()).prefix(3) { t.check(false, "\(item.path): \(problem)") }
        }
        t.check(examples > 400, "examples: \(examples)")
    }

    t.suite("Desk: service — semantic tokens, every type and modifier") {
        let text = """
        info {
            name: "Tokens"
            permissions: [.music]
        }

        options {
            theme = Picker("Theme", [.light, .dark])
            unusedOption = Toggle("Never read")
        }

        widget {
            variable page = 0
            saved note = ""
            computed month = calendar.month(offset: page)
            // A comment
            Column {
                Text("{cpu.usage, digits: 1}% {note}").name(title)
                    .onClick { page = page + 1; music.play(); show(title) }
                    .onScroll { if event.direction == .up { page = 0 } }
                for day in month.days { Text("{day.number}").style(card) }
                Progress(memory.used, total: memory.total).every(500ms) { page = round(page) }
                Rectangle().size(20).background(.glass).hidden(if: options.theme == .dark)
                Text("x").hidden(if: page > 0 && page < 2)
                Text(#Var#)
                Text("é").width(12px)
            }
        }

        style card { .font(.caption) }

        translations {
            "zh-Hans" { "Tokens": "记号" }
        }
        """
        let snapshot = deskNavService(text).snapshot
        let lines = deskTokenLines(snapshot, snapshot.semanticTokens().tokens)
        let seen = Set(snapshot.semanticTokens().tokens.map(\.type))
        for type in DeskSemanticTokenType.allCases {
            t.check(seen.contains(type), "no \(type) token in \(lines)")
        }
        let modifiers = snapshot.semanticTokens().tokens.reduce(DeskSemanticTokenModifiers()) { $0.union($1.modifiers) }
        for modifier in [DeskSemanticTokenModifiers.declaration, .write, .unused, .macOnly] {
            t.check(modifiers.contains(modifier), "no \(modifier) modifier")
        }
        if ProcessInfo.processInfo.environment["DESK_TOKENS_PRINT"] != nil { print(lines.joined(separator: "\n")) }
        func expect(_ line: String) { t.check(lines.contains(line), "expected \(line)") }
        for line in ["1:1 info blockWord", "2:5 name field", "3:20 music enumCase", "7:5 theme option[declaration]",
                     "7:13 Picker control", "8:5 unusedOption option[declaration,unused]", "12:5 variable keyword",
                     "12:14 page variable[declaration]", "13:11 note saved[declaration]", "14:14 month computed[declaration]",
                     "14:22 calendar namespace", "14:31 month function", "14:37 offset label", "15:5 // A comment comment",
                     "16:5 Column component", "17:15 { interpolation", "17:16 cpu namespace", "17:20 usage dataMember",
                     "17:27 digits formatOption", "17:35 1 number", "17:37 %  string", "17:40 note saved",
                     "17:48 name modifier", "17:53 title elementName[declaration]", "18:24 page variable[write]",
                     "18:41 music namespace", "18:47 play action", "18:55 show action", "18:60 title elementName",
                     "19:28 event event", "19:34 direction dataMember", "19:48 up enumCase", "20:13 day loopVariable[declaration]",
                     "20:40 day loopVariable", "20:44 number dataMember", "20:60 card style", "21:58 500 number",
                     "21:61 ms unit", "21:74 round function", "22:30 background modifier[macOnly]",
                     "22:42 glass enumCase[macOnly]", "22:56 if label", "22:68 theme option", "23:39 && foreign",
                     "24:14 #Var# foreign", "25:25 12 number", "25:27 px invalid", "29:1 style blockWord",
                     "29:7 card style[declaration]", "32:6 zh-Hans string", "32:17 \" translationKey",
                     "32:18 Tokens translationKey", "32:28 记号 string"] {
            expect(line)
        }

        // A name the catalog is replacing is marked.
        var catalog = DeskCatalog.current
        if let k = catalog.modifiers.firstIndex(where: { $0.name == "caption" || $0.name == "font" }) {
            catalog.modifiers[k].doc.deprecated = Deprecation(since: AppVersion(major: 1, minor: 1), replacement: ".text")
        }
        let replaced = DeskLanguageService(openFile: DeskFileID(path: "Test.desk"), files: [DeskFileID(path: "Test.desk"): text],
                                           options: DeskServiceOptions(catalog: catalog)).snapshot
        t.check(deskTokenLines(replaced, replaced.semanticTokens().tokens).contains("29:15 font modifier[deprecated]"), "deprecated")
        // Tokens in the middle of a multi-line comment are split per line in the encoding.
        let comment = deskNavService("/* one\n   two */\nwidget { Text(\"A\") }").snapshot
        let tokens = comment.semanticTokens()
        t.equal(tokens.tokens.first?.type, .comment)
        t.equal(Array(tokens.data.prefix(10)), [0, 0, 6, UInt32(DeskSemanticTokenType.comment.rawValue), 0,
                                                1, 0, 9, UInt32(DeskSemanticTokenType.comment.rawValue), 0])
        t.equal(DeskSemanticTokenLegend.tokenTypes.count, DeskSemanticTokenType.allCases.count)
        t.equal(DeskSemanticTokenLegend.tokenTypes[DeskSemanticTokenType.translationKey.rawValue], "translationKey")
        t.equal(DeskSemanticTokenLegend.tokenModifiers, ["declaration", "write", "deprecated", "unused", "macOnly"])
    }
}

/// The UTF-8 offsets in `text` (from `range`) where `needle` starts as a whole word: not after a letter, digit or
/// `_`, and not followed by one.
func deskWordStarts(_ needle: String, in text: String, range: Range<Int>) -> [Int] {
    let bytes = Array(text.utf8)
    let n = Array(needle.utf8)
    guard !n.isEmpty else { return [] }
    func isWord(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F }
    var out: [Int] = []
    var i = range.lowerBound
    while i + n.count <= min(range.upperBound, bytes.count) {
        if Array(bytes[i..<(i + n.count)]) == n,
           i == 0 || !isWord(bytes[i - 1]) || !isWord(n[0]),
           i + n.count >= bytes.count || !isWord(bytes[i + n.count]) || !isWord(n[n.count - 1]) {
            out.append(i)
        }
        i += 1
    }
    return out
}

/// Where a catalog item's name is written in its example (UTF-8 offsets of the name itself); every name-like word
/// for the items whose name is not written (an enum, a record).
func deskItemNameStarts(_ path: CatalogPath, in text: String, range: Range<Int>) -> [Int] {
    func after(_ prefix: String, _ name: String) -> [Int] {
        deskWordStarts(prefix + name, in: text, range: range).map { $0 + prefix.utf8.count }
    }
    switch path {
    case .component(let n), .control(let n), .function(let n): return deskWordStarts(n, in: text, range: range)
    case .modifier(let n), .recordField(_, let n), .typeMember(_, let n), .namedValue(_, let n), .permission(let n),
         .feature(let n):
        return after(".", n)
    case .namespace(let n):
        return deskWordStarts(n, in: text, range: range).filter { $0 == 0 || Array(text.utf8)[$0 - 1] != UInt8(ascii: ".") }
            .map { $0 + (n.split(separator: ".").dropLast().map { $0.utf8.count + 1 }.reduce(0, +)) }
    case .member(let ns, let n): return after(ns + ".", n)
    case .infoField(let n), .packageField(let n): return deskWordStarts(n + ":", in: text, range: range)
    case .formatOption(let l): return deskWordStarts(l + ":", in: text, range: range)
    case .enumCase(_, let n): return after(".", n)
    case .enumeration, .record:
        var starts: [Int] = []
        let bytes = Array(text.utf8)
        var i = range.lowerBound
        while i < range.upperBound {
            let b = bytes[i]
            let isStart = ((b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)) && (i == 0 || !((bytes[i - 1] >= 0x30 && bytes[i - 1] <= 0x39) || (bytes[i - 1] >= 0x41 && bytes[i - 1] <= 0x5A) || (bytes[i - 1] >= 0x61 && bytes[i - 1] <= 0x7A)))
            if isStart { starts.append(i) }
            i += 1
        }
        return starts
    }
}

func runDeskHoverTests(_ t: TestRunner) {
    t.suite("Desk: service — hover, every catalog example") {
        let harness = DeskExampleHarness(catalog: .current)
        var examples = 0
        var hovers = 0
        for item in DeskCatalog.current.documentedItems() where !item.doc.example.isEmpty {
            examples += 1
            let built = harness.build(item.doc.example, context: item.doc.exampleContext)
            let snapshot = deskInfoHarnessSnapshot(built.text)
            let starts = deskItemNameStarts(item.path, in: built.text, range: built.exampleRange)
            var found = false
            var seen: [String] = []
            for start in starts {
                guard let hover = snapshot.hover(at: snapshot.index.position(utf8: start)) else { continue }
                hovers += 1
                if hover.paragraphs.contains(item.doc.text) { found = true; break }
                seen.append(hover.title.en)
            }
            if !found { t.check(false, "\(item.path): \(item.doc.example) — \(starts.count) places, hovers \(seen)") }
        }
        t.check(examples > 400, "examples: \(examples)")
        print("    \(examples) examples, \(hovers) hovers")
    }

    t.suite("Desk: service — hover goldens: own names, options, styles, units, enum cases") {
        let snapshot = deskNavService(deskHoverGoldenText).snapshot
        let chinese = deskNavService(deskHoverGoldenText, language: .simplifiedChinese).snapshot
        let print = ProcessInfo.processInfo.environment["DESK_GOLDEN_PRINT"] != nil
        for (needle, occurrence, expected) in deskHoverGoldens {
            let position = deskNavPosition(snapshot, needle, occurrence: occurrence)
            guard let hover = snapshot.hover(at: position) else {
                t.check(false, "no hover at \(needle) #\(occurrence)")
                continue
            }
            let markdown = hover.markdown(.english)
            if print { Swift.print("(\"\(needle)\", \(occurrence), \"\"\"\n\(markdown)\"\"\"),") }
            t.equal(markdown, expected + "\n", "\(needle) #\(occurrence)")
            // The same card in Chinese: other words, the same code, no leaks.
            let zh = chinese.hover(at: position)
            t.equal(zh, hover, "a card does not depend on the service's language")
            let zhMarkdown = hover.markdown(.simplifiedChinese)
            t.check(zhMarkdown != markdown && zhMarkdown.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF },
                    "\(needle): Chinese card")
            for text in hover.prose(.english) + hover.prose(.simplifiedChinese) { t.equal(deskMessageLeaks(text), [], text) }
        }
    }

    t.suite("Desk: service — hover and signature help, every name of every file") {
        var positions = 0
        var hovers = 0
        var helps = 0
        var leaks: [String: Int] = [:]
        func leakCheck(_ texts: [String], _ what: String) {
            for text in texts {
                for leak in deskMessageLeaks(text) where leaks[what + " " + leak, default: 0] < 3 {
                    leaks[what + " " + leak, default: 0] += 1
                    t.check(false, "\(what) leaks \(leak): \(text)")
                }
            }
        }
        for (label, file, texts) in deskNavSweepTexts() {
            var folder: [DeskFileID: String] = [:]
            for (path, text) in texts { folder[DeskFileID(path: path)] = text }
            let snapshot = DeskLanguageService(openFile: DeskFileID(path: file), files: folder).snapshot
            let length = snapshot.index.utf16Count
            var offsets = Set([0, length])
            for token in deskNavTokenStarts(snapshot.tree) {
                offsets.insert(snapshot.index.utf16Offset(ofUTF8: token.lowerBound))
                offsets.insert(snapshot.index.utf16Offset(ofUTF8: token.upperBound))
            }
            for offset in offsets.sorted() {
                positions += 1
                let position = snapshot.index.position(utf16: offset)
                if let hover = snapshot.hover(at: position) {
                    hovers += 1
                    if hover.range.end.offset > length || !hover.range.contains(offset) && hover.range.end.offset != offset {
                        t.check(false, "\(label): hover at \(position) covers \(hover.range)")
                    }
                    for language in DiagnosticLanguage.allCases {
                        leakCheck(hover.prose(language), "hover")
                        if hover.markdown(language).isEmpty { t.check(false, "\(label): empty hover") }
                    }
                }
                if let help = snapshot.signatureHelp(at: position) {
                    helps += 1
                    if help.range.end.offset > length { t.check(false, "\(label): signature help range \(help.range)") }
                    if !help.signatures.indices.contains(help.activeSignature) { t.check(false, "\(label): active signature") }
                    if let p = help.activeParameter, !help.signatures[help.activeSignature].parameters.indices.contains(p) {
                        t.check(false, "\(label): active parameter \(p)")
                    }
                    for language in DiagnosticLanguage.allCases {
                        var prose = [help.title.text(in: language), help.doc?.text(in: language) ?? ""]
                        for signature in help.signatures {
                            for p in signature.parameters {
                                prose += [p.type.text(in: language), p.doc.text(in: language), p.defaultValue?.text(in: language) ?? ""]
                            }
                        }
                        leakCheck(prose, "signature help")
                    }
                }
            }
        }
        print("    \(positions) positions: \(hovers) hovers, \(helps) signature helps")
    }
}

func deskCatalogProseLeaks() -> [String] {
    var out: [String] = []
    func check(_ place: String, _ text: String) {
        let leaks = deskMessageLeaks(text)
        if !leaks.isEmpty { out.append("\(place): \(leaks) \(text)") }
    }
    let catalog = DeskCatalog.current
    for item in catalog.documentedItems() {
        check("\(item.path) doc", item.doc.en); check("\(item.path) doc zh", item.doc.zh)
        if let title = item.title { check("\(item.path) title", title.en); check("\(item.path) title zh", title.zh) }
    }
    for p in catalog.allParameters() { check(p.place, p.value.doc.en); check(p.place + " zh", p.value.doc.zh) }
    for d in catalog.displayNames { check(d.id, d.name.en); check(d.id + " zh", d.name.zh) }
    for f in catalog.facets { check("facet \(f.id)", f.displayName.en); check("facet \(f.id) zh", f.displayName.zh) }
    for e in catalog.enums { for c in e.cases { if let t = c.title { check("\(e.id).\(c.name)", t.en); check("\(e.id).\(c.name) zh", t.zh) } } }
    for p in catalog.permissions { check("permission \(p.id)", p.needsPhrase.en); check("permission \(p.id) zh", p.needsPhrase.zh) }
    return out
}

func runDeskSignatureHelpTests(_ t: TestRunner) {
    t.suite("Desk: service — signature help, every argument of every catalog example") {
        let harness = DeskExampleHarness(catalog: .current)
        var arguments = 0
        var options = 0
        for item in DeskCatalog.current.documentedItems() where !item.doc.example.isEmpty {
            let built = harness.build(item.doc.example, context: item.doc.exampleContext)
            let snapshot = deskInfoHarnessSnapshot(built.text)
            let table = snapshot.nodeTable
            for (i, entry) in table.entries.enumerated() where built.exampleRange.contains(entry.textStart) {
                guard entry.kind == .argument || entry.kind == .formatOption, entry.textEnd > entry.textStart else { continue }
                let label = table.children(of: i).first { table.entries[$0].kind == .label }
                    .flatMap { table.entries[$0].positioned.childTokens.first?.token.name }
                // At the argument's start (a format option: after its comma), in its value and at its end.
                let start = entry.kind == .formatOption ? entry.textStart + 1 : entry.textStart
                let value = table.children(of: i).last { table.entries[$0].kind != .label }
                var offsets = [start, entry.textEnd]
                if let value { offsets.append(table.entries[value].textStart) }
                for offset in offsets {
                    let position = snapshot.index.position(utf8: offset)
                    guard let help = snapshot.signatureHelp(at: position) else {
                        t.check(false, "\(item.path): no signature help at \(position) in \(item.doc.example)")
                        continue
                    }
                    let signature = help.signatures[help.activeSignature]
                    guard let p = help.activeParameter, signature.parameters.indices.contains(p) else {
                        t.check(false, "\(item.path): no active parameter at \(position) in \(item.doc.example) (\(signature.label))")
                        continue
                    }
                    if let label {
                        t.equal(signature.parameters[p].label, label, "\(item.path): \(item.doc.example) at \(position)")
                    } else if entry.kind == .argument, signature.parameters[p].label != nil {
                        t.check(false, "\(item.path): positional argument at \(position) gets \(signature.parameters[p].label!): in \(item.doc.example) (\(signature.label))")
                    }
                    let range = signature.parameters[p].labelRange
                    t.check(range.upperBound <= signature.label.utf16.count && !range.isEmpty, "label range \(range) of \(signature.label)")
                }
                if entry.kind == .argument { arguments += 1 } else { options += 1 }
            }
        }
        t.check(arguments > 300, "arguments: \(arguments)")
        t.check(options > 10, "format options: \(options)")
        print("    \(arguments) arguments and \(options) format options of the catalog examples")
    }
}

let deskHoverGoldenText = """
options {
    look = Picker("Look", [.mono, .full], default: .mono)
    city = Input("City", default: "Oslo")
}

widget {
    variable page = 0
    saved seconds = 90s
    computed free = memory.free
    Column {
        Text("{free}").name(title).font(.headline).style(card)
        Text("{memory.used}").hidden(if: memory.free < 2GB).every(500ms) { page = page + 1 }
        Progress(disk.used, total: 500GB)
        for day in calendar.month(offset: page).days { Text("{day.number}") }
        Text("Low").color(.red, if: options.look == .full).onClick { show(title) }
    }
}

style card { .font(13, .semibold).color(.white).padding(4).hover { .color(.accent) } }

translations {
    "zh-Hans" { "Low": "低" }
}
"""

/// (needle, occurrence, expected English Markdown).
let deskHoverGoldens: [(String, Int, String)] = [
("look", 1, """
**Option `look`**

```desk
look = Picker("Look", [.mono, .full], default: .mono)
```

An option: a setting people change in the widget's Options panel.

- Control: Choice (`Picker`)
- Label: “Look”
- Type: one of `.mono`, `.full`
- Default: `.mono`

[Reference](#control-picker)
"""),
("city", 1, """
**Option `city`**

```desk
city = Input("City", default: "Oslo")
```

An option: a setting people change in the widget's Options panel.

- Control: Text (`Input`)
- Label: “City”
- Type: text in quotes
- Default: `"Oslo"`

[Reference](#control-input)
"""),
("page", 1, """
**Variable `page`**

```desk
variable page = 0
```

A value the widget keeps while it runs; actions can change it.

- Type: a number
- Starts at: `0`
"""),
("seconds", 1, """
**Saved value `seconds`**

```desk
saved seconds = 90s
```

A value the widget keeps even when it restarts; actions can change it.

- Type: a time, such as `2s` or `500ms`
- Starts at: `90s`
"""),
("free", 1, """
**Computed value `free`**

```desk
computed free = memory.free
```

A value worked out from others; it changes when they do.

- Type: an amount of data, such as `2GB`, counted in 1024s
"""),
("title", 1, """
**Element name `title`**

```desk
Text("{free}").name(title).font(.headline).style(card)
```

The name of an element: actions such as `show(…)` and positions refer to the element by it.

- Component: Text (`Text`)

[Reference](#component-text)
"""),
("day", 1, """
**Loop variable `day`**

```desk
for day in calendar.month(offset: page).days { Text("{day.number}") }
```

Each item of the list this `for` goes through, in turn.

A day of a month

- Each item: a day of a month
"""),
("card", 1, """
**Style `card`**

```desk
style card { .font(13, .semibold).color(.white).padding(4).hover { .color(.accent) } }
```

A style: modifiers that elements take with `.style(…)`.

- Sets: font (`.font`), color (`.color`), padding (`.padding`) and while pointed at (`.hover`)
"""),
("card", 2, """
**Style `card`**

```desk
style card { .font(13, .semibold).color(.white).padding(4).hover { .color(.accent) } }
```

A style: modifiers that elements take with `.style(…)`.

- Sets: font (`.font`), color (`.color`), padding (`.padding`) and while pointed at (`.hover`)
"""),
("title", 2, """
**Element name `title`**

```desk
Text("{free}").name(title).font(.headline).style(card)
```

The name of an element: actions such as `show(…)` and positions refer to the element by it.

- Component: Text (`Text`)

[Reference](#component-text)
"""),
("90s", 1, """
**`90s`**

a time, such as `2s` or `500ms`

- Equals: 90,000 ms · 1.5 min · 0.025 h

[Reference](#units)
"""),
("2GB", 1, """
**`2GB`**

an amount of data, such as `2GB`

- Equals: 2,147,483,648 B · 2,097,152 KB · 2048 MB
- Counted in: 1024, as the data it is compared with counts (like Activity Monitor)

[Reference](#units)
"""),
("500ms", 1, """
**`500ms`**

a time, such as `2s` or `500ms`

- Equals: 0.5 s

[Reference](#units)
"""),
("500GB", 1, """
**`500GB`**

an amount of data, such as `2GB`

- Equals: 500,000,000,000 B · 500,000 MB · 0.5 TB
- Counted in: 1000, as the data it is compared with counts (like Finder)

[Reference](#units)
"""),
("headline", 1, """
**Headline**

```desk
.headline
```

A text style: a size, weight and design that fit together

- Sets: the font design `.standard`, the font `"System"`, the text size `15` and the font weight `.semibold`
- Since: Deskset 1.0

Example:

```desk
.font(.headline)
```

[Reference](#choices-fontpreset-headline)
"""),
("mono", 2, """
**`.mono`**

```desk
.mono
```

One of the choices of `options.look`.

- Choice of: `options.look`
"""),
("red", 1, """
**Red**

```desk
.red
```

The system's red, adapting to light and dark

- Since: Deskset 1.0

Example:

```desk
.color(.red)
```

[Reference](#choices-color-red)
"""),
("Low", 1, """
**Text**

Text people read; `translations { }` can replace it in other languages.

- Key: “Low”
- zh-Hans: “低”

[Reference](#translations)
"""),
("offset", 1, """
**`offset:`**

```desk
calendar.month(offset: …, weekStart: …)
```

Months from now: 0 this month, 1 the next

- Parameter of: Month grid (`calendar.month`)
- Type: a number
- Default: `0`

[Reference](#data-calendar-month)
"""),
("total", 1, """
**`total:`**

```desk
Progress(value, total: …, fills: …)
```

What full is, for values with no known range

- Parameter of: Progress bar (`Progress`)
- Type: a number

[Reference](#component-progress)
"""),
("used", 1, """
**Memory used**

```desk
memory.used
```

Memory in use (Activity Monitor's “Memory Used”)

- Value: an amount of data, such as `2GB`, counted in 1024s
- Updates: every 2 seconds
- Since: Deskset 1.0

Example:

```desk
Progress(memory.used)
```

Rainmeter: `Measure=PhysicalMemory`

[Reference](#data-memory-used)
"""),
("show", 1, """
**Show**

```desk
show(element)
```

Shows a named element; it keeps its space

- Since: Deskset 1.0

Example:

```desk
.onMouseEnter { show(details) }
```

Rainmeter: `[!ShowMeter …]`

[Reference](#function-show)
"""),
]

/// Signature help at the `|` of a line put inside a widget: (line, name, active signature's label, active parameter).
let deskSignatureGoldens: [(String, String, String, String?)] = [
    ("Text(\"A\").font(13, .semi|bold)", ".font", ".font(size, weight, design, if: …)", "weight"),
    ("Text(\"A\").font(.head|line)", ".font", ".font(preset, if: …)", "preset"),
    ("Text(\"A\").font(|)", ".font", ".font(preset, if: …)", "preset"),
    ("Text(\"A\").font(\"Menlo\", |)", ".font", "", "size"),
    ("Text(\"A\").padding(horizontal: 4, |)", ".padding", "", "vertical"),
    ("Text(\"A\").padding(|12)", ".padding", "", "all"),
    ("Text(\"A\").padding(12, if: |)", ".padding", "", "if"),
    ("Progress(cpu.usage, total: |)", "Progress", "Progress(value, total: …, fills: …)", "total"),
    ("Progress(cpu.usage, |)", "Progress", "Progress(value, total: …, fills: …)", "total"),
    ("Text(\"{cpu.usage, decimals: 1, |}\")", "{…}", "", "missing"),
    ("Text(\"{cpu.usage, deci|mals: 1}\")", "{…}", "", "decimals"),
    ("Text(\"{memory.used, unit: .g|b}\")", "{…}", "", "unit"),
    ("Text(\"{round(|cpu.usage)}\")", "round", "round(x, decimals: …)", "x"),
    ("Text(\"{round(cpu.usage, |)}\")", "round", "round(x, decimals: …)", "decimals"),
    ("computed m = calendar.month(offset: 1, |)", "calendar.month", "calendar.month(offset: …, weekStart: …)", "weekStart"),
    ("Text(\"A\").color(light: .black, dark: |)", ".color", ".color(light: …, dark: …, if: …)", "dark"),
    ("Text(\"A\").onClick { open(|) }", "open", "", "target"),
    ("Text(\"A\").onClick { after(2s|) { page = 1 } }", "after", "", "delay"),
    ("Grid(columns: 7, spacing: 4, |) { Text(\"A\") }", "Grid", "Grid(columns: …, spacing: …, rowSpacing: …, columnSpacing: …, align: …)", "rowSpacing"),
]

func runDeskSignatureHelpGoldens(_ t: TestRunner) {
    t.suite("Desk: service — signature help goldens") {
        for (line, name, label, parameter) in deskSignatureGoldens {
            let cursor = (line as NSString).range(of: "|").location
            let code = line.replacingOccurrences(of: "|", with: "")
            let prefix = "widget {\n    variable page = 0\n    "
            let text = prefix + code + "\n}\n"
            let snapshot = deskNavService(text).snapshot
            let offset = (prefix as NSString).length + cursor
            guard let help = snapshot.signatureHelp(at: snapshot.index.position(utf16: offset)) else {
                t.check(false, "no signature help in \(line)")
                continue
            }
            t.equal(help.name, name, line)
            let active = help.signatures[help.activeSignature]
            if !label.isEmpty { t.equal(active.label, label, line) }
            let p = help.activeParameter.map { active.parameters[$0] }
            t.equal(p.map { $0.label ?? $0.name }, parameter, line)
            // Each parameter's range in the label is where its name is written.
            for q in active.parameters {
                let written = (active.label as NSString).substring(with: NSRange(location: q.labelRange.lowerBound, length: q.labelRange.count))
                t.check(written.hasPrefix(q.label ?? q.name), "\(written) in \(active.label)")
            }
            let english = help.markdown(.english)
            let chinese = help.markdown(.simplifiedChinese)
            t.check(english.contains(active.label) && chinese.contains(active.label), line)
            t.check(chinese.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }, "Chinese: \(chinese)")
        }
        // Outside any call's parentheses there is none; nor in a block after a call.
        let snapshot = deskNavService("widget {\n    Row(spacing: 4) { Text(\"A\") }\n}\n").snapshot
        for needle in ["Row", "{ Text", "widget"] {
            t.equal(snapshot.signatureHelp(at: deskNavPosition(snapshot, needle)), nil, needle)
        }
        t.check(snapshot.signatureHelp(at: deskNavPosition(snapshot, "\"A\"")) != nil, "inside Text(…)")
    }
}

func runDeskServiceInfoLatency(_ t: TestRunner) {
    t.suite("Desk: service — semantic tokens by block") {
        // A range request classifies only the blocks it touches; the whole file then reuses them.
        let text = deskNavFixture("Acceptance/MonthView.desk")
        let snapshot = deskNavService(text).snapshot
        let blocks = snapshot.semanticBlockRanges.count
        let line = snapshot.index.range(utf16: snapshot.index.utf16Range(ofLine: 24))
        _ = snapshot.semanticTokens(in: line)
        t.equal(snapshot.caches.semanticBlocks.count, 1, "one block for one line")
        _ = snapshot.semanticTokens()
        t.equal(snapshot.caches.semanticBlocks.count, blocks, "every block once")
        // Runs are relative to their block: the same block text elsewhere in a file gives the same runs.
        let moved = deskNavService("// Moved down\n\n" + text).snapshot
        let original = snapshot.semanticBlock(2)
        let shifted = moved.semanticBlock(2)
        t.equal(original.runs, shifted.runs.filter { _ in true }, "a block's runs do not depend on where it is")
        t.equal(shifted.offset - original.offset, "// Moved down\n\n".utf8.count)
    }

    t.suite("Desk: service — semantic tokens, hover and signature help latency") {
        #if DEBUG
        let build = "debug"
        let factor = 10.0
        #else
        let build = "release"
        let factor = 1.0
        #endif
        func best(_ runs: Int, _ body: () -> Void) -> Double {
            var fastest = Double.infinity
            for _ in 0..<runs {
                let start = ProcessInfo.processInfo.systemUptime
                body()
                fastest = min(fastest, ProcessInfo.processInfo.systemUptime - start)
            }
            return fastest * 1000
        }
        if ProcessInfo.processInfo.environment["DESK_TOKENS_PROFILE"] != nil {
            let service = deskNavService(deskLargeWidget(lines: 2_000), file: "Large.desk")
            let index = best(3) { _ = service.setMessageLanguage(.english).symbolIndex }
            let facts = best(3) { _ = service.setMessageLanguage(.english).semanticFacts }
            let blocks = best(3) {
                let snapshot = service.setMessageLanguage(.english)
                for k in snapshot.semanticBlockRanges.indices { _ = snapshot.semanticBlock(k) }
            }
            let snapshot = service.setMessageLanguage(.english)
            for k in snapshot.semanticBlockRanges.indices { _ = snapshot.semanticBlock(k) }
            let all = best(3) { _ = DeskSemanticTokens(tokens: snapshot.semanticTokens().tokens, index: snapshot.index) }
            let convert = best(3) {
                for k in snapshot.semanticBlockRanges.indices {
                    let block = snapshot.semanticBlock(k)
                    for run in block.runs { _ = snapshot.index.range(utf8: (block.offset + run.start)..<(block.offset + run.end)) }
                }
            }
            print(String(format: "    index %.1f, facts (with index) %.1f, blocks (with facts) %.1f, encode %.1f, convert %.1f ms", index, facts, blocks, all, convert))
        }
        for lines in [300, 2_000] {
            let text = deskLargeWidget(lines: lines)
            let service = deskNavService(text, file: "Large.desk")
            let page = deskNavPosition(service.snapshot, "page + 1")
            let call = deskNavPosition(service.snapshot, "offset:", into: 3)
            // Each measurement starts from a snapshot with empty caches (the check itself is not repeated).
            let all = best(3) { _ = service.setMessageLanguage(.english).semanticTokens() }
            let screen = best(3) {
                let snapshot = service.setMessageLanguage(.english)
                let middle = snapshot.index.lineCount / 2
                let range = snapshot.index.range(utf16: snapshot.index.utf16Range(ofLine: middle).lowerBound
                                                 ..< snapshot.index.utf16Range(ofLine: min(middle + 50, snapshot.index.lineCount - 1)).upperBound)
                _ = snapshot.semanticTokens(in: range)
            }
            let hover = best(3) { _ = service.setMessageLanguage(.english).hover(at: page) }
            let snapshot = service.setMessageLanguage(.english)
            _ = snapshot.hover(at: page)
            let warmHover = best(3) { _ = snapshot.hover(at: page) }
            let help = best(3) { _ = snapshot.signatureHelp(at: call) }
            print(String(format: "    Desk service, %@ build, %d lines: semantic tokens %.1f ms, 50 lines of them %.1f ms; "
                         + "first hover (index) %.1f ms, then %.2f ms; signature help %.2f ms",
                         build as NSString, lines, all, screen, hover, warmHover, help))
            let bound = (lines == 300 ? 100.0 : 400.0) * factor
            t.check(all < bound && screen < bound && hover < bound, "semantic tokens and hover of \(lines) lines are usable")
        }
    }
}
