import Foundation

/// How a line break was written; each is kept exactly as written.
public enum NewlineKind: String, Sendable, Hashable, CaseIterable {
    case lf, crlf, cr

    public var text: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// A piece of text between tokens that does not change the meaning: blanks, line breaks, comments.
///
/// Ownership: a token's trailing trivia is everything after it up to (not including) the next line break outside a
/// comment — blanks, a line comment, and block comments that start on that line even when they span lines. Its
/// leading trivia is everything between the previous token's trailing trivia and itself: line breaks, indentation,
/// whole-line comments, blank lines. The first token also takes the byte order mark; the `eof` token takes what
/// follows the last real token.
public enum Trivia: Sendable, Hashable {
    case spaces(Int)
    case tabs(Int)
    case newline(NewlineKind)
    /// `// …` up to the line break (not included).
    case lineComment(String)
    /// `/* … */`, or `/* …` to the end of the file when it is not closed.
    case blockComment(String)
    /// A run of one kind of unusual space (no-break space, full-width space…).
    case unusualSpace(String)
    /// A run of one kind of invisible (format) character.
    case invisible(String)
    /// U+FEFF at the very start of the file.
    case byteOrderMark

    public var text: String {
        switch self {
        case .spaces(let n): return String(repeating: " ", count: n)
        case .tabs(let n): return String(repeating: "\t", count: n)
        case .newline(let kind): return kind.text
        case .lineComment(let s), .blockComment(let s), .unusualSpace(let s), .invisible(let s): return s
        case .byteOrderMark: return "\u{FEFF}"
        }
    }

    public var utf8Length: Int {
        switch self {
        case .spaces(let n), .tabs(let n): return n
        case .newline(let kind): return kind == .crlf ? 2 : 1
        case .lineComment(let s), .blockComment(let s), .unusualSpace(let s), .invisible(let s): return s.utf8.count
        case .byteOrderMark: return 3
        }
    }

    public var isNewline: Bool {
        if case .newline = self { return true }
        return false
    }

    public var isComment: Bool {
        switch self {
        case .lineComment, .blockComment: return true
        default: return false
        }
    }

    /// A line break, or a block comment that spans lines.
    public var containsLineBreak: Bool {
        switch self {
        case .newline: return true
        case .blockComment(let s): return s.utf8.contains(0x0A) || s.utf8.contains(0x0D)
        default: return false
        }
    }

    /// Blanks: spaces, tabs, unusual spaces and invisible characters.
    public var isBlank: Bool {
        switch self {
        case .spaces, .tabs, .unusualSpace, .invisible: return true
        default: return false
        }
    }
}

extension Array where Element == Trivia {
    public var utf8Length: Int { reduce(0) { $0 + $1.utf8Length } }
    public var text: String { map(\.text).joined() }
    public var containsLineBreak: Bool { contains { $0.containsLineBreak } }
    public var containsComment: Bool { contains { $0.isComment } }
}

/// Every kind of token. Reserved words have their own kinds; block words (`info`, `widget`, `style`…) are
/// identifiers that act as keywords only at the start of a top-level item.
public enum TokenKind: String, Sendable, Hashable, CaseIterable {
    // Names
    case identifier
    /// A run of letters with non-ASCII letters in it (`页码`, `café`): DK1007.
    case invalidIdentifier

    // Reserved words
    case ifKeyword, elseKeyword, forKeyword, inKeyword, andKeyword, orKeyword, notKeyword, trueKeyword,
         falseKeyword, variableKeyword, savedKeyword, computedKeyword, eventKeyword

    // Literals
    /// Digits, an optional fraction and an optional unit in one token: `12`, `0.5`, `50%`, `2s`, `2GB/s`.
    case number
    case stringStart, stringText, interpolationStart, interpolationEnd, stringEnd
    /// `#"…"#`: no escapes, no interpolation.
    case rawString

    // Punctuation and operators
    case lParen, rParen, lBrace, rBrace, lBracket, rBracket, comma, colon, semicolon, dot, ellipsis, equal,
         equalEqual, bangEqual, less, lessEqual, greater, greaterEqual, plus, minus, star, slash, percent, question

    // Tokens that exist only to be diagnosed
    case ampAmp, pipePipe, bang, plusEqual, minusEqual, starEqual, slashEqual, plusPlus, minusMinus, starStar,
         amp, pipe, caret, tilde, questionQuestion, dotDot, dotDotLess, arrow, fatArrow, colonColon, at, dollar,
         backslash, backquote, singleQuote, hash
    /// `</`
    case lessSlash
    /// `<!-- … -->`
    case htmlComment
    /// `#Name#`
    case rainmeterVariable
    /// `#FF6B00` (3, 4, 6 or 8 hex digits): DK1026.
    case hexColor
    /// `0xFF6B00`: DK1026.
    case hexNumber
    /// `"""…"""`: DK1017.
    case tripleQuoteString
    /// `\(…)` inside text: DK9010.
    case foreignInterpolation
    /// `# note` at the start of a line: DK9014.
    case foreignHashComment
    /// `; note` at the start of a line: DK9013.
    case foreignRainmeterComment

    // Other
    /// A character that can't be used outside text: DK1006.
    case invalidCharacter
    /// The body of a `script { … }` block, from `{` to its matching `}`.
    case opaqueBlock
    /// The rest of a file past the size or token limit (DK8503).
    case unlexedText
    case eof

    public var isKeyword: Bool {
        switch self {
        case .ifKeyword, .elseKeyword, .forKeyword, .inKeyword, .andKeyword, .orKeyword, .notKeyword,
             .trueKeyword, .falseKeyword, .variableKeyword, .savedKeyword, .computedKeyword, .eventKeyword:
            return true
        default:
            return false
        }
    }

