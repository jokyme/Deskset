import Foundation

// .rmskin packages — clean-room implementation from the public manual only:
//   https://docs.rainmeter.net/manual/distributing-skins/        (Skin Packager: fields, Variables files, Merge skins)
//   https://docs.rainmeter.net/manual/installing-skins/          (Skin Installer: Skins, Layouts, Plugins, Backup)
//   https://docs.rainmeter.net/manual/distributing-skins/vault-folder/   (@Vault)
//   https://docs.rainmeter.net/manual/skins/resources-folder/    (@Resources\Fonts are loaded by the skin itself)
//   https://docs.rainmeter.net/manual/settings/  and  /manual/user-interface/manage/  (layouts, [Rainmeter] options)
//   https://docs.rainmeter.net/history/  ("Remove all [Rainmeter] section options from layouts installed by a .rmskin")
//
// Package file: a ZIP followed by a 16-byte footer (8-byte little-endian ZIP length + "\0RMSKIN\0"). Inside:
//   RMSKIN.ini ([rmskin] section), optional RMSKIN.bmp header image (400x60), Skins\<one root config>,
//   optional Layouts\<name>\..., Plugins\ (Windows DLLs), and legacy (pre-2.4) Fonts\ / Addons\ folders.
// Legacy Rainstaller packages, plain ZIP archives and extracted folders are handled in RmskinLegacy.swift.

public enum RmskinError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case notAPackage(String)
    case extractionFailed(String)
    case missingManifest
    case nothingToInstall
    /// A folder given to `RmskinPackage.inspect(folder:)` is the Skins folder, inside it, or contains it.
    case alreadyInSkinsFolder
    /// A ZIP archive or folder holds no skin but several .rmskin packages (their file names): the user has to open
    /// them one at a time. (With exactly one, that package is inspected instead.)
    case severalPackages([String])

    public var description: String {
        switch self {
        case .unreadable(let s): return "Cannot read package: \(s)"
        case .notAPackage(let s): return "Not a .rmskin package: \(s)"
        case .extractionFailed(let s): return "Extraction failed: \(s)"
        case .missingManifest: return "RMSKIN.ini not found in package"
        case .nothingToInstall: return "Package contains no skins"
        case .alreadyInSkinsFolder: return "The folder is already in the Skins folder"
        case .severalPackages(let names):
            let list = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", …" : "")
            return "It contains several skin packages (\(list)); extract it and open them one at a time"
        }
    }
}

// MARK: - Manifest

/// `RMSKIN.ini` → `[rmskin]` section.
///
/// The manual documents the Skin Packager fields (Name, Author, Version, "After installation: Load skin / Load
/// layout", minimum Rainmeter / Windows version, header image, Variables files, Merge skins) but not the key names
/// written to RMSKIN.ini; the key names used here are the ones the packager fields map to. Every key is also kept in
/// `raw`, so anything else is still reachable.
public struct RmskinManifest: Equatable {
    public var name: String = ""
    public var author: String = ""
    public var version: String = ""
    /// `Skin` or `Layout` (as written); empty when absent.
    public var loadType: String = ""
    /// `Config\Sub\File.ini` for skins, the layout name for layouts; backslashes kept as written.
    public var load: String = ""
    /// `VariableFiles=` entries (paths relative to the Skins folder, `|`-separated in the file).
    public var variableFiles: [String] = []
    public var mergeSkins: Bool = false
    public var minimumRainmeter: String = ""
    public var minimumWindows: String = ""
    /// Every key/value of the `[rmskin]` section (`[Rainstaller]` for legacy packages), for anything not modelled
    /// above.
    public var raw: IniSection = IniSection(name: "rmskin")
    /// Where the manifest came from: RMSKIN.ini, a legacy Rainstaller.cfg, or none (a plain archive or folder, with
    /// a manifest made up by the installer: `name` only, plus `Load` when the package holds exactly one skin).
    public var packageFormat: RmskinPackageFormat = .rmskin
    /// Legacy `KeepVar=1`: keep the user's `[Variables]` values in every .ini / .inc file of the installed root
    /// configs (like listing all of them in `variableFiles`).
    public var keepsAllVariables: Bool = false

    public init() {}

