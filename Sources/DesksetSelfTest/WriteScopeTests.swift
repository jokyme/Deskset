import Foundation
@testable import DesksetCore

// Where a change to one option of a part is written (`WriteScope`, `WriteScopes`): the scopes a part's option can
// take, and golden write-backs for each — the bytes of every file before and after, and the inverse step giving the
// bytes back exactly (line endings and a byte order mark included).

func runWriteScopeTests(_ t: TestRunner) {
    /// A suite of two widgets over one shared file: Root/Sub/Skin.ini (CRLF) and Root/Other/Other.ini, both including
    /// Root/@Resources/Theme.inc (UTF-8 with a BOM).
    struct Fixture {
        let skins: URL
        let main: URL
        let other: URL
        let theme: URL
        let mainBytes: Data
        let themeBytes: Data
        let skin: Skin

        static let mainText = [
            "[Rainmeter]", "Update=1000", "", "[Variables]", "@Include=#@#Theme.inc", "Gap=4", "",
            "[MeterA]", "Meter=String", "MeterStyle=sValue", "Text=10%", "X=0", "Y=0", "",
            "[MeterB]", "Meter=String", "MeterStyle=sValue", "Text=20%", "X=0", "Y=20", "",
            "[MeterC]", "Meter=String", "MeterStyle=sValue", "Text=30%", "X=0", "Y=40", "Hidden=1", "",
            "[MeterOwn]", "Meter=String", "MeterStyle=sValue", "FontSize=9", "Text=own", "X=0", "Y=60", "",
            "[MeterLabel]", "Meter=String", "FontColor=#TextColor#", "Text=CPU", "X=0", "Y=80", "",
        ].joined(separator: "\r\n")

        static let themeText = """
            [Variables]
            TextColor=255,255,255

            [sValue]
            FontSize=12
            FontColor=#TextColor#

            """

        static let otherText = """
            [Variables]
            @Include=#@#Theme.inc

            [MeterX]
            Meter=String
            MeterStyle=sValue
            Text=x

            """

        init(_ t: TestRunner) throws {
            skins = t.temporaryDirectory("writescope").appendingPathComponent("Skins")
            let fm = FileManager.default
            for dir in ["Root/Sub", "Root/Other", "Root/@Resources"] {
                try fm.createDirectory(at: skins.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            main = skins.appendingPathComponent("Root/Sub/Skin.ini")
            other = skins.appendingPathComponent("Root/Other/Other.ini")
            theme = skins.appendingPathComponent("Root/@Resources/Theme.inc")
            mainBytes = Data(Self.mainText.utf8)
            themeBytes = Data([0xEF, 0xBB, 0xBF]) + Data(Self.themeText.utf8)
            try mainBytes.write(to: main)
            try themeBytes.write(to: theme)
            try Data(Self.otherText.utf8).write(to: other)
            skin = Skin(config: "Root\\Sub", fileURL: main, skinsDirectory: skins, system: FakeSystem(), host: FakeHost())
            try skin.load()
        }
    }

    /// The bytes `ops` make of each file, and whether undoing gives the original bytes back.
    func golden(_ f: Fixture, _ ops: [EditOp], _ message: String,
                expect: [(URL, String, bom: Bool)]) throws {
        let buffers = SourceBuffers()
        let changes = try IniBackend.plan(ops, in: buffers)
        t.equal(changes.count, expect.count, "\(message): files changed")
        let originals = changes.map { change -> Data in
            (try? Data(contentsOf: change.file.url)) ?? Data()
        }
        try buffers.apply(changes)
        for (url, text, bom) in expect {
            let bytes = (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
            let got = buffers.buffer(url)?.data ?? Data()
            t.equal(String(decoding: got, as: UTF8.self), String(decoding: bytes, as: UTF8.self),
                    "\(message): \(url.lastPathComponent) after")
            t.check(got == bytes, "\(message): \(url.lastPathComponent) byte for byte")
        }
        try buffers.apply(changes, reverse: true)
        for (i, change) in changes.enumerated() {
            t.check(buffers.buffer(change.file.url)?.data == originals[i],
                    "\(message): undone, \(change.file.url.lastPathComponent) has its bytes back")
        }
    }

    t.suite("Write scope: the choices a part's option has") {
        let f = try Fixture(t)
        let skin = f.skin
        skin.update()
        let size = WriteScopes.choices(meter: "MeterA", key: "FontSize", in: skin)
        t.equal(size.map(\.scope), [.element, .style("sValue"),
                                    .package(file: f.theme, section: "sValue", key: "FontSize")],
                "this number · the style · the suite's file")
        t.equal(size.first?.parts, ["MeterA"])
        t.equal(size[1].parts, ["MeterA", "MeterB", "MeterC"], "MeterOwn sets its own size: not reached")
        t.equal(size[1].visibleParts, ["MeterA", "MeterB"], "the hidden one changes, but is not counted as seen")
        t.equal(Set(size[2].widgets.map { $0.lowercased() }), ["root\\sub", "root\\other"], "both widgets read Theme.inc")
        let color = WriteScopes.choices(meter: "MeterA", key: "FontColor", in: skin)
        t.equal(color.map(\.scope), [.element, .style("sValue"), .sharedValue("TextColor"),
                                     .package(file: f.theme, section: "Variables", key: "TextColor")],
                "a color written as a variable: the variable too, and the file that defines it")
        t.equal(color[2].parts, ["MeterA", "MeterB", "MeterC", "MeterOwn", "MeterLabel"])
        let label = WriteScopes.choices(meter: "MeterLabel", key: "FontColor", in: skin)
        t.equal(label.map(\.scope), [.element, .sharedValue("TextColor"),
                                     .package(file: f.theme, section: "Variables", key: "TextColor")])
        let own = WriteScopes.choices(meter: "MeterOwn", key: "FontSize", in: skin)
        t.equal(own.map(\.scope), [.element], "its own value: only itself")
        t.equal(WriteScopes.choices(meter: "MeterLabel", key: "Text", in: skin).map(\.scope), [.element])
        t.equal(WriteScopes.choices(meter: "NoSuchMeter", key: "Text", in: skin).count, 0)
        t.equal(WriteScopes.soleVariable(" #TextColor# "), "TextColor")
        t.equal(WriteScopes.soleVariable("#A##B#"), nil)
        t.equal(WriteScopes.soleVariable("255,#Alpha#"), nil)
        t.equal(WriteScopes.soleVariable("[#Nested]"), nil)
        t.equal(WriteScopes.soleVariable("#*Escaped*#"), nil)
    }

    t.suite("Write scope: golden write-backs and their inverses") {
        let f = try Fixture(t)
        let skin = f.skin
        let main = Fixture.mainText
        // .element: the meter's own section, at the end of its block.
        try golden(f, WriteScopes.ops(.element, meter: "MeterA", key: "FontSize", value: "14", in: skin),
                   "this number only", expect: [(f.main, main.replacingOccurrences(
                    of: "Text=10%\r\nX=0\r\nY=0\r\n", with: "Text=10%\r\nX=0\r\nY=0\r\nFontSize=14\r\n"), false)])
        // .element over a value of its own: that value changes in place.
        try golden(f, WriteScopes.ops(.element, meter: "MeterOwn", key: "FontSize", value: "11", in: skin),
                   "its own value", expect: [(f.main, main.replacingOccurrences(of: "FontSize=9", with: "FontSize=11"),
                                              false)])
        // .style: the shared file's style is overridden for this widget by a block of its own at the end of its file.
        try golden(f, WriteScopes.ops(.style("sValue"), meter: "MeterA", key: "FontSize", value: "14", in: skin),
                   "the style, for this widget", expect: [(f.main, main + "\r\n[sValue]\r\nFontSize=14\r\n", false)])
        // .sharedValue: the widget's own [Variables], after its @Include so it wins over the shared definition.
        try golden(f, WriteScopes.ops(.sharedValue("TextColor"), meter: "MeterLabel", key: "FontColor",
                                      value: "10,20,30", in: skin),
                   "the variable, for this widget", expect: [(f.main, main.replacingOccurrences(
                    of: "Gap=4\r\n", with: "Gap=4\r\nTextColor=10,20,30\r\n"), false)])
        // .package: the shared file itself, its byte order mark kept.
        try golden(f, WriteScopes.ops(.package(file: f.theme, section: "sValue", key: "FontSize"), meter: "MeterA",
                                      key: "FontSize", value: "13", in: skin),
                   "the suite's file", expect: [(f.theme, Fixture.themeText.replacingOccurrences(
                    of: "FontSize=12", with: "FontSize=13"), true)])
        try golden(f, WriteScopes.ops(.package(file: f.theme, section: "Variables", key: "TextColor"),
                                      meter: "MeterLabel", key: "FontColor", value: "1,2,3", in: skin),
                   "the suite's variable", expect: [(f.theme, Fixture.themeText.replacingOccurrences(
                    of: "TextColor=255,255,255", with: "TextColor=1,2,3"), true)])
    }

    t.suite("Write scope: all widgets means this one too") {
        // This widget overrides the shared variable: writing the suite's file also takes its own value away, and the
        // inverse puts both back.
        let f = try Fixture(t)
        let overridden = Fixture.mainText.replacingOccurrences(of: "@Include=#@#Theme.inc\r\n",
                                                               with: "@Include=#@#Theme.inc\r\nTextColor=9,9,9\r\n")
        try Data(overridden.utf8).write(to: f.main)
        let skin = Skin(config: "Root\\Sub", fileURL: f.main, skinsDirectory: f.skins, system: FakeSystem(),
                        host: FakeHost())
        try skin.load()
        let choices = WriteScopes.choices(meter: "MeterLabel", key: "FontColor", in: skin)
        guard let package = choices.last, case .package = package.scope else {
            return t.check(false, "a package scope: \(choices.map(\.scope))")
        }
        let ops = WriteScopes.ops(package.scope, meter: "MeterLabel", key: "FontColor", value: "1,2,3", in: skin)
        t.equal(ops.count, 2, "the shared file, and this widget's own value removed")
        let buffers = SourceBuffers()
        let changes = try IniBackend.plan(ops, in: buffers)
        try buffers.apply(changes)
        t.equal(buffers.buffer(f.main)?.data, Data(Fixture.mainText.utf8), "the override is gone")
        try buffers.apply(changes, reverse: true)
        t.equal(buffers.buffer(f.main)?.data, Data(overridden.utf8), "undone: back byte for byte")
        t.equal(buffers.buffer(f.theme)?.data, f.themeBytes, "undone: the shared file too")
    }

    t.suite("Write scope: a part only a shared file defines") {
        // Both widgets include Parts.inc, which defines [MeterBackground]; this widget's own [MeterZ] takes its size
        // from an include inside its block.
        let skins = t.temporaryDirectory("writescope-shared").appendingPathComponent("Skins")
        let fm = FileManager.default
        for dir in ["Root/Sub", "Root/Other", "Root/@Resources"] {
            try fm.createDirectory(at: skins.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let main = skins.appendingPathComponent("Root/Sub/Skin.ini")
        let parts = skins.appendingPathComponent("Root/@Resources/Parts.inc")
        let mainText = "[Variables]\n@Include=#@#Parts.inc\n\n[MeterZ]\nMeter=String\n@Include=#@#Z.inc\nText=z\n"
        try Data(mainText.utf8).write(to: main)
        try Data("[MeterBackground]\nMeter=Image\nW=100\nH=50\nSolidColor=0,0,0\n".utf8).write(to: parts)
        try Data("[MeterZ]\nFontSize=20\n".utf8).write(to: skins.appendingPathComponent("Root/@Resources/Z.inc"))
        try Data("[Variables]\n@Include=#@#Parts.inc\n".utf8).write(to: skins.appendingPathComponent("Root/Other/Other.ini"))
        let skin = Skin(config: "Root\\Sub", fileURL: main, skinsDirectory: skins, system: FakeSystem(), host: FakeHost())
        try skin.load()
        t.check(skin.meter(named: "MeterBackground") != nil, "the shared part loads")
        t.check(!WriteScopes.isLocal(meter: "MeterBackground", key: "SolidColor", in: skin), "not this widget's own")
        t.equal(WriteScopes.ops(.element, meter: "MeterBackground", key: "SolidColor", value: "1,2,3", in: skin), [],
                "this part only: nothing is written into the file both widgets read")
        t.equal(WriteScopes.ops(.element, meter: "MeterBackground", key: "Hidden", value: "1", in: skin), [],
                "nor is it hidden there")
        let choices = WriteScopes.choices(meter: "MeterBackground", key: "SolidColor", in: skin)
        t.equal(choices.map(\.scope), [.element, .package(file: parts, section: "MeterBackground", key: "SolidColor")],
                "the shared file is offered, as one explicit choice")
        t.equal(Set(choices.last?.widgets.map { $0.lowercased() } ?? []), ["root\\sub", "root\\other"])
        let package = WriteScopes.ops(choices[1].scope, meter: "MeterBackground", key: "SolidColor", value: "1,2,3",
                                      in: skin)
        t.equal(package, [.setValue(file: parts, section: "MeterBackground", key: "SolidColor", value: "1,2,3",
                                    afterIncludes: false)])
        // The header is this widget's, the value an include's: written after the block's @Include, so it wins.
        t.check(WriteScopes.isLocal(meter: "MeterZ", key: "FontSize", in: skin))
        let z = WriteScopes.ops(.element, meter: "MeterZ", key: "FontSize", value: "24", in: skin)
        t.equal(z, [.setValue(file: main, section: "MeterZ", key: "FontSize", value: "24", afterIncludes: true)])
        let buffers = SourceBuffers()
        try buffers.apply(try IniBackend.plan(z, in: buffers))
        let written = String(decoding: buffers.buffer(main)?.data ?? Data(), as: UTF8.self)
        try written.write(to: main, atomically: true, encoding: .utf8)
        let reloaded = Skin(config: "Root\\Sub", fileURL: main, skinsDirectory: skins, system: FakeSystem(),
                            host: FakeHost())
        try reloaded.load()
        t.equal(reloaded.meter(named: "MeterZ")?.option("FontSize"), "24", "the step takes effect: \(written)")
    }
}
