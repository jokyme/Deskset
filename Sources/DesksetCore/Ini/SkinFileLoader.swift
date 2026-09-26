import Foundation

/// Where a section header or an option was written: file and 1-based line.
public struct IniSourceLocation: Equatable, CustomStringConvertible {
    public var file: URL
    public var line: Int

    public init(file: URL, line: Int) {
        self.file = file
        self.line = line
    }

    public var description: String { "\(file.lastPathComponent):\(line)" }
}

/// Source locations of a merged skin document, for the inspector (which shows where a value comes from and writes
/// edits back to that place). Keys are lowercased.
public struct IniSourceMap: Equatable {
    /// Section → option → the definition that won the merge ("later wins conflicts").
    public var options: [String: [String: IniSourceLocation]] = [:]
    /// Section → the header that placed the section (the main file's, when it has one).
    public var sections: [String: IniSourceLocation] = [:]

    public init() {}

    public func location(section: String, key: String) -> IniSourceLocation? {
        options[section.lowercased()]?[key.lowercased()]
    }

    public func location(section: String) -> IniSourceLocation? {
        sections[section.lowercased()]
    }
}

/// The result of loading a skin .ini with all `@Include` files merged in.
public struct LoadedIniFile {
    /// The merged document (sections in effective order, includes merged per the Rainmeter manual).
    public var document: IniDocument
    /// Every included file actually read, in load order (the main file is not listed).
    public var includedFiles: [URL]
    /// Human-readable problems (missing include file, include cycle, depth limit…). Loading never fails for these.
    public var warnings: [String]
    /// Where every merged section and option was written.
    public var sources: IniSourceMap

    public init(document: IniDocument, includedFiles: [URL] = [], warnings: [String] = [],
                sources: IniSourceMap = IniSourceMap()) {
        self.document = document
        self.includedFiles = includedFiles
        self.warnings = warnings
        self.sources = sources
    }
}

/// Loads a skin file and expands `@Include` options.
///
/// What the manual says (docs.rainmeter.net/manual/skins/include-option/ and the linked @Include Guide) and how it
/// is implemented here:
///
/// 1. "`@Include`, `@Include2`, `@IncludeN` … The N can also represent text … The option must only start with
///    @Include" → any key whose name starts with `@Include` (any case) is an include. Each is processed at its
///    position among the section's keys, in order.
/// 2. "The statement may be placed in any section." The Guide adds "The @include call must be made within a section",
///    so an `@Include` before the first section header is ignored (with a warning).
/// 3. "The @Include option loads the content of an external .ini at the position it is defined. The loaded file is
///    treated as if the contents were included in the actual skin .ini file." → key precedence follows that
///    textual position (see 5).
/// 4. "All new sections from the included file are inserted immediately after the section where the statement is
///    placed" (in the included file's order; several includes in one section follow each other in reading order).
///    Sections that already exist are not moved: the Guide's example keeps a main-file `[String]` that comes after the
///    include where it is. "Already existing" means defined anywhere in the including file (the whole file is read
///    before its includes) or placed by anything read before. Nested includes work the same way: "when any file
///    includes another file, the new contents are added within its own sections, immediately after the section where
///    the statement is made" — new sections from a nested include follow the section holding the statement *where
///    that section actually is in the skin*. When that section already existed elsewhere (e.g. an included `[M]`
///    block that merges into the skin's own `[M]`), the new sections follow the skin's `[M]`, not the place where the
///    included file was pasted. (Implemented as a tree: every section owns the list of sections its includes added
///    after it; the final order is a depth-first walk from the main file's sections.)
/// 5. "If the same [SectionName] exists in more than one file … Any keys from the earlier section are added, but will
///    be overridden by duplicate keys from later sections … 'Later' wins conflicts." "Earlier/later" is the position
///    in the textual expansion of 3: an included key overrides the same key written before the `@Include` line
///    (including earlier keys of the very section holding the `@Include`), and is overridden by keys written after
///    it (the Guide: a main-file section after the include keeps its values). An overridden key keeps its original
///    place in the section's entry order; new keys are appended. The Guide's looser wording ("placing all unique
///    options into any existing sections") agrees for its example, where the existing section comes after the
///    include; for an existing section *before* the include the manual's "'Later' wins conflicts" is followed.
/// 6. "If both are in the actual .ini file, the second one is entirely ignored." → inside any single file a
///    repeated section is dropped (including `@Include`s in it), and the first definition of a key in a section
///    wins (see `IniDocument.parse`).
/// 7. `[Variables]` in included files are ordinary sections, merged by 4–5. An include path may use variables:
///    `expandVariables` receives the merged `[Variables]` entries read so far (lowercased keys, raw values). As a
///    leniency, variables of the main skin file's own `[Variables]` section that have not been read yet (the section
///    comes after the `@Include`) are also offered; a value read so far always wins. The Guide notes such a
///    variable "cannot be dynamic" — it is resolved once, at load time.
/// 8. Paths: `\` becomes `/`. "Paths relative to the current skin folder" (manual, Option Types) → a relative path is
///    resolved against the folder of the main skin file, also inside nested include files ("treated as if the
///    contents were included in the actual skin .ini file"); if nothing exists there, the including file's own
///    folder is tried as a fallback. A missing file is also looked up case-insensitively (Windows file names are
///    case-insensitive; skins often get the case wrong). Windows drive (`C:\…`) and UNC (`\\server\…`) paths cannot
///    work on macOS and produce a warning.
/// 9. Missing/unreadable files, cycles, excessive nesting (`maxIncludeDepth`), runaway include counts
///    (`maxIncludeLoads`), runaway amounts of included content (`maxIncludedEntries`) and absurdly long paths become
///    warnings; the rest of the skin still loads. The manual gives no limits; these only stop hostile input.
///
/// The consumed `@Include…` keys are not part of the merged document.
public enum SkinFileLoader {
    /// Maximum nesting depth of include files (a file included by the skin file is depth 1).
    public static let maxIncludeDepth = 30
    /// Maximum number of `@Include` options processed for one skin, successful or not (guards against exponential
    /// include trees and against skins with absurd numbers of includes).
    public static let maxIncludeLoads = 500
    /// Maximum total number of `Key=Value` entries merged from include files for one skin (a file included several
    /// times counts every time). Guards against a large file being included hundreds of times.
    public static let maxIncludedEntries = 1_000_000
    /// Include paths longer than this (in UTF-8 bytes, after variable expansion) are rejected with a warning;
    /// macOS paths cannot exceed PATH_MAX (1024) anyway.
    public static let maxIncludePathLength = 1024
    /// Include files larger than this are skipped with a warning.
    public static let maxIncludeFileSize = 32 * 1024 * 1024

