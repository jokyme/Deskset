import Foundation
@testable import DesksetCore

func runEditorTests(_ t: TestRunner) {
    t.suite("Editor: offsets keep the written form") {
        let cases: [(String?, Double, String)] = [
            (nil, 20, "20"),
            ("", -5, "-5"),
            ("100", 20, "120"),
            ("100", -120, "-20"),
            ("12.5", 0.25, "12.75"),
            (".5", 1, "1.5"),
            ("10R", 20, "30R"),
            ("10r", -10, "0r"),
            ("R", 5, "5R"),
            ("  8  ", 2, "10"),
            ("(5)", 3, "(8)"),
            ("(#A# + 5)", 20, "(#A# + 25)"),
            ("(#A# + 5)", -5, "(#A#)"),
            ("(#A# - 5)", 20, "(#A# + 15)"),
            ("(#A# * 2)", 20, "(#A# * 2 + 20)"),
            ("(#A# * 2)", -3, "(#A# * 2 - 3)"),
            ("(10 - #A#)", 4, "(10 - #A# + 4)"),
            ("(#W# - #Pad#)R", 6, "(#W# - #Pad# + 6)R"),
            ("(1e+5)", 1, "(1e+5 + 1)"),  // the exponent sign is not an operator
            ("(a > 1 ? 5 : 9)", 20, "((a > 1 ? 5 : 9) + 20)"),
            ("#Margin#", 20, "(#Margin# + 20)"),
            ("#Margin#r", -4, "(#Margin# - 4)r"),
            ("[MeterA:X]", 3, "([MeterA:X] + 3)"),
            ("(1) + (2)", 1, "((1) + (2) + 1)"),
            ("100", 0, "100"),
        ]
        for (raw, delta, expected) in cases {
            t.equal(GeometryEdit.offset(raw, by: delta), expected, "\(raw ?? "nil") \(delta)")
        }
        t.equal(GeometryEdit.format(3.14159), "3.14")
        t.equal(GeometryEdit.format(-0.001), "0")
    }

    t.suite("Editor: offsets evaluate to the moved value") {
        let formulas = ["(12 * 2)", "(30 - 4 + 1)", "(2 > 1 ? 5 : 9)", "((1 + 2) * 3)", "(-5)"]
        for f in formulas {
            guard let before = OptionValue.number(f) else { t.check(false, "parse \(f)"); continue }
            let moved = GeometryEdit.offset(f, by: 7)
            t.equal(OptionValue.number(moved), before + 7, "\(f) → \(moved)")
        }
        t.equal(OptionValue.position(GeometryEdit.offset("(4 * 2)R", by: 2)), PositionValue(value: 10, mode: .relativeToPreviousEnd))
    }

    t.suite("Editor: snapping") {
        let skin = SkinRect(x: 0, y: 0, width: 200, height: 100)
        let other = SkinRect(x: 50, y: 40, width: 30, height: 10)
        var r = EditorSnapping.snap(SkinRect(x: 52, y: 70, width: 20, height: 10), to: [skin, other], threshold: 4)
        t.equal(r.dx, -2, "left edges align")
        t.equal(r.guides.first, EditorSnapping.Guide(axis: .vertical, position: 50))
        r = EditorSnapping.snap(SkinRect(x: 89, y: 43, width: 20, height: 10), to: [skin, other], threshold: 4)
        t.equal(r.dx, 1, "center 99 snaps to the skin center 100")
        t.equal(r.dy, 2, "nearest line wins (middle 48 → 50)")
        r = EditorSnapping.snap(SkinRect(x: 120, y: 20, width: 10, height: 10), to: [skin, other], threshold: 4)
        t.equal(r, EditorSnapping.Result(dx: 0, dy: 0, guides: []))
    }

    t.suite("Editor: colors keep their notation") {
        let c = RGBA(r: 255, g: 128, b: 0, a: 255)
        t.equal(ColorText.format(c, like: "10,20,30"), "255,128,0")
        t.equal(ColorText.format(c, like: "10,20,30,255"), "255,128,0,255")
        t.equal(ColorText.format(RGBA(r: 255, g: 128, b: 0, a: 100), like: "10,20,30"), "255,128,0,100")
        t.equal(ColorText.format(c, like: "0A141E"), "FF8000")
        t.equal(ColorText.format(c, like: "0a141e80"), "ff8000ff")
        t.equal(ColorText.format(c, like: nil), "255,128,0")
        t.equal(ColorText.format(RGBA(r: 300, g: -4, b: 12.6, a: 255), like: "1,1,1"), "255,0,13")
    }

    t.suite("Editor: undo restores bytes only when unchanged elsewhere") {
        let dir = t.temporaryDirectory("editor-undo")
        let file = dir.appendingPathComponent("Skin.ini")
        try "[M]\r\nX=1\r\n".write(to: file, atomically: true, encoding: .utf8)
        let changes = try EditorFileChange.record([file, file]) {
            try IniWriter.writeValue("5", key: "X", section: "M", fileURL: file)
        }
        t.equal(changes.count, 1)
        try EditorFileChange.restore(changes, undo: true)
        t.equal(try String(contentsOf: file, encoding: .utf8), "[M]\r\nX=1\r\n")
        try EditorFileChange.restore(changes, undo: false)
        t.equal(try String(contentsOf: file, encoding: .utf8), "[M]\r\nX=5\r\n")
        try "[M]\r\nX=9\r\n".write(to: file, atomically: true, encoding: .utf8)
        do {
            try EditorFileChange.restore(changes, undo: true)
            t.check(false, "undo over an external change must fail")
        } catch let failure as EditorFileChange.Failure {
            t.equal(failure, .changedElsewhere(file.resolvingSymlinksInPath()))
        }
        t.equal(try String(contentsOf: file, encoding: .utf8), "[M]\r\nX=9\r\n", "nothing overwritten")
        let none = EditorFileChange.record([file]) {}
        t.equal(none.count, 0)
    }

    t.suite("Editor: preview and own-section writes") {
        let ini = """
        [Rainmeter]
        [Variables]
        Accent=255,0,0
        [Style]
        X=10
        FontColor=#Accent#
        [A]
        Meter=String
        MeterStyle=Style
        Text=Hello
        [B]
        Meter=String
        X=0R
        Text=World
        """
        let (skin, _) = try makeSkin(t, ini)
        skin.update()
        guard let a = skin.meter(named: "A"), let b = skin.meter(named: "B") else { return t.check(false, "meters") }
        skin.execute("[!SetOption A Text Runtime]", from: nil)
        skin.update()  // the new text is measured on the next update
        let bX = b.frame.x
        skin.preview(section: "A", ["X": GeometryEdit.offset(a.rawGeometry.x, by: 15)])
        t.equal(a.frame.x, 25, "preview moves the meter")
        t.equal(b.frame.x, bX + 15, "a relative meter follows")
        t.check(skin.isPreviewing)
        skin.endPreview()
        t.equal(a.frame.x, 10, "preview undone")
        t.equal(a.rawOption("Text"), "Runtime", "real !SetOption values survive a preview")
        t.check(!skin.isPreviewing)

        skin.previewVariables(["Accent": "0,255,0"])
        t.equal(a.option("FontColor"), "0,255,0")
        skin.endPreview()
        t.equal(skin.variable("Accent"), "255,0,0")

        // Dragging A writes X into [A], not into its style.
        let target = try skin.writeOwnOption(section: "A", key: "X", value: "25")
        t.equal(target.section, "A")
        let text = try String(contentsOf: skin.fileURL, encoding: .utf8)
        t.check(text.contains("[Style]\nX=10\n"), "style untouched")
        t.check(text.contains("Text=Hello\nX=25\n"), "override appended to [A]")
        t.equal(skin.ownTarget(section: "B", key: "X").file, skin.fileURL.standardizedFileURL)
    }
}

