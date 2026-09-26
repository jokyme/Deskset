import Foundation
@testable import DesksetCore

// Tests for the .rmskin module. Packages are built for real: a folder tree zipped with
// `/usr/bin/ditto -c -k --sequesterRsrc` plus the 16-byte footer, or crafted byte by byte with `RmskinTestZip`
// for archives no well-behaved tool would produce (zip-slip, symlinks, backslash names).

func runRmskinTests(_ t: TestRunner) {
    // Several suites check that no `Deskset-…` work folder is left in the (shared) system temporary directory: hold
    // the cross-run lock so overlapping DesksetSelfTest runs do not create theirs in the middle of those checks.
    t.withSystemTemporaryDirectoryLock {
        rmskinTemporaryCheckTests(t)
        rmskinManifestTests(t)
        rmskinPayloadTests(t)
        rmskinZipScanTests(t)
        rmskinExtractTests(t)
        rmskinInspectTests(t)
        rmskinInstallTests(t)
        rmskinUpgradeTests(t)
        rmskinMergeTests(t)
        rmskinLayoutTests(t)
        rmskinLoadTests(t)
        rmskinTextTests(t)
        rmskinRobustnessTests(t)
        rmskinExtractionHardeningTests(t)
        rmskinLegacyNameTests(t)
        rmskinManualConformanceTests(t)
    }
}

// MARK: - Helpers

private enum RmskinTestZip {
    struct Entry {
        var name: String
        var data: Data = Data()
        /// Unix mode (e.g. 0o120777 for a symlink) stored in the external attributes with "made by Unix".
        var unixMode: UInt32?
        /// Raw name bytes (e.g. code page 437) written instead of `name`; the UTF-8 flag is then cleared.
        var rawName: Data? = nil
        /// `data` is already raw DEFLATE data (method 8); `declaredSize` is the uncompressed size the headers claim.
        var deflated: Bool = false
        var declaredSize: UInt32? = nil
        /// CRC written to the headers (default: computed from `data`; ditto does not check it).
        var crc: UInt32? = nil
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    /// A ZIP with "stored" (uncompressed) or pre-deflated entries, UTF-8 names unless `rawName` is given.
    /// `declaredCount` makes the end-of-directory record lie about the number of entries.
    static func make(_ entries: [Entry], declaredCount: Int? = nil) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = entry.rawName ?? Data(entry.name.utf8)
            let flags = entry.rawName == nil ? 0x0800 : 0
            let method = entry.deflated ? 8 : 0
            let crc = entry.crc ?? crc32(entry.data)
            let compressedSize = UInt32(entry.data.count)
            let size = entry.declaredSize ?? compressedSize
            let offset = UInt32(out.count)
            out += le32(0x0403_4B50) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0x21)
            out += le32(crc) + le32(compressedSize) + le32(size) + le16(name.count) + le16(0)
            out += name + entry.data
            let madeBy = entry.unixMode == nil ? 20 : (3 << 8) | 20
            let external = entry.unixMode.map { $0 << 16 } ?? (name.last == 0x2F ? 0x10 : 0)
            central += le32(0x0201_4B50) + le16(madeBy) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0x21)
            central += le32(crc) + le32(compressedSize) + le32(size) + le16(name.count) + le16(0) + le16(0) + le16(0)
            central += le16(0) + le32(external) + le32(offset) + name
        }
        let directoryOffset = UInt32(out.count)
        out += central
        let count = declaredCount ?? entries.count
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(count) + le16(count)
        out += le32(UInt32(central.count)) + le32(directoryOffset) + le16(0)
        return out
    }
}

private func footer(_ length: UInt64) -> Data {
    var data = Data()
    for i in 0..<8 { data.append(UInt8((length >> (8 * UInt64(i))) & 0xFF)) }
    data.append(contentsOf: RmskinPackage.footerMagic)
    return data
}

private func utf8(_ s: String) -> Data { Data(s.utf8) }

/// A black 24-bit Windows bitmap: BITMAPFILEHEADER + BITMAPINFOHEADER (40 bytes) + rows padded to 4 bytes.
/// A negative `height` is a top-down bitmap.
private func bitmap(width: Int, height: Int) -> Data {
    func le32(_ v: Int) -> Data { RmskinTestZip.le32(UInt32(truncatingIfNeeded: v)) }
    let rowSize = ((24 * width + 31) / 32) * 4
    let pixels = rowSize * abs(height)
    var data = Data([0x42, 0x4D]) + le32(54 + pixels) + le32(0) + le32(54)
    data += le32(40) + le32(width) + le32(height) + RmskinTestZip.le16(1) + RmskinTestZip.le16(24)
    data += le32(0) + le32(pixels) + le32(2835) + le32(2835) + le32(0) + le32(0)
    data += Data(count: pixels)
    return data
}

private func utf16LE(_ s: String, bom: Bool = true) -> Data {
    (bom ? Data([0xFF, 0xFE]) : Data()) + (s.data(using: .utf16LittleEndian) ?? Data())
}

