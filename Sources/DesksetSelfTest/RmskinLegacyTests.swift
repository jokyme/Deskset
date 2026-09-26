import Foundation
@testable import DesksetCore

// Package formats besides the Skin Packager's .rmskin: legacy Rainstaller packages (Rainstaller.cfg), plain ZIP
// archives without manifest (renamed .rmskin or .zip), already extracted folders, and fonts shipped by any of them.
// Every fixture is original and built here (folder tree → `ditto -c -k`, or a hand-made ZIP for hostile archives);
// TestSkins/Installer holds two original sample folders.

func runRmskinLegacyTests(_ t: TestRunner) {
    // A private folder for the installer's temporary folders: the user's temporary folder is shared with other
    // processes (the app's self-test, parallel runs), which would disturb the "nothing left behind" checks.
    let savedRoot = RmskinFiles.temporaryRoot
    let privateRoot = t.temporaryDirectory("legacy-tmp")
    RmskinFiles.temporaryRoot = privateRoot
    defer {
        RmskinFiles.temporaryRoot = savedRoot
        RmskinFiles.forceRemove(privateRoot)
    }
    legacyManifestTests(t)
    legacyRainstallerTests(t)
    legacyPlainArchiveTests(t)
    legacyFolderTests(t)
    legacyFontTests(t)
    legacyThemeTests(t)
    legacyBadArchiveTests(t)
    legacyFixtureTests(t)
    legacyReviewTests(t)
}

// MARK: - Helpers

private func lgUTF8(_ s: String) -> Data { Data(s.utf8) }

private func lgUTF16LE(_ s: String) -> Data { Data([0xFF, 0xFE]) + (s.data(using: .utf16LittleEndian) ?? Data()) }

private func lgExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func lgText(_ url: URL) -> String? { (try? Data(contentsOf: url)).map(TextDecoding.decode) }

private func lgTemporaryItems() -> Set<String> {
    let root = RmskinFiles.temporaryRoot ?? FileManager.default.temporaryDirectory
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return Set(names.filter { $0.hasPrefix("Deskset-") })
}

private func lgWriteTree(_ files: [(String, Data)], at root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, data) in files {
        let url = root.appendingPathComponent(path)
        if path.hasSuffix("/") {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }
}

private func lgFooter(_ length: Int) -> Data {
    var data = Data()
    for i in 0..<8 { data.append(UInt8((UInt64(length) >> (8 * UInt64(i))) & 0xFF)) }
    return data + Data(RmskinPackage.footerMagic)
}

/// Zips a file list (paths relative to the archive root) with ditto, like Archive Utility or a Windows zipper would;
/// optionally adds the .rmskin footer.
private func lgArchive(_ files: [(String, Data)], in dir: URL, name: String, footer: Bool = false) throws -> URL {
    let source = dir.appendingPathComponent("src-\(UUID().uuidString)")
    try lgWriteTree(files, at: source)
    let zip = dir.appendingPathComponent("\(UUID().uuidString).zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", source.path, zip.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw RmskinError.extractionFailed("test zip creation failed") }
    var data = try Data(contentsOf: zip)
    if footer { data += lgFooter(data.count) }
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: zip)
    return url
}

/// A hand-made ZIP with stored entries, for archives no zipper would produce (zip-slip, symlinks).
private enum LegacyZip {
    struct Entry {
        var name: String
        var data: Data = Data()
        var unixMode: UInt32?
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    static func make(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)
            out += le32(0x0403_4B50) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)
            out += le32(crc) + le32(size) + le32(size) + le16(name.count) + le16(0) + name + entry.data
            let madeBy = entry.unixMode == nil ? 20 : (3 << 8) | 20
            let external = entry.unixMode.map { $0 << 16 } ?? (name.last == 0x2F ? 0x10 : 0)
            central += le32(0x0201_4B50) + le16(madeBy) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)
            central += le32(crc) + le32(size) + le32(size) + le16(name.count) + le16(0) + le16(0) + le16(0)
            central += le16(0) + le32(external) + le32(offset) + name
        }
        let directoryOffset = UInt32(out.count)
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
        out += le32(UInt32(central.count)) + le32(directoryOffset) + le16(0)
        return out
    }
}

private func lgExpect(_ t: TestRunner, _ label: String, file: StaticString = #fileID, line: UInt = #line,
                      _ matching: (RmskinError) -> Bool, _ body: () throws -> Void) {
    do {
        try body()
        t.check(false, "\(label): expected an error", file: file, line: line)
    } catch let error as RmskinError {
        t.check(matching(error), "\(label): got \(error)", file: file, line: line)
    } catch {
        t.check(false, "\(label): got non-Rmskin error \(error)", file: file, line: line)
    }
}

private func lgIsExtractionFailed(_ e: RmskinError) -> Bool {
    if case .extractionFailed = e { return true } else { return false }
}

private func lgIsUnreadable(_ e: RmskinError) -> Bool { if case .unreadable = e { return true } else { return false } }

private func lgIsNotAPackage(_ e: RmskinError) -> Bool { if case .notAPackage = e { return true } else { return false } }

private let fakeFont = Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x0A]) // TrueType signature; contents do not matter here

/// An original legacy package: Rainstaller.cfg, Skins, Fonts, Addons, empty Plugins, Themes.
private func rainstallerFiles(cfg: String, prefix: String = "") -> [(String, Data)] {
    [
        (prefix + "Rainstaller.cfg", lgUTF8(cfg)),
        (prefix + "Skins/Lumen/Clock/Clock.ini", lgUTF8("[Rainmeter]\nUpdate=1000\n[Variables]\nTint=1,2,3\n")),
        (prefix + "Skins/Lumen/Disk/Disk.ini", lgUTF8("[Rainmeter]\n")),
        (prefix + "Skins/Lumen/@Resources/Settings.inc", lgUTF8("[Variables]\nUnit=C\nCity=Oslo\n")),
        (prefix + "Fonts/LumenMono.ttf", fakeFont),
        (prefix + "Fonts/Extra/LumenWide.OTF", fakeFont),
        (prefix + "Fonts/License.txt", lgUTF8("free")),
        (prefix + "Addons/Helper/helper.exe", Data([0x4D, 0x5A])),
        (prefix + "Plugins/", Data()),
        (prefix + "Themes/Lumen Desk/Rainmeter.thm",
         lgUTF8("[Rainmeter]\r\nSkinPath=C:\\Skins\\\r\n\r\n[Lumen\\Clock]\r\nActive=1\r\nWindowX=10\r\n")),
    ]
}

private let rainstallerCfg = """
; comment line as in real packages\r
\r
[Rainstaller]\r
Name=Lumen\r
Author=Deskset tests\r
Version=2.0\r
AdminRights=1\r
RainmeterFonts=\r
MinRainmeterVer=1.3.0\r
Merge=\r
KeepVar=\r
LaunchType=Theme\r
LaunchCommand=Lumen Desk\r

"""

// MARK: - Rainstaller.cfg

