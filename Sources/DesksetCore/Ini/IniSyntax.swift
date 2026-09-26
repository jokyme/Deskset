import Foundation

/// Line-level INI syntax shared by `IniDocument.parse`, `SkinFileLoader` and `IniWriter`, so that reading, merging
/// and writing agree on exactly the same rules.
///
/// Rules (docs.rainmeter.net/manual/skins/, …/getting-started/skin-anatomy/, …/skins/include-option/):
/// - A skin file has three kinds of lines: `[SectionName]`, `OptionName=Option Value` and `;Comment`.
/// - Option values are kept on a single line (no continuation lines).
/// - "Rainmeter will ignore quotes around option values."
/// - "If both [sections] are in the actual .ini file, the second one is entirely ignored."
/// - Section and option names are case-insensitive.
enum IniSyntax {
    enum Line {
        case blank
        case comment
        /// A section header. `name` is trimmed; nil when the brackets hold no name (`[]`).
        case section(name: Substring?)
        /// `key` is trimmed; `value` is trimmed but still quoted (see `unquote`).
        case entry(key: Substring, value: Substring)
        /// Anything else (a line without `=`, or `=value` with an empty key). Ignored by the reader.
        case other
    }

    // MARK: - Whitespace

    /// Only ASCII blanks (and a stray BOM) are trimmed. The manual says nothing about Unicode spaces; a Windows INI
    /// reader trims spaces/tabs only, so e.g. a value consisting of an ideographic space (U+3000) is kept as written.
    @inline(__always)
    static func isBlank(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x20, 0x09, 0x0B, 0x0C, 0xFEFF: return true
        default: return false
        }
    }

    static func trim(_ s: Substring) -> Substring {
        let scalars = s.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, isBlank(scalars[start]) { start = scalars.index(after: start) }
        while end > start {
            let before = scalars.index(before: end)
            if isBlank(scalars[before]) { end = before } else { break }
        }
        return Substring(scalars[start..<end])
    }

    static func trim(_ s: String) -> String { String(trim(Substring(s))) }

    // MARK: - Quotes

    /// "Rainmeter will ignore quotes around option values": one pair of identical quote characters wrapping the whole
    /// (already trimmed) value is removed; nothing else is touched.
    ///
    /// Both `"` and `'` count. The manual only shows double quotes here, but the Substitute page documents that
    /// `'pattern':'replacement'` does not work while `'pattern':"replacement"` and `"pattern":'replacement'` do,
    /// which is exactly what happens when a matching pair of single quotes around the whole value is stripped
    /// (`'a':'b'` → `a':'b`). Only a single pair is removed: `"""x"""` → `""x""`. The same-character check means
    /// `"a'` is left alone. Consequence for other modules: `Substitute="a":"b"` arrives as `a":"b`.
    static func unquote(_ value: Substring) -> Substring {
        let scalars = value.unicodeScalars
        guard let first = scalars.first, let last = scalars.last,
              first == "\"" || first == "'", first == last else { return value }
        let afterFirst = scalars.index(after: scalars.startIndex)
        let beforeLast = scalars.index(before: scalars.endIndex)
        guard afterFirst <= beforeLast else { return value } // a single quote character
        return Substring(scalars[afterFirst..<beforeLast])
    }

    // MARK: - Lines

    /// Classifies one line (without its terminator).
    static func classify(_ raw: Substring) -> Line {
        // Work on scalars, not Characters: a combining mark right after `=` or `]` must not hide the separator.
        let scalars = trim(raw).unicodeScalars
        guard let first = scalars.first else { return .blank }
        if first == ";" { return .comment }
        if first == "[" {
            // `[Name]`: the name ends at the first `]`; anything after it on the line is ignored. The manual says
            // section names should be alphanumeric, so a `]` inside a name is not supported. An unterminated
            // `[Name` is still taken as a header (judgment call: the author clearly meant a section, and treating it
            // otherwise would silently attach the following keys to the previous section).
            let afterBracket = scalars.index(after: scalars.startIndex)
            let nameEnd = scalars[afterBracket...].firstIndex(of: "]") ?? scalars.endIndex
            let name = trim(Substring(scalars[afterBracket..<nameEnd]))
            return .section(name: name.isEmpty ? nil : name)
        }
        guard let eq = scalars.firstIndex(of: "=") else { return .other }
        let key = trim(Substring(scalars[..<eq]))
        if key.isEmpty { return .other }
        return .entry(key: key, value: trim(Substring(scalars[scalars.index(after: eq)...])))
    }

    /// Calls `body` with every line of `text` (without terminator). Lines end at `\r\n`, `\r` or `\n` only —
    /// Unicode separators such as U+2028 or U+0085 are part of the line, as in a Windows INI file.
    static func forEachLine(in text: String, _ body: (Substring) -> Void) {
        forEachLineWithTerminator(in: text) { content, _ in body(content) }
    }

    /// Like `forEachLine`, also passing the terminator (`"\r\n"`, `"\r"`, `"\n"` or `""` for a final unterminated
    /// line). An empty text yields no lines; a text ending with a terminator yields no trailing empty line.
    static func forEachLineWithTerminator(in text: String, _ body: (Substring, Substring) -> Void) {
        var text = text
        text.makeContiguousUTF8() // no-op for native strings; makes bridged NSStrings cheap to scan
        // CR and LF bytes never occur inside a multi-byte UTF-8 sequence, so scanning the UTF-8 view is safe and
        // every index found is a valid scalar boundary of `text`.
        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        var i = lineStart
        while i < utf8.endIndex {
            let byte = utf8[i]
            if byte == 0x0A || byte == 0x0D {
                var next = utf8.index(after: i)
                if byte == 0x0D, next < utf8.endIndex, utf8[next] == 0x0A { next = utf8.index(after: next) }
                body(text[lineStart..<i], text[i..<next])
                lineStart = next
                i = next
            } else {
                i = utf8.index(after: i)
            }
        }
        if lineStart < utf8.endIndex { body(text[lineStart..<utf8.endIndex], text[utf8.endIndex...]) }
    }

    // MARK: - Names

    /// Case-insensitive equality of section / option names. ASCII fast path without allocation (names are almost
    /// always ASCII); otherwise compares `lowercased()` so it agrees with the lowercased dictionary keys used
    /// everywhere else.
    static func namesEqual<A: StringProtocol, B: StringProtocol>(_ a: A, _ b: B) -> Bool {
        var ia = a.utf8.makeIterator()
        var ib = b.utf8.makeIterator()
        while true {
            let ca = ia.next()
            let cb = ib.next()
            guard let x = ca, let y = cb else { return ca == nil && cb == nil }
            if x >= 0x80 || y >= 0x80 { return a.lowercased() == b.lowercased() }
            if x == y { continue }
            let lx = x | 0x20
            if x ^ y == 0x20, lx >= 0x61, lx <= 0x7A { continue }
            return false
        }
    }

    /// `@Include`, `@Include2`, `@IncludeVariables`…: "The option must only start with @Include" (any case).
    static func isIncludeKey<S: StringProtocol>(_ key: S) -> Bool {
        let prefix = "@include".utf8
        var it = key.utf8.makeIterator()
        for p in prefix {
            guard let c = it.next() else { return false }
            let lower = (c >= 0x41 && c <= 0x5A) ? c | 0x20 : c
            if lower != p { return false }
        }
        return true
    }

    // MARK: - Whole files

    struct RawSection {
        var name: String
        /// Entries in file order after the within-file rules (first definition of a key wins). `@Include…` keys are
        /// kept in place so the loader can expand them at their position.
        var entries: [IniEntry]
        /// 1-based line of each entry (parallel to `entries`), for the inspector's source locations.
        var entryLines: [Int] = []
        /// 1-based line of the `[Section]` header.
        var headerLine = 0
    }

    struct ParsedFile {
        /// Sections in file order; a repeated `[Section]` in the same file is dropped entirely.
        var sections: [RawSection] = []
        /// `Key=Value` lines that appear before the first section header (ignored by Rainmeter's INI rules).
        var entriesBeforeFirstSection: [IniEntry] = []
    }

    /// Parses one file's text with the rules of a single INI file.
    ///
    /// - Duplicate sections: "If both are in the actual .ini file, the second one is entirely ignored" (manual,
    ///   @Include page) — its keys, including any `@Include` in it, are skipped.
    /// - Duplicate keys in one section: the manual only says option names "must be unique"; by analogy with the
    ///   section rule the first definition wins and later ones are ignored.
    /// - Keys before any section header, lines without `=` and lines with an empty key are ignored.
    static func parseFile(_ text: String) -> ParsedFile {
        var file = ParsedFile()
        var seenSections: Set<String> = []
        var seenKeys: Set<String> = []
        var current: Int?          // index into file.sections, nil while inside an ignored block
        var beforeFirstSection = true
        var lineNumber = 0

        forEachLine(in: text) { raw in
            lineNumber += 1
            switch classify(raw) {
            case .blank, .comment, .other:
                break
            case .section(let name):
                beforeFirstSection = false
                current = nil
                seenKeys.removeAll(keepingCapacity: true)
                // `[]` (no name): judgment call — its keys are ignored rather than attached to the previous section.
                guard let name else { break }
                let lower = name.lowercased()
                if seenSections.insert(lower).inserted {
                    file.sections.append(RawSection(name: String(name), entries: [], headerLine: lineNumber))
                    current = file.sections.count - 1
                }
            case .entry(let key, let value):
                let entry = IniEntry(key: String(key), value: String(unquote(value)))
                if beforeFirstSection {
                    file.entriesBeforeFirstSection.append(entry)
                } else if let current, seenKeys.insert(key.lowercased()).inserted {
                    file.sections[current].entries.append(entry)
                    file.sections[current].entryLines.append(lineNumber)
                }
            }
        }
        return file
    }
}
