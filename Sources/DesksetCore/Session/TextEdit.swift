import Foundation

/// One change of a text: the characters in `range` (UTF-16 offsets, as NSString and NSTextView count them) replaced by
/// `replacement`. An editing session turns every edit into such changes of its files' text; the code pane can apply the
/// same change to its own copy of the text.
public struct TextEdit: Equatable, CustomStringConvertible {
    public var range: Range<Int>
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// The smallest single edit that turns `old` into `new` (what lies between their common start and common end), or
    /// nil when they are the same text. A surrogate pair is never split.
    public static func between(_ old: String, _ new: String) -> TextEdit? {
        let a = old as NSString, b = new as NSString
        if a.isEqual(to: new) { return nil }
        let oldLength = a.length, newLength = b.length
        var prefix = 0
        let shorter = min(oldLength, newLength)
        while prefix < shorter, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(a.character(at: prefix - 1)) { prefix -= 1 }
        var suffix = 0
        while suffix < shorter - prefix,
              a.character(at: oldLength - 1 - suffix) == b.character(at: newLength - 1 - suffix) {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(a.character(at: oldLength - suffix)) { suffix -= 1 }
        let replacement = b.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))
        return TextEdit(range: prefix..<(oldLength - suffix), replacement: replacement)
    }

    /// `text` with this edit made (the range is clamped to the text).
    public func applied(to text: String) -> String {
        let s = text as NSString
        let lower = min(max(range.lowerBound, 0), s.length)
        let upper = min(max(range.upperBound, lower), s.length)
        return s.replacingCharacters(in: NSRange(location: lower, length: upper - lower), with: replacement)
    }

    /// The edit that takes `applied(to: old)` back to `old`.
    public func inverse(in old: String) -> TextEdit {
        let s = old as NSString
        let lower = min(max(range.lowerBound, 0), s.length)
        let upper = min(max(range.upperBound, lower), s.length)
        let removed = s.substring(with: NSRange(location: lower, length: upper - lower))
        return TextEdit(range: lower..<(lower + (replacement as NSString).length), replacement: removed)
    }

    public var description: String { "\(range.lowerBound)..<\(range.upperBound) → \(replacement.debugDescription)" }
}

/// A fingerprint of a text — its length in UTF-8 bytes and a 64-bit FNV-1a hash of those bytes — to tell whether a
/// file still holds what an undo step left in it without keeping the whole text around.
public struct TextDigest: Equatable, Hashable, CustomStringConvertible {
    public let length: Int
    public let hash: UInt64

    public init(_ text: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var length = 0
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
            length += 1
        }
        self.length = length
        self.hash = hash
    }

    public var description: String { "\(length) bytes #\(String(hash, radix: 16))" }
}

/// What one step did to one file: the edit that made it (from the text before to the text after), the edit that takes
/// it back, the encodings on both sides (an ANSI file that could not hold an edit became UTF-16), and fingerprints of
/// both texts, so the step is undone only on the text it left behind.
public struct SourceChange: Equatable, CustomStringConvertible {
    public var file: SourceFileID
    public var edit: TextEdit
    public var inverse: TextEdit
    public var encodingBefore: TextFileEncoding
    public var encodingAfter: TextFileEncoding
    public var digestBefore: TextDigest
    public var digestAfter: TextDigest

    /// The change from `before` to `after` (nil when neither the text nor the encoding changes).
    public init?(file: SourceFileID, before: String, after: String, encodingBefore: TextFileEncoding,
                 encodingAfter: TextFileEncoding) {
        let edit = TextEdit.between(before, after)
        guard edit != nil || encodingBefore != encodingAfter else { return nil }
        let made = edit ?? TextEdit(range: 0..<0, replacement: "")
        self.file = file
        self.edit = made
        self.inverse = made.inverse(in: before)
        self.encodingBefore = encodingBefore
        self.encodingAfter = encodingAfter
        digestBefore = TextDigest(before)
        digestAfter = TextDigest(after)
    }

    /// The change in the other direction (undo as a change of its own).
    public var reversed: SourceChange {
        var r = self
        r.edit = inverse
        r.inverse = edit
        r.encodingBefore = encodingAfter
        r.encodingAfter = encodingBefore
        r.digestBefore = digestAfter
        r.digestAfter = digestBefore
        return r
    }

    public var description: String { "\(file): \(edit)" }
}

/// A place of the widget's window on the screen (its top-left corner, in the coordinates `SkinController.moveTo` takes).
public struct WidgetPosition: Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A change outside the files that goes back and forth with a step.
public enum TransactionCommand: Equatable {
    /// The widget's window moved with the files (Fit Widget to Content): it moves back on undo and again on redo — and
    /// never without the files.
    case moveWidget(from: WidgetPosition, to: WidgetPosition)
}

/// One step of the undo stack: a name that says what it did and to what ("Change Font
/// Size of “Audio”"), what it did to each file, the selection before and after it, and what it did outside the files.
public struct Transaction: Equatable {
    public var name: String
    public var changes: [SourceChange]
    public var selectionBefore: [String]
    public var selectionAfter: [String]
    public var commands: [TransactionCommand]

    public init(name: String, changes: [SourceChange], selectionBefore: [String] = [], selectionAfter: [String] = [],
                commands: [TransactionCommand] = []) {
        self.name = name
        self.changes = changes
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.commands = commands
    }

    /// The files it changed.
    public var files: [URL] { changes.map(\.file.url) }
}
