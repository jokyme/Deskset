import Foundation

// The values the language service speaks in. Every position it takes or gives is 0-based and counts UTF-16 units,
// like `NSRange` and the text view; the checker's UTF-8 ranges never leave the service.

/// A place in a text: its UTF-16 offset, and the 0-based line and UTF-16 column it is at. A request reads only
/// `offset`, clamped to the text and to the start of a scalar; every position the service gives is at a scalar's
/// start, with the line and column of its offset.
public struct DeskPosition: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var offset: Int
    public var line: Int
    public var column: Int

    public init(offset: Int, line: Int, column: Int) {
        self.offset = offset
        self.line = line
        self.column = column
    }

    public static func < (a: DeskPosition, b: DeskPosition) -> Bool { a.offset < b.offset }

    /// `12:5`, 1-based as people count lines and columns.
    public var description: String { "\(line + 1):\(column + 1)" }
}

/// A half-open range of a text, from `start` up to but not including `end`.
public struct DeskRange: Sendable, Hashable, CustomStringConvertible {
    public var start: DeskPosition
    public var end: DeskPosition

    public init(start: DeskPosition, end: DeskPosition) {
        self.start = start
        self.end = max(start, end)
    }

    // `start` and `end` can be set one at a time, so a range may be reversed (or hold offsets no text has) when it
    // is read: it then reads as empty at `start`, and nothing below overflows or traps.

    /// The UTF-16 offsets.
    public var utf16: Range<Int> { start.offset..<max(start.offset, end.offset) }
    /// The range as a text view takes it.
    public var nsRange: NSRange { NSRange(location: start.offset, length: length) }
    /// The number of UTF-16 units (0 for a reversed range).
    public var length: Int {
        guard end.offset > start.offset else { return 0 }
        let (units, overflow) = end.offset.subtractingReportingOverflow(start.offset)
        return overflow ? Int.max : units
    }
    public var isEmpty: Bool { end.offset <= start.offset }

    /// Whether `offset` is inside; an empty range holds only its own position.
    public func contains(_ offset: Int) -> Bool {
        isEmpty ? offset == start.offset : start.offset <= offset && offset < end.offset
    }

    /// Whether the two ranges share a position or touch.
    public func meets(_ other: DeskRange) -> Bool {
        start.offset <= other.end.offset && other.start.offset <= end.offset
    }

    public var description: String { "\(start)-\(end)" }
}

extension DeskTextIndex {
    /// The position of a UTF-16 offset, clamped to the text and to the start of a scalar.
    public func position(utf16 offset: Int) -> DeskPosition {
        let p = position(ofUTF16: offset)
        return DeskPosition(offset: p.utf16, line: p.line, column: p.column)
    }

    /// The position of a UTF-8 offset (the tree's and the checker's), clamped likewise.
    public func position(utf8 offset: Int) -> DeskPosition {
        let p = position(ofUTF8: offset)
        return DeskPosition(offset: p.utf16, line: p.line, column: p.column)
    }

    /// The position of a 0-based line and UTF-16 column (clamped as `utf16Offset(line:column:)` clamps them).
    public func position(line: Int, column: Int) -> DeskPosition {
        position(utf16: utf16Offset(line: line, column: column))
    }

    /// The range of UTF-16 offsets, each clamped.
    public func range(utf16 range: Range<Int>) -> DeskRange {
        DeskRange(start: position(utf16: range.lowerBound), end: position(utf16: range.upperBound))
    }

    /// The range of UTF-8 offsets, each clamped.
    public func range(utf8 range: Range<Int>) -> DeskRange {
        let start = position(utf8: range.lowerBound)
        return DeskRange(start: start, end: range.upperBound <= range.lowerBound ? start : position(utf8: range.upperBound))
    }

    /// A text view's range, clamped to the text; nil for `NSNotFound` or a negative length.
    public func range(_ nsRange: NSRange) -> DeskRange? {
        guard nsRange.location != NSNotFound, nsRange.length >= 0 else { return nil }
        let (end, overflow) = nsRange.location.addingReportingOverflow(nsRange.length)
        return range(utf16: nsRange.location..<(overflow ? Int.max : end))
    }

    /// The UTF-8 offsets of a range (the checker's and the tree's).
    public func utf8Range(of range: DeskRange) -> Range<Int> {
        utf8Range(ofUTF16: range.utf16)
    }
}

/// A range in a file of the folder.
public struct DeskLocation: Sendable, Hashable, CustomStringConvertible {
    public var file: DeskFileID
    public var range: DeskRange

    public init(file: DeskFileID, range: DeskRange) {
        self.file = file
        self.range = range
    }

    public var description: String { "\(file.path):\(range.start)" }
}

/// A change as a text view reports it: replace `range` (UTF-16) with `text`. In a list of changes each range is in
/// the text as the changes before it left it, the order `NSTextStorage` reports edits in.
public struct DeskTextChange: Sendable, Hashable {
    public var range: Range<Int>
    public var text: String

    public init(range: Range<Int>, text: String) {
        self.range = range
        self.text = text
    }

    /// A text view's change (`NSNotFound`: at the start; a negative length: an insertion).
    public init(nsRange: NSRange, text: String) {
        let location = nsRange.location == NSNotFound ? 0 : nsRange.location
        let (end, overflow) = location.addingReportingOverflow(max(0, nsRange.length))
        self.range = location..<(overflow ? Int.max : end)
        self.text = text
    }
}