private func legacyManifestTests(_ t: TestRunner) {
    t.suite("RmskinLegacy: Rainstaller.cfg keys") {
        let m = RmskinManifest.parseRainstaller(rainstallerCfg)
        t.equal(m.packageFormat, .rainstaller)
        t.equal(m.name, "Lumen")
        t.equal(m.author, "Deskset tests")
        t.equal(m.version, "2.0")
        t.equal(m.minimumRainmeter, "1.3.0")
        t.equal(m.mergeSkins, false)
        t.equal(m.keepsAllVariables, false)
        t.equal(m.variableFiles, [])
        t.equal(m.loadType, "Layout")
        t.equal(m.load, "Lumen Desk")
        t.equal(m.raw["AdminRights"], "1", "unmodelled keys stay reachable")
        t.equal(m.raw.name, "Rainstaller")

        let other = RmskinManifest.parseRainstaller("[rainstaller]\nname=X\nMerge=1\nKeepVar=1\n")
        t.equal(other.name, "X", "section and keys are case-insensitive")
        t.equal(other.mergeSkins, true)
        t.equal(other.keepsAllVariables, true)
        t.equal(RmskinManifest.parseRainstaller("[Rainstaller]\nKeepVar=0\n").keepsAllVariables, false)
        t.equal(RmskinManifest.parseRainstaller("[Rainstaller]\nKeepVar=Yes\n").keepsAllVariables, true)
        t.equal(RmskinManifest.parseRainstaller("[Rainstaller]\nKeepVar=off\n").variableFiles, [], "a switch, not a file")
        let list = RmskinManifest.parseRainstaller("[Rainstaller]\nKeepVar=Lumen\\@Resources\\Settings.inc | \"Lumen\\Clock\\Clock.ini\"\n")
        t.equal(list.variableFiles, ["Lumen\\@Resources\\Settings.inc", "Lumen\\Clock\\Clock.ini"])
        t.equal(list.keepsAllVariables, false)

        let empty = RmskinManifest.parseRainstaller("no section here")
        t.equal(empty.packageFormat, .rainstaller)
        t.equal(empty.name, "")
        t.equal(RmskinManifest.parse(rainstallerCfg).name, "", "RMSKIN.ini parsing ignores [Rainstaller]")
        t.equal(RmskinManifest.parse("[rmskin]\nName=A\n").packageFormat, .rmskin)
        t.equal(RmskinManifest.parseRainstaller(TextDecoding.decode(lgUTF16LE(rainstallerCfg))).name, "Lumen",
                "UTF-16 configuration")
    }

    t.suite("RmskinLegacy: LaunchType and LaunchCommand") {
        func launch(_ type: String, _ command: String) -> [String] {
            let r = RmskinManifest.rainstallerLaunch(type: type, command: command)
            return [r.type, r.load]
        }
        t.equal(launch("Theme", "Pog Desk"), ["Layout", "Pog Desk"])
        t.equal(launch("theme", "\"My Theme\""), ["Layout", "My Theme"], "quoted command")
        t.equal(launch("Theme", "My Theme\\Rainmeter.thm"), ["Layout", "My Theme"], "theme named by its file")
        t.equal(launch("Layout", "Desk"), ["Layout", "Desk"])
        t.equal(launch("load", "Suite\\Clock\\Clock.ini"), ["Skin", "Suite\\Clock\\Clock.ini"])
        t.equal(launch("Skin", "Suite\\Clock"), ["Skin", "Suite\\Clock"])
        t.equal(launch("Config", "Suite/Clock/Clock.ini"), ["Skin", "Suite/Clock/Clock.ini"])
        t.equal(launch("", "Suite\\Clock\\Clock.ini"), ["", "Suite\\Clock\\Clock.ini"], "inferred later from .ini")
        t.equal(launch("", ""), ["", ""])
        t.equal(launch("Command", "!RainmeterActivateConfig \"Suite\\Clock\" \"Clock.ini\""),
                ["Skin", "Suite\\Clock\\Clock.ini"], "bang with the old prefix")
        t.equal(launch("", "!ActivateConfig Suite\\Clock"), ["Skin", "Suite\\Clock"])
        t.equal(launch("", "!LoadLayout \"Big Desk\""), ["Layout", "Big Desk"])
        t.equal(launch("", "!RainmeterLoadTheme Old"), ["Layout", "Old"])
        t.equal(launch("", "!Refresh"), ["", "!Refresh"], "other bangs are left for the installer to report")
        t.equal(launch("Execute", "setup.exe"), ["Execute", "setup.exe"], "unknown types pass through")
        t.equal(launch("", "!ActivateConfig"), ["", ""], "bang without arguments")
    }

    t.suite("RmskinLegacy: root config names from file names") {
        t.equal(RmskinPackage.sanitizedRootName("Tiny Clock"), "Tiny Clock")
        t.equal(RmskinPackage.sanitizedRootName("a/b\\c:d"), "a-b-c-d")
        t.equal(RmskinPackage.sanitizedRootName("..@hidden. "), "hidden")
        t.equal(RmskinPackage.sanitizedRootName(" . "), "Skin")
        t.equal(RmskinPackage.sanitizedRootName(""), "Skin")
        t.equal(RmskinPackage.sanitizedRootName(String(repeating: "x", count: 300)).count, 200)
        t.equal(RmskinPackage.displayName(of: URL(fileURLWithPath: "/tmp/My Skin 1.0.zip")), "My Skin 1.0")
        t.check(RmskinPackage.canInspect(URL(fileURLWithPath: "/tmp/a.RMSKIN")))
        t.check(RmskinPackage.canInspect(URL(fileURLWithPath: "/tmp/a.zip")))
        t.check(!RmskinPackage.canInspect(URL(fileURLWithPath: "/tmp/a.rar")))
        t.check(RmskinPackage.canInspect(FileManager.default.temporaryDirectory), "folders")
    }
}

// MARK: - Rainstaller packages

