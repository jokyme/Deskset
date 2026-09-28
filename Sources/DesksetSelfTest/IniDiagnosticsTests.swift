import Foundation
@testable import DesksetCore

// The Studio code pane's INI diagnostics: amber when a widget still draws (a misspelled key, a color that is not one),
// red when a part cannot (a formula, a name or file pointing at nothing, an unknown bang); on the line that causes it,
// with the parts it reaches and a fix when it is certain. Suites: "INI diagnostics: …".

func runIniDiagnosticsTests(_ t: TestRunner) {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// A widget whose shared styles live in an included file, as many Rainmeter skins are written.
    let styles = """
        ; Shared looks

        [StyleLabel]
        FontSize=10
        FontColor=#AccentColor#
        StringStyle=Bold

        [StyleValue]
        FontFace=#FontName#
        FontSize=15
        FontColr=#TextColor#
        StringStyle=Bold

        [StyleBar]
        W=(#BarWidth# *)
        H=4
        BarColor=72,212,232
        """
    let main = """
        [Rainmeter]
        Update=1000

        [Variables]
        FontName=Helvetica
        TextColor=255,255,255
        AccentColor=72,212,232
        BarWidth=110
        @Include=#@#Styles.inc

        [MeasureCPU]
        Measure=CPU

        [MeasureRAM]
        Measure=PhysicalMemory

        [MeterCPU]
        Meter=String
        MeterStyle=StyleValue
        MeasureName=MeasureCPU
        Text=%1%

        [MeterCPUBar]
        Meter=Bar
        MeterStyle=StyleBar
        MeasureName=MeasureCPU
        Y=20

        [MeterRAM]
        Meter=String
        MeterStyle=StyleValue
        MeasureName=MeasureRAM
        Y=40

        [MeterRAMBar]
        Meter=Bar
        MeterStyle=StyleBar
        MeasureName=MeasureRAM
        Y=60
        """

    t.suite("INI diagnostics: a misspelled key and a broken formula in an included file") {
        let (skin, _) = try makeSkin(t, main, files: ["Root/@Resources/Styles.inc": styles])
        let found = IniDiagnostics.check(skin)
        let file = skin.includedFiles.first!
        t.equal(found.count, 2, "\(found)")
        guard found.count == 2 else { return }
        let key = found[0]
        t.equal(SourceFileID(key.file), SourceFileID(file), "in the included file")
        t.equal(key.line, 11)
        t.equal(key.column, 0)
        t.equal(key.length, 8, "FontColr")
        t.equal(key.section, "StyleValue")
        t.equal(key.kind, .unknownKey(key: "FontColr", sectionType: "String", suggestion: "FontColor"))
        t.equal(key.severity, .warning, "the numbers still draw")
        t.equal(key.meters, ["MeterCPU", "MeterRAM"], "both texts use the style")
        t.equal(key.defaultValue, "0,0,0,255", "black meanwhile")
        t.equal(key.fix, IniDiagnostic.Fix(column: 0, length: 8, text: "FontColor"))

        let formula = found[1]
        t.equal(formula.line, 15)
        t.equal(formula.column, 2, "the value")
        t.equal(formula.length, 14, "(#BarWidth# *)")
        t.equal(formula.kind, .badFormula(key: "W", value: "(#BarWidth# *)", reason: .missingNumber(after: "*")))
        t.equal(formula.severity, .problem)
        t.equal(formula.meters, ["MeterCPUBar", "MeterRAMBar"], "the bars can't draw")
        t.equal(formula.fix, nil, "no certain fix")
        t.check(IniDiagnostics.hasProblems(found))
    }

    t.suite("INI diagnostics: typed text is checked before it is committed") {
        let (skin, _) = try makeSkin(t, main, files: ["Root/@Resources/Styles.inc": styles])
        let file = skin.includedFiles.first!
        let fixed = styles.replacingOccurrences(of: "FontColr", with: "FontColor")
            .replacingOccurrences(of: "(#BarWidth# *)", with: "(#BarWidth# * 1)")
        let typed = TypedSources(overrides: [SourceFileID(file): fixed])
        t.equal(IniDiagnostics.check(skin, sources: typed), [], "the typed text is fine")
        t.equal(IniDiagnostics.check(skin).count, 2, "the loaded one still has both")
        let broken = TypedSources(overrides: [SourceFileID(file): fixed.replacingOccurrences(of: "* 1)", with: "* 1")])
        let found = IniDiagnostics.check(skin, sources: broken)
        t.equal(found.map(\.kind), [.badFormula(key: "W", value: "(#BarWidth# * 1", reason: .missingParenthesis)])
    }

    t.suite("INI diagnostics: names, files and bangs that point at nothing") {
        let ini = """
            [Rainmeter]
            Update=1000
            OnRefreshAction=[!Refresh][!SetOpton MeterA Text "x"]

            [Variables]
            @Include=#@#Missing.inc
            @Include2=#@#Here.inc

            [MeasureA]
            Measure=Calc
            Formula=(1 + )

            [MeterA]
            Meter=String
            MeasureName=MeasureNope
            MeterStyle=StyleHere | StyleGone
            LeftMouseUpAction=[!ShowMeterr MeterB]

            [MeterB]
            Meter=Image
            ImageName=#@#nothing.png

            [MeterC]
            Meter=Image
            ImageName=#@#there.png

            [MeterD]
            Meter=String
            MeasureName=MeasureA
            FontColor=12,red
            SolidColor=0,0,0,1
            """
        let (skin, _) = try makeSkin(t, ini, files: ["Root/@Resources/Here.inc": "[StyleHere]\nFontSize=12\n",
                                                   "Root/@Resources/there.png": "not really a picture"])
        let found = IniDiagnostics.check(skin)
        let kinds = found.map(\.kind)
        t.equal(kinds, [
            .unknownBang(name: "!SetOpton", suggestion: "!SetOption"),
            .missingInclude(path: "#@#Missing.inc"),
            .badFormula(key: "Formula", value: "(1 + )", reason: .missingNumber(after: "+")),
            .missingMeasure(name: "MeasureNope"),
            .missingStyle(name: "StyleGone"),
            .unknownBang(name: "!ShowMeterr", suggestion: "!ShowMeter"),
            .missingImage(path: "#@#nothing.png"),
            .badColor(key: "FontColor", value: "12,red"),
        ], "\(kinds)")
        guard found.count == 8 else { return }
        t.equal(found[0].line, 3)
        t.equal(found[0].column, 27, "the bang's name")
        t.equal(found[0].length, 9)
        t.equal(found[0].fix?.text, "!SetOption")
        t.equal(found[0].meters, [], "the skin's own action: no part")
        t.equal(found[1].line, 6)
        t.equal(found[1].column, 9)
        t.equal(found[1].section, "Variables")
        t.equal(found[2].meters, ["MeterD"], "the text showing the Calc")
        t.equal(found[3].meters, ["MeterA"])
        t.equal(found[4].column, 23, "the style's name in the list")
        t.equal(found[4].length, 9)
        t.equal(found[5].meters, ["MeterA"])
        t.equal(found[6].meters, ["MeterB"])
        t.equal(found[7].severity, .warning)
        t.equal(found[7].defaultValue, "0,0,0,255")
        t.equal(found.filter { $0.severity == .problem }.count, 7)
    }

    t.suite("INI diagnostics: what depends on the running widget is not judged") {
        let ini = """
            [Variables]
            Size=20

            [MeasureNet]
            Measure=Plugin
            Plugin=SomeAddOn
            Colr=1
            WhateverOption=2

            [MeasureCPU]
            Measure=CPU
            Processor=0

            [MeterA]
            Meter=String
            MeasureName=[#Which]
            FontColor=[MeasureCPU],0,0
            W=([MeterB:W] + #Size#)
            X=(#Size# * 2)R
            Y=(#UNDEFINEDTHING# + 1)
            CustomNote=kept for a script
            DynamicVariables=1

            [MeterB]
            Meter=Image
            ImageName=sf:cpu
            W=(5+5) junk
            """
        let (skin, _) = try makeSkin(t, ini)
        t.equal(IniDiagnostics.check(skin), [], "add-on keys, dynamic values, keys far from any option, sf: symbols")
    }

    t.suite("INI diagnostics: did you mean") {
        t.equal(IniDiagnostics.closest(to: "FontColr", in: ["FontFace", "FontColor", "FontSize"]), "FontColor")
        t.equal(IniDiagnostics.closest(to: "Fontcolor", in: ["FontColor"]), nil, "letter case is not a mistake")
        t.equal(IniDiagnostics.closest(to: "Txet", in: ["Text"]), "Text", "two letters swapped")
        t.equal(IniDiagnostics.closest(to: "Zzz", in: ["Text"]), nil)
        t.equal(IniDiagnostics.closest(to: "SolidColr2", in: ["SolidColor", "SolidColor2"]), "SolidColor2")
        t.equal(IniDiagnostics.distance("kitten", "sitting", limit: 5), 3)
    }

    t.suite("INI diagnostics: the default skins and the Studio's fixtures are clean") {
        var checked = 0
        // A settings folder of its own: the suite's settings file is looked for there (letter case ignored), and the
        // default one, the shared temporary folder, can hold thousands of entries.
        let settings = SettingsHost(settingsPath: t.temporaryDirectory("settings").path + "/")
        for folder in ["DefaultSkins", "TestSkins/Studio2"] {
            let skins = repo.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: skins, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "ini"
                && !url.path.contains("/@Resources/") {
                let relative = url.deletingLastPathComponent().path.dropFirst(skins.path.count + 1)
                guard !relative.isEmpty else { continue }
                let config = relative.replacingOccurrences(of: "/", with: "\\")
                let skin = Skin(config: config, fileURL: url, skinsDirectory: skins, system: FakeSystem(), host: settings)
                // Not loaded (its measures would start): the check reads the files itself.
                let found = IniDiagnostics.check(skin, sources: TypedSources(overrides: [:]))
                t.equal(found, [], "\(config)\\\(url.lastPathComponent): \(found.map { "\($0.line) \($0.kind)" })")
                checked += 1
            }
        }
        t.check(checked >= 30, "checked \(checked) skins")
    }
}

/// A host whose settings folder is a folder of the test's own.
private final class SettingsHost: FakeHost {
    let settingsPath: String
    init(settingsPath: String) { self.settingsPath = settingsPath }
    override func environment(for skin: Skin) -> SkinEnvironment { SkinEnvironment(settingsPath: settingsPath) }
}

/// Typed text over the files on disk (the code pane's buffer before it is committed).
private final class TypedSources: SourceProvider {
    let overrides: [SourceFileID: String]
    init(overrides: [SourceFileID: String]) { self.overrides = overrides }
    func sourceText(for url: URL) -> String? { overrides[SourceFileID(url)] }
}