@discardableResult
private func runTool(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func writeTree(_ files: [(String, Data)], at root: URL) throws {
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

/// Builds a package from a file list (paths relative to the package root, `/`-separated) with ditto.
private func makePackage(_ files: [(String, Data)], in dir: URL, name: String = "Test.rmskin",
                         withFooter: Bool = true) throws -> URL {
    let source = dir.appendingPathComponent("src-\(UUID().uuidString)")
    try writeTree(files, at: source)
    let zip = dir.appendingPathComponent("\(UUID().uuidString).zip")
    let status = try runTool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", source.path, zip.path])
    guard status == 0 else { throw RmskinError.extractionFailed("test zip creation failed") }
    var data = try Data(contentsOf: zip)
    if withFooter { data += footer(UInt64(data.count)) }
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: zip)
    return url
}

private func rawPackage(_ entries: [RmskinTestZip.Entry], in dir: URL, name: String = "Raw.rmskin") throws -> URL {
    var data = RmskinTestZip.make(entries)
    data += footer(UInt64(data.count))
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func text(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map(TextDecoding.decode)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func expectRmskinError(_ t: TestRunner, _ label: String, file: StaticString = #fileID, line: UInt = #line,
                               matching: (RmskinError) -> Bool, _ body: () throws -> Void) {
    do {
        try body()
        t.check(false, "\(label): expected an error", file: file, line: line)
    } catch let error as RmskinError {
        t.check(matching(error), "\(label): got \(error)", file: file, line: line)
    } catch {
        t.check(false, "\(label): got non-Rmskin error \(error)", file: file, line: line)
    }
}

private func isNotAPackage(_ e: RmskinError) -> Bool { if case .notAPackage = e { return true } else { return false } }
private func isExtractionFailed(_ e: RmskinError) -> Bool {
    if case .extractionFailed = e { return true } else { return false }
}
private func isUnreadable(_ e: RmskinError) -> Bool { if case .unreadable = e { return true } else { return false } }

private let clockManifest = """
[rmskin]
Name=Clockwork
Author=Tester
Version=1.2
LoadType=Skin
Load=Clockwork\\Digital\\Digital.ini
VariableFiles=Clockwork\\@Resources\\Variables.inc
MinimumRainmeter=4.5.0.0
MinimumWindows=6.1
"""

private func clockFiles(manifest: String = clockManifest, variables: String? = nil) -> [(String, Data)] {
    [
        ("RMSKIN.ini", utf8(manifest)),
        ("Skins/Clockwork/Digital/Digital.ini", utf8("[Rainmeter]\nUpdate=1000\n[MeterTime]\nMeter=String\n")),
        ("Skins/Clockwork/Analog/Analog.ini", utf8("[Rainmeter]\nUpdate=1000\n")),
        ("Skins/Clockwork/@Resources/Variables.inc",
         utf8(variables ?? "[Variables]\nColor=255,255,255\nSize=12\n")),
        ("Skins/Clockwork/@Resources/Fonts/Clock.ttf", Data([0, 1, 0, 0])),
    ]
}

/// DesksetCore's work folders (`Deskset-…`) in the system temporary directory right now.
private func temporaryItems(_ t: TestRunner) -> Set<String> {
    t.systemTemporaryItems(prefix: "Deskset-")
}

/// Work folders created since `before` that are still there: leftovers (see `TestRunner.newSystemTemporaryItems`,
/// which ignores the short-lived folders of other processes).
private func temporaryLeftovers(_ t: TestRunner, since before: Set<String>) -> Set<String> {
    t.newSystemTemporaryItems(prefix: "Deskset-", since: before)
}

// MARK: - Test infrastructure

private func rmskinTemporaryCheckTests(_ t: TestRunner) {
    t.suite("Rmskin: temporary-folder leftover checks (test infrastructure)") {
        let dir = t.temporaryDirectory("rmskin-infra")
        t.check(dir.path.hasPrefix(t.temporaryRoot.path + "/"), "test folders live in this run's own root")
        t.check(t.temporaryRoot.lastPathComponent.hasPrefix("DesksetSelfTest-run-"))
        t.check(!t.temporaryRoot.lastPathComponent.hasPrefix("Deskset-"), "never counted as a DesksetCore work folder")

        let fm = FileManager.default
        let before = temporaryItems(t)
        let leftover = fm.temporaryDirectory.appendingPathComponent("Deskset-selftest-leftover-\(UUID().uuidString)")
        let passing = fm.temporaryDirectory.appendingPathComponent("Deskset-selftest-passing-\(UUID().uuidString)")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        try fm.createDirectory(at: passing, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: leftover)
            try? fm.removeItem(at: passing)
        }
        // Another process's short-lived work folder: gone again while the check waits.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { try? fm.removeItem(at: passing) }
        t.equal(t.newSystemTemporaryItems(prefix: "Deskset-", since: before, grace: 1), [leftover.lastPathComponent],
                "a folder that stays is a leftover, one that goes away again is not")
        try fm.removeItem(at: leftover)
        t.equal(temporaryLeftovers(t, since: before), [])
    }
}

// MARK: - Manifest

private func rmskinManifestTests(_ t: TestRunner) {
    t.suite("Rmskin: manifest keys") {
        let m = RmskinManifest.parse("""
        ; comment
        [rmskin]
        Name=illustro
        Author=poiru
        Version=2.0
        LoadType=Skin
        Load=illustro\\Clock\\Clock.ini
        VariableFiles=illustro\\Clock\\Variables.inc | illustro\\Feeds\\Variables.inc
        MergeSkins=0
        MinimumRainmeter=4.2.0.3111
        MinimumWindows=6.1
        Extra=kept
        """)
        t.equal(m.name, "illustro")
        t.equal(m.author, "poiru")
        t.equal(m.version, "2.0")
        t.equal(m.loadType, "Skin")
        t.equal(m.load, "illustro\\Clock\\Clock.ini", "backslashes kept as written")
        t.equal(m.variableFiles, ["illustro\\Clock\\Variables.inc", "illustro\\Feeds\\Variables.inc"])
        t.equal(m.mergeSkins, false)
        t.equal(m.minimumRainmeter, "4.2.0.3111")
        t.equal(m.minimumWindows, "6.1")
        t.equal(m.raw["Extra"], "kept")
        t.equal(m.raw["name"], "illustro")
        t.equal(m.raw.name, "rmskin")
    }

    t.suite("Rmskin: manifest case, quotes, bools, pipes") {
        let m = RmskinManifest.parse("""
        [RMSKIN]
        name="Quoted Name"
        AUTHOR = Someone
        mergeskins=1
        loadtype=Layout
        load=My Layout
        variablefiles= a\\b.inc|| "c\\d.inc" |  |e/f.inc
        """)
        t.equal(m.name, "Quoted Name")
        t.equal(m.author, "Someone")
        t.equal(m.mergeSkins, true)
        t.equal(m.loadType, "Layout")
        t.equal(m.load, "My Layout")
        t.equal(m.variableFiles, ["a\\b.inc", "c\\d.inc", "e/f.inc"])
        for (value, expected) in [("1", true), ("0", false), ("", false), ("2", true), ("true", true),
                                  ("no", false), ("abc", false), (" 1 ", true), ("0.0", false)] {
            t.equal(RmskinManifest.parseBool(value), expected, "parseBool(\(value))")
        }
    }

    t.suite("Rmskin: manifest missing section / garbage") {
        t.equal(RmskinManifest.parse(""), RmskinManifest())
        t.equal(RmskinManifest.parse("[Other]\nName=x\n"), RmskinManifest())
        t.equal(RmskinManifest.parse("Name=before section\n[rmskin"), RmskinManifest())
        let m = RmskinManifest.parse("[rmskin]\nName=first\nName=second\n=novalue\nVariableFiles=\n")
        t.equal(m.name, "first", "first definition wins")
        t.equal(m.variableFiles, [])
        _ = RmskinManifest.parse(String(repeating: "[rmskin]\n=|=|\n", count: 200))
    }

    t.suite("Rmskin: manifest UTF-16LE file") {
        let dir = t.temporaryDirectory("rmskin-manifest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("RMSKIN.ini")
        try utf16LE("[rmskin]\r\nName=Ünïcødé 時計\r\nAuthor=A\r\n").write(to: url)
        let m = try RmskinManifest.parse(contentsOf: url)
        t.equal(m.name, "Ünïcødé 時計")
        t.equal(m.author, "A")
        try utf16LE("[rmskin]\nName=NoBOM\n", bom: false).write(to: url)
        t.equal(try RmskinManifest.parse(contentsOf: url).name, "NoBOM")
        expectRmskinError(t, "missing manifest file", matching: isUnreadable) {
            _ = try RmskinManifest.parse(contentsOf: dir.appendingPathComponent("nope.ini"))
        }
    }

    t.suite("Rmskin: minimum version comparison") {
        // "to target the .rmskin at any revision of 4.0 or later you can leave off most of the number, and just
        //  use 4, target any revision of 4.2 with 4.2 or a specific revision number with 4.2.0.3111."
        t.check(RmskinManifest.version("4.0.0.2551", isAtLeast: "4"))
        t.check(RmskinManifest.version("4.2.0.3111", isAtLeast: "4.2"))
        t.check(RmskinManifest.version("4.2.0.3111", isAtLeast: "4.2.0.3111"))
        t.check(!RmskinManifest.version("4.2.0.3110", isAtLeast: "4.2.0.3111"))
        t.check(!RmskinManifest.version("3.3.0.2519", isAtLeast: "4"))
        t.check(RmskinManifest.version("4.5", isAtLeast: "4.2.0.3111"))
        t.check(RmskinManifest.version("10.0", isAtLeast: "9.9.9.9"))
        t.check(RmskinManifest.version("4", isAtLeast: ""))
        t.check(RmskinManifest.version("4.5.23 beta", isAtLeast: "4.5.22"))
        t.check(!RmskinManifest.version("", isAtLeast: "1"))
        t.check(RmskinManifest.version("99999999999999999999", isAtLeast: "1"))
    }
}

// MARK: - Footer / payload

private func rmskinPayloadTests(_ t: TestRunner) {
    t.suite("Rmskin: zipPayload footer") {
        let zip = RmskinTestZip.make([.init(name: "a.txt", data: utf8("hi"))])
        let package = zip + footer(UInt64(zip.count))
        t.equal(try RmskinPackage.zipPayload(of: package), zip)
        t.equal(RmskinPackage.footerMagic, Array("\0RMSKIN\0".utf8))

        // Recorded length shorter than the space before the footer: the leading `length` bytes are the ZIP.
        let padded = zip + Data([1, 2, 3]) + footer(UInt64(zip.count))
        t.equal(try RmskinPackage.zipPayload(of: padded), zip)

        // A Data slice with a non-zero start index works too.
        let big = Data([9, 9, 9]) + package
        let slice = big[3...]
        t.equal(try RmskinPackage.zipPayload(of: slice), zip)
    }

    t.suite("Rmskin: zipPayload plain ZIP") {
        let zip = RmskinTestZip.make([.init(name: "a.txt", data: utf8("hi"))])
        t.equal(try RmskinPackage.zipPayload(of: zip), zip)
        let slice = (Data([7]) + zip)[1...]
        let payload = try RmskinPackage.zipPayload(of: slice)
        t.equal(payload, zip)
        t.equal(payload.startIndex, 0)
    }

    t.suite("Rmskin: zipPayload malformed") {
        let zip = RmskinTestZip.make([.init(name: "a.txt", data: utf8("hi"))])
        expectRmskinError(t, "length too large", matching: isNotAPackage) {
            _ = try RmskinPackage.zipPayload(of: zip + footer(UInt64(zip.count + 1)))
        }
        expectRmskinError(t, "huge length", matching: isNotAPackage) {
            _ = try RmskinPackage.zipPayload(of: zip + footer(UInt64.max))
        }
        expectRmskinError(t, "zero length", matching: isNotAPackage) {
            _ = try RmskinPackage.zipPayload(of: zip + footer(0))
        }
        expectRmskinError(t, "payload not a ZIP", matching: isNotAPackage) {
            let junk = Data(repeating: 0x41, count: 40)
            _ = try RmskinPackage.zipPayload(of: junk + footer(40))
        }
        expectRmskinError(t, "no footer, not a ZIP", matching: isNotAPackage) {
            _ = try RmskinPackage.zipPayload(of: utf8("This is just a text file, not a package at all."))
        }
        expectRmskinError(t, "empty", matching: isNotAPackage) { _ = try RmskinPackage.zipPayload(of: Data()) }
        expectRmskinError(t, "tiny", matching: isNotAPackage) { _ = try RmskinPackage.zipPayload(of: Data([0x50])) }
        expectRmskinError(t, "footer only", matching: isNotAPackage) {
            _ = try RmskinPackage.zipPayload(of: footer(0))
        }
        // Truncated package: the footer is gone and what remains starts with PK → treated as a plain (broken) ZIP;
        // extraction rejects it later (see the extract suite).
        let truncated = (zip + footer(UInt64(zip.count))).prefix(zip.count - 5)
        t.equal(try RmskinPackage.zipPayload(of: truncated), truncated)
        // Damaged magic: not a footer, and the start is not PK → rejected.
        var badMagic = Data(repeating: 0, count: 10) + footer(10)
        badMagic[badMagic.count - 3] = 0x58
        expectRmskinError(t, "bad magic", matching: isNotAPackage) { _ = try RmskinPackage.zipPayload(of: badMagic) }
    }
}

// MARK: - ZIP central directory scan

private func rmskinZipScanTests(_ t: TestRunner) {
    t.suite("Rmskin: zip scan lists entries") {
        let zip = RmskinTestZip.make([
            .init(name: "RMSKIN.ini", data: utf8("[rmskin]")),
            .init(name: "Skins/"),
            .init(name: "Skins/A/..hidden/x.ini", data: utf8("x")),
            .init(name: "Skins\\B\\b.ini", data: utf8("bb")),
        ])
        let entries = try RmskinZip.scanCentralDirectory(zip)
        t.equal(entries.map(\.name), ["RMSKIN.ini", "Skins/", "Skins/A/..hidden/x.ini", "Skins\\B\\b.ini"])
        t.equal(entries.map(\.isDirectory), [false, true, false, false])
        t.equal(entries.map(\.uncompressedSize), [8, 0, 1, 2])
        // Trailing bytes after the archive (e.g. a footer that was not stripped) are tolerated by the scan.
        t.equal(try RmskinZip.scanCentralDirectory(zip + footer(UInt64(zip.count))).count, 4)
        t.equal(try RmskinZip.scanCentralDirectory(RmskinTestZip.make([])).count, 0)
    }

    t.suite("Rmskin: zip scan rejects unsafe entries") {
        let unsafe = ["../evil.txt", "Skins/../../evil.txt", "/etc/evil", "\\evil", "C:\\evil.txt", "c:evil",
                      "Skins\\..\\..\\evil", "a/b/..", "..", "a\u{0}b"]
        for name in unsafe {
            let zip = RmskinTestZip.make([.init(name: "ok.txt"), .init(name: name, data: utf8("x"))])
            t.throwsError("unsafe name \(name.debugDescription)") { _ = try RmskinZip.scanCentralDirectory(zip) }
        }
        let symlink = RmskinTestZip.make([.init(name: "Skins/A/link", data: utf8("/etc"), unixMode: 0o120777)])
        t.throwsError("symlink entry") { _ = try RmskinZip.scanCentralDirectory(symlink) }
        let regular = RmskinTestZip.make([.init(name: "Skins/A/file", data: utf8("x"), unixMode: 0o100644)])
        t.equal(try RmskinZip.scanCentralDirectory(regular).count, 1)

        t.equal(RmskinZip.unsafePathReason(Array("a/..b/c..".utf8)), nil)
        t.equal(RmskinZip.unsafePathReason(Array("...".utf8)), nil)
        t.equal(RmskinZip.unsafePathReason(Array("ab:c".utf8)), nil, "only X: at the start is a drive letter")
        t.check(RmskinZip.unsafePathReason(Array("a:b".utf8)) != nil)
        t.check(RmskinZip.unsafePathReason([]) != nil)
        let deep = Array(repeating: "d", count: RmskinZip.maxPathDepth + 1).joined(separator: "/")
        t.check(RmskinZip.unsafePathReason(Array(deep.utf8)) != nil, "too deep")
    }

    t.suite("Rmskin: zip scan rejects corrupt archives") {
        let zip = RmskinTestZip.make([.init(name: "a.txt", data: utf8("hello")), .init(name: "b.txt")])
        t.throwsError("too small") { _ = try RmskinZip.scanCentralDirectory(Data([0x50, 0x4B])) }
        t.throwsError("no EOCD") { _ = try RmskinZip.scanCentralDirectory(zip.prefix(zip.count - 22)) }
        t.throwsError("truncated") { _ = try RmskinZip.scanCentralDirectory(zip.prefix(zip.count / 2)) }
        // EOCD claiming more entries than exist.
        var lying = zip
        lying[lying.count - 12] = 9
        lying[lying.count - 14] = 9
        t.throwsError("entry count lies") { _ = try RmskinZip.scanCentralDirectory(lying) }
        // Directory offset out of range.
        var badOffset = zip
        badOffset[badOffset.count - 3] = 0x7F
        t.throwsError("offset out of range") { _ = try RmskinZip.scanCentralDirectory(badOffset) }
        // Huge declared sizes (zip bomb guard): one ~4 GB entry is fine, three are over the 4 GiB total.
        var bomb = RmskinTestZip.make([.init(name: "a.txt", data: utf8("x"))])
        let cd = bomb.count - 22 - (46 + 5)
        for i in 0..<4 { bomb[cd + 24 + i] = 0xFE }
        t.equal(try RmskinZip.scanCentralDirectory(bomb).first?.uncompressedSize, 0xFEFE_FEFE)
        var entries: [RmskinTestZip.Entry] = []
        for i in 0..<3 { entries.append(.init(name: "f\(i).bin", data: utf8("x"))) }
        var bigBomb = RmskinTestZip.make(entries)
        // Patch every central record's uncompressed size to ~4 GB → total over the limit.
        var position = bigBomb.count - 22 - 3 * (46 + 6)
        for _ in 0..<3 {
            for i in 0..<4 { bigBomb[position + 24 + i] = 0xFE }
            position += 46 + 6
        }
        t.throwsError("zip bomb") { _ = try RmskinZip.scanCentralDirectory(bigBomb) }
    }
}

// MARK: - Extract

private func rmskinExtractTests(_ t: TestRunner) {
    t.suite("Rmskin: extract real package") {
        let dir = t.temporaryDirectory("rmskin-extract")
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = try makePackage(clockFiles(), in: dir)
        let target = dir.appendingPathComponent("out/nested")
        let returned = try RmskinPackage.extract(package, into: target)
        t.equal(returned, target)
        t.check(exists(target.appendingPathComponent("RMSKIN.ini")))
        t.equal(text(target.appendingPathComponent("Skins/Clockwork/Digital/Digital.ini")),
                "[Rainmeter]\nUpdate=1000\n[MeterTime]\nMeter=String\n")
        t.check(exists(target.appendingPathComponent("Skins/Clockwork/@Resources/Fonts/Clock.ttf")))
        t.check(!exists(target.appendingPathComponent("__MACOSX")))
    }

    t.suite("Rmskin: extract plain zip and errors") {
        let dir = t.temporaryDirectory("rmskin-extract2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try makePackage(clockFiles(), in: dir, name: "plain.zip", withFooter: false)
        let out = dir.appendingPathComponent("plain-out")
        _ = try RmskinPackage.extract(plain, into: out)
        t.check(exists(out.appendingPathComponent("Skins/Clockwork/Analog/Analog.ini")))

        let good = try Data(contentsOf: try makePackage(clockFiles(), in: dir, name: "good.rmskin"))

        let malformed = dir.appendingPathComponent("malformed.rmskin")
        var badFooter = good
        badFooter.replaceSubrange((badFooter.count - 16)..<(badFooter.count - 8), with: footer(UInt64(good.count)).prefix(8))
        try badFooter.write(to: malformed)
        expectRmskinError(t, "malformed footer", matching: isNotAPackage) {
            _ = try RmskinPackage.extract(malformed, into: dir.appendingPathComponent("m-out"))
        }

        let truncated = dir.appendingPathComponent("truncated.rmskin")
        try good.prefix(good.count / 2).write(to: truncated)
        expectRmskinError(t, "truncated", matching: isExtractionFailed) {
            _ = try RmskinPackage.extract(truncated, into: dir.appendingPathComponent("t-out"))
        }

        let text = dir.appendingPathComponent("text.rmskin")
        try utf8("hello").write(to: text)
        expectRmskinError(t, "text file", matching: isNotAPackage) {
            _ = try RmskinPackage.extract(text, into: dir.appendingPathComponent("x-out"))
        }
        expectRmskinError(t, "missing file", matching: isUnreadable) {
            _ = try RmskinPackage.extract(dir.appendingPathComponent("missing.rmskin"), into: dir)
        }
        expectRmskinError(t, "directory as package", matching: isUnreadable) {
            _ = try RmskinPackage.extract(dir, into: dir.appendingPathComponent("d-out"))
        }
    }

    t.suite("Rmskin: extract refuses zip-slip and symlinks") {
        let dir = t.temporaryDirectory("rmskin-slip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("a/b/out")
        for (index, name) in ["../../evil.txt", "Skins/../../../evil.txt", "..\\..\\evil.txt"].enumerated() {
            let package = try rawPackage([.init(name: "RMSKIN.ini", data: utf8("[rmskin]\n")),
                                          .init(name: name, data: utf8("pwned"))], in: dir, name: "slip\(index).rmskin")
            expectRmskinError(t, "zip-slip \(name)", matching: isExtractionFailed) {
                _ = try RmskinPackage.extract(package, into: out)
            }
        }
        t.check(!exists(dir.appendingPathComponent("a/evil.txt")))
        t.check(!exists(dir.appendingPathComponent("evil.txt")))
        t.check(!exists(dir.appendingPathComponent("a/b/evil.txt")))

        let linkPackage = try rawPackage([
            .init(name: "Skins/A/link", data: utf8(dir.path), unixMode: 0o120755),
            .init(name: "Skins/A/link/evil.txt", data: utf8("pwned")),
        ], in: dir, name: "link.rmskin")
        expectRmskinError(t, "symlink", matching: isExtractionFailed) {
            _ = try RmskinPackage.extract(linkPackage, into: dir.appendingPathComponent("link-out"))
        }
        t.check(!exists(dir.appendingPathComponent("evil.txt")))

        let absolute = try rawPackage([.init(name: "/tmp/deskset-evil.txt", data: utf8("x"))], in: dir, name: "abs.rmskin")
        expectRmskinError(t, "absolute", matching: isExtractionFailed) {
            _ = try RmskinPackage.extract(absolute, into: dir.appendingPathComponent("abs-out"))
        }
    }

    t.suite("Rmskin: extract turns backslash names into folders") {
        let dir = t.temporaryDirectory("rmskin-backslash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = try rawPackage([
            .init(name: "RMSKIN.ini", data: utf8("[rmskin]\nName=Win\nLoad=Win\\Main\\Main.ini\nLoadType=Skin\n")),
            .init(name: "Skins\\Win\\Main\\Main.ini", data: utf8("[Rainmeter]\n")),
            .init(name: "Skins\\Win\\@Resources\\Images\\bg.png", data: Data([1, 2, 3])),
            .init(name: "Skins/Win/Other/Other.ini", data: utf8("[Rainmeter]\n")),
        ], in: dir)
        let out = dir.appendingPathComponent("out")
        _ = try RmskinPackage.extract(package, into: out)
        t.equal(text(out.appendingPathComponent("Skins/Win/Main/Main.ini")), "[Rainmeter]\n")
        t.check(exists(out.appendingPathComponent("Skins/Win/@Resources/Images/bg.png")))
        t.check(exists(out.appendingPathComponent("Skins/Win/Other/Other.ini")))
        let top = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        t.equal(top.filter { $0.contains("\\") }, [], "no backslash names left")

        // Installing works end to end.
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(result.installedRootConfigs, ["Win"])
        t.equal(result.skinToLoadConfig, "Win\\Main")
        t.equal(result.skinToLoadFile, "Main.ini")
    }

    t.suite("Rmskin: sanitize removes stray symlinks") {
        let dir = t.temporaryDirectory("rmskin-sanitize")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root")
        try writeTree([("Skins/A/a.ini", utf8("x"))], at: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Skins/A/out"),
                                                   withDestinationURL: dir)
        let warnings = try RmskinZip.sanitizeExtractedTree(at: root)
        t.equal(warnings.count, 1)
        t.check((try? FileManager.default.destinationOfSymbolicLink(
            atPath: root.appendingPathComponent("Skins/A/out").path)) == nil, "symlink removed")
        t.check(exists(root.appendingPathComponent("Skins/A/a.ini")))
    }
}

// MARK: - Inspect

private func rmskinInspectTests(_ t: TestRunner) {
    t.suite("Rmskin: inspect") {
        let dir = t.temporaryDirectory("rmskin-inspect")
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = clockFiles()
        files += [
            ("RMSKIN.bmp", bitmap(width: 400, height: 60)),
            ("Skins/Second/Main.ini", utf8("[Rainmeter]\n")),
            ("Skins/.hidden/x.ini", utf8("x")),
            ("Skins/.DS_Store", Data([0])),
            ("Skins/@Vault/Stuff/readme.txt", utf8("vault")),
            ("Skins/loose.txt", utf8("loose")),
            ("Layouts/Clockwork Desk/Rainmeter.ini", utf8("[Rainmeter]\nSkinPath=C:\\x\n")),
            ("Plugins/64bit/CursorColor.dll", Data([0x4D, 0x5A])),
            ("Plugins/32bit/CursorColor.dll", Data([0x4D, 0x5A])),
            ("Plugins/64bit/Other.DLL", Data([0x4D, 0x5A])),
        ]
        let package = try makePackage(files, in: dir)
        let before = temporaryItems(t)
        let inspection = try RmskinPackage.inspect(package)
        t.equal(inspection.manifest.name, "Clockwork")
        t.equal(inspection.manifest.load, "Clockwork\\Digital\\Digital.ini")
        t.equal(inspection.rootConfigs, ["Clockwork", "Second"])
        t.equal(inspection.layouts, ["Clockwork Desk"])
        t.equal(inspection.containsLayouts, true)
        t.equal(inspection.containsPlugins, true)
        t.equal(inspection.pluginNames, ["CursorColor.dll", "Other.DLL"])
        t.equal(inspection.headerImageURL?.lastPathComponent, "RMSKIN.bmp")
        t.check(inspection.headerImageURL.map(exists) ?? false)
        t.check(inspection.warnings.contains { $0.contains("CursorColor.dll") }, "plugin warning")
        t.check(inspection.warnings.contains { $0.contains("loose.txt") }, "loose file warning")
        t.equal(inspection.legacyFonts, [])
        t.equal(inspection.containsAddons, false)

        let skins = dir.appendingPathComponent("UserSkins")
        try writeTree([("clockwork/old.ini", utf8("x"))], at: skins)
        t.equal(inspection.existingRootConfigs(in: skins), ["Clockwork"])
        t.equal(inspection.existingRootConfigs(in: dir.appendingPathComponent("none")), [])

        t.check(exists(inspection.temporaryDirectory))
        t.check(inspection.packageRoot.path.hasPrefix(inspection.temporaryDirectory.path))
        inspection.cleanup()
        t.check(!exists(inspection.temporaryDirectory), "cleanup removes the temp folder")
        inspection.cleanup()
        t.equal(temporaryLeftovers(t, since: before), [], "no temp leftovers")
    }

    t.suite("Rmskin: inspect minimal / nested / missing manifest") {
        let dir = t.temporaryDirectory("rmskin-inspect2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let minimal = try makePackage([("RMSKIN.ini", utf8("[rmskin]\nName=M\n")),
                                       ("Skins/M/M.ini", utf8("[Rainmeter]\n"))], in: dir, name: "m.rmskin")
        let a = try RmskinPackage.inspect(minimal)
        defer { a.cleanup() }
        t.equal(a.rootConfigs, ["M"])
        t.equal(a.containsPlugins, false)
        t.equal(a.containsLayouts, false)
        t.equal(a.headerImageURL, nil)
        t.equal(a.warnings, [])

        // Everything wrapped in one folder (hand-made zip).
        let nested = try makePackage([("Wrapper/RMSKIN.ini", utf8("[rmskin]\nName=N\n")),
                                      ("Wrapper/Skins/N/N.ini", utf8("[Rainmeter]\n"))], in: dir, name: "n.rmskin")
        let b = try RmskinPackage.inspect(nested)
        defer { b.cleanup() }
        t.equal(b.manifest.name, "N")
        t.equal(b.rootConfigs, ["N"])

        // Lower-case manifest name and folder names.
        let lower = try makePackage([("rmskin.ini", utf8("[rmskin]\nName=L\n")),
                                     ("skins/L/L.ini", utf8("[Rainmeter]\n"))], in: dir, name: "l.rmskin")
        let c = try RmskinPackage.inspect(lower)
        defer { c.cleanup() }
        t.equal(c.manifest.name, "L")
        t.equal(c.rootConfigs, ["L"])

        let before = temporaryItems(t)
        let noManifest = try makePackage([("Skins/X/X.ini", utf8("[Rainmeter]\n"))], in: dir, name: "x.rmskin")
        expectRmskinError(t, "missing manifest", matching: { $0 == .missingManifest }) {
            _ = try RmskinPackage.inspect(noManifest)
        }
        let empty = try rawPackage([], in: dir, name: "empty.rmskin")
        t.throwsError("empty zip") { _ = try RmskinPackage.inspect(empty) }
        t.equal(temporaryLeftovers(t, since: before), [], "temp folder removed when inspect throws")
    }

    t.suite("Rmskin: inspect legacy fonts and addons") {
        let dir = t.temporaryDirectory("rmskin-legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = try makePackage([
            ("RMSKIN.ini", utf8("[rmskin]\nName=Old\n")),
            ("Skins/Old/Old.ini", utf8("[Rainmeter]\n")),
            ("Fonts/Legacy.ttf", Data([0, 1, 0, 0])),
            ("Fonts/readme.txt", utf8("x")),
            ("Addons/Tool/tool.exe", Data([0x4D, 0x5A])),
        ], in: dir)
        let inspection = try RmskinPackage.inspect(package)
        defer { inspection.cleanup() }
        t.equal(inspection.legacyFonts.map(\.lastPathComponent), ["Legacy.ttf"])
        t.equal(inspection.containsAddons, true)
        t.check(inspection.warnings.contains { $0.contains("add-on") })

        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        t.check(exists(skins.appendingPathComponent("Old/@Resources/Fonts/Legacy.ttf")), "legacy font placed")
        t.check(!exists(skins.appendingPathComponent("Addons")))
        t.check(!exists(skins.appendingPathComponent("Old/Addons")))
        t.equal(result.installedRootConfigs, ["Old"])
    }
}

// MARK: - Install

private func rmskinInstallTests(_ t: TestRunner) {
    t.suite("Rmskin: install fresh") {
        let dir = t.temporaryDirectory("rmskin-install")
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = clockFiles()
        files += [("Skins/Clockwork/.DS_Store", Data([0])), ("Skins/Clockwork/Digital/.backup.ini", utf8("x"))]
        let package = try makePackage(files, in: dir)
        let skins = dir.appendingPathComponent("App Support/Skins")
        let before = temporaryItems(t)
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(temporaryLeftovers(t, since: before), [], "temp folders cleaned up")

        t.equal(result.manifest.name, "Clockwork")
        t.equal(result.installedRootConfigs, ["Clockwork"])
        t.equal(result.skinToLoadConfig, "Clockwork\\Digital")
        t.equal(result.skinToLoadFile, "Digital.ini")
        t.check(result.skinToLoad?.config == "Clockwork\\Digital" && result.skinToLoad?.file == "Digital.ini")
        t.equal(result.layoutToLoad, nil)
        t.equal(result.containsPlugins, false)
        t.equal(result.backupLocations, [])
        t.equal(result.preservedVariableCount, 0)
        t.equal(result.warnings, [])

        t.equal(text(skins.appendingPathComponent("Clockwork/Digital/Digital.ini")),
                "[Rainmeter]\nUpdate=1000\n[MeterTime]\nMeter=String\n")
        t.equal(text(skins.appendingPathComponent("Clockwork/@Resources/Variables.inc")),
                "[Variables]\nColor=255,255,255\nSize=12\n")
        t.check(exists(skins.appendingPathComponent("Clockwork/@Resources/Fonts/Clock.ttf")))
        t.check(!exists(skins.appendingPathComponent("Clockwork/.DS_Store")), "hidden files skipped")
        t.check(!exists(skins.appendingPathComponent("Clockwork/Digital/.backup.ini")), "hidden files skipped")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: skins.path)) ?? [])
        t.equal(leftovers, ["Clockwork"], "no staging folders left")
    }

    t.suite("Rmskin: install UTF-16LE RMSKIN.ini") {
        let dir = t.temporaryDirectory("rmskin-utf16")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = "[rmskin]\r\nName=Uhr 時計\r\nAuthor=Ä\r\nVersion=1\r\nLoadType=Skin\r\nLoad=Uhr\\Uhr.ini\r\n"
        let package = try makePackage([("RMSKIN.ini", utf16LE(manifest)),
                                       ("Skins/Uhr/Uhr.ini", utf8("[Rainmeter]\n"))], in: dir)
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(result.manifest.name, "Uhr 時計")
        t.equal(result.manifest.author, "Ä")
        t.equal(result.skinToLoadConfig, "Uhr")
        t.equal(result.skinToLoadFile, "Uhr.ini")
    }

    t.suite("Rmskin: install Unicode paths") {
        let dir = t.temporaryDirectory("rmskin-unicode")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = "[rmskin]\nName=Größe\nLoadType=Skin\nLoad=Größe 時計\\Übersicht\\Größe.ini\n"
            + "VariableFiles=Größe 時計\\@Resources\\Välues.inc\n"
        let package = try makePackage([("RMSKIN.ini", utf8(manifest)),
                                       ("Skins/Größe 時計/Übersicht/Größe.ini", utf8("[Rainmeter]\n")),
                                       ("Skins/Größe 時計/@Resources/Välues.inc", utf8("[Variables]\nA=new\n"))],
                                      in: dir)
        let skins = dir.appendingPathComponent("Skins")
        try writeTree([("Größe 時計/@Resources/Välues.inc", utf8("[Variables]\nA=mine\n"))], at: skins)
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(result.installedRootConfigs, ["Größe 時計"])
        t.equal(result.skinToLoadConfig, "Größe 時計\\Übersicht")
        t.equal(result.skinToLoadFile, "Größe.ini")
        t.equal(text(skins.appendingPathComponent("Größe 時計/@Resources/Välues.inc")), "[Variables]\nA=mine\n")
    }

    t.suite("Rmskin: install package with plugins") {
        let dir = t.temporaryDirectory("rmskin-plugins")
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = clockFiles()
        files += [("Plugins/32bit/Fancy.dll", Data([0x4D, 0x5A])), ("Plugins/64bit/Fancy.dll", Data([0x4D, 0x5A]))]
        let package = try makePackage(files, in: dir)
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(result.containsPlugins, true)
        t.equal(result.pluginNames, ["Fancy.dll"])
        t.check(result.warnings.contains { $0.contains("Fancy.dll") })
        t.equal(result.installedRootConfigs, ["Clockwork"])
        t.check(!exists(skins.appendingPathComponent("Plugins")))
        t.check(!exists(skins.appendingPathComponent("@Vault/Plugins")), "plugins are not archived")
        t.equal(((try? FileManager.default.contentsOfDirectory(atPath: skins.path)) ?? []), ["Clockwork"])
    }

    t.suite("Rmskin: install @Vault merges without overwriting") {
        let dir = t.temporaryDirectory("rmskin-vault")
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = clockFiles()
        files += [("Skins/@Vault/MyFonts/New.ttf", Data([1])), ("Skins/@Vault/MyFonts/Existing.ttf", utf8("package")),
                  ("@Vault/Top/top.txt", utf8("top"))]
        let package = try makePackage(files, in: dir)
        let skins = dir.appendingPathComponent("Skins")
        try writeTree([("@Vault/MyFonts/Existing.ttf", utf8("user"))], at: skins)
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(result.installedRootConfigs, ["Clockwork"], "@Vault is not a root config")
        t.check(exists(skins.appendingPathComponent("@Vault/MyFonts/New.ttf")))
        t.equal(text(skins.appendingPathComponent("@Vault/MyFonts/Existing.ttf")), "user")
        t.equal(text(skins.appendingPathComponent("@Vault/Top/top.txt")), "top")
    }

    t.suite("Rmskin: nothing to install") {
        let dir = t.temporaryDirectory("rmskin-nothing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let skins = dir.appendingPathComponent("Skins")
        let manifestOnly = try makePackage([("RMSKIN.ini", utf8("[rmskin]\nName=Empty\n"))], in: dir, name: "e.rmskin")
        expectRmskinError(t, "manifest only", matching: { $0 == .nothingToInstall }) {
            _ = try RmskinInstaller.install(packageURL: manifestOnly, skinsDirectory: skins)
        }
        let vaultOnly = try makePackage([("RMSKIN.ini", utf8("[rmskin]\n")), ("Skins/@Vault/x.txt", utf8("x")),
                                         ("Skins/file.txt", utf8("x"))], in: dir, name: "v.rmskin")
        expectRmskinError(t, "vault only", matching: { $0 == .nothingToInstall }) {
            _ = try RmskinInstaller.install(packageURL: vaultOnly, skinsDirectory: skins)
        }
        let layoutOnly = try makePackage([("RMSKIN.ini", utf8("[rmskin]\nLoadType=Layout\nLoad=Desk\n")),
                                          ("Layouts/Desk/Rainmeter.ini", utf8("[Rainmeter]\n"))], in: dir,
                                         name: "l.rmskin")
        expectRmskinError(t, "layout only without a layouts directory", matching: { $0 == .nothingToInstall }) {
            _ = try RmskinInstaller.install(packageURL: layoutOnly, skinsDirectory: skins)
        }
        let layouts = dir.appendingPathComponent("Layouts")
        let result = try RmskinInstaller.install(packageURL: layoutOnly, skinsDirectory: skins,
                                                 layoutsDirectory: layouts)
        t.equal(result.installedLayouts, ["Desk"])
        t.equal(result.layoutToLoad, "Desk")
        t.equal(result.installedRootConfigs, [])
        let missing = try makePackage([("Skins/X/X.ini", utf8("[Rainmeter]\n"))], in: dir, name: "x.rmskin")
        expectRmskinError(t, "missing manifest", matching: { $0 == .missingManifest }) {
            _ = try RmskinInstaller.install(packageURL: missing, skinsDirectory: skins)
        }
        t.check(!exists(skins.appendingPathComponent("X")))
    }
}

