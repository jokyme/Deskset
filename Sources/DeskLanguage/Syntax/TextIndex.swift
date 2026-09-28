import Foundation

/// Converts between the three ways of pointing into a text: UTF-8 offsets (the syntax tree's and the checker's),
/// UTF-16 offsets (`NSString`, `NSRange`, text views) and 0-based (line, UTF-16 column) pairs. A line break is LF,
/// CR LF or a lone CR, as for `SourceLocation` (U+2028, U+2029 and U+0085 are ordinary characters). A byte order mark
/// kept at the start of the text is an ordinary character: one UTF-16 unit, three UTF-8 bytes.
///
/// Every conversion clamps: an offset before the start or past the end goes to the start or the end, an offset inside
/// a scalar (inside its UTF-8 bytes, or between the two halves of a surrogate pair) goes to the start of that scalar,
/// and a column past the end of its line goes to the end of the line's content (before its line break). Lines of
/// ASCII text convert by arithmetic; other lines are walked from their start.
public struct DeskTextIndex: Sendable {
    /// The UTF-8 bytes of the text.
    let bytes: [UInt8]
    /// UTF-8 offset of the first byte of each line; `starts8[0] == 0`.
    let starts8: [Int]
    /// UTF-16 offset of the first unit of each line.
    let starts16: [Int]
    /// Lines whose bytes, line break included, are all ASCII.
    let asciiLines: [Bool]
    /// The length of the text in UTF-16 units.
    public let utf16Count: Int

    public init(_ text: String) {
        self.init(bytes: Array(text.utf8))
    }

    /// The index of a tree's text (sharing its bytes).
    public init(tree: SyntaxTree) {
        self.init(bytes: tree.lines.bytes)
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
        var starts8 = [0]
        var starts16 = [0]
        var asciiLines: [Bool] = []
        var units = 0
        bytes.withUnsafeBufferPointer { buffer in
            let n = buffer.count
            var lineIsASCII = true
            var i = 0
            while i < n {
                let b = buffer[i]
                if b < 0x80 {
                    units += 1
                    if b == 0x0A || b == 0x0D {
                        if b == 0x0D, i + 1 < n, buffer[i + 1] == 0x0A {
                            i += 1
                            units += 1
                        }
                        starts8.append(i + 1)
                        starts16.append(units)
                        asciiLines.append(lineIsASCII)
                        lineIsASCII = true
                    }
                } else {
                    lineIsASCII = false
                    // A lead byte starts a scalar: four-byte scalars take a surrogate pair.
                    if b & 0xC0 != 0x80 { units += b >= 0xF0 ? 2 : 1 }
                }
                i += 1
            }
            asciiLines.append(lineIsASCII)
        }
        self.starts8 = starts8
        self.starts16 = starts16
        self.asciiLines = asciiLines
        self.utf16Count = units
    }

    /// The length of the text in UTF-8 bytes.
    public var utf8Count: Int { bytes.count }

    /// The number of lines: one more than the number of line breaks.
    public var lineCount: Int { starts8.count }

    // MARK: Offsets

    /// A UTF-8 offset clamped to the text and to the start of the scalar it falls in.
    public func clampedUTF8(_ offset: Int) -> Int {
        var o = max(0, min(offset, bytes.count))
        while o > 0, o < bytes.count, bytes[o] & 0xC0 == 0x80 { o -= 1 }
        return o
    }

    /// A UTF-16 offset clamped to the text and to the start of the surrogate pair it falls in.
    public func clampedUTF16(_ offset: Int) -> Int {
        utf16Offset(ofUTF8: utf8Offset(ofUTF16: offset))
    }

    /// The UTF-16 offset of a UTF-8 offset.
    public func utf16Offset(ofUTF8 offset: Int) -> Int {
        let o = clampedUTF8(offset)
        let line = line(ofUTF8: o)
        return starts16[line] + utf16Length(from: starts8[line], to: o, ascii: asciiLines[line])
    }

    /// The UTF-8 offset of a UTF-16 offset.
    public func utf8Offset(ofUTF16 offset: Int) -> Int {
        let o = max(0, min(offset, utf16Count))
        let line = line(ofUTF16: o)
        return utf8Offset(inLine: line, utf16Column: o - starts16[line])
    }

    public func utf16Range(ofUTF8 range: Range<Int>) -> Range<Int> {
        let lower = utf16Offset(ofUTF8: range.lowerBound)
        return lower..<max(lower, utf16Offset(ofUTF8: range.upperBound))
    }

    public func utf8Range(ofUTF16 range: Range<Int>) -> Range<Int> {
        let lower = utf8Offset(ofUTF16: range.lowerBound)
        return lower..<max(lower, utf8Offset(ofUTF16: range.upperBound))
    }

    // MARK: Lines and columns

    /// The 0-based line and UTF-16 column of a UTF-16 offset. An offset between the CR and the LF of a CR LF is on
    /// the line the CR ends.
    public func lineAndColumn(ofUTF16 offset: Int) -> (line: Int, column: Int) {
        let o = clampedUTF16(offset)
        let line = line(ofUTF16: o)
        return (line, o - starts16[line])
    }

    /// The 0-based line and UTF-16 column of a UTF-8 offset.
    public func lineAndColumn(ofUTF8 offset: Int) -> (line: Int, column: Int) {
        let o = clampedUTF8(offset)
        let line = line(ofUTF8: o)
        return (line, utf16Length(from: starts8[line], to: o, ascii: asciiLines[line]))
    }

