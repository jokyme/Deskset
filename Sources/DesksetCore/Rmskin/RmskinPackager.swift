import Foundation

// Skin Packager (manual: /manual/distributing-skins/): makes a .rmskin from one root config folder, any number of
// layouts and Windows plugin pairs, with the options of its Information, Options and Advanced steps.
//
// Package layout, as the installer reads it (`RmskinPackage.describe`): `RMSKIN.ini` (`[rmskin]`), optional
// `RMSKIN.bmp`, `Skins/<root config>/…`, `Layouts/<name>/…`, `Plugins/32bit/<dll>` and `Plugins/64bit/<dll>`; the ZIP
// is followed by the 16-byte footer (8-byte little-endian ZIP length + `\0RMSKIN\0`).
//
// Choices made for packages that Windows installs the same way:
// - RMSKIN.ini is UTF-16 LE with a BOM and CRLF line ends (Windows' INI reader takes UTF-16; it reads UTF-8 as ANSI);
// - file names are stored in Unicode normal form C (macOS file systems may hand out decomposed names), with the ZIP
//   UTF-8 flag set (ditto leaves it off, so Windows would read non-ASCII names in a legacy code page);
// - the ZIP has no resource forks, extended attributes, ACLs or quarantine flags (`ditto --norsrc --noextattr
//   --noacl --noqtn`), so no `__MACOSX` folder;
// - "The Skin Packager will ignore any hidden files or folders": names starting with `.`, Windows Explorer's own files
//   (`RmskinFiles.isIgnoredName`) and items marked hidden in Finder are left out; symbolic links are left out too
//   (they would pull in files from elsewhere, and Windows cannot recreate them) and reported.

/// Everything the Skin Packager asks for.
public struct RmskinPackageSpec: Equatable, Codable {
    /// "After installation": nothing, load one skin of the package (`Root\Sub\File.ini`), or load one of its layouts.
    public enum Load: Equatable, Codable {
        case none
        case skin(String)
        case layout(String)
    }

    /// A Windows plugin: "you must provide both the 32-bit and 64-bit versions".
    public struct Plugin: Equatable, Codable {
        public var x86: URL?
        public var x64: URL?

        public init(x86: URL? = nil, x64: URL? = nil) {
            self.x86 = x86
            self.x64 = x64
        }

        /// The DLL's file name (both versions must share it).
        public var fileName: String { (x64 ?? x86)?.lastPathComponent ?? "" }
    }

    public var name = ""
    public var author = ""
    public var version = ""
    /// The root config folder ("Only one root config folder is allowed in a single package").
    public var rootConfig: URL?
    /// Layout folders (each holds a `Rainmeter.ini`).
    public var layouts: [URL] = []
    public var plugins: [Plugin] = []
    public var load: Load = .none
    /// Written as `MinimumRainmeter`; "Rainmeter version numbers are written in the form Major.Minor.Patch.Revision".
    public var minimumRainmeter = RmskinPackager.defaultMinimumRainmeter
    /// A 400×60 `.bmp` shown by the installer.
    public var headerImage: URL?
    /// Paths starting with the root config folder (`illustro\Clock\Variables.inc`).
    public var variableFiles: [String] = []
    public var mergeSkins = false
    /// "Save package to" (the Desktop by default).
    public var outputDirectory: URL?

    public init() {}
}

/// Why a package cannot be made yet.
public enum RmskinPackagerProblem: Equatable {
    case nameMissing
    case authorMissing
    case skinMissing
    /// The root config folder is missing, unreadable, or holds no `.ini` skin.
    case skinWithoutSkins(String)
    /// A layout folder without `Rainmeter.ini`.
    case layoutWithoutSettings(String)
    /// A plugin without both its 32-bit and 64-bit DLLs, or whose two files differ in name.
    case pluginIncomplete(String)
    case loadSkinNotFound(String)
    case loadLayoutNotIncluded(String)
    case headerNotBitmap
    case headerWrongSize(width: Int, height: Int)
    case variableFileNotFound(String)
    /// "This option is not compatible with the Merge skins option."
    case mergeWithVariableFiles
    case minimumVersionInvalid(String)
    case outputMissing
}

public enum RmskinPackagerError: Error, Equatable, CustomStringConvertible {
    case invalid([RmskinPackagerProblem])
    case writeFailed(String)

    public var description: String {
        switch self {
        case .invalid(let problems): return "the package is not ready (\(problems.count) problems)"
        case .writeFailed(let reason): return "the package could not be written: \(reason)"
        }
    }
}