func runEditorModelTests(_ t: TestRunner) {
    t.suite("Editor: removing a section") {
        let text = "[A]\nX=1\n\n[B]\nY=2\n\n; about C\n[C]\nZ=3\n"
        t.equal(IniWriter.removingSection(text, section: "b"), "[A]\nX=1\n\n; about C\n[C]\nZ=3\n")
        t.equal(IniWriter.removingSection(text, section: "C"), "[A]\nX=1\n\n[B]\nY=2\n\n; about C\n")
        t.equal(IniWriter.removingSection("[A]\r\nX=1\r\n\r\n[B]\r\nY=2\r\n", section: "B"), "[A]\r\nX=1\r\n")
        t.equal(IniWriter.removingSection(text, section: "Missing"), text)
        // A repeated header: readers ignore the later block, which would become the section once the first is gone.
        t.equal(IniWriter.removingSection("[A]\n[B]\n[A]\nX=1\n", section: "A"), "[B]\n", "every block of it")
        t.equal(IniWriter.removingSection("[B]\nY=2\n[A]\nX=1\n[B]\nY=9\n", section: "b"), "[A]\nX=1\n",
                "the ignored duplicate goes too")
        t.check(IniWriter.definesSection("[A]\n [ b ] \nY=2\n", section: "B"))
        t.check(!IniWriter.definesSection("[A]\nB=1\n;[B]\n", section: "B"), "keys and comments are not headers")
    }

    t.suite("Editor: components") {
        let plain = EditorComponents.sections(for: "cpu", x: 10, y: 20, existing: ["MeasureCPU"], variables: [])
        t.equal(plain.map(\.name), ["MeasureCPU2", "MeterCPUBar"])
        t.equal(plain[1].options.first { $0.key == "MeasureName" }?.value, "MeasureCPU2")
        t.equal(plain[1].options.first { $0.key == "X" }?.value, "10")
        let themed = EditorComponents.sections(for: "clock", x: 0, y: 0, existing: [], variables: ["textcolor", "fontface"])
        let meter = themed[1].options
        t.equal(meter.first { $0.key == "FontColor" }?.value, "#TextColor#")
        t.equal(meter.first { $0.key == "FontFace" }?.value, "#FontFace#")
        t.equal(meter.filter { $0.key == "FontSize" }.count, 1, "overridden keys appear once")
        t.equal(meter.first { $0.key == "FontSize" }?.value, "28")
        for c in EditorComponents.all {
            let sections = EditorComponents.sections(for: c.id, x: 5, y: 5, existing: [], variables: [])
            t.check(sections.contains { $0.options.contains { $0.key == "Meter" } }, "\(c.id) has a meter")
        }
        t.equal(EditorComponents.uniqueName("A", taken: ["a", "a2"]), "A3")
    }

    t.suite("Editor: components load and draw") {
        // All together in one skin (names must not clash), then each on its own at a known corner. Components
        // with app-registered measures (NowPlaying, WiFiStatus) are checked by the app self-test.
        let core = EditorComponents.all.filter { !$0.needsAppMeasures }
        var ini = "[Rainmeter]\nUpdate=1000\n"
        var names: Set<String> = []
        var meterCount = 0
        for c in core {
            for s in EditorComponents.sections(for: c.id, x: 5, y: 5, existing: names, variables: []) {
                names.insert(s.name.lowercased())
                if s.options.contains(where: { $0.key == "Meter" }) { meterCount += 1 }
                ini += "[\(s.name)]\n" + s.options.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
            }
        }
        let (skin, host) = try makeSkin(t, ini)
        skin.update()
        t.equal(skin.issues, [], "every component is supported")
        t.equal(skin.meters.count, meterCount)
        t.check(skin.meters.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 }, "every meter has an area")
        t.equal(host.logs.filter { $0.hasPrefix("Warning") || $0.hasPrefix("Error") }, [], "nothing to warn about")

        for c in core {
            var single = "[Rainmeter]\nUpdate=1000\n"
            for s in EditorComponents.sections(for: c.id, x: 30, y: 40, existing: [], variables: ["accentcolor", "fontface"]) {
                single += "[\(s.name)]\n" + s.options.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
            }
            single += "[Variables]\nAccentColor=255,120,0\nFontFace=Helvetica\n"
            let (skin, host) = try makeSkin(t, single)
            skin.update()
            skin.update()
            t.equal(skin.issues, [], c.id)
            t.equal(host.logs.filter { $0.hasPrefix("Warning") || $0.hasPrefix("Error") }, [], c.id)
            let frames = skin.meters.map(\.frame)
            t.check(!frames.isEmpty && frames.allSatisfy { $0.width > 0 && $0.height > 0 }, "\(c.id) draws: \(frames)")
            // The component starts at its corner (the canvas centres drops on the default size from there).
            t.equal(frames.map(\.x).min(), 30, "\(c.id) left edge")
            t.equal(frames.map(\.y).min(), 40, "\(c.id) top edge")
        }
    }

    t.suite("Editor: component metadata") {
        let all = EditorComponents.all
        t.equal(Set(all.map(\.id)).count, all.count, "unique ids")
        t.equal(Set(all.map(\.title)).count, all.count, "unique titles")
        for c in all {
            t.check(!c.title.isEmpty && !c.summary.isEmpty && !c.symbol.isEmpty, "\(c.id) is described")
            t.check(c.defaultSize.width > 0 && c.defaultSize.height > 0, "\(c.id) has a size")
            t.check(c.badge.map { !$0.isEmpty } ?? true, "\(c.id) badge is a word")
            t.check(c.summary.count <= 45, "\(c.id) summary fits two short lines: \(c.summary)")
            t.equal(EditorComponents.component(c.id), c)
        }
        // Grouped in category order, and no category is empty (each is a chip in the library).
        let order = all.map { EditorComponents.Category.allCases.firstIndex(of: $0.category) ?? -1 }
        t.equal(order, order.sorted(), "grouped by category")
        for category in EditorComponents.Category.allCases {
            t.check(all.contains { $0.category == category }, "\(category) has components")
            t.check(!category.title.isEmpty && !category.symbol.isEmpty)
        }
        t.equal(EditorComponents.Category.allCases.map(\.title), ["Text", "Live Data", "Graphs", "Gauges", "Shapes", "Pictures"])
        t.equal(EditorComponents.component("nope"), nil)
        // Shapes and fixed-size meters are exactly their default size.
        t.equal(EditorComponents.component("cpu")?.defaultSize, EditorComponents.Size(width: 160, height: 6))
        t.equal(EditorComponents.component("circle")?.defaultSize, EditorComponents.Size(width: 48, height: 48))
        t.equal(Set(all.filter(\.needsAppMeasures).map(\.id)), ["wifi", "nowplaying", "albumart"])
        // The ids the editor used before the library keep working.
        for id in ["text", "clock", "date", "cpu", "memory", "network", "graph", "gauge", "disk", "rectangle"] {
            t.check(EditorComponents.component(id) != nil, "\(id) still exists")
        }
    }

    t.suite("Editor: component search") {
        func ids(_ q: String, _ c: EditorComponents.Category? = nil) -> [String] { EditorComponents.search(q, category: c).map(\.id) }
        t.equal(ids(""), EditorComponents.all.map(\.id), "empty query: everything in library order")
        t.equal(ids("   "), EditorComponents.all.map(\.id))
        t.equal(ids("", .shapes), ["rectangle", "circle", "divider"])
        t.equal(ids("cpu").prefix(4), ["graph", "cpu", "gauge", "ring"], "titles starting with the word come first")
        t.check(ids("cpu").contains("labelvalue"), "badge matches too")
        t.equal(ids("CPU", .gauges), ["gauge", "ring"], "case-insensitive, within a category")
        t.equal(ids("roundline"), ["gauge", "ring"], "Rainmeter meter types find components")
        t.equal(ids("memory bar"), ["memory"], "every word must match")
        t.equal(ids("wifi"), ["wifi"], "keywords")
        t.equal(ids("wi-fi"), ["wifi"], "as written in the title")
        t.equal(ids("spotify"), ["nowplaying", "albumart"])
        t.equal(ids("backgrounds"), ["rectangle"], "summary words")
        t.equal(ids("zzz"), [])
        t.equal(ids("ÉCRAN"), [], "diacritics fold without matching everything")
        t.equal(ids("battery"), ["battery"])
        t.equal(ids("disk").first, "disk", "the title match ranks above the badge matches")
        t.check(ids("disk").contains("progress"))
    }

    t.suite("Editor: align and distribute") {
        let a = SkinRect(x: 10, y: 10, width: 20, height: 10)
        let b = SkinRect(x: 50, y: 30, width: 40, height: 20)
        let c = SkinRect(x: 30, y: 60, width: 10, height: 10)
        let skin = SkinRect(x: 0, y: 0, width: 200, height: 100)
        t.equal(EditorAlign.frames([a, b], mode: .left, skin: skin)?.map(\.x), [10, 10])
        t.equal(EditorAlign.frames([a, b], mode: .right, skin: skin)?.map { $0.x + $0.width }, [90, 90])
        t.equal(EditorAlign.frames([a, b], mode: .centerX, skin: skin)?.map { $0.x + $0.width / 2 }, [50, 50])
        t.equal(EditorAlign.frames([a, b], mode: .bottom, skin: skin)?.map { $0.y + $0.height }, [50, 50])
        t.equal(EditorAlign.frames([a], mode: .centerX, skin: skin)?.first?.x, 90, "one meter aligns to the skin")
        t.equal(EditorAlign.frames([a], mode: .bottom, skin: skin)?.first?.y, 90)
        t.equal(EditorAlign.frames([a, b], mode: .distributeX, skin: skin), nil, "distribute needs three")
        let d = EditorAlign.frames([a, b, c], mode: .distributeX, skin: skin)!
        // a 10…30, c then b; span 10…90 = 80, widths 70, gap 5.
        t.equal(d.map(\.x), [10, 50, 35])
        let v = EditorAlign.frames([a, b, c], mode: .distributeY, skin: skin)!
        t.equal(v[0].y, 10)
        t.equal(v[2].y + v[2].height, 70, "last stays")
    }

    t.suite("Editor: append, duplicate and remove sections") {
        let (skin, _) = try makeSkin(t, "[Rainmeter]\n[Style]\nX=7\n[A]\nMeter=String\nMeterStyle=Style\nY=(4 * 2)\nText=Hi\n")
        var taken = skin.sectionNames
        guard let dup = skin.duplicateSections("A", dx: 10, dy: 10, taken: &taken) else { return t.check(false, "dup") }
        t.equal(dup.name, "A2")
        t.equal(dup.options.first { $0.key == "Y" }?.value, "(4 * 2 + 10)")
        t.equal(dup.options.first { $0.key == "X" }?.value, "17", "inherited X copied and moved")
        try skin.appendSections([dup])
        let reloaded = Skin(config: skin.config, fileURL: skin.fileURL, skinsDirectory: skin.skinsDirectory,
                            system: FakeSystem(), host: nil)
        try reloaded.load()
        reloaded.update()
        t.equal(reloaded.meter(named: "A2")?.frame.x, 17)
        t.equal(reloaded.meter(named: "A2")?.frame.y, 18)
        try reloaded.removeSection("A2")
        let text = try String(contentsOf: skin.fileURL, encoding: .utf8)
        t.check(!text.contains("[A2]"), "removed")
        t.check(text.hasSuffix("Text=Hi\n"), "file ends like before: \(text.debugDescription)")
    }

    t.suite("Editor: new data sources") {
        func type(_ name: String) -> EditorSchema.MeasureType? { EditorSchema.measureTypes.first { $0.name == name } }
        guard let cpu = type("CPU"), let power = type("PowerPlugin"), let time = type("Time") else {
            return t.check(false, "types")
        }
        let first = EditorComponents.measureSection(cpu, existing: ["rainmeter"])
        t.equal(first.name, "MeasureCPU")
        t.equal(first.options.map(\.key), ["Measure"])
        t.equal(first.options.first?.value, "CPU")
        t.equal(EditorComponents.measureSection(cpu, existing: ["measurecpu"]).name, "MeasureCPU2", "a free name")
        let battery = EditorComponents.measureSection(power, existing: [])
        t.equal(battery.name, "MeasurePower")
        t.equal(battery.options.map { "\($0.key)=\($0.value)" }, ["Measure=Plugin", "Plugin=PowerPlugin", "PowerState=Percent"],
                "plugins as Measure=Plugin + Plugin=")
        t.equal(EditorComponents.measureSection(time, existing: []).options.last?.value, "%H:%M", "a time shows the time")
        // Every type makes a section the engine reads as that type.
        for m in EditorSchema.measureTypes {
            let section = EditorComponents.measureSection(m, existing: [])
            let measure = section.options.first { $0.key == "Measure" }?.value ?? ""
            let plugin = section.options.first { $0.key == "Plugin" }?.value
            t.equal(EditorSchema.measureType(type: measure, plugin: plugin)?.name, m.name, "\(m.name) round trip")
        }
    }

    t.suite("Editor: file values ignore what the running skin set") {
        let ini = "[Rainmeter]\n[Variables]\nCard=10,20,30\n[Panel]\nShape=Rectangle 0,0,10,10 | Fill Color #Card#\n"
            + "[M]\nMeter=Shape\nMeterStyle=Panel\nShape2=Ellipse 5,5,5 | Fill Color #Card#\n"
        let (skin, _) = try makeSkin(t, ini)
        guard let m = skin.meter(named: "M") else { return t.check(false, "meter") }
        skin.execute("[!SetOption M Shape2 \"Ellipse 5,5,5 | Fill Color #Card#\"][!SetOption M Shape \"Rectangle 1,1,2,2\"]", from: nil)
        t.equal(m.rawOption("Shape2"), "Ellipse 5,5,5 | Fill Color 10,20,30", "!SetOption stores the resolved text")
        t.equal(m.optionOrigin("Shape"), .setOption)
        t.equal(m.fileOption("Shape2"), "Ellipse 5,5,5 | Fill Color #Card#", "the file's text, variables kept")
        t.equal(m.fileOption("Shape"), "Rectangle 0,0,10,10 | Fill Color #Card#", "from the style")
        if case .style(let style, _)? = m.fileOrigin("Shape") { t.equal(style, "Panel") } else { t.check(false, "style origin") }
        if case .own? = m.fileOrigin("Shape2") {} else { t.check(false, "own origin") }
        t.equal(m.fileOption("Shape3"), nil)
        t.equal(skin.editTarget(section: "M", key: "Shape").section, "M", "a runtime value is written on the layer")
        t.equal(skin.fileEditTarget(section: "M", key: "Shape").section, "Panel", "its file value lives in the style")
        skin.preview(section: "M", ["Shape2": "Ellipse 9,9,9"])
        t.equal(m.fileOption("Shape2"), "Ellipse 5,5,5 | Fill Color #Card#", "previews are not file values either")
        skin.endPreview()
    }

    t.suite("Editor: removing a section removes every block of it") {
        // [Bar] in the skin file (twice: the second block is ignored today) and in an @Include file (merged).
        let dir = t.temporaryDirectory("remove-section")
        let skinDir = dir.appendingPathComponent("Cfg")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let inc = skinDir.appendingPathComponent("Extra.inc")
        try "[Other]\nZ=1\n\n[Bar]\nMeter=String\nText=From include\n".write(to: inc, atomically: true, encoding: .utf8)
        let ini = skinDir.appendingPathComponent("Cfg.ini")
        try ("[Rainmeter]\n@Include=Extra.inc\n\n[Bar]\nMeter=String\nText=First\n\n[Keep]\nMeter=String\n\n"
             + "[Bar]\nMeter=Image\nW=5\n").write(to: ini, atomically: true, encoding: .utf8)
        func load() throws -> Skin {
            let s = Skin(config: "Cfg", fileURL: ini, skinsDirectory: dir, system: FakeSystem(), host: nil)
            try s.load()
            s.update()
            return s
        }
        let skin = try load()
        t.equal(skin.meter(named: "Bar")?.rawOption("Text"), "First")
        t.equal(skin.definingFiles(ofSection: "bar").map(\.lastPathComponent), ["Cfg.ini", "Extra.inc"],
                "the header's file first, then the include that adds to it")
        try skin.removeSection("Bar")
        let after = try load()
        t.check(after.meter(named: "Bar") == nil && after.document.section(named: "Bar") == nil,
                "the layer does not come back from the ignored block or the include")
        t.check(after.meter(named: "Keep") != nil && after.document.section(named: "Other") != nil, "the rest stays")
        t.equal(try String(contentsOf: inc, encoding: .utf8), "[Other]\nZ=1\n")
    }
}