    /// Reads the skin file at `url` and expands every `@Include`, `@Include2`, `@IncludeXxx` key (in any section),
    /// recursively, with cycle and depth protection.
    ///
    /// - Parameter expandVariables: substitutes `#Variables#` in a raw include value. It receives the raw value and
    ///   the `[Variables]` entries read so far (keys lowercased, values as written). The caller supplies built-in
    ///   variables such as `#@#` and `#CURRENTPATH#`.
    /// - The loader converts `\` to `/` and resolves relative paths as the manual specifies.
    /// - Throws only when the main file itself cannot be read.
    /// - Performance: `expandVariables` is called once per `@Include` (at most `maxIncludeLoads` times). The dictionary
    ///   is passed without copying; look names up in it instead of copying or merging it on every call, which would
    ///   cost O(#variables) per include.
    public static func load(url: URL, expandVariables: (String, [String: String]) -> String) throws -> LoadedIniFile {
        let text = try TextDecoding.readFile(at: url)
        var loader = IncludeLoader(mainURL: url)
        return loader.run(mainText: text, expand: expandVariables)
    }
}

// MARK: - Implementation

private struct MergedSection {
    var name: String
    var entries: [IniEntry] = []
    var indexByKey: [String: Int] = [:]

    init(name: String) { self.name = name }

    /// Later definitions win; an overridden key keeps its position.
    mutating func set(_ entry: IniEntry) {
        let lower = entry.key.lowercased()
        if let i = indexByKey[lower] {
            entries[i].value = entry.value
        } else {
            indexByKey[lower] = entries.count
            entries.append(entry)
        }
    }
}

private struct IncludeLoader {
    /// A parsed include file plus its entry count (for the `maxIncludedEntries` budget).
    struct CachedFile {
        var parsed: IniSyntax.ParsedFile
        var entryCount: Int
    }

    let mainURL: URL
    let skinFolder: URL