public enum RmskinPackager {
    /// The Rainmeter release whose skin features Deskset implements (`RmskinManifest.compatibleRainmeterVersion`).
    public static let defaultMinimumRainmeter = "5.0"
    public static let headerSize = (width: 400, height: 60)

    /// What `build` did besides writing the package.
    public struct Result: Equatable {
        public var url: URL
        /// Symbolic links left out, as paths inside the package.
        public var skippedLinks: [String]
    }

    // MARK: Choosing

    /// The `.ini` skins of a root config folder, as `Load` values (`Root\Sub\File.ini`), sorted; `@Resources` and
    /// hidden items are skipped.
    public static func skinFiles(inRootConfig root: URL) -> [String] {
        let rootName = root.lastPathComponent.precomposedStringWithCanonicalMapping
        var result: [String] = []
        func walk(_ folder: URL, _ path: [String], depth: Int) {
            guard depth < RmskinFiles.maxCopyDepth else { return }
            for child in visibleItems(of: folder) {
                let name = child.lastPathComponent.precomposedStringWithCanonicalMapping
                if isLink(child) { continue }
                if RmskinFiles.isDirectory(child) {
                    if depth == 0 && name.caseInsensitiveCompare("@Resources") == .orderedSame { continue }
                    walk(child, path + [name], depth: depth + 1)
                } else if (name as NSString).pathExtension.lowercased() == "ini" {
                    result.append((path + [name]).joined(separator: "\\"))
                }
            }
        }
        walk(root, [rootName], depth: 0)
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// "When you choose one of the plugin DLLs, the Skin Packager automatically looks for the other version by
    /// swapping the architecture in the source folder name, such as 32bit and 64bit." Which version a DLL is comes
    /// from its PE header; the other is looked up by swapping `32bit`/`64bit` or `x86`/`x64` in its folder names.
    public static func plugin(choosing dll: URL) -> RmskinPackageSpec.Plugin {
        var plugin = RmskinPackageSpec.Plugin()
        let is64 = windowsArchitecture(of: dll).map { $0 == .x64 }
            ?? dll.pathComponents.contains { ["64bit", "x64"].contains($0.lowercased()) }
        if is64 { plugin.x64 = dll } else { plugin.x86 = dll }
        let swaps: [String: String] = ["32bit": "64bit", "64bit": "32bit", "x86": "x64", "x64": "x86"]
        let folders = dll.deletingLastPathComponent().pathComponents
        for (i, component) in folders.enumerated().reversed() {
            guard let other = swaps[component.lowercased()] else { continue }
            var swapped = folders
            swapped[i] = component == component.uppercased() ? other.uppercased() : other
            let parent = URL(fileURLWithPath: NSString.path(withComponents: swapped), isDirectory: true)
            guard let counterpart = RmskinFiles.child(named: dll.lastPathComponent, in: parent, directory: false)
            else { continue }
            if is64 { plugin.x86 = counterpart } else { plugin.x64 = counterpart }
            break
        }
        return plugin
    }

    public enum WindowsArchitecture: Equatable { case x86, x64, other }

    /// The machine type in a Windows executable's PE header; nil when the file is not one.
    public static func windowsArchitecture(of url: URL) -> WindowsArchitecture? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let dos = try? handle.read(upToCount: 64), dos.count == 64, dos[0] == 0x4D, dos[1] == 0x5A else { return nil }
        let b = [UInt8](dos)
        let offset = UInt64(b[60]) | UInt64(b[61]) << 8 | UInt64(b[62]) << 16 | UInt64(b[63]) << 24
        guard offset < 1 << 20, (try? handle.seek(toOffset: offset)) != nil,
              let pe = try? handle.read(upToCount: 6), pe.count == 6 else { return nil }
        let p = [UInt8](pe)
        guard p[0] == 0x50, p[1] == 0x45, p[2] == 0, p[3] == 0 else { return nil }
        switch UInt16(p[4]) | UInt16(p[5]) << 8 {
        case 0x014C: return .x86
        case 0x8664: return .x64
        default: return .other
        }
    }

    // MARK: Checking