private func legacyRainstallerTests(_ t: TestRunner) {
    t.suite("RmskinLegacy: Rainstaller package inspect and install") {
        let dir = t.temporaryDirectory("legacy-rainstaller")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try lgArchive(rainstallerFiles(cfg: rainstallerCfg), in: dir, name: "lumen.rmskin")
        let before = lgTemporaryItems()
        let inspection = try RmskinPackage.inspect(package)
        t.equal(inspection.manifest.packageFormat, .rainstaller)
        t.equal(inspection.manifest.name, "Lumen")
        t.equal(inspection.rootConfigs, ["Lumen"])
        t.equal(inspection.layouts, ["Lumen Desk"], "Themes become layouts")
        t.equal(inspection.containsLayouts, true)
        t.equal(inspection.legacyFonts.map(\.lastPathComponent).sorted(), ["LumenMono.ttf", "LumenWide.OTF"])
        t.equal(inspection.fontNames, ["LumenMono.ttf", "LumenWide.OTF"])
        t.equal(inspection.containsAddons, true)
        t.equal(inspection.containsPlugins, false, "an empty Plugins folder is nothing")
        t.check(inspection.warnings.contains { $0.contains("add-on") })
        t.check(lgExists(inspection.packageRoot.appendingPathComponent("Skins/Lumen/Clock/Clock.ini")),
                "packageRoot/Skins holds the root configs (the app lists configs from there)")

        let skins = dir.appendingPathComponent("Skins"), layouts = dir.appendingPathComponent("Layouts")
        let result = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins,
                                                 layoutsDirectory: layouts)
        inspection.cleanup()
        t.equal(lgTemporaryItems(), before, "no temporary leftovers")
        t.equal(result.manifest.packageFormat, .rainstaller)
        t.equal(result.installedRootConfigs, ["Lumen"])
        t.equal(result.installedLayouts, ["Lumen Desk"])
        t.equal(result.layoutToLoad, "Lumen Desk")
        t.equal(result.skinToLoadConfig, nil)
        t.equal(result.installedFonts, ["LumenMono.ttf", "LumenWide.OTF"])
        t.check(lgExists(skins.appendingPathComponent("Lumen/@Resources/Fonts/LumenMono.ttf")))
        t.check(lgExists(skins.appendingPathComponent("Lumen/@Resources/Fonts/LumenWide.OTF")), "fonts are flattened")
        t.check(!lgExists(skins.appendingPathComponent("Lumen/@Resources/Fonts/License.txt")))
        t.check(!lgExists(skins.appendingPathComponent("Fonts")))
        t.check(!lgExists(skins.appendingPathComponent("Addons")))
        t.check(!lgExists(skins.appendingPathComponent("Themes")))
        t.equal(lgText(layouts.appendingPathComponent("Lumen Desk/Rainmeter.ini")),
                "[Rainmeter]\r\n\r\n[Lumen\\Clock]\r\nActive=1\r\nWindowX=10\r\n",
                "Rainmeter.thm → Rainmeter.ini, global [Rainmeter] options removed")
        t.check(!lgExists(layouts.appendingPathComponent("Lumen Desk/Rainmeter.thm")))
    }

    t.suite("RmskinLegacy: Rainstaller wrapped in a folder, loading a skin") {
        let dir = t.temporaryDirectory("legacy-wrapped")
        defer { RmskinFiles.forceRemove(dir) }
        let cfg = "[Rainstaller]\r\nName=Lumen\r\nLaunchType=load\r\nLaunchCommand=lumen\\clock\\CLOCK.ini\r\n"
        let package = try lgArchive(rainstallerFiles(cfg: cfg, prefix: "Lumen 2.0/"), in: dir, name: "Lumen 2.0.zip")
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(result.installedRootConfigs, ["Lumen"])
        t.equal(result.skinToLoadConfig, "Lumen\\Clock", "spelled as on disk")
        t.equal(result.skinToLoadFile, "Clock.ini")
        t.check(result.warnings.contains { $0.contains("Lumen Desk") }, "layouts without a layouts folder are reported")

        // Two wrapper folders (an archive of the downloaded folder).
        let deep = try lgArchive(rainstallerFiles(cfg: cfg, prefix: "Downloads/Lumen 2.0/"), in: dir, name: "deep.zip")
        let deepInspection = try RmskinPackage.inspect(deep)
        t.equal(deepInspection.manifest.packageFormat, .rainstaller)
        t.equal(deepInspection.rootConfigs, ["Lumen"])
        deepInspection.cleanup()

        // A launch command naming only the config folder loads its first skin.
        let bang = "[Rainstaller]\nName=Lumen\nLaunchCommand=!RainmeterActivateConfig \"Lumen\\Disk\"\n"
        let second = try lgArchive(rainstallerFiles(cfg: bang), in: dir, name: "bang.rmskin")
        let r2 = try RmskinInstaller.install(packageURL: second, skinsDirectory: skins)
        t.equal(r2.skinToLoadConfig, "Lumen\\Disk")
        t.equal(r2.skinToLoadFile, "Disk.ini")

        let unknown = try lgArchive(rainstallerFiles(cfg: "[Rainstaller]\nLaunchType=Program\nLaunchCommand=x.exe\n"),
                                    in: dir, name: "unknown.rmskin")
        let r3 = try RmskinInstaller.install(packageURL: unknown, skinsDirectory: skins)
        t.equal(r3.skinToLoadConfig, nil)
        t.check(r3.warnings.contains { $0.contains("Unknown LoadType") })
    }

    t.suite("RmskinLegacy: Rainstaller KeepVar and Merge") {
        let dir = t.temporaryDirectory("legacy-keepvar")
        defer { RmskinFiles.forceRemove(dir) }
        let skins = dir.appendingPathComponent("Skins"), backups = dir.appendingPathComponent("Backups")
        func install(_ cfg: String) throws -> RmskinInstallResult {
            let package = try lgArchive(rainstallerFiles(cfg: cfg), in: dir, name: "\(UUID().uuidString).rmskin")
            return try RmskinInstaller.install(packageURL: package, skinsDirectory: skins, backupDirectory: backups)
        }
        func customise() throws {
            try lgUTF8("[Rainmeter]\nUpdate=1000\n[Variables]\nTint=9,9,9\n")
                .write(to: skins.appendingPathComponent("Lumen/Clock/Clock.ini"))
            try lgUTF8("[Variables]\nUnit=F\nCity=Lima\n").write(to: skins.appendingPathComponent("Lumen/@Resources/Settings.inc"))
            try lgUTF8("mine").write(to: skins.appendingPathComponent("Lumen/Notes.txt"))
        }
        _ = try install("[Rainstaller]\nName=Lumen\n")
        try customise()

        // KeepVar=1: every .ini / .inc keeps the user's [Variables] values.
        let kept = try install("[Rainstaller]\nName=Lumen\nKeepVar=1\n")
        t.equal(kept.preservedVariableCount, 3)
        t.equal(lgText(skins.appendingPathComponent("Lumen/Clock/Clock.ini")), "[Rainmeter]\nUpdate=1000\n[Variables]\nTint=9,9,9\n")
        t.equal(lgText(skins.appendingPathComponent("Lumen/@Resources/Settings.inc")), "[Variables]\nUnit=F\nCity=Lima\n")
        t.check(!lgExists(skins.appendingPathComponent("Lumen/Notes.txt")), "not merging: the folder is replaced")
        t.check(lgExists(backups.appendingPathComponent("Lumen/Notes.txt")), "and backed up")

        // KeepVar as a file list: only the listed file.
        try customise()
        let listed = try install("[Rainstaller]\nName=Lumen\nKeepVar=Lumen\\@Resources\\Settings.inc\n")
        t.equal(listed.preservedVariableCount, 2)
        t.equal(lgText(skins.appendingPathComponent("Lumen/Clock/Clock.ini")), "[Rainmeter]\nUpdate=1000\n[Variables]\nTint=1,2,3\n")
        t.equal(lgText(skins.appendingPathComponent("Lumen/@Resources/Settings.inc")), "[Variables]\nUnit=F\nCity=Lima\n")

        // KeepVar=0: package defaults.
        try customise()
        let reset = try install("[Rainstaller]\nName=Lumen\nKeepVar=0\n")
        t.equal(reset.preservedVariableCount, 0)
        t.equal(lgText(skins.appendingPathComponent("Lumen/@Resources/Settings.inc")), "[Variables]\nUnit=C\nCity=Oslo\n")

        // Merge=1: existing files stay, package files are added over them.
        try customise()
        let merged = try install("[Rainstaller]\nName=Lumen\nMerge=1\n")
        t.equal(merged.manifest.mergeSkins, true)
        t.equal(lgText(skins.appendingPathComponent("Lumen/Notes.txt")), "mine")
        t.equal(lgText(skins.appendingPathComponent("Lumen/@Resources/Settings.inc")), "[Variables]\nUnit=C\nCity=Oslo\n")
    }

    t.suite("RmskinLegacy: kept variables stay in the user's ANSI code page") {
        // Old skins are often ANSI files in the author's Windows code page (GBK here); rewriting one to keep the
        // user's values must not turn it into Windows-1252 or UTF-16.
        let saved = TextDecoding.ansiCodePage
        TextDecoding.ansiCodePage = 936
        defer { TextDecoding.ansiCodePage = saved }
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertWindowsCodepageToEncoding(936)))
        let dir = t.temporaryDirectory("legacy-gbk")
        defer { RmskinFiles.forceRemove(dir) }
        let url = dir.appendingPathComponent("Settings.inc")
        let original = "[Variables]\r\n城市=北京\r\n"
        guard let data = original.data(using: gbk) else { t.check(false, "GBK unavailable"); return }
        try data.write(to: url)
        try RmskinTextEncoding.rewriteFile(at: url) { $0.replacingOccurrences(of: "北京", with: "上海") }
        t.equal(try Data(contentsOf: url), "[Variables]\r\n城市=上海\r\n".data(using: gbk))
        try RmskinTextEncoding.rewriteFile(at: url) { $0 + "名=Grüße ☃\r\n" }
        t.equal(Array((try Data(contentsOf: url)).prefix(2)), [0xFF, 0xFE], "unrepresentable text → UTF-16 LE")
        t.equal(lgText(url), "[Variables]\r\n城市=上海\r\n名=Grüße ☃\r\n")
    }

    t.suite("RmskinLegacy: RMSKIN.ini wins over Rainstaller.cfg") {
        let dir = t.temporaryDirectory("legacy-both")
        defer { RmskinFiles.forceRemove(dir) }
        var files = rainstallerFiles(cfg: rainstallerCfg)
        files.append(("RMSKIN.ini", lgUTF8("[rmskin]\nName=Modern\n")))
        let inspection = try RmskinPackage.inspect(try lgArchive(files, in: dir, name: "both.rmskin", footer: true))
        defer { inspection.cleanup() }
        t.equal(inspection.manifest.packageFormat, .rmskin)
        t.equal(inspection.manifest.name, "Modern")
        t.equal(inspection.layouts, ["Lumen Desk"], "legacy Themes are still converted")

        // A packager-made file (with footer) may also carry a Rainstaller.cfg only.
        let footed = try RmskinPackage.inspect(try lgArchive(rainstallerFiles(cfg: rainstallerCfg), in: dir,
                                                             name: "footed.rmskin", footer: true))
        defer { footed.cleanup() }
        t.equal(footed.manifest.packageFormat, .rainstaller)
    }
}

// MARK: - Plain archives