/// An edit the service asks for: replace `range` of the text it was computed on with `newText`.
public struct DeskTextEditU16: Sendable, Hashable, CustomStringConvertible {
    public var range: DeskRange
    public var newText: String

    public init(range: DeskRange, newText: String) {
        self.range = range
        self.newText = newText
    }

    public var nsRange: NSRange { range.nsRange }

    public var description: String { "\(range.start.offset)..<\(range.end.offset) → \(String(reflecting: newText))" }

    /// Applies edits of one text, sorted and not overlapping (as `DeskWorkspaceEdit` keeps them), from the last to
    /// the first, as a text view would.
    public static func apply(_ edits: [DeskTextEditU16], to text: String) -> String {
        if edits.isEmpty { return text }
        let string = NSMutableString(string: text)
        for edit in edits.reversed() {
            let location = max(0, min(edit.range.start.offset, string.length))
            let length = min(edit.range.length, string.length - location)
            string.replaceCharacters(in: NSRange(location: location, length: length), with: edit.newText)
        }
        return string as String
    }
}

/// Edits of one or more files of the folder. Each file's edits are sorted by position and never overlap: an edit
/// that would overlap one before it is left out. Insertions at one position keep the order they were given in.
public struct DeskWorkspaceEdit: Sendable, Hashable {
    public private(set) var files: [DeskFileID: [DeskTextEditU16]]

    public init(_ files: [DeskFileID: [DeskTextEditU16]] = [:]) {
        var normalized: [DeskFileID: [DeskTextEditU16]] = [:]
        for (file, edits) in files {
            let kept = Self.normalize(edits)
            if !kept.isEmpty { normalized[file] = kept }
        }
        self.files = normalized
    }

    public var isEmpty: Bool { files.isEmpty }

    /// The files it changes, sorted by path.
    public var changedFiles: [DeskFileID] { files.keys.sorted { $0.path < $1.path } }

    /// The edits of one file, sorted (empty when it has none).
    public func edits(for file: DeskFileID) -> [DeskTextEditU16] { files[file] ?? [] }

    /// The edits sorted by (start, end), stable, without the ones that overlap an earlier one.
    static func normalize(_ edits: [DeskTextEditU16]) -> [DeskTextEditU16] {
        let sorted = edits.enumerated().sorted { a, b in
            let ka = (a.element.range.start.offset, a.element.range.end.offset)
            let kb = (b.element.range.start.offset, b.element.range.end.offset)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        var kept: [DeskTextEditU16] = []
        var reached = 0
        for edit in sorted {
            if !kept.isEmpty, edit.range.start.offset < reached { continue }
            kept.append(edit)
            reached = max(reached, edit.range.end.offset)
        }
        return kept
    }
}

/// How the service checks, words its messages and formats.
public struct DeskServiceOptions: Sendable {
    /// The language of messages, note texts and fix-it titles.
    public var messageLanguage: DiagnosticLanguage
    public var catalog: DeskCatalog
    /// Services the checker uses when given (§4.20); without them the related checks are skipped.
    public var fonts: FontCataloging?
    public var symbols: SymbolValidating?
    public var layout: LayoutMeasuring?
    /// Nil: the newest release the catalog knows.
    public var appVersion: AppVersion?
    /// Nil: `appVersion`.
    public var targetAppVersion: AppVersion?
    public var usesMetric: Bool
    public var usesFahrenheit: Bool
    public var format: FormatOptions
    /// From this many UTF-8 bytes of open text, `update(changes:version:checkingOn:deliverOn:completion:)` checks in
    /// the background (about 200 lines of a widget; a check of that size takes about 6 ms in a release build on
    /// Apple silicon, three times as long on Intel).
    public var backgroundCheckBytes = 8 * 1024
    /// A text whose last check took at least this long is checked in the background too, whatever its size (a
    /// frame at 120 Hz).
    public var backgroundCheckMilliseconds: Double = 8

    public init(messageLanguage: DiagnosticLanguage = .english, catalog: DeskCatalog = .current,
                fonts: FontCataloging? = nil, symbols: SymbolValidating? = nil, layout: LayoutMeasuring? = nil,
                appVersion: AppVersion? = nil, targetAppVersion: AppVersion? = nil, usesMetric: Bool = true,
                usesFahrenheit: Bool = false, format: FormatOptions = .canonical) {
        self.messageLanguage = messageLanguage
        self.catalog = catalog
        self.fonts = fonts
        self.symbols = symbols
        self.layout = layout
        self.appVersion = appVersion
        self.targetAppVersion = targetAppVersion
        self.usesMetric = usesMetric
        self.usesFahrenheit = usesFahrenheit
        self.format = format
    }

    /// The options of a check context (its package and resources are the service's own).
    public init(context: CheckContext, format: FormatOptions = .canonical) {
        self.init(messageLanguage: context.messageLanguage, catalog: context.catalog, fonts: context.fonts,
                  symbols: context.symbols, layout: context.layout, appVersion: context.appVersion,
                  targetAppVersion: context.targetAppVersion, usesMetric: context.usesMetric,
                  usesFahrenheit: context.usesFahrenheit, format: format)
    }

    /// The context a file of the folder is checked with.
    func checkContext(package: CheckedPackage?, resources: ResourceResolving?) -> CheckContext {
        CheckContext(catalog: catalog, package: package, resources: resources, fonts: fonts, symbols: symbols,
                     layout: layout, appVersion: appVersion, targetAppVersion: targetAppVersion,
                     messageLanguage: messageLanguage, usesMetric: usesMetric, usesFahrenheit: usesFahrenheit)
    }
}
