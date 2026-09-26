import Foundation
@testable import DesksetCore

func runInspectorTests(_ t: TestRunner) {
    let ini = """
    ; header comment
    [Rainmeter]
    Update=1000
    @Include=#@#Styles.inc

    [Variables]
    Accent=255,0,0
    Size=12

    [MeterTitle]
    Meter=String
    MeterStyle=StyleText | StyleBig
    X=10
    Y=(#Size# * 2)
    FontColor=#Accent#
    Text=Hello

    [MeasureCPU]
    Measure=CPU

    [MeterBar]
    Meter=Bar
    MeasureName=MeasureCPU
    X=0R
    W=50
    H=10
    """
    let styles = """
    [StyleText]
    FontSize=#Size#
    FontFace=Helvetica
    FontColor=0,0,0

    [StyleBig]
    FontSize=20

    [Variables]
    Size=14
    """

    t.suite("Inspector: source locations") {
        let (skin, _) = try makeSkin(t, ini, files: ["Root/@Resources/Styles.inc": styles])
        let main = skin.fileURL.standardizedFileURL
        t.equal(skin.sources.location(section: "MeterTitle", key: "X"), IniSourceLocation(file: main, line: 13))
        t.equal(skin.sources.location(section: "metertitle", key: "text"), IniSourceLocation(file: main, line: 16))
        t.equal(skin.sources.location(section: "MeterTitle"), IniSourceLocation(file: main, line: 10))
        let inc = skin.sources.location(section: "StyleText", key: "FontFace")
        t.equal(inc?.file.lastPathComponent, "Styles.inc")
        t.equal(inc?.line, 3)
        // "Later wins": Size=14 from the include (read at the @Include in [Rainmeter]) is overridden by the main
        // file's [Variables], which comes after it.
        t.equal(skin.sources.location(section: "Variables", key: "Size"), IniSourceLocation(file: main, line: 8))
        t.equal(skin.sources.location(section: "Variables")?.file, main)
    }

    t.suite("Inspector: CRLF and duplicate sections keep line numbers") {
        let (skin, _) = try makeSkin(t, "[A]\r\nMeter=String\r\n\r\n[A]\r\nX=5\r\n[B]\r\nMeter=String\r\n;c\r\nX=7\r\n")
        t.equal(skin.sources.location(section: "B", key: "X")?.line, 9)
        t.equal(skin.sources.location(section: "A", key: "X"), nil)
        t.equal(skin.sources.location(section: "B")?.line, 6)
    }

    t.suite("Inspector: option origins") {
        let (skin, _) = try makeSkin(t, ini, files: ["Root/@Resources/Styles.inc": styles])
        guard let title = skin.meter(named: "MeterTitle") else { return t.check(false, "no meter") }
        let options = title.inspectedOptions()
        t.equal(options.map(\.key), ["Meter", "MeterStyle", "X", "Y", "FontColor", "Text", "FontSize", "FontFace"])
        let byKey = Dictionary(uniqueKeysWithValues: options.map { ($0.key.lowercased(), $0) })
        t.equal(byKey["y"]?.raw, "(#Size# * 2)")
        t.equal(byKey["y"]?.resolved, "(12 * 2)")
        t.equal(byKey["y"]?.variables, ["Size"])
        t.equal(byKey["fontcolor"]?.resolved, "255,0,0")
        t.equal(byKey["fontcolor"]?.shadowedStyles, ["StyleText"], "own FontColor hides the style's")
        if case .style(let name, let loc)? = byKey["fontsize"]?.origin {
            t.equal(name, "StyleBig", "later style wins")
            t.equal(loc?.line, 7)
        } else {
            t.check(false, "FontSize should come from a style")
        }
        t.equal(byKey["fontsize"]?.shadowedStyles, ["StyleText"])
        t.equal(byKey["fontface"]?.resolved, "Helvetica")

        skin.execute("[!SetOption MeterTitle Text Changed][!SetOption MeterTitle W 99]", from: nil)
        t.equal(title.optionOrigin("Text"), .setOption)
        t.equal(title.inspectedOptions().last?.key, "w")
        skin.execute("[!SetOption MeterTitle FontColor \"\"]", from: nil)
        if case .style(let name, _)? = title.optionOrigin("FontColor") {
            t.equal(name, "StyleText", "removed option falls back to the style")
        } else {
            t.check(false, "FontColor should fall back to the style")
        }
        t.equal(title.optionOrigin("SolidColor"), nil)
    }

    t.suite("Inspector: sections and variables") {
        let (skin, _) = try makeSkin(t, ini, files: ["Root/@Resources/Styles.inc": styles])
        let sections = skin.inspectedSections()
        // Sections from the include follow [Rainmeter], which holds the @Include.
        t.equal(sections.map(\.name), ["Rainmeter", "Variables", "StyleText", "StyleBig", "MeterTitle",
                                       "MeasureCPU", "MeterBar"])
        t.equal(sections.first { $0.name == "StyleBig" }?.kind, .other)
        t.equal(sections.first { $0.name == "MeasureCPU" }?.kind, .measure)
        t.equal(sections.first { $0.name == "MeterBar" }?.kind, .meter)

        let vars = skin.inspectedVariables()
        // The included Size came first and keeps its place when the main file overrides it.
        t.equal(vars.map(\.name), ["Size", "Accent"])
        t.equal(vars.first?.raw, "12")
        skin.execute("[!SetVariable Accent 0,0,255]", from: nil)
        let accent = skin.inspectedVariables().first { $0.name == "Accent" }
        t.equal(accent?.current, "0,0,255")
        t.equal(accent?.raw, "255,0,0")

        let style = skin.inspectedOptions(ofSection: "StyleText")
        t.equal(style.map(\.key), ["FontSize", "FontFace", "FontColor"])
        t.equal(style.first?.resolved, "12")
        t.equal(style.first?.origin.location?.file.lastPathComponent, "Styles.inc")
    }

    t.suite("Inspector: picking meters") {
        let (skin, _) = try makeSkin(t, ini, files: ["Root/@Resources/Styles.inc": styles])
        skin.update()
        guard let title = skin.meter(named: "MeterTitle"), let bar = skin.meter(named: "MeterBar") else {
            return t.check(false, "meters missing")
        }
        t.equal(skin.inspectableMeter(at: title.frame.x + 1, title.frame.y + 1)?.name, "MeterTitle")
        t.equal(skin.inspectableMeter(at: bar.frame.x + 1, bar.frame.y + 1)?.name, "MeterBar")
        t.check(skin.inspectableMeter(at: -5, -5) == nil)
    }

    t.suite("Inspector: edit targets and write-back") {
        let (skin, _) = try makeSkin(t, ini, files: ["Root/@Resources/Styles.inc": styles])
        let main = skin.fileURL.standardizedFileURL
        t.equal(skin.editTarget(section: "MeterTitle", key: "X"), SkinEditTarget(file: main, section: "MeterTitle"))
        let styleTarget = skin.editTarget(section: "metertitle", key: "FontFace")
        t.equal(styleTarget.section, "StyleText")
        t.equal(styleTarget.file.lastPathComponent, "Styles.inc")
        t.equal(skin.editTarget(section: "MeterTitle", key: "SolidColor"),
                SkinEditTarget(file: main, section: "MeterTitle"))
        t.equal(skin.editTarget(section: "Variables", key: "Size").file, main)
        t.equal(skin.editTarget(section: "StyleBig", key: "FontSize").file.lastPathComponent, "Styles.inc")

        try skin.writeOption(section: "MeterTitle", key: "X", value: "25")
        try skin.writeOption(section: "MeterTitle", key: "FontFace", value: "Menlo")
        try skin.writeOption(section: "MeterTitle", key: "SolidColor", value: "0,0,0,1")
        let text = try String(contentsOf: main, encoding: .utf8)
        t.check(text.contains("X=25\n"), "X rewritten in place")
        t.check(text.hasPrefix("; header comment\n[Rainmeter]"), "rest of the file kept")
        t.check(text.contains("Text=Hello\nSolidColor=0,0,0,1\n"), "new option appended to its section")
        let inc = try String(contentsOf: styleTarget.file, encoding: .utf8)
        t.check(inc.contains("FontFace=Menlo"), "style value edited where it is defined")

        let reloaded = Skin(config: skin.config, fileURL: skin.fileURL, skinsDirectory: skin.skinsDirectory,
                            system: FakeSystem(), host: nil)
        try reloaded.load()
        t.equal(reloaded.meter(named: "MeterTitle")?.rawOption("X"), "25")
        t.equal(reloaded.sources.location(section: "MeterTitle", key: "X")?.line, 13, "line numbers stay stable")
    }

    t.suite("Inspector: section variables show their current value") {
        let (skin, _) = try makeSkin(t, "[Rainmeter]\n[A]\nMeter=String\nX=12\nText=a\n[B]\nMeter=String\nX=([A:X] + 5)\nText=b\n")
        skin.update()
        let x = skin.meter(named: "B")?.inspectedOptions().first { $0.key == "X" }
        t.equal(x?.raw, "([A:X] + 5)")
        t.equal(x?.resolved, "(12 + 5)", "resolved although B has no DynamicVariables")
        t.equal(skin.meter(named: "B")?.frame.x, 17)
    }

    t.suite("Inspector: variable references") {
        t.equal(SkinInspection.referencedVariables(in: "(#A# + #B#) * #A#"), ["A", "B"])
        t.equal(SkinInspection.referencedVariables(in: "#@#Images\\bg.png"), ["@"])
        t.equal(SkinInspection.referencedVariables(in: "#*Esc*# and #Real#"), ["Real"])
        t.equal(SkinInspection.referencedVariables(in: "# not # a #var#"), ["var"])
        t.equal(SkinInspection.referencedVariables(in: "[#Color[#Index]]"), [])
        t.equal(SkinInspection.referencedVariables(in: "100%#"), [])
    }
}
