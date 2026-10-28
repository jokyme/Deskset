import Foundation

// The files a widget shares with the other widgets of its root config: which of its files are its own, which
// configs read a shared file through their `@Include`s, and writing a value of its own after its includes.

// MARK: - Writing a shared value for one widget

extension IniWriter {
    /// Writes `key=value` into the first `[section]` block of the file so that it wins over the same key read from
    /// the block's `@Include` files (docs/editor-friendly.md §8.1.1, "This Widget"). Per the include rules
    /// (`SkinFileLoader` 5 and 6): a key written after the `@Include` lines overrides the included one, and inside
    /// one file the first definition of a key wins — so a definition before the last `@Include` is moved after it
    /// (removed, then appended at the end of the block). A definition already after the includes is updated in place.
    public static func writeAfterIncludes(_ value: String, key: String, section: String, fileURL: URL) throws {
        let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        try withFileLock(target) {
            let (text, encoding) = try TextDecoding.readFileDetectingEncoding(at: target)
            let updated = try writingAfterIncludes(text, value: value, key: key, section: section)
            if updated.utf8.elementsEqual(text.utf8) { return }
            let data = TextDecoding.encodeForWriting(updated, preferring: encoding)
            try data.write(to: target, options: .atomic)
        }
    }

    /// The text-level operation behind `writeAfterIncludes`.
    public static func writingAfterIncludes(_ text: String, value: String, key: String, section: String) throws -> String {
        let sectionName = IniSyntax.trim(section)
        let keyName = IniSyntax.trim(key)
        var inside = false
        var lastInclude: Int?
        var firstKey: Int?
        var index = 0
        var done = false
        IniSyntax.forEachLineWithTerminator(in: text) { content, _ in
            defer { index += 1 }
            guard !done else { return }
            switch IniSyntax.classify(content) {
            case .section(let name):
                if inside { done = true; return }
                if let name, IniSyntax.namesEqual(name, sectionName) { inside = true }
            case .entry(let k, _):
                guard inside else { return }
                if k.lowercased().hasPrefix("@include") { lastInclude = index }
                if firstKey == nil, IniSyntax.namesEqual(k, keyName) { firstKey = index }
            default:
                break
            }
        }
        if let firstKey, let lastInclude, firstKey < lastInclude {
            let removed = removingKey(text, key: keyName, section: sectionName)
            return try updating(removed, value: value, key: keyName, section: sectionName)
        }
        return try updating(text, value: value, key: keyName, section: sectionName)
    }
}

// MARK: - Who reads a shared file

extension Skin {
    /// Whether a file is one of this widget's own (its .ini, or a file in its folder outside `@Resources`), as opposed
    /// to one shared with the other widgets of its root config.
    public func isOwnFile(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == fileURL.standardizedFileURL.resolvingSymlinksInPath().path { return true }
        let folder = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let resources = resourcesDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(folder) && !path.hasPrefix(resources)
    }

    /// The configs of this widget's root config (itself included) whose skin files read `file` through their
    /// `@Include`s, sorted — who changes when a shared value is written where it is defined (§8.1.1 "All 9 Widgets").
    public func configsIncluding(_ file: URL) -> [String] {
        includeMap().configs(including: file)
    }