    var sections: [String: MergedSection] = [:]   // lowercased name → merged content
    var known: Set<String> = []                    // sections already placed
    /// Section order as a tree: the main file's sections are the roots; every section owns the new sections that
    /// includes placed right after it (in reading order). The document order is a depth-first walk.
    var roots: [String] = []
    var children: [String: [String]] = [:]
    /// What `expandVariables` sees: the main file's own `[Variables]` (leniency, see 7 above) overlaid with every
    /// `[Variables]` entry read so far. Updated incrementally so an include costs O(1), not O(#variables).
    var visibleVariables: [String: String] = [:]
    var warnings: [String] = []
    var suppressedWarnings = 0
    var includedFiles: [URL] = []
    var includedIDs: Set<String> = []
    var stack: [String] = []                       // identities of the files being expanded
    var attempts = 0
    var loadLimitWarned = false
    var includedEntries = 0
    var entryLimitWarned = false
    var cache: [String: CachedFile] = [:]
    var sources = IniSourceMap()

    static let maxWarnings = 100
    /// Longest excerpt of a skin-provided value quoted in a warning.
    static let maxQuotedLength = 200

    init(mainURL: URL) {
        self.mainURL = mainURL.standardizedFileURL
        self.skinFolder = self.mainURL.deletingLastPathComponent()
    }

    mutating func run(mainText: String, expand: (String, [String: String]) -> String) -> LoadedIniFile {
        let parsed = IniSyntax.parseFile(mainText)
        warnAboutIncludesBeforeFirstSection(parsed, file: mainURL)
        if let vars = parsed.sections.first(where: { IniSyntax.namesEqual($0.name, "Variables") }) {
            for e in vars.entries where !IniSyntax.isIncludeKey(e.key) {
                visibleVariables[e.key.lowercased()] = e.value
            }
        }
        stack = [IncludePaths.identity(of: mainURL)]
        expandFile(parsed, url: mainURL, depth: 0, parent: nil, expand: expand)

        var document = IniDocument()
        document.sections.reserveCapacity(sections.count)
        for key in orderedSectionKeys() {
            if let s = sections[key] { document.sections.append(IniSection(name: s.name, entries: s.entries)) }
        }
        if suppressedWarnings > 0 { warnings.append("… and \(suppressedWarnings) more @Include warnings") }
        return LoadedIniFile(document: document, includedFiles: includedFiles, warnings: warnings, sources: sources)
    }

    /// Depth-first walk of the section tree (iterative; the tree is at most `maxIncludeDepth` + 1 levels deep anyway).
    func orderedSectionKeys() -> [String] {
        var out: [String] = []
        out.reserveCapacity(sections.count)
        var stack: [(list: [String], next: Int)] = [(roots, 0)]
        while let top = stack.last {
            if top.next >= top.list.count {
                stack.removeLast()
                continue
            }
            let key = top.list[top.next]
            stack[stack.count - 1].next += 1
            out.append(key)
            if let kids = children[key], !kids.isEmpty { stack.append((kids, 0)) }
        }
        return out
    }

    /// Streams one file's keys into the merged sections (in textual order, expanding includes in place). The file's
    /// new sections are placed right after `parent` (the section holding the `@Include`; nil for the main file).
    mutating func expandFile(_ parsed: IniSyntax.ParsedFile, url: URL, depth: Int, parent: String?,
                             expand: (String, [String: String]) -> String) {
        // The whole file is read first, so every section it defines "already exists" for its own includes.
        var placed: [String] = []
        for s in parsed.sections {
            let key = s.name.lowercased()
            if known.insert(key).inserted {
                sections[key] = MergedSection(name: s.name)
                placed.append(key)
                sources.sections[key] = IniSourceLocation(file: url, line: s.headerLine)
            }
        }
        if let parent {
            if !placed.isEmpty { children[parent, default: []].append(contentsOf: placed) }
        } else {
            roots.append(contentsOf: placed)
        }

        for s in parsed.sections {
            let key = s.name.lowercased()
            for (i, entry) in s.entries.enumerated() {
                if IniSyntax.isIncludeKey(entry.key) {
                    include(entry.value, optionName: entry.key, sectionName: s.name, sectionKey: key, from: url,
                            depth: depth + 1, expand: expand)
                } else {
                    sections[key, default: MergedSection(name: s.name)].set(entry)
                    if i < s.entryLines.count {
                        sources.options[key, default: [:]][entry.key.lowercased()] =
                            IniSourceLocation(file: url, line: s.entryLines[i])
                    }
                    if key == "variables" { visibleVariables[entry.key.lowercased()] = entry.value }
                }
            }
        }
    }