// MARK: - Upgrade: backup + VariableFiles

private func rmskinUpgradeTests(_ t: TestRunner) {
    t.suite("Rmskin: upgrade with backup and VariableFiles") {
        let dir = t.temporaryDirectory("rmskin-upgrade")
        defer { try? FileManager.default.removeItem(at: dir) }
        let skins = dir.appendingPathComponent("Skins")
        let backup = dir.appendingPathComponent("Backup")

        // v1 installed, then customised by the user.
        let v1 = try makePackage(clockFiles(), in: dir, name: "v1.rmskin")
        _ = try RmskinInstaller.install(packageURL: v1, skinsDirectory: skins, backupDirectory: backup)
        let variablesURL = skins.appendingPathComponent("Clockwork/@Resources/Variables.inc")
        try utf8("""
        [Variables]
        Color="0,128,255"
        Size=20
        Removed=gone
        Empty=user
        """).write(to: variablesURL)
        try utf8("mine").write(to: skins.appendingPathComponent("Clockwork/Digital/user-notes.txt"))
        try utf8("hidden").write(to: skins.appendingPathComponent("Clockwork/.user-hidden"))

        // v2: new default values, a new key, a comment, CRLF line endings, UTF-16LE encoding, a removed skin.
        let v2Variables = "; Settings\r\n[Variables]\r\nColor=255,255,255\r\nSize = 12\r\nNewKey=default\r\nEmpty=\r\n"
        let v2Files: [(String, Data)] = [
            ("RMSKIN.ini", utf8(clockManifest.replacingOccurrences(of: "Version=1.2", with: "Version=2.0"))),
            ("Skins/Clockwork/Digital/Digital.ini", utf8("[Rainmeter]\nUpdate=500\n")),
            ("Skins/Clockwork/@Resources/Variables.inc", utf16LE(v2Variables)),
        ]
        let v2 = try makePackage(v2Files, in: dir, name: "v2.rmskin")

        let result = try RmskinInstaller.install(packageURL: v2, skinsDirectory: skins, backupDirectory: backup)
        t.equal(result.manifest.version, "2.0")
        t.equal(result.installedRootConfigs, ["Clockwork"])
        t.equal(result.backupLocations.map(\.path), [backup.appendingPathComponent("Clockwork").path])
        t.equal(result.preservedVariableCount, 3)

        // The old version is in the backup, complete with the user's files (hidden ones too).
        t.equal(text(backup.appendingPathComponent("Clockwork/Digital/user-notes.txt")), "mine")
        t.check(exists(backup.appendingPathComponent("Clockwork/Analog/Analog.ini")))
        t.check(exists(backup.appendingPathComponent("Clockwork/.user-hidden")))

        // The root config was replaced: removed skins and user files are gone from the live folder.
        t.check(!exists(skins.appendingPathComponent("Clockwork/Analog")))
        t.check(!exists(skins.appendingPathComponent("Clockwork/Digital/user-notes.txt")))
        t.equal(text(skins.appendingPathComponent("Clockwork/Digital/Digital.ini")), "[Rainmeter]\nUpdate=500\n")

        // Variables: user values for keys in both files, new defaults for new keys, removed keys dropped,
        // comments / CRLF / spacing / UTF-16LE kept.
        let merged = try Data(contentsOf: variablesURL)
        t.equal(Array(merged.prefix(2)), [0xFF, 0xFE], "UTF-16LE BOM kept")
        t.equal(TextDecoding.decode(merged),
                "; Settings\r\n[Variables]\r\nColor=\"0,128,255\"\r\nSize = 20\r\nNewKey=default\r\nEmpty=user\r\n")
        let doc = IniDocument.parse(TextDecoding.decode(merged))
        t.equal(doc.section(named: "Variables")?["Color"], "0,128,255")
        t.equal(doc.section(named: "Variables")?["Removed"], nil)

        // Upgrading again keeps the earlier backup and makes a new one.
        _ = try RmskinInstaller.install(packageURL: v2, skinsDirectory: skins, backupDirectory: backup)
        t.check(exists(backup.appendingPathComponent("Clockwork (2)")))
        t.check(exists(backup.appendingPathComponent("Clockwork/Digital/user-notes.txt")))
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: skins.path)) ?? []).sorted()
        t.equal(names, ["Clockwork"], "no staging folders left")
    }

    t.suite("Rmskin: empty user value is preserved") {
        let dir = t.temporaryDirectory("rmskin-emptyvar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let skins = dir.appendingPathComponent("Skins")
        try writeTree([("Clockwork/@Resources/Variables.inc", utf8("[Variables]\nColor=\nSize=30\n"))], at: skins)
        let package = try makePackage(clockFiles(), in: dir)
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(text(skins.appendingPathComponent("Clockwork/@Resources/Variables.inc")),
                "[Variables]\nColor=\nSize=30\n")
        t.equal(result.preservedVariableCount, 2)
        t.equal(result.backupLocations, [], "no backup directory → old folder deleted")
        t.equal(((try? FileManager.default.contentsOfDirectory(atPath: skins.path)) ?? []), ["Clockwork"])
    }

    t.suite("Rmskin: VariableFiles edge cases") {
        let dir = t.temporaryDirectory("rmskin-varedge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let skins = dir.appendingPathComponent("Skins")
        // Wrong case in the manifest, forward slashes, a leading Skins\, a missing file, an outside path.
        let manifest = """
        [rmskin]
        Name=Clockwork
        VariableFiles=clockwork/@resources/VARIABLES.inc | Skins\\Clockwork\\Digital\\Settings.inc | Clockwork\\Missing.inc | Other\\x.inc | ..\\..\\etc\\passwd
        """
        var files = clockFiles(manifest: manifest)
        files.append(("Skins/Clockwork/Digital/Settings.inc", utf8("[Variables]\nMode=default\n")))
        try writeTree([("Clockwork/@Resources/Variables.inc", utf8("[variables]\ncolor=1,2,3\n")),
                       ("Clockwork/Digital/Settings.inc", utf8("[Variables]\nMode=user\n")),
                       ("Clockwork/Missing.inc", utf8("[Variables]\nX=1\n"))], at: skins)
        let package = try makePackage(files, in: dir)
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(text(skins.appendingPathComponent("Clockwork/@Resources/Variables.inc")),
                "[Variables]\nColor=1,2,3\nSize=12\n", "case-insensitive section/key match, package spelling kept")
        t.equal(text(skins.appendingPathComponent("Clockwork/Digital/Settings.inc")), "[Variables]\nMode=user\n")
        t.check(!exists(skins.appendingPathComponent("Clockwork/Missing.inc")), "not restored when not shipped")
        t.check(result.warnings.contains { $0.contains("Other\\x.inc") })
        t.check(result.warnings.contains { $0.contains("passwd") })
        t.equal(result.preservedVariableCount, 2)
    }

    t.suite("Rmskin: case-insensitive existing root config") {
        let dir = t.temporaryDirectory("rmskin-case")
        defer { try? FileManager.default.removeItem(at: dir) }
        let skins = dir.appendingPathComponent("Skins")
        let backup = dir.appendingPathComponent("Backup")
        try writeTree([("CLOCKWORK/old.txt", utf8("old"))], at: skins)
        let package = try makePackage(clockFiles(), in: dir)
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins, backupDirectory: backup)
        t.equal(result.backupLocations.map(\.lastPathComponent), ["Clockwork"])
        t.equal(text(backup.appendingPathComponent("Clockwork/old.txt")), "old")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: skins.path)) ?? [])
        t.equal(names, ["Clockwork"], "package spelling wins")
    }
}

