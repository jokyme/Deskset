import Foundation

/// Replace a UTF-8 byte range of a file's text. Every editor operation becomes a list of these, so bytes outside
/// the edited ranges never change.
public struct TextEdit: Sendable, Hashable, CustomStringConvertible {
    public var file: DeskFileID
    public var range: Range<Int>
    public var replacement: String

    public init(file: DeskFileID, range: Range<Int>, replacement: String) {
        self.file = file
        self.range = range
        self.replacement = replacement
    }

    public var description: String {
        "\(range.lowerBound)..<\(range.upperBound) → \(String(reflecting: replacement))"
    }

    /// Applies non-overlapping edits (in any order) to `text`.
    public static func apply(_ edits: [TextEdit], to text: String) -> String {
        if edits.isEmpty { return text }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + edits.reduce(0) { $0 + $1.replacement.utf8.count })
        var cursor = 0
        for edit in edits.sorted(by: { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }) {
            let lower = max(cursor, min(edit.range.lowerBound, bytes.count))
            let upper = max(lower, min(edit.range.upperBound, bytes.count))
            out.append(contentsOf: bytes[cursor..<lower])
            out.append(contentsOf: edit.replacement.utf8)
            cursor = upper
        }
        out.append(contentsOf: bytes[cursor...])
        return String(decoding: out, as: UTF8.self)
    }
}

/// A statement that an edit moved or wrapped: where its text was, and where it is after the edit. The runtime uses
/// these to keep element identity (selection, timers, animations) across the edit.
public struct TextMove: Sendable, Hashable {
    /// In the old text.
    public var from: Range<Int>
    /// In the new text.
    public var to: Range<Int>

    public init(from: Range<Int>, to: Range<Int>) {
        self.from = from
        self.to = to
    }
}

/// Identifies a node of one parse of a file: its kind, where its first token's text starts, and the tree version.
/// A reference from an older tree version is refused, never guessed.
public struct NodeID: Sendable, Hashable, CustomStringConvertible {
    public var kind: SyntaxKind
    /// Start offset of the node's first token text (after its leading trivia) in the parsed text.
    public var utf8Start: Int
    /// `SyntaxTree.version` of the tree the node belongs to.
    public var treeVersion: Int

    public init(kind: SyntaxKind, utf8Start: Int, treeVersion: Int) {
        self.kind = kind
        self.utf8Start = utf8Start
        self.treeVersion = treeVersion
    }

    public var description: String { "\(kind.rawValue)@\(utf8Start)#\(treeVersion)" }
}

public typealias ElementRef = NodeID
public typealias ArgumentRef = NodeID
public typealias ModifierRef = NodeID
public typealias FieldRef = NodeID
public typealias BlockRef = NodeID
public typealias StatementRef = NodeID
public typealias SymbolRef = NodeID
