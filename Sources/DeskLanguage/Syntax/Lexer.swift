import Foundation

/// The lexer's output: tokens with their trivia, where each token's text starts, and the lexical diagnostics.
struct LexedFile {
    var tokens: [Token]
    /// UTF-8 offset where each token's text starts (after its leading trivia).
    var starts: [Int]
    /// NL(t): a line break between the previous present token and this one, in the previous token's trailing trivia
    /// (a block comment spanning lines) or in this token's leading trivia.
    var newlineBefore: [Bool]
    var diagnostics: [Diagnostic]
    /// Lexing stopped at the size or token limit.
    var truncated: Bool
}

/// Characters and their meaning, shared by the lexer's scanning functions.
enum Chars {
    static func isASCIILetter(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }
    static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    static func isNameByte(_ b: UInt8) -> Bool { isASCIILetter(b) || isDigit(b) || b == 0x5F }
    static func isHexDigit(_ b: UInt8) -> Bool {
        isDigit(b) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    static func isFullWidthLetter(_ v: UInt32) -> Bool { (0xFF21...0xFF3A).contains(v) || (0xFF41...0xFF5A).contains(v) }
    static func isFullWidthDigit(_ v: UInt32) -> Bool { (0xFF10...0xFF19).contains(v) }

    /// Unusual spaces: trivia with DK1004.
    static func isUnusualSpace(_ v: UInt32) -> Bool {
        v == 0x00A0 || (0x2000...0x200A).contains(v) || v == 0x202F || v == 0x205F || v == 0x3000
    }

    /// Bidirectional controls: an error outside text and comments, a warning inside (DK1006, DK1019).
    static func isBidiControl(_ v: UInt32) -> Bool {
        v == 0x061C || v == 0x200E || v == 0x200F || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
    }

    /// Invisible (format) characters that are trivia with DK1005: every Cf character that is not a bidi control,
    /// and U+FEFF when it is not at the start of the file.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if isBidiControl(v) { return false }
        if (0x200B...0x200D).contains(v) || v == 0x2060 || v == 0xFEFF { return true }
        return scalar.properties.generalCategory == .format
    }

    /// Control characters that are never allowed (other than tab and line breaks), and U+2028, U+2029.
    static func isForbiddenControl(_ v: UInt32) -> Bool {
        (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D) || v == 0x7F || (0x80...0x9F).contains(v)
            || v == 0x2028 || v == 0x2029
    }

    static func isLetterLike(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber:
            return true
        default:
            return false
        }
    }

    /// The ASCII punctuation a full-width or look-alike character stands for, for the one-to-one mappings;
    /// quotes, 「」『』, `…`, `≤`, `≥`, `≠` are handled separately.
    static func mappedPunctuation(_ v: UInt32) -> UInt8? {
        switch v {
        case 0xFF08: return 0x28            // （
        case 0xFF09: return 0x29            // ）
        case 0xFF3B, 0x3010, 0x3014: return 0x5B   // ［ 【 〔
        case 0xFF3D, 0x3011, 0x3015: return 0x5D   // ］ 】 〕
        case 0xFF5B: return 0x7B            // ｛
        case 0xFF5D: return 0x7D            // ｝
        case 0xFF0E, 0x3002, 0xFF61: return 0x2E   // ． 。 ｡
        case 0xFF0B: return 0x2B            // ＋
        case 0xFF0D, 0x2014, 0x2013: return 0x2D   // － — –
        case 0xFF0A, 0x00D7: return 0x2A    // ＊ ×
        case 0xFF0F, 0x00F7: return 0x2F    // ／ ÷
        case 0xFF05: return 0x25            // ％
        case 0xFF01: return 0x21            // ！
        case 0xFF1A, 0xFE30: return 0x3A    // ： ︰
        case 0xFF0C, 0x3001, 0xFF64: return 0x2C   // ， 、 ､
        case 0xFF1B: return 0x3B            // ；
        case 0xFF1D: return 0x3D            // ＝
        case 0xFF1C, 0x300A, 0x3008: return 0x3C   // ＜ 《 〈
        case 0xFF1E, 0x300B, 0x3009: return 0x3E   // ＞ 》 〉
        case 0xFF1F: return 0x3F            // ？
        case 0xFF03: return 0x23            // ＃
        default: return nil
        }
    }

    static let reservedWords: [String: TokenKind] = [
        "if": .ifKeyword, "else": .elseKeyword, "for": .forKeyword, "in": .inKeyword, "and": .andKeyword,
        "or": .orKeyword, "not": .notKeyword, "true": .trueKeyword, "false": .falseKeyword,
        "variable": .variableKeyword, "saved": .savedKeyword, "computed": .computedKeyword, "event": .eventKeyword,
    ]

    static let blockWords: Set<String> = [
        "info", "options", "widget", "style", "translations", "component", "script", "package",
    ]
}

struct Lexer {
    static let maxBytes = 1 << 20
    static let maxTokens = 200_000
    /// Strings nested in interpolations deeper than this are read as text.
    static let maxStringDepth = 32

    let bytes: [UInt8]
    let file: DeskFileID
    var pos = 0
    var tokens: [Token] = []
    var starts: [Int] = []
    var diagnostics: [Diagnostic] = []
    var truncated = false
    /// Braces opened and not yet closed outside text (for `script { … }` at the top level).
    private var braceDepth = 0
    /// The last token was `script` at the top level: a `{` that follows is one opaque token.
    private var scriptPending = false

    init(bytes: [UInt8], file: DeskFileID) {
        self.bytes = bytes
        self.file = file
        tokens.reserveCapacity(bytes.count / 4 + 8)
        starts.reserveCapacity(bytes.count / 4 + 8)
    }

    static func lex(_ bytes: [UInt8], file: DeskFileID) -> LexedFile {
        var lexer = Lexer(bytes: bytes, file: file)
        lexer.run()
        var newlineBefore = [Bool](repeating: false, count: lexer.tokens.count)
        var previousTrailingBreak = false
        for i in lexer.tokens.indices {
            let token = lexer.tokens[i]
            if token.isMissing { newlineBefore[i] = previousTrailingBreak; continue }
            newlineBefore[i] = previousTrailingBreak || token.leadingTrivia.containsLineBreak
            previousTrailingBreak = token.trailingTrivia.containsLineBreak
        }
        return LexedFile(tokens: lexer.tokens, starts: lexer.starts, newlineBefore: newlineBefore,
                         diagnostics: lexer.diagnostics, truncated: lexer.truncated)
    }

    // MARK: - Driver

    mutating func run() {
        while true {
            let leading = scanTrivia(newlines: true, limit: bytes.count) ?? []
            if pos >= bytes.count {
                append(Token(kind: .eof, text: "", leadingTrivia: leading), start: pos)
                return
            }
            if tokens.count >= Lexer.maxTokens || pos >= Lexer.maxBytes {
                truncated = true
                let start = pos
                append(Token(kind: .unlexedText, text: text(start, bytes.count), leadingTrivia: leading), start: start)
                report(.fileTooLarge, .error, start..<bytes.count)
                pos = bytes.count
                append(Token(kind: .eof, text: ""), start: pos)
                return
            }
            lexNormalToken(leading: leading, limit: bytes.count, inInterpolation: false)
        }
    }

    // MARK: - Emitting

    @inline(__always)
    func text(_ start: Int, _ end: Int) -> String {
        String(decoding: bytes[start..<end], as: UTF8.self)
    }

    @inline(__always)
    mutating func append(_ token: Token, start: Int) {
        tokens.append(token)
        starts.append(start)
    }

