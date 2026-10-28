import Foundation
@testable import DesksetCore

// Skin Packager (`RmskinPackager`): checking a package, writing it, and installing what it wrote.

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// A Windows bitmap of `width`×`height` (24-bit, no pixels needed for the header check).
private func bmp(_ width: Int, _ height: Int) -> Data {
    func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    let pixels = ((24 * width + 31) / 32) * 4 * height
    var bytes: [UInt8] = [0x42, 0x4D]
    for v in [54 + pixels, 0, 54, 40, width, height] { bytes += le32(v) }
    bytes += [1, 0, 24, 0]
    for v in [0, pixels, 2835, 2835, 0, 0] { bytes += le32(v) }
    return Data(bytes) + Data(count: pixels)
}

/// The start of a Windows DLL with the PE machine type `machine` (0x14C x86, 0x8664 x64).
private func dll(_ machine: UInt16) -> Data {
    var bytes = [UInt8](repeating: 0, count: 0x48)
    bytes[0] = 0x4D; bytes[1] = 0x5A
    bytes[0x3C] = 0x40
    bytes[0x40] = 0x50; bytes[0x41] = 0x45
    bytes[0x44] = UInt8(machine & 0xFF); bytes[0x45] = UInt8(machine >> 8)
    return Data(bytes)
}

/// The general purpose flags of each ZIP entry by name: from its central directory record and its local header.
private func zipFlags(_ data: Data) -> [String: (central: UInt16, local: UInt16)] {
    let b = [UInt8](data)
    func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    var result: [String: (UInt16, UInt16)] = [:]
    var o = 0
    while o + 46 <= b.count {
        if u32(o) == 0x0201_4B50 {
            let nameLength = u16(o + 28)
            let name = String(decoding: b[(o + 46)..<(o + 46 + nameLength)], as: UTF8.self)
            let local = u32(o + 42)
            result[name] = (UInt16(u16(o + 8)), UInt16(u16(local + 6)))
            o += 46 + nameLength
        } else {
            o += 1
        }
    }
    return result
}

