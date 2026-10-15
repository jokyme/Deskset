import Foundation
import zlib

/// Synthetic ZIP records deliberately let local metadata disagree with the directory.
enum DeskPackageArchiveSelfTests {
    private struct Item {
        var name: String = "Widget.desk"
        var bytes = Data("hello".utf8)
        var localName: String? = nil
        var mode = 0o100644
        var compressed: Data? = nil
        var declaredSize: Int? = nil
        var descriptor = false
        var crcOverride: UInt32? = nil
    }
    private static func put(_ value: Int, _ width: Int, into data: inout Data) {
        for shift in 0..<width { data.append(UInt8(truncatingIfNeeded: value >> (8 * shift))) }
    }
    private static func zip(_ items: [Item]) -> Data {
        var local = Data(), central = Data()
        for item in items {
            let offset = local.count, name = Data(item.name.utf8), lname = Data((item.localName ?? item.name).utf8)
            let payload = item.compressed ?? item.bytes, size = item.declaredSize ?? item.bytes.count
            let crc = item.crcOverride ?? item.bytes.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count))) }
            let flags = 0x800 | (item.descriptor ? 8 : 0), method = item.compressed == nil ? 0 : 8
            put(0x04034b50, 4, into: &local)
            for value in [20, flags, method, 0, 0] { put(value, 2, into: &local) }
            for value in [Int(crc), payload.count, size] { put(item.descriptor ? 0 : value, 4, into: &local) }
            put(lname.count, 2, into: &local); put(0, 2, into: &local)
            local.append(lname); local.append(payload)
            if item.descriptor {
                for value in [0x08074b50, Int(crc), payload.count, size] { put(value, 4, into: &local) }
            }
            put(0x02014b50, 4, into: &central)
            for value in [0x314, 20, flags, method, 0, 0] { put(value, 2, into: &central) }
            for value in [Int(crc), payload.count, size] { put(value, 4, into: &central) }
            for value in [name.count, 0, 0, 0, 0] { put(value, 2, into: &central) }
            put(item.mode << 16, 4, into: &central); put(offset, 4, into: &central); central.append(name)
        }
        let offset = local.count
        local.append(central)
        put(0x06054b50, 4, into: &local)
        for value in [0, 0, items.count, items.count] { put(value, 2, into: &local) }
        put(central.count, 4, into: &local); put(offset, 4, into: &local); put(0, 2, into: &local)
        return local
    }
    private static func rejects(_ t: AppTestRunner, _ failure: DeskPackageArchive.Failure,
                                _ operation: () throws -> Void) {
        do { try operation(); t.check(false, "unsafe archive accepted") }
        catch { t.equal(error as? DeskPackageArchive.Failure, failure, "unexpected error: \(error)") }
    }
    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk archive: paths and local records") {
            for name in ["../escape", "/absolute", "a/../../b", "a\\b", "C:/x", "a//b", "./x", "a/./b", "x\0y"] {
                rejects(t, .unsafePath) { _ = try DeskPackageArchive.scan(zip([Item(name: name)])) }
            }
            rejects(t, .corrupt) { _ = try DeskPackageArchive.scan(zip([Item(localName: "../outside")])) }
            for mode in [0o120777, 0o010600, 0o020600, 0o060600, 0o140600] {
                rejects(t, .unsupported) { _ = try DeskPackageArchive.scan(zip([Item(mode: mode)])) }
            }
            for names in [["A", "a"], ["a", "a/b"], ["a/b", "a"], ["A/b", "a/c"], ["caf\u{e9}", "cafe\u{301}"], ["x", "x"]] {
                rejects(t, .conflict) { _ = try DeskPackageArchive.scan(zip(names.map { Item(name: $0) })) }
            }
            let data = zip([Item()])
            for count in 0..<data.count {
                do { _ = try DeskPackageArchive.scan(Data(data.prefix(count))); t.check(false, "truncated ZIP accepted at \(count)") }
                catch { t.check(true) }
            }
            var trailing = data; trailing.append(0)
            rejects(t, .corrupt) { _ = try DeskPackageArchive.scan(trailing) }
            // A local record not represented in the central directory is never extracted.
            var hidden = data
            hidden.insert(contentsOf: [0x50, 0x4b, 3, 4], at: 0)
            rejects(t, .corrupt) { _ = try DeskPackageArchive.scan(hidden) }
        }
        t.suite("App: Desk archive: capture integrity and cleanup") {
            let parent = t.temporaryDirectory("archive-capture")
            let data = zip([Item(), Item(name: "assets/a", bytes: Data([1, 2, 3])),
                            Item(name: "empty/", bytes: Data(), mode: 0o040755)])
            var capturedRoot: URL?
            let captured = try DeskPackageArchive.withCapture(bytes: data, temporaryParent: parent) { capture in
                capturedRoot = capture.root
                try capture.validateUnchanged()
                t.equal(capture.files.map(\.path), ["Widget.desk", "assets/a"])
                t.equal(capture.totalBytes, 8)
                return capture
            }
            t.check(!FileManager.default.fileExists(atPath: capturedRoot!.path))
            t.equal(captured.files.first?.bytes, Data("hello".utf8))
            t.equal(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
            rejects(t, .corrupt) {
                _ = try DeskPackageArchive.withCapture(bytes: zip([Item(crcOverride: 1)]), temporaryParent: parent) { _ in () }
            }
            rejects(t, .io) {
                _ = try DeskPackageArchive.withCapture(bytes: data, temporaryParent: parent) { _ in throw DeskPackageArchive.Failure.io }
            }
            var cancelled = false
            rejects(t, .cancelled) {
                _ = try DeskPackageArchive.withCapture(bytes: data, temporaryParent: parent, isCancelled: { cancelled }) { _ in cancelled = true }
            }
            t.equal(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
            let archive = parent.appendingPathComponent("test.deskset")
            try data.write(to: archive)
            try DeskPackageArchive.withCapture(archive: archive, temporaryParent: parent) { t.equal($0.totalBytes, 8) }
            let link = parent.appendingPathComponent("link.deskset")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)
            rejects(t, .io) { try DeskPackageArchive.withCapture(archive: link, temporaryParent: parent) { _ in () } }
        }
        t.suite("App: Desk archive: actual deflate output and descriptors") {
            let parent = t.temporaryDirectory("archive-deflate")
            // Independent raw DEFLATE encoding of "hello" (fixed Huffman block).
            let deflated = Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 7, 0])
            for descriptor in [false, true] {
                let data = zip([Item(compressed: deflated, descriptor: descriptor)])
                try DeskPackageArchive.withCapture(bytes: data, temporaryParent: parent) { t.equal($0.files.first?.bytes, Data("hello".utf8)) }
            }
            rejects(t, .limit) {
                try DeskPackageArchive.withCapture(bytes: zip([Item(compressed: deflated, declaredSize: 1)]), temporaryParent: parent) { _ in () }
            }
            rejects(t, .corrupt) {
                try DeskPackageArchive.withCapture(bytes: zip([Item(compressed: deflated, declaredSize: 6)]), temporaryParent: parent) { _ in () }
            }
            for payload in [Data(deflated.dropLast()), deflated + Data([0]), Data([255, 255])] {
                rejects(t, .corrupt) {
                    try DeskPackageArchive.withCapture(bytes: zip([Item(compressed: payload)]), temporaryParent: parent) { _ in () }
                }
            }
            t.equal(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        }
        t.suite("App: Desk archive: exact budgets and cancellation") {
            let parent = t.temporaryDirectory("archive-budget")
            let items = (0..<2_000).map { Item(name: "f\($0)", bytes: Data()) }
            t.equal(try DeskPackageArchive.scan(zip(items)).count, 2_000)
            try DeskPackageArchive.withCapture(bytes: zip(items), temporaryParent: parent) { t.equal($0.files.count, 2_000) }
            rejects(t, .limit) { _ = try DeskPackageArchive.scan(zip(items + [Item(name: "extra", bytes: Data())])) }
            // Exercise the real 100 MiB output/capture boundary, not just directory arithmetic.
            let boundary = Data(repeating: 0, count: DeskPackageArchive.maximumBytes)
            let boundaryArchive = zip([Item(name: "boundary.bin", bytes: boundary)])
            try DeskPackageArchive.withCapture(bytes: boundaryArchive, temporaryParent: parent) {
                t.equal($0.totalBytes, DeskPackageArchive.maximumBytes)
                t.equal($0.files.first?.bytes, boundary)
            }
            t.equal(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
            // Declared sizes alone cannot grant expansion permission; actual decoding is separately checked.
            t.equal(try DeskPackageArchive.scan(zip([Item(declaredSize: 100 * 1024 * 1024)])).first?.size, 100 * 1024 * 1024)
            rejects(t, .limit) { _ = try DeskPackageArchive.scan(zip([Item(declaredSize: 100 * 1024 * 1024 + 1)])) }
            rejects(t, .limit) { _ = try DeskPackageArchive.scan(zip([Item(declaredSize: 100 * 1024 * 1024), Item(name: "b")])) }
            rejects(t, .cancelled) { _ = try DeskPackageArchive.scan(zip(items), isCancelled: { true }) }
            let data = zip([Item(bytes: Data(repeating: 1, count: 200_000))])
            var checks = 0
            rejects(t, .cancelled) {
                try DeskPackageArchive.withCapture(bytes: data, temporaryParent: parent, isCancelled: { checks += 1; return checks == 7 }) { _ in () }
            }
            t.equal(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        }
    }
}
