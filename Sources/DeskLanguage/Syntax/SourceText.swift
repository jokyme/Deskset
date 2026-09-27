import Foundation

/// Which file a tree, a diagnostic or an edit belongs to: a path relative to the widget folder (`"CPU.desk"`,
/// `"package.desk"`).
public struct DeskFileID: Sendable, Hashable, CustomStringConvertible {
    public var path: String

    public init(path: String) {
        self.path = path
    }

    public init(_ path: String) {
        self.path = path
    }

    public var description: String { path }
}

/// The result of turning a file's bytes into text (`Desk.load`).
public enum LoadResult: Sendable {
    /// Valid UTF-8, decoded without dropping a byte order mark.
    case text(String, file: DeskFileID)
    /// Not UTF-8 (DK1008); nothing else is parsed.
    case rejected(Diagnostic)
}

/// A position in a file. `line` and `column` are 1-based; `column` counts grapheme clusters (what a person sees,
/// used in messages) and `utf16Column` counts UTF-16 code units from the start of the line, also 1-based, for
/// text views.
public struct SourceLocation: Sendable, Hashable, CustomStringConvertible {
    public var utf8Offset: Int
    public var line: Int
    public var column: Int
    public var utf16Column: Int

    public init(utf8Offset: Int, line: Int, column: Int, utf16Column: Int) {
        self.utf8Offset = utf8Offset
        self.line = line
        self.column = column
        self.utf16Column = utf16Column
    }

    public var description: String { "\(line):\(column)" }
}

/// The start offset of every line of a text, for turning UTF-8 offsets into lines and columns. A line break is
/// LF, CR LF or a lone CR.
final class LineTable: @unchecked Sendable {
    let bytes: [UInt8]
    /// UTF-8 offset of the first byte of each line; `starts[0] == 0`.
    let starts: [Int]
    /// The file's most frequent line break (LF when tied), for the line breaks fix-its insert.
    let newline: String

    init(bytes: [UInt8]) {
        self.bytes = bytes
        var starts = [0]
        var i = 0
        let n = bytes.count
        var lf = 0
        var crlf = 0
        var cr = 0
        while i < n {
            let b = bytes[i]
            if b == 0x0A {
                starts.append(i + 1)
                lf += 1
            } else if b == 0x0D {
                if i + 1 < n, bytes[i + 1] == 0x0A { i += 1; crlf += 1 } else { cr += 1 }
                starts.append(i + 1)
            }
            i += 1
        }
        self.starts = starts
        newline = crlf > lf && crlf >= cr ? "\r\n" : cr > lf && cr > crlf ? "\r" : "\n"
    }

    /// 0-based line index of `offset` (offsets past the end belong to the last line).
    func lineIndex(of offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The offset where the line's content ends (before its line break).
    func contentEnd(ofLine line: Int) -> Int {
        var end = line + 1 < starts.count ? starts[line + 1] : bytes.count
        if end > starts[line], end - 1 < bytes.count, bytes[end - 1] == 0x0A { end -= 1 }
        if end > starts[line], end - 1 < bytes.count, bytes[end - 1] == 0x0D { end -= 1 }
        return end
    }

    func location(of rawOffset: Int) -> SourceLocation {
        let offset = max(0, min(rawOffset, bytes.count))
        let line = lineIndex(of: offset)
        let start = starts[line]
        // Only whole scalars are counted: an offset inside a scalar counts up to the scalar before it.
        var end = offset
        while end > start, end < bytes.count, (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        let prefix = String(decoding: bytes[start..<end], as: UTF8.self)
        return SourceLocation(utf8Offset: offset, line: line + 1, column: prefix.count + 1,
                              utf16Column: prefix.utf16.count + 1)
    }

    /// Width of the leading blanks of a line, a tab advancing to the next multiple of 4 columns.
    func indentation(ofLine line: Int) -> Int {
        var i = starts[line]
        var width = 0
        while i < bytes.count {
            switch bytes[i] {
            case 0x20: width += 1
            case 0x09: width = (width / 4 + 1) * 4
            default: return width
            }
            i += 1
        }
        return width
    }
}

/// UTF-8 validation for `Desk.load`: the offset of the first byte that is not part of a valid UTF-8 sequence
/// (overlong forms, surrogates and values above U+10FFFF are invalid), or nil.
func firstInvalidUTF8Offset(_ bytes: [UInt8]) -> Int? {
    var i = 0
    let n = bytes.count
    while i < n {
        let b0 = bytes[i]
        if b0 < 0x80 { i += 1; continue }
        let length: Int
        var minimum: UInt32
        var scalar: UInt32
        switch b0 {
        case 0xC2...0xDF: length = 2; scalar = UInt32(b0 & 0x1F); minimum = 0x80
        case 0xE0...0xEF: length = 3; scalar = UInt32(b0 & 0x0F); minimum = 0x800
        case 0xF0...0xF4: length = 4; scalar = UInt32(b0 & 0x07); minimum = 0x10000
        default: return i
        }
        if i + length > n { return i }
        for k in 1..<length {
            let b = bytes[i + k]
            if b & 0xC0 != 0x80 { return i }
            scalar = (scalar << 6) | UInt32(b & 0x3F)
        }
        if scalar < minimum || scalar > 0x10FFFF || (0xD800...0xDFFF).contains(scalar) { return i }
        i += length
    }
    return nil
}
