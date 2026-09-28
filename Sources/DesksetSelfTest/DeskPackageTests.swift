import Foundation
@testable import DeskLanguage

// Widget folders (the language specification §8.3, §8.4, §8.6, §4.13, §8.1): loading from disk and from memory,
// the limits, the manifest and widget entries, the folder checks, languages, options panels, the install summary,
// and the index from package names to their uses in every file.

let deskHarborFolder = deskFixtures.appendingPathComponent("Packages/Harbor")

/// Font families by file name, standing in for Core Text: `HarborSans.ttf` holds "Harbor Sans".
struct DeskFakeFontFiles: FontFileInspecting {
    func families(inFontData data: Data, fileName: String) -> [String]? {
        guard !data.isEmpty else { return nil }
        let stem = (fileName as NSString).deletingPathExtension
        var words = ""
        for c in stem {
            if c.isUppercase, !words.isEmpty { words += " " }
            words.append(c)
        }
        return [words]
    }
}

/// Every entry of a folder on disk, held in memory with the same paths (links and folders as they are).
func deskMemoryCopy(of folder: URL) -> InMemoryPackageSource {
    var source = InMemoryPackageSource()
    let fm = FileManager.default
    func visit(_ relative: String) {
        let absolute = relative.isEmpty ? folder.path : folder.appendingPathComponent(relative).path
        for name in (try? fm.contentsOfDirectory(atPath: absolute)) ?? [] {
            let path = relative.isEmpty ? name : relative + "/" + name
            let full = (absolute as NSString).appendingPathComponent(name)
            let type = (try? fm.attributesOfItem(atPath: full))?[.type] as? FileAttributeType
            switch type {
            case .typeDirectory?:
                source.add(path, .directory)
                visit(path)
            case .typeSymbolicLink?:
                source.add(path, .link((try? fm.destinationOfSymbolicLink(atPath: full)) ?? ""))
            default:
                source.add(path, .file((try? Data(contentsOf: URL(fileURLWithPath: full))) ?? Data()))
            }
        }
    }
    visit("")
    return source
}

func deskHarbor(fonts: FontFileInspecting? = DeskFakeFontFiles()) -> DeskPackage {
    (try? PackageLoader.load(folder: deskHarborFolder, fonts: fonts)) ?? DeskPackage()
}

/// Harbor checked with its own files as resources and Core Text standing in.
func deskCheckedHarbor() -> CheckedDeskPackage {
    CheckedDeskPackage(package: deskHarbor(), context: CheckContext(fonts: DeskFakeFonts()))
}

func deskFolderDescription(_ package: CheckedDeskPackage) -> [String] {
    package.allDiagnostics.map { "\($0.id.rawValue)@\($0.file.path)" }
}

/// The text a site covers.
func deskSiteText(_ site: DeskSite, in package: DeskPackage) -> String {
    guard let text = package.texts[site.file] else { return "" }
    let bytes = Array(text.utf8)
    guard site.range.upperBound <= bytes.count else { return "" }
    return String(decoding: bytes[site.range], as: UTF8.self)
}

/// A folder of `.desk` texts (and anything else) in memory, loaded.
func deskMemoryPackage(_ texts: [String: String], extra: [(String, InMemoryPackageSource.Item)] = [],
                       fonts: FontFileInspecting? = nil) -> DeskPackage {
    var source = InMemoryPackageSource(texts: texts)
    for (path, item) in extra { source.add(path, item) }
    return (try? PackageLoader.load(source, fonts: fonts)) ?? DeskPackage()
}