    /// Names usable as member names and argument labels (IDENT, UIDENT, reserved words).
    public var isWord: Bool { self == .identifier || isKeyword }
}

/// Whether a token was written or inserted by error recovery.
public enum Presence: Sendable, Hashable {
    case present
    /// Inserted by recovery: empty text, no trivia.
    case missing
}

public struct TokenFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Written with full-width or look-alike characters that stand for this token (DK1001, DK1002).
    public static let fullWidth = TokenFlags(rawValue: 1 << 0)
    /// `If`, `AND`, `True`: a reserved word in the wrong case (DK3013).
    public static let keywordCaseVariant = TokenFlags(rawValue: 1 << 1)
    /// A token from another language (`&&`, `#Name#`…).
    public static let foreign = TokenFlags(rawValue: 1 << 2)
    /// A number whose unit is diagnosed (DK1021–DK1024, DK1027).
    public static let unitDiagnosed = TokenFlags(rawValue: 1 << 3)
    /// Text that looks like a Windows path (`C:\…`, `\\server`, `%APPDATA%`); its escapes are not reported one by
    /// one, the checker reports the path once.
    public static let windowsPath = TokenFlags(rawValue: 1 << 4)
    /// A raw string `#"…"#`.
    public static let raw = TokenFlags(rawValue: 1 << 5)
    /// A number written with a leading dot, `.5` (DK1020).
    public static let leadingDot = TokenFlags(rawValue: 1 << 6)
    /// A string, raw string or comment that is not closed.
    public static let unterminated = TokenFlags(rawValue: 1 << 7)
    /// A string written between single quotes or backquotes (DK1003).
    public static let wrongQuotes = TokenFlags(rawValue: 1 << 8)
}

/// How a number's unit was written. The grammar does not know dimensions (that is the catalog's job); it only
/// knows whether the spelling is one of the units, a diagnosed spelling, or unknown.
public struct UnitSpelling: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// One of the units (`pt`, `ms`, `%`, `GB/s`, `°C`…).
        case known
        /// A diagnosed spelling (`px`, `em`, `kb`, `Mbps`…) with its diagnostic.
        case diagnosed(DiagnosticID)
        /// `R` or `r`: Rainmeter's relative position (`4R`); DK9309 in `.position`/`.offset`, else DK1024.
        case relativePosition
        /// Not a unit Desk knows (DK1024).
        case unknown
    }

    /// As written, full-width characters mapped to ASCII (`"ms"`, `"GB/s"`, `"°C"`, `"%"`).
    public var text: String
    public var status: Status
    /// The spelling to use instead, when there is one (`"KB"` for `kb`, `"min"` for `m`).
    public var suggestion: String?

    public init(text: String, status: Status, suggestion: String? = nil) {
        self.text = text
        self.status = status
        self.suggestion = suggestion
    }
}

public struct Token: Sendable, Hashable {
    public var kind: TokenKind
    /// Exactly as written (full-width characters kept); empty for a missing token.
    public var text: String
    public var leadingTrivia: [Trivia]
    public var trailingTrivia: [Trivia]
    public var presence: Presence
    public var flags: TokenFlags
    /// For numbers with a unit.
    public var unit: UnitSpelling?

    public init(kind: TokenKind, text: String, leadingTrivia: [Trivia] = [], trailingTrivia: [Trivia] = [],
                presence: Presence = .present, flags: TokenFlags = [], unit: UnitSpelling? = nil) {
        self.kind = kind
        self.text = text
        self.leadingTrivia = leadingTrivia
        self.trailingTrivia = trailingTrivia
        self.presence = presence
        self.flags = flags
        self.unit = unit
    }

    /// A token inserted by recovery.
    public static func missing(_ kind: TokenKind) -> Token {
        Token(kind: kind, text: "", presence: .missing)
    }

    public var isMissing: Bool { presence == .missing }

    /// UTF-8 length of the text and all trivia.
    public var utf8Length: Int { leadingTrivia.utf8Length + text.utf8.count + trailingTrivia.utf8Length }

    /// The text with full-width letters and digits mapped to ASCII: the name a full-width identifier stands for.
    public var name: String {
        guard flags.contains(.fullWidth) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { asciiEquivalent(of: $0) ?? $0 }))
    }

    /// For a number: the digits without the unit (`"12"` of `12pt`, `".5"` of `.5`), full-width digits mapped.
    public var numberText: String {
        guard kind == .number else { return text }
        var digits = ""
        for scalar in text.unicodeScalars {
            let mapped = asciiEquivalent(of: scalar) ?? scalar
            if ("0"..."9").contains(mapped) || mapped == "." {
                digits.unicodeScalars.append(mapped)
            } else {
                break
            }
        }
        return digits
    }

    /// The value of a number token (without its unit), or nil when it is not a finite number.
    public var numberValue: Double? {
        let digits = numberText
        let source = digits.hasPrefix(".") ? "0" + digits : digits
        guard let value = Double(source), value.isFinite else { return nil }
        return value
    }

    /// Whether this is an identifier that starts with an upper-case letter (UIDENT).
    public var isUpperName: Bool {
        guard kind == .identifier, let first = name.unicodeScalars.first else { return false }
        return ("A"..."Z").contains(first)
    }
}

/// The ASCII character a full-width letter, digit or punctuation mark stands for.
func asciiEquivalent(of scalar: Unicode.Scalar) -> Unicode.Scalar? {
    let v = scalar.value
    if (0xFF01...0xFF5E).contains(v) { return Unicode.Scalar(v - 0xFF01 + 0x21) }
    return nil
}