private func legacyPlainArchiveTests(_ t: TestRunner) {
    t.suite("RmskinLegacy: plain zip with one root config") {
        let dir = t.temporaryDirectory("legacy-plain1")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try lgArchive([
            ("Pebble/Clock/Clock.ini", lgUTF8("[Rainmeter]\n[Meter]\nMeter=String\n")),
            ("Pebble/@Resources/Back.png", Data([0x89, 0x50])),
            ("Pebble/.DS_Store", Data([0])),
        ], in: dir, name: "Pebble.zip")
        let before = lgTemporaryItems()
        let inspection = try RmskinPackage.inspect(package)
        t.equal(inspection.manifest.packageFormat, .plain)
        t.equal(inspection.manifest.name, "Pebble")
        t.equal(inspection.manifest.author, "")
        t.equal(inspection.rootConfigs, ["Pebble"])
        t.equal(inspection.manifest.loadType, "Skin", "a single skin is loaded after installing")
        t.equal(inspection.manifest.load, "Pebble\\Clock\\Clock.ini")
        t.equal(inspection.warnings, [])
        t.check(lgExists(inspection.packageRoot.appendingPathComponent("Skins/Pebble/Clock/Clock.ini")))
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        inspection.cleanup()
        t.equal(lgTemporaryItems(), before)
        t.equal(result.installedRootConfigs, ["Pebble"])
        t.equal(result.skinToLoadConfig, "Pebble\\Clock")
        t.equal(result.skinToLoadFile, "Clock.ini")
        t.check(lgExists(skins.appendingPathComponent("Pebble/@Resources/Back.png")))
        t.check(!lgExists(skins.appendingPathComponent("Pebble/.DS_Store")))
        t.equal((try? FileManager.default.contentsOfDirectory(atPath: skins.path)) ?? [], ["Pebble"])
    }

    t.suite("RmskinLegacy: plain archive renamed .rmskin, several root configs") {
        let dir = t.temporaryDirectory("legacy-plain2")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try lgArchive([
            ("Alpha/Clock/Clock.ini", lgUTF8("[Rainmeter]\n")),
            ("Beta/Beta.ini", lgUTF8("[Rainmeter]\n")),
            ("Beta/Fonts/BetaSans.otf", fakeFont),
            ("Fonts/Shared.ttf", fakeFont),
            ("Shared Serif.TTF", fakeFont),
            ("Old.fon", Data([0x4D, 0x5A])),
            ("Wallpapers/desk.jpg", Data([0xFF, 0xD8])),
            ("Plugins/Tool.dll", Data([0x4D, 0x5A])),
            ("Read me.txt", lgUTF8("hi")),
        ], in: dir, name: "Duo Pack.rmskin")
        let inspection = try RmskinPackage.inspect(package)
        defer { inspection.cleanup() }
        t.equal(inspection.manifest.packageFormat, .plain)
        t.equal(inspection.manifest.name, "Duo Pack", "several root configs: named after the archive")
        t.equal(inspection.rootConfigs, ["Alpha", "Beta"])
        t.equal(inspection.manifest.load, "", "several skins: nothing is loaded")
        t.equal(inspection.legacyFonts.map(\.lastPathComponent).sorted(), ["Shared Serif.TTF", "Shared.ttf"])
        t.equal(inspection.rootConfigFonts["Beta"]?.map(\.lastPathComponent), ["BetaSans.otf"])
        t.equal(inspection.pluginNames, ["Tool.dll"])
        t.check(inspection.warnings.contains { $0.contains("Wallpapers") }, "ignored folders are named")
        t.check(inspection.warnings.contains { $0.contains("Old.fon") }, "unusable font formats are named")
        t.check(!inspection.warnings.contains { $0.contains("Read me") }, "loose documents are not warnings")

        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        t.equal(result.installedRootConfigs, ["Alpha", "Beta"])
        t.equal(result.skinToLoadConfig, nil)
        t.equal(result.containsPlugins, true)
        for root in ["Alpha", "Beta"] {
            t.check(lgExists(skins.appendingPathComponent("\(root)/@Resources/Fonts/Shared.ttf")), root)
            t.check(lgExists(skins.appendingPathComponent("\(root)/@Resources/Fonts/Shared Serif.TTF")), root)
        }
        t.check(lgExists(skins.appendingPathComponent("Beta/@Resources/Fonts/BetaSans.otf")))
        t.check(!lgExists(skins.appendingPathComponent("Alpha/@Resources/Fonts/BetaSans.otf")), "own fonts stay own")
        t.equal(result.installedFonts, ["BetaSans.otf", "Shared Serif.TTF", "Shared.ttf"])
        t.equal(Set((try? FileManager.default.contentsOfDirectory(atPath: skins.path)) ?? []), ["Alpha", "Beta"])
    }

    t.suite("RmskinLegacy: plain archive with a Skins folder below a wrapper") {
        let dir = t.temporaryDirectory("legacy-plain3")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try lgArchive([
            ("Kit 2.0/Skins/Kit/Clock/Clock.ini", lgUTF8("[Rainmeter]\n")),
            ("Kit 2.0/Skins/Kit/Disk/Disk.ini", lgUTF8("[Rainmeter]\n")),
            ("Kit 2.0/Fonts/KitFont.ttf", fakeFont),
            ("Kit 2.0/Themes/Kit/Rainmeter.thm", lgUTF8("[Kit\\Clock]\nActive=1\n")),
            ("Kit 2.0/Addons/Setup/setup.exe", Data([0x4D, 0x5A])),
        ], in: dir, name: "kit.zip")
        let inspection = try RmskinPackage.inspect(package)
        defer { inspection.cleanup() }
        t.equal(inspection.manifest.packageFormat, .plain)
        t.equal(inspection.manifest.name, "Kit 2.0")
        t.equal(inspection.rootConfigs, ["Kit"])
        t.equal(inspection.layouts, ["Kit"])
        t.equal(inspection.legacyFonts.map(\.lastPathComponent), ["KitFont.ttf"])
        t.equal(inspection.containsAddons, true)
        let skins = dir.appendingPathComponent("Skins"), layouts = dir.appendingPathComponent("Layouts")
        let result = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins, layoutsDirectory: layouts)
        t.equal(result.installedLayouts, ["Kit"])
        t.equal(result.layoutToLoad, nil, "no manifest: nothing is applied")
        t.check(lgExists(skins.appendingPathComponent("Kit/@Resources/Fonts/KitFont.ttf")))
        t.check(lgExists(layouts.appendingPathComponent("Kit/Rainmeter.ini")))
    }

    t.suite("RmskinLegacy: plain archive wrapper detection") {
        let dir = t.temporaryDirectory("legacy-plain4")
        defer { RmskinFiles.forceRemove(dir) }
        func roots(_ files: [(String, Data)], name: String = "x.zip") throws -> [String] {
            let inspection = try RmskinPackage.inspect(try lgArchive(files, in: dir, name: name))
            defer { inspection.cleanup() }
            return inspection.rootConfigs
        }
        let ini = lgUTF8("[Rainmeter]\n")
        // A single folder whose sub-folder has @Resources is a wrapper (twice here).
        t.equal(try roots([("Outer/Download/Real/@Resources/Vars.inc", lgUTF8("[Variables]\n")),
                           ("Outer/Download/Real/Clock/Clock.ini", ini)]), ["Real"])
        // Skins addressing their files through #SKINSPATH#Name\ name their root config.
        t.equal(try roots([("Bundle v3/Gauge/Meter/Meter.ini",
                            lgUTF8("[Rainmeter]\n[M]\nMeter=Image\nImageName=#SKINSPATH#Gauge\\Images\\a.png\n")),
                           ("Bundle v3/Gauge/Images/a.png", Data([0x89]))]), ["Gauge"])
        t.equal(try roots([("Gauge/Meter/Meter.ini", lgUTF8("[M]\nImageName=#SKINSPATH#Gauge\\a.png\n"))]), ["Gauge"],
                "the referenced folder is never unwrapped")
        // Otherwise a single folder is the root config, with its configs below it.
        t.equal(try roots([("Suite/Clock/Clock.ini", ini), ("Suite/Disk/Disk.ini", ini)]), ["Suite"])
        t.equal(try roots([("Suite/Only/Deep/Deep.ini", ini)]), ["Suite"])
        // Folders with .ini files directly are root configs, even when their name looks like a component.
        t.equal(try roots([("Clock/Clock.ini", ini), ("Fonts/F.ttf", fakeFont), ("Layouts/L/Rainmeter.ini", ini)]),
                ["Clock"])
        // @ folders are never root configs.
        t.equal(try roots([("@Vault/Thing/Thing.ini", ini), ("Real/Real.ini", ini)]), ["Real"])
    }

    t.suite("RmskinLegacy: archive that is itself one root config") {
        let dir = t.temporaryDirectory("legacy-plain5")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try lgArchive([
            ("Clock.ini", lgUTF8("[Rainmeter]\n")),
            ("back.png", Data([0x89])),
            ("Fonts/Dial.ttf", fakeFont),
        ], in: dir, name: "Tiny Clock.zip")
        let inspection = try RmskinPackage.inspect(package)
        defer { inspection.cleanup() }
        t.equal(inspection.rootConfigs, ["Tiny Clock"])
        t.equal(inspection.manifest.name, "Tiny Clock")
        t.equal(inspection.manifest.load, "Tiny Clock\\Clock.ini")
        t.equal(inspection.rootConfigFonts["Tiny Clock"]?.map(\.lastPathComponent), ["Dial.ttf"])
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        t.equal(result.skinToLoadConfig, "Tiny Clock")
        t.equal(result.skinToLoadFile, "Clock.ini")
        t.check(lgExists(skins.appendingPathComponent("Tiny Clock/back.png")))
        t.check(lgExists(skins.appendingPathComponent("Tiny Clock/@Resources/Fonts/Dial.ttf")))

        // The archive's name is made safe for a folder name.
        let odd = try RmskinPackage.inspect(try lgArchive([("Clock.ini", lgUTF8("[Rainmeter]\n"))], in: dir,
                                                          name: ".@Odd: Name .zip"))
        defer { odd.cleanup() }
        t.equal(odd.rootConfigs, ["Odd- Name"])
    }

    t.suite("RmskinLegacy: plain archive upgrade keeps backups") {
        let dir = t.temporaryDirectory("legacy-plain6")
        defer { RmskinFiles.forceRemove(dir) }
        let skins = dir.appendingPathComponent("Skins"), backups = dir.appendingPathComponent("Backups")
        let v1 = try lgArchive([("Pebble/Clock/Clock.ini", lgUTF8("v1"))], in: dir, name: "p1.zip")
        let v2 = try lgArchive([("Pebble/Clock/Clock.ini", lgUTF8("v2"))], in: dir, name: "p2.zip")
        _ = try RmskinInstaller.install(packageURL: v1, skinsDirectory: skins, backupDirectory: backups)
        let r = try RmskinInstaller.install(packageURL: v2, skinsDirectory: skins, backupDirectory: backups)
        t.equal(lgText(skins.appendingPathComponent("Pebble/Clock/Clock.ini")), "v2")
        t.equal(r.backupLocations.map(\.lastPathComponent), ["Pebble"])
        t.equal(lgText(backups.appendingPathComponent("Pebble/Clock/Clock.ini")), "v1")
    }
}