// MARK: - MergeSkins

private func rmskinMergeTests(_ t: TestRunner) {
    t.suite("Rmskin: MergeSkins keeps existing files") {
        let dir = t.temporaryDirectory("rmskin-merge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let skins = dir.appendingPathComponent("Skins")
        let backup = dir.appendingPathComponent("Backup")
        try writeTree([
            ("Clockwork/Digital/Digital.ini", utf8("old digital")),
            ("Clockwork/Extra/Extra.ini", utf8("user extra")),
            ("Clockwork/@Resources/Variables.inc", utf8("[Variables]\nSize=99\n")),
        ], at: skins)
        let manifest = "[rmskin]\nName=Patch\nMergeSkins=1\nVariableFiles=Clockwork\\@Resources\\Variables.inc\n"
        let package = try makePackage([
            ("RMSKIN.ini", utf8(manifest)),
            ("Skins/Clockwork/Digital/Digital.ini", utf8("patched digital")),
            ("Skins/Clockwork/New/New.ini", utf8("new")),
            ("Skins/Clockwork/@Resources/Variables.inc", utf8("[Variables]\nSize=12\nAdded=1\n")),
        ], in: dir)
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins, backupDirectory: backup)
        t.equal(result.manifest.mergeSkins, true)
        t.equal(text(skins.appendingPathComponent("Clockwork/Digital/Digital.ini")), "patched digital")
        t.equal(text(skins.appendingPathComponent("Clockwork/Extra/Extra.ini")), "user extra", "existing kept")
        t.equal(text(skins.appendingPathComponent("Clockwork/New/New.ini")), "new")
        t.equal(text(skins.appendingPathComponent("Clockwork/@Resources/Variables.inc")),
                "[Variables]\nSize=99\nAdded=1\n")
        t.check(result.warnings.contains { $0.contains("MergeSkins") }, "incompatible options reported")
        // The backup is a full copy of the state before merging.
        t.equal(text(backup.appendingPathComponent("Clockwork/Digital/Digital.ini")), "old digital")
        t.equal(text(backup.appendingPathComponent("Clockwork/Extra/Extra.ini")), "user extra")

        // Merge into a folder that does not exist yet = plain install.
        let fresh = dir.appendingPathComponent("Fresh")
        let r2 = try RmskinInstaller.install(packageURL: package, skinsDirectory: fresh)
        t.equal(r2.backupLocations, [])
        t.equal(text(fresh.appendingPathComponent("Clockwork/New/New.ini")), "new")
    }
}

