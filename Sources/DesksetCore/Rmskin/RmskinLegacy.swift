import Foundation

// Package formats found in the wild besides the Skin Packager's .rmskin (see docs/compat/installer.md):
//
// - Legacy Rainstaller packages (Rainmeter 1.x – 2.3): a ZIP without the 16-byte footer, with `Rainstaller.cfg`
//   (`[Rainstaller]` section) instead of RMSKIN.ini and the folders `Skins\`, `Fonts\`, `Addons\`, `Plugins\` and
//   `Themes\<name>\Rainmeter.thm` (themes were renamed layouts in Rainmeter 2.4). The version history mentions
//   "Rainstaller: Added Merge=1/0 to support addons for suites" and "Rainstaller: Fixed a bug when there was no top
//   level folder in a .rmskin" (so both layouts — with and without one wrapper folder — exist). The key names below
//   are the ones observed in real packages; the manual does not document them.
// - Plain archives: an ordinary ZIP (renamed .rmskin, or .zip) without any manifest, meant for manual installation.
//   The manual's "Installing skins manually" steps: extract, "Locate the skin folder (may be nested within a 'Skins'
//   parent folder)", move it to the Skins folder. Root configs are therefore detected from their contents.
// - Already extracted folders (the same detection, on a copy that keeps the folder itself as the top item, like a ZIP
//   made of that folder).
// - A ZIP (or folder) without skins that only wraps one .rmskin, as many download sites deliver packages.
// Windows Explorer's hidden `desktop.ini` / `Thumbs.db` files are ignored like macOS's `.DS_Store`.

/// Which kind of package an inspection came from.
public enum RmskinPackageFormat: String, Equatable {
    /// `RMSKIN.ini` (Skin Packager, Rainmeter 2.4 and later).
    case rmskin
    /// `Rainstaller.cfg` (legacy packages for Rainmeter 1.x – 2.3).
    case rainstaller
    /// No manifest: a plain ZIP or folder whose root configs were detected from their .ini files.
    case plain
}

// MARK: - Rainstaller.cfg

