import Foundation

public enum IniWriterError: Error, Equatable, CustomStringConvertible {
    /// "The file must exist" (manual, !WriteKeyValue).
    case fileNotFound(String)
    /// Empty, or contains `]` or a line break — it could not be read back as the same section.
    case invalidSectionName(String)
    /// Empty, contains `=` or a line break, or starts with `[` or `;` — it could not be read back as the same key.
    case invalidKeyName(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path): return "file not found: \(path)"
        case .invalidSectionName(let name): return "invalid section name: \"\(name)\""
        case .invalidKeyName(let name): return "invalid key name: \"\(name)\""
        }
    }
}

/// Writes single `Key=Value` pairs into INI files, for `!WriteKeyValue`.
///
/// Manual (Bangs → !WriteKeyValue Section, Key, Value, FilePath): "Permanently writes a Key=Value pair below a
/// section in a INI formatted file … If the section does not exist in the file, a new section will be written at the
/// end of the file. If the key does not exist under the section, a new key will be written at the end of the section.
/// … Any previous value will be overwritten. … The file must exist and must be located under either #SKINSPATH# or
/// #SETTINGSPATH#." (Use `isPathAllowed(_:roots:)` for the location check.) "A skin must be refreshed for a new value
/// written to the skin's .ini or .inc files to be re-read."
///
/// Everything else in the file is preserved byte for byte: encoding (and BOM), line endings, comments, blank lines,
/// ordering and the spelling/spacing of the updated line's key.
public enum IniWriter {
    /// Updates the first `key` (case-insensitive) in the first `[section]` of the file — the occurrence a reader
    /// uses, since a repeated section in the same file is ignored — or appends the key at the end of that section,
    /// or appends the section at the end of the file. Nothing is written when the text would not change.
    ///
    /// The file keeps its encoding; an ANSI (Windows code page) file that cannot represent the new value is converted
    /// to UTF-16 LE with BOM (the Unicode encoding Rainmeter skins conventionally use). A symlink is followed and its
    /// target updated.
    public static func writeValue(_ value: String, key: String, section: String, fileURL: URL) throws {
        let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw IniWriterError.fileNotFound(fileURL.path)
        }
        let (text, encoding) = try TextDecoding.readFileDetectingEncoding(at: target)
        let updated = try updating(text, value: value, key: key, section: section)
        // Compare bytes, not `==`: String equality is canonical equivalence, so an NFC → NFD change would be skipped.
        if updated.utf8.elementsEqual(text.utf8) { return }
        let data = TextDecoding.encodeForWriting(updated, preferring: encoding)
        try data.write(to: target, options: .atomic)
    }

    /// The text-level operation behind `writeValue`: returns `text` with `key=value` set in `[section]`.
    /// Only the updated line changes (or new lines are inserted); all other characters are kept exactly.
    ///
    /// Value handling (the manual is silent): line breaks in `value` become spaces (option values must stay on one
    /// line), and a value with leading or trailing spaces/tabs is wrapped in double quotes because a reader trims
    /// unquoted values, so it reads back unchanged. Any other value is written exactly as given — including one that
    /// is itself wrapped in a pair of quotes (`"x"`), which a reader then strips like any quoted value, as it would
    /// for a hand-written `Key="x"` (skins use this to store `"  padded  "` text).
    ///
    /// Names are validated per Unicode scalar, the way the reader splits lines, so a combining mark after `=`, `]`,
    /// `[` or `;` cannot sneak a separator past the check.
    public static func updating(_ text: String, value: String, key: String, section: String) throws -> String {
        let sectionName = IniSyntax.trim(section)
        let keyName = IniSyntax.trim(key)
        let sectionScalars = sectionName.unicodeScalars
        if sectionName.isEmpty || sectionScalars.contains("]") || containsLineBreak(sectionName) {
            throw IniWriterError.invalidSectionName(section)
        }
        let keyScalars = keyName.unicodeScalars
        if keyName.isEmpty || keyScalars.contains("=") || containsLineBreak(keyName)
            || keyScalars.first == "[" || keyScalars.first == ";" {
            throw IniWriterError.invalidKeyName(key)
        }
        let written = encodeValue(value)

        var lines: [(content: Substring, terminator: Substring)] = []
        IniSyntax.forEachLineWithTerminator(in: text) { lines.append(($0, $1)) }
        let newline: Substring = lines.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\r\n"

        var headerIndex: Int?
        var lastContentIndex = 0
        var keyIndex: Int?
        scan: for (i, line) in lines.enumerated() {
            switch IniSyntax.classify(line.content) {
            case .section(let name):
                if headerIndex != nil { break scan } // end of the first block of the target section
                if let name, IniSyntax.namesEqual(name, sectionName) {
                    headerIndex = i
                    lastContentIndex = i
                }
            case .entry(let k, _):
                guard headerIndex != nil else { continue }
                lastContentIndex = i
                if IniSyntax.namesEqual(k, keyName) {
                    keyIndex = i
                    break scan
                }
            case .other:
                if headerIndex != nil { lastContentIndex = i }
            case .blank, .comment:
                break
            }
        }

        var out = ""
        out.reserveCapacity(text.utf8.count + written.utf8.count + keyName.utf8.count + sectionName.utf8.count + 8)

        if let keyIndex {
            for (i, line) in lines.enumerated() {
                if i == keyIndex {
                    out += replacingValue(in: line.content, with: written)
                } else {
                    out += line.content
                }
                out += line.terminator
            }
            return out
        }

        let newEntry = keyName + "=" + written
        if headerIndex != nil {
            for (i, line) in lines.enumerated() {
                out += line.content
                if i == lastContentIndex {
                    let isLastLine = i == lines.count - 1
                    if line.terminator.isEmpty {
                        // Last line of a file without a final line break: keep it that way.
                        out += newline
                        out += newEntry
                    } else {
                        out += line.terminator
                        out += newEntry
                        out += isLastLine ? line.terminator : newline
                    }
                } else {
                    out += line.terminator
                }
            }
            return out
        }

        // The section does not exist: append it at the end of the file, separated by a blank line.
        out += text
        if let last = lines.last {
            if last.terminator.isEmpty { out += newline }
            if !IniSyntax.trim(last.content).isEmpty { out += newline }
        }
        out += "[" + sectionName + "]"
        out += newline
        out += newEntry
        out += newline
        return out
    }

    /// True when `fileURL` (symlinks resolved) is inside one of `roots` (e.g. #SKINSPATH# and #SETTINGSPATH#).
    /// The comparison is case-insensitive, like the default macOS file system.
    public static func isPathAllowed(_ fileURL: URL, roots: [URL]) -> Bool {
        guard let path = canonicalPath(fileURL) else { return false }
        for root in roots {
            guard let rootPath = canonicalPath(root) else { continue }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if path == rootPath || path.hasPrefix(prefix) { return true }
        }
        return false
    }

    // MARK: - Helpers

    /// `..` is collapsed textually first (as `writeValue` does), then symlinks are resolved physically with
    /// `realpath` on the deepest existing ancestor (the file itself may not exist yet), lowercased.
    private static func canonicalPath(_ url: URL) -> String? {
        var path = url.standardizedFileURL.path
        var missing: [String] = []
        let fm = FileManager.default
        // attributesOfItem does not follow symlinks, so a dangling symlink counts as existing (and then fails below).
        while path != "/", !path.isEmpty, (try? fm.attributesOfItem(atPath: path)) == nil {
            missing.insert((path as NSString).lastPathComponent, at: 0)
            path = (path as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(path, nil) else { return nil }
        path = String(cString: resolved)
        free(resolved)
        for component in missing {
            path = (path as NSString).appendingPathComponent(component)
        }
        return path.lowercased()
    }

    private static func containsLineBreak(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    private static func encodeValue(_ value: String) -> String {
        var v = value
        if containsLineBreak(v) {
            v = v.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        if let first = v.unicodeScalars.first, let last = v.unicodeScalars.last,
           IniSyntax.isBlank(first) || IniSyntax.isBlank(last) {
            v = "\"" + v + "\""
        }
        return v
    }

    /// Keeps everything up to `=` plus the blanks after it, then the new value.
    private static func replacingValue(in line: Substring, with value: String) -> String {
        let scalars = line.unicodeScalars
        guard let eq = scalars.firstIndex(of: "=") else { return String(line) + value }
        var valueStart = scalars.index(after: eq)
        while valueStart < scalars.endIndex, IniSyntax.isBlank(scalars[valueStart]) {
            valueStart = scalars.index(after: valueStart)
        }
        return String(Substring(scalars[..<valueStart])) + value
    }
}