    mutating func include(_ rawValue: String, optionName: String, sectionName: String, sectionKey: String,
                          from includer: URL, depth: Int, expand: (String, [String: String]) -> String) {
        let raw = IniSyntax.trim(rawValue)
        if raw.isEmpty { return } // `@Include=` placeholder: nothing to do
        let origin = "\(Self.excerpt(optionName))=\(Self.excerpt(raw)) in [\(Self.excerpt(sectionName))] of \(includer.lastPathComponent)"

        if depth > SkinFileLoader.maxIncludeDepth {
            warn("\(origin): skipped, include nesting deeper than \(SkinFileLoader.maxIncludeDepth) levels")
            return
        }
        // Every attempt counts (failed ones too): a skin with thousands of @Include lines must not stall loading.
        // Once a limit is hit, later includes are skipped before any work (including the expandVariables call).
        if entryLimitWarned { return }
        if attempts >= SkinFileLoader.maxIncludeLoads {
            if !loadLimitWarned {
                loadLimitWarned = true
                warn("\(origin): skipped, more than \(SkinFileLoader.maxIncludeLoads) @Include options; further includes ignored",
                     always: true)
            }
            return
        }
        attempts += 1
        // Cheap early exit for absurd values before any string processing (variables practically never shorten
        // a path by that much; the exact limit is checked after expansion and trimming).
        if raw.utf8.count > 64 * SkinFileLoader.maxIncludePathLength {
            warn("\(origin): the path is longer than \(SkinFileLoader.maxIncludePathLength) bytes")
            return
        }

        let expanded = expand(raw, visibleVariables)

        let fileURL: URL
        switch resolve(expanded, includer: includer) {
        case .success(let url): fileURL = url
        case .failure(let problem):
            warn("\(origin): \(problem.message)")
            return
        }

        let id = IncludePaths.identity(of: fileURL)
        if stack.contains(id) {
            warn("\(origin): skipped, include cycle (\(fileURL.lastPathComponent) is already being included)")
            return
        }

        let file: CachedFile
        if let cached = cache[id] {
            file = cached
        } else {
            let realPath = fileURL.resolvingSymlinksInPath().path // size of the target, not of a symlink
            if let size = (try? FileManager.default.attributesOfItem(atPath: realPath))?[.size] as? NSNumber,
               size.intValue > SkinFileLoader.maxIncludeFileSize {
                warn("\(origin): skipped, \(Self.excerpt(fileURL.path)) is larger than \(SkinFileLoader.maxIncludeFileSize / 1_048_576) MB")
                return
            }
            let parsed: IniSyntax.ParsedFile
            do {
                parsed = IniSyntax.parseFile(try TextDecoding.readFile(at: fileURL))
            } catch {
                warn("\(origin): cannot read \(Self.excerpt(fileURL.path)) (\(error.localizedDescription))")
                return
            }
            file = CachedFile(parsed: parsed, entryCount: parsed.sections.reduce(0) { $0 + $1.entries.count })
            cache[id] = file
            warnAboutIncludesBeforeFirstSection(parsed, file: fileURL)
        }

        if includedEntries + file.entryCount > SkinFileLoader.maxIncludedEntries {
            if !entryLimitWarned {
                entryLimitWarned = true
                warn("\(origin): skipped, include files add more than \(SkinFileLoader.maxIncludedEntries) options; further includes ignored",
                     always: true)
            }
            return
        }
        includedEntries += file.entryCount

        if includedIDs.insert(id).inserted { includedFiles.append(fileURL) }
        stack.append(id)
        defer { stack.removeLast() }
        expandFile(file.parsed, url: fileURL, depth: depth, parent: sectionKey, expand: expand)
    }

    // MARK: Paths

    struct PathProblem: Error { let message: String }

    func resolve(_ expandedValue: String, includer: URL) -> Result<URL, PathProblem> {
        let tooLong = PathProblem(message: "the path is longer than \(SkinFileLoader.maxIncludePathLength) bytes")
        // Only edge blanks and one pair of quotes are removed below, so a much longer value cannot become valid.
        if expandedValue.utf8.count > 16 * SkinFileLoader.maxIncludePathLength { return .failure(tooLong) }
        var path = IniSyntax.trim(expandedValue.replacingOccurrences(of: "\\", with: "/"))
        path = IniSyntax.trim(String(IniSyntax.unquote(Substring(path))))
        let shown = Self.excerpt(path)
        let unresolved = path.contains("#") ? " (is a #Variable# undefined?)" : ""
        if path.isEmpty { return .failure(PathProblem(message: "the path is empty after variable expansion")) }
        if path.utf8.count > SkinFileLoader.maxIncludePathLength { return .failure(tooLong) }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            // A NUL would silently truncate the path at the file-system layer; line breaks cannot be in a file name.
            return .failure(PathProblem(message: "the path contains control characters"))
        }