func runDeskPackageTests(_ t: TestRunner) {
    let tide = DeskFileID("Tide.desk"), lamp = DeskFileID("Lamp.desk"), radio = DeskFileID("Radio.desk")
    let packageID = DeskFileID("package.desk")

    t.suite("Desk: package — loading") {
        let package = deskHarbor()
        let kinds = package.files.map { "\($0.path) \($0.kind.rawValue)" }
        t.equal(kinds, ["Lamp.desk widget", "Radio.desk widget", "Tide.desk widget", "fonts/HarborSans.ttf font",
                        "images/buoy.gif image", "images/old.png image", "images/paper.jpg image", "images/waves.png image",
                        "notes.txt other", "package.desk package"])
        t.equal(package.file(at: "images/waves.png")?.pixelSize, DeskPixelSize(width: 8, height: 6), "PNG header")
        t.equal(package.file(at: "images/buoy.gif")?.pixelSize, DeskPixelSize(width: 5, height: 3), "GIF header")
        t.equal(package.file(at: "images/paper.jpg")?.pixelSize, DeskPixelSize(width: 12, height: 10), "JPEG header after Exif")
        t.equal(package.file(at: "fonts/HarborSans.ttf")?.fontFamilies, ["Harbor Sans"])
        t.equal(deskHarbor(fonts: nil).file(at: "fonts/HarborSans.ttf")?.fontFamilies, nil, "no families without the service")
        t.equal(package.widgetFiles, [lamp, radio, tide])
        t.equal(package.packageFile, packageID)
        t.equal(package.diagnostics.count, 0)
        for id in [lamp, radio, tide, packageID] {
            let disk = try Data(contentsOf: deskHarborFolder.appendingPathComponent(id.path))
            t.check(package.texts[id].map { Data($0.utf8) } == disk, "\(id.path) is the file's bytes")
        }
        // The same folder from memory gives the same model.
        let memory = try PackageLoader.load(deskMemoryCopy(of: deskHarborFolder), fonts: DeskFakeFontFiles())
        t.check(memory == package, "disk and memory models are equal")

        // Hidden files, .DS_Store and __MACOSX are listed as ignored and never read.
        let folder = t.temporaryDirectory("desk-package")
        let fm = FileManager.default
        for file in package.files {
            let target = folder.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: deskHarborFolder.appendingPathComponent(file.path), to: target)
        }
        try Data("junk".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        try fm.createDirectory(at: folder.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data("widget { Text(\"secret\") }".utf8).write(to: folder.appendingPathComponent(".hidden/Secret.desk"))
        try fm.createDirectory(at: folder.appendingPathComponent("__MACOSX/images"), withIntermediateDirectories: true)
        try Data([0, 5, 22, 7]).write(to: folder.appendingPathComponent("__MACOSX/._Tide.desk"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("images/.keep"))
        let withJunk = try PackageLoader.load(folder: folder, fonts: DeskFakeFontFiles())
        t.equal(withJunk.files(.ignored).map(\.path), [".DS_Store", ".hidden", "__MACOSX", "images/.keep"])
        t.equal(withJunk.files.filter { $0.kind != .ignored }, package.files, "the rest is the same")
        t.equal(withJunk.texts, package.texts, "nothing ignored is read")
        t.check(withJunk == (try PackageLoader.load(deskMemoryCopy(of: folder), fonts: DeskFakeFontFiles())), "equal from memory")

        // A byte order mark is kept; invalid UTF-8 is DK1008 and the file is not read.
        let bom = deskMemoryPackage(["A.desk": "\u{FEFF}info { name: \"A\" }\nwidget { Text(\"A\") }\n"])
        t.check(bom.texts[DeskFileID("A.desk")]?.hasPrefix("\u{FEFF}") == true, "BOM kept")
        t.equal(bom.widgets.first?.name, "A")
        let invalid = try PackageLoader.load(InMemoryPackageSource([("Bad.desk", .file(Data([0x77, 0xFF, 0x20]))),
                                                                     ("Good.desk", .file(Data("widget { Text(\"A\") }".utf8)))]))
        t.equal(invalid.diagnostics.map(\.id), [.invalidEncoding])
        t.equal(invalid.diagnostics.first?.file, DeskFileID("Bad.desk"))
        t.equal(invalid.texts.keys.map(\.path), ["Good.desk"])
        t.equal(invalid.files(.widget).count, 2, "the file is still a widget file")

        // A single .desk file.
        let single = try PackageLoader.load(deskFile: deskFixtures.appendingPathComponent("Acceptance/CPU.desk"))
        t.check(single.isSingleFile)
        t.equal(single.widgets.map(\.name), ["CPU"])
        t.equal(single, PackageLoader.load(deskData: try Data(contentsOf: deskFixtures.appendingPathComponent("Acceptance/CPU.desk")),
                                           fileName: "CPU.desk"))
        let singleChecked = CheckedDeskPackage(package: single)
        t.equal(deskFolderDescription(singleChecked), [], "a single clean widget")

        // Picture headers: truncated, wrong, progressive JPEG.
        let png = deskPNG(width: 300, height: 200)
        t.equal(ImageHeader.pixelSize(png), DeskPixelSize(width: 300, height: 200))
        t.equal(ImageHeader.pixelSize(png.prefix(20)), nil, "truncated")
        t.equal(ImageHeader.pixelSize(Data("not a picture".utf8)), nil)
        let progressive = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC2, 0x00, 0x0B, 0x08, 0x01, 0x2C, 0x02, 0x58, 0x03,
                                0x01, 0x11, 0x00])
        t.equal(ImageHeader.pixelSize(progressive), DeskPixelSize(width: 600, height: 300), "SOF2")
        t.equal(ImageHeader.pixelSize(Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02])), nil, "scan before a frame")
        t.equal(ImageHeader.pixelSize(Data("GIF89a".utf8) + Data([0x10, 0x00, 0x20, 0x00])), DeskPixelSize(width: 16, height: 32))
    }

    t.suite("Desk: package — limits") {
        let widget = "info { name: \"Notes\" }\nwidget { Text(\"A\") }\n"
        // 2,001 files: DK8607, listing stops, nothing crashes; 2,000 are fine.
        var many = InMemoryPackageSource(texts: ["Notes.desk": widget])
        for i in 1...1_999 { many.add(String(format: "notes/n%04d.txt", i), text: "\(i)") }
        let atLimit = try PackageLoader.load(many)
        t.equal(atLimit.diagnostics.map(\.id), [], "2,000 files")
        t.check(!atLimit.isTruncated)
        many.add("notes/n2000.txt", text: "2000")
        let over = try PackageLoader.load(many)
        t.equal(over.diagnostics.map(\.id), [.tooManyFiles])
        t.equal(over.diagnostics.first?.file, DeskPackage.folderFile)
        t.check(over.isTruncated)
        t.equal(over.files.count, 2_000)
        t.equal(over.widgets.map(\.name), ["Notes"], "the widget is still read")
        let overChecked = CheckedDeskPackage(package: over)
        t.equal(deskFolderDescription(overChecked), ["DK8607@"], "no folder check guesses about a partial folder")

        // More than 100 MiB, and a .desk over 1 MiB (not read).
        let large = deskMemoryPackage(["Clip.desk": widget, "Big.desk": String(repeating: "// padding\n", count: 100_000)],
                                      extra: [("clip.mov", .file(Data(count: 101 * 1_048_576)))])
        t.equal(Set(large.diagnostics.map(\.id)), [.folderTooLarge, .fileTooLarge])
        t.equal(large.diagnostics.first { $0.id == .fileTooLarge }?.file, DeskFileID("Big.desk"))
        t.equal(large.texts.keys.map(\.path), ["Clip.desk"])
        t.equal(large.diagnostics.first { $0.id == .folderTooLarge }?.message(in: .english),
                "The files in this folder add up to more than 100 MiB.")

        // Names that differ only by case, or only by Unicode normalization: the first is read, the other shadowed.
        let clash = deskMemoryPackage(["Clock.desk": "info { name: \"Clock\" }\nwidget { Text(\"A\") }\n",
                                       "clock.desk": "info { name: \"Other\" }\nwidget { Text(\"B\") }\n"])
        t.equal(clash.diagnostics.map { "\($0.id.rawValue) \($0.file.path)" }, ["DK8602 clock.desk"])
        t.equal(clash.texts.keys.map(\.path), ["Clock.desk"])
        t.equal(clash.files.filter(\.isShadowed).map(\.path), ["clock.desk"])
        t.check(clash.diagnostics.first?.message(in: .english).contains("upper and lower case") == true)
        t.equal(clash.diagnostics.first?.notes.first?.file, DeskFileID("Clock.desk"))
        let nfc = "Caf\u{E9}.desk", nfd = "Cafe\u{301}.desk"
        let normalization = try PackageLoader.load(InMemoryPackageSource([(nfc, .file(Data("widget { Text(\"A\") }".utf8))),
                                                                           (nfd, .file(Data("widget { Text(\"B\") }".utf8)))]))
        t.equal(normalization.files.count, 2, "both names are listed")
        t.equal(normalization.texts.count, 1, "one is read")
        t.equal(normalization.diagnostics.map(\.id), [.fileNameClash])
        t.check(normalization.diagnostics.first?.message(in: .simplifiedChinese).contains("带重音字母的存储方式") == true)
        t.check(CheckedDeskPackage(package: normalization).allDiagnostics.contains { $0.id == .fileNameClash }, "no crash")

        // Paths that leave the folder never enter the model.
        let slip = deskMemoryPackage(["A.desk": widget], extra: [("../outside.png", .file(deskPNG(width: 1, height: 1)))])
        t.equal(slip.diagnostics.map { "\($0.id.rawValue) \($0.file.path)" }, ["DK4030 ../outside.png"])
        t.check(!slip.files.contains { $0.path.contains("..") })

        // On disk: links are reported and never followed; a linked folder is not entered.
        let folder = t.temporaryDirectory("desk-links")
        let outside = t.temporaryDirectory("desk-outside")
        let fm = FileManager.default
        try Data("OUTSIDE-SECRET widget { Text(\"x\") }".utf8).write(to: outside.appendingPathComponent("Secret.desk"))
        try Data(widget.utf8).write(to: folder.appendingPathComponent("Notes.desk"))
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("Linked.desk").path,
                                  withDestinationPath: outside.appendingPathComponent("Secret.desk").path)
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("Again.desk").path, withDestinationPath: "Notes.desk")
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("more").path, withDestinationPath: outside.path)
        let linked = try PackageLoader.load(folder: folder)
        t.equal(linked.diagnostics.map { "\($0.id.rawValue) \($0.file.path)" },
                ["DK8606 Again.desk", "DK8606 Linked.desk", "DK8606 more"])
        t.check(!linked.texts.values.contains { $0.contains("OUTSIDE-SECRET") }, "never read through a link")
        t.equal(linked.texts.keys.map(\.path), ["Notes.desk"])
        t.check(!linked.files.contains { $0.path.hasPrefix("more/") }, "a linked folder is not entered")
        t.check(linked.diagnostics.first { $0.file.path == "Linked.desk" }?.message(in: .english).contains("outside the folder") == true)
        t.check(linked.diagnostics.first { $0.file.path == "Again.desk" }?.message(in: .english).contains("another file in the folder") == true)
        t.equal(linked, try PackageLoader.load(deskMemoryCopy(of: folder)), "links alike from memory")
        t.check(CheckedDeskPackage(package: linked).allDiagnostics.filter { $0.id == .fileLink }.count == 3, "no crash")
        // Reading through a link is refused even when asked directly.
        t.check((try? LocalPackageSource(root: folder).read("Linked.desk", limit: 100)) == nil, "O_NOFOLLOW")

        // On disk: 2,001 files.
        let crowded = t.temporaryDirectory("desk-crowded")
        try Data(widget.utf8).write(to: crowded.appendingPathComponent("Notes.desk"))
        try fm.createDirectory(at: crowded.appendingPathComponent("notes"), withIntermediateDirectories: true)
        for i in 1...2_001 { try Data("\(i)".utf8).write(to: crowded.appendingPathComponent(String(format: "notes/n%04d.txt", i))) }
        let crowdedPackage = try PackageLoader.load(folder: crowded)
        t.equal(crowdedPackage.diagnostics.map(\.id), [.tooManyFiles])
        t.equal(crowdedPackage, try PackageLoader.load(deskMemoryCopy(of: crowded)), "the same files are listed from memory")
        try? fm.removeItem(at: crowded)

        // A case clash on disk, when this volume keeps both names.
        let caseFolder = t.temporaryDirectory("desk-case")
        try Data(widget.utf8).write(to: caseFolder.appendingPathComponent("Notes.desk"))
        try Data(widget.utf8).write(to: caseFolder.appendingPathComponent("notes.desk"))
        if (try fm.contentsOfDirectory(atPath: caseFolder.path)).count == 2 {
            t.equal(try PackageLoader.load(folder: caseFolder).diagnostics.map(\.id), [.fileNameClash])
        }

        // An archive's entry list, before unpacking.
        func ids(_ entries: [DeskArchiveEntry]) -> [String] { PackageLoader.checkArchive(entries).map { "\($0.id.rawValue) \($0.file.path)" } }
        t.equal(ids([DeskArchiveEntry(path: "Tide.desk", size: 10), DeskArchiveEntry(path: "images/", size: 0, isDirectory: true),
                     DeskArchiveEntry(path: "__MACOSX/._Tide.desk", size: 4)]), [])
        t.equal(ids([DeskArchiveEntry(path: "../evil.sh", size: 1), DeskArchiveEntry(path: "/etc/x", size: 1),
                     DeskArchiveEntry(path: "C:\\x.desk", size: 1), DeskArchiveEntry(path: "a\\..\\..\\x", size: 1),
                     DeskArchiveEntry(path: "ok/./x", size: 1)]),
                ["DK4030 ../evil.sh", "DK4030 /etc/x", "DK4030 C:\\x.desk", "DK4030 a\\..\\..\\x", "DK4030 ok/./x"])
        t.equal(ids([DeskArchiveEntry(path: "bg.png", size: 1, linkDestination: "/Users/x/bg.png")]), ["DK8606 bg.png"])
        t.equal(ids([DeskArchiveEntry(path: "Tide.desk", size: 1), DeskArchiveEntry(path: "tide.desk", size: 1)]), ["DK8602 tide.desk"])
        t.equal(ids((1...2_001).map { DeskArchiveEntry(path: "n\($0).txt", size: 1) }), ["DK8607 "])
        t.equal(ids([DeskArchiveEntry(path: "a.mov", size: 60 * 1_048_576), DeskArchiveEntry(path: "b.mov", size: 41 * 1_048_576)]),
                ["DK8608 "])
    }

    t.suite("Desk: package — manifest") {
        let package = deskHarbor()
        let manifest = package.manifest
        t.equal(manifest?.name, "Harbor")
        t.equal(manifest?.description, "Tides, a lamp and a radio for the desk.")
        t.equal(manifest?.author, "Deskset")
        t.equal(manifest?.version, "1.0")
        t.equal(manifest?.license, "MIT")
        t.equal(manifest?.deskVersion, 1)
        t.equal(manifest?.requires, AppVersion("1.0"))
        t.equal(manifest?.fields["name"], "\"Harbor\"")
        if let range = manifest?.ranges["requires"] {
            t.equal(deskSiteText(DeskSite(file: packageID, range: range), in: package), "\"1.0\"")
        }
        let tideEntry = package.widget(tide)
        t.equal(tideEntry?.name, "Tide")
        t.equal(tideEntry?.hasWrittenName, true)
        t.equal(tideEntry?.description, "The next high tide.")
        t.equal(tideEntry?.size, "small")
        t.equal(tideEntry?.category, "weather")
        t.equal(tideEntry?.permissions, [])
        let radioEntry = package.widget(radio)
        t.equal(radioEntry?.permissions, ["music"])
        t.equal(radioEntry?.network, ["api.example.com"])
        t.equal(radioEntry?.size, "medium")
        t.equal(package.widget(lamp)?.permissions, ["commands"])
        if let range = tideEntry?.ranges["name"] { t.equal(deskSiteText(DeskSite(file: tide, range: range), in: package), "\"Tide\"") }

        // Defaults and the INI habit.
        let plain = deskMemoryPackage(["Bare.desk": "widget { Text(\"A\") }", "Ini.desk": "info { name = \"Ini\" }\nwidget { Text(\"A\") }"])
        t.equal(plain.widget(DeskFileID("Bare.desk"))?.name, "Bare")
        t.equal(plain.widget(DeskFileID("Bare.desk"))?.hasWrittenName, false)
        t.equal(plain.widget(DeskFileID("Ini.desk"))?.name, "Ini")
        t.equal(plain.manifest, nil)

        // Editing texts keeps the model in step.
        let renamed = package.settingText(package.texts[tide]!.replacingOccurrences(of: "name: \"Tide\"", with: "name: \"Tides\""), of: tide)
        t.equal(renamed.widget(tide)?.name, "Tides")
        let added = renamed.settingText("info { name: \"Buoy\" }\nwidget { Text(\"B\") }\n", of: DeskFileID("Buoy.desk"))
        t.equal(added.widgetFiles, [DeskFileID("Buoy.desk"), lamp, radio, tide])
        t.equal(added.file(at: "Buoy.desk")?.kind, .widget)
        let removed = added.settingText(nil, of: lamp)
        t.equal(removed.widgetFiles, [DeskFileID("Buoy.desk"), radio, tide])
        t.equal(removed.file(at: "Lamp.desk"), nil)
        let repackaged = removed.settingText("package { name: \"Harbour\", requires: \"1.2\" }", of: packageID)
        t.equal(repackaged.manifest?.name, "Harbour")
        t.equal(repackaged.manifest?.requires, AppVersion("1.2"))
        t.equal(package.settingText("x", of: DeskFileID("sub/Nested.desk")), package, "a nested file is not a widget")
    }

    t.suite("Desk: package — validator") {
        let checked = deskCheckedHarbor()
        t.equal(deskFolderDescription(checked), ["DK3026@Tide.desk", "DK8609@images/old.png"])
        t.equal(checked.problemCounts()[DeskFileID("images/old.png")], DeskProblemCount(tips: 1))
        t.equal(checked.problemCounts()[tide], DeskProblemCount(tips: 1))
        t.equal(checked.diagnostics(of: DeskFileID("images/old.png")).map(\.id), [.unusedAsset])
        // Without the folder's font, the family is unknown on this Mac (DK4032); with it, no problem.
        var noFont = deskHarbor()
        noFont.files.removeAll { $0.kind == .font }
        let noFontChecked = CheckedDeskPackage(package: noFont, context: CheckContext(fonts: DeskFakeFonts()))
        t.check(noFontChecked.allDiagnostics.contains { $0.id == .fontNotInstalled && $0.file == tide }, "DK4032 without the font")

        // Pictures are found per folder, as a Mac finds them; a misspelled one gets the similar file.
        let pictures: [(String, InMemoryPackageSource.Item)] = [("images/waves.png", .file(deskPNG(width: 8, height: 8)))]
        let found = CheckedDeskPackage(package: deskMemoryPackage(["A.desk": "info { name: \"A\" }\nwidget { Image(\"Images/Waves.PNG\") }"],
                                                                  extra: pictures))
        t.equal(deskFolderDescription(found), [], "case-insensitive like the Mac")
        let misspelled = CheckedDeskPackage(package: deskMemoryPackage(["A.desk": "info { name: \"A\" }\nwidget { Image(\"images/wave.png\") }"],
                                                                       extra: pictures))
        let missing = misspelled.allDiagnostics.first { $0.id == .fileNotFound }
        t.check(missing?.message(in: .english).contains("images/waves.png") == true, "\(String(describing: missing))")
        t.equal(missing?.fixIts.first?.edits.first?.replacement, "\"images/waves.png\"")
        t.equal(misspelled.allDiagnostics.filter { $0.id == .unusedAsset }.map(\.file.path), ["images/waves.png"],
                "no widget shows it until the name is fixed")

        // Pictures from data: unused ones cannot be known.
        let computed = CheckedDeskPackage(package: deskMemoryPackage(
            ["A.desk": "info { name: \"A\", permissions: [.music] }\nwidget { Image(music.cover.ifMissing(\"images/waves.png\")) }"],
            extra: pictures + [("images/other.png", .file(deskPNG(width: 2, height: 2)))]))
        t.equal(computed.allDiagnostics.filter { $0.id == .unusedAsset }.count, 0)
        t.check(computed.files[DeskFileID("A.desk")]?.assets.computedImages == true)
        // Both branches of `?:` are written out.
        let branches = CheckedDeskPackage(package: deskMemoryPackage(
            ["A.desk": "info { name: \"A\" }\nwidget { Image(time.now.hour < 12 ? \"images/waves.png\" : \"images/other.png\") }"],
            extra: pictures + [("images/other.png", .file(deskPNG(width: 2, height: 2)))]))
        t.equal(deskFolderDescription(branches), [])

        // An empty folder and a folder with only package.desk.
        t.equal(deskFolderDescription(CheckedDeskPackage(package: DeskPackage())), ["DK8601@"])
        let onlyPackage = CheckedDeskPackage(package: deskMemoryPackage(["package.desk": "package { name: \"P\" }"]))
        t.equal(deskFolderDescription(onlyPackage), ["DK8601@package.desk"])
        t.equal(onlyPackage.folderDiagnostics.first?.range, 0..<7, "at `package`")

        // Requires: the fix-it writes what the widgets need; the note points at the widget.
        var future = CheckContext(catalog: deskFutureCatalog(), appVersion: AppVersion("1.2"))
        future.resources = nil
        let sparks = deskMemoryPackage(["package.desk": "package { name: \"S\", requires: \"1.0\" }",
                                        "Spark.desk": "info { name: \"Spark\" }\nwidget { Text(\"Hi\").sparkle(2) }",
                                        "Plain.desk": "info { name: \"Plain\" }\nwidget { Text(\"Hi\") }"])
        let sparksChecked = CheckedDeskPackage(package: sparks, context: future)
        let old = sparksChecked.folderDiagnostics.first { $0.id == .packageRequiresTooOld }
        t.equal(old?.message(in: .english), "The package says it runs on Deskset 1.0, but Spark.desk needs Deskset 1.2.")
        t.equal(old?.fixIts.first?.edits.first?.replacement, "\"1.2\"")
        t.equal(old?.fixIts.first?.title(in: .english), "Replace with `\"1.2\"`")
        t.equal(old?.notes.first?.file, DeskFileID("Spark.desk"))
        t.equal(old?.notes.first?.message(in: .english), "This widget needs Deskset 1.2.")
        // A widget's own `requires` counts too.
        let written = CheckedDeskPackage(package: deskMemoryPackage(["package.desk": "package { name: \"S\", requires: \"1.0\" }",
                                                                     "A.desk": "info { name: \"A\", requires: \"1.3\" }\nwidget { Text(\"Hi\") }"]),
                                         context: future)
        t.check(written.folderDiagnostics.contains { $0.id == .packageRequiresTooOld && $0.message(in: .english).hasSuffix("needs Deskset 1.3.") })
        let noRequires = CheckedDeskPackage(package: deskMemoryPackage(["package.desk": "package { name: \"S\" }",
                                                                        "Spark.desk": "info { name: \"Spark\" }\nwidget { Text(\"Hi\").sparkle(2) }"]),
                                            context: future)
        t.check(!noRequires.folderDiagnostics.contains { $0.id == .packageRequiresTooOld }, "only a written requires is compared")

        // Two widgets with one name (case aside), a widget in a subfolder.
        let named = CheckedDeskPackage(package: deskMemoryPackage([
            "A.desk": "info { name: \"Clock\" }\nwidget { Text(\"A\") }",
            "B.desk": "info { name: \"clock \" }\nwidget { Text(\"B\") }",
            "Extras/C.desk": "info { name: \"C\" }\nwidget { Text(\"C\") }"]))
        t.equal(deskFolderDescription(named), ["DK8603@B.desk", "DK8605@Extras/C.desk"])
        t.equal(named.folderDiagnostics.first?.notes.first?.file, DeskFileID("A.desk"))
        t.equal(named.folderDiagnostics.last?.message(in: .english),
                "Deskset loads only the `.desk` files at the top of the folder, so `Extras/C.desk` is left out. Move it next to the other widgets.")
    }

    t.suite("Desk: package — locales") {
        let checked = deskCheckedHarbor()
        let locales = DeskPackageLocales(checked)
        t.equal(locales.languages, ["ja", "zh-Hans"])
        t.equal(locales.languages(of: tide), ["ja", "zh-Hans"], "the package's languages apply to every widget")
        t.equal(locales.widgetTables[tide]?["zh-Hans"]?["Tide"], "\"潮位\"", "the widget wins")
        t.equal(locales.widgetTables[lamp]?["zh-Hans"]?["Tide"], "\"潮汐\"", "the package's entry elsewhere")
        t.equal(locales.displayLanguage(of: tide, preferred: ["zh-Hans-CN", "en"]), "zh-Hans")
        t.equal(locales.displayLanguage(of: tide, preferred: ["zh_CN"]), "zh-Hans")
        t.equal(locales.displayLanguage(of: tide, preferred: ["en-GB", "zh-Hans"]), "zh-Hans", "English is the source, not a table")
        t.equal(locales.displayLanguage(of: tide, preferred: ["zh-TW"]), nil)
        t.equal(locales.displayLanguage(of: tide, preferred: ["ja-JP"]), "ja")
        t.equal(locales.name(of: tide, preferred: ["zh-Hans"]), "潮位")
        t.equal(locales.name(of: tide, preferred: ["ja"]), "Tide", "no Japanese name")
        t.equal(locales.name(of: lamp, preferred: ["zh-Hans"]), "Lamp")
        t.equal(locales.description(of: tide, preferred: ["zh-Hans"]), "下一次涨潮。")
        t.equal(locales.description(of: radio, preferred: ["zh-Hans"]), "What is playing, and the station's news.")
        t.equal(locales.packageName(preferred: ["ja"]), "ハーバー")
        t.equal(locales.packageName(preferred: ["zh-Hant"]), "Harbor")
        t.equal(locales.packageDescription(preferred: ["zh-Hans"]), "桌上的潮汐、台灯和收音机。")
        t.equal(locales.translate("Tide", in: tide, language: "zh-CN"), "潮位")
        t.equal(locales.translate("Nothing", in: tide, language: "zh-Hans"), nil)

        // Coverage: hints per language.
        let tideCoverage = locales.coverage(of: tide)
        t.equal(tideCoverage.map(\.language), ["ja", "zh-Hans"])
        let zh = tideCoverage.first { $0.language == "zh-Hans" }
        t.check(zh?.missing.contains("Wave height") == true && zh?.missing.contains("Show waves") == false, "\(String(describing: zh))")
        t.check(zh.map { $0.translated + $0.missing.count == $0.total } == true)
        t.equal(locales.coverage(of: nil).map(\.missing),
                [["Tides, a lamp and a radio for the desk.", "Accent color", "Units", "Use metric units", "Meters and degrees Celsius."], []])

        // A translation with data is a pattern, not text.
        let pattern = CheckedDeskPackage(package: deskMemoryPackage(["A.desk": """
            info { name: "A" }
            widget { Text("{cpu.usage}% used") }
            translations { "de" { "{cpu.usage}% used": "{cpu.usage}% belegt" } }
            """]))
        let patternLocales = DeskPackageLocales(pattern)
        t.equal(patternLocales.translate("{cpu.usage}% used", in: DeskFileID("A.desk"), language: "de"), nil)
        t.equal(patternLocales.widgetTables[DeskFileID("A.desk")]?["de"]?["{cpu.usage}% used"], "\"{cpu.usage}% belegt\"")
        t.equal(patternLocales.coverage(of: DeskFileID("A.desk")).first?.missing, ["A"])
    }

    t.suite("Desk: package — schema") {
        let checked = deskCheckedHarbor()
        let schema = checked.optionsSchema(for: tide)
        t.equal(schema.items.map(\.name), ["showWaves", "look", "height", "accent", "metric"])
        t.equal(schema.items.map(\.order), [0, 1, 2, 3, 4])
        let showWaves = schema.item("showWaves")
        t.equal(showWaves?.control, "Toggle")
        t.equal(showWaves?.panel, .toggle)
        t.equal(showWaves?.defaultValue, "true")
        t.equal(showWaves?.defaultIsWritten, true)
        t.equal(showWaves?.typeName, DeskCatalog.current.displayName(for: .bool))
        let look = schema.item("look")
        t.equal(look?.choices.map(\.value), [".calm", ".stormy"])
        t.equal(look?.choices.map(\.label), ["Calm", "Stormy"])
        t.equal(look?.defaultValue, ".calm", "a Picker starts with its first choice")
        t.equal(look?.defaultIsWritten, false)
        t.check(look?.isSegmented == true)
        t.equal(look?.typeName.en, "one of its choices")
        let height = schema.item("height")
        t.equal([height?.minimum, height?.maximum, height?.step, height?.defaultValue], ["10", "60", "5", "30"])
        t.equal(height?.hiddenIf, DeskOptionCondition(text: "not options.showWaves", options: ["showWaves"], hidesWhenTrue: true))
        t.equal(height?.panel, .slider)
        let accent = schema.item("accent")
        t.equal(accent?.scope, .widget)
        t.equal(accent?.replacesPackageOption, true)
        t.equal(accent?.label, "Tide color")
        t.equal(accent?.typeName, DeskCatalog.current.displayName(for: .color))
        if let site = accent?.declaration { t.equal(deskSiteText(site, in: checked.package), "accent") }
        let metric = schema.item("metric")
        t.equal(metric?.scope, .package)
        t.equal(metric?.help, "Meters and degrees Celsius.")
        t.equal(metric?.section.map { schema.sections[$0].title }, "Units")
        t.equal(schema.sections.map(\.scope), [.package])
        t.equal(schema.storage.perInstance, ["showWaves", "look", "height", "accent"])
        t.equal(schema.storage.perPackage, ["metric"])
        t.equal(schema.storage.savedValues, [])
        t.equal(schema.storage.maximumValueBytes, 65_536)
        t.equal(schema.storage.maximumInstanceBytes, 1_048_576)

        // In Chinese: the widget's and the package's labels.
        let zh = checked.optionsSchema(for: tide, language: "zh-Hans")
        t.equal(zh.item("showWaves")?.displayLabel, "显示波浪")
        t.equal(zh.item("metric")?.displayLabel, "使用公制单位")
        t.equal(zh.item("metric")?.displayHelp, "米和摄氏度。")
        t.equal(zh.sections.first?.displayTitle, "单位")
        t.equal(zh.item("look")?.choices.first?.displayLabel, "Calm", "untranslated labels stay")

        let lampSchema = checked.optionsSchema(for: lamp)
        t.equal(lampSchema.items.map(\.name), ["target", "accent", "metric"])
        t.equal(lampSchema.item("target")?.placeholder, "https://…")
        t.equal(lampSchema.item("target")?.defaultValue, "\"https://example.com\"")
        t.equal(lampSchema.item("accent")?.scope, .package)
        t.equal(lampSchema.item("accent")?.defaultValue, ".teal")
        t.equal(lampSchema.storage.savedValues, ["clicks"])
        t.equal(lampSchema.storage.perPackage, ["accent", "metric"])
        let radioSchema = checked.optionsSchema(for: radio)
        t.equal(radioSchema.item("apiKey")?.userOnly, true)
        t.equal(radioSchema.item("apiKey")?.isSecret, true)
        t.equal(radioSchema.item("apiKey")?.defaultValue, nil, "missing until the user chooses")
        t.equal(radioSchema.storage.keychain, ["apiKey"])

        let packagePage = checked.packageOptionsSchema()
        t.equal(packagePage.widget, nil)
        t.equal(packagePage.items.map(\.name), ["accent", "metric"])
        t.equal(packagePage.storage.perPackage, ["accent", "metric"])
        t.equal(packagePage.storage.perInstance, [])

        // Built-in choices take the catalog's titles; defaults of the other controls; a whole command is user-only.
        let more = CheckedDeskPackage(package: deskMemoryPackage(["A.desk": """
            info { name: "A", permissions: [.commands] }
            options {
                weekStart = Picker("Week starts on", [.sunday, .monday, .saturday, .wednesday])
                days = Stepper("Days", min: 1, max: 14)
                note = Input("Note")
                tint = ColorPicker("Tint")
                face = FontPicker("Font")
                script = Input("Script", default: "date")
            }
            widget {
                Column {
                    Text(options.note).font(options.face, 14).color(options.tint)
                    Text("{calendar.month(weekStart: options.weekStart).title}")
                    Text("{options.days}")
                        .onClick { run(options.script) }
                }
            }
            """]))
        t.equal(deskFolderDescription(more), [])
        let moreSchema = more.optionsSchema(for: DeskFileID("A.desk"), language: "zh-Hans")
        t.equal(moreSchema.item("weekStart")?.choices.map(\.label), ["Sunday", "Monday", "Saturday", "Wednesday"])
        t.equal(moreSchema.item("weekStart")?.choices.first?.displayLabel, "星期日")
        t.check(moreSchema.item("weekStart")?.isSegmented == false, "four choices make a menu")
        t.equal(moreSchema.item("days")?.defaultValue, "1")
        t.equal(moreSchema.item("days")?.step, "1")
        t.equal(moreSchema.item("note")?.defaultValue, "\"\"")
        t.equal(moreSchema.item("tint")?.defaultValue, ".accent")
        t.equal(moreSchema.item("face")?.defaultValue, "\"System\"")
        t.equal(moreSchema.item("script")?.userOnly, true)
        t.equal(moreSchema.item("note")?.userOnly, false)
        t.equal(SchemaBuilder.words("darkBlue"), "Dark Blue")
        t.equal(SchemaBuilder.words("level2Alarm"), "Level 2 Alarm")
    }

    t.suite("Desk: package — consent") {
        let checked = deskCheckedHarbor()
        let summary = checked.installSummary()
        let total = summary.total
        t.equal(total.permissions.map(\.id), ["music", "commands"], "in the catalog's order")
        t.equal(total.permissions.first?.phrase.en, DeskCatalog.current.permissions.first { $0.id == "music" }?.needsPhrase.en)
        t.equal(total.permissions.map(\.declared), [true, true])
        t.equal(total.permissions.map(\.needed), [true, true])
        t.equal(total.permissions.map(\.widgets), [[radio], [lamp]])
        t.equal(total.hosts, ["api.example.com"])
        t.equal(total.features, ["liquidGlass"])
        t.equal(total.minimumAppVersion, AppVersion("1.0"))
        t.equal(total.commands.count, 1)
        let command = total.commands.first
        t.equal(command?.template, "open {options.target}")
        t.equal(command?.script, "open \"${1}\"")
        t.equal(command?.placeholders, [DeskConsentCommand.Placeholder(option: "target", knownValues: ["\"https://example.com\""])])
        if let site = command?.site { t.equal(deskSiteText(site, in: checked.package), "\"open {options.target}\"") }
        t.equal(summary.widgets[tide], DeskConsent(minimumAppVersion: AppVersion("1.0")!), "Tide asks for nothing")
        t.check(summary.widgets[tide]?.isEmpty == true)
        t.equal(summary.widgets[radio]?.permissions.map(\.id), ["music"])
        t.equal(summary.widgets[lamp]?.commands.count, 1)
        t.equal(summary.fonts.map(\.path), ["fonts/HarborSans.ttf"])
        let lines = total.lines(in: .english)
        t.check(lines.contains("connects to api.example.com") && lines.contains("runs open {options.target}"), "\(lines)")
        t.check(total.lines(in: .simplifiedChinese).contains("连接 api.example.com"))

        // A permission needed but not asked for, a whole command with its default, and a host no pattern covers.
        let asked = CheckedDeskPackage(package: deskMemoryPackage(["A.desk": """
            info { name: "A", permissions: [.commands] }
            options { script = Input("Script", default: "uptime") }
            widget {
                Text(music.title.ifMissing("–")).onClick { run(options.script) }
                Text("{web.json("https://news.example.org/a").title}")
            }
            """]))
        let consent = asked.installSummary().total
        t.equal(consent.permissions.map { "\($0.id) declared:\($0.declared) needed:\($0.needed)" },
                ["music declared:false needed:true", "commands declared:true needed:true"])
        t.equal(consent.commands.first?.scriptOption, "script")
        t.equal(consent.commands.first?.scriptDefault, "\"uptime\"")
        t.equal(consent.hosts, ["news.example.org"])
        t.check(consent.lines(in: .english).contains("runs options.script = \"uptime\""), "\(consent.lines(in: .english))")
    }

    t.suite("Desk: package — cross-file") {
        let checked = deskCheckedHarbor()
        let uses = checked.uses
        t.equal(Set(uses.styles.keys), ["card", "heading"])
        t.equal(uses.styles["card"]?.widgets, [lamp, radio, tide])
        for entry in uses.styles.values {
            t.equal(entry.declarations.map { deskSiteText($0, in: checked.package) }, [entry.name])
            for site in entry.uses { t.equal(deskSiteText(site, in: checked.package), entry.name, "\(site)") }
        }
        t.equal(uses.options["metric"]?.uses.map { deskSiteText($0, in: checked.package) }, ["options.metric"])
        t.equal(uses.options["metric"]?.widgets, [tide])
        t.equal(uses.options["accent"]?.uses.map(\.file), [packageID], "only the package's style reads it")
        t.equal(uses.options["accent"]?.replacedIn, [tide])
        t.equal(uses.options["accent"]?.declarations.map { deskSiteText($0, in: checked.package) }, ["accent"])
        let tideKey = uses.translations["Tide"]
        t.equal(tideKey?.declarations.map { deskSiteText($0, in: checked.package) }, ["\"Tide\""])
        t.equal(tideKey?.uses.map { deskSiteText($0, in: checked.package) }, ["\"Tide\"", "\"Tide\""])
        t.equal(tideKey?.widgets, [tide])
        t.equal(uses.translations["Harbor"]?.declarations.count, 2, "one per language")
        if let use = uses.styles["heading"]?.uses.first {
            t.equal(uses.entry(at: use.range.lowerBound + 1, in: use.file)?.name, "heading")
        }
        t.equal(uses.entry(at: 0, in: tide)?.name, nil)

        // The language service over a loaded folder.
        let package = deskHarbor()
        let service = DeskLanguageService(package: package, openFile: tide,
                                          options: DeskServiceOptions(fonts: DeskFakeFonts()))
        let first = service.snapshot
        t.equal(first.diagnostics.map(\.id), [.optionReplacesPackage], "pictures and fonts come from the folder")
        let viaService = first.packageCheck()
        t.equal(deskFolderDescription(viaService), deskFolderDescription(checked))
        t.equal(viaService.uses, checked.uses)
        let lampVersion = first.folderResults()[lamp]?.tree.version
        // Editing the open widget reuses the other widgets' checks.
        let edited = service.update(changes: [DeskTextChange(range: 0..<0, text: "// note\n")], version: 1)
        t.equal(edited.folderResults()[lamp]?.tree.version, lampVersion, "Lamp is not checked again")
        t.check(edited.packageCheck().package.texts[tide]?.hasPrefix("// note\n") == true, "the folder holds the edited text")
        // Using the unused picture in the open file clears DK8609.
        let usesOld = service.replaceText(edited.text.replacingOccurrences(of: "Text(\"Tide\")", with: "Image(\"images/old.png\")\n        Text(\"Tide\")"),
                                          version: 2)
        t.equal(deskFolderDescription(usesOld.packageCheck()), ["DK3026@Tide.desk"])
        // A change to package.desk checks every widget again.
        let packageText = package.texts[packageID]!
        let changed = service.setText(packageText.replacingOccurrences(of: "\"Units\"", with: "\"Measures\""), of: packageID)
        t.check(changed.folderResults()[lamp]?.tree.version != lampVersion, "Lamp is checked again")

        // Editing package.desk itself.
        let packageService = DeskLanguageService(package: package, openFile: packageID)
        let before = packageService.snapshot.folderResults()[radio]?.tree.version
        let again = packageService.update(changes: [], version: 1).folderResults()[radio]?.tree.version
        t.equal(again, before, "no edit, no new check")
        let afterEdit = packageService.update(changes: [DeskTextChange(range: 0..<0, text: " ")], version: 2)
        t.check(afterEdit.folderResults()[radio]?.tree.version != before, "an edit to package.desk checks the widgets again")
        t.equal(afterEdit.packageCheck().widgetFiles, [lamp, radio, tide])

        // A new file on disk: setPackage.
        let grown = package.settingText("info { name: \"Buoy\" }\nwidget { Image(\"images/old.png\") }\n", of: DeskFileID("Buoy.desk"))
        let regrown = service.setPackage(grown)
        t.equal(regrown.packageCheck().widgetFiles.first, DeskFileID("Buoy.desk"))
    }
}