    /// Appends a token and, outside text, its trailing trivia. Returns false when the trailing trivia could not be
    /// read within `limit` (an interpolation that runs to the end of its line).
    @discardableResult
    mutating func emit(_ kind: TokenKind, _ start: Int, _ end: Int, leading: [Trivia], flags: TokenFlags = [],
                       unit: UnitSpelling? = nil, trailing: Bool = true, limit: Int) -> Bool {
        pos = end
        append(Token(kind: kind, text: text(start, end), leadingTrivia: leading, flags: flags, unit: unit), start: start)
        guard trailing else { return true }
        guard let trivia = scanTrivia(newlines: false, limit: limit) else { return false }
        if !trivia.isEmpty { tokens[tokens.count - 1].trailingTrivia = trivia }
        return true
    }

    mutating func report(_ id: DiagnosticID, _ severity: Severity, _ range: Range<Int>,
                         _ arguments: [String: DiagnosticArgument] = [:], fixIts: [FixIt] = []) {
        diagnostics.append(Diagnostic(id: id, severity: severity, file: file, range: range, arguments: arguments,
                                      fixIts: fixIts))
    }

    func edit(_ range: Range<Int>, _ replacement: String) -> TextEdit {
        TextEdit(file: file, range: range, replacement: replacement)
    }

    // MARK: - Scalars

    /// The scalar at `i` and its UTF-8 length (the text is valid UTF-8).
    @inline(__always)
    func scalar(at i: Int) -> (Unicode.Scalar, Int) {
        let b0 = bytes[i]
        if b0 < 0x80 { return (Unicode.Scalar(b0), 1) }
        var value: UInt32
        var length: Int
        if b0 < 0xE0 {
            value = UInt32(b0 & 0x1F); length = 2
        } else if b0 < 0xF0 {
            value = UInt32(b0 & 0x0F); length = 3
        } else {
            value = UInt32(b0 & 0x07); length = 4
        }
        var k = 1
        while k < length, i + k < bytes.count {
            value = (value << 6) | UInt32(bytes[i + k] & 0x3F)
            k += 1
        }
        return (Unicode.Scalar(value) ?? "\u{FFFD}", length)
    }

    /// Position of the next line break (or the end of the text) at or after `i`.
    func lineEnd(from i: Int) -> Int {
        var j = i
        while j < bytes.count, bytes[j] != 0x0A, bytes[j] != 0x0D { j += 1 }
        return j
    }