    /// The UTF-16 offset of a 0-based line and UTF-16 column. A line past the last is the end of the text; a line
    /// before the first is the start. (The offset between a CR and its LF has a column one past the line's content;
    /// that column comes back as the end of the content.)
    public func utf16Offset(line: Int, column: Int) -> Int {
        guard line >= 0 else { return 0 }
        guard line < lineCount else { return utf16Count }
        let column = max(0, min(column, contentEnd16(ofLine: line) - starts16[line]))
        return utf16Offset(ofUTF8: utf8Offset(inLine: line, utf16Column: column))
    }

    /// The UTF-8 offset of a 0-based line and UTF-16 column.
    public func utf8Offset(line: Int, column: Int) -> Int {
        utf8Offset(ofUTF16: utf16Offset(line: line, column: column))
    }

    /// The UTF-16 range of a line's content, without its line break.
    public func utf16ContentRange(ofLine line: Int) -> Range<Int> {
        let line = max(0, min(line, lineCount - 1))
        return starts16[line]..<contentEnd16(ofLine: line)
    }

    /// The UTF-16 range of a line with its line break.
    public func utf16Range(ofLine line: Int) -> Range<Int> {
        let line = max(0, min(line, lineCount - 1))
        return starts16[line]..<(line + 1 < lineCount ? starts16[line + 1] : utf16Count)
    }

    /// The UTF-8 range of a line with its line break.
    public func utf8Range(ofLine line: Int) -> Range<Int> {
        let line = max(0, min(line, lineCount - 1))
        return starts8[line]..<(line + 1 < lineCount ? starts8[line + 1] : bytes.count)
    }

    /// The UTF-8 offset where a line's content ends (before its line break).
    public func utf8ContentEnd(ofLine line: Int) -> Int {
        let line = max(0, min(line, lineCount - 1))
        var end = line + 1 < lineCount ? starts8[line + 1] : bytes.count
        if end > starts8[line], bytes[end - 1] == 0x0A { end -= 1 }
        if end > starts8[line], bytes[end - 1] == 0x0D { end -= 1 }
        return end
    }

    /// The 0-based line of a UTF-8 offset.
    public func line(ofUTF8 offset: Int) -> Int {
        Self.search(starts8, max(0, min(offset, bytes.count)))
    }

    /// The 0-based line of a UTF-16 offset.
    public func line(ofUTF16 offset: Int) -> Int {
        Self.search(starts16, max(0, min(offset, utf16Count)))
    }

    /// The UTF-16 offset, 0-based line and UTF-16 column of each UTF-8 offset, in one pass: the offsets must not
    /// decrease. Each is clamped as `utf16Offset(ofUTF8:)` clamps it; the results equal `lineAndColumn(ofUTF8:)`'s.
    ///
    /// Columns are counted on from the previous offset of the same line, so many offsets on one long line that is not
    /// ASCII cost one walk of the line, not one each.
    public func positions(ofAscendingUTF8 offsets: [Int]) -> [(utf16: Int, line: Int, column: Int)] {
        guard let first = offsets.first else { return [] }
        var out: [(utf16: Int, line: Int, column: Int)] = []
        out.reserveCapacity(offsets.count)
        var line = self.line(ofUTF8: clampedUTF8(first))
        // The column of `counted`, a scalar start on `line`.
        var counted = starts8[line]
        var column = 0
        let lines = lineCount
        for offset in offsets {
            let o = clampedUTF8(offset)
            if o < starts8[line] {
                line = self.line(ofUTF8: o)
                counted = starts8[line]
                column = 0
            }
            if line + 1 < lines, starts8[line + 1] <= o {
                while line + 1 < lines, starts8[line + 1] <= o { line += 1 }
                counted = starts8[line]
                column = 0
            }
            if o < counted {
                counted = starts8[line]
                column = 0
            }
            column += utf16Length(from: counted, to: o, ascii: asciiLines[line])
            counted = o
            out.append((starts16[line] + column, line, column))
        }
        return out
    }

    // MARK: Private

    private func contentEnd16(ofLine line: Int) -> Int {
        let next = line + 1 < lineCount ? starts16[line + 1] : utf16Count
        let breakBytes = (line + 1 < lineCount ? starts8[line + 1] : bytes.count) - utf8ContentEnd(ofLine: line)
        // Line breaks are ASCII: one UTF-16 unit per byte.
        return next - breakBytes
    }

    /// UTF-16 units of the bytes `from..<to` (both at scalar starts).
    private func utf16Length(from: Int, to: Int, ascii: Bool) -> Int {
        if ascii || to <= from { return max(0, to - from) }
        var units = 0
        bytes.withUnsafeBufferPointer { buffer in
            for i in from..<to {
                let b = buffer[i]
                if b & 0xC0 != 0x80 { units += b >= 0xF0 ? 2 : 1 }
            }
        }
        return units
    }

    /// The UTF-8 offset `column` UTF-16 units into `line` (a column inside a surrogate pair goes to the pair's start;
    /// the walk does not stop at the line's end, so the caller clamps).
    private func utf8Offset(inLine line: Int, utf16Column column: Int) -> Int {
        let start = starts8[line]
        if asciiLines[line] { return min(start + max(0, column), bytes.count) }
        var units = 0
        var i = start
        bytes.withUnsafeBufferPointer { buffer in
            let n = buffer.count
            while units < column, i < n {
                let b = buffer[i]
                let length: Int
                let width: Int
                if b < 0x80 { length = 1; width = 1 } else if b < 0xE0 { length = 2; width = 1 } else if b < 0xF0 {
                    length = 3; width = 1
                } else { length = 4; width = 2 }
                if units + width > column { break }
                units += width
                i += length
            }
        }
        return i
    }

    /// The last index whose start is at or before `offset`.
    private static func search(_ starts: [Int], _ offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