// MARK: - Layouts

private func rmskinLayoutTests(_ t: TestRunner) {
    t.suite("Rmskin: layouts installed without [Rainmeter] options") {
        let dir = t.temporaryDirectory("rmskin-layouts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let layoutIni = "[Rainmeter]\r\nSkinPath=C:\\Evil\\\r\nConfigEditor=notepad.exe\r\n; keep me\r\n\r\n"
            + "[Clockwork\\Digital]\r\nActive=1\r\nWindowX=100\r\n[Rainmeter]\r\nLogging=1\r\n"
        let manifest = "[rmskin]\nName=Suite\nLoadType=Layout\nLoad=clockwork desk\n"
        var files = clockFiles(manifest: manifest)
        files += [("Layouts/Clockwork Desk/Rainmeter.ini", utf16LE(layoutIni)),
                  ("Layouts/Clockwork Desk/Wallpaper.bmp", Data([0x42, 0x4D])),
                  ("Layouts/Second/Rainmeter.ini", utf8("[Clockwork\\Analog]\nActive=1\n")),
                  ("Layouts/stray.ini", utf8("x"))]
        let package = try makePackage(files, in: dir)
        let skins = dir.appendingPathComponent("Skins")
        let layouts = dir.appendingPathComponent("Layouts")
        let backup = dir.appendingPathComponent("Backup")
        try writeTree([("Second/Rainmeter.ini", utf8("user layout"))], at: layouts)

        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins,
                                                 layoutsDirectory: layouts, backupDirectory: backup)
        t.equal(result.installedLayouts, ["Clockwork Desk", "Second"])
        t.equal(result.layoutToLoad, "Clockwork Desk", "on-disk spelling")
        t.equal(result.skinToLoadConfig, nil)
        let installed = try Data(contentsOf: layouts.appendingPathComponent("Clockwork Desk/Rainmeter.ini"))
        t.equal(Array(installed.prefix(2)), [0xFF, 0xFE], "encoding kept")
        t.equal(TextDecoding.decode(installed),
                "[Rainmeter]\r\n; keep me\r\n\r\n[Clockwork\\Digital]\r\nActive=1\r\nWindowX=100\r\n[Rainmeter]\r\n")
        t.check(exists(layouts.appendingPathComponent("Clockwork Desk/Wallpaper.bmp")))
        t.equal(text(layouts.appendingPathComponent("Second/Rainmeter.ini")), "[Clockwork\\Analog]\nActive=1\n")
        t.equal(text(backup.appendingPathComponent("@Layouts/Second/Rainmeter.ini")), "user layout")
        t.equal(result.backupLocations.map(\.path), [backup.appendingPathComponent("@Layouts/Second").path])
        t.check(result.warnings.contains { $0.contains("stray.ini") })
        t.check(!exists(layouts.appendingPathComponent("stray.ini")))

        // Without a layouts directory the layouts are skipped and not loaded.
        let skins2 = dir.appendingPathComponent("Skins2")
        let r2 = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins2)
        t.equal(r2.installedLayouts, [])
        t.equal(r2.layoutToLoad, nil)
        t.check(r2.warnings.contains { $0.contains("not installed") })
    }
}

// MARK: - Load / LoadType

private func rmskinLoadTests(_ t: TestRunner) {
    t.suite("Rmskin: Load resolution") {
        let dir = t.temporaryDirectory("rmskin-load")
        defer { try? FileManager.default.removeItem(at: dir) }
        let skins = dir.appendingPathComponent("Skins")
        try writeTree([("Clock/Sub/Deep/Skin.ini", utf8("[Rainmeter]\n")), ("Clock/Top.ini", utf8("x")),
                       ("Existing/Old.ini", utf8("x"))], at: skins)
        let layouts = dir.appendingPathComponent("Layouts")
        try writeTree([("My Desk/Rainmeter.ini", utf8("x"))], at: layouts)

        func resolve(_ type: String, _ load: String, layoutsDir: URL? = layouts) -> RmskinInstallResult {
            var manifest = RmskinManifest()
            manifest.loadType = type
            manifest.load = load
            var result = RmskinInstallResult(manifest: manifest)
            result.installedRootConfigs = ["Clock"]
            result.installedLayouts = ["My Desk"]
            RmskinInstaller.resolveLoad(manifest, skinsDirectory: skins, layoutsDirectory: layoutsDir, result: &result)
            return result
        }
        var r = resolve("Skin", "Clock\\Sub\\Deep\\Skin.ini")
        t.equal(r.skinToLoadConfig, "Clock\\Sub\\Deep")
        t.equal(r.skinToLoadFile, "Skin.ini")
        t.equal(r.warnings, [])
        r = resolve("skin", "clock/sub/deep/SKIN.INI")
        t.equal(r.skinToLoadConfig, "Clock\\Sub\\Deep", "on-disk spelling")
        t.equal(r.skinToLoadFile, "Skin.ini")
        r = resolve("", "\\Clock\\\\Top.ini\\")
        t.equal(r.skinToLoadConfig, "Clock", "LoadType inferred from .ini; empty components ignored")
        t.equal(r.skinToLoadFile, "Top.ini")
        // "You may choose one of the skin '.ini' files in your package": a skin that was already in the library but
        // is not part of this package is never activated.
        r = resolve("Skin", "Existing\\Old.ini")
        t.equal(r.skinToLoadConfig, nil, "a library skin outside the package is not loaded")
        t.equal(r.warnings.count, 1)
        r = resolve("Skin", "Clock\\Missing.ini")
        t.equal(r.skinToLoadConfig, nil)
        t.equal(r.warnings.count, 1)
        r = resolve("Skin", "Top.ini")
        t.equal(r.skinToLoadConfig, nil, "a file without a config folder")
        r = resolve("Skin", "Clock\\..\\..\\Top.ini")
        t.equal(r.skinToLoadConfig, nil)
        t.equal(r.warnings.count, 1)
        r = resolve("Skin", "Clock\\Sub")
        t.equal(r.skinToLoadConfig, nil, "a folder is not a skin file")
        r = resolve("Layout", "my desk")
        t.equal(r.layoutToLoad, "My Desk")
        r = resolve("", "My Desk")
        t.equal(r.layoutToLoad, "My Desk", "LoadType inferred: not .ini → layout")
        r = resolve("Layout", "Nope")
        t.equal(r.layoutToLoad, nil)
        t.equal(r.warnings.count, 1)
        r = resolve("Layout", "My Desk", layoutsDir: nil)
        t.equal(r.layoutToLoad, nil)
        r = resolve("Layout", "a\\b")
        t.equal(r.layoutToLoad, nil)
        r = resolve("Theme", "My Desk")
        t.equal(r.layoutToLoad, nil)
        t.check(r.warnings.first?.contains("LoadType") ?? false)
        r = resolve("Skin", "")
        t.equal(r.skinToLoadConfig, nil)
        t.equal(r.warnings, [], "no Load → nothing to do")
    }
}

