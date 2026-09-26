import Foundation

// MARK: - Removing an option

extension IniWriter {
    /// Removes `key` (case-insensitive) from the first `[section]` block of the file — every definition of it in that
    /// block, so the option really becomes unset (a reader uses the first one; a second one would take its place) —
    /// keeping the rest of the file byte for byte. The file keeps its encoding. Nothing is written when the key is not
    /// there. Returns whether anything was removed.
    @discardableResult
    public static func removeKey(_ key: String, section: String, fileURL: URL) throws -> Bool {
        let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        return try withFileLock(target) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw IniWriterError.fileNotFound(fileURL.path)
            }
            let (text, encoding) = try TextDecoding.readFileDetectingEncoding(at: target)
            let updated = removingKey(text, key: key, section: section)
            if updated.utf8.elementsEqual(text.utf8) { return false }
            let data = TextDecoding.encodeForWriting(updated, preferring: encoding)
            try data.write(to: target, options: .atomic)
            return true
        }
    }

    /// The text-level operation behind `removeKey`: the lines defining `key` in the first `[section]` block are
    /// dropped with their line breaks; every other character stays. A key in a later repeated `[section]` block is
    /// left alone (readers ignore repeated blocks in the same file, and `writeValue` never writes there).
    public static func removingKey(_ text: String, key: String, section: String) -> String {
        let sectionName = IniSyntax.trim(section)
        let keyName = IniSyntax.trim(key)
        guard !sectionName.isEmpty, !keyName.isEmpty else { return text }
        var lines: [(content: Substring, terminator: Substring)] = []
        IniSyntax.forEachLineWithTerminator(in: text) { lines.append(($0, $1)) }
        var inside = false
        var seenBlock = false
        var drop: Set<Int> = []
        for (i, line) in lines.enumerated() {
            switch IniSyntax.classify(line.content) {
            case .section(let name):
                if inside { inside = false; seenBlock = true }
                if !seenBlock, let name, IniSyntax.namesEqual(name, sectionName) { inside = true }
            case .entry(let k, _):
                if inside, IniSyntax.namesEqual(k, keyName) { drop.insert(i) }
            default:
                break
            }
            if seenBlock { break }
        }
        guard !drop.isEmpty else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        let last = lines.count - 1
        for (i, line) in lines.enumerated() where !drop.contains(i) {
            out += line.content
            out += line.terminator
        }
        // The dropped line was the last one and had no line break: the new last line keeps none either.
        if drop.contains(last), lines[last].terminator.isEmpty, let keptLast = (0..<last).last(where: { !drop.contains($0) }) {
            let terminator = lines[keptLast].terminator
            if !terminator.isEmpty, out.hasSuffix(terminator) { out.removeLast(terminator.count) }
        }
        return out
    }
}

extension Skin {
    /// Removes the section's own definition of `key` (never a MeterStyle's, never a variable): the option then comes
    /// from its MeterStyles or the default again. `[Variables]` entries are removed from the file that defines them.
    /// Returns the file that changed, nil when the section has no own definition of the key.
    @discardableResult
    public func removeOwnOption(section name: String, key: String) throws -> URL? {
        let sectionName = section(named: name)?.name ?? document.section(named: name)?.name ?? name
        guard let location = sources.location(section: sectionName, key: key) else { return nil }
        return try IniWriter.removeKey(key, section: sectionName, fileURL: location.file) ? location.file : nil
    }

    /// The file `removeOwnOption` changes (nil when the section has no own definition of the key).
    public func ownDefinitionFile(section name: String, key: String) -> URL? {
        let sectionName = section(named: name)?.name ?? document.section(named: name)?.name ?? name
        return sources.location(section: sectionName, key: key)?.file
    }
}