// MARK: - Folders

private func legacyFolderTests(_ t: TestRunner) {
    t.suite("RmskinLegacy: install from an extracted folder") {
        let dir = t.temporaryDirectory("legacy-folder")
        defer { RmskinFiles.forceRemove(dir) }
        let folder = dir.appendingPathComponent("Downloads/Pebble")
        try lgWriteTree([
            ("Clock/Clock.ini", lgUTF8("[Rainmeter]\n")),
            ("Clock/.hidden.ini", lgUTF8("x")),
            ("@Resources/Fonts/Own.ttf", fakeFont),
            ("Fonts/Loose.ttf", fakeFont),
        ], at: folder)
        let outside = dir.appendingPathComponent("Outside")
        try lgWriteTree([("secret.txt", lgUTF8("secret"))], at: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Clock/link.txt"),
                                                   withDestinationURL: outside.appendingPathComponent("secret.txt"))
        let before = lgTemporaryItems()
        let inspection = try RmskinPackage.inspect(folder)
        t.equal(inspection.manifest.packageFormat, .plain)
        t.equal(inspection.rootConfigs, ["Pebble"])
        t.check(inspection.warnings.contains { $0.contains("symbolic link") })
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        inspection.cleanup()
        t.equal(result.skinToLoadConfig, "Pebble\\Clock")
        t.equal(result.installedFonts, ["Loose.ttf"])
        t.check(lgExists(skins.appendingPathComponent("Pebble/@Resources/Fonts/Own.ttf")))
        t.check(lgExists(skins.appendingPathComponent("Pebble/@Resources/Fonts/Loose.ttf")))
        t.check(!lgExists(skins.appendingPathComponent("Pebble/Link")), "links are not followed")
        t.check(!lgExists(skins.appendingPathComponent("Pebble/Clock/link.txt")))
        t.check(!lgExists(skins.appendingPathComponent("Pebble/Clock/.hidden.ini")))
        t.check(lgExists(folder.appendingPathComponent("Clock/Clock.ini")), "the source folder is left alone")
        t.check(lgExists(folder.appendingPathComponent("Fonts/Loose.ttf")))

        // install(packageURL:) accepts folders too.
        let again = try RmskinInstaller.install(packageURL: folder, skinsDirectory: dir.appendingPathComponent("Skins2"))
        t.equal(again.installedRootConfigs, ["Pebble"])

        // A folder that is, contains or lies in the Skins folder is not installed into it.
        let inSkins = skins.appendingPathComponent("Pebble")
        lgExpect(t, "folder inside the Skins folder", { $0 == .alreadyInSkinsFolder }) {
            _ = try RmskinInstaller.install(packageURL: inSkins, skinsDirectory: skins)
        }
        lgExpect(t, "the Skins folder itself", { $0 == .alreadyInSkinsFolder }) {
            _ = try RmskinInstaller.install(packageURL: skins, skinsDirectory: skins.appendingPathComponent("."))
        }
        lgExpect(t, "a folder holding the Skins folder", { $0 == .alreadyInSkinsFolder }) {
            _ = try RmskinInstaller.install(packageURL: dir, skinsDirectory: skins)
        }
        t.equal(lgTemporaryItems(), before)
        t.check(RmskinPackage.folder(URL(fileURLWithPath: "/a/Skins"), overlaps: URL(fileURLWithPath: "/a/skins/x")))
        t.check(!RmskinPackage.folder(URL(fileURLWithPath: "/a/Skins2"), overlaps: URL(fileURLWithPath: "/a/Skins")))
    }

    t.suite("RmskinLegacy: folders of each format") {
        let dir = t.temporaryDirectory("legacy-folders")
        defer { RmskinFiles.forceRemove(dir) }
        let modern = dir.appendingPathComponent("Modern")
        try lgWriteTree([("RMSKIN.ini", lgUTF8("[rmskin]\nName=Modern\nLoad=M\\M.ini\n")),
                         ("Skins/M/M.ini", lgUTF8("[Rainmeter]\n"))], at: modern)
        let a = try RmskinPackage.inspect(folder: modern)
        defer { a.cleanup() }
        t.equal(a.manifest.packageFormat, .rmskin)
        t.equal(a.rootConfigs, ["M"])

        let legacy = dir.appendingPathComponent("Legacy")
        try lgWriteTree(rainstallerFiles(cfg: rainstallerCfg), at: legacy)
        let b = try RmskinPackage.inspect(folder: legacy)
        defer { b.cleanup() }
        t.equal(b.manifest.packageFormat, .rainstaller)
        t.equal(b.layouts, ["Lumen Desk"])
        t.check(lgExists(legacy.appendingPathComponent("Themes/Lumen Desk/Rainmeter.thm")), "source not converted in place")

        // The chosen folder is what the user would move into Skins: without a wrapper mark it is the root config…
        let unmarked = dir.appendingPathComponent("My Suite")
        try lgWriteTree([("One/One.ini", lgUTF8("[Rainmeter]\n")), ("Two/Sub/Two.ini", lgUTF8("[Rainmeter]\n"))],
                        at: unmarked)
        let u = try RmskinPackage.inspect(folder: unmarked)
        defer { u.cleanup() }
        t.equal(u.rootConfigs, ["My Suite"])
        t.equal(u.manifest.name, "My Suite")
        // …and a folder of root configs marked by @Resources is a collection.
        let collection = dir.appendingPathComponent("My Skins")
        try lgWriteTree([("One/One.ini", lgUTF8("[Rainmeter]\n")), ("One/@Resources/v.inc", lgUTF8("[Variables]\n")),
                         ("Two/Sub/Two.ini", lgUTF8("[Rainmeter]\n"))], at: collection)
        let c = try RmskinPackage.inspect(folder: collection)
        defer { c.cleanup() }
        t.equal(c.rootConfigs, ["One", "Two"])

        let before = lgTemporaryItems()
        let empty = dir.appendingPathComponent("Pictures")
        try lgWriteTree([("a.png", Data([0x89])), ("b/c.txt", lgUTF8("x"))], at: empty)
        lgExpect(t, "folder without skins", { $0 == .nothingToInstall }) { _ = try RmskinPackage.inspect(folder: empty) }
        lgExpect(t, "not a folder", lgIsUnreadable) {
            _ = try RmskinPackage.inspect(folder: empty.appendingPathComponent("a.png"))
        }
        lgExpect(t, "missing folder", lgIsUnreadable) {
            _ = try RmskinPackage.inspect(folder: dir.appendingPathComponent("missing"))
        }
        t.equal(lgTemporaryItems(), before, "nothing left behind")
    }
}

// MARK: - Fonts

