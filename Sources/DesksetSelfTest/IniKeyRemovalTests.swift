import Foundation
@testable import DesksetCore

func runIniKeyRemovalTests(_ t: TestRunner) {
    t.suite("IniWriter: removing a key keeps everything else") {
        let text = "; top\r\n[A]\r\nX=1\r\n; about Y\r\nY=2\r\nZ=3\r\n\r\n[B]\r\nY=9\r\n"
        t.equal(IniWriter.removingKey(text, key: "y", section: "a"),
                "; top\r\n[A]\r\nX=1\r\n; about Y\r\nZ=3\r\n\r\n[B]\r\nY=9\r\n", "only [A] loses Y, comments stay")
        t.equal(IniWriter.removingKey(text, key: "Missing", section: "A"), text, "unknown key: unchanged")
        t.equal(IniWriter.removingKey(text, key: "Y", section: "C"), text, "unknown section: unchanged")
        t.equal(IniWriter.removingKey("[A]\nX=1\nX=2\nY=3\n", key: "X", section: "A"), "[A]\nY=3\n",
                "every definition in the block goes, so no second one takes its place")
        t.equal(IniWriter.removingKey("[A]\nX=1\n[B]\nX=2\n[A]\nX=3\n", key: "X", section: "A"), "[A]\n[B]\nX=2\n[A]\nX=3\n",
                "a repeated block later in the file is left alone")
        t.equal(IniWriter.removingKey("[A]\nX=1\nY=2", key: "Y", section: "A"), "[A]\nX=1",
                "no final line break stays without one")
        t.equal(IniWriter.removingKey("[A]\n  x  = 1\n", key: "X", section: "A"), "[A]\n", "spacing and case ignored")
        t.equal(IniWriter.removingKey("[A]\nX=1\n", key: "", section: "A"), "[A]\nX=1\n")
    }

    t.suite("IniWriter: removeKey writes the file in its encoding") {
        let dir = t.temporaryDirectory("remove-key")
        let url = dir.appendingPathComponent("Skin.ini")
        let original = "[Rainmeter]\r\nUpdate=1000\r\n[M]\r\nMeter=String\r\nText=Größe\r\nFontSize=12\r\n"
        let utf16 = Data([0xFF, 0xFE]) + original.data(using: .utf16LittleEndian)!
        try utf16.write(to: url)
        t.check(try IniWriter.removeKey("FontSize", section: "M", fileURL: url), "removed")
        let data = try Data(contentsOf: url)
        t.equal(Array(data.prefix(2)), [0xFF, 0xFE], "BOM kept")
        t.equal(String(data: data.dropFirst(2), encoding: .utf16LittleEndian),
                "[Rainmeter]\r\nUpdate=1000\r\n[M]\r\nMeter=String\r\nText=Größe\r\n")
        t.check(try !IniWriter.removeKey("FontSize", section: "M", fileURL: url), "nothing left to remove")
        t.equal(try Data(contentsOf: url), data, "untouched when nothing is removed")
        do {
            try IniWriter.removeKey("X", section: "M", fileURL: dir.appendingPathComponent("missing.ini"))
            t.check(false, "missing file throws")
        } catch {
            t.check(error is IniWriterError, "missing file: \(error)")
        }
    }

    t.suite("Skin: removing an option falls back to the style, then the default") {
        let ini = """
            [Rainmeter]
            [Variables]
            @Include=#@#Vars.inc
            [StyleBig]
            FontSize=20
            [M]
            Meter=String
            MeterStyle=StyleBig
            FontSize=12
            Text=Hi
            """
        let (skin, _) = try makeSkin(t, ini, files: ["Root/@Resources/Vars.inc": "[Variables]\nColor=1,2,3\n"])
        t.equal(skin.meter(named: "M")?.rawOption("FontSize"), "12")
        t.equal(skin.ownDefinitionFile(section: "M", key: "FontSize"), skin.fileURL)
        t.equal(try skin.removeOwnOption(section: "M", key: "FontSize"), skin.fileURL)
        let text = try String(contentsOf: skin.fileURL, encoding: .utf8)
        t.check(!text.contains("FontSize=12") && text.contains("FontSize=20"), "own value gone, style kept")
        t.equal(try skin.removeOwnOption(section: "M", key: "FontSize"), nil, "the style's value is not the layer's own")
        t.equal(try skin.removeOwnOption(section: "M", key: "Nothing"), nil)
        // A variable defined in an included file is removed there.
        let vars = skin.resourcesDirectory.appendingPathComponent("Vars.inc")
        t.equal(try skin.removeOwnOption(section: "Variables", key: "Color")?.lastPathComponent, "Vars.inc")
        t.equal(try String(contentsOf: vars, encoding: .utf8), "[Variables]\n")
        let (reloaded, _) = try makeSkin(t, text)
        t.equal(reloaded.meter(named: "M")?.rawOption("FontSize"), "20", "the style's value applies again")
    }
}
