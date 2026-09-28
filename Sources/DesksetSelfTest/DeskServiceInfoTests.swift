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