private func legacyFontTests(_ t: TestRunner) {
    t.suite("RmskinLegacy: fonts from a modern package") {
        // A modern .rmskin whose root config ships its fonts in <Root>/Fonts (Windows users installed them by hand).
        let dir = t.temporaryDirectory("legacy-fonts")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try lgArchive([
            ("RMSKIN.ini", lgUTF8("[rmskin]\nName=Watch\nLoadType=Skin\nLoad=Watch\\Watch.ini\n")),
            ("Skins/Watch/Watch.ini", lgUTF8("[Rainmeter]\n")),
            ("Skins/Watch/Fonts/Dial.ttf", fakeFont),
            ("Skins/Watch/Fonts/dial-bold.TTF", fakeFont),
            ("Skins/Watch/Fonts/Legacy.pfb", Data([0x80])),
            ("Skins/Watch/@Resources/Fonts/Keep.otf", lgUTF8("skin's own")),
            ("Skins/Watch/@Resources/Fonts/Dial.ttf", lgUTF8("skin's own copy")),
        ], in: dir, name: "watch.rmskin", footer: true)
        let skins = dir.appendingPathComponent("Skins")
        let inspection = try RmskinPackage.inspect(package)
        defer { inspection.cleanup() }
        t.equal(inspection.fontNames, ["dial-bold.TTF", "Dial.ttf"])
        t.check(inspection.warnings.contains { $0.contains("Legacy.pfb") })
        let result = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        t.equal(result.installedFonts, ["dial-bold.TTF"], "an existing font is never replaced")
        t.equal(lgText(skins.appendingPathComponent("Watch/@Resources/Fonts/Dial.ttf")), "skin's own copy")
        t.check(lgExists(skins.appendingPathComponent("Watch/@Resources/Fonts/dial-bold.TTF")))
        t.check(lgExists(skins.appendingPathComponent("Watch/Fonts/Dial.ttf")), "the original folder stays")
        t.check(!lgExists(skins.appendingPathComponent("Watch/@Resources/Fonts/Legacy.pfb")))

        // The user's own font of the same name (any case) survives a reinstall.
        try lgUTF8("user").write(to: skins.appendingPathComponent("Watch/@Resources/Fonts/dial-bold.TTF"))
        let merge = try lgArchive([
            ("RMSKIN.ini", lgUTF8("[rmskin]\nName=Watch\nMergeSkins=1\n")),
            ("Skins/Watch/Watch.ini", lgUTF8("[Rainmeter]\n")),
            ("Fonts/DIAL-BOLD.ttf", fakeFont),
        ], in: dir, name: "merge.rmskin", footer: true)
        let r2 = try RmskinInstaller.install(packageURL: merge, skinsDirectory: skins)
        t.equal(r2.installedFonts, [])
        t.equal(lgText(skins.appendingPathComponent("Watch/@Resources/Fonts/dial-bold.TTF")), "user")
    }

    t.suite("RmskinLegacy: fonts without a skin to hold them") {
        let dir = t.temporaryDirectory("legacy-fonts2")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try lgArchive([
            ("RMSKIN.ini", lgUTF8("[rmskin]\nLoadType=Layout\nLoad=Desk\n")),
            ("Layouts/Desk/Rainmeter.ini", lgUTF8("[Rainmeter]\n")),
            ("Fonts/Lonely.ttf", fakeFont),
        ], in: dir, name: "layout.rmskin", footer: true)
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: dir.appendingPathComponent("Skins"),
                                                 layoutsDirectory: dir.appendingPathComponent("Layouts"))
        t.equal(result.installedFonts, [])
        t.check(result.warnings.contains { $0.contains("no skin to hold them") })
    }
}

// MARK: - Themes

private func legacyThemeTests(_ t: TestRunner) {
    t.suite("RmskinLegacy: themes become layouts") {
        let dir = t.temporaryDirectory("legacy-themes")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try lgArchive([
            ("Rainstaller.cfg", lgUTF8("[Rainstaller]\nName=T\n")),
            ("Skins/T/T.ini", lgUTF8("[Rainmeter]\n")),
            ("Themes/Named/Named.thm", lgUTF8("[T]\nActive=1\n")),
            ("Themes/Named/Wallpaper.bmp", Data([0x42, 0x4D])),
            ("Themes/Both/Rainmeter.thm", lgUTF8("theme")),
            ("Themes/Both/Rainmeter.ini", lgUTF8("[Rainmeter]\n[T]\nActive=1\n")),
            ("Themes/Clash/Rainmeter.thm", lgUTF8("theme")),
            ("Layouts/Clash/Rainmeter.ini", lgUTF8("[T]\nActive=0\n")),
            ("Themes/loose.thm", lgUTF8("x")),
        ], in: dir, name: "themes.rmskin")
        let inspection = try RmskinPackage.inspect(package)
        defer { inspection.cleanup() }
        t.equal(inspection.layouts, ["Both", "Clash", "Named"])
        t.check(inspection.warnings.contains { $0.contains("Ignored theme Clash") })
        t.check(inspection.warnings.contains { $0.contains("loose.thm") })
        let layouts = dir.appendingPathComponent("Layouts")
        _ = try RmskinInstaller.install(inspection: inspection, skinsDirectory: dir.appendingPathComponent("Skins"),
                                        layoutsDirectory: layouts)
        t.equal(lgText(layouts.appendingPathComponent("Named/Rainmeter.ini")), "[T]\nActive=1\n",
                "a single .thm of another name is the layout file")
        t.check(lgExists(layouts.appendingPathComponent("Named/Wallpaper.bmp")))
        t.equal(lgText(layouts.appendingPathComponent("Both/Rainmeter.ini")), "[Rainmeter]\n[T]\nActive=1\n")
        t.equal(lgText(layouts.appendingPathComponent("Clash/Rainmeter.ini")), "[T]\nActive=0\n", "the layout wins")
    }
}

// MARK: - Bad archives

private func legacyBadArchiveTests(_ t: TestRunner) {
    t.suite("RmskinLegacy: archives without skins and damaged files") {
        let dir = t.temporaryDirectory("legacy-bad")
        defer { RmskinFiles.forceRemove(dir) }
        let before = lgTemporaryItems()
        let photos = try lgArchive([("Holiday/a.jpg", Data([0xFF, 0xD8])), ("notes.txt", lgUTF8("x"))], in: dir,
                                   name: "photos.zip")
        lgExpect(t, "zip without skins", { $0 == .nothingToInstall }) { _ = try RmskinPackage.inspect(photos) }
        let layoutsOnly = try lgArchive([("Layouts/Desk/Rainmeter.ini", lgUTF8("[Rainmeter]\n"))], in: dir,
                                        name: "layouts.zip")
        lgExpect(t, "zip with only a layout", { $0 == .nothingToInstall }) { _ = try RmskinPackage.inspect(layoutsOnly) }
        let resourcesOnly = try lgArchive([("@Resources/x.ini", lgUTF8("[Variables]\n"))], in: dir, name: "res.zip")
        lgExpect(t, "only @ folders", { $0 == .nothingToInstall }) { _ = try RmskinPackage.inspect(resourcesOnly) }
        let looseInSkins = try lgArchive([("Skins/Loose.ini", lgUTF8("[Rainmeter]\n"))], in: dir, name: "loose.zip")
        lgExpect(t, "a loose .ini in Skins is no skin", { $0 == .nothingToInstall }) {
            _ = try RmskinPackage.inspect(looseInSkins)
        }
        // With the Skin Packager's footer a manifest is still required (the packager always writes RMSKIN.ini).
        let footed = try lgArchive([("Skins/X/X.ini", lgUTF8("[Rainmeter]\n"))], in: dir, name: "x.rmskin", footer: true)
        lgExpect(t, "footer without manifest", { $0 == .missingManifest }) { _ = try RmskinPackage.inspect(footed) }
        let text = dir.appendingPathComponent("text.zip")
        try lgUTF8("this is not an archive at all").write(to: text)
        lgExpect(t, "not a zip", lgIsNotAPackage) { _ = try RmskinPackage.inspect(text) }
        var truncated = try Data(contentsOf: try lgArchive([("A/A.ini", lgUTF8("[Rainmeter]\n"))], in: dir, name: "t.zip"))
        truncated = truncated.prefix(truncated.count - 30)
        let cut = dir.appendingPathComponent("cut.zip")
        try truncated.write(to: cut)
        lgExpect(t, "truncated zip", lgIsExtractionFailed) { _ = try RmskinPackage.inspect(cut) }
        t.equal(lgTemporaryItems(), before, "temporary folders removed after every failure")
    }

    t.suite("RmskinLegacy: plain archives keep the extraction safety checks") {
        let dir = t.temporaryDirectory("legacy-hostile")
        defer { RmskinFiles.forceRemove(dir) }
        func archive(_ entries: [LegacyZip.Entry], _ name: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try LegacyZip.make(entries).write(to: url)
            return url
        }
        let before = lgTemporaryItems()
        let slip = try archive([.init(name: "Skin/Skin.ini", data: lgUTF8("[Rainmeter]\n")),
                                .init(name: "../escape.ini", data: lgUTF8("x"))], "slip.zip")
        lgExpect(t, "zip-slip", lgIsExtractionFailed) { _ = try RmskinPackage.inspect(slip) }
        t.check(!lgExists(dir.appendingPathComponent("escape.ini")))
        let absolute = try archive([.init(name: "/tmp/abs.ini", data: lgUTF8("x"))], "abs.zip")
        lgExpect(t, "absolute path", lgIsExtractionFailed) { _ = try RmskinPackage.inspect(absolute) }
        let link = try archive([.init(name: "Skin/Skin.ini", data: lgUTF8("[Rainmeter]\n")),
                                .init(name: "Skin/out", data: lgUTF8("/etc"), unixMode: 0o120777)], "link.zip")
        lgExpect(t, "symlink", lgIsExtractionFailed) { _ = try RmskinPackage.inspect(link) }
        let rainstallerSlip = try archive([.init(name: "Rainstaller.cfg", data: lgUTF8("[Rainstaller]\n")),
                                           .init(name: "Skins/A/A.ini", data: lgUTF8("[Rainmeter]\n")),
                                           .init(name: "Skins\\..\\..\\x.ini", data: lgUTF8("x"))], "rs.rmskin")
        lgExpect(t, "backslash zip-slip in a legacy package", lgIsExtractionFailed) {
            _ = try RmskinPackage.inspect(rainstallerSlip)
        }
        // A hand-made ZIP with Windows separators still installs.
        let windows = try archive([.init(name: "Pack\\Clock\\Clock.ini", data: lgUTF8("[Rainmeter]\n")),
                                   .init(name: "Pack\\@Resources\\v.inc", data: lgUTF8("[Variables]\n"))], "win.zip")
        let inspection = try RmskinPackage.inspect(windows)
        t.equal(inspection.rootConfigs, ["Pack"])
        t.equal(inspection.manifest.load, "Pack\\Clock\\Clock.ini")
        inspection.cleanup()
        t.equal(lgTemporaryItems(), before)
    }
}

