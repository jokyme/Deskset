import Foundation

/// How the items of a list argument are joined in a message: "a, b and c" / "a、b 和 c", or "a, b or c".
public enum ListJoiner: String, Sendable, Hashable {
    case and, or
    /// A path such as a cycle: "`a` → `b` → `a`".
    case arrow
}

/// A typed value inserted into a message template. A diagnostic holds no text in any language; its message is
/// rendered per language from these values (code as written, display names from the catalog, prose in both
/// languages).
public indirect enum DiagnosticArgument: Sendable, Hashable {
    /// Desk text, shown in backquotes as written and never translated: `cpuu`, `.font`.
    case code(String)
    /// Prose in both languages.
    case text(LocalizedText)
    /// A type, rendered with its display name: "a number" / "数字".
    case type(DeskType)
    /// A display-name id of the catalog: `"slot:expression"`, `"component:Progress"`, `"facet:font.weight"`.
    case name(String)
    /// A line, a count, a limit, an amount.
    case number(Int)
    case list([DiagnosticArgument], joiner: ListJoiner)
}

/// A secondary location of a diagnostic: "declared here", "the other copy", "the block opens here".
public struct Note: Sendable, Hashable {
    public var file: DeskFileID
    public var range: Range<Int>
    public var messageKey: String
    public var arguments: [String: DiagnosticArgument]

    public init(file: DeskFileID, range: Range<Int>, messageKey: String,
                arguments: [String: DiagnosticArgument] = [:]) {
        self.file = file
        self.range = range
        self.messageKey = messageKey
        self.arguments = arguments
    }
}

/// A one-click correction: text edits, and a button title given by a key of the catalog's fix-it titles.
public struct FixIt: Sendable, Hashable {
    public var titleKey: String
    public var titleArguments: [String: DiagnosticArgument]
    public var edits: [TextEdit]
    /// Fix-its with the same group form one "Fix all" (全部改正) action.
    public var group: String?

    public init(titleKey: String, titleArguments: [String: DiagnosticArgument] = [:], edits: [TextEdit],
                group: String? = nil) {
        self.titleKey = titleKey
        self.titleArguments = titleArguments
        self.edits = edits
        self.group = group
    }
}

/// What error isolation removed because of a diagnostic.
public enum DroppedUnit: Sendable, Hashable {
    case modifier(NodeID), element(NodeID), field(NodeID), option(NodeID), action(NodeID),
         declarationPoisoned(NodeID)
}

/// A problem found in a file: its stable id, where it is, the values its message needs, and its fix-its.
public struct Diagnostic: Sendable, Hashable {
    public var id: DiagnosticID
    public var severity: Severity
    /// The file `range` is in.
    public var file: DeskFileID
    /// UTF-8 byte range of the primary location, in `file`.
    public var range: Range<Int>
    public var arguments: [String: DiagnosticArgument]
    public var notes: [Note]
    public var fixIts: [FixIt]
    public var dropped: DroppedUnit?

    public init(id: DiagnosticID, severity: Severity, file: DeskFileID, range: Range<Int>,
                arguments: [String: DiagnosticArgument] = [:], notes: [Note] = [], fixIts: [FixIt] = [],
                dropped: DroppedUnit? = nil) {
        self.id = id
        self.severity = severity
        self.file = file
        self.range = range
        self.arguments = arguments
        self.notes = notes
        self.fixIts = fixIts
        self.dropped = dropped
    }
}

extension Diagnostic: CustomStringConvertible {
    /// `DK1010 error 12..<17`, for logs and test failures (messages are rendered with the catalog).
    public var description: String {
        let args = arguments.keys.sorted().map { key -> String in
            switch arguments[key]! {
            case .code(let s): return "\(key)=`\(s)`"
            case .text(let t): return "\(key)=\(t.en)"
            case .name(let n): return "\(key)=<\(n)>"
            case .type(let type): return "\(key)=<\(type)>"
            case .number(let n): return "\(key)=\(n)"
            case .list(let items, _): return "\(key)=[\(items.count)]"
            }
        }
        let suffix = args.isEmpty ? "" : " " + args.joined(separator: " ")
        return "\(id.rawValue) \(severity.rawValue) \(range.lowerBound)..<\(range.upperBound)\(suffix)"
    }
}