    public static func problems(_ spec: RmskinPackageSpec) -> [RmskinPackagerProblem] {
        var problems: [RmskinPackagerProblem] = []
        if clean(spec.name).isEmpty { problems.append(.nameMissing) }
        if clean(spec.author).isEmpty { problems.append(.authorMissing) }
        var skins: [String] = []
        if let root = spec.rootConfig {
            skins = RmskinFiles.isDirectory(root) ? skinFiles(inRootConfig: root) : []
            if skins.isEmpty { problems.append(.skinWithoutSkins(root.lastPathComponent)) }
        } else {
            problems.append(.skinMissing)
        }
        for layout in spec.layouts where RmskinFiles.child(named: "Rainmeter.ini", in: layout, directory: false) == nil {
            problems.append(.layoutWithoutSettings(layout.lastPathComponent))
        }
        for plugin in spec.plugins {
            guard let x86 = plugin.x86, let x64 = plugin.x64, RmskinFiles.isRegularFile(x86), RmskinFiles.isRegularFile(x64),
                  x86.lastPathComponent.caseInsensitiveCompare(x64.lastPathComponent) == .orderedSame else {
                problems.append(.pluginIncomplete(plugin.fileName))
                continue
            }
        }
        switch spec.load {
        case .none: break
        case .skin(let path):
            if !skins.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) {
                problems.append(.loadSkinNotFound(path))
            }
        case .layout(let name):
            if !spec.layouts.contains(where: { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }) {
                problems.append(.loadLayoutNotIncluded(name))
            }
        }
        if let header = spec.headerImage {
            if let size = RmskinFiles.bitmapSize(of: header) {
                if size != headerSize { problems.append(.headerWrongSize(width: size.width, height: size.height)) }
            } else {
                problems.append(.headerNotBitmap)
            }
        }
        if let root = spec.rootConfig {
            for path in spec.variableFiles where variableFile(path, in: root) == nil {
                problems.append(.variableFileNotFound(path))
            }
        }
        if spec.mergeSkins && !spec.variableFiles.isEmpty { problems.append(.mergeWithVariableFiles) }
        let minimum = spec.minimumRainmeter.trimmingCharacters(in: .whitespaces)
        if minimum.range(of: #"^[0-9]{1,4}(\.[0-9]{1,6}){0,3}$"#, options: .regularExpression) == nil {
            problems.append(.minimumVersionInvalid(minimum))
        }
        if spec.outputDirectory == nil || !RmskinFiles.isDirectory(spec.outputDirectory!) {
            problems.append(.outputMissing)
        }
        return problems
    }

    /// The file a `VariableFiles` entry names inside `root` ("Specify the file location starting with the root config
    /// folder"), ignoring case; nil when it does not exist or names another root config.
    static func variableFile(_ path: String, in root: URL) -> URL? {
        guard let components = RmskinFiles.pathComponents(path), components.count >= 2,
              components[0].precomposedStringWithCanonicalMapping.caseInsensitiveCompare(
                root.lastPathComponent.precomposedStringWithCanonicalMapping) == .orderedSame,
              let resolved = RmskinFiles.resolveCaseInsensitively(Array(components.dropFirst()), from: root) else {
            return nil
        }
        let url = RmskinFiles.appending(resolved, to: root)
        return RmskinFiles.isRegularFile(url) ? url : nil
    }

    // MARK: Writing

    /// "The file will be saved in your chosen location as Name_Version.rmskin"; characters Windows or macOS do not allow
    /// in file names become `-`.
    public static func fileName(for spec: RmskinPackageSpec) -> String {
        let name = clean(spec.name), version = clean(spec.version)
        let base = version.isEmpty ? name : "\(name)_\(version)"
        let unsafe = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        let safe = String(base.unicodeScalars.map { unsafe.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return (safe.isEmpty ? "Package" : safe).precomposedStringWithCanonicalMapping + ".rmskin"
    }

    /// The `[rmskin]` section, with CRLF line ends (written as UTF-16 LE by `build`).
    public static func manifestText(_ spec: RmskinPackageSpec) -> String {
        var lines = ["[rmskin]", "Name=\(clean(spec.name))", "Author=\(clean(spec.author))",
                     "Version=\(clean(spec.version))"]
        switch spec.load {
        case .none: break
        case .skin(let path): lines += ["LoadType=Skin", "Load=\(clean(path))"]
        case .layout(let name): lines += ["LoadType=Layout", "Load=\(clean(name))"]
        }
        if !spec.variableFiles.isEmpty {
            lines.append("VariableFiles=" + spec.variableFiles.map(clean).joined(separator: " | "))
        }
        if spec.mergeSkins { lines.append("MergeSkins=1") }
        lines.append("MinimumRainmeter=\(clean(spec.minimumRainmeter))")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Writes the package as `outputDirectory/fileName(for:)`, replacing a file of that name. Throws `.invalid` when
    /// `problems` finds any.
    @discardableResult
    public static func build(_ spec: RmskinPackageSpec) throws -> Result {
        let problems = problems(spec)
        guard problems.isEmpty, let root = spec.rootConfig, let output = spec.outputDirectory else {
            throw RmskinPackagerError.invalid(problems)
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Deskset-package-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let staging = work.appendingPathComponent("Package", isDirectory: true)
        var skipped: [String] = []
        do {
            // Paths are joined as strings and created with POSIX calls: Foundation's file APIs decompose names.
            let base = staging.path
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try makeDirectory(base)
            let rootName = root.lastPathComponent.precomposedStringWithCanonicalMapping
            try makeDirectory(base + "/Skins")
            try stage(root, to: base + "/Skins/" + rootName, path: "Skins/\(rootName)", skipped: &skipped)
            if !spec.layouts.isEmpty { try makeDirectory(base + "/Layouts") }
            for layout in spec.layouts {
                let name = layout.lastPathComponent.precomposedStringWithCanonicalMapping
                try stage(layout, to: base + "/Layouts/" + name, path: "Layouts/\(name)", skipped: &skipped)
            }
            if !spec.plugins.isEmpty { try makeDirectory(base + "/Plugins") }
            for plugin in spec.plugins {
                for (folder, file) in [("32bit", plugin.x86), ("64bit", plugin.x64)] {
                    guard let file else { continue }
                    try makeDirectory(base + "/Plugins/" + folder)
                    try copyFile(file.path, to: base + "/Plugins/" + folder + "/"
                                 + file.lastPathComponent.precomposedStringWithCanonicalMapping)
                }
            }
            if let header = spec.headerImage { try copyFile(header.path, to: base + "/RMSKIN.bmp") }
            var manifest = Data([0xFF, 0xFE])
            manifest.append(manifestText(spec).data(using: .utf16LittleEndian) ?? Data())
            try manifest.write(to: staging.appendingPathComponent("RMSKIN.ini"))
        } catch let error as RmskinPackagerError {
            throw error
        } catch {
            throw RmskinPackagerError.writeFailed(error.localizedDescription)
        }

        let zip = work.appendingPathComponent("Package.zip")
        let (status, message) = try RmskinZip.runDitto(["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--noqtn",
                                                        staging.path, zip.path])
        guard status == 0, var data = try? Data(contentsOf: zip) else {
            throw RmskinPackagerError.writeFailed(message.isEmpty ? "ditto exited with status \(status)" : message)
        }
        do {
            try RmskinZip.markNamesUTF8(&data)
        } catch {
            throw RmskinPackagerError.writeFailed("\(error)")
        }
        var length = UInt64(data.count)
        for _ in 0..<8 {
            data.append(UInt8(length & 0xFF))
            length >>= 8
        }
        data.append(contentsOf: RmskinPackage.footerMagic)
        let destination = output.appendingPathComponent(fileName(for: spec))
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw RmskinPackagerError.writeFailed(error.localizedDescription)
        }
        return Result(url: destination, skippedLinks: skipped)
    }

    /// Copies a folder into the staging area without hidden items or symbolic links, naming every item in Unicode
    /// normal form C.
    private static func stage(_ source: URL, to destination: String, path: String, skipped: inout [String],
                              depth: Int = 0) throws {
        guard depth < RmskinFiles.maxCopyDepth else { return }
        try makeDirectory(destination)
        for child in visibleItems(of: source) {
            let name = child.lastPathComponent.precomposedStringWithCanonicalMapping
            if isLink(child) {
                skipped.append("\(path)/\(name)")
            } else if RmskinFiles.isDirectory(child) {
                try stage(child, to: destination + "/" + name, path: "\(path)/\(name)", skipped: &skipped,
                          depth: depth + 1)
            } else if RmskinFiles.isRegularFile(child) {
                try copyFile(child.path, to: destination + "/" + name)
            }
        }
    }

    /// `mkdir` with the path's own bytes (an existing folder is fine).
    private static func makeDirectory(_ path: String) throws {
        if mkdir(path, 0o755) != 0 && errno != EEXIST {
            throw RmskinPackagerError.writeFailed("\(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Copies a file's data and permissions; the destination keeps the exact bytes of its name.
    private static func copyFile(_ source: String, to destination: String) throws {
        if copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT)) != 0 {
            throw RmskinPackagerError.writeFailed("\(destination): \(String(cString: strerror(errno)))")
        }
    }

    /// Children of a folder that the Skin Packager keeps: not hidden by name (`RmskinFiles.isIgnoredName`) nor by
    /// Finder's hidden flag.
    private static func visibleItems(of folder: URL) -> [URL] {
        RmskinFiles.visibleChildren(of: folder).filter {
            (try? $0.resourceValues(forKeys: [.isHiddenKey]).isHidden) != true
        }
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// A field as one line: no line breaks (they would end the INI value), no surrounding spaces.
    private static func clean(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
