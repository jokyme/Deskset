import Foundation

// File-system and INI-text helpers for the .rmskin installer.

enum RmskinFiles {
    static var fm: FileManager { FileManager.default }

    /// Deepest recursion accepted when copying folder trees (extraction already refuses deeper packages).
    static let maxCopyDepth = RmskinZip.maxPathDepth + 8

    // MARK: Queries

    /// True when anything (file, folder or symlink, even a dangling one) exists at `url`; symlinks are not followed.
    static func itemExists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Hidden files and folders are ignored everywhere in a package: the Skin Packager "will ignore any hidden files
    /// or folders" (so a genuine package never has them), and macOS zips add `__MACOSX` / `.DS_Store` debris.
    /// Windows Explorer's own hidden files (`desktop.ini` folder settings, `Thumbs.db` thumbnail caches) count as
    /// hidden too: they end up in hand-made ZIPs, and `desktop.ini` would otherwise look like a skin.
    static func isIgnoredName(_ name: String) -> Bool {
        name.hasPrefix(".") || name.caseInsensitiveCompare("__MACOSX") == .orderedSame
            || windowsMetadataNames.contains(name.lowercased())
    }

    /// Hidden system files Windows Explorer writes into folders (see `isIgnoredName`), lowercased.
    static let windowsMetadataNames: Set<String> = ["desktop.ini", "thumbs.db", "ehthumbs.db"]

    /// Children of a folder (empty when unreadable), sorted case-insensitively for deterministic results.
    static func children(of directory: URL) -> [URL] {
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
        return urls.sorted {
            $0.lastPathComponent.caseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func visibleChildren(of directory: URL) -> [URL] {
        children(of: directory).filter { !isIgnoredName($0.lastPathComponent) }
    }

    /// Finds a child by name, case-insensitively (Windows packages are case-insensitive by nature); an exact-case
    /// match wins. `directory` restricts the kind of item (nil = any).
    static func child(named name: String, in parent: URL, directory: Bool? = nil) -> URL? {
        let candidates = children(of: parent).filter { url in
            guard url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame else { return false }
            guard let wantDirectory = directory else { return true }
            return wantDirectory ? isDirectory(url) : isRegularFile(url)
        }
        return candidates.first { $0.lastPathComponent == name } ?? candidates.first
    }

    /// Follows `components` from `base`, matching each one case-insensitively against what is on disk. Returns the
    /// on-disk spelling of every component, or nil when the path does not exist.
    static func resolveCaseInsensitively(_ components: [String], from base: URL) -> [String]? {
        var current = base
        var resolved: [String] = []
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            guard let next = child(named: component, in: current, directory: isLast ? nil : true) else { return nil }
            resolved.append(next.lastPathComponent)
            current = next
        }
        return resolved
    }

    /// Splits a Windows/Unix relative path (`Config\Sub\File.ini`) into components, dropping empty and `.` parts.
    /// Returns nil when a component is `..` (never allowed to leave the target folder).
    static func pathComponents(_ path: String) -> [String]? {
        let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init).filter { $0 != "." }
        if parts.contains("..") { return nil }
        return parts
    }

    static func appending(_ components: [String], to base: URL) -> URL {
        components.reduce(base) { $0.appendingPathComponent($1) }
    }