// MARK: - INI text rewriting and encodings

private func rmskinTextTests(_ t: TestRunner) {
    t.suite("Rmskin: preserving variable values") {
        let old = """
        ; user file
        Orphan=ignored
        [Variables]
        Color="1,2,3"
        Size=20
        Size=21
        Font = Segoe UI
        Blank=
        [Other]
        Key=old other
        [variables]
        Late=late value
        """
        let new = """
        [Variables]
        ; comment stays
        COLOR=255,255,255
        Size=12
        Size=13
        Font=Arial
        Blank=default
        Fresh=new
        Late=default
        [Other]
        Key=new other
        [NoOld]
        Key=x
        Orphan=y
        """
        let (merged, count) = RmskinIniText.preservingValues(from: old, into: new)
        t.equal(merged, """
        [Variables]
        ; comment stays
        COLOR="1,2,3"
        Size=20
        Size=13
        Font=Segoe UI
        Blank=
        Fresh=new
        Late=late value
        [Other]
        Key=new other
        [NoOld]
        Key=x
        Orphan=y
        """, "only [Variables] values are variables; other sections stay as the package ships them")
        t.equal(count, 5)
        let (same, zero) = RmskinIniText.preservingValues(from: new, into: new)
        t.equal(same, new)
        t.equal(zero, 0)
        t.equal(RmskinIniText.preservingValues(from: "", into: "").text, "")
        t.equal(RmskinIniText.preservingValues(from: "[Variables]\nk=1", into: "[Variables]\r\nk=2\r\n").text,
                "[Variables]\r\nk=1\r\n")
        t.equal(RmskinIniText.preservingValues(from: "[Variables]\rk=1\r", into: "[Variables]\rk=2\r").text,
                "[Variables]\rk=1\r")
        t.equal(RmskinIniText.preservingValues(from: "[Variables]\nk = 1", into: "[Variables]\nk =   2  ").text,
                "[Variables]\nk =   1")
        t.equal(RmskinIniText.preservingValues(from: "[Variables]\nk=a=b", into: "[Variables]\nk=c").text,
                "[Variables]\nk=a=b")
        t.equal(RmskinIniText.preservingValues(from: "[Variables\nk=1", into: "[Variables]\nk=2").text,
                "[Variables]\nk=2")
        // Any section can be named explicitly.
        t.equal(RmskinIniText.preservingValues(from: "[A]\nk=1", into: "[A]\nk=2", section: "a").text, "[A]\nk=1")
        t.equal(RmskinIniText.preservingValues(from: "[A]\nk=1", into: "[A]\nk=2").text, "[A]\nk=2")
    }

    t.suite("Rmskin: removing [Rainmeter] options") {
        let (stripped, removed) = RmskinIniText.removingOptions(ofSection: "Rainmeter", from: """
        [rainmeter]
        SkinPath=x
        ;Comment=kept
        [Skin]
        A=1
        [Rainmeter]
        B=2
        """)
        // The removed lines go with their own line breaks; the header keeps its own.
        t.equal(stripped, "[rainmeter]\n;Comment=kept\n[Skin]\nA=1\n[Rainmeter]\n")
        t.equal(removed, 2)
        t.equal(RmskinIniText.removingOptions(ofSection: "Rainmeter", from: "[Skin]\nA=1").removed, 0)
    }

    t.suite("Rmskin: text encodings round-trip") {
        let sample = "[Variables]\r\nName=Grüße 時計\r\n"
        let cases: [(Data, RmskinTextEncoding)] = [
            (utf8(sample), .utf8),
            (Data([0xEF, 0xBB, 0xBF]) + utf8(sample), .utf8BOM),
            (utf16LE(sample), .utf16LEBOM),
            (utf16LE(sample, bom: false), .utf16LE),
            (Data([0xFE, 0xFF]) + (sample.data(using: .utf16BigEndian) ?? Data()), .utf16BEBOM),
        ]
        for (data, expected) in cases {
            let detected = RmskinTextEncoding.detect(data)
            t.equal(detected, expected)
            t.equal(detected.encode(TextDecoding.decode(data)), data, "round trip \(expected)")
        }
        let ansi = "[Variables]\nName=Café\n".data(using: .windowsCP1252) ?? Data()
        t.equal(RmskinTextEncoding.detect(ansi), .windows1252)
        t.equal(RmskinTextEncoding.windows1252.encode("Café"), "Café".data(using: .windowsCP1252))
        // Text Windows-1252 cannot hold falls back to UTF-16 LE with BOM.
        let fallback = RmskinTextEncoding.windows1252.encode("時計")
        t.equal(Array(fallback.prefix(2)), [0xFF, 0xFE])
        t.equal(TextDecoding.decode(fallback), "時計")

        let dir = t.temporaryDirectory("rmskin-encoding")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v.inc")
        try ansi.write(to: url)
        try RmskinTextEncoding.rewriteFile(at: url) { $0.replacingOccurrences(of: "Café", with: "Crème") }
        t.equal(try Data(contentsOf: url), "[Variables]\nName=Crème\n".data(using: .windowsCP1252))
        try RmskinTextEncoding.rewriteFile(at: url) { _ in nil }
        t.equal(try Data(contentsOf: url), "[Variables]\nName=Crème\n".data(using: .windowsCP1252), "nil = untouched")
    }

    t.suite("Rmskin: path helpers") {
        t.equal(RmskinFiles.pathComponents("a\\b/c.ini"), ["a", "b", "c.ini"])
        t.equal(RmskinFiles.pathComponents("\\\\a\\.\\b\\"), ["a", "b"])
        t.equal(RmskinFiles.pathComponents("a\\..\\b"), nil)
        t.equal(RmskinFiles.pathComponents(""), [])
        let dir = t.temporaryDirectory("rmskin-paths")
        defer { try? FileManager.default.removeItem(at: dir) }
        t.equal(RmskinFiles.uniqueURL(in: dir, baseName: "X").lastPathComponent, "X")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("X"), withIntermediateDirectories: true)
        try utf8("x").write(to: dir.appendingPathComponent("X (2)"))
        t.equal(RmskinFiles.uniqueURL(in: dir, baseName: "X").lastPathComponent, "X (3)")
        t.equal(RmskinFiles.resolveCaseInsensitively(["x"], from: dir), ["X"])
        t.equal(RmskinFiles.resolveCaseInsensitively(["x (2)", "y"], from: dir), nil, "a file is not a folder")
        t.equal(RmskinFiles.resolveCaseInsensitively([], from: dir), [])
    }
}

// MARK: - Robustness

private func rmskinRobustnessTests(_ t: TestRunner) {
    t.suite("Rmskin: random bytes never crash") {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }
        let valid = RmskinTestZip.make([.init(name: "RMSKIN.ini", data: utf8("[rmskin]\nName=x\n")),
                                        .init(name: "Skins/A/A.ini", data: utf8("[Rainmeter]\n"))])
        var survived = 0
        for round in 0..<3_000 {
            var data: Data
            switch round % 4 {
            case 0:
                data = Data((0..<Int(next() % 300)).map { _ in UInt8(next() & 0xFF) })
            case 1:
                data = valid
                for _ in 0..<(1 + Int(next() % 6)) where !data.isEmpty {
                    data[Int(next() % UInt64(data.count))] = UInt8(next() & 0xFF)
                }
            case 2:
                data = valid.prefix(Int(next() % UInt64(valid.count + 1)))
            default:
                data = Data([0x50, 0x4B]) + Data((0..<Int(next() % 100)).map { _ in UInt8(next() & 0xFF) })
                data += footer(next() % 200)
            }
            if let payload = try? RmskinPackage.zipPayload(of: data) {
                _ = try? RmskinZip.scanCentralDirectory(payload)
            }
            _ = try? RmskinZip.scanCentralDirectory(data)
            _ = RmskinManifest.parse(TextDecoding.decode(data))
            _ = RmskinIniText.preservingValues(from: TextDecoding.decode(data), into: TextDecoding.decode(valid))
            let latin = String(decoding: data.map { $0 == 0 ? 0x5C : $0 }, as: UTF8.self)
            for part in RmskinZip.backslashComponents(latin, decodeEscapes: round % 2 == 0) {
                if part.isEmpty || part.contains("\\") { survived -= 1 }
            }
            survived += 1
        }
        t.equal(survived, 3_000)
    }

    t.suite("Rmskin: corrupted package files fail cleanly") {
        let dir = t.temporaryDirectory("rmskin-corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try Data(contentsOf: try makePackage(clockFiles(), in: dir, name: "good.rmskin"))
        let skins = dir.appendingPathComponent("Skins")
        let before = temporaryItems(t)
        var seed: UInt64 = 42
        for round in 0..<12 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            var data = good
            let body = data.count - 16
            for k in 0..<8 { data[Int((seed >> UInt64(k * 3)) % UInt64(body))] ^= 0x5A }
            let url = dir.appendingPathComponent("bad\(round).rmskin")
            try data.write(to: url)
            // May succeed (a flipped byte inside compressed data can be harmless) or throw; must never crash/hang.
            _ = try? RmskinInstaller.install(packageURL: url, skinsDirectory: skins)
        }
        t.equal(temporaryLeftovers(t, since: before), [], "temp folders always cleaned up")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: skins.path)) ?? [])
        t.equal(leftovers.filter { $0.hasPrefix(".deskset") }, [], "no staging folders left")
    }
}

// MARK: - Extraction hardening (review)

private func setQuarantine(_ url: URL) {
    let value = "0083;66f2a000;Safari;"
    _ = setxattr(url.path, "com.apple.quarantine", value, value.utf8.count, 0, 0)
}

private func hasXattr(_ url: URL, _ name: String) -> Bool {
    getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
}

