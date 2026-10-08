import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import DeskLanguage
import DesksetCore

/// File-worker preparation from real encoded pictures and an immutable directory capture. No editor, desktop
/// window or user installation is created; original and private-copy bytes are compared independently.
enum DeskPackageResourceSelfTests {
    private enum Failure: Error { case fixture(String) }
    private static let worker = DispatchQueue(label: "desk.package.resources.tests")

    private static func root(_ t: AppTestRunner, files: [(String, Data)]) throws -> URL {
        let root = t.temporaryDirectory("desk-package-resources")
        try Data("widget { Text(\"Package\") }\n".utf8).write(to: root.appendingPathComponent("Widget.desk"))
        for (path, bytes) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        return root
    }

    private static func capture(_ root: URL) throws -> DeskPackageCapture {
        try worker.sync { try DeskPackageCapture.read(root: root) }
    }

    private static func prepare(_ capture: DeskPackageCapture, _ literals: [String]) -> DeskProgramResources.Prepared {
        worker.sync { DeskProgramResources.prepare(capture: capture, literals: literals, language: .english) }
    }

    private static func unchanged(_ prepared: DeskProgramResources.Prepared) -> Bool {
        worker.sync { prepared.unchanged() }
    }

    private static func image(_ prepared: DeskProgramResources.Prepared, _ literal: String) throws -> ProgramImageResource {
        guard let image = prepared.images[literal] else { throw Failure.fixture("missing prepared image: \(literal)") }
        return image
    }