    /// Width and height of a Windows bitmap (`BM` signature, BITMAPCOREHEADER or BITMAPINFOHEADER and later), or nil
    /// when the file is not a BMP or claims an implausible size (over 4096 pixels either way).
    static func bitmapSize(of url: URL) -> (width: Int, height: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 26), head.count >= 26 else { return nil }
        let b = [UInt8](head)
        guard b[0] == 0x42, b[1] == 0x4D else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        }
        let headerSize = u32(14)
        let width: Int, height: Int
        if headerSize == 12 {
            width = Int(UInt16(b[18]) | UInt16(b[19]) << 8)
            height = Int(UInt16(b[20]) | UInt16(b[21]) << 8)
        } else if headerSize >= 40 {
            width = Int(Int32(bitPattern: u32(18)))
            height = abs(Int(Int32(bitPattern: u32(22)))) // negative = top-down rows; Int is 64-bit, no overflow
        } else {
            return nil
        }
        guard (1...4096).contains(width), (1...4096).contains(height) else { return nil }
        return (width, height)
    }

    /// Every regular (non-hidden) file below `directory`.
    static func allFiles(in directory: URL) -> [URL] {
        var result: [URL] = []
        collectFiles(in: directory, depth: 0, into: &result)
        return result
    }

    private static func collectFiles(in directory: URL, depth: Int, into result: inout [URL]) {
        guard depth < maxCopyDepth else { return }
        for child in visibleChildren(of: directory) {
            if isDirectory(child) {
                collectFiles(in: child, depth: depth + 1, into: &result)
            } else {
                result.append(child)
            }
        }
    }

    // MARK: Mutations

    /// A folder path inside `directory` named `baseName`, or `baseName (2)`, `baseName (3)`… when taken.
    static func uniqueURL(in directory: URL, baseName: String) -> URL {
        let first = directory.appendingPathComponent(baseName, isDirectory: true)
        if !itemExists(first) { return first }
        for n in 2...9_999 {
            let candidate = directory.appendingPathComponent("\(baseName) (\(n))", isDirectory: true)
            if !itemExists(candidate) { return candidate }
        }
        return directory.appendingPathComponent("\(baseName) (\(UUID().uuidString))", isDirectory: true)
    }

    /// Copies `source` to `destination`, skipping hidden items. Folders are merged into existing folders; an existing
    /// file is replaced when `overwrite` is true and kept otherwise.
    static func copyTree(from source: URL, to destination: URL, overwrite: Bool, depth: Int = 0) throws {
        guard depth < maxCopyDepth else { return }
        if isDirectory(source) {
            if itemExists(destination), !isDirectory(destination) {
                guard overwrite else { return }
                try fm.removeItem(at: destination)
            }
            if !itemExists(destination) {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            for child in visibleChildren(of: source) {
                try copyTree(from: child, to: destination.appendingPathComponent(child.lastPathComponent),
                             overwrite: overwrite, depth: depth + 1)
            }
        } else {
            if itemExists(destination) {
                guard overwrite else { return }
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
        }
    }

    /// Moves `source` to `destination`; when both are folders the contents are merged (later entries win).
    static func mergeMove(from source: URL, to destination: URL, depth: Int = 0) throws {
        guard depth < maxCopyDepth else { return }
        if !itemExists(destination) {
            try fm.moveItem(at: source, to: destination)
            return
        }
        if isDirectory(source), isDirectory(destination) {
            for child in children(of: source) {
                try mergeMove(from: child, to: destination.appendingPathComponent(child.lastPathComponent),
                              depth: depth + 1)
            }
            try? fm.removeItem(at: source)
        } else {
            try fm.removeItem(at: destination)
            try fm.moveItem(at: source, to: destination)
        }
    }

    /// Deletes `url` (file or folder). When a plain delete fails — typically a read-only or unsearchable folder in an
    /// extracted package — the owner is given full access to every folder below it and the delete is retried.
    static func forceRemove(_ url: URL) {
        guard itemExists(url) else { return }
        if (try? fm.removeItem(at: url)) != nil { return }
        var pending: [(URL, Int)] = [(url, 0)]
        var visited = 0
        while let (folder, depth) = pending.popLast(), visited < Int(RmskinZip.maxEntries) * 2 {
            var info = stat()
            guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            _ = chmod(folder.path, (info.st_mode & 0o777) | 0o700)
            guard depth < maxCopyDepth,
                  let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names {
                visited += 1
                pending.append((folder.appendingPathComponent(name), depth + 1))
            }
        }
        try? fm.removeItem(at: url)
    }

    /// Where temporary folders are made; nil (the default) is the user's temporary folder. The self-tests point it
    /// at a private folder so their "nothing left behind" checks are not disturbed by other processes.
    static var temporaryRoot: URL?

    static func makeTemporaryDirectory(_ label: String) throws -> URL {
        let url = (temporaryRoot ?? fm.temporaryDirectory)
            .appendingPathComponent("Deskset-\(label)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Text files with their original encoding

/// The byte encoding of a skin text file, detected the same way `TextDecoding` reads it, so a file can be rewritten
/// without changing its encoding (Rainmeter files are often UTF-16 LE).
enum RmskinTextEncoding: Equatable {
    case utf8, utf8BOM, utf16LEBOM, utf16BEBOM, utf16LE, windows1252

    static func detect(_ data: Data) -> RmskinTextEncoding {
        let head = [UInt8](data.prefix(4))
        if head.count >= 3, head[0] == 0xEF, head[1] == 0xBB, head[2] == 0xBF { return .utf8BOM }
        if head.count >= 2, head[0] == 0xFF, head[1] == 0xFE { return .utf16LEBOM }
        if head.count >= 2, head[0] == 0xFE, head[1] == 0xFF { return .utf16BEBOM }
        if looksLikeUTF16LE(data), String(data: data, encoding: .utf16LittleEndian) != nil { return .utf16LE }
        if String(data: data, encoding: .utf8) != nil { return .utf8 }
        return .windows1252
    }

    /// Same heuristic as `TextDecoding`: ASCII-heavy UTF-16 LE text has zeros at odd offsets only.
    private static func looksLikeUTF16LE(_ data: Data) -> Bool {
        guard data.count >= 4, data.count % 2 == 0 else { return false }
        let sample = data.prefix(512)
        var oddZeros = 0, evenZeros = 0
        for (i, byte) in sample.enumerated() where byte == 0 {
            if i % 2 == 1 { oddZeros += 1 } else { evenZeros += 1 }
        }
        return oddZeros > sample.count / 4 && evenZeros == 0
    }

    /// Encodes `text`; when the original encoding cannot represent it (e.g. CJK text merged into a Windows-1252
    /// file) the result falls back to UTF-16 LE with BOM, which is what Rainmeter itself recommends for skins.
    func encode(_ text: String) -> Data {
        switch self {
        case .utf8:
            return Data(text.utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16LEBOM:
            return Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
        case .utf16BEBOM:
            return Data([0xFE, 0xFF]) + (text.data(using: .utf16BigEndian) ?? Data())
        case .utf16LE:
            return text.data(using: .utf16LittleEndian) ?? Data()
        case .windows1252:
            if let data = text.data(using: .windowsCP1252, allowLossyConversion: false) { return data }
            return RmskinTextEncoding.utf16LEBOM.encode(text)
        }
    }

    /// Reads a text file, lets `transform` rewrite it and writes it back in its original encoding.
    /// `transform` returns nil to leave the file untouched. Detection and encoding are `TextDecoding`'s, so a file in
    /// the user's ANSI code page (`TextDecoding.ansiCodePage`, e.g. GBK) is read and written back in that code page;
    /// text the original encoding cannot hold falls back to UTF-16 LE with BOM.
    static func rewriteFile(at url: URL, _ transform: (String) -> String?) throws {
        let data = try Data(contentsOf: url)
        let decoded = TextDecoding.decodeDetectingEncoding(data)
        guard let rewritten = transform(decoded.text) else { return }
        let encoded = TextDecoding.encode(rewritten, as: decoded.encoding) ?? RmskinTextEncoding.utf16LEBOM.encode(rewritten)
        try encoded.write(to: url, options: .atomic)
    }
}

// MARK: - Line-level INI rewriting

/// Rewrites INI text line by line, keeping comments, blank lines, key spelling, order and line endings intact.
/// Parsing rules mirror `IniDocument.parse`: `;` comment lines, `[Section]` headers (a line starting with `[` and
/// no `]` is ignored), `Key=Value` split at the first `=`, keys before the first section ignored, section names and
/// keys case-insensitive, a repeated section continues the first one, and the first definition of a key wins.
enum RmskinIniText {
    enum Line {
        case other
        case section(String)
        /// `valueStart` is the offset (in Characters) just after the `=`.
        case entry(key: String, rawValue: String, valueStart: Int)
    }

    static func classify(_ line: Substring) -> Line {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix(";") { return .other }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return .other }
            let name = trimmed[trimmed.index(after: trimmed.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            return .section(name)
        }
        guard let eq = line.firstIndex(of: "=") else { return .other }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return .other }
        let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return .entry(key: key, rawValue: raw, valueStart: line.distance(from: line.startIndex, to: eq) + 1)
    }

    /// Splits text into lines like `IniDocument.parse` (any newline; `\r\n` is a single Character in Swift), keeping
    /// each line's own terminator so untouched lines are written back byte for byte — mixed line endings and rare
    /// newline characters (form feed, U+2028…) included. The last line has an empty terminator.
    static func splitLines(_ text: String) -> [(content: Substring, terminator: Substring)] {
        var result: [(content: Substring, terminator: Substring)] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index].isNewline {
                result.append((text[start..<index], text[index..<next]))
                start = next
            }
            index = next
        }
        result.append((text[start..<text.endIndex], text[text.endIndex..<text.endIndex]))
        return result
    }

    /// Raw values (as written, quotes included) by lowercased section → lowercased key; first definition wins.
    static func rawValues(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section: String?
        for (line, _) in splitLines(text) {
            switch classify(line) {
            case .other: break
            case .section(let name):
                section = name.lowercased()
                if result[name.lowercased()] == nil { result[name.lowercased()] = [:] }
            case .entry(let key, let raw, _):
                guard let s = section else { continue }
                let k = key.lowercased()
                if result[s]?[k] == nil { result[s]?[k] = raw }
            }
        }
        return result
    }

    /// Keeps the user's values: every key of section `sectionName` (default `[Variables]`) in `newText` that also
    /// exists in that section of `oldText` gets the old value, written exactly as it was (even an empty value). Keys
    /// only in `newText` keep the package default; keys only in `oldText` are dropped (the new file defines which
    /// variables exist). Other sections are left as the package ships them: the manual's "Variables files" keep
    /// "existing variable values", and an include file's styles or meters must still be upgraded.
    /// `@Include…` keys are never taken from the old file: the manual calls @Include an option that "may be placed in
    /// any section", not a variable, and Variables files replace lines "that are not variables"; the old value can
    /// name a file the new version no longer ships.
    /// Returns the merged text and how many values were taken from the old file.
    static func preservingValues(from oldText: String, into newText: String,
                                 section sectionName: String = "Variables") -> (text: String, preserved: Int) {
        let target = sectionName.lowercased()
        guard let old = rawValues(oldText)[target] else { return (newText, 0) }
        var output = ""
        output.reserveCapacity(newText.utf8.count + 64)
        var inTarget = false
        var seen: Set<String> = []
        var preserved = 0
        for (line, terminator) in splitLines(newText) {
            switch classify(line) {
            case .section(let name):
                inTarget = name.lowercased() == target
            case .entry(let key, let raw, let valueStart) where inTarget:
                let k = key.lowercased()
                guard seen.insert(k).inserted, !k.hasPrefix("@include"), let oldValue = old[k], oldValue != raw else {
                    break
                }
                // Keep the key and the spacing right after `=` as written in the new file.
                let afterEq = line.dropFirst(valueStart)
                let spacing = afterEq.prefix { $0 == " " || $0 == "\t" }
                output += line.prefix(valueStart)
                output += spacing
                output += oldValue
                output += terminator
                preserved += 1
                continue
            default:
                break
            }
            output += line
            output += terminator
        }
        return (preserved > 0 ? output : newText, preserved)
    }

    /// Removes every `Key=Value` line of section `sectionName` (all occurrences of the section); the header and
    /// comments stay. Returns the text and the number of removed lines.
    static func removingOptions(ofSection sectionName: String, from text: String) -> (text: String, removed: Int) {
        let target = sectionName.lowercased()
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var inTarget = false
        var removed = 0
        for (line, terminator) in splitLines(text) {
            switch classify(line) {
            case .section(let name):
                inTarget = name.lowercased() == target
            case .entry where inTarget:
                removed += 1
                continue
            default:
                break
            }
            output += line
            output += terminator
        }
        return (removed > 0 ? output : text, removed)
    }
}