// MARK: - TestSkins/Installer fixtures

private func legacyFixtureTests(_ t: TestRunner) {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TestSkins/Installer")
    guard FileManager.default.fileExists(atPath: fixtures.path) else { return }
    t.suite("RmskinLegacy: TestSkins/Installer sample folders") {
        let dir = t.temporaryDirectory("legacy-fixtures")
        defer { RmskinFiles.forceRemove(dir) }
        let skins = dir.appendingPathComponent("Skins"), layouts = dir.appendingPathComponent("Layouts")
        let orbit = try RmskinInstaller.install(packageURL: fixtures.appendingPathComponent("Legacy Orbit"),
                                                skinsDirectory: skins, layoutsDirectory: layouts)
        t.equal(orbit.manifest.packageFormat, .rainstaller)
        t.equal(orbit.manifest.keepsAllVariables, true)
        t.equal(orbit.installedRootConfigs, ["Orbit"])
        t.equal(orbit.installedLayouts, ["Orbit Desk"])
        t.equal(orbit.skinToLoadConfig, "Orbit\\Clock")
        t.equal(orbit.skinToLoadFile, "Clock.ini")
        t.equal(lgText(layouts.appendingPathComponent("Orbit Desk/Rainmeter.ini"))?.contains("SkinPath"), false)

        let pebble = try RmskinInstaller.install(packageURL: fixtures.appendingPathComponent("Plain Pebble"),
                                                 skinsDirectory: skins)
        t.equal(pebble.manifest.packageFormat, .plain)
        t.equal(pebble.installedRootConfigs, ["Pebble"], "#SKINSPATH#Pebble\\ unwraps the version folder")
        t.equal(pebble.skinToLoadConfig, "Pebble\\Gauge")
        t.check(lgExists(skins.appendingPathComponent("Pebble/Images/dot.png")))
    }
}

// MARK: - Review regressions

/// Makes the central directory of a hand-made ZIP declare `size` uncompressed bytes for every entry (nothing is
/// decompressed: archives that are refused early never reach ditto).
private func lgDeclaringSize(_ zip: Data, _ size: UInt32) -> Data {
    var bytes = [UInt8](zip)
    var i = 0
    while i + 46 <= bytes.count {
        guard bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x01, bytes[i + 3] == 0x02 else {
            i += 1
            continue
        }
        for k in 0..<4 { bytes[i + 24 + k] = UInt8((size >> (8 * UInt32(k))) & 0xFF) }
        i += 46
    }
    return Data(bytes)
}