func runRmskinPackagerTests(_ t: TestRunner) {
    t.suite("Skin Packager: a package installs what was chosen and leaves hidden files out") {
        let dir = t.temporaryDirectory("packager")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let root = dir.appendingPathComponent("Source/Clockwork")
        try write("[Rainmeter]\n[M]\nMeter=String\nText=Hi\n", to: root.appendingPathComponent("Digital/Digital.ini"))
        try write("[Variables]\nColor=255,0,0\n", to: root.appendingPathComponent("Digital/Variables.inc"))
        try write("[Rainmeter]\n", to: root.appendingPathComponent("Cafe\u{301}/Cafe\u{301}.ini"))
        try write("font", to: root.appendingPathComponent("@Resources/Fonts/Face.ttf"))
        try write("[Rainmeter]\n", to: root.appendingPathComponent("@Resources/NotASkin.ini"))
        try write("psd", to: root.appendingPathComponent(".work/Design.psd"))
        try write("x", to: root.appendingPathComponent(".DS_Store"))
        try write("x", to: root.appendingPathComponent("Digital/Thumbs.db"))
        var finderHidden = root.appendingPathComponent("Digital/Backup.ini")
        try write("[Rainmeter]\n", to: finderHidden)
        var values = URLResourceValues()
        values.isHidden = true
        try finderHidden.setResourceValues(values)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: dir)

        let layout = dir.appendingPathComponent("Layouts/Clockwork Desk")
        try write("[Rainmeter]\n[Clockwork\\Digital]\nActive=1\n", to: layout.appendingPathComponent("Rainmeter.ini"))
        let plugins = dir.appendingPathComponent("Plugins")
        try fm.createDirectory(at: plugins.appendingPathComponent("32bit"), withIntermediateDirectories: true)
        try fm.createDirectory(at: plugins.appendingPathComponent("64bit"), withIntermediateDirectories: true)
        try dll(0x14C).write(to: plugins.appendingPathComponent("32bit/Glow.dll"))
        try dll(0x8664).write(to: plugins.appendingPathComponent("64bit/Glow.dll"))
        let header = dir.appendingPathComponent("Header.bmp")
        try bmp(400, 60).write(to: header)
        let output = dir.appendingPathComponent("Out")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)

        t.equal(RmskinPackager.skinFiles(inRootConfig: root),
                ["Clockwork\\Café\\Café.ini", "Clockwork\\Digital\\Digital.ini"],
                "skins to load: no @Resources, hidden or linked files, names in form C")

        var spec = RmskinPackageSpec()
        spec.name = "Clockwork"
        spec.author = "Someone"
        spec.version = "1.2"
        spec.rootConfig = root
        spec.layouts = [layout]
        spec.plugins = [RmskinPackager.plugin(choosing: plugins.appendingPathComponent("64bit/Glow.dll"))]
        spec.load = .skin("Clockwork\\Digital\\Digital.ini")
        spec.headerImage = header
        spec.variableFiles = ["clockwork\\digital\\variables.inc"]
        spec.outputDirectory = output
        t.equal(RmskinPackager.problems(spec), [])
        let result = try RmskinPackager.build(spec)
        t.equal(result.url.lastPathComponent, "Clockwork_1.2.rmskin")
        t.equal(result.skippedLinks, ["Skins/Clockwork/Linked"], "links are left out and reported")

        let data = try Data(contentsOf: result.url)
        t.check(RmskinPackage.hasFooter(data), "the Skin Installer's footer")
        let inspection = try RmskinPackage.inspect(result.url)
        defer { inspection.cleanup() }
        t.equal(inspection.manifest.name, "Clockwork")
        t.equal(inspection.manifest.author, "Someone")
        t.equal(inspection.manifest.version, "1.2")
        t.equal(inspection.manifest.loadType, "Skin")
        t.equal(inspection.manifest.load, "Clockwork\\Digital\\Digital.ini")
        t.equal(inspection.manifest.variableFiles, ["clockwork\\digital\\variables.inc"])
        t.equal(inspection.manifest.minimumRainmeter, "5.0")
        t.check(!inspection.manifest.requiresNewerRainmeter)
        t.equal(inspection.rootConfigs, ["Clockwork"])
        t.equal(inspection.layouts, ["Clockwork Desk"])
        t.equal(inspection.pluginNames, ["Glow.dll"])
        t.check(inspection.headerImageURL != nil, "the header image")

        let packaged = inspection.packageRoot
        let manifestBytes = try Data(contentsOf: packaged.appendingPathComponent("RMSKIN.ini"))
        t.equal(Array(manifestBytes.prefix(2)), [0xFF, 0xFE], "RMSKIN.ini is UTF-16 LE with a BOM")
        t.check(String(data: manifestBytes.dropFirst(2), encoding: .utf16LittleEndian)?.contains("\r\nAuthor=Someone\r\n")
                ?? false, "with CRLF line ends")
        let skin = packaged.appendingPathComponent("Skins/Clockwork")
        let names = (fm.enumerator(atPath: skin.path)?.allObjects as? [String] ?? []).sorted()
        t.equal(names, ["@Resources", "@Resources/Fonts", "@Resources/Fonts/Face.ttf", "@Resources/NotASkin.ini",
                        "Café", "Café/Café.ini", "Digital", "Digital/Digital.ini", "Digital/Variables.inc"],
                "hidden files, Finder-hidden files and links are left out")
        // Swift's == treats both forms as equal: look at the bytes of the names stored in the ZIP.
        let nfc = Data("Café/Café.ini".utf8), nfd = Data("Cafe\u{301}/Cafe\u{301}.ini".utf8)
        t.check(data.range(of: nfc) != nil && data.range(of: nfd) == nil, "names are stored in Unicode form C")
        let flags = zipFlags(data)
        t.check(flags["Skins/Clockwork/Café/Café.ini"] != nil, "entries are named from the package root")
        t.check(!flags.isEmpty && flags.values.allSatisfy { $0.central & 0x0800 != 0 && $0.local & 0x0800 != 0 },
                "every entry carries the UTF-8 flag, in the directory and the local header")
        t.check(!fm.fileExists(atPath: packaged.appendingPathComponent("__MACOSX").path), "no Mac metadata folder")
        t.check(fm.fileExists(atPath: packaged.appendingPathComponent("Plugins/32bit/Glow.dll").path))
        t.check(fm.fileExists(atPath: packaged.appendingPathComponent("Plugins/64bit/Glow.dll").path))

        let skins = dir.appendingPathComponent("Installed/Skins")
        let layouts = dir.appendingPathComponent("Installed/Layouts")
        try fm.createDirectory(at: skins, withIntermediateDirectories: true)
        let installed = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins, layoutsDirectory: layouts)
        t.equal(installed.installedRootConfigs, ["Clockwork"])
        t.equal(installed.installedLayouts, ["Clockwork Desk"])
        t.check(fm.fileExists(atPath: skins.appendingPathComponent("Clockwork/Digital/Digital.ini").path),
                "Deskset's own installer installs the package")

        try write("old", to: result.url)
        spec.version = ""
        spec.load = .layout("Clockwork Desk")
        spec.variableFiles = []
        spec.mergeSkins = true
        let second = try RmskinPackager.build(spec)
        t.equal(second.url.lastPathComponent, "Clockwork.rmskin", "no version: Name.rmskin")
        let again = try RmskinPackage.inspect(second.url)
        defer { again.cleanup() }
        t.equal(again.manifest.loadType, "Layout")
        t.equal(again.manifest.load, "Clockwork Desk")
        t.check(again.manifest.mergeSkins)
    }

    t.suite("Skin Packager: what keeps a package from being made") {
        let dir = t.temporaryDirectory("packager-problems")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Suite")
        try write("[Rainmeter]\n", to: root.appendingPathComponent("Main/Main.ini"))
        let empty = dir.appendingPathComponent("Empty")
        try write("x", to: empty.appendingPathComponent("readme.txt"))
        let layout = dir.appendingPathComponent("NoSettings")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        let small = dir.appendingPathComponent("Small.bmp")
        try bmp(200, 60).write(to: small)
        let png = dir.appendingPathComponent("Header.png")
        try write("not a bitmap", to: png)
        let lone = dir.appendingPathComponent("Lone.dll")
        try dll(0x8664).write(to: lone)

        var spec = RmskinPackageSpec()
        spec.name = "  "
        spec.minimumRainmeter = "5.0 beta"
        t.equal(RmskinPackager.problems(spec), [.nameMissing, .authorMissing, .skinMissing,
                                                .minimumVersionInvalid("5.0 beta"), .outputMissing])
        spec.name = "Suite"
        spec.author = "A"
        spec.rootConfig = empty
        spec.outputDirectory = dir
        spec.minimumRainmeter = "5"
        t.equal(RmskinPackager.problems(spec), [.skinWithoutSkins("Empty")], "a root config needs a skin")
        spec.rootConfig = root
        spec.layouts = [layout]
        spec.plugins = [RmskinPackager.plugin(choosing: lone)]
        spec.load = .layout("Elsewhere")
        spec.headerImage = small
        spec.variableFiles = ["Suite\\Main\\Missing.inc", "Other\\Main\\Main.ini"]
        spec.mergeSkins = true
        t.equal(RmskinPackager.problems(spec), [
            .layoutWithoutSettings("NoSettings"), .pluginIncomplete("Lone.dll"), .loadLayoutNotIncluded("Elsewhere"),
            .headerWrongSize(width: 200, height: 60), .variableFileNotFound("Suite\\Main\\Missing.inc"),
            .variableFileNotFound("Other\\Main\\Main.ini"), .mergeWithVariableFiles,
        ])
        spec.layouts = []
        spec.plugins = []
        spec.load = .skin("Suite\\Main\\Gone.ini")
        spec.headerImage = png
        spec.variableFiles = ["Suite\\Main\\Main.ini"]
        spec.mergeSkins = false
        spec.minimumRainmeter = "5.0.0.4657"
        t.equal(RmskinPackager.problems(spec), [.loadSkinNotFound("Suite\\Main\\Gone.ini"), .headerNotBitmap])
        t.check({ do { try RmskinPackager.build(spec); return false } catch RmskinPackagerError.invalid { return true }
                  catch { return false } }(), "build refuses an unready package")
        t.check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Suite.rmskin").path))
    }

    t.suite("Skin Packager: plugins, file names and RMSKIN.ini") {
        let dir = t.temporaryDirectory("packager-plugins")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for folder in ["Vault/Glow/1.0/32bit", "Vault/Glow/1.0/64bit", "Other/x86", "Other/x64", "Flat"] {
            try fm.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try dll(0x14C).write(to: dir.appendingPathComponent("Vault/Glow/1.0/32bit/Glow.dll"))
        try dll(0x8664).write(to: dir.appendingPathComponent("Vault/Glow/1.0/64bit/Glow.dll"))
        try dll(0x8664).write(to: dir.appendingPathComponent("Other/x64/Spin.dll"))
        try dll(0x14C).write(to: dir.appendingPathComponent("Other/x86/spin.DLL"))
        try dll(0x14C).write(to: dir.appendingPathComponent("Flat/Solo.dll"))
        try write("not a dll", to: dir.appendingPathComponent("Flat/Text.dll"))

        t.equal(RmskinPackager.windowsArchitecture(of: dir.appendingPathComponent("Vault/Glow/1.0/32bit/Glow.dll")), .x86)
        t.equal(RmskinPackager.windowsArchitecture(of: dir.appendingPathComponent("Vault/Glow/1.0/64bit/Glow.dll")), .x64)
        t.equal(RmskinPackager.windowsArchitecture(of: dir.appendingPathComponent("Flat/Text.dll")), nil)
        let glow = RmskinPackager.plugin(choosing: dir.appendingPathComponent("Vault/Glow/1.0/32bit/Glow.dll"))
        t.equal(glow.x64?.resolvingSymlinksInPath().path,
                dir.appendingPathComponent("Vault/Glow/1.0/64bit/Glow.dll").resolvingSymlinksInPath().path,
                "the other version is found by swapping 32bit and 64bit")
        let spin = RmskinPackager.plugin(choosing: dir.appendingPathComponent("Other/x64/Spin.dll"))
        t.equal(spin.x86?.lastPathComponent, "spin.DLL", "or x86 and x64, ignoring case")
        let solo = RmskinPackager.plugin(choosing: dir.appendingPathComponent("Flat/Solo.dll"))
        t.check(solo.x86 != nil && solo.x64 == nil, "a lone 32-bit DLL")
        t.equal(solo.fileName, "Solo.dll")

        var spec = RmskinPackageSpec()
        spec.name = "My: Skin/Pack"
        spec.author = "Me\nYou"
        spec.version = "2.0?"
        t.equal(RmskinPackager.fileName(for: spec), "My- Skin-Pack_2.0-.rmskin", "unsafe characters become -")
        spec.name = "..."
        spec.version = ""
        t.equal(RmskinPackager.fileName(for: spec), "Package.rmskin")
        spec.name = "Suite"
        spec.load = .skin("Suite\\Main\\Main.ini")
        spec.variableFiles = ["Suite\\A.inc", "Suite\\B.inc"]
        spec.minimumRainmeter = "5.0.0.4657"
        t.equal(RmskinPackager.manifestText(spec), "[rmskin]\r\nName=Suite\r\nAuthor=Me You\r\nVersion=\r\n"
                + "LoadType=Skin\r\nLoad=Suite\\Main\\Main.ini\r\nVariableFiles=Suite\\A.inc | Suite\\B.inc\r\n"
                + "MinimumRainmeter=5.0.0.4657\r\n", "one line per value")
        t.equal(RmskinManifest.parse(RmskinPackager.manifestText(spec)).variableFiles, ["Suite\\A.inc", "Suite\\B.inc"],
                "the installer reads what the packager writes")
    }
}