    /// Whether only blanks stand between the start of the line and `i`.
    func isFirstOnLine(_ i: Int) -> Bool {
        var j = i
        while j > 0 {
            let b = bytes[j - 1]
            if b == 0x20 || b == 0x09 { j -= 1; continue }
            if b == 0x0A || b == 0x0D { return true }
            if j == 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return true }
            return false
        }
        return true
    }

    // MARK: - Trivia

    /// Reads trivia at `pos`. Without `newlines` it stops before a line break (trailing trivia). When `limit` is
    /// before the end of the text (inside an interpolation) a comment that reaches it makes the scan fail (nil).
    mutating func scanTrivia(newlines: Bool, limit: Int) -> [Trivia]? {
        var pieces: [Trivia] = []
        let bounded = limit < bytes.count
        while pos < limit {
            let b = bytes[pos]
            switch b {
            case 0x20:
                var n = 0
                while pos < limit, bytes[pos] == 0x20 { n += 1; pos += 1 }
                pieces.append(.spaces(n))
            case 0x09:
                var n = 0
                while pos < limit, bytes[pos] == 0x09 { n += 1; pos += 1 }
                pieces.append(.tabs(n))
            case 0x0A:
                guard newlines else { return pieces }
                pieces.append(.newline(.lf)); pos += 1
            case 0x0D:
                guard newlines else { return pieces }
                if pos + 1 < bytes.count, bytes[pos + 1] == 0x0A {
                    pieces.append(.newline(.crlf)); pos += 2
                } else {
                    pieces.append(.newline(.cr)); pos += 1
                }
            case 0x2F where pos + 1 < bytes.count && bytes[pos + 1] == 0x2F:
                if bounded { return nil }
                let end = lineEnd(from: pos)
                pieces.append(.lineComment(text(pos, end)))
                checkCommentCharacters(pos, end)
                pos = end
            case 0x2F where pos + 1 < bytes.count && bytes[pos + 1] == 0x2A:
                let start = pos
                var j = pos + 2
                var closed = false
                while j + 1 < bytes.count {
                    if bytes[j] == 0x2A, bytes[j + 1] == 0x2F { closed = true; j += 2; break }
                    j += 1
                }
                if !closed { j = bytes.count }
                if bounded && j > limit { return nil }
                pieces.append(.blockComment(text(start, j)))
                checkCommentCharacters(start, j)
                if !closed {
                    report(.unterminatedComment, .error, start..<min(start + 2, bytes.count),
                           fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code("*/")],
                                          edits: [edit(bytes.count..<bytes.count, "*/")])])
                }
                pos = j
            default:
                guard b >= 0x80 else { return pieces }
                let (s, length) = scalar(at: pos)
                let v = s.value
                if v == 0xFEFF && pos == 0 {
                    pieces.append(.byteOrderMark); pos += length
                } else if Chars.isUnusualSpace(v) {
                    let start = pos
                    while pos < limit, scalar(at: pos).0 == s { pos += length }
                    pieces.append(.unusualSpace(text(start, pos)))
                    let count = (pos - start) / length
                    report(.unusualSpace, .warning, start..<pos, ["name": .code(Lexer.scalarName(s))],
                           fixIts: [FixIt(titleKey: "replaceWithSpace",
                                          edits: [edit(start..<pos, String(repeating: " ", count: count))],
                                          group: "unusualSpace")])
                } else if Chars.isInvisible(s) {
                    let start = pos
                    while pos < limit, scalar(at: pos).0 == s { pos += length }
                    pieces.append(.invisible(text(start, pos)))
                    report(.invisibleCharacter, .warning, start..<pos, ["name": .code(Lexer.scalarName(s))],
                           fixIts: [FixIt(titleKey: "remove", edits: [edit(start..<pos, "")], group: "invisible")])
                } else {
                    return pieces
                }
            }
        }
        return pieces
    }

    static func scalarName(_ s: Unicode.Scalar) -> String {
        let code = String(format: "U+%04X", s.value)
        if let name = s.properties.name { return "\(code) \(name)" }
        return code
    }

    /// Direction marks inside comments and text are kept, with a warning (DK1019).
    mutating func checkCommentCharacters(_ start: Int, _ end: Int) {
        var i = start
        while i < end {
            if bytes[i] < 0x80 { i += 1; continue }
            let (s, length) = scalar(at: i)
            if Chars.isBidiControl(s.value) {
                report(.directionMark, .warning, i..<(i + length), ["name": .code(Lexer.scalarName(s))],
                       fixIts: [FixIt(titleKey: "remove", edits: [edit(i..<(i + length), "")], group: "directionMark")])
            }
            i += length
        }
    }

    // MARK: - Normal tokens

    /// Lexes one token at `pos` (a string emits several). Inside an interpolation `limit` is the end of the line.
    mutating func lexNormalToken(leading: [Trivia], limit: Int, inInterpolation: Bool) {
        let start = pos
        let b = bytes[start]

        if scriptPending, !inInterpolation {
            scriptPending = false
            if b == 0x7B { lexOpaqueBlock(leading: leading); return }
        }

        if Chars.isASCIILetter(b) || b == 0x5F {
            lexIdentifier(leading: leading, limit: limit, inInterpolation: inInterpolation)
            return
        }
        if Chars.isDigit(b) {
            lexNumber(leading: leading, limit: limit)
            return
        }
        switch b {
        case 0x22: // "
            if start + 2 < bytes.count, bytes[start + 1] == 0x22, bytes[start + 2] == 0x22 {
                lexTripleQuote(leading: leading, limit: limit)
            } else {
                lexString(openLength: 1, style: .double(opener: "\""), leading: leading, nested: inInterpolation,
                          limit: limit)
            }
            return
        case 0x27: // '
            lexQuotedOrLone(style: .single(opener: "'"), openLength: 1, leading: leading, nested: inInterpolation,
                            limit: limit)
            return
        case 0x60: // `
            lexQuotedOrLone(style: .backquote, openLength: 1, leading: leading, nested: inInterpolation, limit: limit)
            return
        case 0x23: // #
            lexHash(leading: leading, limit: limit, inInterpolation: inInterpolation)
            return
        case 0x3B where !inInterpolation && isFirstOnLine(start): // ; at the start of a line
            let end = lineEnd(from: start)
            checkCommentCharacters(start, end)
            emit(.foreignRainmeterComment, start, end, leading: leading, flags: .foreign, limit: limit)
            return
        case 0x3C where start + 3 < bytes.count && bytes[start + 1] == 0x21 && bytes[start + 2] == 0x2D
                        && bytes[start + 3] == 0x2D: // <!--
            lexHTMLComment(leading: leading, limit: limit)
            return
        default:
            break
        }
        if b < 0x80 {
            if lexPunctuation(leading: leading, limit: limit) { return }
            // Any other ASCII character (a control character) is invalid here.
            invalidCharacter(leading: leading, length: 1, limit: limit)
            return
        }

        // Non-ASCII
        let (s, length) = scalar(at: start)
        let v = s.value
        switch v {
        case 0x201C, 0x201D, 0xFF02: // “ ” ＂
            lexString(openLength: length, style: .double(opener: s), leading: leading, nested: inInterpolation,
                      limit: limit)
            return
        case 0x2018, 0x2019, 0xFF07: // ‘ ’ ＇
            lexQuotedOrLone(style: .single(opener: s), openLength: length, leading: leading, nested: inInterpolation,
                            limit: limit)
            return
        case 0x300C, 0x300E: // 「 『
            lexCornerOpen(scalar: s, length: length, leading: leading, limit: limit, inInterpolation: inInterpolation)
            return
        case 0x300D, 0x300F: // 」 』
            emitMapped(.rBrace, start, start + length, "}", leading: leading, limit: limit)
            braceDepth = max(0, braceDepth - 1)
            return
        case 0x2026: // …
            emitMapped(.ellipsis, start, start + length, "...", leading: leading, limit: limit)
            return
        case 0x2264:
            emitMapped(.lessEqual, start, start + length, "<=", leading: leading, limit: limit)
            return
        case 0x2265:
            emitMapped(.greaterEqual, start, start + length, ">=", leading: leading, limit: limit)
            return
        case 0x2260:
            emitMapped(.bangEqual, start, start + length, "!=", leading: leading, limit: limit)
            return
        default:
            break
        }
        if Chars.isFullWidthLetter(v) || v == 0xFF3F {
            lexIdentifier(leading: leading, limit: limit, inInterpolation: inInterpolation)
            return
        }
        if Chars.isFullWidthDigit(v) {
            lexNumber(leading: leading, limit: limit)
            return
        }
        if Chars.mappedPunctuation(v) != nil {
            if lexPunctuation(leading: leading, limit: limit) { return }
        }
        if Chars.isLetterLike(s) && !Chars.isBidiControl(v) {
            lexIdentifier(leading: leading, limit: limit, inInterpolation: inInterpolation)
            return
        }
        invalidCharacter(leading: leading, length: length, limit: limit)
    }

    mutating func invalidCharacter(leading: [Trivia], length: Int, limit: Int) {
        let start = pos
        let (s, _) = scalar(at: start)
        let shown = Chars.isBidiControl(s.value) || s.value < 0x20 || s.properties.generalCategory == .format
            ? String(format: "\\u{%04X}", s.value) : String(s)
        report(.invalidCharacter, .error, start..<(start + length), ["char": .code(shown)],
               fixIts: [FixIt(titleKey: "remove", edits: [edit(start..<(start + length), "")])])
        emit(.invalidCharacter, start, start + length, leading: leading, limit: limit)
    }

    /// A token written with full-width or look-alike characters: DK1002 with a replace fix-it in the "Fix all" group.
    mutating func emitMapped(_ kind: TokenKind, _ start: Int, _ end: Int, _ ascii: String, leading: [Trivia],
                             limit: Int) {
        let original = text(start, end)
        report(.fullWidthPunctuation, .error, start..<end, ["char": .code(original), "ascii": .code(ascii)],
               fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code(ascii)],
                              edits: [edit(start..<end, ascii)], group: "fullWidth")])
        emit(kind, start, end, leading: leading, flags: .fullWidth, limit: limit)
    }

    // MARK: Punctuation

    /// The ASCII punctuation byte at `i` and its length: ASCII itself, or a full-width look-alike.
    func punctuation(at i: Int) -> (byte: UInt8, length: Int, fullWidth: Bool)? {
        guard i < bytes.count else { return nil }
        let b = bytes[i]
        if b < 0x80 { return (b, 1, false) }
        let (s, length) = scalar(at: i)
        if let mapped = Chars.mappedPunctuation(s.value) { return (mapped, length, true) }
        return nil
    }

    /// Operators and punctuation by maximal munch over ASCII and mapped full-width characters.
    mutating func lexPunctuation(leading: [Trivia], limit: Int) -> Bool {
        let start = pos
        guard let first = punctuation(at: start) else { return false }
        var end = start + first.length
        var fullWidth = first.fullWidth
        func next(_ at: Int) -> (byte: UInt8, length: Int, fullWidth: Bool)? {
            at < limit ? punctuation(at: at) : nil
        }
        func take(_ p: (byte: UInt8, length: Int, fullWidth: Bool)) {
            end += p.length
            if p.fullWidth { fullWidth = true }
        }
        var kind: TokenKind
        switch first.byte {
        case 0x28: kind = .lParen
        case 0x29: kind = .rParen
        case 0x7B: kind = .lBrace; braceDepth += 1
        case 0x7D: kind = .rBrace; braceDepth = max(0, braceDepth - 1)
        case 0x5B: kind = .lBracket
        case 0x5D: kind = .rBracket
        case 0x2C: kind = .comma
        case 0x3B: kind = .semicolon
        case 0x3A:
            if let p = next(end), p.byte == 0x3A { take(p); kind = .colonColon } else { kind = .colon }
        case 0x2E:
            if let p = next(end), p.byte == 0x2E {
                take(p)
                if let q = next(end), q.byte == 0x2E { take(q); kind = .ellipsis }
                else if let q = next(end), q.byte == 0x3C { take(q); kind = .dotDotLess }
                else { kind = .dotDot }
            } else if end < limit, isDigitAt(end), !previousEndsOperand() {
                pos = start
                lexNumber(leading: leading, limit: limit, leadingDot: true)
                return true
            } else {
                kind = .dot
            }
        case 0x3D:
            if let p = next(end), p.byte == 0x3D { take(p); kind = .equalEqual }
            else if let p = next(end), p.byte == 0x3E { take(p); kind = .fatArrow }
            else { kind = .equal }
        case 0x21:
            if let p = next(end), p.byte == 0x3D { take(p); kind = .bangEqual } else { kind = .bang }
        case 0x3C:
            if let p = next(end), p.byte == 0x2F, !p.fullWidth { take(p); kind = .lessSlash }
            else if let p = next(end), p.byte == 0x3D { take(p); kind = .lessEqual }
            else { kind = .less }
        case 0x3E:
            if let p = next(end), p.byte == 0x3D { take(p); kind = .greaterEqual } else { kind = .greater }
        case 0x2B:
            if let p = next(end), p.byte == 0x3D { take(p); kind = .plusEqual }
            else if let p = next(end), p.byte == 0x2B { take(p); kind = .plusPlus }
            else { kind = .plus }
        case 0x2D:
            if let p = next(end), p.byte == 0x3D { take(p); kind = .minusEqual }
            else if let p = next(end), p.byte == 0x2D { take(p); kind = .minusMinus }
            else if let p = next(end), p.byte == 0x3E { take(p); kind = .arrow }
            else { kind = .minus }
        case 0x2A:
            if let p = next(end), p.byte == 0x2A { take(p); kind = .starStar }
            else if let p = next(end), p.byte == 0x3D { take(p); kind = .starEqual }
            else { kind = .star }
        case 0x2F:
            if let p = next(end), p.byte == 0x3D { take(p); kind = .slashEqual } else { kind = .slash }
        case 0x25: kind = .percent
        case 0x3F:
            if let p = next(end), p.byte == 0x3F { take(p); kind = .questionQuestion } else { kind = .question }
        case 0x26:
            if let p = next(end), p.byte == 0x26 { take(p); kind = .ampAmp } else { kind = .amp }
        case 0x7C:
            if let p = next(end), p.byte == 0x7C { take(p); kind = .pipePipe } else { kind = .pipe }
        case 0x5E: kind = .caret
        case 0x7E: kind = .tilde
        case 0x40: kind = .at
        case 0x24: kind = .dollar
        case 0x5C: kind = .backslash
        case 0x23: kind = .hash
        default:
            return false
        }
        if fullWidth {
            let ascii = String(decoding: asciiText(start, end), as: UTF8.self)
            emitMapped(kind, start, end, ascii, leading: leading, limit: limit)
        } else {
            emit(kind, start, end, leading: leading, limit: limit)
        }
        return true
    }

    func asciiText(_ start: Int, _ end: Int) -> [UInt8] {
        var out: [UInt8] = []
        var i = start
        while i < end {
            if let p = punctuation(at: i) { out.append(p.byte); i += p.length; continue }
            let (s, length) = scalar(at: i)
            if let a = asciiEquivalent(of: s), a.isASCII { out.append(UInt8(a.value)) } else { out.append(contentsOf: Array(String(s).utf8)) }
            i += length
        }
        return out
    }

    func isDigitAt(_ i: Int) -> Bool {
        guard i < bytes.count else { return false }
        if Chars.isDigit(bytes[i]) { return true }
        if bytes[i] >= 0x80 { return Chars.isFullWidthDigit(scalar(at: i).0.value) }
        return false
    }

    /// Whether the previous token can end an operand, so a `.` after it is a member access (`x.5` is not `.5`).
    func previousEndsOperand() -> Bool {
        guard let last = tokens.last else { return false }
        switch last.kind {
        case .identifier, .number, .stringEnd, .rawString, .rParen, .rBracket, .rBrace, .trueKeyword, .falseKeyword,
             .eventKeyword, .interpolationEnd:
            return !last.trailingTrivia.containsLineBreak
        default:
            return false
        }
    }

    // MARK: Names

    mutating func lexIdentifier(leading: [Trivia], limit: Int, inInterpolation: Bool) {
        let start = pos
        var i = start
        var fullWidth = false
        var foreignLetters = false
        while i < limit {
            let b = bytes[i]
            if b < 0x80 {
                if Chars.isNameByte(b) { i += 1; continue }
                break
            }
            let (s, length) = scalar(at: i)
            let v = s.value
            if Chars.isFullWidthLetter(v) || Chars.isFullWidthDigit(v) || v == 0xFF3F {
                fullWidth = true
            } else if Chars.isLetterLike(s) && !Chars.isBidiControl(v) && !Chars.isInvisible(s) {
                foreignLetters = true
            } else {
                break
            }
            i += length
        }
        if foreignLetters {
            report(.nonAsciiName, .error, start..<i, ["name": .code(text(start, i))])
            emit(.invalidIdentifier, start, i, leading: leading, limit: limit)
            return
        }
        let written = text(start, i)
        let name = fullWidth ? String(String.UnicodeScalarView(written.unicodeScalars.map { asciiEquivalent(of: $0) ?? $0 })) : written
        var kind = TokenKind.identifier
        var flags: TokenFlags = fullWidth ? [.fullWidth] : []
        if let keyword = Chars.reservedWords[name] {
            kind = keyword
        } else if let first = name.first, first.isUppercase, Chars.reservedWords[name.lowercased()] != nil,
                  name == name.uppercased() || name.dropFirst() == name.dropFirst().lowercased() {
            flags.insert(.keywordCaseVariant)
        }
        if name.utf8.count > 128 {
            report(.nameTooLong, .error, start..<i, ["limit": .number(128)])
        }
        if fullWidth {
            report(.fullWidthPunctuation, .error, start..<i, ["char": .code(written), "ascii": .code(name)],
                   fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code(name)],
                                  edits: [edit(start..<i, name)], group: "fullWidth")])
        }
        if !inInterpolation, kind == .identifier, name == "script", braceDepth == 0 {
            scriptPending = true
        }
        emit(kind, start, i, leading: leading, flags: flags, limit: limit)
    }

    // MARK: Numbers

    mutating func lexNumber(leading: [Trivia], limit: Int, leadingDot: Bool = false) {
        let start = pos
        var i = start
        var fullWidth = false
        var flags: TokenFlags = []

        // 0x followed by 6 or 8 hex digits: a Rainmeter or CSS color written as a number (DK1026).
        if !leadingDot, bytes[i] == 0x30, i + 1 < limit, bytes[i + 1] == 0x78 || bytes[i + 1] == 0x58 {
            var j = i + 2
            while j < limit, Chars.isHexDigit(bytes[j]) { j += 1 }
            let count = j - (i + 2)
            if (count == 6 || count == 8), j >= limit || !Chars.isNameByte(bytes[j]) {
                let hex = text(i + 2, j)
                report(.bareHexColor, .error, i..<j, ["hex": .code(hex)],
                       fixIts: [FixIt(titleKey: "addQuotes", edits: [edit(i..<j, "\"#\(hex)\"")])])
                emit(.hexNumber, i, j, leading: leading, flags: .foreign, limit: limit)
                return
            }
        }

        func digits() {
            while i < limit {
                if Chars.isDigit(bytes[i]) { i += 1; continue }
                if bytes[i] >= 0x80 {
                    let (s, length) = scalar(at: i)
                    if Chars.isFullWidthDigit(s.value) { fullWidth = true; i += length; continue }
                }
                break
            }
        }
        if leadingDot {
            let dot = punctuation(at: i)!
            if dot.fullWidth { fullWidth = true }
            i += dot.length
            flags.insert(.leadingDot)
            digits()
        } else {
            digits()
            if let dot = punctuation(at: i), dot.byte == 0x2E, i + dot.length < limit, isDigitAt(i + dot.length) {
                if dot.fullWidth { fullWidth = true }
                i += dot.length
                digits()
            }
        }
        let digitsEnd = i

        // Unit
        var unit: UnitSpelling?
        if i < limit {
            if bytes[i] == 0x25 {
                i += 1
                unit = UnitSpelling(text: "%", status: .known)
            } else if bytes[i] >= 0x80, scalar(at: i).0.value == 0xFF05 {
                i += 3
                fullWidth = true
                unit = UnitSpelling(text: "%", status: .known)
            } else if Chars.isASCIILetter(bytes[i]) || (bytes[i] == 0xC2 && i + 1 < limit && bytes[i + 1] == 0xB0) {
                let unitStart = i
                if bytes[i] == 0xC2 { i += 2 }
                while i < limit, Chars.isASCIILetter(bytes[i]) { i += 1 }
                // `/s` and `/h` belong to the unit only when no name character follows.
                if i + 1 < limit, bytes[i] == 0x2F, bytes[i + 1] == 0x73 || bytes[i + 1] == 0x68,
                   i + 2 >= limit || !Chars.isNameByte(bytes[i + 2]) {
                    i += 2
                } else if text(unitStart, i) == "km", i + 2 < limit, bytes[i] == 0x2F, bytes[i + 1] == 0x68,
                          bytes[i + 2] == 0x72, i + 3 >= limit || !Chars.isNameByte(bytes[i + 3]) {
                    i += 3 // km/hr, diagnosed
                }
                unit = UnitTable.spelling(text(unitStart, i))
            }
        }
        if fullWidth { flags.insert(.fullWidth) }
        if let u = unit, u.status != .known { flags.insert(.unitDiagnosed) }

        let digitText = String(decoding: asciiDigits(start, digitsEnd), as: UTF8.self)
        pos = i
        append(Token(kind: .number, text: text(start, i), leadingTrivia: leading, flags: flags, unit: unit), start: start)

        if leadingDot {
            report(.leadingDotNumber, .error, start..<digitsEnd, ["digits": .code(String(digitText.dropFirst()))],
                   fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code("0")],
                                  edits: [edit(start..<start, "0")])])
        }
        if fullWidth {
            let ascii = digitText + (unit?.text ?? "")
            report(.fullWidthPunctuation, .error, start..<i, ["char": .code(text(start, i)), "ascii": .code(ascii)],
                   fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code(ascii)],
                                  edits: [edit(start..<i, ascii)], group: "fullWidth")])
        }
        let significant = digitText.filter { $0 != "." }.drop { $0 == "0" }.count
        if significant > 15 {
            report(.numberTooLarge, .error, start..<digitsEnd)
        }
        if let unit {
            reportUnit(unit, digits: digitText, range: start..<i, unitRange: digitsEnd..<i)
        }
        if let trivia = scanTrivia(newlines: false, limit: limit), !trivia.isEmpty {
            tokens[tokens.count - 1].trailingTrivia = trivia
        }
    }

    func asciiDigits(_ start: Int, _ end: Int) -> [UInt8] {
        var out: [UInt8] = []
        var i = start
        while i < end {
            if bytes[i] < 0x80 { out.append(bytes[i]); i += 1; continue }
            let (s, length) = scalar(at: i)
            if let a = asciiEquivalent(of: s) { out.append(UInt8(a.value)) }
            i += length
        }
        return out
    }

    mutating func reportUnit(_ unit: UnitSpelling, digits: String, range: Range<Int>, unitRange: Range<Int>) {
        switch unit.status {
        case .known, .relativePosition:
            return
        case .diagnosed(let id):
            switch id {
            case .pxUnit:
                report(.pxUnit, .error, range, ["number": .code(digits)],
                       fixIts: [FixIt(titleKey: "removeText", titleArguments: ["text": .code("px")],
                                      edits: [edit(unitRange, "")])])
            case .cssUnit:
                var arguments: [String: DiagnosticArgument] = ["unit": .code(unit.text)]
                if let s = unit.suggestion { arguments["suggestion"] = .code(s) }
                report(.cssUnit, .error, range, arguments)
            case .bitsUnit:
                let bytesUnit = unit.suggestion ?? "B"
                let value = (Double(digits.hasPrefix(".") ? "0" + digits : digits) ?? 0) / 8
                let number = Lexer.shortNumber(value)
                report(.bitsUnit, .error, range, ["number": .code(number), "bytes": .code(bytesUnit)],
                       fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code(number + bytesUnit)],
                                      edits: [edit(range, number + bytesUnit)])])
            default:
                let fixed = unit.suggestion ?? unit.text
                report(.unitSpelling, .error, range, ["number": .code(digits), "unit": .code(fixed)],
                       fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code(digits + fixed)],
                                      edits: [edit(unitRange, fixed)])])
            }
        case .unknown:
            var fixIts: [FixIt] = []
            if let s = unit.suggestion {
                fixIts.append(FixIt(titleKey: "replaceWith", titleArguments: ["text": .code(digits + s)],
                                    edits: [edit(unitRange, s)]))
            }
            report(.unknownUnit, .error, range,
                   ["unit": .code(unit.text), "list": .list(UnitTable.listed.map { .code($0) }, joiner: .and)],
                   fixIts: fixIts)
        }
    }

    static func shortNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var s = String(format: "%.3f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: # forms

    mutating func lexHash(leading: [Trivia], limit: Int, inInterpolation: Bool) {
        let start = pos
        // #"…"#: a raw string.
        if start + 1 < limit, bytes[start + 1] == 0x22 {
            let stop = min(lineEnd(from: start), limit)
            var j = start + 2
            var closed = false
            while j + 1 < stop {
                if bytes[j] == 0x22, bytes[j + 1] == 0x23 { closed = true; j += 2; break }
                j += 1
            }
            if !closed {
                j = stop
                report(.unterminatedString, .error, start..<j,
                       fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code("\"#")],
                                      edits: [edit(j..<j, "\"#")])])
            }
            checkCommentCharacters(start, j)
            emit(.rawString, start, j, leading: leading, flags: closed ? [.raw] : [.raw, .unterminated], limit: limit)
            return
        }
        // `# note` at the start of a line: a comment from another language.
        if !inInterpolation, isFirstOnLine(start), start + 1 < bytes.count, bytes[start + 1] == 0x20 || bytes[start + 1] == 0x09 {
            let end = lineEnd(from: start)
            checkCommentCharacters(start, end)
            emit(.foreignHashComment, start, end, leading: leading, flags: .foreign, limit: limit)
            return
        }
        // #Name#: a Rainmeter variable.
        var j = start + 1
        while j < limit, Chars.isNameByte(bytes[j]) || bytes[j] == 0x40 || bytes[j] == 0x2A { j += 1 }
        if j > start + 1, j < limit, bytes[j] == 0x23 {
            emit(.rainmeterVariable, start, j + 1, leading: leading, flags: .foreign, limit: limit)
            return
        }
        // #FF6B00: a color without quotes.
        var k = start + 1
        while k < limit, Chars.isHexDigit(bytes[k]) { k += 1 }
        let count = k - start - 1
        if [3, 4, 6, 8].contains(count), k >= limit || !Chars.isNameByte(bytes[k]) {
            let hex = text(start + 1, k)
            report(.bareHexColor, .error, start..<k, ["hex": .code(hex)],
                   fixIts: [FixIt(titleKey: "addQuotes", edits: [edit(start..<k, "\"#\(hex)\"")])])
            emit(.hexColor, start, k, leading: leading, flags: .foreign, limit: limit)
            return
        }
        report(.invalidCharacter, .error, start..<(start + 1), ["char": .code("#")],
               fixIts: [FixIt(titleKey: "remove", edits: [edit(start..<(start + 1), "")])])
        emit(.hash, start, start + 1, leading: leading, flags: .foreign, limit: limit)
    }

    mutating func lexHTMLComment(leading: [Trivia], limit: Int) {
        let start = pos
        var j = start + 4
        var end = lineEnd(from: start)
        while j + 2 < bytes.count {
            if bytes[j] == 0x2D, bytes[j + 1] == 0x2D, bytes[j + 2] == 0x3E { end = j + 3; break }
            j += 1
        }
        let stop = min(max(end, start + 4), bytes.count)
        checkCommentCharacters(start, stop)
        emit(.htmlComment, start, stop, leading: leading, flags: .foreign, limit: limit)
    }

    mutating func lexTripleQuote(leading: [Trivia], limit: Int) {
        let start = pos
        var j = start + 3
        var end = -1
        while j + 2 < bytes.count {
            if bytes[j] == 0x22, bytes[j + 1] == 0x22, bytes[j + 2] == 0x22 { end = j + 3; break }
            j += 1
        }
        var flags: TokenFlags = []
        if end < 0 || limit < bytes.count && end > limit {
            end = min(lineEnd(from: start), limit)
            flags.insert(.unterminated)
        }
        report(.tripleQuote, .error, start..<(start + 3))
        checkCommentCharacters(start, end)
        emit(.tripleQuoteString, start, end, leading: leading, flags: flags, limit: limit)
    }

    /// `script { … }`: the body is one token, from `{` to its matching `}`, counting braces while skipping
    /// JavaScript strings, template literals and comments.
    mutating func lexOpaqueBlock(leading: [Trivia]) {
        let start = pos
        let n = bytes.count
        var i = start + 1
        var depth = 1
        // Brace depth of each open `${` inside template literals.
        var templates: [Int] = []
        var inTemplate = false
        var end = n
        scan: while i < n {
            let b = bytes[i]
            if inTemplate {
                if b == 0x5C { i += 2; continue }
                if b == 0x60 { inTemplate = false; i += 1; continue }
                if b == 0x24, i + 1 < n, bytes[i + 1] == 0x7B { templates.append(0); inTemplate = false; i += 2; continue }
                i += 1
                continue
            }
            switch b {
            case 0x2F where i + 1 < n && bytes[i + 1] == 0x2F:
                i = lineEnd(from: i)
            case 0x2F where i + 1 < n && bytes[i + 1] == 0x2A:
                i += 2
                while i + 1 < n, !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
                i = min(n, i + 2)
            case 0x22, 0x27:
                let quote = b
                i += 1
                while i < n, bytes[i] != quote, bytes[i] != 0x0A, bytes[i] != 0x0D {
                    i += bytes[i] == 0x5C ? 2 : 1
                }
                i += 1
            case 0x60:
                inTemplate = true
                i += 1
            case 0x7B:
                if !templates.isEmpty { templates[templates.count - 1] += 1 } else { depth += 1 }
                i += 1
            case 0x7D:
                if let top = templates.last {
                    if top == 0 { templates.removeLast(); inTemplate = true } else { templates[templates.count - 1] -= 1 }
                } else {
                    depth -= 1
                    if depth == 0 { end = i + 1; break scan }
                }
                i += 1
            default:
                i += 1
            }
        }
        checkCommentCharacters(start, min(end, n))
        emit(.opaqueBlock, start, min(end, n), leading: leading, limit: bytes.count)
    }

    // MARK: - Strings

    enum QuoteStyle: Equatable {
        case double(opener: Unicode.Scalar)
        case single(opener: Unicode.Scalar)
        case backquote
        case corner(opener: Unicode.Scalar)

        /// Whether `s` closes a string opened this way.
        func closes(_ s: Unicode.Scalar) -> Bool {
            switch self {
            case .double(let o):
                if s == "\"" { return true }
                if o == "\u{201C}" || o == "\u{201D}" { return s == "\u{201D}" }
                if o == "\u{FF02}" { return s == "\u{FF02}" }
                return false
            case .single(let o):
                if s == "'" { return true }
                if o == "\u{2018}" || o == "\u{2019}" { return s == "\u{2019}" }
                if o == "\u{FF07}" { return s == "\u{FF07}" }
                return false
            case .backquote:
                return s == "`"
            case .corner(let o):
                return o == "\u{300C}" ? s == "\u{300D}" : s == "\u{300F}"
            }
        }

        var isDoubleFamily: Bool {
            if case .double = self { return true }
            return false
        }
    }

    /// Single quotes and backquotes open a string (DK1003) only when their closing mark is on the same line;
    /// otherwise the mark alone is an invalid character.
    mutating func lexQuotedOrLone(style: QuoteStyle, openLength: Int, leading: [Trivia], nested: Bool, limit: Int) {
        let start = pos
        let end = min(lineEnd(from: start), limit)
        var i = start + openLength
        var found = false
        while i < end {
            let (s, length) = scalar(at: i)
            if s == "\\" { i += 2; continue }
            if style.closes(s) { found = true; break }
            i += length
        }
        if found {
            lexString(openLength: openLength, style: style, leading: leading, nested: nested, limit: limit)
            return
        }
        let kind: TokenKind = style == .backquote ? .backquote : .singleQuote
        report(.invalidCharacter, .error, start..<(start + openLength), ["char": .code(text(start, start + openLength))],
               fixIts: [FixIt(titleKey: "remove", edits: [edit(start..<(start + openLength), "")])])
        emit(kind, start, start + openLength, leading: leading, flags: .foreign, limit: limit)
    }

    /// 「 and 『 are braces where a block opens (after `)`, a capitalised name, a block word, a style or modifier
    /// name, or at the end of a line); quotes only where an expression can start and their closing mark is on the
    /// same line.
    mutating func lexCornerOpen(scalar s: Unicode.Scalar, length: Int, leading: [Trivia], limit: Int,
                                inInterpolation: Bool) {
        let start = pos
        let closer: Unicode.Scalar = s == "\u{300C}" ? "\u{300D}" : "\u{300F}"
        if !readsAsBrace(at: start, length: length) && expressionCanStart() {
            let end = min(lineEnd(from: start), limit)
            var i = start + length
            var found = false
            while i < end {
                let (c, l) = scalar(at: i)
                if c == closer { found = true; break }
                i += l
            }
            if found {
                lexString(openLength: length, style: .corner(opener: s), leading: leading, nested: inInterpolation,
                          limit: limit)
                return
            }
        }
        braceDepth += 1
        emitMapped(.lBrace, start, start + length, "{", leading: leading, limit: limit)
    }

    func readsAsBrace(at start: Int, length: Int) -> Bool {
        // The last token on its line.
        var j = start + length
        while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
        if j >= bytes.count || bytes[j] == 0x0A || bytes[j] == 0x0D { return true }
        if j + 1 < bytes.count, bytes[j] == 0x2F, bytes[j + 1] == 0x2F { return true }
        guard let last = tokens.last else { return false }
        if last.kind == .rParen { return true }
        if last.kind == .identifier {
            if last.isUpperName || Chars.blockWords.contains(last.name) { return true }
            if tokens.count >= 2 {
                let before = tokens[tokens.count - 2]
                if before.kind == .dot || (before.kind == .identifier && before.name == "style") { return true }
            }
        }
        return false
    }

    func expressionCanStart() -> Bool {
        guard let last = tokens.last else { return false }
        switch last.kind {
        case .lParen, .lBracket, .comma, .colon, .equal, .plus, .minus, .star, .slash, .percent, .equalEqual,
             .bangEqual, .less, .lessEqual, .greater, .greaterEqual, .andKeyword, .orKeyword, .notKeyword, .question,
             .ellipsis, .interpolationStart:
            return true
        default:
            return false
        }
    }

    private struct Checkpoint {
        var tokens: Int
        var diagnostics: Int
        var braceDepth: Int
    }

    private func checkpoint() -> Checkpoint {
        Checkpoint(tokens: tokens.count, diagnostics: diagnostics.count, braceDepth: braceDepth)
    }

    private mutating func rollback(_ c: Checkpoint) {
        tokens.removeSubrange(c.tokens...)
        starts.removeSubrange(c.tokens...)
        diagnostics.removeSubrange(c.diagnostics...)
        braceDepth = c.braceDepth
    }

    /// Lexes a string whose opening mark (`openLength` bytes) is at `pos`, with the line-end rules: an
    /// interpolation open at the end of its line is text (DK1014); a `"` string that reaches the end of its line and
    /// contains `”`, `」` or `』` before `)`, `,` or `}` ends there (DK1001); a string whose next line holds an odd
    /// number of `"` continues on it (DK1016); otherwise the string ends at the line break (DK1010).
    mutating func lexString(openLength: Int, style: QuoteStyle, leading: [Trivia], nested: Bool, limit: Int,
                            depth: Int = 0) {
        let start = pos
        let lineLimit = min(lineEnd(from: start), limit)
        let saved = checkpoint()

        var result = lexStringOnce(start: start, openLength: openLength, style: style, leading: leading,
                                   lineLimit: lineLimit, forcedEnd: nil, depth: depth)
        if result.closed { return finishString(start: start, end: result.end, limit: limit) }

        // The closing mark was typed as a curly quote before `)`, `,` or `}`.
        if style.isDoubleFamily, let slip = curlyQuoteSlip(from: start + openLength, to: lineLimit) {
            rollback(saved)
            pos = start
            result = lexStringOnce(start: start, openLength: openLength, style: style, leading: leading,
                                   lineLimit: lineLimit, forcedEnd: slip, depth: depth)
            return finishString(start: start, end: result.end, limit: limit)
        }

        // Broken over two lines.
        if !nested, style.isDoubleFamily, lineLimit < bytes.count, let nextLine = nextLineRange(after: lineLimit),
           quoteCount(nextLine) % 2 == 1 {
            rollback(saved)
            pos = start
            result = lexStringOnce(start: start, openLength: openLength, style: style, leading: leading,
                                   lineLimit: nextLine.upperBound, forcedEnd: nil, depth: depth)
            report(.newlineInString, .error, start..<max(result.end, start + openLength))
            if !result.closed {
                tokens[result.startIndex].flags.insert(.unterminated)
                append(Token.missing(.stringEnd), start: result.end)
            }
            return finishString(start: start, end: result.end, limit: limit)
        }

        // Ends at the line break.
        tokens[result.startIndex].flags.insert(.unterminated)
        append(Token.missing(.stringEnd), start: result.end)
        report(.unterminatedString, .error, start..<max(result.end, start + openLength),
               fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code("\"")],
                              edits: [edit(result.end..<result.end, "\"")])])
        finishString(start: start, end: result.end, limit: limit)
    }

    private mutating func finishString(start: Int, end: Int, limit: Int) {
        pos = end
        if end - start > 32_768 {
            var units = 0
            var k = tokens.count - 1
            while k >= 0, starts[k] >= start {
                if tokens[k].kind == .stringText { units += tokens[k].text.utf16.count }
                k -= 1
            }
            if units > 32_768 { report(.textTooLong, .error, start..<end, ["limit": .number(32_768)]) }
        }
        guard let last = tokens.last, !last.isMissing else { return }
        if let trivia = scanTrivia(newlines: false, limit: limit), !trivia.isEmpty {
            tokens[tokens.count - 1].trailingTrivia = trivia
        }
    }

    /// The first `”`, `」` or `』` directly followed by `)`, `,` or `}` in `from..<to`.
    private func curlyQuoteSlip(from: Int, to: Int) -> Int? {
        var i = from
        while i < to {
            if bytes[i] < 0x80 { i += 1; continue }
            let (s, length) = scalar(at: i)
            if s == "\u{201D}" || s == "\u{300D}" || s == "\u{300F}", i + length < to {
                let next = bytes[i + length]
                if next == 0x29 || next == 0x2C || next == 0x7D { return i }
            }
            i += length
        }
        return nil
    }

    private func nextLineRange(after lineBreak: Int) -> Range<Int>? {
        var i = lineBreak
        guard i < bytes.count else { return nil }
        if bytes[i] == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2 } else { i += 1 }
        return i..<lineEnd(from: i)
    }

    private func quoteCount(_ range: Range<Int>) -> Int {
        var count = 0
        for i in range where bytes[i] == 0x22 { count += 1 }
        return count
    }

    /// One pass over a string. `lineLimit` is the end of its line, or of the next line for a string broken over
    /// two lines (DK1016); interpolations never run past the end of their own line.
    private mutating func lexStringOnce(start: Int, openLength: Int, style: QuoteStyle, leading: [Trivia],
                                        lineLimit: Int, forcedEnd: Int?,
                                        depth: Int) -> (end: Int, closed: Bool, startIndex: Int) {
        var flags: TokenFlags = []
        let (opener, _) = scalar(at: start)
        if !opener.isASCII { flags.insert(.fullWidth) }
        switch style {
        case .single, .backquote: flags.insert(.wrongQuotes)
        default: break
        }
        let windows = looksLikeWindowsPath(start + openLength, lineLimit)
        if windows { flags.insert(.windowsPath) }
        append(Token(kind: .stringStart, text: text(start, start + openLength), leadingTrivia: leading, flags: flags),
               start: start)
        let startIndex = tokens.count - 1
        var i = start + openLength
        var segment = i
        var closerRange: Range<Int>?
        var result: (end: Int, closed: Bool)
        loop: while true {
            if let f = forcedEnd, i >= f {
                flushText(&segment, f)
                let (_, length) = scalar(at: f)
                append(Token(kind: .stringEnd, text: text(f, f + length), flags: .fullWidth), start: f)
                closerRange = f..<(f + length)
                result = (f + length, true)
                break loop
            }
            if i >= lineLimit {
                flushText(&segment, lineLimit)
                result = (lineLimit, false)
                break loop
            }
            let b = bytes[i]
            if b == 0x0A || b == 0x0D {
                // Only inside a continued string (DK1016): the line break is text.
                i += (b == 0x0D && i + 1 < bytes.count && bytes[i + 1] == 0x0A) ? 2 : 1
                continue
            }
            let (s, length) = scalar(at: i)
            if style.closes(s) {
                flushText(&segment, i)
                append(Token(kind: .stringEnd, text: text(i, i + length), flags: s.isASCII ? [] : .fullWidth), start: i)
                closerRange = i..<(i + length)
                result = (i + length, true)
                break loop
            }
            switch b {
            case 0x5C:
                i = lexEscape(at: i, lineLimit: lineLimit, windows: windows, segment: &segment)
            case 0x7B:
                if i + 1 < lineLimit, bytes[i + 1] == 0x7B { i += 2; continue }
                let beforeFlush = checkpoint()
                let segmentBefore = segment
                flushText(&segment, i)
                let interpolationLimit = min(lineEnd(from: i), lineLimit, forcedEnd ?? lineLimit)
                if depth < Lexer.maxStringDepth,
                   let end = lexInterpolation(at: i, lineLimit: interpolationLimit, depth: depth + 1) {
                    i = end
                    segment = end
                } else {
                    // Still open at the end of its line: the `{` is text, and the text before it stays one segment.
                    rollback(beforeFlush)
                    segment = segmentBefore
                    reportUnterminatedInterpolation(at: i, lineLimit: interpolationLimit)
                    i += 1
                }
            case 0x7D:
                if i + 1 < lineLimit, bytes[i + 1] == 0x7D { i += 2; continue }
                report(.loneClosingBrace, .warning, i..<(i + 1),
                       fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("}}")],
                                      edits: [edit(i..<(i + 1), "}}")])])
                i += 1
            default:
                if b >= 0x80 || b < 0x20 {
                    if Chars.isBidiControl(s.value) {
                        report(.directionMark, .warning, i..<(i + length), ["name": .code(Lexer.scalarName(s))],
                               fixIts: [FixIt(titleKey: "remove", edits: [edit(i..<(i + length), "")], group: "directionMark")])
                    } else if Chars.isForbiddenControl(s.value) {
                        report(.invalidCharacter, .error, i..<(i + length),
                               ["char": .code(String(format: "\\u{%04X}", s.value))],
                               fixIts: [FixIt(titleKey: "remove", edits: [edit(i..<(i + length), "")])])
                    }
                }
                i += length
            }
        }
        // Wrong delimiters: one diagnostic per string.
        let openerRange = start..<(start + openLength)
        switch style {
        case .single, .backquote:
            var edits = [edit(openerRange, "\"")]
            if let c = closerRange { edits.append(edit(c, "\"")) }
            let content = text(start + openLength, closerRange?.lowerBound ?? result.end)
            report(.wrongQuoteStyle, .error, start..<result.end, ["text": .code(content)],
                   fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("\"")], edits: edits)])
        default:
            var edits: [TextEdit] = []
            if !opener.isASCII { edits.append(edit(openerRange, "\"")) }
            if let c = closerRange, bytes[c.lowerBound] >= 0x80 { edits.append(edit(c, "\"")) }
            if !edits.isEmpty {
                report(.fullWidthQuote, .error, edits[0].range,
                       fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("\"")], edits: edits,
                                      group: "fullWidth")])
            }
        }
        return (result.end, result.closed, startIndex)
    }

    private mutating func flushText(_ segment: inout Int, _ upTo: Int) {
        if upTo > segment {
            append(Token(kind: .stringText, text: text(segment, upTo)), start: segment)
        }
        segment = upTo
    }

    private mutating func reportUnterminatedInterpolation(at i: Int, lineLimit: Int) {
        report(.unterminatedInterpolation, .error, i..<(i + 1),
               fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code("}")],
                              edits: [edit(lineLimit..<lineLimit, "}")]),
                        FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("{{")],
                              edits: [edit(i..<(i + 1), "{{")])])
    }

    /// Whether a string's text looks like a Windows path: a drive letter and `:\`, a leading `\\`, or `%NAME%`.
    private func looksLikeWindowsPath(_ from: Int, _ to: Int) -> Bool {
        let n = to - from
        guard n >= 2 else { return false }
        var hasBackslash = false
        for i in from..<to where bytes[i] == 0x5C { hasBackslash = true; break }
        guard hasBackslash else { return false }
        if n >= 3, Chars.isASCIILetter(bytes[from]), bytes[from + 1] == 0x3A, bytes[from + 2] == 0x5C { return true }
        if bytes[from] == 0x5C, bytes[from + 1] == 0x5C { return true }
        var i = from
        while i < to {
            if bytes[i] == 0x25 {
                var j = i + 1
                while j < to, Chars.isNameByte(bytes[j]) { j += 1 }
                if j > i + 1, j < to, bytes[j] == 0x25 { return true }
                i = j
            } else {
                i += 1
            }
        }
        return false
    }

    /// An escape at `i` (a backslash). Returns the position after it.
    private mutating func lexEscape(at i: Int, lineLimit: Int, windows: Bool, segment: inout Int) -> Int {
        let next = i + 1
        guard next < lineLimit else {
            if !windows { reportEscape(i..<next, "") }
            return next
        }
        let c = bytes[next]
        switch c {
        case 0x22, 0x5C, 0x6E, 0x74: // \" \\ \n \t
            return i + 2
        case 0x75 where next + 1 < lineLimit && bytes[next + 1] == 0x7B: // \u{…}
            var j = next + 2
            while j < lineLimit, Chars.isHexDigit(bytes[j]) { j += 1 }
            let digits = j - (next + 2)
            if (1...6).contains(digits), j < lineLimit, bytes[j] == 0x7D,
               let value = UInt32(text(next + 2, j), radix: 16), Unicode.Scalar(value) != nil {
                return j + 1
            }
            if !windows { reportEscape(i..<(next + 1), "u") }
            return next + 1
        case 0x7B: // \{…}: the literal text {…}
            var j = next + 1
            while j < lineLimit, bytes[j] != 0x7D, bytes[j] != 0x22 { j += 1 }
            if j < lineLimit, bytes[j] == 0x7D {
                let inner = text(next + 1, j)
                report(.invalidEscape, .error, i..<(j + 1), ["c": .code("{")],
                       fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("{{\(inner)}}")],
                                      edits: [edit(i..<(j + 1), "{{\(inner)}}")])])
                return j + 1
            }
            report(.invalidEscape, .error, i..<(next + 1), ["c": .code("{")],
                   fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("{{")],
                                  edits: [edit(i..<(next + 1), "{{")])])
            return next + 1
        case 0x7D: // \}
            report(.invalidEscape, .error, i..<(next + 1), ["c": .code("}")],
                   fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("}}")],
                                  edits: [edit(i..<(next + 1), "}}")])])
            return next + 1
        case 0x28: // \(…): Swift interpolation
            var j = next + 1
            var depth = 1
            while j < lineLimit {
                let b = bytes[j]
                if b == 0x22 {
                    j += 1
                    while j < lineLimit, bytes[j] != 0x22 { j += bytes[j] == 0x5C ? 2 : 1 }
                    j += 1
                    continue
                }
                if b == 0x28 { depth += 1 }
                if b == 0x29 { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            let end = (j < lineLimit && depth == 0) ? j + 1 : next + 1
            if i > segment { append(Token(kind: .stringText, text: text(segment, i)), start: segment) }
            append(Token(kind: .foreignInterpolation, text: text(i, end), flags: .foreign), start: i)
            segment = end
            var edits = [edit(i..<(next + 1), "{")]
            if end > next + 1 { edits.append(edit((end - 1)..<end, "}")) }
            let inner = end > next + 1 ? text(next + 1, end - 1) : ""
            report(.swiftInterpolation, .error, i..<end, ["fixed": .code("{\(inner)}")],
                   fixIts: [FixIt(titleKey: "rewrite", edits: edits)])
            return end
        default:
            let (s, length) = scalar(at: next)
            if !windows { reportEscape(i..<(next + length), String(s)) }
            return next + length
        }
    }

    private mutating func reportEscape(_ range: Range<Int>, _ c: String) {
        report(.invalidEscape, .error, range, ["c": .code(c)],
               fixIts: [FixIt(titleKey: "showBackslash", titleArguments: ["text": .code("\\\\\(c)")],
                              edits: [edit(range.lowerBound..<range.lowerBound, "\\")], group: "invalidEscape")])
    }

    /// An interpolation starting at the `{` at `brace`. Returns the position after its closing `}`, or nil when it is
    /// still open at `lineLimit` (the caller then reads the `{` as text).
    private mutating func lexInterpolation(at brace: Int, lineLimit: Int, depth: Int) -> Int? {
        pos = brace + 1
        append(Token(kind: .interpolationStart, text: "{"), start: brace)
        if let trivia = scanTrivia(newlines: false, limit: lineLimit) {
            if !trivia.isEmpty { tokens[tokens.count - 1].trailingTrivia = trivia }
        } else {
            return nil
        }
        var stack: [UInt8] = []
        var first = true
        while true {
            guard let leading = scanTrivia(newlines: false, limit: lineLimit) else { return nil }
            if pos >= lineLimit { return nil }
            let at = pos
            let p = punctuation(at: at)
            let b = p?.byte ?? 0
            if b == 0x7D, stack.isEmpty || stack.last != 0x7B {
                let length = p?.length ?? 1
                append(Token(kind: .interpolationEnd, text: text(at, at + length), leadingTrivia: leading,
                             flags: (p?.fullWidth ?? false) ? .fullWidth : []), start: at)
                pos = at + length
                if first {
                    report(.emptyInterpolation, .error, brace..<pos,
                           fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("{{}}")],
                                          edits: [edit(brace..<pos, "{{}}")])])
                }
                return pos
            }
            first = false
            if p != nil, b == 0x7B || b == 0x28 || b == 0x5B { stack.append(b) }
            if p != nil, b == 0x7D || b == 0x29 || b == 0x5D, let top = stack.last,
               (b == 0x7D && top == 0x7B) || (b == 0x29 && top == 0x28) || (b == 0x5D && top == 0x5B) {
                stack.removeLast()
            }
            let (s, _) = scalar(at: at)
            let isQuote = bytes[at] == 0x22 || s == "\u{201C}" || s == "\u{201D}" || s == "\u{FF02}"
            if isQuote {
                if depth >= Lexer.maxStringDepth { return nil }
                let before = tokens.count
                if bytes[at] == 0x22, at + 2 < lineLimit, bytes[at + 1] == 0x22, bytes[at + 2] == 0x22 { return nil }
                lexString(openLength: s.isASCII ? 1 : 3, style: .double(opener: s), leading: leading, nested: true,
                          limit: lineLimit, depth: depth)
                // An unterminated nested string makes the interpolation unterminated too.
                if tokens.count > before, let last = tokens.last, last.kind == .stringEnd, last.isMissing { return nil }
                continue
            }
            let before = tokens.count
            lexNormalToken(leading: leading, limit: lineLimit, inInterpolation: true)
            if tokens.count == before || pos <= at { return nil }
        }
    }
}
