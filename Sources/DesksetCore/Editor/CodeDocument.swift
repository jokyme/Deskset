import Foundation

/// One skin text file as the built-in code editor sees it (docs/editor-design.md §5): its text, the byte encoding
/// and BOM it was read with, its dominant line ending, and line / section lookups over the text.
///
/// Byte-exact round trip: the text is kept exactly as decoded — CRLF, lone CR and LF all stay where they are (the
/// text view keeps them too) — and `data(for:)` encodes it back with the same encoding and BOM without normalising
/// anything, so an unchanged text gives back the original bytes (UTF-8 with or without BOM, UTF-16 LE/BE, and
/// legacy ANSI, which `TextDecoding` decodes losslessly). New line breaks typed in the editor use `lineEnding`.
///
/// Lines are 1-based, like `IniSyntax.ParsedFile` / `IniSourceMap` line numbers. Unlike the reader, a text that
/// ends with a line break has one more, empty, line after it (where the caret can go), so `lineCount` is the number
/// of line breaks + 1. Offsets are UTF-16 (NSString / NSTextView) offsets.
public struct CodeDocument: Equatable {
    public enum LineEnding: String, Equatable, CaseIterable {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"

        public var string: String { rawValue }

        /// "LF", "CRLF", "CR".
        public var name: String {
            switch self {
            case .lf: return "LF"
            case .crlf: return "CRLF"
            case .cr: return "CR"
            }
        }
    }

    /// A `[Section]` header line and what its block declares.
    public struct Header: Equatable {
        public var name: String
        /// 1-based line of the header.
        public var line: Int
        /// The block's `Meter=` value (as written, unquoted), if any.
        public var meter: String?
        /// The block's `Measure=` value, if any.
        public var measure: String?

        public init(name: String, line: Int, meter: String? = nil, measure: String? = nil) {
            self.name = name
            self.line = line
            self.meter = meter
            self.measure = measure
        }
    }

    /// The text as decoded (line endings untouched). Setting it rebuilds the line index.
    public var text: String {
        didSet { lineStarts = CodeDocument.lineStarts(of: text) }
    }
    public var encoding: TextFileEncoding
    /// The line ending the editor inserts: the most frequent one in the file when it was read (see
    /// `dominantLineEnding`).
    public var lineEnding: LineEnding
    /// UTF-16 offset of the start of every line (the first is 0; a text ending with a line break has a last,
    /// empty line starting at its end).
    public private(set) var lineStarts: [Int]

