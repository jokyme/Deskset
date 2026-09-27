import Foundation

/// Bounds the lexer and parser enforce so that hostile input can neither overflow the stack nor take unbounded
/// time (§1.1, §2.11 rule 7, §8.4).
public enum SyntaxLimits {
    /// Files larger than this are lexed up to here; the rest is one `unexpected` node (DK8503).
    public static let maxFileBytes = 1 << 20
    /// Lexing stops after this many tokens; the rest is one `unexpected` node (DK8503).
    public static let maxTokens = 200_000
    /// Blocks nested deeper than this are skipped to their closing brace (DK2028). An `else if` counts as a level.
    public static let maxBlockDepth = 64
    /// Expressions nested deeper than this are skipped to their closing bracket (DK2028).
    public static let maxExpressionDepth = 128
    /// Longest cooked text literal, in UTF-16 code units (DK8504).
    public static let maxTextLength = 32_768
    /// Longest name (DK1009).
    public static let maxNameLength = 128
    /// After this many foreign lines in a file, foreign lines are still wrapped but get no diagnostics of their
    /// own; one DK9015 stands for the rest (§2.11 rule 5).
    public static let foreignLinesBeforeSummary = 20
}

/// The grammar slots the parser names in DK2005 ("Expected {expected} here"). Each is a display-name id of the
/// catalog (§5.15), so the message reads naturally in both languages.
public enum SyntaxSlot: String, Sendable, Hashable, CaseIterable {
    case expression = "slot:expression"
    case operand = "slot:operand"
    case condition = "slot:condition"
    case name = "slot:name"
    case declarationName = "slot:declarationName"
    case loopVariable = "slot:loopVariable"
    case styleName = "slot:styleName"
    case memberName = "slot:memberName"
    case label = "slot:label"
    case openingBrace = "slot:openingBrace"
    case closingBrace = "slot:closingBrace"
    case openingParen = "slot:openingParen"
    case closingParen = "slot:closingParen"
    case closingBracket = "slot:closingBracket"
    case colon = "slot:colon"
    case comma = "slot:comma"
    case equals = "slot:equals"
    case inKeyword = "slot:in"
    case block = "slot:block"
    case argument = "slot:argument"
    case statement = "slot:statement"
}

/// The fix-it title keys and note keys the syntax layer uses. The catalog holds their text in both languages; its
/// consistency test checks that every key listed here exists.
public enum SyntaxMessageKeys {
    public static let fixItTitles: [String] = [
        "insert", "replaceWith", "replaceWithSpace", "remove", "removeText", "addQuotes", "showBackslash",
        "rewrite", "joinLines", "newLine", "useBraces", "moveNameToInfo", "removeClosureParameter",
    ]
    public static let notes: [String] = ["openedHere"]
}
