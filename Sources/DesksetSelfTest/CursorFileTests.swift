import Foundation
@testable import DesksetCore

/// `.cur` / `.ico` bytes: a directory of `(width, height, hotX, hotY)` entries, each followed by a dummy image.
func cursorFileBytes(type: UInt16 = 2, _ images: [(Int, Int, Int, Int)]) -> Data {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16) }
    var bytes: [UInt8] = [0, 0] + le16(Int(type)) + le16(images.count)
    var offset = 6 + images.count * 16
    for (w, h, x, y) in images {
        bytes += [UInt8(w & 0xFF), UInt8(h & 0xFF), 0, 0] + le16(x) + le16(y) + le32(4) + le32(offset)
        offset += 4
    }
    for _ in images { bytes += [1, 2, 3, 4] }
    return Data(bytes)
}

/// An `.ani` file holding `frames` (each a `.cur` file) and an optional `seq ` order.
func animatedCursorBytes(_ frames: [Data], sequence: [Int]? = nil) -> Data {
    func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        Array(id.utf8) + le32(body.count) + body + (body.count % 2 == 1 ? [0] : [])
    }
    var body: [UInt8] = Array("ACON".utf8)
    body += chunk("anih", [UInt8](repeating: 0, count: 36))
    if let sequence { body += chunk("seq ", sequence.flatMap(le32)) }
    body += chunk("LIST", Array("fram".utf8) + frames.flatMap { chunk("icon", [UInt8]($0)) })
    return Data(Array("RIFF".utf8) + le32(body.count) + body)
}

func runCursorFileTests(_ t: TestRunner) {
    t.suite("Cursor files: .cur and .ico directories") {
        let cur = CursorFile.entries(in: cursorFileBytes([(32, 32, 5, 7), (0, 0, 300, 9), (64, 64, 10, 14)]))
        t.equal(cur.count, 3)
        t.equal(cur[0], CursorFile.Entry(index: 0, width: 32, height: 32, hotSpotX: 5, hotSpotY: 7))
        t.equal(cur[1].width, 256, "a stored 0 means 256 pixels")
        t.equal(cur[1].hotSpotX, 255, "a hot spot is kept inside the image")
        let ico = CursorFile.entries(in: cursorFileBytes(type: 1, [(16, 16, 4, 4)]))
        t.equal(ico.first?.hotSpotX, 0, "icons have no hot spot")
        t.equal(CursorFile.entries(in: Data([0, 0, 3, 0, 1, 0])), [], "another type")
        t.equal(CursorFile.entries(in: Data([0, 0, 2, 0, 9, 0, 1])), [], "a truncated directory")
        t.equal(CursorFile.entries(in: Data()), [])

        t.equal(CursorFile.bestEntry(cur, scale: 1)?.index, 0, "32 pixels at 1x")
        t.equal(CursorFile.bestEntry(cur, scale: 2)?.index, 2, "64 pixels at 2x")
        t.equal(CursorFile.bestEntry(CursorFile.entries(in: cursorFileBytes([(16, 16, 0, 0), (24, 24, 0, 0)])))?.width, 24,
                "the largest when none is big enough")
        t.equal(CursorFile.bestEntry([]), nil)
    }

    t.suite("Cursor files: the first frame of an .ani") {
        let a = cursorFileBytes([(32, 32, 1, 1)]), b = cursorFileBytes([(32, 32, 2, 2), (48, 48, 3, 3)])
        t.equal(CursorFile.firstAnimatedFrame(in: animatedCursorBytes([a, b])), a)
        t.equal(CursorFile.firstAnimatedFrame(in: animatedCursorBytes([a, b], sequence: [1, 0])), b, "seq gives the order")
        t.equal(CursorFile.firstAnimatedFrame(in: animatedCursorBytes([a, b], sequence: [7])), a, "a bad seq is ignored")
        t.equal(CursorFile.firstAnimatedFrame(in: animatedCursorBytes([])), nil)
        t.equal(CursorFile.firstAnimatedFrame(in: a), nil, "a .cur is not animated")
        var truncated = animatedCursorBytes([a])
        truncated.removeLast(10)
        t.equal(CursorFile.firstAnimatedFrame(in: truncated), nil, "a frame cut short is not read")
    }

    t.suite("Cursor files: names are looked up in @Resources\\Cursors, ignoring case") {
        let skins = t.temporaryDirectory("cursor-files")
        defer { try? FileManager.default.removeItem(at: skins) }
        let dir = CursorFile.directory(skinsDirectory: skins, config: "Root\\Sub")
        t.equal(dir.path, skins.appendingPathComponent("Root/@Resources/Cursors").path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try cursorFileBytes([(32, 32, 0, 0)]).write(to: dir.appendingPathComponent("Pointer.cur"))
        try Data().write(to: dir.appendingPathComponent("Spin.ANI"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder.cur"), withIntermediateDirectories: true)
        t.equal(CursorFile.file(named: "Pointer.cur", in: dir)?.lastPathComponent, "Pointer.cur")
        t.equal(CursorFile.file(named: " pointer.CUR ", in: dir)?.lastPathComponent, "Pointer.cur")
        t.equal(CursorFile.file(named: "spin.ani", in: dir)?.lastPathComponent, "Spin.ANI")
        t.equal(CursorFile.file(named: "HAND", in: dir), nil, "built-in names are not files")
        t.equal(CursorFile.file(named: "Pointer.png", in: dir), nil, "only .cur and .ani")
        t.equal(CursorFile.file(named: "..\\Cursors\\Pointer.cur", in: dir), nil, "no path is used")
        t.equal(CursorFile.file(named: "Cursors/Pointer.cur", in: dir), nil)
        t.equal(CursorFile.file(named: "Folder.cur", in: dir), nil, "a folder is not a cursor")
        t.equal(CursorFile.file(named: "Missing.cur", in: dir), nil)
    }
}
