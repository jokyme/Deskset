import Foundation

/// A built-in widget's original: the copy the app ships, next to the one in the Skins folder the Studio edits. "Revert
/// to Original" puts the widget's own files (its folder: the variant it runs and the files it includes from there)
/// back as they came; the suite's shared files (`@Resources`) are left alone, since every widget of the suite reads
/// them. What it would take away is counted in places changed (runs of changed lines), so the page can say so before.
///
/// Only the design counts (§3.2–3.5): the widget's settings — its options (city, units, 12/24 hours, a ring shown or
/// not), which are this copy's, not its design — are neither counted nor put back.
public enum OriginalCopy {
    /// A setting of the widget: `key` of `[section]` (an option's `[Variables]` entry, a clock's `Format`).
    public struct Setting: Hashable {
        public var section: String
        public var key: String

        public init(section: String, key: String) {
            self.section = section.lowercased()
            self.key = key.lowercased()
        }
    }

    /// A file of the widget that differs from its original.
    public struct Change: Equatable {
        /// The file in the Skins folder.
        public var file: URL
        /// The same file in the shipped copy.
        public var original: URL
        /// The original's text.
        public var originalText: String
        /// How many places differ (runs of changed lines), the widget's settings left out.
        public var places: Int
        /// What Revert writes: the original's text with the widget's settings as they are now.
        public var restoredText: String

        public init(file: URL, original: URL, originalText: String, places: Int, restoredText: String? = nil) {
            self.file = file
            self.original = original
            self.originalText = originalText
            self.places = places
            self.restoredText = restoredText ?? originalText
        }
    }

    /// The widget's own files that differ from the shipped copy under `originals` (the root folder of the shipped
    /// skins). `files` are the files the widget reads; only those in the widget's own folder count. `text` reads a
    /// file as the Studio has it (its editing buffer, else the disk). Empty when the widget has no shipped original.
    public static func changes(files: [URL], widgetFolder: URL, skinsDirectory: URL, originals: URL,
                               settings: Set<Setting> = [], text: (URL) -> String?) -> [Change] {
        let folder = widgetFolder.standardizedFileURL.resolvingSymlinksInPath().path
        let skins = skinsDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        var result: [Change] = []
        var seen: Set<String> = []
        for file in files {
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(folder + "/"), path.hasPrefix(skins + "/"), seen.insert(path.lowercased()).inserted
            else { continue }
            let relative = String(path.dropFirst(skins.count + 1))
            let original = originals.appendingPathComponent(relative)
            guard let originalText = read(original), let current = text(file) else { continue }
            let places = placesChanged(without(settings, originalText), without(settings, current))
            if places > 0 {
                result.append(Change(file: file, original: original, originalText: originalText, places: places,
                                     restoredText: restored(originalText, keeping: settings, of: current)))
            }
        }
        return result
    }

    /// The text without the lines that write one of `settings` (in their section), so a setting changed or added is
    /// not a change of the design.
    static func without(_ settings: Set<Setting>, _ text: String) -> String {
        guard !settings.isEmpty else { return text }
        var section = ""
        var out = ""
        IniSyntax.forEachLineWithTerminator(in: text) { content, terminator in
            switch IniSyntax.classify(content) {
            case .section(let name):
                section = name.map { String($0).lowercased() } ?? ""
            case .entry(let key, _):
                if settings.contains(Setting(section: section, key: String(key))) { return }
            default:
                break
            }
            out += content
            out += terminator
        }
        return out
    }

    /// The original's text with each of `settings` as `current` has it: changed, added after the block's includes
    /// (where the Studio writes a widget's own option), or taken away.
    public static func restored(_ original: String, keeping settings: Set<Setting>, of current: String) -> String {
        guard !settings.isEmpty else { return original }
        let now = IniDocument.parse(current), was = IniDocument.parse(original)
        var text = original
        for s in settings.sorted(by: { ($0.section, $0.key) < ($1.section, $1.key) }) {
            let value = now.section(named: s.section)?.value(forKey: s.key)
            guard value != was.section(named: s.section)?.value(forKey: s.key) else { continue }
            guard let value else {
                text = IniWriter.removingKey(text, key: s.key, section: s.section)
                continue
            }
            // Written with the key's own spelling in the current text.
            let key = now.section(named: s.section)?.entries.first { $0.key.lowercased() == s.key }?.key ?? s.key
            let section = now.section(named: s.section)?.name ?? s.section
            if let written = try? IniWriter.writingAfterIncludes(text, value: value, key: key, section: section) {
                text = written
            }
        }
        return text
    }

    /// The text of a file on disk (UTF-8, else UTF-16 with its byte-order mark, else Latin-1), nil when there is none.
    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .isoLatin1)
    }

    /// How many places differ between two texts: runs of lines removed, added or changed (a changed line is one place,
    /// three lines added together are one place). Line endings do not count.
    public static func placesChanged(_ a: String, _ b: String) -> Int {
        let old = lines(a), new = lines(b)
        guard old != new else { return 0 }
        let diff = new.difference(from: old)
        var removed: Set<Int> = [], inserted: Set<Int> = []
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var places = 0
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                places += 1
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
            } else {
                i += 1
                j += 1
            }
        }
        return places
    }

    static func lines(_ text: String) -> [String] {
        // "\r\n" is one character to Swift: made "\n" first, so both endings split the same.
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A final line ending is not a line of its own.
        if result.last?.isEmpty == true { result.removeLast() }
        return result
    }
}