    /// Which configs of this widget's root config read which files through their `@Include`s: every .ini file of
    /// every config folder is loaded once, the way the engine loads it (include paths expanded with the built-in path
    /// variables and the variables read so far); a config counts once, whichever of its files includes a file.
    /// One walk answers `configsIncluding` for every shared file (a suite of 300 skins took a second per file).
    /// A file whose include paths use the Mac appearance variables (`@Include=#@#Theme-#MACAPPEARANCE#.inc`) is loaded
    /// once in the light and once in the dark appearance: its config reads both theme files, whichever the Mac shows now.
    public func includeMap() -> IncludeMap {
        let root = rootConfigDirectory.standardizedFileURL
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return IncludeMap()
        }
        func dir(_ url: URL) -> String { url.path.hasSuffix("/") ? url.path : url.path + "/" }
        var map = IncludeMap()
        var visited = 0
        for case let url as URL in walker {
            if url.lastPathComponent.hasPrefix("@") { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "ini", visited < 400 else { continue }
            visited += 1
            let folder = url.deletingLastPathComponent().standardizedFileURL
            let relative = folder.path.hasPrefix(root.path) ? String(folder.path.dropFirst(root.path.count)) : ""
            let config = ([rootConfig] + relative.split(separator: "/").map(String.init)).joined(separator: "\\")
            let builtins: [String: String] = [
                "@": dir(resourcesDirectory), "currentpath": dir(folder), "currentfile": url.lastPathComponent,
                "currentconfig": config, "rootconfig": rootConfig, "rootconfigpath": dir(rootConfigDirectory),
                "skinspath": dir(skinsDirectory),
            ]
            // Loaded before, and neither it nor any file it read changed since (on disk or in the editor's text):
            // what it read then (a suite of hundreds of skins is walked in a few milliseconds on every step).
            let key = IncludeMapCache.key(url)
            if let cached = IncludeMapCache.shared.entry(key), cached.isCurrent(sourceProvider) {
                for file in cached.included { map.readers[file, default: []].insert(config.lowercased()) }
                continue
            }
            var usesAppearance = false
            func load(_ appearance: SkinAppearance) -> LoadedIniFile? {
                let mac = appearance.variables
                return try? SkinFileLoader.load(url: url, sources: sourceProvider, expandVariables: { raw, readSoFar in
                    VariableResolver(variableLookup: { name in
                        let key = name.lowercased()
                        // As the engine resolves them (`Skin.load`): the Mac's, whatever [Variables] says.
                        if let value = mac[key] {
                            usesAppearance = true
                            return value
                        }
                        return readSoFar[key] ?? builtins[key]
                    }).resolve(raw)
                })
            }
            guard let loaded = load(.light) else { continue }
            var included = loaded.includedFiles
            if usesAppearance, let dark = load(.dark) { included += dark.includedFiles }
            for file in included {
                map.readers[IncludeMap.key(file), default: []].insert(config.lowercased())
            }
            IncludeMapCache.shared.store(key, .init(included: included.map(IncludeMap.key),
                                                    stamps: ([url] + included).map { IncludeMapCache.stamp($0, sourceProvider) }))
        }
        return map
    }

    /// What `includeMap()` found for each .ini file, kept for the next walk: the files it read, and a stamp of each
    /// (its size and modification date, and the editor's text of it when an editing session holds one), so a skin is
    /// loaded again only when it or a file it read changed — a file added or removed shows in the walk itself.
    final class IncludeMapCache: @unchecked Sendable {
        static let shared = IncludeMapCache()

        struct Stamp: Equatable {
            var path: String
            var modified: Date?
            var size: Int?
            var text: Int?
        }

        struct Entry {
            var included: [String]
            var stamps: [Stamp]

            func isCurrent(_ sources: SourceProvider?) -> Bool {
                stamps.allSatisfy { IncludeMapCache.stamp(URL(fileURLWithPath: $0.path), sources) == $0 }
            }
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

        static func stamp(_ url: URL, _ sources: SourceProvider?) -> Stamp {
            let path = key(url)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return Stamp(path: path, modified: attributes?[.modificationDate] as? Date,
                         size: (attributes?[.size] as? NSNumber)?.intValue,
                         text: sources?.sourceText(for: URL(fileURLWithPath: path))?.hashValue)
        }

        func entry(_ key: String) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func store(_ key: String, _ entry: Entry) {
            lock.lock()
            defer { lock.unlock() }
            entries[key] = entry
        }
    }

    /// The files each config reads through `@Include` (`Skin.includeMap()`).
    public struct IncludeMap: Equatable {
        /// A file's standardised, symlink-resolved path → the configs (lowercased) that read it.
        var readers: [String: Set<String>] = [:]

        public init() {}

        static func key(_ file: URL) -> String { file.standardizedFileURL.resolvingSymlinksInPath().path }

        /// The configs reading `file`, sorted.
        public func configs(including file: URL) -> [String] { (readers[Self.key(file)] ?? []).sorted() }
    }
}
