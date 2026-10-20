import Darwin
import Foundation
@testable import DesksetCore

func runIniMetadataTests(_ t: TestRunner) {
    let savedANSICodePage = TextDecoding.ansiCodePage
    TextDecoding.ansiCodePage = 1252
    defer { TextDecoding.ansiCodePage = savedANSICodePage }

    t.suite("Ini: metadata keys and section insertion") {
        t.equal(IniWriter.metadataKeys, ["Name", "Author", "Information", "Version", "License"])
        t.check(!IniWriter.metadataKeys.contains("Config"))

        let dir = t.temporaryDirectory("ini-metadata-basic")
        let url = dir.appendingPathComponent("Skin.ini")
        try "[Rainmeter]\nUpdate=1000\n\n; comment stays\n[MeterText]\nMeter=String\nText=Hello\n"
            .write(to: url, atomically: true, encoding: .utf8)

        t.equal( try IniWriter.addMetadataIfMissing(fileURL: url), true)
        let text = try TextDecoding.readFile(at: url)
        t.check(text.contains("; comment stays"))
        let doc = IniDocument.parse(text)
        t.equal(doc.sections.map(\.name), ["Rainmeter", "MeterText", "Metadata"])
        let metadata = doc.section(named: "Metadata")
        t.equal(metadata?.entries, [
            IniEntry(key: "Name", value: ""),
            IniEntry(key: "Author", value: ""),
            IniEntry(key: "Information", value: ""),
            IniEntry(key: "Version", value: ""),
            IniEntry(key: "License", value: ""),
        ])

        // Calling a second time is a no-op because the empty [Metadata] section now exists.
        let bytesAfterFirst = try Data(contentsOf: url)
        t.equal(try IniWriter.addMetadataIfMissing(fileURL: url), false)
        t.equal(try Data(contentsOf: url), bytesAfterFirst)
    }

    t.suite("Ini: addMetadataIfMissing preserves encodings and BOMs") {
        let dir = t.temporaryDirectory("ini-metadata-encodings")
        let cases: [(name: String, encoding: TextFileEncoding, codePage: Int, sample: String)] = [
            ("utf8-nobom", .utf8(bom: false), 1252, "[Rainmeter]\n; Café 🎉\nUpdate=1000\n"),
            ("utf8-bom", .utf8(bom: true), 1252, "[Rainmeter]\n; Café 🎉\nUpdate=1000\n"),
            ("utf16le-bom", .utf16LittleEndian(bom: true), 1252, "[Rainmeter]\r\n; Café 雪\r\nUpdate=1000\r\n"),
            ("utf16le-nobom", .utf16LittleEndian(bom: false), 1252, "[Rainmeter]\r\nUpdate=1000\r\n"),
            ("utf16be-bom", .utf16BigEndian(bom: true), 1252, "[Rainmeter]\r\n; Café 雪\r\nUpdate=1000\r\n"),
            ("utf16be-nobom", .utf16BigEndian(bom: false), 1252, "[Rainmeter]\r\nUpdate=1000\r\n"),
            ("utf32le-bom", .utf32LittleEndian, 1252, "[Rainmeter]\nUpdate=1000\n"),
            ("utf32be-bom", .utf32BigEndian, 1252, "[Rainmeter]\nUpdate=1000\n"),
            ("cp1252", .windows1252, 1252, "[Rainmeter]\r\n; Café €\r\nUpdate=1000\r\n"),
            ("cp936", .windowsCodePage(936), 936, "[Rainmeter]\r\n; 中文皮肤\r\nUpdate=1000\r\n"),
        ]

        for item in cases {
            TextDecoding.ansiCodePage = item.codePage
            let url = dir.appendingPathComponent("\(item.name).ini")
            guard let initialBytes = TextDecoding.encode(item.sample, as: item.encoding) else {
                t.check(false, "encoded \(item.name)")
                continue
            }
            try initialBytes.write(to: url)
            t.equal(try IniWriter.addMetadataIfMissing(fileURL: url), true, item.name)
            let decoded = try TextDecoding.readFileDetectingEncoding(at: url)
            t.equal(decoded.encoding, item.encoding, "\(item.name) encoding preserved")
            let doc = IniDocument.parse(decoded.text)
            t.equal(doc.section(named: "Rainmeter")?["Update"], "1000", item.name)
            t.equal(doc.section(named: "Metadata")?.keys, IniWriter.metadataKeys, item.name)
            t.equal(try IniWriter.addMetadataIfMissing(fileURL: url), false, "\(item.name) idempotent")
        }
        TextDecoding.ansiCodePage = 1252
    }

    t.suite("Ini: addMetadataIfMissing line endings and edge shapes") {
        let dir = t.temporaryDirectory("ini-metadata-endings")

        // CRLF preserved
        let crlfURL = dir.appendingPathComponent("CRLF.ini")
        try Data("[Rainmeter]\r\nUpdate=1000\r\n".utf8).write(to: crlfURL)
        t.equal(try IniWriter.addMetadataIfMissing(fileURL: crlfURL), true)
        let crlfText = try TextDecoding.readFile(at: crlfURL)
        t.check(crlfText.contains("[Metadata]\r\nName=\r\nAuthor=\r\nInformation=\r\nVersion=\r\nLicense=\r\n"))
        t.check(!crlfText.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "pure CRLF kept")

        // Bare CR preserved
        let crURL = dir.appendingPathComponent("CR.ini")
        try Data("[Rainmeter]\rUpdate=1000\r".utf8).write(to: crURL)
        t.equal(try IniWriter.addMetadataIfMissing(fileURL: crURL), true)
        let crText = try TextDecoding.readFile(at: crURL)
        t.check(crText.contains("[Metadata]\rName=\rAuthor=\rInformation=\rVersion=\rLicense=\r"))
        t.check(!crText.contains("\n"), "pure CR kept")

        // No trailing newline
        let noNewlineURL = dir.appendingPathComponent("NoNewline.ini")
        try Data("[Rainmeter]\nUpdate=1000".utf8).write(to: noNewlineURL)
        t.equal(try IniWriter.addMetadataIfMissing(fileURL: noNewlineURL), true)
        let noNewlineDoc = IniDocument.parse(try TextDecoding.readFile(at: noNewlineURL))
        t.equal(noNewlineDoc.section(named: "Rainmeter")?["Update"], "1000")
        t.equal(noNewlineDoc.section(named: "Metadata")?.keys, IniWriter.metadataKeys)

        // Empty file
        let emptyURL = dir.appendingPathComponent("Empty.ini")
        try Data().write(to: emptyURL)
        t.equal(try IniWriter.addMetadataIfMissing(fileURL: emptyURL), true)
        let emptyDoc = IniDocument.parse(try TextDecoding.readFile(at: emptyURL))
        t.equal(emptyDoc.sections.map(\.name), ["Metadata"])
        t.equal(emptyDoc.section(named: "Metadata")?.keys, IniWriter.metadataKeys)

        // Commented-out [Metadata] does not count as an existing section
        let commentedURL = dir.appendingPathComponent("Commented.ini")
        try Data(";[Metadata]\n;Author=Someone\n[Rainmeter]\nUpdate=1000\n".utf8).write(to: commentedURL)
        t.equal(try IniWriter.addMetadataIfMissing(fileURL: commentedURL), true)
        let commentedText = try TextDecoding.readFile(at: commentedURL)
        t.check(commentedText.hasPrefix(";[Metadata]\n;Author=Someone\n"))
        t.equal(IniDocument.parse(commentedText).section(named: "Metadata")?.keys, IniWriter.metadataKeys)
    }

    t.suite("Ini: addMetadataIfMissing is a no-op when [Metadata] already exists") {
        let dir = t.temporaryDirectory("ini-metadata-existing")
        let samples = [
            "[Metadata]\nAuthor=Ada\n[Rainmeter]\nUpdate=1000\n",
            "[metadata]\r\nname=Clock\r\n",
            "[METADATA]\n\n[Rainmeter]\nUpdate=1000\n",
            "[Rainmeter]\nUpdate=1000\n[Metadata]\nAuthor=First\n[Metadata]\nVersion=2.0\n",
        ]
        for (index, sample) in samples.enumerated() {
            let url = dir.appendingPathComponent("Existing\(index).ini")
            let raw = Data(sample.utf8)
            try raw.write(to: url)
            t.equal(try IniWriter.addMetadataIfMissing(fileURL: url), false, "sample \(index)")
            t.equal(try Data(contentsOf: url), raw, "sample \(index) bytes untouched")
        }
    }

    t.suite("Ini: addMetadataIfMissing preserves symbolic links") {
        let dir = t.temporaryDirectory("ini-metadata-symlink")
        let target = dir.appendingPathComponent("RealSkin.ini")
        let link = dir.appendingPathComponent("LinkedSkin.ini")
        try Data("[Rainmeter]\nUpdate=1000\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        t.equal(try IniWriter.addMetadataIfMissing(fileURL: link), true)
        let linkValues = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        t.equal(linkValues.isSymbolicLink, true, "symlink stays a symlink")
        t.equal(IniDocument.parse(try TextDecoding.readFile(at: target)).section(named: "Metadata")?.keys,
                IniWriter.metadataKeys)
    }

    t.suite("Ini: addMetadataIfMissing rejects invalid files and malformed encodings without mutation") {
        let dir = t.temporaryDirectory("ini-metadata-errors")

        // Missing file
        let missing = dir.appendingPathComponent("Missing.ini")
        t.throwsError { _ = try IniWriter.addMetadataIfMissing(fileURL: missing) }

        // Directory
        let subdir = dir.appendingPathComponent("Folder.ini")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        t.throwsError { _ = try IniWriter.addMetadataIfMissing(fileURL: subdir) }

        // Broken symlink
        let broken = dir.appendingPathComponent("Broken.ini")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: missing)
        t.throwsError { _ = try IniWriter.addMetadataIfMissing(fileURL: broken) }

        // Non-regular FIFO
        let fifo = dir.appendingPathComponent("Pipe.ini")
        if mkfifo(fifo.path, 0o600) == 0 {
            defer { try? FileManager.default.removeItem(at: fifo) }
            t.throwsError { _ = try IniWriter.addMetadataIfMissing(fileURL: fifo) }
        }

        // Malformed byte sequences that cannot round-trip losslessly
        let malformedCases: [(String, [UInt8])] = [
            ("odd-utf16le-bom", [0xFF, 0xFE, 0x5B, 0x00, 0x52]),
            ("invalid-utf32le-bom", [0xFF, 0xFE, 0x00, 0x00, 0x00, 0xD8, 0x00, 0x00]),
            ("invalid-utf8-bom", [0xEF, 0xBB, 0xBF, 0x5B, 0xFF, 0x5D]),
        ]
        for (name, rawBytes) in malformedCases {
            let url = dir.appendingPathComponent("\(name).ini")
            let raw = Data(rawBytes)
            try raw.write(to: url)
            t.throwsError(name) { _ = try IniWriter.addMetadataIfMissing(fileURL: url) }
            t.equal(try Data(contentsOf: url), raw, "\(name) bytes preserved on error")
        }

        // Write failure in a read-only directory leaves the original file intact
        let roDir = dir.appendingPathComponent("ReadOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        let roFile = roDir.appendingPathComponent("Locked.ini")
        let roBytes = Data("[Rainmeter]\nUpdate=1000\n".utf8)
        try roBytes.write(to: roFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: roDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: roDir.path) }
        if geteuid() != 0 {
            t.throwsError { _ = try IniWriter.addMetadataIfMissing(fileURL: roFile) }
            t.equal(try Data(contentsOf: roFile), roBytes, "original file untouched on write failure")
        }
    }

    t.suite("Ini: addMetadataIfMissing serializes with writeValue under withFileLock") {
        let dir = t.temporaryDirectory("ini-metadata-concurrent")
        let url = dir.appendingPathComponent("Concurrent.ini")
        try Data("[Rainmeter]\nUpdate=1000\n[Variables]\nCount=0\n".utf8).write(to: url)

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ini-metadata-concurrent", attributes: .concurrent)
        let lock = NSLock()
        var addResults: [Bool] = []
        var errors: [Error] = []

        for index in 1...12 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    if index % 2 == 0 {
                        let added = try IniWriter.addMetadataIfMissing(fileURL: url)
                        lock.lock()
                        addResults.append(added)
                        lock.unlock()
                    } else {
                        try IniWriter.writeValue("\(index)", key: "Key\(index)", section: "Variables", fileURL: url)
                    }
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
            }
        }
        group.wait()

        t.equal(errors.count, 0)
        t.equal(addResults.filter { $0 }.count, 1, "exactly one concurrent call inserted [Metadata]")
        let doc = IniDocument.parse(try TextDecoding.readFile(at: url))
        t.equal(doc.section(named: "Metadata")?.keys, IniWriter.metadataKeys)
        for index in stride(from: 1, through: 11, by: 2) {
            t.equal(doc.section(named: "Variables")?["Key\(index)"], "\(index)")
        }
    }
}
