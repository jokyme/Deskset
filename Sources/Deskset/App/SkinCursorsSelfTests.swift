import AppKit
import DesksetCore

/// `MouseActionCursorName`: every built-in Windows name has a cursor, and `.cur` / `.ani` files decode with their hot
/// spots (`SkinCursors`).
enum SkinCursorsSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: cursors: every built-in name has its own cursor") {
            let system: [String: NSCursor] = ["HAND": .pointingHand, "TEXT": .iBeam, "CROSS": .crosshair,
                                              "NO": .operationNotAllowed, "SIZE_WE": .resizeLeftRight,
                                              "SIZE_NS": .resizeUpDown]
            for (name, cursor) in system {
                t.check(SkinCursors.cursor(named: name.lowercased(), cursorsDirectory: nil) === cursor, name)
            }
            let drawn = ["HELP", "BUSY", "WAIT", "PEN", "UPARROW", "SIZE_ALL", "SIZE_NWSE", "SIZE_NESW"]
            var seen: [NSCursor] = []
            for name in drawn {
                let cursor = SkinCursors.cursor(named: " \(name) ", cursorsDirectory: nil)
                t.check(cursor !== NSCursor.arrow && cursor !== NSCursor.pointingHand, "\(name) is not a fallback")
                t.check(!seen.contains { $0 === cursor }, "\(name) differs from the others")
                t.check(cursor.image.size.width >= 16 && cursor.image.size.height >= 16, "\(name): \(cursor.image.size)")
                t.check(cursor === SkinCursors.cursor(named: name, cursorsDirectory: nil), "\(name) is made once")
                seen.append(cursor)
            }
            t.equal(SkinCursors.cursor(named: "HELP", cursorsDirectory: nil).hotSpot, NSCursor.arrow.hotSpot,
                    "Help points with the arrow's tip")
            let wait = SkinCursors.cursor(named: "WAIT", cursorsDirectory: nil)
            t.equal(wait.hotSpot, NSPoint(x: wait.image.size.width / 2, y: wait.image.size.height / 2))
            t.check(SkinCursors.cursor(named: nil, cursorsDirectory: nil) === NSCursor.arrow)
            t.check(SkinCursors.cursor(named: "", cursorsDirectory: nil) === NSCursor.arrow)
            t.check(SkinCursors.cursor(named: "Nonsense", cursorsDirectory: nil) === NSCursor.pointingHand,
                    "an unknown name shows the standard hand")
        }

        t.suite("App: cursors: .cur and .ani files from @Resources\\Cursors") {
            let skins = t.temporaryDirectory("cursors")
            defer { try? FileManager.default.removeItem(at: skins) }
            let dir = CursorFile.directory(skinsDirectory: skins, config: "Root\\Sub")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let cur = curFile([(32, 4, 6), (64, 8, 12)])
            try cur.write(to: dir.appendingPathComponent("Pointer.cur"))
            try curFile([(48, 24, 12)]).write(to: dir.appendingPathComponent("Big.cur"))
            try curFile([(16, 3, 3)]).write(to: dir.appendingPathComponent("Small.cur"))
            try animatedCursorFile([curFile([(32, 1, 2)]), cur], sequence: [1, 0]).write(to: dir.appendingPathComponent("Spin.ani"))
            try Data("not a cursor".utf8).write(to: dir.appendingPathComponent("Broken.cur"))

            let pointer = SkinCursors.cursor(named: "pointer.cur", cursorsDirectory: dir)
            t.equal(pointer.image.size, NSSize(width: 32, height: 32))
            t.equal(pointer.hotSpot, NSPoint(x: 4, y: 6), "the 32-pixel image's hot spot")
            t.equal(pointer.image.representations.count, 2, "with the 64-pixel image for Retina displays")
            t.check(SkinCursors.cursor(named: "Pointer.cur", cursorsDirectory: dir) === pointer, "decoded once")

            let big = SkinCursors.cursor(named: "Big.cur", cursorsDirectory: dir)
            t.equal(big.image.size, NSSize(width: 32, height: 32), "larger images show at 32 points")
            t.equal(big.hotSpot, NSPoint(x: 16, y: 8), "with the hot spot scaled")
            t.equal(SkinCursors.cursor(named: "Small.cur", cursorsDirectory: dir).image.size, NSSize(width: 16, height: 16),
                    "smaller images keep their size")
            t.equal(SkinCursors.cursor(named: "Spin.ani", cursorsDirectory: dir).hotSpot, NSPoint(x: 4, y: 6),
                    "an .ani shows the first frame of its sequence")
            t.check(SkinCursors.cursor(named: "Broken.cur", cursorsDirectory: dir) === NSCursor.pointingHand)
            t.check(SkinCursors.cursor(named: "Missing.cur", cursorsDirectory: dir) === NSCursor.pointingHand)
            t.check(SkinCursors.cursor(named: "Pointer.cur", cursorsDirectory: nil) === NSCursor.pointingHand)

            try curFile([(32, 10, 11)]).write(to: dir.appendingPathComponent("Pointer.cur"))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                                  ofItemAtPath: dir.appendingPathComponent("Pointer.cur").path)
            t.equal(SkinCursors.cursor(named: "Pointer.cur", cursorsDirectory: dir).hotSpot, NSPoint(x: 10, y: 11),
                    "a changed file is read again")
        }
    }

    /// A `.cur` file of square PNG images `(size, hotX, hotY)` (Windows has accepted PNG cursor images since Vista).
    private static func curFile(_ images: [(Int, Int, Int)]) -> Data {
        let pngs = images.map { png(size: $0.0) }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16) }
        var bytes: [UInt8] = [0, 0, 2, 0] + le16(images.count)
        var offset = 6 + images.count * 16
        for (i, (size, x, y)) in images.enumerated() {
            bytes += [UInt8(size & 0xFF), UInt8(size & 0xFF), 0, 0] + le16(x) + le16(y) + le32(pngs[i].count) + le32(offset)
            offset += pngs[i].count
        }
        for png in pngs { bytes += png }
        return Data(bytes)
    }

    private static func png(size: Int) -> [UInt8] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return [UInt8](rep.representation(using: .png, properties: [:])!)
    }

    private static func animatedCursorFile(_ frames: [Data], sequence: [Int]) -> Data {
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
            Array(id.utf8) + le32(body.count) + body + (body.count % 2 == 1 ? [0] : [])
        }
        let body = Array("ACON".utf8) + chunk("anih", [UInt8](repeating: 0, count: 36))
            + chunk("seq ", sequence.flatMap(le32))
            + chunk("LIST", Array("fram".utf8) + frames.flatMap { chunk("icon", [UInt8]($0)) })
        return Data(Array("RIFF".utf8) + le32(body.count) + body)
    }
}