    public static func parse(_ text: String) -> RmskinManifest {
        var manifest = RmskinManifest()
        guard let section = IniDocument.parse(text).section(named: "rmskin") else { return manifest }
        manifest.raw = section
        func string(_ key: String) -> String {
            (section[key] ?? "").trimmingCharacters(in: .whitespaces)
        }
        manifest.name = string("Name")
        manifest.author = string("Author")
        manifest.version = string("Version")
        manifest.loadType = string("LoadType")
        manifest.load = string("Load")
        manifest.minimumRainmeter = string("MinimumRainmeter")
        manifest.minimumWindows = string("MinimumWindows")
        // `Merge=1/0` is the pre-2.4 (Rainstaller) spelling: "Rainstaller: Added Merge=1/0 to support addons for
        // suites" (version history). `MergeSkins` wins when both are present.
        manifest.mergeSkins = parseBool(section["MergeSkins"] != nil ? string("MergeSkins") : string("Merge"))
        // "You may specify multiple files by separating them with pipes (|), e.g.
        //  illustro\Clock\Variables.inc | illustro\Feeds\Variables.inc" — spaces around the pipes are allowed.
        manifest.variableFiles = string("VariableFiles")
            .split(separator: "|")
            .map { IniDocument.unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        return manifest
    }

    /// Reads and parses a RMSKIN.ini file (UTF-8, UTF-16 or ANSI).
    public static func parse(contentsOf url: URL) throws -> RmskinManifest {
        do {
            return parse(try TextDecoding.readFile(at: url))
        } catch {
            throw RmskinError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Rainmeter options are `0`/`1`; any non-zero number counts as true. `true`/`yes`/`on` are accepted too
    /// (hand-written manifests).
    static func parseBool(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        if let number = Double(v) { return number != 0 }
        return v == "true" || v == "yes" || v == "on"
    }

    /// Compares dotted version strings the way the manual describes `MinimumRainmeter` ("Major.Minor.Patch.Revision";
    /// a shorter number such as `4` or `4.2` targets every revision of that version): components are compared
    /// numerically, missing components count as 0, and non-numeric components use their leading digits (or 0).
    /// An empty `minimum` is always satisfied.
    public static func version(_ version: String, isAtLeast minimum: String) -> Bool {
        let a = versionComponents(version), b = versionComponents(minimum)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    static func versionComponents(_ version: String) -> [Int] {
        version.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
            .prefix(16)
            .map { part in
                let digits = part.trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && $0.isNumber }
                return Int(digits.prefix(9)) ?? 0
            }
    }
}

// MARK: - Package

public enum RmskinPackage {
    /// The 8 trailing magic bytes `\0RMSKIN\0`.
    public static let footerMagic: [UInt8] = [0x00, 0x52, 0x4D, 0x53, 0x4B, 0x49, 0x4E, 0x00]

    /// Returns the ZIP payload of a .rmskin file: data minus the 16-byte footer (8-byte little-endian ZIP length +
    /// magic). A plain ZIP without footer is accepted as-is. Throws `.notAPackage` for anything else.
    public static func zipPayload(of data: Data) throws -> Data {
        let count = data.count
        if count >= 16 {
            let footer = [UInt8](data.suffix(16))
            if Array(footer[8..<16]) == footerMagic {
                var length: UInt64 = 0
                for (shift, byte) in footer[0..<8].enumerated() { length |= UInt64(byte) << (8 * UInt64(shift)) }
                guard length > 0, length <= UInt64(count - 16) else {
                    throw RmskinError.notAPackage("the footer records a ZIP length of \(length) bytes, "
                        + "but the file only has \(count - 16) (truncated or damaged file)")
                }
                // The ZIP is at the start of the file. A shorter recorded length than the space before the footer
                // is accepted (the manual does not describe padding); the bytes in between are ignored.
                // `prefix` shares the (possibly memory-mapped) storage; a slice not starting at 0 is copied so the
                // result is always indexed from 0.
                let payload = data.startIndex == 0
                    ? data.prefix(Int(length))
                    : data.subdata(in: data.startIndex..<(data.startIndex + Int(length)))
                guard startsWithZipSignature(payload) else {
                    throw RmskinError.notAPackage("the package does not contain a ZIP archive")
                }
                return payload
            }
        }
        // Plain ZIP (e.g. a renamed .zip). Rainmeter ≥ 2.3 refuses these; being lenient costs nothing.
        if startsWithZipSignature(data) {
            return data.startIndex == 0 ? data : Data(data)
        }
        throw RmskinError.notAPackage(count < 16 ? "the file is too small" : "the .rmskin footer is missing")
    }

    private static func startsWithZipSignature(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
    }

    /// Extracts the package into `directory` (created if needed) with `/usr/bin/ditto -x -k`, returning `directory`.
    ///
    /// Before anything is written the ZIP directory is checked: absolute paths, drive letters, `..` components and
    /// symbolic links are refused (zip-slip), as are archives with more than 200 000 entries or 4 GB of content.
    /// Because ditto follows the local headers rather than that directory, the limits are also enforced on what it
    /// really writes: it is stopped as soon as the output outgrows the declared size (ZIP bombs). Extraction skips
    /// AppleDouble metadata (no ACLs / extended attributes from the package) but keeps the package's quarantine flag.
    /// Afterwards the owner gets full access to every extracted item, links, special files and `__MACOSX` are
    /// removed, and names containing `\` (Windows tools, or ditto's escapes for non-UTF-8 names) become folders.
    /// When this throws, `directory` may hold a partial extraction.
    public static func extract(_ packageURL: URL, into directory: URL) throws -> URL {
        _ = try extractCollectingWarnings(packageURL, into: directory)
        return directory
    }

    static func extractCollectingWarnings(_ packageURL: URL, into directory: URL) throws -> [String] {
        try extractPackage(packageURL, into: directory).warnings
    }

    /// True when `data` ends with the 16-byte .rmskin footer (valid or not).
    static func hasFooter(_ data: Data) -> Bool {
        data.count >= 16 && Array(data.suffix(8)) == footerMagic
    }

    struct Extraction {
        var warnings: [String]
        /// The file ends with the .rmskin footer (made by the Skin Packager, so RMSKIN.ini is required).
        var hasFooter: Bool
        /// The archive holds no skin, only .rmskin package(s) (a download wrapping the real package in a ZIP).
        var holdsOnlyPackages = false
    }

    /// Largest archive (declared uncompressed size) opened only to reach a .rmskin package inside it. Real packages
    /// are a few MB; the limit keeps "archive in an archive" from doubling the extraction limits.
    static let maxWrappingArchiveBytes: UInt64 = 512 << 20

    /// The name components of a ZIP entry (`/` or `\` separated), lowercased.
    private static func entryComponents(_ entry: RmskinZipEntry) -> [String] {
        entry.name.lowercased().split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
    }

    /// A file entry that makes an archive worth extracting: a skin (.ini, except Windows' `desktop.ini`) or a
    /// manifest (RMSKIN.ini is an .ini; Rainstaller.cfg).
    private static func isSkinEntry(_ entry: RmskinZipEntry) -> Bool {
        guard !entry.isDirectory, let last = entryComponents(entry).last else { return false }
        return (last.hasSuffix(".ini") && !RmskinFiles.windowsMetadataNames.contains(last)) || last == "rainstaller.cfg"
    }

    /// A visible `.rmskin` file entry (not in a hidden or `__MACOSX` folder).
    private static func isPackageEntry(_ entry: RmskinZipEntry) -> Bool {
        let parts = entryComponents(entry)
        guard !entry.isDirectory, let last = parts.last, last.hasSuffix(".rmskin") else { return false }
        return !parts.contains(where: RmskinFiles.isIgnoredName)
    }

    /// `extract` plus what `inspect` needs to know. With `refuseArchivesWithoutSkins`, an archive without footer
    /// whose ZIP directory lists no .ini file and no Rainstaller.cfg is refused with `.nothingToInstall` before
    /// anything is written (someone dropped an unrelated ZIP) — unless `allowPackages` is set and it lists a .rmskin
    /// file and is no larger than `maxWrappingArchiveBytes` (`holdsOnlyPackages` in the result).
    static func extractPackage(_ packageURL: URL, into directory: URL, refuseArchivesWithoutSkins: Bool = false,
                               allowPackages: Bool = false) throws -> Extraction {
        let fm = FileManager.default
        let data: Data
        do {
            data = try Data(contentsOf: packageURL, options: .mappedIfSafe)
        } catch {
            throw RmskinError.unreadable("\(packageURL.lastPathComponent): \(error.localizedDescription)")
        }
        let payload = try zipPayload(of: data)
        let footer = hasFooter(data)
        let entries: [RmskinZipEntry]
        do {
            entries = try RmskinZip.scanCentralDirectory(payload)
        } catch let error as RmskinZip.ScanError {
            throw RmskinError.extractionFailed(error.description)
        }
        let declaredBytes = entries.reduce(UInt64(0)) { $0 &+ $1.uncompressedSize }
        var holdsOnlyPackages = false
        if refuseArchivesWithoutSkins, !footer, !entries.contains(where: isSkinEntry) {
            guard allowPackages, declaredBytes <= maxWrappingArchiveBytes, entries.contains(where: isPackageEntry) else {
                throw RmskinError.nothingToInstall
            }
            holdsOnlyPackages = true
        }
        let hasLegacyNames = entries.contains { !$0.nameIsUTF8 }

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RmskinError.extractionFailed("cannot create \(directory.path): \(error.localizedDescription)")
        }

        // ditto needs a real ZIP file: write the payload (without the footer) next to nothing else.
        let workDirectory: URL
        do {
            workDirectory = try RmskinFiles.makeTemporaryDirectory("zip")
        } catch {
            throw RmskinError.extractionFailed("cannot create a temporary folder: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: workDirectory) }
        let zipURL = workDirectory.appendingPathComponent("package.zip")
        do {
            try payload.write(to: zipURL)
        } catch {
            throw RmskinError.extractionFailed("cannot write a temporary file: \(error.localizedDescription)")
        }
        // ditto hands the archive's quarantine flag on to what it extracts; the temporary copy needs it for that.
        RmskinZip.copyQuarantine(from: packageURL, to: zipURL)

        // Whatever `directory` already held does not count against the package (normally it is empty).
        let preexistingBytes = RmskinZip.measureOutput(directory).bytes
        let monitor = RmskinZip.outputMonitor(for: directory, declaredBytes: declaredBytes)
        let (status, message) = try RmskinZip.runDitto(["-x", "-k", "--norsrc", "--qtn", zipURL.path, directory.path],
                                                       monitor: monitor)
        guard status == 0 else {
            throw RmskinError.extractionFailed(message.isEmpty ? "ditto exited with status \(status)" : message)
        }
        let byteLimit = preexistingBytes &+ min(declaredBytes, RmskinZip.maxTotalUncompressedSize)
            &+ RmskinZip.outputSlack
        let warnings = try RmskinZip.sanitizeExtractedTree(at: directory, decodeEscapes: hasLegacyNames,
                                                           maxBytes: byteLimit)
        return Extraction(warnings: warnings, hasFooter: footer, holdsOnlyPackages: holdsOnlyPackages)
    }

    /// Extracts the package into a new temporary folder and describes it, for a confirmation dialog before
    /// installing. Call `cleanup()` on the result when done (or pass it to `RmskinInstaller.install(inspection:…)`
    /// and clean up afterwards). The temporary folder is removed whenever this throws.
    ///
    /// Accepted: .rmskin packages (RMSKIN.ini), legacy Rainstaller packages (Rainstaller.cfg), plain ZIP archives
    /// without manifest (whatever their extension: root configs are detected, see `RmskinPlainArchive`) and folders
    /// (forwarded to `inspect(folder:)`). A file with the .rmskin footer must contain RMSKIN.ini (or Rainstaller.cfg)
    /// — `.missingManifest` otherwise, as the Skin Packager always writes one; an archive without any skin throws
    /// `.nothingToInstall`. A ZIP without skins that wraps exactly one .rmskin (as many download sites deliver them)
    /// is opened and that package inspected instead (one level deep only); with several, `.severalPackages`.
    public static func inspect(_ packageURL: URL) throws -> RmskinInspection {
        try inspect(packageURL, openingWrappedPackage: true)
    }

    static func inspect(_ packageURL: URL, openingWrappedPackage: Bool) throws -> RmskinInspection {
        if RmskinFiles.isDirectory(packageURL) {
            return try inspect(folder: packageURL, openingWrappedPackage: openingWrappedPackage)
        }
        let temporary: URL
        do {
            temporary = try RmskinFiles.makeTemporaryDirectory("rmskin")
        } catch {
            throw RmskinError.extractionFailed("cannot create a temporary folder: \(error.localizedDescription)")
        }
        do {
            let extracted = temporary.appendingPathComponent("package", isDirectory: true)
            let extraction = try extractPackage(packageURL, into: extracted, refuseArchivesWithoutSkins: true,
                                                allowPackages: openingWrappedPackage)
            if extraction.holdsOnlyPackages {
                // The inner package is extracted into its own temporary folder; this one goes once that is done.
                var inner = try inspectWrappedPackage(RmskinFiles.allFiles(in: extracted).map(\.path))
                inner.warnings.insert(contentsOf: extraction.warnings, at: 0)
                RmskinFiles.forceRemove(temporary)
                return inner
            }
            var inspection = try describe(extracted, temporaryDirectory: temporary,
                                          requiresManifest: extraction.hasFooter,
                                          fallbackName: displayName(of: packageURL))
            inspection.warnings.insert(contentsOf: extraction.warnings, at: 0)
            return inspection
        } catch {
            RmskinFiles.forceRemove(temporary)
            throw error
        }
    }

    /// Inspects the only `.rmskin` among `paths` (files of a wrapping archive or folder), never opening a further
    /// wrapper. Throws `.nothingToInstall` without one and `.severalPackages` with more.
    static func inspectWrappedPackage(_ paths: [String]) throws -> RmskinInspection {
        let packages = paths.filter { ($0 as NSString).pathExtension.lowercased() == "rmskin" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard packages.count == 1 else {
            if packages.isEmpty { throw RmskinError.nothingToInstall }
            throw RmskinError.severalPackages(packages.map { ($0 as NSString).lastPathComponent })
        }
        return try inspect(URL(fileURLWithPath: packages[0]), openingWrappedPackage: false)
    }

    /// Builds an inspection of an already extracted package folder (inside `temporaryDirectory`, which this may
    /// rearrange). RMSKIN.ini wins over Rainstaller.cfg; each is looked for at the top and below single wrapper
    /// folders (`locateManifest`). Without either, `requiresManifest` throws `.missingManifest`, otherwise the root
    /// configs are detected (`fallbackName` names a package that is itself one root config). `wrapperLevels` is how
    /// many single wrapper folders are looked through.
    static func describe(_ extracted: URL, temporaryDirectory: URL, requiresManifest: Bool = true,
                         fallbackName: String = "",
                         wrapperLevels: Int = RmskinPlainArchive.maxUnwrap) throws -> RmskinInspection {
        if let found = locateManifest(named: "RMSKIN.ini", in: extracted, wrapperLevels: wrapperLevels) {
            return try describeLayout(found.root, manifest: try RmskinManifest.parse(contentsOf: found.file),
                                      temporaryDirectory: temporaryDirectory)
        }
        if let found = locateManifest(named: "Rainstaller.cfg", in: extracted, wrapperLevels: wrapperLevels) {
            return try describeLayout(found.root, manifest: try RmskinManifest.parseRainstaller(contentsOf: found.file),
                                      temporaryDirectory: temporaryDirectory)
        }
        guard !requiresManifest else { throw RmskinError.missingManifest }
        let plain = try RmskinPlainArchive.normalize(extracted, temporaryDirectory: temporaryDirectory,
                                                     fallbackName: fallbackName, wrapperLevels: wrapperLevels)
        var inspection = try describeLayout(plain.packageRoot, manifest: plain.manifest,
                                            temporaryDirectory: temporaryDirectory)
        inspection.warnings.insert(contentsOf: plain.warnings, at: 0)
        guard !inspection.rootConfigs.isEmpty else { throw RmskinError.nothingToInstall }
        return inspection
    }

    /// Describes a package root in the standard layout (Skins/, Layouts/, Plugins/, Fonts/, Addons/, @Vault/,
    /// legacy Themes/).
    static func describeLayout(_ root: URL, manifest: RmskinManifest,
                               temporaryDirectory: URL) throws -> RmskinInspection {
        var inspection = RmskinInspection(manifest: manifest, packageRoot: root, temporaryDirectory: temporaryDirectory)
        convertThemesToLayouts(in: root, warnings: &inspection.warnings)

        if let skins = RmskinFiles.child(named: "Skins", in: root, directory: true) {
            inspection.skinsFolder = skins
            for item in RmskinFiles.visibleChildren(of: skins) {
                let name = item.lastPathComponent
                if !RmskinFiles.isDirectory(item) {
                    inspection.warnings.append("Ignored file \(name) outside a skin folder")
                } else if name.caseInsensitiveCompare("@Vault") == .orderedSame {
                    inspection.vaultFolders.append(item)
                } else {
                    inspection.rootConfigs.append(name)
                }
            }
        }
        // A top-level @Vault (next to Skins) is treated like Skins\@Vault: the manual places @Vault in the Skins folder.
        if let vault = RmskinFiles.child(named: "@Vault", in: root, directory: true) {
            inspection.vaultFolders.append(vault)
        }

        if let layouts = RmskinFiles.child(named: "Layouts", in: root, directory: true) {
            inspection.layoutsFolder = layouts
            for item in RmskinFiles.visibleChildren(of: layouts) {
                if RmskinFiles.isDirectory(item) {
                    inspection.layouts.append(item.lastPathComponent)
                } else {
                    inspection.warnings.append("Ignored file \(item.lastPathComponent) outside a layout folder")
                }
            }
        }
        inspection.containsLayouts = !inspection.layouts.isEmpty

        if let plugins = RmskinFiles.child(named: "Plugins", in: root, directory: true) {
            let files = RmskinFiles.allFiles(in: plugins)
            inspection.containsPlugins = !files.isEmpty
            var seen: Set<String> = []
            for file in files where file.pathExtension.lowercased() == "dll" {
                let name = file.lastPathComponent
                if seen.insert(name.lowercased()).inserted { inspection.pluginNames.append(name) }
            }
            inspection.pluginNames.sort { $0.caseInsensitiveCompare($1) == .orderedAscending }
            if inspection.containsPlugins {
                let list = inspection.pluginNames.isEmpty ? "" : ": " + inspection.pluginNames.joined(separator: ", ")
                inspection.warnings.append("The package includes Windows plugins that cannot run on macOS\(list). "
                    + "Skins that use them will show missing values.")
            }
        }

        // Legacy (pre-2.4) components: Fonts\ (installed system-wide on Windows) and Addons\ (Windows programs).
        describeFonts(root, inspection: &inspection)
        if let addons = RmskinFiles.child(named: "Addons", in: root, directory: true),
           !RmskinFiles.allFiles(in: addons).isEmpty {
            inspection.containsAddons = true
            inspection.warnings.append("The package includes Windows add-on programs; they are not installed.")
        }

        // "The image must be a bitmap image (.bmp) that is exactly 400x60 pixels in size." Only a real BMP of sane
        // dimensions is offered for display (a crafted header could claim a huge canvas); the exact size is not
        // required since older packages predate the packager's check.
        if let header = RmskinFiles.child(named: "RMSKIN.bmp", in: root, directory: false) {
            if RmskinFiles.bitmapSize(of: header) != nil {
                inspection.headerImageURL = header
            } else {
                inspection.warnings.append("Ignored the header image RMSKIN.bmp: not a valid bitmap.")
            }
        }

        if inspection.manifest.mergeSkins, !inspection.manifest.variableFiles.isEmpty {
            inspection.warnings.append("The package sets both MergeSkins and VariableFiles, which the Skin Packager "
                + "treats as incompatible; both are applied.")
        }
        if inspection.manifest.packageFormat != .rmskin { completeSkinLoad(&inspection) }
        return inspection
    }
}

// MARK: - Inspection

/// What a .rmskin contains, extracted to a temporary folder — for the confirmation dialog shown before installing.
public struct RmskinInspection {
    public var manifest: RmskinManifest
    /// Root config folder names under `Skins/` (hidden folders and `@Vault` excluded), sorted case-insensitively.
    public var rootConfigs: [String] = []
    /// Layout folder names under `Layouts/`.
    public var layouts: [String] = []
    /// The package has at least one layout under `Layouts/`.
    public var containsLayouts: Bool = false
    /// The package has files under `Plugins/` (Windows DLLs; never installed).
    public var containsPlugins: Bool = false
    /// Distinct `.dll` file names under `Plugins/`, sorted.
    public var pluginNames: [String] = []
    /// Package-level fonts: the legacy (pre-Rainmeter 2.4 / Rainstaller) `Fonts/` folder, and loose font files at the
    /// top of the package (TrueType/OpenType only). On install they are copied into each installed root config's
    /// `@Resources/Fonts`, where skins load fonts from.
    public var legacyFonts: [URL] = []
    /// Fonts in a root config's own `Fonts/` folder (`<RootConfig>/Fonts`, not `@Resources/Fonts`) or loose at its
    /// top, by root config name. On install they are copied into that root config's `@Resources/Fonts`.
    public var rootConfigFonts: [String: [URL]] = [:]
    /// Legacy `Addons/` folder with Windows programs (never installed).
    public var containsAddons: Bool = false
    /// `RMSKIN.bmp`, the optional 400x60 header image, when present and a readable Windows bitmap no larger than
    /// 4096 pixels either way (anything else is ignored with a warning).
    public var headerImageURL: URL?
    /// The extracted package (the folder holding RMSKIN.ini).
    public var packageRoot: URL
    /// The temporary folder removed by `cleanup()`.
    public var temporaryDirectory: URL
    /// The folder `RmskinPackage.inspect(folder:)` copied (nil for archives, and for a folder whose only package file
    /// was inspected instead).
    public var sourceFolder: URL?
    /// Notes worth showing to the user (unsupported plugins, ignored files…).
    public var warnings: [String] = []

    var skinsFolder: URL?
    var layoutsFolder: URL?
    var vaultFolders: [URL] = []

    init(manifest: RmskinManifest, packageRoot: URL, temporaryDirectory: URL) {
        self.manifest = manifest
        self.packageRoot = packageRoot
        self.temporaryDirectory = temporaryDirectory
    }

    /// File names of every font the installation adds to `@Resources/Fonts` folders, sorted, without duplicates.
    public var fontNames: [String] {
        let all = legacyFonts + rootConfigFonts.values.flatMap { $0 }
        var seen: Set<String> = []
        return all.map(\.lastPathComponent).filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The root configs of this package that already exist in `skinsDirectory` (they would be replaced — and backed
    /// up when a backup folder is given — or, with MergeSkins, added to).
    public func existingRootConfigs(in skinsDirectory: URL) -> [String] {
        rootConfigs.filter { RmskinFiles.child(named: $0, in: skinsDirectory) != nil }
    }

    /// Removes the temporary folder. Safe to call more than once.
    public func cleanup() {
        RmskinFiles.forceRemove(temporaryDirectory)
    }
}

// MARK: - Install result

public struct RmskinInstallResult: Equatable {
    public var manifest: RmskinManifest
    /// Root config folder names copied into the Skins directory.
    public var installedRootConfigs: [String] = []
    /// Skin to activate after install: config path with `\` separators (`Clock\Digital`) and the .ini file name.
    public var skinToLoad: (config: String, file: String)? {
        get { skinToLoadConfig.map { ($0, skinToLoadFile ?? "") } }
        set { skinToLoadConfig = newValue?.config; skinToLoadFile = newValue?.file }
    }
    public var skinToLoadConfig: String?
    public var skinToLoadFile: String?
    /// Layout name when `LoadType=Layout`.
    public var layoutToLoad: String?
    /// The package ships Windows plugins (DLLs) that cannot run on macOS.
    public var containsPlugins: Bool = false
    public var warnings: [String] = []
    /// Layout folder names copied into the layouts directory.
    public var installedLayouts: [String] = []
    /// Where existing skins / layouts were backed up (one folder per replaced root config or layout).
    public var backupLocations: [URL] = []
    /// Distinct `.dll` names found under `Plugins/` (not installed).
    public var pluginNames: [String] = []
    /// Number of user values kept from existing `VariableFiles`.
    public var preservedVariableCount: Int = 0
    /// Font file names newly copied into `@Resources/Fonts` folders (from the package's `Fonts/` folder or a root
    /// config's own `Fonts/` folder), sorted, without duplicates.
    public var installedFonts: [String] = []

    public init(manifest: RmskinManifest) {
        self.manifest = manifest
    }

    public static func == (a: RmskinInstallResult, b: RmskinInstallResult) -> Bool {
        a.manifest == b.manifest && a.installedRootConfigs == b.installedRootConfigs
            && a.skinToLoadConfig == b.skinToLoadConfig && a.skinToLoadFile == b.skinToLoadFile
            && a.layoutToLoad == b.layoutToLoad && a.containsPlugins == b.containsPlugins && a.warnings == b.warnings
            && a.installedLayouts == b.installedLayouts && a.backupLocations == b.backupLocations
            && a.pluginNames == b.pluginNames && a.preservedVariableCount == b.preservedVariableCount
            && a.installedFonts == b.installedFonts
    }
}

// MARK: - Installer

public enum RmskinInstaller {
    /// Installs a .rmskin, a legacy Rainstaller package, a plain ZIP or a folder (see `RmskinPackage.inspect`):
    /// extract to a temp dir, copy `Skins/*` into `skinsDirectory` (backing up existing
    /// root configs into `backupDirectory` when given, preserving `VariableFiles` values as the manual describes),
    /// copy `Layouts/*` into `layoutsDirectory` when given, ignore `Plugins/` (flag it), clean up the temp dir.
    public static func install(packageURL: URL, skinsDirectory: URL, layoutsDirectory: URL? = nil,
                               backupDirectory: URL? = nil) throws -> RmskinInstallResult {
        let inspection = try RmskinPackage.inspect(packageURL)
        defer { inspection.cleanup() }
        return try install(inspection: inspection, skinsDirectory: skinsDirectory,
                           layoutsDirectory: layoutsDirectory, backupDirectory: backupDirectory)
    }

    /// Installs an already inspected package (see `RmskinPackage.inspect`). Does not clean the inspection up.
    ///
    /// What happens, following the manual:
    /// - Each root config under `Skins/` goes to `skinsDirectory`. "Normally, the root config folder is removed and
    ///   replaced with the version in the skin package"; with `MergeSkins=1` "the Skin Installer will not remove any
    ///   existing files" — package files are added over the existing folder.
    /// - "If any of the skins to be installed already exist, they will be moved to a Backup folder before
    ///   installation": with `backupDirectory` the existing root config is moved to `backupDirectory/<RootConfig>`
    ///   (or `<RootConfig> (2)`, `(3)`… so older backups are never overwritten). With MergeSkins nothing is removed,
    ///   so the backup is a copy. Without `backupDirectory` ("Backup skins" unchecked) the old folder is deleted.
    ///   Replacement is staged: the new folder is fully prepared first and swapped in, and the old one is put back
    ///   if the swap fails.
    /// - `VariableFiles`: "the existing variable values are used instead of the defaults in the package" — for each
    ///   listed file present both in the existing install and in the package, values of keys found in both (same
    ///   section) are taken from the existing file; the package file keeps its layout, comments, new keys and
    ///   encoding.
    /// - `Layouts/<name>` goes to `layoutsDirectory/<name>` (existing layouts of the same name are backed up to
    ///   `backupDirectory/@Layouts/`), with every option of its `[Rainmeter]` section removed (the installer does not
    ///   let authors overwrite the user's global settings).
    /// - `Plugins/` (Windows DLLs) and legacy `Addons/` are never installed; `containsPlugins` / warnings report them.
    ///   Package-level fonts (legacy `Fonts/`, loose font files) are copied into each installed root config's
    ///   `@Resources/Fonts`, and a root config's own `Fonts/` folder into its `@Resources/Fonts` — never replacing a
    ///   font already there (`installedFonts` lists what was added).
    /// - Legacy `KeepVar=1` (`manifest.keepsAllVariables`) treats every .ini / .inc file of the package's root configs
    ///   as a variables file.
    /// - An inspection of a folder that is, contains or lies inside `skinsDirectory` throws `.alreadyInSkinsFolder`.
    /// - A package `@Vault` (in `Skins/` or at the top level) is merged into `skinsDirectory/@Vault` without
    ///   overwriting existing files.
    /// - `LoadType`/`Load` become `skinToLoad` / `layoutToLoad` when the target exists after installation.
    public static func install(inspection: RmskinInspection, skinsDirectory: URL, layoutsDirectory: URL? = nil,
                               backupDirectory: URL? = nil) throws -> RmskinInstallResult {
        let fm = FileManager.default
        let manifest = inspection.manifest
        if let source = inspection.sourceFolder, RmskinPackage.folder(source, overlaps: skinsDirectory) {
            throw RmskinError.alreadyInSkinsFolder
        }
        var result = RmskinInstallResult(manifest: manifest)
        result.warnings = inspection.warnings
        result.containsPlugins = inspection.containsPlugins
        result.pluginNames = inspection.pluginNames

        // "At least one skin will always be included"; a package with only layouts is still accepted when the
        // layouts can be installed.
        let willInstallLayouts = layoutsDirectory != nil && !inspection.layouts.isEmpty
        let skinsSource = inspection.skinsFolder
        guard (skinsSource != nil && !inspection.rootConfigs.isEmpty) || willInstallLayouts else {
            throw RmskinError.nothingToInstall
        }

        try fm.createDirectory(at: skinsDirectory, withIntermediateDirectories: true)
        var variableFiles = variableFileTargets(manifest.variableFiles, rootConfigs: inspection.rootConfigs,
                                                warnings: &result.warnings)
        if manifest.keepsAllVariables, let skinsSource {
            var listed = Set(variableFiles.map { ([$0.root] + $0.path).joined(separator: "/").lowercased() })
            for target in allVariableFileTargets(inspection.rootConfigs, skinsSource: skinsSource)
            where listed.insert(([target.root] + target.path).joined(separator: "/").lowercased()).inserted {
                variableFiles.append(target)
            }
        }

        for rootConfig in inspection.rootConfigs {
            guard let skinsSource else { break }
            try installRootConfig(rootConfig, from: skinsSource.appendingPathComponent(rootConfig),
                                  skinsDirectory: skinsDirectory, backupDirectory: backupDirectory,
                                  merge: manifest.mergeSkins,
                                  variableFiles: variableFiles.filter { $0.root == rootConfig }.map(\.path),
                                  result: &result)
            result.installedRootConfigs.append(rootConfig)
        }

        installLegacyFonts(inspection.legacyFonts, skinsDirectory: skinsDirectory, result: &result)
        for rootConfig in result.installedRootConfigs {
            guard let fonts = inspection.rootConfigFonts[rootConfig] else { continue }
            installFonts(fonts, into: skinsDirectory.appendingPathComponent(rootConfig), result: &result)
        }
        var seenFonts: Set<String> = []
        result.installedFonts = result.installedFonts.filter { seenFonts.insert($0.lowercased()).inserted }
            .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }

        for vault in inspection.vaultFolders {
            do {
                try RmskinFiles.copyTree(from: vault, to: skinsDirectory.appendingPathComponent("@Vault"),
                                         overwrite: false)
            } catch {
                result.warnings.append("Could not copy @Vault: \(error.localizedDescription)")
            }
        }

        if let layoutsDirectory, let layoutsFolder = inspection.layoutsFolder {
            for layout in inspection.layouts {
                try installLayout(layout, from: layoutsFolder.appendingPathComponent(layout),
                                  layoutsDirectory: layoutsDirectory, backupDirectory: backupDirectory,
                                  result: &result)
                result.installedLayouts.append(layout)
            }
        } else if !inspection.layouts.isEmpty {
            result.warnings.append("The package includes layouts (\(inspection.layouts.joined(separator: ", "))) "
                + "that were not installed.")
        }

        resolveLoad(manifest, skinsDirectory: skinsDirectory, layoutsDirectory: layoutsDirectory, result: &result)
        return result
    }

    // MARK: Root configs

    /// `VariableFiles` entries "starting with the root config folder, e.g. illustro\Clock\Variables.inc", mapped to
    /// the package's root config names (case-insensitively) and a path relative to that root config.
    static func variableFileTargets(_ entries: [String], rootConfigs: [String],
                                    warnings: inout [String]) -> [(root: String, path: [String])] {
        var targets: [(root: String, path: [String])] = []
        for entry in entries {
            guard var parts = RmskinFiles.pathComponents(entry), !parts.isEmpty else {
                warnings.append("Ignored invalid VariableFiles entry \"\(entry)\"")
                continue
            }
            // Tolerate a leading "Skins\" (a common mistake) unless a root config is really called "Skins".
            if parts.count > 2, parts[0].caseInsensitiveCompare("Skins") == .orderedSame,
               !rootConfigs.contains(where: { $0.caseInsensitiveCompare("Skins") == .orderedSame }) {
                parts.removeFirst()
            }
            guard parts.count >= 2,
                  let root = rootConfigs.first(where: { $0 == parts[0] })
                    ?? rootConfigs.first(where: { $0.caseInsensitiveCompare(parts[0]) == .orderedSame }) else {
                warnings.append("VariableFiles entry \"\(entry)\" is not inside a skin of this package")
                continue
            }
            targets.append((root, Array(parts.dropFirst())))
        }
        return targets
    }

    private static func installRootConfig(_ rootConfig: String, from source: URL, skinsDirectory: URL,
                                          backupDirectory: URL?, merge: Bool, variableFiles: [[String]],
                                          result: inout RmskinInstallResult) throws {
        let fm = FileManager.default
        let destination = RmskinFiles.child(named: rootConfig, in: skinsDirectory)
            ?? skinsDirectory.appendingPathComponent(rootConfig)
        let exists = RmskinFiles.itemExists(destination)

        // The user's current variable files, read before anything moves.
        var oldVariableFiles: [([String], Data)] = []
        if exists {
            for path in variableFiles {
                if let resolved = RmskinFiles.resolveCaseInsensitively(path, from: destination),
                   let data = try? Data(contentsOf: RmskinFiles.appending(resolved, to: destination)) {
                    oldVariableFiles.append((path, data))
                }
            }
        }

        if merge {
            if exists, let backupDirectory {
                try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                let backup = RmskinFiles.uniqueURL(in: backupDirectory, baseName: rootConfig)
                try fm.copyItem(at: destination, to: backup) // a full copy, hidden files included
                result.backupLocations.append(backup)
            }
            if exists, !RmskinFiles.isDirectory(destination) { try fm.removeItem(at: destination) }
            try RmskinFiles.copyTree(from: source, to: destination, overwrite: true)
            restoreVariables(oldVariableFiles, in: destination, rootConfig: rootConfig, result: &result)
            return
        }

        // Stage the complete new folder (hidden, same volume) so the swap below is two renames.
        let staging = skinsDirectory.appendingPathComponent(".deskset-install-\(UUID().uuidString)")
        do {
            try RmskinFiles.copyTree(from: source, to: staging, overwrite: true)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        restoreVariables(oldVariableFiles, in: staging, rootConfig: rootConfig, result: &result)

        let finalDestination = skinsDirectory.appendingPathComponent(rootConfig)
        guard exists else {
            do {
                try fm.moveItem(at: staging, to: finalDestination)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            return
        }

        let aside: URL
        if let backupDirectory {
            do {
                try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            aside = RmskinFiles.uniqueURL(in: backupDirectory, baseName: rootConfig)
        } else {
            aside = skinsDirectory.appendingPathComponent(".deskset-old-\(UUID().uuidString)")
        }
        do {
            try fm.moveItem(at: destination, to: aside)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        do {
            try fm.moveItem(at: staging, to: finalDestination)
        } catch {
            try? fm.moveItem(at: aside, to: destination) // put the user's skin back
            try? fm.removeItem(at: staging)
            throw error
        }
        if backupDirectory != nil {
            result.backupLocations.append(aside)
        } else {
            try? fm.removeItem(at: aside)
        }
    }

    private static func restoreVariables(_ oldFiles: [([String], Data)], in folder: URL, rootConfig: String,
                                         result: inout RmskinInstallResult) {
        for (path, oldData) in oldFiles {
            let display = ([rootConfig] + path).joined(separator: "\\")
            guard let resolved = RmskinFiles.resolveCaseInsensitively(path, from: folder) else {
                continue // the new version no longer ships this file: nothing to preserve into
            }
            let url = RmskinFiles.appending(resolved, to: folder)
            do {
                try RmskinTextEncoding.rewriteFile(at: url) { newText in
                    let merged = RmskinIniText.preservingValues(from: TextDecoding.decode(oldData), into: newText)
                    result.preservedVariableCount += merged.preserved
                    return merged.preserved > 0 ? merged.text : nil
                }
            } catch {
                result.warnings.append("Could not keep your settings in \(display): \(error.localizedDescription)")
            }
        }
    }

    private static func installLegacyFonts(_ fonts: [URL], skinsDirectory: URL, result: inout RmskinInstallResult) {
        guard !fonts.isEmpty else { return }
        guard !result.installedRootConfigs.isEmpty else {
            result.warnings.append("The package includes fonts but no skin to hold them; they were not installed.")
            return
        }
        for rootConfig in result.installedRootConfigs {
            installFonts(fonts, into: skinsDirectory.appendingPathComponent(rootConfig), result: &result)
        }
    }

    /// Copies font files (flat: the engine loads only the top of `@Resources/Fonts`) into `rootFolder/@Resources/Fonts`
    /// without replacing a font already there — the skin's own copy, or the user's.
    private static func installFonts(_ fonts: [URL], into rootFolder: URL, result: inout RmskinInstallResult) {
        let resources = RmskinFiles.child(named: "@Resources", in: rootFolder, directory: true)
            ?? rootFolder.appendingPathComponent("@Resources")
        let folder = RmskinFiles.child(named: "Fonts", in: resources, directory: true)
            ?? resources.appendingPathComponent("Fonts")
        for font in fonts {
            let name = font.lastPathComponent
            guard RmskinFiles.child(named: name, in: folder) == nil else { continue }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: font, to: folder.appendingPathComponent(name))
                result.installedFonts.append(name)
            } catch {
                result.warnings.append("Could not copy font \(name): \(error.localizedDescription)")
            }
        }
    }

    /// Legacy `KeepVar=1`: every .ini / .inc file of the package's root configs (at most 2 000), as variable-file
    /// targets.
    static func allVariableFileTargets(_ rootConfigs: [String], skinsSource: URL) -> [(root: String, path: [String])] {
        var targets: [(root: String, path: [String])] = []
        for rootConfig in rootConfigs {
            let folder = skinsSource.appendingPathComponent(rootConfig)
            for file in RmskinFiles.allFiles(in: folder) where ["ini", "inc"].contains(file.pathExtension.lowercased()) {
                guard targets.count < 2_000 else { return targets }
                if let path = RmskinFiles.relativeComponents(of: file, in: folder) { targets.append((rootConfig, path)) }
            }
        }
        return targets
    }

    // MARK: Layouts

    private static func installLayout(_ layout: String, from source: URL, layoutsDirectory: URL,
                                      backupDirectory: URL?, result: inout RmskinInstallResult) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layoutsDirectory, withIntermediateDirectories: true)
        let staging = layoutsDirectory.appendingPathComponent(".deskset-install-\(UUID().uuidString)")
        do {
            try RmskinFiles.copyTree(from: source, to: staging, overwrite: true)
            // Remove the author's global [Rainmeter] options so installing never overrides the user's settings.
            for file in RmskinFiles.children(of: staging)
            where file.pathExtension.lowercased() == "ini" && RmskinFiles.isRegularFile(file) {
                try RmskinTextEncoding.rewriteFile(at: file) { text in
                    let stripped = RmskinIniText.removingOptions(ofSection: "Rainmeter", from: text)
                    return stripped.removed > 0 ? stripped.text : nil
                }
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        let destination = layoutsDirectory.appendingPathComponent(layout)
        if let existing = RmskinFiles.child(named: layout, in: layoutsDirectory) {
            let aside: URL
            if let backupDirectory {
                let folder = backupDirectory.appendingPathComponent("@Layouts")
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                } catch {
                    try? fm.removeItem(at: staging)
                    throw error
                }
                aside = RmskinFiles.uniqueURL(in: folder, baseName: layout)
            } else {
                aside = layoutsDirectory.appendingPathComponent(".deskset-old-\(UUID().uuidString)")
            }
            do {
                try fm.moveItem(at: existing, to: aside)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            do {
                try fm.moveItem(at: staging, to: destination)
            } catch {
                try? fm.moveItem(at: aside, to: existing)
                try? fm.removeItem(at: staging)
                throw error
            }
            if backupDirectory != nil { result.backupLocations.append(aside) } else { try? fm.removeItem(at: aside) }
        } else {
            do {
                try fm.moveItem(at: staging, to: destination)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
    }

    // MARK: Load / LoadType

    /// `LoadType=Skin` + `Load=Config\Sub\File.ini` → `skinToLoad` (`Config\Sub`, `File.ini`);
    /// `LoadType=Layout` + `Load=Name` → `layoutToLoad`. Without LoadType, a `Load` ending in `.ini` is a skin and
    /// anything else a layout. The target must exist after installation (spelled as on disk) and belong to this
    /// package — a root config in `result.installedRootConfigs` or a layout in `result.installedLayouts`: the
    /// packager lets authors pick "one of the skin .ini files in your package" / "one layout" they added, and the
    /// installer never loads "a non-installed skin/layout" (version history, SkinInstaller). Otherwise a warning is
    /// added and nothing is loaded.
    static func resolveLoad(_ manifest: RmskinManifest, skinsDirectory: URL, layoutsDirectory: URL?,
                            result: inout RmskinInstallResult) {
        let load = manifest.load.trimmingCharacters(in: .whitespaces)
        guard !load.isEmpty else { return }
        guard let parts = RmskinFiles.pathComponents(load), let last = parts.last else {
            result.warnings.append("Invalid Load value \"\(load)\"; nothing is loaded.")
            return
        }
        let type = manifest.loadType.trimmingCharacters(in: .whitespaces).lowercased()
        let isSkin: Bool
        switch type {
        case "skin": isSkin = true
        case "layout": isSkin = false
        case "": isSkin = last.lowercased().hasSuffix(".ini")
        default:
            result.warnings.append("Unknown LoadType \"\(manifest.loadType)\"; nothing is loaded.")
            return
        }

        if isSkin {
            guard parts.count >= 2 else {
                result.warnings.append("Load=\(load) does not name a skin folder and file; nothing is loaded.")
                return
            }
            guard result.installedRootConfigs.contains(where: { $0.caseInsensitiveCompare(parts[0]) == .orderedSame }),
                  let resolved = RmskinFiles.resolveCaseInsensitively(parts, from: skinsDirectory),
                  RmskinFiles.isRegularFile(RmskinFiles.appending(resolved, to: skinsDirectory)) else {
                result.warnings.append("The skin to load (\(load)) is not in the package; nothing is loaded.")
                return
            }
            result.skinToLoadConfig = resolved.dropLast().joined(separator: "\\")
            result.skinToLoadFile = resolved.last
        } else {
            guard parts.count == 1 else {
                result.warnings.append("Invalid layout name \"\(load)\"; nothing is loaded.")
                return
            }
            guard let layoutsDirectory,
                  result.installedLayouts.contains(where: { $0.caseInsensitiveCompare(parts[0]) == .orderedSame }),
                  let layout = RmskinFiles.child(named: parts[0], in: layoutsDirectory, directory: true) else {
                result.warnings.append("The layout to load (\(load)) was not installed; nothing is loaded.")
                return
            }
            result.layoutToLoad = layout.lastPathComponent
        }
    }
}