func runEditorSchemaTests(_ t: TestRunner) {
    t.suite("Editor: moving sections") {
        let text = "[Rainmeter]\nUpdate=1000\n\n[A]\nX=1\n\n; about B\n[B]\nX=2\n\n[C]\nX=3\n"
        t.equal(IniWriter.movingSection(text, section: "C", before: "A"),
                "[Rainmeter]\nUpdate=1000\n\n[C]\nX=3\n\n[A]\nX=1\n\n; about B\n[B]\nX=2\n\n")
        t.equal(IniWriter.movingSection(text, section: "A", before: nil),
                "[Rainmeter]\nUpdate=1000\n\n; about B\n[B]\nX=2\n\n[C]\nX=3\n\n[A]\nX=1\n\n")
        t.equal(IniWriter.movingSection(text, section: "B", before: "A"),
                "[Rainmeter]\nUpdate=1000\n\n; about B\n[B]\nX=2\n\n[A]\nX=1\n\n[C]\nX=3\n", "comments travel with their section")
        t.equal(IniWriter.movingSection(text, section: "A", before: "B"), text, "already there")
        t.equal(IniWriter.movingSection(text, section: "Z", before: "A"), nil)
        t.equal(IniWriter.movingSection("[A]\r\nX=1\r\n[B]\r\nX=2", section: "B", before: "A"), "[B]\r\nX=2\r\n\r\n[A]\r\nX=1\r\n")
    }

    t.suite("Editor: reordering meters changes the drawing order") {
        let (skin, _) = try makeSkin(t, "[Rainmeter]\n[A]\nMeter=String\nText=a\n[B]\nMeter=String\nText=b\n[C]\nMeter=String\nText=c\n")
        t.check(try skin.moveSection("A", before: nil), "moved to the front")
        let reloaded = Skin(config: skin.config, fileURL: skin.fileURL, skinsDirectory: skin.skinsDirectory,
                            system: FakeSystem(), host: nil)
        try reloaded.load()
        t.equal(reloaded.meters.map(\.name), ["B", "C", "A"])
    }

    t.suite("Editor: schema") {
        for type in ["string", "bar", "line", "histogram", "roundline", "rotator", "image", "button", "bitmap", "shape"] {
            let groups = EditorSchema.meterGroups(type)
            t.check(!groups.isEmpty, "\(type) has groups")
            let keys = groups.flatMap { $0.properties.map { $0.key.lowercased() } }
            t.equal(keys.count, Set(keys).count, "\(type): no key twice")
        }
        t.equal(EditorSchema.meterGroups("string").first?.title, "Shows")
        t.equal(EditorSchema.meterGroups("string")[1].title, "Text")
        t.check(EditorSchema.meterGroups("bar").contains { $0.properties.contains { $0.kind == .sectionRef(.measure) } },
                "bar shows data")
        t.equal(EditorSchema.describeMeasure(type: "cpu").title, "CPU usage")
        t.equal(EditorSchema.describeMeasure(type: "PhysicalMemory").title, "Memory used")
        t.equal(EditorSchema.describeMeasure(type: "PhysicalMemory", total: true).title, "Total memory")
        t.equal(EditorSchema.describeMeasure(type: "SwapMemory", invert: true).title, "Memory and swap free")
        t.equal(EditorSchema.describeMeasure(type: "Plugin", plugin: "PowerPlugin").title, "Battery")
        t.check(EditorSchema.measureGroups("time").first?.properties.contains { $0.key == "Format" } == true)
        t.check(EditorSchema.keys(EditorSchema.skinGroups).contains("update"))
    }
}