        let scalars = Array(path.unicodeScalars.prefix(3))
        if scalars.count >= 2, scalars[1] == ":", IncludePaths.isASCIILetter(scalars[0]),
           scalars.count == 2 || scalars[2] == "/" {
            return .failure(PathProblem(message: "Windows drive path \"\(shown)\" cannot be used on macOS"))
        }
        if path.hasPrefix("//") {
            return .failure(PathProblem(message: "network path \"\(shown)\" is not supported"))
        }

        var candidates: [String] = []
        if path.hasPrefix("/") {
            candidates.append(IncludePaths.normalize(path))
        } else {
            candidates.append(IncludePaths.normalize(skinFolder.path + "/" + path))
            let includerFolder = includer.standardizedFileURL.deletingLastPathComponent().path
            let alt = IncludePaths.normalize(includerFolder + "/" + path)
            if alt != candidates[0] { candidates.append(alt) }
        }
        for candidate in candidates where IncludePaths.isRegularFile(candidate) {
            return .success(URL(fileURLWithPath: candidate))
        }
        for candidate in candidates {
            if let found = IncludePaths.caseInsensitiveLookup(candidate), IncludePaths.isRegularFile(found) {
                return .success(URL(fileURLWithPath: found))
            }
        }
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return .failure(PathProblem(message: "\(Self.excerpt(existing)) is not a file (directory, device or pipe)"))
        }
        return .failure(PathProblem(message: "file not found: \(Self.excerpt(candidates[0]))\(unresolved)"))
    }

    // MARK: Warnings

    /// `always`: one-time limit messages are kept even when the warning list is full, so the log says why includes
    /// stopped.
    mutating func warn(_ message: String, always: Bool = false) {
        if warnings.count < Self.maxWarnings || always { warnings.append(message) } else { suppressedWarnings += 1 }
    }

    mutating func warnAboutIncludesBeforeFirstSection(_ parsed: IniSyntax.ParsedFile, file: URL) {
        for e in parsed.entriesBeforeFirstSection where IniSyntax.isIncludeKey(e.key) {
            warn("\(Self.excerpt(e.key))=\(Self.excerpt(e.value)) in \(file.lastPathComponent) is ignored: @Include must be placed inside a section")
        }
    }

    /// Skin-provided text quoted in a warning, shortened so a hostile value cannot blow up the log.
    static func excerpt(_ s: String) -> String {
        guard s.utf8.count > maxQuotedLength else { return s }
        return String(s.unicodeScalars.prefix(maxQuotedLength)) + "…"
    }
}

/// File-system helpers for include paths (internal so the self-tests can reach them).
enum IncludePaths {
    static func isASCIILetter(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A)
    }

    /// Collapses `//`, `.` and `..` textually (as Windows does), without touching `~` or symlinks.
    static func normalize(_ absolutePath: String) -> String {
        var parts: [Substring] = []
        for part in absolutePath.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// True for a regular file (symlinks followed). Directories, FIFOs, sockets and devices (`/dev/zero`) are not
    /// include files.
    static func isRegularFile(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let type = (try? FileManager.default.attributesOfItem(atPath: resolved))?[.type] as? FileAttributeType
        else { return false }
        return type == .typeRegular
    }

    /// Walks the path component by component, matching each missing component case-insensitively.
    static func caseInsensitiveLookup(_ path: String) -> String? {
        let fm = FileManager.default
        var current = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            let exact = current + "/" + part
            if fm.fileExists(atPath: exact) {
                current = exact
                continue
            }
            let lower = part.lowercased()
            guard let items = try? fm.contentsOfDirectory(atPath: current.isEmpty ? "/" : current),
                  let match = items.first(where: { $0.lowercased() == lower }) else { return nil }
            current += "/" + match
        }
        return current.isEmpty ? nil : current
    }

    /// File identity for cycle detection: device + inode of the symlink-resolved file (so `a.inc`, `A.inc`,
    /// `./x/../a.inc` and symlinks to it are the same file); falls back to the lowercased resolved path.
    static func identity(of url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
           let device = attrs[.systemNumber] as? NSNumber, let inode = attrs[.systemFileNumber] as? NSNumber {
            return "\(device):\(inode)"
        }
        return resolved.lowercased()
    }
}