private func rmskinExtractionHardeningTests(_ t: TestRunner) {
    t.suite("Rmskin: ZIP bomb with a small declared size is stopped") {
        // ditto follows the local headers and ignores declared sizes: an 80 MB stream declared as 10 bytes used to be
        // written out in full, whatever the central-directory scan said.
        let dir = t.temporaryDirectory("rmskin-bomb")
        defer { RmskinFiles.forceRemove(dir) }
        let zeros = try (Data(count: 80 << 20) as NSData).compressed(using: .zlib) as Data
        let package = try rawPackage([
            .init(name: "RMSKIN.ini", data: utf8("[rmskin]\nName=Bomb\n")),
            .init(name: "Skins/Bomb/Bomb.ini", data: utf8("[Rainmeter]\n")),
            .init(name: "Skins/Bomb/zeros.bin", data: zeros, deflated: true, declaredSize: 10, crc: 0),
        ], in: dir, name: "bomb.rmskin")
        t.equal(try RmskinZip.scanCentralDirectory(try RmskinPackage.zipPayload(of: Data(contentsOf: package)))
            .reduce(0) { $0 + $1.uncompressedSize }, 41, "the directory declares almost nothing")
        let before = temporaryItems(t)
        let isBomb: (RmskinError) -> Bool = {
            if case .extractionFailed(let message) = $0 { return message.contains("declares") }
            return false
        }
        expectRmskinError(t, "inspect", matching: isBomb) { _ = try RmskinPackage.inspect(package) }
        let skins = dir.appendingPathComponent("Skins")
        expectRmskinError(t, "install", matching: isBomb) {
            _ = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        }
        t.check(!exists(skins.appendingPathComponent("Bomb")))
        t.equal(temporaryLeftovers(t, since: before), [], "temporary folders removed")
        expectRmskinError(t, "extract", matching: isBomb) {
            _ = try RmskinPackage.extract(package, into: dir.appendingPathComponent("out"))
        }
    }

    t.suite("Rmskin: output monitor measures what is really written") {
        let dir = t.temporaryDirectory("rmskin-monitor")
        defer { RmskinFiles.forceRemove(dir) }
        let monitor = RmskinZip.outputMonitor(for: dir, declaredBytes: 10)
        t.check(monitor() == nil, "empty folder is fine")
        try writeTree([("a/b.txt", utf8("hello"))], at: dir)
        t.check(monitor() == nil, "within the declared size + slack")
        // A sparse file: logical size counts, no disk space needed for the test.
        let big = dir.appendingPathComponent("a/big.bin")
        t.check(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(100 << 20))
        try handle.close()
        t.check(monitor()?.contains("declares") ?? false, "100 MB for a 10-byte archive")
        let usage = RmskinZip.measureOutput(dir)
        t.equal(usage.bytes, UInt64(100 << 20) + 5)
        t.equal(usage.items, 3)
        t.equal(RmskinZip.measureOutput(dir, byteLimit: 10).bytes > 10, true, "stops early past a limit")
        // What was already in the folder does not count against a new extraction.
        t.check(RmskinZip.outputMonitor(for: dir, declaredBytes: 10)() == nil)
        t.check(RmskinZip.outputMonitor(for: dir.appendingPathComponent("missing"), declaredBytes: 0)() == nil)
        t.check(RmskinZip.availableBytes(at: dir) ?? 0 > 0)
    }

    t.suite("Rmskin: ditto is stopped by the monitor and the timeout") {
        // ditto blocks forever opening a FIFO as its archive: a deterministic "slow extraction".
        let dir = t.temporaryDirectory("rmskin-ditto-stop")
        defer { RmskinFiles.forceRemove(dir) }
        let fifo = dir.appendingPathComponent("never.zip")
        t.equal(mkfifo(fifo.path, 0o600), 0)
        var calls = 0
        let start = Date()
        expectRmskinError(t, "monitor", matching: { $0 == .extractionFailed("stop requested") }) {
            _ = try RmskinZip.runDitto(["-x", "-k", fifo.path, dir.appendingPathComponent("out").path],
                                       pollInterval: 0.02) {
                calls += 1
                return calls >= 3 ? "stop requested" : nil
            }
        }
        t.equal(calls, 3)
        expectRmskinError(t, "timeout", matching: {
            if case .extractionFailed(let m) = $0 { return m.contains("did not finish") }
            return false
        }) {
            _ = try RmskinZip.runDitto(["-x", "-k", fifo.path, dir.appendingPathComponent("out2").path], timeout: 0.2)
        }
        t.check(Date().timeIntervalSince(start) < 20, "both stops are prompt")
    }

    t.suite("Rmskin: AppleDouble ACLs and attributes are not restored") {
        // A package made on a Mac carries ACLs / extended attributes in __MACOSX/._* entries. ditto used to restore
        // them: an "everyone deny delete" ACL made installed files undeletable and broke temporary clean-up.
        let dir = t.temporaryDirectory("rmskin-acl")
        defer { RmskinFiles.forceRemove(dir) }
        let source = dir.appendingPathComponent("src")
        try writeTree([("RMSKIN.ini", utf8("[rmskin]\nName=Locked\nLoadType=Skin\nLoad=Locked\\Locked.ini\n")),
                       ("Skins/Locked/Locked.ini", utf8("[Rainmeter]\n"))], at: source)
        let ini = source.appendingPathComponent("Skins/Locked/Locked.ini")
        t.equal(setxattr(ini.path, "com.example.deskset", "x", 1, 0, 0), 0)
        t.equal(try runTool("/bin/chmod", ["+a", "everyone deny delete", ini.path]), 0)
        let zip = dir.appendingPathComponent("locked.zip")
        t.equal(try runTool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", source.path, zip.path]), 0)
        _ = try runTool("/bin/chmod", ["-N", ini.path])
        var data = try Data(contentsOf: zip)
        t.check(try RmskinZip.scanCentralDirectory(data).contains { $0.name.hasPrefix("__MACOSX/") },
                "the archive really carries AppleDouble metadata")
        data += footer(UInt64(data.count))
        let package = dir.appendingPathComponent("locked.rmskin")
        try data.write(to: package)

        let out = dir.appendingPathComponent("out")
        _ = try RmskinPackage.extract(package, into: out)
        t.check(!exists(out.appendingPathComponent("__MACOSX")), "metadata folder removed")
        t.check(!hasXattr(out.appendingPathComponent("Skins/Locked/Locked.ini"), "com.example.deskset"))

        let before = temporaryItems(t)
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(temporaryLeftovers(t, since: before), [], "temporary folders removed")
        t.equal(result.skinToLoadFile, "Locked.ini")
        let installed = skins.appendingPathComponent("Locked/Locked.ini")
        t.check(!hasXattr(installed, "com.example.deskset"), "no extended attributes from the package")
        t.check((try? FileManager.default.removeItem(at: installed)) != nil, "installed files can be deleted")
        t.check(!exists(skins.appendingPathComponent("__MACOSX")))
    }

    t.suite("Rmskin: quarantine flag reaches extracted and installed files") {
        let dir = t.temporaryDirectory("rmskin-quarantine")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try makePackage(clockFiles(), in: dir)
        let plain = try RmskinPackage.inspect(package)
        t.check(!hasXattr(plain.packageRoot.appendingPathComponent("Skins/Clockwork/Digital/Digital.ini"),
                          "com.apple.quarantine"), "no flag when the package has none")
        plain.cleanup()

        setQuarantine(package)
        t.check(hasXattr(package, "com.apple.quarantine"))
        let inspection = try RmskinPackage.inspect(package)
        defer { inspection.cleanup() }
        t.check(hasXattr(inspection.packageRoot.appendingPathComponent("Skins/Clockwork/Digital/Digital.ini"),
                         "com.apple.quarantine"), "extracted files inherit the package's quarantine flag")
        let skins = dir.appendingPathComponent("Skins")
        _ = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        t.check(hasXattr(skins.appendingPathComponent("Clockwork/Digital/Digital.ini"), "com.apple.quarantine"),
                "installed files stay quarantined")
        // Quarantined fonts still work (verified by hand: CTFontManagerRegisterFontsForURL accepts them).
        t.check(exists(skins.appendingPathComponent("Clockwork/@Resources/Fonts/Clock.ttf")))
    }

    t.suite("Rmskin: odd Unix modes in the archive") {
        // Folders stored as unreadable (0o311) or read-only (0o555) used to be skipped silently (missing skin files)
        // and left undeletable temporary folders behind; set-uid bits were copied into the Skins folder.
        let dir = t.temporaryDirectory("rmskin-modes")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try rawPackage([
            .init(name: "RMSKIN.ini", data: utf8("[rmskin]\nName=Odd\nLoadType=Skin\nLoad=Odd\\Hidden\\Deep.ini\n")),
            .init(name: "Skins/Odd/", unixMode: 0o040555),
            .init(name: "Skins/Odd/Odd.ini", data: utf8("[Rainmeter]\n"), unixMode: 0o100444),
            .init(name: "Skins/Odd/Hidden/", unixMode: 0o040311),
            .init(name: "Skins/Odd/Hidden/Deep.ini", data: utf8("[Rainmeter]\nUpdate=1\n"), unixMode: 0o100644),
            .init(name: "Skins/Odd/tool", data: utf8("#!/bin/sh\n"), unixMode: 0o104755),
        ], in: dir)
        let before = temporaryItems(t)
        let skins = dir.appendingPathComponent("Skins")
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(temporaryLeftovers(t, since: before), [], "temporary folders removed")
        t.equal(text(skins.appendingPathComponent("Odd/Hidden/Deep.ini")), "[Rainmeter]\nUpdate=1\n",
                "files inside an unreadable folder are installed")
        t.equal(result.skinToLoadConfig, "Odd\\Hidden")
        t.equal(access(skins.appendingPathComponent("Odd/Odd.ini").path, W_OK), 0, "the owner can edit skin files")
        var info = stat()
        t.equal(lstat(skins.appendingPathComponent("Odd/tool").path, &info), 0)
        t.equal(info.st_mode & 0o7000, 0, "no set-uid bit")
        t.equal(info.st_mode & 0o100, 0o100, "execute bit kept")
    }

    t.suite("Rmskin: hidden directory records and links are dropped") {
        // The end-of-directory record claims 2 entries; ditto still extracts the third (a symlink to /tmp).
        let dir = t.temporaryDirectory("rmskin-hidden")
        defer { RmskinFiles.forceRemove(dir) }
        var zip = RmskinTestZip.make([
            .init(name: "RMSKIN.ini", data: utf8("[rmskin]\nName=A\n")),
            .init(name: "Skins/A/A.ini", data: utf8("[Rainmeter]\n")),
            .init(name: "Skins/A/link", data: utf8("/tmp"), unixMode: 0o120777),
        ], declaredCount: 2)
        t.equal(try RmskinZip.scanCentralDirectory(zip).count, 2, "the scan only sees what the directory declares")
        zip += footer(UInt64(zip.count))
        let package = dir.appendingPathComponent("hidden.rmskin")
        try zip.write(to: package)
        let inspection = try RmskinPackage.inspect(package)
        defer { inspection.cleanup() }
        let link = inspection.packageRoot.appendingPathComponent("Skins/A/link")
        t.equal((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)), nil, "no link survives")
        let skins = dir.appendingPathComponent("Skins")
        _ = try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins)
        t.check(!exists(skins.appendingPathComponent("A/link")))
        t.check(exists(skins.appendingPathComponent("A/A.ini")))
    }

    t.suite("Rmskin: extract into a linked folder") {
        let dir = t.temporaryDirectory("rmskin-linkroot")
        defer { RmskinFiles.forceRemove(dir) }
        let package = try makePackage(clockFiles(), in: dir)
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        _ = try RmskinPackage.extract(package, into: link)
        t.check(exists(real.appendingPathComponent("Skins/Clockwork/Digital/Digital.ini")))
    }

    t.suite("Rmskin: large variable files merge in linear time") {
        let count = 20_000
        var old = "[Variables]\r\n", new = "; defaults\r\n[Variables]\r\n"
        for i in 0..<count {
            old += "Key\(i)=user \(i)\r\n"
            new += "Key\(i)=default\r\n"
        }
        let start = Date()
        let merged = RmskinIniText.preservingValues(from: old, into: new)
        t.equal(merged.preserved, count)
        t.check(merged.text.hasSuffix("Key\(count - 1)=user \(count - 1)\r\n"))
        t.check(Date().timeIntervalSince(start) < 5, "20 000 keys merged quickly")
    }

    t.suite("Rmskin: forceRemove") {
        let dir = t.temporaryDirectory("rmskin-force")
        let locked = dir.appendingPathComponent("a/b")
        try writeTree([("a/b/c/d.txt", utf8("x")), ("a/e.txt", utf8("y"))], at: dir)
        t.equal(chmod(locked.appendingPathComponent("c").path, 0o000), 0)
        t.equal(chmod(locked.path, 0o500), 0)
        t.check((try? FileManager.default.removeItem(at: dir)) == nil, "a plain delete fails")
        RmskinFiles.forceRemove(dir)
        t.check(!exists(dir))
        RmskinFiles.forceRemove(dir) // missing: no-op
    }
}

