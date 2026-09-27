import Foundation
@testable import DeskLanguage

private func lex(_ text: String) -> LexedFile { Lexer.lex(Array(text.utf8), file: DeskFileID(path: "Test.desk")) }

/// Kinds of the present tokens, eof left out.
private func kinds(_ text: String) -> [TokenKind] {
    lex(text).tokens.filter { !$0.isMissing && $0.kind != .eof }.map(\.kind)
}

/// Texts of the present tokens, eof left out.
private func texts(_ text: String) -> [String] {
    lex(text).tokens.filter { !$0.isMissing && $0.kind != .eof }.map(\.text)
}

private func lexIDs(_ text: String) -> [String] { lex(text).diagnostics.map(\.id.rawValue) }

func runDeskLexerTests(_ t: TestRunner) {
    t.suite("Desk: lexer — names, keywords, punctuation") {
        t.equal(kinds("Text cpu _x a1"), [.identifier, .identifier, .identifier, .identifier])
        t.equal(kinds("if else for in and or not true false variable saved computed event"),
                [.ifKeyword, .elseKeyword, .forKeyword, .inKeyword, .andKeyword, .orKeyword, .notKeyword,
                 .trueKeyword, .falseKeyword, .variableKeyword, .savedKeyword, .computedKeyword, .eventKeyword])
        // Block words are identifiers.
        t.equal(kinds("info options widget style translations component package"), Array(repeating: .identifier, count: 7))
        // Case variants of reserved words are identifiers flagged for DK3013.
        for word in ["If", "AND", "True", "Else", "NOT"] {
            let token = lex(word).tokens[0]
            t.equal(token.kind, .identifier, word)
            t.check(token.flags.contains(.keywordCaseVariant), "\(word) is flagged")
        }
        t.check(!lex("Iff").tokens[0].flags.contains(.keywordCaseVariant))
        t.check(!lex("iF").tokens[0].flags.contains(.keywordCaseVariant))
        // Non-ASCII letters make one invalid identifier (DK1007).
        t.equal(kinds("variable 页码 = 0"), [.variableKeyword, .invalidIdentifier, .equal, .number])
        t.equal(lexIDs("café"), ["DK1007"])
        t.equal(lexIDs(String(repeating: "a", count: 129)), ["DK1009"])
        t.equal(lexIDs(String(repeating: "a", count: 128)), [])
        // Punctuation and operators, maximal munch.
        t.equal(kinds("( ) { } [ ] , : ; . ... = == != < <= > >= + - * / % ?"),
                [.lParen, .rParen, .lBrace, .rBrace, .lBracket, .rBracket, .comma, .colon, .semicolon, .dot,
                 .ellipsis, .equal, .equalEqual, .bangEqual, .less, .lessEqual, .greater, .greaterEqual, .plus,
                 .minus, .star, .slash, .percent, .question])
        t.equal(kinds("&& || ! += -= *= /= ++ -- ** & | ^ ~ ?? .. ..< -> => :: @ $"),
                [.ampAmp, .pipePipe, .bang, .plusEqual, .minusEqual, .starEqual, .slashEqual, .plusPlus,
                 .minusMinus, .starStar, .amp, .pipe, .caret, .tilde, .questionQuestion, .dotDot, .dotDotLess,
                 .arrow, .fatArrow, .colonColon, .at, .dollar])
        t.equal(kinds("a....b"), [.identifier, .ellipsis, .dot, .identifier])
        // `?` and `.` are always two tokens (D73).
        t.equal(kinds("hot ?.red : .blue"), [.identifier, .question, .dot, .identifier, .colon, .dot, .identifier])
        t.equal(kinds("</div>"), [.lessSlash, .identifier, .greater])
        t.equal(kinds("<!-- note -->"), [.htmlComment])
        t.equal(kinds("#Color#"), [.rainmeterVariable])
        t.equal(kinds("a\\b"), [.identifier, .backslash, .identifier])
        // Kinds compare and hash by their case (one byte), not through their raw-value strings.
        t.equal([MemoryLayout<TokenKind>.size, MemoryLayout<SyntaxKind>.size, MemoryLayout<ForeignKind>.size,
                 MemoryLayout<NewlineKind>.size], [1, 1, 1, 1])
        var mismatches = 0
        for a in TokenKind.allCases { for b in TokenKind.allCases where (a == b) != (a.rawValue == b.rawValue) { mismatches += 1 } }
        for a in SyntaxKind.allCases { for b in SyntaxKind.allCases where (a == b) != (a.rawValue == b.rawValue) { mismatches += 1 } }
        for a in ForeignKind.allCases { for b in ForeignKind.allCases where (a == b) != (a.rawValue == b.rawValue) { mismatches += 1 } }
        t.equal(mismatches, 0)
        t.equal(Set(TokenKind.allCases).count, TokenKind.allCases.count)
        t.equal(Set(SyntaxKind.allCases).count, SyntaxKind.allCases.count)
        t.check(Set<SyntaxKind>([.block, .callStmt]).contains(.callStmt) && !Set<SyntaxKind>([.block]).contains(.field))
    }

    t.suite("Desk: lexer — numbers and units") {
        t.equal(texts("12 0.5 50% 2s 500ms 5min 1h 1d 2GB/s 50km/h 1.5GHz 30°C -40°F 45° 1rad"),
                ["12", "0.5", "50%", "2s", "500ms", "5min", "1h", "1d", "2GB/s", "50km/h", "1.5GHz", "30°C", "-",
                 "40°F", "45°", "1rad"])
        for (source, unit) in [("2s", "s"), ("2GB/s", "GB/s"), ("50km/h", "km/h"), ("12pt", "pt"), ("30°C", "°C"),
                               ("50%", "%"), ("3m/s", "m/s"), ("12KiB", "KiB"), ("1000hPa", "hPa")] {
            let token = lex(source).tokens[0]
            t.equal(token.kind, .number, source)
            t.equal(token.unit?.text, unit, source)
            t.equal(token.unit?.status, .known, source)
        }
        // `/s` and `/h` join the unit only when no name character follows.
        t.equal(texts("10/2"), ["10", "/", "2"])
        t.equal(texts("2GB/2"), ["2GB", "/", "2"])
        t.equal(texts("5GB/speed"), ["5GB", "/", "speed"])
        t.equal(texts("10s/speed"), ["10s", "/", "speed"])
        // A `.` belongs to a number only when a digit follows.
        t.equal(texts("1...12"), ["1", "...", "12"])
        t.equal(texts("10 % 3"), ["10", "%", "3"])
        t.equal(lex("2.5").tokens[0].numberValue, 2.5)
        // Diagnosed spellings keep number and unit together.
        let cases: [(String, String, String?)] = [
            ("18px", "DK1021", ""), ("10em", "DK1022", nil), ("2in", "DK1022", nil), ("5m", "DK1023", "5min"),
            ("2kb", "DK1023", "2KB"), ("1sec", "DK1023", "1s"), ("30C", "DK1023", "30°C"), ("10kmh", "DK1023", "10km/h"),
            ("100Mb", "DK1027", "12.5MB"), ("8Mbps", "DK1027", "1MB/s"), ("12pc", "DK1024", nil), ("3zz", "DK1024", nil),
        ]
        for (source, id, fixed) in cases {
            let lexed = lex(source)
            t.equal(lexed.tokens[0].kind, .number, source)
            t.check(lexed.tokens[0].flags.contains(.unitDiagnosed), "\(source) flagged")
            t.equal(lexed.diagnostics.map(\.id.rawValue), [id], source)
            if let fixed, let fixIt = lexed.diagnostics.first?.fixIts.first {
                let result = TextEdit.apply(fixIt.edits, to: source)
                t.equal(result, fixed.isEmpty ? "18" : fixed, "\(source) fix-it")
            }
        }
        // `R` / `r` after digits are Rainmeter's relative positions: no lexer diagnostic (the checker decides).
        t.equal(lex("4R").tokens[0].unit?.status, .relativePosition)
        t.equal(lexIDs("4R 2r"), [])
        // A leading dot, bare hex colors, hex numbers, too many digits.
        t.equal(lexIDs(".opacity(.5)"), ["DK1020"])
        t.equal(TextEdit.apply(lex("(.5)").diagnostics[0].fixIts[0].edits, to: "(.5)"), "(0.5)")
        t.equal(kinds("0xFF6B00"), [.hexNumber])
        t.equal(lexIDs("0xFF6B00"), ["DK1026"])
        t.equal(kinds("#FF6B00 #FFF #FF6B00AA"), [.hexColor, .hexColor, .hexColor])
        t.equal(TextEdit.apply(lex("#FF6B00").diagnostics[0].fixIts[0].edits, to: "#FF6B00"), "\"#FF6B00\"")
        t.equal(lexIDs("1234567890123456"), ["DK1025"])
        t.equal(lexIDs("123456789012345"), [])
        t.equal(lexIDs("0.000000000000000001"), [])
    }

    t.suite("Desk: lexer — strings, escapes and interpolation") {
        t.equal(kinds("\"CPU\""), [.stringStart, .stringText, .stringEnd])
        t.equal(kinds("\"{cpu.usage}%\""), [.stringStart, .interpolationStart, .identifier, .dot, .identifier,
                                             .interpolationEnd, .stringText, .stringEnd])
        // Strings nest inside interpolations to any depth.
        t.equal(kinds("\"{time.now, format: \"HH:mm\"}\""),
                [.stringStart, .interpolationStart, .identifier, .dot, .identifier, .comma, .identifier, .colon,
                 .stringStart, .stringText, .stringEnd, .interpolationEnd, .stringEnd])
        t.equal(lexIDs("\"{a, b: \"{c, d: \"{e}\"}\"}\""), [])
        // Escapes, doubled braces.
        t.equal(lexIDs(#""a \" \\ \n \t \u{1F600} {{ }} b""#), [])
        t.equal(StringLiteralSyntax.cook(#"a \" \\ \n \t \u{41} {{x}}"#), "a \" \\ \n \t A {x}")
        t.equal(lexIDs(#""a\qb""#), ["DK1012"])
        t.equal(TextEdit.apply(lex(#""a\qb""#).diagnostics[0].fixIts[0].edits, to: #""a\qb""#), #""a\\qb""#)
        // `\{…}` is literal text; its fix-it writes `{{…}}`; `\(…)` is Swift's interpolation (DK9010).
        let braced = #""\{name}""#
        t.equal(lexIDs(braced), ["DK1012"])
        t.equal(TextEdit.apply(lex(braced).diagnostics[0].fixIts[0].edits, to: braced), #""{{name}}""#)
        t.equal(kinds(braced), [.stringStart, .stringText, .stringEnd])
        let swift = #""\(cpu.usage)%""#
        t.equal(kinds(swift), [.stringStart, .foreignInterpolation, .stringText, .stringEnd])
        t.equal(lexIDs(swift), ["DK9010"])
        t.equal(TextEdit.apply(lex(swift).diagnostics[0].fixIts[0].edits, to: swift), #""{cpu.usage}%""#)
        // A lone `}` is text with a warning; `{}` is empty.
        t.equal(lexIDs("\"a } b\""), ["DK1013"])
        t.equal(lex("\"a } b\"").diagnostics[0].severity, .warning)
        t.equal(lexIDs("\"a {} b\""), ["DK1015"])
        // Its fix-it shows the braces as written.
        t.equal(TextEdit.apply(lex("\"a { } b\"").diagnostics[0].fixIts[0].edits, to: "\"a { } b\""), "\"a {{ }} b\"")
        t.equal(lexIDs("\"a {{ }} b\""), [])
        // An interpolation open at the end of its line is text: one DK1014, no nested string.
        t.equal(lexIDs("Text(\"Use { to open\")"), ["DK1014"])
        t.equal(kinds("Text(\"Use { to open\")"), [.identifier, .lParen, .stringStart, .stringText, .stringEnd, .rParen])
        // A `}` that meets an open `(` closes the interpolation (the parser reports the `(`).
        t.equal(kinds("\"{round(x}%\""), [.stringStart, .interpolationStart, .identifier, .lParen, .identifier,
                                          .interpolationEnd, .stringText, .stringEnd])
        // Line ends: the curly-quote slip (DK1001), a string broken over two lines (DK1016), unterminated (DK1010).
        let slip = "Text(\"CPU”).font(.caption)"
        t.equal(lexIDs(slip), ["DK1001"])
        t.equal(kinds(slip), [.identifier, .lParen, .stringStart, .stringText, .stringEnd, .rParen, .dot,
                              .identifier, .lParen, .dot, .identifier, .rParen])
        let broken = "Text(\"first\nsecond\")\n"
        t.equal(lexIDs(broken), ["DK1016"])
        t.equal(kinds(broken), [.identifier, .lParen, .stringStart, .stringText, .stringEnd, .rParen])
        let unterminated = "Text(\"CPU)\nText(\"B\")"
        t.equal(lexIDs(unterminated), ["DK1010"])
        t.equal(TextEdit.apply(lex(unterminated).diagnostics[0].fixIts[0].edits, to: unterminated),
                "Text(\"CPU\")\nText(\"B\")")
        // Raw strings: no escapes, no interpolation, end at the first `"#`.
        t.equal(kinds(##"#"^\d{3}$"#"##), [.rawString])
        t.equal(lexIDs(##".matches(#"^\d{3}$"#)"##), [])
        t.equal(StringLiteralSyntax.literalValue(of: deskParse(##"x = #"a\{b}"#"##).root.firstNode(.stringLiteral)!), #"a\{b}"#)
        // Wrong quotes.
        t.equal(lexIDs("Text('CPU')"), ["DK1003"])
        t.equal(TextEdit.apply(lex("Text('CPU')").diagnostics[0].fixIts[0].edits, to: "Text('CPU')"), "Text(\"CPU\")")
        t.equal(lexIDs("Text(“CPU”)"), ["DK1001"])
        t.equal(TextEdit.apply(lex("Text(“CPU”)").diagnostics[0].fixIts[0].edits, to: "Text(“CPU”)"), "Text(\"CPU\")")
        t.equal(kinds("\"\"\"long text\"\"\""), [.tripleQuoteString])
        t.equal(lexIDs("\"\"\"long text\"\"\""), ["DK1017"])
        // Windows paths are flagged; their escapes are not reported one by one.
        let path = #"open("C:\Program Files\Steam\steam.exe")"#
        t.equal(lexIDs(path), [])
        t.check(lex(path).tokens[2].flags.contains(.windowsPath))
        t.check(lex(#""%APPDATA%\x""#).tokens[0].flags.contains(.windowsPath))
        // Text longer than 32,768 UTF-16 code units (DK8504).
        t.equal(lexIDs("\"" + String(repeating: "a", count: 40_000) + "\""), ["DK8504"])
    }

    t.suite("Desk: lexer — full-width and look-alike characters") {
        // Every row of the table maps to the ASCII token, keeps the text, and reports DK1002 with a replace fix-it.
        let table: [(String, TokenKind, String)] = [
            ("（", .lParen, "("), ("）", .rParen, ")"), ("［", .lBracket, "["), ("］", .rBracket, "]"),
            ("【", .lBracket, "["), ("】", .rBracket, "]"), ("〔", .lBracket, "["), ("〕", .rBracket, "]"),
            ("｛", .lBrace, "{"), ("｝", .rBrace, "}"), ("．", .dot, "."), ("。", .dot, "."), ("｡", .dot, "."),
            ("＋", .plus, "+"), ("－", .minus, "-"), ("＊", .star, "*"), ("／", .slash, "/"), ("％", .percent, "%"),
            ("！", .bang, "!"), ("：", .colon, ":"), ("︰", .colon, ":"), ("，", .comma, ","), ("、", .comma, ","),
            ("､", .comma, ","), ("；", .semicolon, ";"), ("＝", .equal, "="), ("＜", .less, "<"), ("＞", .greater, ">"),
            ("《", .less, "<"), ("〈", .less, "<"), ("》", .greater, ">"), ("〉", .greater, ">"), ("？", .question, "?"),
            ("…", .ellipsis, "..."), ("≤", .lessEqual, "<="), ("≥", .greaterEqual, ">="), ("≠", .bangEqual, "!="),
            ("×", .star, "*"), ("÷", .slash, "/"), ("—", .minus, "-"), ("–", .minus, "-"),
        ]
        for (character, kind, ascii) in table {
            let source = "a \(character) b"
            let lexed = lex(source)
            let token = lexed.tokens[1]
            t.equal(token.kind, kind, character)
            t.equal(token.text, character, "\(character) keeps its text")
            t.check(token.flags.contains(.fullWidth), "\(character) flagged")
            let ids = lexed.diagnostics.map(\.id.rawValue)
            t.equal(ids, ["DK1002"], character)
            if let fixIt = lexed.diagnostics.first?.fixIts.first {
                t.equal(TextEdit.apply(fixIt.edits, to: source), "a \(ascii) b", "\(character) fix-it")
                t.equal(fixIt.group, "fullWidth", "\(character) in the Fix-all group")
            }
        }
        // Full-width digits and letters.
        t.equal(lex("１２").tokens[0].kind, .number)
        t.equal(lex("１２").tokens[0].numberValue, 12)
        t.equal(lex("Ｔｅｘｔ").tokens[0].name, "Text")
        t.equal(lexIDs("Ｔｅｘｔ"), ["DK1002"])
        // The full-width space is an unusual space (DK1004).
        t.equal(lexIDs("a\u{3000}b"), ["DK1004"])
        // 「 」 read as braces where a block opens or closes, as quotes where an expression starts.
        t.equal(kinds("widget 「\n」"), [.identifier, .lBrace, .rBrace])
        t.equal(kinds("Row 「 Text(\"A\") 」"), [.identifier, .lBrace, .identifier, .lParen, .stringStart, .stringText,
                                               .stringEnd, .rParen, .rBrace])
        t.equal(kinds("Text(「CPU」)"), [.identifier, .lParen, .stringStart, .stringText, .stringEnd, .rParen])
        t.equal(lexIDs("Text(「CPU」)"), ["DK1001"])
        // Inside strings these characters are content and are never reported.
        t.equal(lexIDs("\"（CPU）：。，\""), [])
    }

    t.suite("Desk: lexer — comments and trivia") {
        let source = "\u{FEFF}// top\nText(\"A\") // end\n/* block\n */ x /* inline */ y\n"
        let tokens = lex(source).tokens
        t.equal(tokens[0].leadingTrivia.first, .byteOrderMark)
        t.check(tokens[0].leadingTrivia.contains(.lineComment("// top")), "whole-line comment leads the next token")
        let close = tokens.first { $0.kind == .rParen }!
        t.check(close.trailingTrivia.contains(.lineComment("// end")), "end-of-line comment trails its line")
        let x = tokens.first { $0.text == "x" }!
        t.check(x.leadingTrivia.contains(.blockComment("/* block\n */")), "a block comment on its own lines leads")
        t.check(x.trailingTrivia.contains(.blockComment("/* inline */")), "an inline block comment trails")
        t.equal(tokens.last?.kind, .eof)
        t.equal(tokens.last?.leadingTrivia, [.newline(.lf)])
        // A block comment that starts on a token's line trails it even across lines, and still counts as NL.
        let spanning = lex("Text(\"A\") /* old\n*/ Text(\"B\")")
        let firstClose = spanning.tokens.firstIndex { $0.kind == .rParen }!
        t.check(spanning.tokens[firstClose].trailingTrivia.contains(.blockComment("/* old\n*/")))
        t.check(spanning.newlineBefore[firstClose + 1], "the line break inside the comment is a newline boundary")
        // Line breaks are kept as written.
        let breaks = lex("a\r\nb\rc\nd").tokens
        t.equal(breaks[1].leadingTrivia, [.newline(.crlf)])
        t.equal(breaks[2].leadingTrivia, [.newline(.cr)])
        t.equal(breaks[3].leadingTrivia, [.newline(.lf)])
        // Unclosed block comments run to the end (DK1011).
        t.equal(lexIDs("x /* note"), ["DK1011"])
        // `#` and `;` at the start of a line are other languages' comments (tokens, warnings from the parser).
        t.equal(kinds("# note\n; note\nx"), [.foreignHashComment, .foreignRainmeterComment, .identifier])
        t.equal(kinds("a; b"), [.identifier, .semicolon, .identifier])
        // Unusual spaces (DK1004) and invisible characters (DK1005) are trivia.
        t.equal(lexIDs("a\u{00A0}b"), ["DK1004"])
        t.equal(lexIDs("a\u{200B}b"), ["DK1005"])
        t.equal(kinds("a\u{00A0}\u{200B}b"), [.identifier, .identifier])
        t.equal(TextEdit.apply(lex("a\u{00A0}b").diagnostics[0].fixIts[0].edits, to: "a\u{00A0}b"), "a b")
        // Direction marks: an error outside text, a warning in text and comments (D86).
        t.equal(lexIDs("a \u{202E} b"), ["DK1006"])
        t.equal(lexIDs("\"a\u{202E}b\""), ["DK1019"])
        t.equal(lexIDs("// a\u{202E}b"), ["DK1019"])
        t.equal(lexIDs(##"#"a\##u{202E}b"#"##), ["DK1019"])
        // Control characters, U+2028.
        t.equal(lexIDs("a \u{0007} b"), ["DK1006"])
        t.equal(lexIDs("a \u{2028} b"), ["DK1006"])
        t.equal(lexIDs("a § b"), ["DK1006"])
    }

    t.suite("Desk: lexer — script blocks and limits") {
        let script = "script { let a = { b: \"}\" }; const s = `x ${ {y: 1} } }`; // }\n }\nwidget { }"
        t.equal(kinds(script), [.identifier, .opaqueBlock, .identifier, .lBrace, .rBrace])
        t.check(lex(script).tokens[1].text.hasSuffix("}\n }"))
        // Past 1 MiB the rest is one unlexed token (DK8503), and the text still round-trips.
        let line = "Text(\"abcdefghij\")\n"
        let big = String(repeating: line, count: (1 << 20) / line.utf8.count + 100)
        let lexed = lex(big)
        t.equal(lexed.tokens.filter { $0.kind == .unlexedText }.count, 1)
        t.equal(lexed.diagnostics.map(\.id.rawValue), ["DK8503"])
        t.check(lexed.truncated)
        let total = lexed.tokens.reduce(0) { $0 + $1.utf8Length }
        t.equal(total, big.utf8.count)
        // More than 200,000 tokens.
        let many = String(repeating: "a;", count: 100_001)
        let manyLexed = lex(many)
        t.equal(manyLexed.diagnostics.map(\.id.rawValue), ["DK8503"])
        t.equal(manyLexed.tokens.reduce(0) { $0 + $1.utf8Length }, many.utf8.count)
    }
}

extension SyntaxNode {
    /// The first node of a kind, depth first (tests).
    func firstNode(_ kind: SyntaxKind) -> SyntaxNode? {
        var stack: [SyntaxNode] = [self]
        while let node = stack.popLast() {
            if node.kind == kind { return node }
            for child in node.children.reversed() { if case .node(let n) = child { stack.append(n) } }
        }
        return nil
    }

    /// Every node of a kind, depth first (tests).
    func allNodes(_ kind: SyntaxKind) -> [SyntaxNode] {
        var out: [SyntaxNode] = []
        var stack: [SyntaxNode] = [self]
        while let node = stack.popLast() {
            if node.kind == kind { out.append(node) }
            for child in node.children.reversed() { if case .node(let n) = child { stack.append(n) } }
        }
        return out
    }
}
