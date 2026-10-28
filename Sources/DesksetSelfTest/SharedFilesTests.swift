import Foundation
@testable import DesksetCore

/// The files a widget shares with the other widgets of its root config (`Skin.configsIncluding`) and writing a
/// widget's own value after its includes (`IniWriter.writingAfterIncludes`), in an encoding that can hold it.
/// Suites: "Shared files: …", "Ini: an edited ANSI file …".
func runSharedFilesTests(_ t: TestRunner) {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    func load(_ folder: String, _ config: String) throws -> Skin {
        let skins = repo.appendingPathComponent(folder)
        let parts = config.split(separator: "\\").map(String.init)
        let skin = Skin(config: config, fileURL: skins.appendingPathComponent(parts.joined(separator: "/"))
                            .appendingPathComponent("\(parts.last ?? "").ini"),
                        skinsDirectory: skins, system: FakeSystem(), host: FakeHost())
        try skin.load()
        skin.update()
        return skin
    }

    t.suite("Shared files: one walk finds the widgets reading each shared file") {
        let skin = try load("TestSkins", "Deskset\\System")
        let map = skin.includeMap()
        let variables = skin.resourcesDirectory.appendingPathComponent("Variables.inc")
        let readers = map.configs(including: variables)
        t.check(readers.contains("deskset\\system") && readers.contains("deskset\\clock"), "\(readers)")
        t.equal(skin.configsIncluding(variables), readers)
        t.equal(map.configs(including: skin.fileURL), [], "nothing includes a widget's own .ini")
    }

    t.suite("Shared files: which widgets read a shared file, kept between walks") {
        let skins = t.temporaryDirectory("includemap").appendingPathComponent("Skins")
        let fm = FileManager.default
        for dir in ["Root/A", "Root/B", "Root/@Resources"] {
            try fm.createDirectory(at: skins.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let shared = skins.appendingPathComponent("Root/@Resources/Shared.inc")
        try "[Variables]\nX=1\n".write(to: shared, atomically: true, encoding: .utf8)
        let a = skins.appendingPathComponent("Root/A/A.ini"), b = skins.appendingPathComponent("Root/B/B.ini")
        try "[Variables]\n@Include=#@#Shared.inc\n".write(to: a, atomically: true, encoding: .utf8)
        try "[Variables]\n@Include=#@#Shared.inc\n".write(to: b, atomically: true, encoding: .utf8)
        let skin = Skin(config: "Root\\A", fileURL: a, skinsDirectory: skins, system: FakeSystem(), host: FakeHost())
        try skin.load()
        t.equal(skin.configsIncluding(shared), ["root\\a", "root\\b"])
        // B no longer includes it (a later modification date): walked again, it is gone.
        try "[Variables]\nY=2\n".write(to: b, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: b.path)
        t.equal(skin.configsIncluding(shared), ["root\\a"], "a changed file is loaded again")
        // A new widget shows at once.
        try fm.createDirectory(at: skins.appendingPathComponent("Root/C"), withIntermediateDirectories: true)
        try "[Variables]\n@Include=#@#Shared.inc\n".write(to: skins.appendingPathComponent("Root/C/C.ini"),
                                                             atomically: true, encoding: .utf8)
        t.equal(skin.configsIncluding(shared), ["root\\a", "root\\c"], "a widget added")
        // A file an include path depends on: A reads Looks/#Look#.inc, Look set in Shared.inc.
        let looks = skins.appendingPathComponent("Root/@Resources/Looks")
        try fm.createDirectory(at: looks, withIntermediateDirectories: true)
        for name in ["Light", "Dark"] {
            try "[Variables]\nInk=1\n".write(to: looks.appendingPathComponent("\(name).inc"), atomically: true, encoding: .utf8)
        }
        try "[Variables]\nLook=Light\n".write(to: shared, atomically: true, encoding: .utf8)
        try "[Variables]\n@Include=#@#Shared.inc\n@Include2=#@#Looks/#Look#.inc\n".write(to: a, atomically: true,
                                                                                         encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: a.path)
        t.equal(skin.configsIncluding(looks.appendingPathComponent("Light.inc")), ["root\\a"])
        try "[Variables]\nLook=Dark\n".write(to: shared, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(15)], ofItemAtPath: shared.path)
        t.equal(skin.configsIncluding(looks.appendingPathComponent("Dark.inc")), ["root\\a"],
                "the file an include path reads changed: loaded again")
        t.equal(skin.configsIncluding(looks.appendingPathComponent("Light.inc")), [])
    }

    t.suite("Shared files: a widget's own value is written after its includes") {
        let w = { (text: String) throws -> String in
            try IniWriter.writingAfterIncludes(text, value: "1,2,3", key: "CPUColor", section: "Variables")
        }
        t.equal(try w("[Variables]\n@Include=a.inc\n@Include2=b.inc\nPanelHeight=196\n\n[M]\nMeter=String\n"),
                "[Variables]\n@Include=a.inc\n@Include2=b.inc\nPanelHeight=196\nCPUColor=1,2,3\n\n[M]\nMeter=String\n")
        t.equal(try w("[Variables]\nCPUColor=9,9,9\n@Include=a.inc\nX=1\n"), "[Variables]\n@Include=a.inc\nX=1\nCPUColor=1,2,3\n",
                "a key before the include is moved after it")
        t.equal(try w("[Variables]\n@Include=a.inc\nCPUColor=9,9,9\nX=1\n"), "[Variables]\n@Include=a.inc\nCPUColor=1,2,3\nX=1\n",
                "after the include: updated in place")
        t.equal(try w("[Rainmeter]\n"), "[Rainmeter]\n\n[Variables]\nCPUColor=1,2,3\n", "no [Variables]: added")
    }

    t.suite("Ini: an edited ANSI file that can't hold the new text is saved as UTF-16 with a BOM") {
        let dir = t.temporaryDirectory("encoding")
        let url = dir.appendingPathComponent("Skin.ini")
        try Data("[Variables]\r\n@Include=#@#Theme.inc\r\nFont=Caf\u{E9}\r\n".utf8).write(to: url)
        // As Windows-1252 bytes: é is one byte.
        try (TextDecoding.encode("[Variables]\r\n@Include=#@#Theme.inc\r\nFont=Caf\u{E9}\r\n", as: .windows1252) ?? Data())
            .write(to: url)
        try IniWriter.writeAfterIncludes("ヒラギノ角ゴ", key: "Font", section: "Variables", fileURL: url)
        let bytes = [UInt8](try Data(contentsOf: url).prefix(2))
        t.equal(bytes, [0xFF, 0xFE], "UTF-16 LE with BOM, as IniWriter.writeValue saves it")
        t.equal(try TextDecoding.readFileDetectingEncoding(at: url).text.contains("Font=ヒラギノ角ゴ"), true)
        t.equal(TextDecoding.encodeForWriting("abc", preferring: .windows1252), Data("abc".utf8), "its own encoding when it can")
    }
}