extension RmskinManifest {
    /// Parses a legacy `Rainstaller.cfg` (`[Rainstaller]` section) into the .rmskin model:
    /// - `Name`, `Author`, `Version` as in RMSKIN.ini; `MinRainmeterVer` → `minimumRainmeter`.
    /// - `Merge=1` → `mergeSkins`.
    /// - `KeepVar`: a number (or true/false, yes/no, on/off) is a switch — non-zero keeps the user's `[Variables]`
    ///   values in every .ini / .inc file of the installed root configs (`keepsAllVariables`); anything else is read
    ///   as a `|`-separated file list like `VariableFiles`.
    /// - `LaunchType` / `LaunchCommand` → `loadType` / `load`: `Theme` (or `Layout`) loads a layout (themes became
    ///   layouts); `Load`, `Skin` or `Config` loads a skin (`Config\Sub\File.ini`, or just a config folder — the first
    ///   .ini in it is used). A command written as a bang (`!ActivateConfig "Config" "File.ini"`,
    ///   `!LoadLayout Name`, with or without the old `Rainmeter` prefix) is understood too. An empty type infers the
    ///   kind from the command (a path ending in .ini is a skin).
    /// - `AdminRights` and `RainmeterFonts` only concern where Windows put fonts and plugins; they are kept in `raw`
    ///   and otherwise ignored.
    public static func parseRainstaller(_ text: String) -> RmskinManifest {
        var manifest = RmskinManifest()
        manifest.packageFormat = .rainstaller
        guard let section = IniDocument.parse(text).section(named: "Rainstaller") else { return manifest }
        manifest.raw = section
        func string(_ key: String) -> String {
            (section[key] ?? "").trimmingCharacters(in: .whitespaces)
        }
        manifest.name = string("Name")
        manifest.author = string("Author")
        manifest.version = string("Version")
        manifest.minimumRainmeter = string("MinRainmeterVer")
        manifest.mergeSkins = parseBool(string("Merge"))

        let keep = string("KeepVar")
        if !keep.isEmpty {
            if Double(keep) != nil || ["true", "false", "yes", "no", "on", "off"].contains(keep.lowercased()) {
                manifest.keepsAllVariables = parseBool(keep)
            } else {
                manifest.variableFiles = keep.split(separator: "|")
                    .map { IniDocument.unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
            }
        }

        let launch = rainstallerLaunch(type: string("LaunchType"), command: string("LaunchCommand"))
        manifest.loadType = launch.type
        manifest.load = launch.load
        return manifest
    }

    /// Reads and parses a Rainstaller.cfg file (UTF-8, UTF-16 or ANSI).
    public static func parseRainstaller(contentsOf url: URL) throws -> RmskinManifest {
        do {
            return parseRainstaller(try TextDecoding.readFile(at: url))
        } catch {
            throw RmskinError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Maps `LaunchType` / `LaunchCommand` onto `LoadType` / `Load` (see `parseRainstaller`). Unknown types are
    /// passed through unchanged, so the installer reports them instead of guessing.
    static func rainstallerLaunch(type rawType: String, command rawCommand: String) -> (type: String, load: String) {
        let command = IniDocument.unquote(rawCommand.trimmingCharacters(in: .whitespaces))
        // A bang, bare (`!ActivateConfig …`) or bracketed like an action option (`[!ActivateConfig …]`); only the
        // first one counts.
        if command.hasPrefix("!") || command.hasPrefix("[") {
            guard case .bang(let bang)? = ActionParser.parse(command).first else { return (rawType, command) }
            switch bang.name {
            case "activateconfig", "toggleconfig":
                guard let config = bang.args.first, !config.isEmpty else { return (rawType, "") }
                let file = bang.args.count > 1 ? bang.args[1] : ""
                return ("Skin", file.isEmpty ? config : config + "\\" + file)
            case "loadlayout", "loadtheme":
                return ("Layout", bang.args.first ?? "")
            default:
                return (rawType, command)
            }
        }
        switch rawType.lowercased() {
        case "theme", "layout", "loadtheme", "loadlayout":
            // A theme may be named by its file (`Name\Rainmeter.thm`); the layout is the folder.
            var parts = RmskinFiles.pathComponents(command) ?? [command]
            if parts.count > 1, let last = parts.last?.lowercased(), last.hasSuffix(".thm") || last.hasSuffix(".ini") {
                parts.removeLast()
            }
            return ("Layout", parts.joined(separator: "\\"))
        case "load", "skin", "config", "loadskin", "loadconfig", "activateconfig":
            return ("Skin", command)
        default:
            return (rawType, command)
        }
    }
}

// MARK: - Locating the manifest

extension RmskinPackage {
    /// Finds `fileName` at the top of `extracted` or below a chain of wrapper folders that are each the only visible
    /// folder of their parent (hand-made packages wrap everything in one folder, sometimes more, often with a
    /// read-me file beside it; at most `wrapperLevels` are followed). Returns the package root (the folder holding
    /// the file) and the file.
    static func locateManifest(named fileName: String, in extracted: URL,
                               wrapperLevels: Int = RmskinPlainArchive.maxUnwrap) -> (root: URL, file: URL)? {
        var level = extracted
        for _ in 0...max(0, wrapperLevels) {
            if let file = RmskinFiles.child(named: fileName, in: level, directory: false) { return (level, file) }
            let folders = RmskinFiles.visibleChildren(of: level).filter(RmskinFiles.isDirectory)
            guard folders.count == 1 else { return nil }
            level = folders[0]
        }
        return nil
    }

    /// True when the two folders are the same or one contains the other (links resolved, case-insensitively), e.g. a
    /// folder the user wants to install and the Skins folder.
    public static func folder(_ folder: URL, overlaps other: URL) -> Bool {
        let a = folder.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let b = other.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/") || b.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }

    /// A root config name derived from a file or folder name: path separators and `:` become `-`, leading dots and
    /// `@` (hidden / reserved folders) and surrounding spaces are dropped. Never empty.
    static func sanitizedRootName(_ name: String) -> String {
        var result = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        result = String(result.drop { $0 == "." || $0 == "@" || $0 == " " })
        while let last = result.last, last == " " || last == "." { result.removeLast() }
        if result.count > 200 { result = String(result.prefix(200)) }
        return result.isEmpty ? "Skin" : result
    }

    /// Name used when a package or folder has to be named after itself: the file name without its extension.
    static func displayName(of url: URL) -> String {
        RmskinFiles.isDirectory(url) ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Plain archives

/// Detects the root configs of a package without manifest and rearranges the extracted (temporary) tree into the
/// standard layout — `Skins/<RootConfig>`, `Fonts/`, `Plugins/`, `Addons/`, `Layouts/`, `Themes/`, `@Vault/` — so the
/// rest of the installer (and anything that reads `packageRoot/Skins`) treats it like any other package.
///
/// Rules, in order (all names case-insensitive, hidden items ignored):
/// 1. A folder named `Skins` holding at least one skin folder, at the top or below a chain of single wrapper
///    folders (`PogPack 1.3/Skins/PogPack/…`): that is the package layout, used as is.
/// 2. The top of the archive is itself a root config (it has .ini files or `@Resources` directly): it is installed
///    as one root config named after the archive.
/// 3. Otherwise the folders containing skins (.ini files at any depth, outside `@…` folders; never one called
///    `Skins`) are root configs. A single such folder is a wrapper — and its sub-folders the root configs — only when
///    it is no root config itself and a folder below it (through at most three single wrappers) has `@Resources` or
///    is the folder the skins name in `#SKINSPATH#Name\…` paths. Without such a mark a single folder is the root
///    config, as the manual's manual-installation steps assume.
///    The component folders `Fonts`, `Plugins`, `Addons`, `Layouts`, `Themes` and `@Vault` next to them (at any
///    unwrapped level) are kept as package components, loose font files become package fonts, and everything else
///    outside the root configs (read-me files, previews, wallpapers) is not installed.
enum RmskinPlainArchive {
    static let componentFolders = ["Fonts", "Plugins", "Addons", "Layouts", "Themes", "@Vault"]
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]
    /// Font formats Windows skins ship that macOS cannot use (bitmap .fon/.fnt, Type 1 .pfb/.pfm/.pfa).
    static let unsupportedFontExtensions: Set<String> = ["fon", "fnt", "pfb", "pfm", "pfa"]
    /// Deepest folder looked at for .ini files (the app's skin scan stops at the same depth).
    static let maxScanDepth = 12
    /// Wrapper folders unwrapped at most.
    static let maxUnwrap = 3
    /// `#SKINSPATH#` references are read from at most this many files, this many bytes each.
    static let maxReferenceFiles = 64
    static let maxReferenceBytes = 256 * 1024

    struct Result {
        var packageRoot: URL
        var manifest: RmskinManifest
        var warnings: [String] = []
    }

    /// One walk over the extracted tree: which folders contain skins, which have .ini files or `@Resources` directly.
    struct TreeIndex {
        private(set) var containsSkins: Set<String> = []
        private(set) var directIni: Set<String> = []
        private(set) var hasResources: Set<String> = []
        /// Every skin .ini (outside `@…` folders), in walk order.
        private(set) var iniFiles: [URL] = []
        /// .ini and .inc files, for `#SKINSPATH#` references.
        private(set) var textFiles: [URL] = []

        init(_ root: URL) {
            _ = walk(root, depth: 0, reserved: false)
        }

        static func key(_ url: URL) -> String { url.standardizedFileURL.path }

        func containsSkins(_ url: URL) -> Bool { containsSkins.contains(TreeIndex.key(url)) }
        func isRootConfig(_ url: URL) -> Bool {
            let k = TreeIndex.key(url)
            return directIni.contains(k) || hasResources.contains(k)
        }

        /// Returns whether `folder` contains skins. `reserved` = inside an `@…` folder (not a config).
        private mutating func walk(_ folder: URL, depth: Int, reserved: Bool) -> Bool {
            guard depth <= RmskinPlainArchive.maxScanDepth else { return false }
            var found = false
            for child in RmskinFiles.visibleChildren(of: folder) {
                let name = child.lastPathComponent
                if RmskinFiles.isDirectory(child) {
                    if name.caseInsensitiveCompare("@Resources") == .orderedSame {
                        hasResources.insert(TreeIndex.key(folder))
                    }
                    let childReserved = reserved || name.hasPrefix("@")
                    if walk(child, depth: depth + 1, reserved: childReserved), !childReserved { found = true }
                } else {
                    let ext = child.pathExtension.lowercased()
                    if ext == "ini" || ext == "inc" { textFiles.append(child) }
                    if ext == "ini", !reserved {
                        directIni.insert(TreeIndex.key(folder))
                        iniFiles.append(child)
                        found = true
                    }
                }
            }
            if found { containsSkins.insert(TreeIndex.key(folder)) }
            return found
        }
    }

    /// Rearranges `extracted` (a temporary folder the caller owns) into the standard layout under
    /// `temporaryDirectory/normalized` when needed. Throws `.nothingToInstall` when no skin is found. At most
    /// `wrapperLevels` wrapper folders are unwrapped.
    static func normalize(_ extracted: URL, temporaryDirectory: URL, fallbackName: String,
                          wrapperLevels: Int = maxUnwrap) throws -> Result {
        let index = TreeIndex(extracted)
        guard !index.iniFiles.isEmpty else { throw RmskinError.nothingToInstall }
        let name = RmskinPackage.sanitizedRootName(fallbackName)

        // 1. A standard layout below single wrapper folders.
        var level = extracted
        for depth in 0...max(0, wrapperLevels) {
            if let skins = RmskinFiles.child(named: "Skins", in: level, directory: true),
               RmskinFiles.visibleChildren(of: skins).contains(where: {
                   RmskinFiles.isDirectory($0) && !$0.lastPathComponent.hasPrefix("@") && index.containsSkins($0)
               }) {
                var manifest = plainManifest(name: depth == 0 ? name : level.lastPathComponent)
                setSingleSkinLoad(&manifest, index: index, skinsFolder: skins)
                return Result(packageRoot: level, manifest: manifest)
            }
            let folders = RmskinFiles.visibleChildren(of: level).filter(RmskinFiles.isDirectory)
            guard depth < wrapperLevels, folders.count == 1, !index.isRootConfig(level) else { break }
            level = folders[0]
        }

        let fm = FileManager.default
        let normalized = temporaryDirectory.appendingPathComponent("normalized", isDirectory: true)
        let skins = normalized.appendingPathComponent("Skins", isDirectory: true)
        do {
            try fm.createDirectory(at: skins, withIntermediateDirectories: true)
        } catch {
            throw RmskinError.extractionFailed("cannot prepare the package: \(error.localizedDescription)")
        }

        // 2. The archive itself is one root config.
        if index.isRootConfig(extracted) {
            let destination = skins.appendingPathComponent(name, isDirectory: true)
            do {
                try fm.moveItem(at: extracted, to: destination)
            } catch {
                throw RmskinError.extractionFailed("cannot prepare the package: \(error.localizedDescription)")
            }
            var manifest = plainManifest(name: name)
            setSingleSkinLoad(&manifest, index: TreeIndex(skins), skinsFolder: skins)
            return Result(packageRoot: normalized, manifest: manifest)
        }

        // 3. Root configs below the top, unwrapping wrapper folders.
        let referenced = skinsPathReferences(index)
        func skinFolders(in folder: URL) -> [URL] {
            RmskinFiles.visibleChildren(of: folder).filter { url in
                RmskinFiles.isDirectory(url) && index.containsSkins(url) && !isComponentFolder(url.lastPathComponent)
                    && url.lastPathComponent.caseInsensitiveCompare("Skins") != .orderedSame
            }
        }
        func marksRootConfig(_ folder: URL) -> Bool {
            index.hasResources.contains(TreeIndex.key(folder)) || referenced.contains(folder.lastPathComponent.lowercased())
        }
        /// A folder is a wrapper when it is no root config itself and a root config marked by `@Resources` or a
        /// `#SKINSPATH#` reference lies below it (through further single wrappers).
        func isWrapper(_ folder: URL, budget: Int) -> Bool {
            guard budget > 0, !index.isRootConfig(folder), !marksRootConfig(folder) else { return false }
            let inner = skinFolders(in: folder)
            if inner.contains(where: marksRootConfig) { return true }
            return inner.count == 1 && isWrapper(inner[0], budget: budget - 1)
        }
        var levels: [URL] = [extracted]
        var current = extracted
        var roots: [URL] = []
        while true {
            let candidates = skinFolders(in: current)
            let budget = wrapperLevels - (levels.count - 1)
            guard candidates.count == 1, isWrapper(candidates[0], budget: budget) else {
                roots = candidates
                break
            }
            current = candidates[0]
            levels.append(current)
        }
        guard !roots.isEmpty else { throw RmskinError.nothingToInstall }

        var result = Result(packageRoot: normalized, manifest: plainManifest(
            name: roots.count == 1 ? roots[0].lastPathComponent : (levels.count > 1 ? current.lastPathComponent : name)))
        do {
            for root in roots {
                try fm.moveItem(at: root, to: skins.appendingPathComponent(root.lastPathComponent, isDirectory: true))
            }
            // Package components and loose fonts next to the root configs or their wrappers.
            var ignored: [String] = []
            for folder in levels.reversed() {
                for item in RmskinFiles.visibleChildren(of: folder) {
                    let itemName = item.lastPathComponent
                    if levels.contains(where: { TreeIndex.key($0) == TreeIndex.key(item) }) { continue }
                    if RmskinFiles.isDirectory(item) {
                        if let component = componentFolders.first(where: {
                            $0.caseInsensitiveCompare(itemName) == .orderedSame }) {
                            try RmskinFiles.mergeMove(from: item,
                                                      to: normalized.appendingPathComponent(component, isDirectory: true))
                        } else {
                            ignored.append(itemName)
                        }
                    } else if fontExtensions.contains(item.pathExtension.lowercased())
                                || unsupportedFontExtensions.contains(item.pathExtension.lowercased()) {
                        let fonts = normalized.appendingPathComponent("Fonts", isDirectory: true)
                        try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
                        try RmskinFiles.mergeMove(from: item, to: fonts.appendingPathComponent(itemName))
                    }
                }
            }
            if !ignored.isEmpty {
                let list = ignored.prefix(6).joined(separator: ", ") + (ignored.count > 6 ? ", …" : "")
                result.warnings.append("Folders without skins were not installed: \(list)")
            }
        } catch {
            throw RmskinError.extractionFailed("cannot prepare the package: \(error.localizedDescription)")
        }
        setSingleSkinLoad(&result.manifest, index: TreeIndex(skins), skinsFolder: skins)
        return result
    }

    static func isComponentFolder(_ name: String) -> Bool {
        componentFolders.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func plainManifest(name: String) -> RmskinManifest {
        var manifest = RmskinManifest()
        manifest.packageFormat = .plain
        manifest.name = name
        return manifest
    }

    /// A plain archive holding exactly one skin (.ini file) loads it after installation — there is nothing to choose
    /// from. With more skins nothing is loaded, as with a manual installation.
    static func setSingleSkinLoad(_ manifest: inout RmskinManifest, index: TreeIndex, skinsFolder: URL) {
        let base = TreeIndex.key(skinsFolder) + "/"
        let inis = index.iniFiles.filter { TreeIndex.key($0).hasPrefix(base) }
        guard inis.count == 1 else { return }
        let relative = String(TreeIndex.key(inis[0]).dropFirst(base.count)).split(separator: "/").map(String.init)
        guard relative.count >= 2 else { return } // a loose .ini directly in Skins is no skin
        manifest.loadType = "Skin"
        manifest.load = relative.joined(separator: "\\")
    }

    /// Root config names the skins refer to with `#SKINSPATH#Name\…` (lowercased), from the first few .ini / .inc
    /// files. Old skins often address their files this way instead of `#@#`, which tells which folder is meant to be
    /// the root config.
    static func skinsPathReferences(_ index: TreeIndex) -> Set<String> {
        var names: Set<String> = []
        let marker = Array("#skinspath#".utf8)
        for file in index.textFiles.prefix(maxReferenceFiles) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let data = (try? handle.read(upToCount: maxReferenceBytes)) ?? Data()
            try? handle.close()
            let text = Array(TextDecoding.decode(data).lowercased().utf8)
            var i = 0
            while i + marker.count <= text.count {
                guard text[i] == 0x23, Array(text[i..<(i + marker.count)]) == marker else {
                    i += 1
                    continue
                }
                var j = i + marker.count
                let start = j
                while j < text.count, ![0x5C, 0x2F, 0x23, 0x22, 0x0A, 0x0D, 0x5D, 0x7C].contains(text[j]) { j += 1 }
                // Only `Name\` or `Name/` counts: `#SKINSPATH#Name` alone may be a file.
                if j < text.count, text[j] == 0x5C || text[j] == 0x2F, j > start,
                   let name = String(bytes: text[start..<j], encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
                   !name.isEmpty {
                    names.insert(name)
                }
                i = j
            }
        }
        return names
    }
}

// MARK: - Folders

extension RmskinPackage {
    /// Inspects an already extracted package or skin folder — an extracted .rmskin (with RMSKIN.ini), a legacy
    /// Rainstaller folder, a root config folder, or a folder holding several root configs. The folder is copied to a
    /// temporary folder first (it is never modified); symbolic links, special files and hidden items are skipped.
    /// The folder itself is what the user would move into the Skins folder, so detection sees it the way it sees a
    /// ZIP of that folder: it is the root config unless it is marked as a wrapper (see `RmskinPlainArchive`).
    /// A folder without skins holding exactly one .rmskin file inspects that package instead.
    /// Throws `.nothingToInstall` when it contains no skin, `.severalPackages` when it holds only .rmskin packages,
    /// and `.extractionFailed` when it is too large to be a skin (more than 200 000 items or 4 GB). Call `cleanup()`
    /// on the result. Installing it into a Skins folder that contains it, is it, or lies inside it throws
    /// `.alreadyInSkinsFolder`.
    public static func inspect(folder: URL) throws -> RmskinInspection {
        try inspect(folder: folder, openingWrappedPackage: true)
    }

    static func inspect(folder: URL, openingWrappedPackage: Bool) throws -> RmskinInspection {
        guard RmskinFiles.isDirectory(folder) else {
            throw RmskinError.unreadable("\(folder.lastPathComponent) is not a folder")
        }
        let survey = try RmskinFolderCopy.survey(folder)
        guard survey.hasSkinFiles else {
            guard openingWrappedPackage, !survey.packages.isEmpty else { throw RmskinError.nothingToInstall }
            return try inspectWrappedPackage(survey.packages)
        }
        let temporary: URL
        do {
            temporary = try RmskinFiles.makeTemporaryDirectory("rmskin")
        } catch {
            throw RmskinError.extractionFailed("cannot create a temporary folder: \(error.localizedDescription)")
        }
        do {
            // Copied *with* the folder (package/<Name>/…), like a ZIP made of the folder: one more wrapper level.
            let extracted = temporary.appendingPathComponent("package", isDirectory: true)
            let copy = extracted.appendingPathComponent(sanitizedRootName(folder.lastPathComponent), isDirectory: true)
            var warnings = try RmskinFolderCopy.copy(folder, to: copy)
            warnings += try RmskinZip.sanitizeExtractedTree(at: extracted)
            var inspection = try describe(extracted, temporaryDirectory: temporary, requiresManifest: false,
                                          fallbackName: displayName(of: folder),
                                          wrapperLevels: RmskinPlainArchive.maxUnwrap + 1)
            inspection.warnings.insert(contentsOf: warnings, at: 0)
            inspection.sourceFolder = folder
            return inspection
        } catch {
            RmskinFiles.forceRemove(temporary)
            throw error
        }
    }

    /// File extensions `inspect` accepts besides folders (`rmskin`, and `zip` for plain or legacy archives).
    public static let supportedFileExtensions = ["rmskin", "zip"]

    /// True for folders and files with a supported extension (what an app should offer to install).
    public static func canInspect(_ url: URL) -> Bool {
        RmskinFiles.isDirectory(url) || supportedFileExtensions.contains(url.pathExtension.lowercased())
    }
}

/// Copies a user's folder for inspection without following links and within the package limits.
enum RmskinFolderCopy {
    struct Survey {
        var items = 0
        var bytes: UInt64 = 0
        /// The folder holds .ini files (other than Windows' `desktop.ini`), RMSKIN.ini or Rainstaller.cfg.
        var hasSkinFiles = false
        /// Paths of the .rmskin files found (at most `maxPackages`).
        var packages: [String] = []
    }

    static let maxPackages = 64

    /// Walks `folder` (never following links) and refuses trees over the extraction limits.
    static func survey(_ folder: URL) throws -> Survey {
        var survey = Survey()
        var pending: [(String, Int)] = [(folder.path, 0)]
        let fm = FileManager.default
        while let (path, depth) = pending.popLast() {
            guard let names = try? fm.contentsOfDirectory(atPath: path) else {
                if depth == 0 { throw RmskinError.unreadable("cannot read the folder \((path as NSString).lastPathComponent)") }
                continue
            }
            for name in names where !RmskinFiles.isIgnoredName(name) {
                survey.items += 1
                guard UInt64(survey.items) <= RmskinZip.maxEntries else {
                    throw RmskinError.extractionFailed("the folder contains too many files to be a skin")
                }
                let child = (path as NSString).appendingPathComponent(name)
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    if depth + 1 <= RmskinZip.maxPathDepth { pending.append((child, depth + 1)) }
                case S_IFREG:
                    survey.bytes &+= UInt64(max(0, info.st_size))
                    guard survey.bytes <= RmskinZip.maxTotalUncompressedSize else {
                        throw RmskinError.extractionFailed("the folder is too large to be a skin")
                    }
                    let lower = name.lowercased()
                    if lower.hasSuffix(".ini") || lower == "rainstaller.cfg" { survey.hasSkinFiles = true }
                    if lower.hasSuffix(".rmskin"), survey.packages.count < maxPackages { survey.packages.append(child) }
                default:
                    break
                }
            }
        }
        return survey
    }

    /// Copies `source` to `destination` (created), skipping hidden items, links and special files. Returns warnings.
    static func copy(_ source: URL, to destination: URL) throws -> [String] {
        let fm = FileManager.default
        var warnings: [String] = []
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw RmskinError.extractionFailed("cannot create a temporary folder: \(error.localizedDescription)")
        }
        var pending: [(URL, URL, Int)] = [(source, destination, 0)]
        while let (from, to, depth) = pending.popLast() {
            guard let names = try? fm.contentsOfDirectory(atPath: from.path) else {
                warnings.append("Could not read the folder \(from.lastPathComponent)")
                continue
            }
            for name in names.sorted() where !RmskinFiles.isIgnoredName(name) {
                let item = from.appendingPathComponent(name)
                let target = to.appendingPathComponent(name)
                var info = stat()
                guard lstat(item.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    guard depth + 1 <= RmskinZip.maxPathDepth else {
                        throw RmskinError.extractionFailed("folders are nested too deeply")
                    }
                    do {
                        try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    } catch {
                        throw RmskinError.extractionFailed("cannot copy \(name): \(error.localizedDescription)")
                    }
                    pending.append((item, target, depth + 1))
                case S_IFREG:
                    do {
                        try fm.copyItem(at: item, to: target)
                    } catch {
                        warnings.append("Could not copy \(name): \(error.localizedDescription)")
                    }
                case S_IFLNK:
                    warnings.append("Ignored symbolic link \(name)")
                default:
                    warnings.append("Ignored special file \(name)")
                }
            }
        }
        return warnings
    }
}

// MARK: - Package components shared by every format

extension RmskinPackage {
    /// Legacy `Themes\<name>\Rainmeter.thm` (Rainmeter before 2.4: "Changed the term 'Themes' to 'Layouts'
    /// throughout Rainmeter") become `Layouts\<name>\Rainmeter.ini` inside the extracted package, so they install
    /// like layouts. A theme whose name a layout of the package already uses is skipped.
    static func convertThemesToLayouts(in root: URL, warnings: inout [String]) {
        guard let themes = RmskinFiles.child(named: "Themes", in: root, directory: true) else { return }
        let items = RmskinFiles.visibleChildren(of: themes)
        guard !items.isEmpty else { return }
        let layouts = RmskinFiles.child(named: "Layouts", in: root, directory: true)
            ?? root.appendingPathComponent("Layouts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: layouts, withIntermediateDirectories: true)
        } catch {
            warnings.append("Could not read the themes of the package: \(error.localizedDescription)")
            return
        }
        for item in items {
            let name = item.lastPathComponent
            guard RmskinFiles.isDirectory(item) else {
                warnings.append("Ignored file \(name) outside a theme folder")
                continue
            }
            if RmskinFiles.child(named: name, in: layouts) != nil {
                warnings.append("Ignored theme \(name): the package also has a layout of that name")
                continue
            }
            let target = layouts.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.moveItem(at: item, to: target)
            } catch {
                warnings.append("Could not read theme \(name): \(error.localizedDescription)")
                continue
            }
            guard RmskinFiles.child(named: "Rainmeter.ini", in: target, directory: false) == nil else { continue }
            let themeFiles = RmskinFiles.visibleChildren(of: target).filter {
                RmskinFiles.isRegularFile($0) && $0.pathExtension.lowercased() == "thm"
            }
            if let file = RmskinFiles.child(named: "Rainmeter.thm", in: target, directory: false)
                ?? (themeFiles.count == 1 ? themeFiles[0] : nil) {
                try? FileManager.default.moveItem(at: file, to: target.appendingPathComponent("Rainmeter.ini"))
            }
        }
    }

    /// Fonts a Windows user would have installed by hand, placed where Deskset loads them (`@Resources/Fonts` of the
    /// installed root configs, never a system font folder):
    /// - the package's `Fonts/` folder (legacy .rmskin and Rainstaller packages, plain archives) and loose font files
    ///   at the top of the package → `legacyFonts`, copied into every installed root config;
    /// - a root config's own `Fonts/` folder (`<RootConfig>/Fonts`, beside rather than inside `@Resources`) and font
    ///   files loose at the top of the root config → `rootConfigFonts`, copied into that root config's
    ///   `@Resources/Fonts`.
    /// TrueType / OpenType files (.ttf .otf .ttc .otc) only; Windows bitmap and Type 1 fonts are reported.
    static func describeFonts(_ root: URL, inspection: inout RmskinInspection) {
        var unsupported: [String] = []
        func fonts(in files: [URL]) -> [URL] {
            var result: [URL] = []
            for file in files {
                let ext = file.pathExtension.lowercased()
                if RmskinPlainArchive.fontExtensions.contains(ext) {
                    result.append(file)
                } else if RmskinPlainArchive.unsupportedFontExtensions.contains(ext) {
                    unsupported.append(file.lastPathComponent)
                }
            }
            return result
        }
        var packageFonts: [URL] = []
        if let folder = RmskinFiles.child(named: "Fonts", in: root, directory: true) {
            packageFonts += fonts(in: RmskinFiles.allFiles(in: folder))
        }
        packageFonts += fonts(in: RmskinFiles.visibleChildren(of: root).filter(RmskinFiles.isRegularFile))
        inspection.legacyFonts = packageFonts

        if let skins = inspection.skinsFolder {
            for rootConfig in inspection.rootConfigs {
                let rootFolder = skins.appendingPathComponent(rootConfig)
                var own: [URL] = []
                if let folder = RmskinFiles.child(named: "Fonts", in: rootFolder, directory: true) {
                    own += fonts(in: RmskinFiles.allFiles(in: folder))
                }
                // Font files lying loose next to the skins (a common way to ship a hand-zipped skin's font).
                own += fonts(in: RmskinFiles.visibleChildren(of: rootFolder).filter(RmskinFiles.isRegularFile))
                if !own.isEmpty { inspection.rootConfigFonts[rootConfig] = own }
            }
        }
        if !unsupported.isEmpty {
            let list = unsupported.prefix(6).joined(separator: ", ") + (unsupported.count > 6 ? ", …" : "")
            inspection.warnings.append("Some fonts use a Windows-only format (bitmap or Type 1) that macOS can’t use "
                + "and were not installed: \(list)")
        }
    }

    /// A legacy launch command may name only a config folder (`!ActivateConfig "Suite\Clock"`): the first .ini in it
    /// (in Finder order) is the skin to load.
    static func completeSkinLoad(_ inspection: inout RmskinInspection) {
        let manifest = inspection.manifest
        let load = manifest.load.trimmingCharacters(in: .whitespaces)
        guard manifest.loadType.caseInsensitiveCompare("Skin") == .orderedSame, !load.isEmpty,
              !load.lowercased().hasSuffix(".ini"), let skins = inspection.skinsFolder,
              let parts = RmskinFiles.pathComponents(load), !parts.isEmpty,
              let resolved = RmskinFiles.resolveCaseInsensitively(parts, from: skins) else { return }
        let folder = RmskinFiles.appending(resolved, to: skins)
        guard RmskinFiles.isDirectory(folder) else { return }
        let first = RmskinFiles.visibleChildren(of: folder)
            .filter { RmskinFiles.isRegularFile($0) && $0.pathExtension.lowercased() == "ini" }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first
        guard let file = first else { return }
        inspection.manifest.load = (resolved + [file]).joined(separator: "\\")
    }
}

extension RmskinFiles {
    /// Path components of `file` relative to `base` (both from the same walk), or nil when it is not below it.
    static func relativeComponents(of file: URL, in base: URL) -> [String]? {
        let prefix = base.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        return parts.isEmpty ? nil : parts
    }
}