// MARK: - Non-UTF-8 names (review)

private func rmskinLegacyNameTests(_ t: TestRunner) {
    t.suite("Rmskin: ditto escapes are decoded, not split") {
        // ditto writes names it cannot decode with `\\` for a backslash and `\ooo` for other bytes.
        t.equal(RmskinZip.backslashComponents("Gr\\224\\341e", decodeEscapes: true), ["Größe"])
        t.equal(RmskinZip.backslashComponents("Skins\\\\Gr\\224e\\\\a.ini", decodeEscapes: true),
                ["Skins", "Gröe", "a.ini"])
        t.equal(RmskinZip.backslashComponents("Win\\Main\\Main.ini", decodeEscapes: true), ["Win", "Main", "Main.ini"],
                "plain Windows separators still split")
        t.equal(RmskinZip.backslashComponents("A\\250px\\x.png", decodeEscapes: false), ["A", "250px", "x.png"])
        t.equal(RmskinZip.backslashComponents("\\\\a\\.\\b\\", decodeEscapes: false), ["a", "b"])
        t.equal(RmskinZip.backslashComponents("x\\..\\y", decodeEscapes: false), ["x", "..", "y"],
                "`..` is reported so the caller refuses it")
        t.equal(RmskinZip.backslashComponents("Gr\\303\\266\\303\\237e", decodeEscapes: true), ["Größe"],
                "escaped bytes that form UTF-8 are read as UTF-8")
        t.equal(RmskinZip.backslashComponents("trail\\", decodeEscapes: true), ["trail"])
        t.equal(RmskinZip.backslashComponents("short\\2", decodeEscapes: true), ["short", "2"])
        t.equal(RmskinZip.backslashComponents("", decodeEscapes: true), [])
    }

    t.suite("Rmskin: code page 437 names install under readable folders") {
        // Windows Explorer and older tools store non-ASCII names in the OEM code page without the UTF-8 flag.
        // With a UTF-8 user text encoding ditto escapes them, and the installer used to split each escape into
        // folders (Skins/Gr/224/341e). Force that encoding for ditto (inherited) so the test is deterministic.
        let dir = t.temporaryDirectory("rmskin-cp437")
        defer { RmskinFiles.forceRemove(dir) }
        func cp437(_ s: String) -> Data { s.data(using: RmskinZip.codePage437) ?? Data() }
        let package = try rawPackage([
            .init(name: "RMSKIN.ini", data: utf8("[rmskin]\nName=G\nLoadType=Skin\nLoad=Größe\\Grüße.ini\n"
                                                    + "VariableFiles=Größe\\@Resources\\Välues.inc\n")),
            .init(name: "", data: utf8("[Rainmeter]\n"), rawName: cp437("Skins/Größe/Grüße.ini")),
            .init(name: "", data: utf8("[Variables]\nA=new\n"), rawName: cp437("Skins\\Größe\\@Resources\\Välues.inc")),
        ], in: dir)
        let skins = dir.appendingPathComponent("Skins")
        try writeTree([("Größe/@Resources/Välues.inc", utf8("[Variables]\nA=mine\n"))], at: skins)

        let saved = getenv("__CF_USER_TEXT_ENCODING").map { String(cString: $0) }
        setenv("__CF_USER_TEXT_ENCODING", "0x1F5:0x8000100:0", 1)
        defer {
            if let saved { setenv("__CF_USER_TEXT_ENCODING", saved, 1) } else { unsetenv("__CF_USER_TEXT_ENCODING") }
        }
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(result.installedRootConfigs, ["Größe"])
        t.equal(((try? FileManager.default.contentsOfDirectory(atPath: skins.path)) ?? []).map {
            $0.precomposedStringWithCanonicalMapping }, ["Größe"], "one root config, no escape debris")
        t.equal(text(skins.appendingPathComponent("Größe/Grüße.ini")), "[Rainmeter]\n")
        t.equal(text(skins.appendingPathComponent("Größe/@Resources/Välues.inc")), "[Variables]\nA=mine\n",
                "backslash + code page 437 name lands in the same root config; the user's value is kept")
        t.equal(result.skinToLoadFile?.precomposedStringWithCanonicalMapping, "Grüße.ini")
    }
}

// MARK: - Manual conformance (review)

private func rmskinManualConformanceTests(_ t: TestRunner) {
    t.suite("Rmskin: VariableFiles keep only [Variables] values") {
        // "include files to store variables ... the existing variable values are used instead of the defaults in the
        // package": other sections of such a file (styles, meters) must still be upgraded.
        let dir = t.temporaryDirectory("rmskin-varsection")
        defer { RmskinFiles.forceRemove(dir) }
        let skins = dir.appendingPathComponent("Skins")
        try writeTree([("Clockwork/@Resources/Variables.inc",
                        utf8("[Variables]\nColor=0,0,0\nSize=30\n[StyleText]\nFontSize=10\nFontFace=Old\n"))], at: skins)
        let package = try makePackage(clockFiles(variables:
            "[Variables]\nColor=255,255,255\nSize=12\n[StyleText]\nFontSize=12\nFontFace=New\n"), in: dir)
        let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins)
        t.equal(text(skins.appendingPathComponent("Clockwork/@Resources/Variables.inc")),
                "[Variables]\nColor=0,0,0\nSize=30\n[StyleText]\nFontSize=12\nFontFace=New\n")
        t.equal(result.preservedVariableCount, 2)
    }

    t.suite("Rmskin: Load only activates what the package installed") {
        // "You may choose one of the skin '.ini' files in your package" / "one layout to be loaded"; the installer
        // does not load "a non-installed skin/layout" (version history, SkinInstaller).
        let dir = t.temporaryDirectory("rmskin-loadown")
        defer { RmskinFiles.forceRemove(dir) }
        let skins = dir.appendingPathComponent("Skins")
        let layouts = dir.appendingPathComponent("Layouts")
        try writeTree([("Existing/Old.ini", utf8("[Rainmeter]\n"))], at: skins)
        try writeTree([("User Desk/Rainmeter.ini", utf8("[Existing]\nActive=1\n"))], at: layouts)
        let skinLoad = try makePackage(clockFiles(manifest: "[rmskin]\nName=C\nLoadType=Skin\nLoad=Existing\\Old.ini\n"),
                                       in: dir, name: "a.rmskin")
        var result = try RmskinInstaller.install(packageURL: skinLoad, skinsDirectory: skins)
        t.equal(result.skinToLoadConfig, nil)
        t.check(result.warnings.contains { $0.contains("Existing\\Old.ini") })
        let layoutLoad = try makePackage(clockFiles(manifest: "[rmskin]\nName=C\nLoadType=Layout\nLoad=User Desk\n"),
                                         in: dir, name: "b.rmskin")
        result = try RmskinInstaller.install(packageURL: layoutLoad, skinsDirectory: skins, layoutsDirectory: layouts)
        t.equal(result.layoutToLoad, nil)
        t.check(result.warnings.contains { $0.contains("User Desk") })
        // A MergeSkins patch may load a skin of its root config that only the earlier install provided.
        let patch = try makePackage([("RMSKIN.ini", utf8("[rmskin]\nName=P\nMergeSkins=1\nLoad=Clockwork\\Analog\\Analog.ini\n")),
                                     ("Skins/Clockwork/Digital/Digital.ini", utf8("patched"))], in: dir, name: "p.rmskin")
        result = try RmskinInstaller.install(packageURL: patch, skinsDirectory: skins)
        t.equal(result.skinToLoadConfig, "Clockwork\\Analog")
    }

    t.suite("Rmskin: legacy Merge key") {
        // "Rainstaller: Added Merge=1/0 to support addons for suites" (pre-2.4 packages).
        t.equal(RmskinManifest.parse("[rmskin]\nMerge=1\n").mergeSkins, true)
        t.equal(RmskinManifest.parse("[rmskin]\nMerge=0\n").mergeSkins, false)
        t.equal(RmskinManifest.parse("[rmskin]\nMergeSkins=0\nMerge=1\n").mergeSkins, false, "MergeSkins wins")
        t.equal(RmskinManifest.parse("[rmskin]\nMergeSkins=1\nMerge=0\n").mergeSkins, true)
        t.equal(RmskinManifest.parse("[rmskin]\nMergeSkins=\nMerge=1\n").mergeSkins, false, "present but empty")
    }

    t.suite("Rmskin: rewrites keep every line ending") {
        // Untouched lines must come back byte for byte: mixed CRLF/LF files and rare newline characters used to be
        // rewritten with the first separator of the file.
        let new = "; head\r\n[Variables]\r\nA=1\nB=2\r\nC=x\u{2028}y\u{0C}\r\nD=4"
        let merged = RmskinIniText.preservingValues(from: "[Variables]\nA=9\nD=8\n", into: new)
        t.equal(merged.text, "; head\r\n[Variables]\r\nA=9\nB=2\r\nC=x\u{2028}y\u{0C}\r\nD=8")
        t.equal(merged.preserved, 2)
        t.equal(RmskinIniText.preservingValues(from: "[Variables]\nB=2", into: new).text, new, "nothing changed")
        let layout = "[Rainmeter]\r\nSkinPath=x\n[Skin]\r\nA=1\u{2028}"
        t.equal(RmskinIniText.removingOptions(ofSection: "Rainmeter", from: layout).text, "[Rainmeter]\r\n[Skin]\r\nA=1\u{2028}")
        let lines = RmskinIniText.splitLines("a\r\nb\rc\n")
        t.equal(lines.map { String($0.content) }, ["a", "b", "c", ""])
        t.equal(lines.map { String($0.terminator) }, ["\r\n", "\r", "\n", ""])
        t.equal(RmskinIniText.splitLines("").count, 1)
    }

    t.suite("Rmskin: header image must be a real bitmap") {
        // "The image must be a bitmap image (.bmp) that is exactly 400x60 pixels in size."
        let dir = t.temporaryDirectory("rmskin-bmp")
        defer { RmskinFiles.forceRemove(dir) }
        func size(_ data: Data) throws -> [Int]? {
            let url = dir.appendingPathComponent("h\(UUID().uuidString).bmp")
            try data.write(to: url)
            return RmskinFiles.bitmapSize(of: url).map { [$0.width, $0.height] }
        }
        t.equal(try size(bitmap(width: 400, height: 60)), [400, 60])
        t.equal(try size(bitmap(width: 400, height: -60)), [400, 60], "top-down bitmap")
        var core = Data([0x42, 0x4D]) + Data(count: 12) + RmskinTestZip.le32(12)
        core += RmskinTestZip.le16(400) + RmskinTestZip.le16(60) + RmskinTestZip.le16(1) + RmskinTestZip.le16(24)
        t.equal(try size(core), [400, 60], "BITMAPCOREHEADER")
        var huge = bitmap(width: 1, height: 1)
        huge.replaceSubrange(18..<22, with: RmskinTestZip.le32(100_000))
        t.equal(try size(huge), nil, "implausible width")
        t.equal(try size(Data([0x42, 0x4D, 0, 0])), nil, "truncated")
        t.equal(try size(utf8(String(repeating: "x", count: 64))), nil, "not a bitmap")
        var zeroHeader = bitmap(width: 4, height: 4)
        zeroHeader.replaceSubrange(14..<18, with: RmskinTestZip.le32(5))
        t.equal(try size(zeroHeader), nil, "unknown header size")
        t.equal(RmskinFiles.bitmapSize(of: dir.appendingPathComponent("missing.bmp")).map { $0.width }, nil)

        var files = clockFiles()
        files.append(("RMSKIN.bmp", utf8("not a bitmap at all, just text")))
        let inspection = try RmskinPackage.inspect(try makePackage(files, in: dir))
        defer { inspection.cleanup() }
        t.equal(inspection.headerImageURL, nil)
        t.check(inspection.warnings.contains { $0.contains("RMSKIN.bmp") })
    }
}