private func legacyReviewTests(_ t: TestRunner) {
    t.suite("RmskinLegacy: kept variables never keep an old @Include") {
        // @Include is an option ("may be placed in any section"), not a variable: an old value can name a file the
        // new version no longer ships, which would leave the upgraded skin without its variables.
        let merged = RmskinIniText.preservingValues(
            from: "[Variables]\n@Include=#@#Old.inc\n@includeColors=#@#A.inc\nColor=9\n",
            into: "[Variables]\n@Include=#@#New.inc\n@IncludeColors=#@#B.inc\nColor=2\n")
        t.equal(merged.text, "[Variables]\n@Include=#@#New.inc\n@IncludeColors=#@#B.inc\nColor=9\n")
        t.equal(merged.preserved, 1)

        let dir = t.temporaryDirectory("legacy-include")
        defer { RmskinFiles.forceRemove(dir) }
        let skins = dir.appendingPathComponent("Skins"), backups = dir.appendingPathComponent("Backups")
        func package(_ include: String, _ color: String) throws -> URL {
            try lgArchive([("Rainstaller.cfg", lgUTF8("[Rainstaller]\nName=S\nKeepVar=1\n")),
                           ("Skins/S/C/C.ini", lgUTF8("[Variables]\n@Include=#@#\(include)\nColor=\(color)\n")),
                           ("Skins/S/@Resources/\(include)", lgUTF8("[Variables]\nX=1\n"))],
                          in: dir, name: "\(UUID().uuidString).zip")
        }
        _ = try RmskinInstaller.install(packageURL: try package("Old.inc", "1"), skinsDirectory: skins,
                                        backupDirectory: backups)
        try lgUTF8("[Variables]\n@Include=#@#Old.inc\nColor=9\n").write(to: skins.appendingPathComponent("S/C/C.ini"))
        let r = try RmskinInstaller.install(packageURL: try package("New.inc", "2"), skinsDirectory: skins,
                                            backupDirectory: backups)
        t.equal(lgText(skins.appendingPathComponent("S/C/C.ini")), "[Variables]\n@Include=#@#New.inc\nColor=9\n")
        t.equal(r.preservedVariableCount, 1)
    }

    t.suite("RmskinLegacy: Windows desktop.ini and Thumbs.db are not skins") {
        let dir = t.temporaryDirectory("legacy-desktopini")
        defer { RmskinFiles.forceRemove(dir) }
        let shell = lgUTF8("[.ShellClassInfo]\r\nIconResource=C:\\x.ico,0\r\n")
        let package = try lgArchive([
            ("desktop.ini", shell),
            ("Suite/desktop.ini", shell),
            ("Suite/Clock/Clock.ini", lgUTF8("[Rainmeter]\n")),
            ("Suite/Clock/Thumbs.db", Data([0xD0, 0xCF])),
            ("Suite/@Resources/v.inc", lgUTF8("[Variables]\n")),
        ], in: dir, name: "Pack.zip")
        let inspection = try RmskinPackage.inspect(package)
        t.equal(inspection.rootConfigs, ["Suite"], "a desktop.ini at the top does not make the archive a root config")
        t.equal(inspection.manifest.load, "Suite\\Clock\\Clock.ini", "the only real skin is loaded")
        let skins = dir.appendingPathComponent("Skins")
        _ = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        inspection.cleanup()
        t.check(!lgExists(skins.appendingPathComponent("Suite/desktop.ini")))
        t.check(!lgExists(skins.appendingPathComponent("Suite/Clock/Thumbs.db")))
        t.check(lgExists(skins.appendingPathComponent("Suite/Clock/Clock.ini")))

        let before = lgTemporaryItems()
        let photos = try lgArchive([("Photos/desktop.ini", shell), ("Photos/a.jpg", Data([0xFF, 0xD8]))], in: dir,
                                   name: "Photos.zip")
        lgExpect(t, "a folder with only desktop.ini", { $0 == .nothingToInstall }) {
            _ = try RmskinPackage.inspect(photos)
        }
        let folder = dir.appendingPathComponent("Pictures")
        try lgWriteTree([("desktop.ini", shell), ("a.png", Data([0x89]))], at: folder)
        lgExpect(t, "a folder with only desktop.ini", { $0 == .nothingToInstall }) {
            _ = try RmskinPackage.inspect(folder: folder)
        }
        t.equal(lgTemporaryItems(), before)
    }

    t.suite("RmskinLegacy: fonts loose next to the skins") {
        // Packager-made packages sometimes ship the font beside the .ini files (Windows users installed it by hand).
        let dir = t.temporaryDirectory("legacy-loosefonts")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try lgArchive([
            ("RMSKIN.ini", lgUTF8("[rmskin]\nName=Tick\n")),
            ("Skins/Tick/Tick.ini", lgUTF8("[Rainmeter]\n")),
            ("Skins/Tick/Tick Sans.ttf", fakeFont),
            ("Skins/Tick/Clock/Deep.otf", fakeFont),
            ("Skins/Tick/@Resources/Fonts/Own.otf", fakeFont),
        ], in: dir, name: "tick.rmskin", footer: true)
        let inspection = try RmskinPackage.inspect(package)
        t.equal(inspection.fontNames, ["Tick Sans.ttf"], "only the top of the root config; @Resources/Fonts is loaded anyway")
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        inspection.cleanup()
        t.equal(result.installedFonts, ["Tick Sans.ttf"])
        t.check(lgExists(skins.appendingPathComponent("Tick/@Resources/Fonts/Tick Sans.ttf")))
        t.check(lgExists(skins.appendingPathComponent("Tick/Tick Sans.ttf")), "the original stays")

        let tiny = try RmskinPackage.inspect(try lgArchive([("Clock.ini", lgUTF8("[Rainmeter]\n")), ("Dial.ttf", fakeFont)],
                                                           in: dir, name: "Tiny.zip"))
        defer { tiny.cleanup() }
        t.equal(tiny.rootConfigFonts["Tiny"]?.map(\.lastPathComponent), ["Dial.ttf"], "an archive that is one root config")
    }

    t.suite("RmskinLegacy: a ZIP wrapping one .rmskin") {
        let dir = t.temporaryDirectory("legacy-wrapped-rmskin")
        defer { RmskinFiles.forceRemove(dir) }
        func rmskin(_ name: String) throws -> Data {
            try Data(contentsOf: try lgArchive([
                ("RMSKIN.ini", lgUTF8("[rmskin]\nName=\(name)\nLoadType=Skin\nLoad=\(name)\\Main.ini\n")),
                ("Skins/\(name)/Main.ini", lgUTF8("[Rainmeter]\n")),
            ], in: dir, name: "\(name).rmskin", footer: true))
        }
        let before = lgTemporaryItems()
        let download = try lgArchive([("Inner 1.0/Inner_1.0.rmskin", try rmskin("Inner")),
                                      ("Inner 1.0/Read me.txt", lgUTF8("Double-click the .rmskin")),
                                      ("preview.png", Data([0x89]))], in: dir, name: "inner_1_0_by_someone.zip")
        let inspection = try RmskinPackage.inspect(download)
        t.equal(inspection.manifest.packageFormat, .rmskin)
        t.equal(inspection.manifest.name, "Inner")
        t.equal(inspection.rootConfigs, ["Inner"])
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        inspection.cleanup()
        t.equal(result.skinToLoadConfig, "Inner")
        t.equal(result.skinToLoadFile, "Main.ini")
        t.equal(lgTemporaryItems(), before, "both temporary folders are removed")

        let two = try lgArchive([("A.rmskin", try rmskin("A")), ("B.rmskin", try rmskin("B"))], in: dir, name: "two.zip")
        lgExpect(t, "two packages", { $0 == .severalPackages(["A.rmskin", "B.rmskin"]) }) {
            _ = try RmskinPackage.inspect(two)
        }
        // Only one level: a wrapper inside a wrapper is not opened.
        let middle = try Data(contentsOf: try lgArchive([("Inner.rmskin", try rmskin("Inner"))], in: dir, name: "m.zip"))
        let nested = try lgArchive([("middle.rmskin", middle)], in: dir, name: "nested.zip")
        lgExpect(t, "a wrapper in a wrapper", { $0 == .nothingToInstall }) { _ = try RmskinPackage.inspect(nested) }
        // A wrapping archive declaring more than 512 MB is refused before anything is extracted.
        let big = dir.appendingPathComponent("big.zip")
        try lgDeclaringSize(LegacyZip.make([.init(name: "big.rmskin", data: lgUTF8("x"))]), 600 << 20).write(to: big)
        lgExpect(t, "a huge wrapping archive", { $0 == .nothingToInstall }) { _ = try RmskinPackage.inspect(big) }

        // Folders: a download folder holding the package.
        let folder = dir.appendingPathComponent("Downloads/Inner 1.0")
        try lgWriteTree([("Inner.rmskin", try rmskin("Inner")), ("Read me.txt", lgUTF8("x"))], at: folder)
        let fromFolder = try RmskinPackage.inspect(folder)
        t.equal(fromFolder.rootConfigs, ["Inner"])
        t.equal(fromFolder.sourceFolder, nil, "the package, not the folder, is installed")
        fromFolder.cleanup()
        try rmskin("Other").write(to: folder.appendingPathComponent("Other.rmskin"))
        lgExpect(t, "a folder of packages", { $0 == .severalPackages(["Inner.rmskin", "Other.rmskin"]) }) {
            _ = try RmskinPackage.inspect(folder: folder)
        }
        t.equal(lgTemporaryItems(), before)
        t.check(RmskinError.severalPackages(["A.rmskin", "B.rmskin"]).description.contains("A.rmskin, B.rmskin"))
    }

    t.suite("RmskinLegacy: manifest in a wrapper folder beside a read-me") {
        let dir = t.temporaryDirectory("legacy-wrapper-readme")
        defer { RmskinFiles.forceRemove(dir) }
        let modern = try RmskinPackage.inspect(try lgArchive([
            ("Suite 2.0/RMSKIN.ini", lgUTF8("[rmskin]\nName=Suite\nVariableFiles=Suite\\@Resources\\Vars.inc\n")),
            ("Suite 2.0/Skins/Suite/Clock/Clock.ini", lgUTF8("[Rainmeter]\n")),
            ("Suite 2.0/Skins/Suite/@Resources/Vars.inc", lgUTF8("[Variables]\nA=1\n")),
            ("Read me first.txt", lgUTF8("x")),
        ], in: dir, name: "suite.zip"))
        defer { modern.cleanup() }
        t.equal(modern.manifest.packageFormat, .rmskin, "the manifest's VariableFiles are not lost")
        t.equal(modern.manifest.variableFiles, ["Suite\\@Resources\\Vars.inc"])
        let legacy = try RmskinPackage.inspect(try lgArchive([
            ("Kit/Rainstaller.cfg", lgUTF8("[Rainstaller]\nName=Kit\nMerge=1\n")),
            ("Kit/Skins/Kit/Kit.ini", lgUTF8("[Rainmeter]\n")),
            ("Screenshot.png", Data([0x89])),
        ], in: dir, name: "kit.zip"))
        defer { legacy.cleanup() }
        t.equal(legacy.manifest.packageFormat, .rainstaller)
        t.equal(legacy.manifest.mergeSkins, true)
    }

    t.suite("RmskinLegacy: bracketed launch bangs") {
        func launch(_ type: String, _ command: String) -> [String] {
            let r = RmskinManifest.rainstallerLaunch(type: type, command: command)
            return [r.type, r.load]
        }
        t.equal(launch("", "[!ActivateConfig \"Suite\\Clock\" \"Clock.ini\"]"), ["Skin", "Suite\\Clock\\Clock.ini"])
        t.equal(launch("", "[!RainmeterLoadTheme \"Big Desk\"][!Refresh]"), ["Layout", "Big Desk"], "first bang")
        t.equal(launch("Load", "[\"https://example.com\"]")[0], "Load", "not a bang: left for the installer to report")
    }

    t.suite("RmskinLegacy: a chosen folder is the root config") {
        // A root config without @Resources whose skins sit in config folders (common in old skins): choosing the
        // folder installs it under its own name, as moving it into Skins would.
        let dir = t.temporaryDirectory("legacy-folder-root")
        defer { RmskinFiles.forceRemove(dir) }
        let folder = dir.appendingPathComponent("Tiny Drives")
        try lgWriteTree([("Drive C/Drive C.ini", lgUTF8("[Rainmeter]\n")), ("Drive C/c.png", Data([0x89])),
                         ("Drive D/Drive D.ini", lgUTF8("[Rainmeter]\n"))], at: folder)
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(packageURL: folder, skinsDirectory: skins)
        t.equal(result.installedRootConfigs, ["Tiny Drives"])
        t.check(lgExists(skins.appendingPathComponent("Tiny Drives/Drive C/Drive C.ini")))
        t.equal(result.skinToLoadConfig, nil, "two skins: nothing is loaded")

        // A folder holding a Skins folder (an extracted package without manifest) is named after itself.
        let extracted = dir.appendingPathComponent("Kit 3")
        try lgWriteTree([("Skins/Kit/Kit.ini", lgUTF8("[Rainmeter]\n")), ("Fonts/K.ttf", fakeFont)], at: extracted)
        let kit = try RmskinPackage.inspect(folder: extracted)
        defer { kit.cleanup() }
        t.equal(kit.manifest.name, "Kit 3")
        t.equal(kit.rootConfigs, ["Kit"])
        t.equal(kit.fontNames, ["K.ttf"])
    }
}