    private static func bytes(_ image: ProgramImageResource) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: image.path))
    }

    private static func encodedImage(alternate: Bool = false) throws -> Data {
        var pixels: [UInt8] = []
        for y in 0..<6 { for x in 0..<8 {
            pixels += alternate ? [216, 48, 24, 255]
                : (x < 4 ? [24, 168, 72, 255] : (y < 3 ? [80, 24, 112, 128] : [216, 88, 16, 255]))
        } }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                                  space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.fixture("image construction")
        }
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.fixture("PNG encoder")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw Failure.fixture("PNG encoding") }
        return data as Data
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk package resources: original encoded bytes and aliases share one private copy per preparation") {
            let png = try encodedImage(), path = "Pictures/Café.PNG"
            let folder = try root(t, files: [(path, png), ("unused.png", Data([1, 2, 3])), ("notes.txt", Data("notes".utf8))])
            let captured = try capture(folder)
            let aliases = [path, "./PICTURES/CAFE\u{301}.PNG", "Pictures/../Pictures/Café.PNG"]
            let first = prepare(captured, aliases), second = prepare(captured, [path])
            defer { first.removeCopies(); second.removeCopies() }
            t.equal(first.failure, nil); t.equal(second.failure, nil)
            t.check(first.capture != nil && second.capture != nil)
            t.equal(first.images.count, aliases.count)
            t.equal(first.files.map(\.path), [path])
            t.equal(first.files.first?.size, png.count)
            t.equal(first.files.first?.pixelSize, DeskPixelSize(width: 8, height: 6))
            t.equal(first.sources.map(\.literal), aliases)
            t.equal(first.sources.map(\.resolved), Array(repeating: path, count: aliases.count))
            t.check(captured.files.contains { $0.path == "unused.png" }, "the whole snapshot includes unreferenced bytes")
            let one = try image(first, path), two = try image(second, path)
            t.equal(one.naturalSize, SkinSize(width: 8, height: 6))
            for alias in aliases { t.equal(try image(first, alias), one) }
            t.equal(try bytes(one), png); t.equal(try bytes(two), png)
            t.check(one.path != two.path && first.folder != second.folder)
            t.check(!one.path.hasPrefix(folder.path + "/") && !two.path.hasPrefix(folder.path + "/"))
            guard let firstFolder = first.folder, let secondFolder = second.folder else { throw Failure.fixture("private folders") }
            for privateFolder in [firstFolder, secondFolder] {
                let attributes = try FileManager.default.attributesOfItem(atPath: privateFolder.path)
                t.equal((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
                t.equal(try FileManager.default.contentsOfDirectory(atPath: privateFolder.path).count, 1)
            }
            t.check(unchanged(first)); t.check(unchanged(second))
            guard let source = first.sources.first else { throw Failure.fixture("source stamp") }
            try worker.sync {
                try DeskProgramResources.withPreparedImage(source, in: first) { fd, count in
                    t.equal(count, png.count)
                    var buffer = [UInt8](repeating: 0, count: count), offset = 0
                    while offset < count {
                        let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
                        if read < 0 && errno == EINTR { continue }
                        guard read > 0 else { throw Failure.fixture("prepared descriptor short read") }
                        offset += read
                    }
                    var trailing: UInt8 = 0
                    t.equal(Darwin.read(fd, &trailing, 1), 0)
                    t.equal(Data(buffer), png)
                }
            }
            first.removeCopies()
            t.check(!unchanged(first)); t.check(unchanged(second))
            t.equal(try bytes(two), png, "cleanup of one preparation leaves the other owner's copy intact")
        }

        t.suite("App: Desk package resources: changed unreferenced members invalidate freshness without replacing snapshot bytes") {
            let original = try encodedImage(), replacement = try encodedImage(alternate: true)
            t.check(original != replacement)
            let folder = try root(t, files: [("image.png", original), ("unused.txt", Data("first".utf8))])
            let captured = try capture(folder), prepared = prepare(captured, ["image.png"])
            defer { prepared.removeCopies() }
            t.equal(prepared.failure, nil); t.check(unchanged(prepared))
            try Data("second".utf8).write(to: folder.appendingPathComponent("unused.txt"))
            t.check(!unchanged(prepared), "a source outside the reference graph participates in whole-package freshness")
            t.equal(try bytes(image(prepared, "image.png")), original)
            try replacement.write(to: folder.appendingPathComponent("image.png"))
            let fromSnapshot = prepare(captured, ["image.png"])
            defer { fromSnapshot.removeCopies() }
            t.equal(fromSnapshot.failure, nil)
            t.equal(try bytes(image(fromSnapshot, "image.png")), original, "preparation must not reopen the current source image")
            t.equal(fromSnapshot.sources, prepared.sources, "source stamps describe the capture, not the later disk version")
            t.check(!unchanged(fromSnapshot))
            try FileManager.default.removeItem(at: folder.appendingPathComponent("image.png"))
            let afterRemoval = prepare(captured, ["image.png"])
            defer { afterRemoval.removeCopies() }
            t.equal(afterRemoval.failure, nil)
            t.equal(try bytes(image(afterRemoval, "image.png")), original)
            t.check(!unchanged(afterRemoval))

            let latest = try capture(folder), noImages = prepare(latest, [])
            defer { noImages.removeCopies() }
            t.equal(noImages.failure, nil); t.check(noImages.images.isEmpty); t.check(unchanged(noImages))
            try Data([9]).write(to: folder.appendingPathComponent("added.bin"))
            t.check(!unchanged(noImages), "even an empty reference set validates complete package membership")
        }

        t.suite("App: Desk package resources: invalid and unavailable captured images fail the whole collection") {
            let png = try encodedImage()
            let folder = try root(t, files: [("valid.png", png), ("broken.png", Data("not an image".utf8)),
                                             ("header.png", Data(png.prefix(33))), ("picture.bin", png),
                                             (".secret.png", png), ("__MACOSX/private.png", png)])
            let captured = try capture(folder)
            t.check(!captured.files.contains { DeskPackagePath.kind(of: $0.path) == .ignored })
            let cases = [["valid.png", "broken.png"], ["broken.png", "valid.png"], ["valid.png", "header.png"],
                         ["valid.png", "missing.png"], ["valid.png", ".secret.png"], ["valid.png", "__MACOSX/private.png"],
                         ["valid.png", "picture.bin"], ["valid.png", "../valid.png"],
                         ["valid.png", folder.appendingPathComponent("valid.png").path]]
            for literals in cases {
                let prepared = prepare(captured, literals)
                defer { prepared.removeCopies() }
                t.check(prepared.failure != nil, literals.joined(separator: ", "))
                t.check(prepared.images.isEmpty && prepared.folder == nil, "a failed collection publishes no partial inputs")
                t.check(prepared.files.contains { $0.path == "valid.png" && $0.pixelSize == DeskPixelSize(width: 8, height: 6) },
                        "found valid-image metadata survives a different member's failure")
            }
            let recovered = prepare(captured, ["valid.png"])
            defer { recovered.removeCopies() }
            t.equal(recovered.failure, nil); t.equal(try bytes(image(recovered, "valid.png")), png)
            t.check(unchanged(recovered), "unreferenced malformed image bytes do not enter the image decoder")
        }

        t.suite("App: Desk package resources: private-copy checks and the legacy hidden-literal entry remain independent") {
            let png = try encodedImage()
            let folder = try root(t, files: [("valid.png", png), (".photos/hidden.png", png)])
            let captured = try capture(folder), first = prepare(captured, ["valid.png"]), second = prepare(captured, ["valid.png"])
            defer { first.removeCopies(); second.removeCopies() }
            t.equal(first.failure, nil); t.equal(second.failure, nil)
            let privateImage = try image(first, "valid.png")
            try (png + Data([0])).write(to: URL(fileURLWithPath: privateImage.path))
            t.check(!unchanged(first), "an unchanged source does not make a damaged private copy current")
            t.check(unchanged(second)); t.equal(try bytes(image(second, "valid.png")), png)
            let legacy = worker.sync {
                DeskProgramResources.prepare(root: folder, literals: ["./.PHOTOS/HIDDEN.PNG", ".photos/hidden.png"],
                                             maximumBytes: png.count, maximumFiles: 1, language: .english)
            }
            defer { legacy.removeCopies() }
            t.equal(legacy.failure, nil); t.check(legacy.capture == nil)
            t.equal(legacy.files.map(\.path), [".photos/hidden.png"])
            t.equal(legacy.images.count, 2)
            t.equal(try bytes(image(legacy, ".photos/hidden.png")), png)
            t.check(unchanged(legacy))
            try Data("new".utf8).write(to: folder.appendingPathComponent("unreferenced.txt"))
            t.check(!unchanged(second), "captured preparation uses whole membership")
            t.check(unchanged(legacy), "the pre-existing single-document entry checks its approved references")
        }

        t.suite("App: Desk package resources: drawing checks only owned copies after whole-package qualification") {
            let png = try encodedImage()
            let folder = try root(t, files: [("image.png", png)])
            let captured = try capture(folder), prepared = prepare(captured, ["image.png"])
            defer { prepared.removeCopies() }
            t.equal(prepared.failure, nil)
            t.check(unchanged(prepared)); t.check(prepared.copiesUnchanged())
            let owned = try image(prepared, "image.png")
            try FileManager.default.removeItem(at: folder)
            t.check(!unchanged(prepared), "explicit refresh still validates the entire original package")
            t.check(prepared.copiesUnchanged(), "ordinary drawing does not reopen the now-absent package")
            t.equal(try bytes(owned), png)
            try (png + Data([0])).write(to: URL(fileURLWithPath: owned.path))
            t.check(!prepared.copiesUnchanged(), "owned-copy damage remains a drawing failure")
            prepared.removeCopies()
            t.check(!prepared.copiesUnchanged(), "a released owner cannot reuse its removed private copy")
        }
    }
}