    public init(text: String, encoding: TextFileEncoding = .utf8(bom: false), lineEnding: LineEnding? = nil) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding ?? CodeDocument.dominantLineEnding(in: text)
        self.lineStarts = CodeDocument.lineStarts(of: text)
    }

    /// Decodes file bytes with `TextDecoding`'s detection (BOM, UTF-16 heuristics, UTF-8, ANSI code page).
    public init(data: Data) {
        let (text, encoding) = TextDecoding.decodeDetectingEncoding(data)
        self.init(text: text, encoding: encoding)
    }

    public static func load(_ url: URL) throws -> CodeDocument {
        CodeDocument(data: try Data(contentsOf: url))
    }

    // MARK: - Encoding

    /// Whether the file starts with a byte order mark (UTF-32 is only read and written with one).
    public var hasBOM: Bool {
        switch encoding {
        case .utf8(let bom), .utf16LittleEndian(let bom), .utf16BigEndian(let bom): return bom
        case .utf32LittleEndian, .utf32BigEndian: return true
        case .windows1252, .windowsCodePage: return false
        }
    }

    /// True for the legacy Windows "ANSI" code pages, which cannot hold every character.
    public var isANSI: Bool {
        switch encoding {
        case .windows1252, .windowsCodePage: return true
        default: return false
        }
    }

    /// A short name for the encoding: "UTF-8", "UTF-8 with BOM", "UTF-16 LE", "Windows-1252", "Windows-936"…
    public var encodingName: String {
        switch encoding {
        case .utf8(let bom): return bom ? "UTF-8 with BOM" : "UTF-8"
        case .utf16LittleEndian(let bom): return bom ? "UTF-16 LE" : "UTF-16 LE (no BOM)"
        case .utf16BigEndian(let bom): return bom ? "UTF-16 BE" : "UTF-16 BE (no BOM)"
        case .utf32LittleEndian: return "UTF-32 LE"
        case .utf32BigEndian: return "UTF-32 BE"
        case .windows1252: return "Windows-1252"
        case .windowsCodePage(let page): return "Windows-\(page)"
        }
    }

    /// The bytes of `text` in this document's encoding (with its BOM). Line endings are written exactly as they are in
    /// `text`. nil when an ANSI code page cannot represent a character of `text` (see `canEncode`).
    public func data(for text: String) -> Data? {
        TextDecoding.encode(text, as: encoding)
    }

    /// The bytes of the document's own text.
    public var data: Data? { data(for: text) }

    /// False when `text` has a character the document's ANSI code page cannot hold. Unicode encodings hold anything.
    public func canEncode(_ text: String) -> Bool {
        isANSI ? TextDecoding.encode(text, as: encoding) != nil : true
    }

    /// Switches an ANSI document to UTF-16 LE with BOM — the Unicode encoding Rainmeter skins conventionally use, and
    /// the one `IniWriter` falls back to — so any character can be saved. Unicode documents are left alone.
    public mutating func convertToUnicode() {
        if isANSI { encoding = .utf16LittleEndian(bom: true) }
    }

    /// Writes `text` to `url` (atomically) in this document's encoding; an ANSI document that cannot hold a
    /// character of `text` is converted to Unicode first (`convertToUnicode`), as `IniWriter` does.
    ///
    /// A symlink is followed and its target updated (see `writeTarget(for:)`), like `IniWriter` and
    /// `EditorFileChange`: an atomic write to the link itself would replace it with a regular file and leave the
    /// real file — e.g. in a git or synced folder the skin is linked from — silently stale.
    public mutating func write(_ text: String, to url: URL) throws {
        if !canEncode(text) { convertToUnicode() }
        let bytes = data(for: text) ?? Data(text.utf8)
        try bytes.write(to: CodeDocument.writeTarget(for: url), options: .atomic)
    }

    /// The file an edit of `url` must be written to: standardized with symlinks resolved, as `IniWriter` writes. A
    /// host that writes a buffer itself (the code editor's `onCommit`) writes here, not to the URL as listed.
    public static func writeTarget(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Line endings

    /// The most frequent line ending of `text` (CRLF counts once, not as a CR and an LF). Ties prefer CRLF, then
    /// LF; a text without line breaks gets CRLF, the Windows convention `IniWriter` also uses for new lines.
    public static func dominantLineEnding(in text: String) -> LineEnding {
        var crlf = 0, lf = 0, cr = 0
        var afterCR = false
        for unit in text.utf16 {
            if afterCR {
                afterCR = false
                if unit == 0x0A { crlf += 1; continue }
                cr += 1
            }
            if unit == 0x0D { afterCR = true } else if unit == 0x0A { lf += 1 }
        }
        if afterCR { cr += 1 }
        if crlf == 0 && lf == 0 && cr == 0 { return .crlf }
        if crlf >= lf && crlf >= cr { return .crlf }
        return lf >= cr ? .lf : .cr
    }

    // MARK: - Lines

    /// Number of lines, counting the empty line after a final line break.
    public var lineCount: Int { lineStarts.count }

    /// The 1-based line that contains the UTF-16 `offset` (clamped to the text). An offset right after a line break
    /// is on the next line.
    public func line(containingOffset offset: Int) -> Int {
        // Last line start <= offset (binary search).
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// UTF-16 offset of the start of a 1-based line (clamped to the first / last line).
    public func offset(ofLine line: Int) -> Int {
        lineStarts[min(max(line, 1), lineStarts.count) - 1]
    }

    /// UTF-16 range of a 1-based line (clamped), without its terminator unless `includingTerminator`.
    public func range(ofLine line: Int, includingTerminator: Bool = false) -> NSRange {
        let index = min(max(line, 1), lineStarts.count) - 1
        let start = lineStarts[index]
        let next = index + 1 < lineStarts.count ? lineStarts[index + 1] : text.utf16.count
        if includingTerminator { return NSRange(location: start, length: next - start) }
        var end = next
        if index + 1 < lineStarts.count {
            // Drop the terminator: LF, CR, or both of CRLF.
            let ns = text as NSString
            let last = ns.character(at: end - 1)
            end -= 1
            if last == 0x0A, end > start, ns.character(at: end - 1) == 0x0D { end -= 1 }
        }
        return NSRange(location: start, length: end - start)
    }

    /// UTF-16 range covering 1-based `lines` (whole lines with their terminators), clamped to the text.
    public func range(ofLines lines: Range<Int>) -> NSRange {
        let length = text.utf16.count
        let start = lines.lowerBound <= 1 ? 0 : (lines.lowerBound > lineCount ? length : offset(ofLine: lines.lowerBound))
        let end = lines.upperBound > lineCount ? length : max(start, offset(ofLine: lines.upperBound))
        return NSRange(location: start, length: end - start)
    }

    static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        var afterCR = false
        for unit in text.utf16 {
            if afterCR {
                afterCR = false
                if unit == 0x0A {
                    offset += 1
                    starts.append(offset)
                    continue
                }
                starts.append(offset)
            }
            offset += 1
            if unit == 0x0D { afterCR = true } else if unit == 0x0A { starts.append(offset) }
        }
        if afterCR { starts.append(offset) }
        return starts
    }

    // MARK: - Sections

    /// Every `[Section]` header in file order, repeated ones included (the reader ignores a repeated section; the
    /// jump bar still lists it so it can be found). `[]` is left out.
    public func sectionHeaders() -> [Header] {
        outline().headers
    }

    /// The name of the section whose block contains the 1-based `line`, or nil before the first header (and inside a
    /// `[]` block). Comment lines right above a header belong to that header's section, as in
    /// `IniWriter.movingSection`; other lines belong to the header above them.
    public func section(containingLine line: Int) -> String? {
        let o = outline()
        guard line >= 1, !o.kinds.isEmpty else { return nil }
        return o.owner(ofLine: min(line, o.kinds.count))
    }

    /// The 1-based lines of the first `[name]` block (the one the reader uses; names are case-insensitive): from its
    /// header to the next header, without the comment lines that introduce the next section and without trailing
    /// blank lines. nil when there is no such section.
    public func lineRange(ofSection name: String) -> Range<Int>? {
        let o = outline()
        guard let k = o.headerLines.firstIndex(where: { $0.name.map { IniSyntax.namesEqual($0, name) } ?? false }) else {
            return nil
        }
        return o.block(k)
    }

    // MARK: - Outline

    private enum LineKind { case blank, comment, header, other }

    private struct Outline {
        var kinds: [LineKind] = []
        /// Every header line (1-based) with its name (nil for `[]`).
        var headerLines: [(name: String?, line: Int)] = []
        var headers: [Header] = []

        /// Lines [header, end) of the k-th header's block.
        func block(_ k: Int) -> Range<Int> {
            let start = headerLines[k].line
            var end = k + 1 < headerLines.count ? headerLines[k + 1].line : kinds.count + 1
            if k + 1 < headerLines.count {
                while end - 1 > start, kinds[end - 2] == .comment { end -= 1 }
            }
            while end - 1 > start, kinds[end - 2] == .blank { end -= 1 }
            return start..<end
        }

        func owner(ofLine line: Int) -> String? {
            guard !kinds.isEmpty, line >= 1 else { return nil }
            var l = line
            // A run of comment lines that ends right at a header introduces that header.
            if kinds[l - 1] == .comment {
                var next = l
                while next < kinds.count, kinds[next] == .comment { next += 1 }
                if next < kinds.count, kinds[next] == .header { l = next + 1 }
            }
            guard let k = headerLines.lastIndex(where: { $0.line <= l }) else { return nil }
            return headerLines[k].name
        }
    }

    private func outline() -> Outline {
        var o = Outline()
        var current: Int?
        IniSyntax.forEachLine(in: text) { raw in
            let line = o.kinds.count + 1
            switch IniSyntax.classify(raw) {
            case .blank:
                o.kinds.append(.blank)
            case .comment:
                o.kinds.append(.comment)
            case .other:
                o.kinds.append(.other)
            case .section(let name):
                o.kinds.append(.header)
                o.headerLines.append((name.map(String.init), line))
                current = nil
                if let name {
                    o.headers.append(Header(name: String(name), line: line))
                    current = o.headers.count - 1
                }
            case .entry(let key, let value):
                o.kinds.append(.other)
                guard let current else { break }
                if o.headers[current].meter == nil, IniSyntax.namesEqual(key, "Meter") {
                    o.headers[current].meter = String(IniSyntax.unquote(value))
                } else if o.headers[current].measure == nil, IniSyntax.namesEqual(key, "Measure") {
                    o.headers[current].measure = String(IniSyntax.unquote(value))
                }
            }
        }
        // The empty line after a final line break (or of an empty text) is a blank line of the editor.
        while o.kinds.count < lineCount { o.kinds.append(.blank) }
        return o
    }
}
