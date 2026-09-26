import Foundation
@testable import DesksetCore

/// The Number and Format menus of rendered examples (docs/editor-friendly.md §8.2), the schema's essentials and
/// "More" summaries, and action sentences. Suites: "Editor: format presets …", "Editor: schema levels …",
/// "Editor: action summaries …" (WP-C).
func runFormatPresetsTests(_ t: TestRunner) {
    typealias S = EditorSchema

    t.suite("Editor: format presets for numbers") {
        let titles = FormatPresets.numberPresets(for: 13268.00443).map(\.title)
        for expected in ["13268", "13268.0", "13.3 k"] { t.check(titles.contains(expected), "\(expected) in \(titles)") }
        t.equal(titles.first, "13268", "the plain number first")
        // What each choice writes renders as its title with the engine's own formatting.
        for preset in FormatPresets.numberPresets(for: 48.24) {
            let o = FormatPresets.parse(preset.options)
            t.equal(NumberFormatting.format(48.24, minValue: 0, maxValue: 1, options: o).trimmingCharacters(in: .whitespaces),
                    preset.title, "renders as its title")
        }
        t.equal(FormatPresets.numberPresets(for: 48.24).map(\.title), ["48", "48.2", "48.24", "0.05 k"], "§8.2's example")
        // Bytes.
        t.equal(FormatPresets.numberPresets(for: 3_221_225_472, unit: .bytes).map(\.title),
                ["3 GB", "3.2 GB", "3,221,225,472"])
        t.equal(FormatPresets.numberPresets(for: 2_400_000, unit: .bytesPerSecond).first?.title, "2 MB/s")
        // A text that shortens by 1024s (System's memory: AutoScale=1) keeps its base: its format is a choice, and
        // no choice changes 17.9 GB into 19.2 GB.
        t.equal(FormatPresets.base(ofAutoScale: "1"), .binary)
        t.equal(FormatPresets.base(ofAutoScale: " 1k "), .binary)
        t.equal(FormatPresets.base(ofAutoScale: "2"), .thousands)
        t.equal(FormatPresets.base(ofAutoScale: nil), .thousands)
        let memory = 19_220_000_000.0
        let binary = FormatPresets.numberPresets(for: memory, unit: .bytes, base: .binary)
        t.equal(binary.map(\.title), ["18 GB", "17.9 GB", "19,220,000,000"])
        t.check(binary.prefix(2).allSatisfy { ($0.options["AutoScale"] ?? nil) == "1" }, "written AutoScale=1")
        t.equal(FormatPresets.index(of: ["AutoScale": "1", "NumOfDecimals": "1"], in: binary), 1, "System's RAM text is a choice")
        t.equal(FormatPresets.numberPresets(for: memory, unit: .bytes).map(\.title), ["19 GB", "19.2 GB", "19,220,000,000"])
        t.equal(FormatPresets.index(of: ["AutoScale": "1", "NumOfDecimals": "1"],
                                    in: FormatPresets.numberPresets(for: memory, unit: .bytes)), nil, "not among 1000s")
        t.equal(FormatPresets.numberPresets(for: 13268.00443, base: .binary).last?.options["AutoScale"] ?? nil, "1k")
        // Percent of the range, when there is a range.
        let ranged = FormatPresets.numberPresets(for: 0.83, range: (0, 1))
        t.equal(ranged.last?.title, "Percent of range — 83%")
        t.equal(ranged.last?.options["Percentual"] ?? nil, "1")
        t.check(!FormatPresets.numberPresets(for: 5, range: (1, 1)).contains { $0.title.hasPrefix("Percent") }, "empty range")
        // The current options find their choice; unknown combinations find none.
        let presets = FormatPresets.numberPresets(for: 13268.00443)
        t.equal(FormatPresets.index(of: [:], in: presets), 0, "nothing set: the plain number")
        t.equal(FormatPresets.index(of: ["NumOfDecimals": "0"], in: presets), 0, "0 is the default")
        t.equal(FormatPresets.index(of: ["NumOfDecimals": "1"], in: presets), 1)
        t.equal(FormatPresets.index(of: ["AutoScale": "2k", "NumOfDecimals": "1"], in: presets), 3)
        t.equal(FormatPresets.index(of: ["AutoScale": "2k"], in: presets), 3, "AutoScale's default is one decimal")
        t.equal(FormatPresets.index(of: ["Scale": "1000"], in: presets), nil, "a custom combination")
        // Units by type.
        t.equal(FormatPresets.unit(forMeasureType: "PhysicalMemory"), .bytes)
        t.equal(FormatPresets.unit(forMeasureType: "NetIn"), .bytesPerSecond)
        t.equal(FormatPresets.unit(forMeasureType: "Plugin", plugin: "AudioLevel"), .plain)
    }

    t.suite("Editor: format presets for times") {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 9, 24, 14, 5, 9)
        c.timeZone = TimeZone(identifier: "UTC")
        guard let date = Calendar(identifier: .gregorian).date(from: c), let utc = TimeZone(identifier: "UTC") else {
            return t.check(false, "date")
        }
        let presets = FormatPresets.timePresets(at: date, timeZone: utc)
        t.equal(presets.first?.format, "%H:%M")
        t.equal(presets.first?.title, "14:05", "%H:%M renders 14:05 at 14:05")
        t.equal(presets.map(\.title), ["14:05", "2:05 PM", "14:05:09", "Thu 24 Sep", "September 24, 2026"])
    }

    t.suite("Editor: schema levels") {
        var all: [(String, [S.Group])] = S.meterTypes.map { ("Meter=\($0)", S.meterGroups($0)) }
        for m in S.measureTypes {
            all.append(("Measure \(m.name)", m.isPlugin ? S.measureGroups("Plugin", plugin: m.name) : S.measureGroups(m.name)))
        }
        // The situations a card can be seen in: nothing set, a child of other live data, text showing live data.
        let situations: [[String: String]] = [[:], ["Parent": "MeasureParent", "Type": "Band"], ["MeasureName": "M"],
                                              ["Formula": "Random"], ["StringEffect": "Shadow"]]
        for (name, groups) in all {
            for g in groups {
                t.check(!g.essentialRows.isEmpty, "\(name): \(g.title) has an essential row")
                let limit = g.title == "Text" ? 7 : 5
                for values in situations {
                    let shown = g.essentialRows.filter { S.isVisible($0, in: groups, values: { values[$0] }) }
                    t.check(shown.count <= limit, "\(name): \(g.title) shows \(shown.count) essentials with \(values)")
                }
                if !g.moreProperties.isEmpty { t.check(!g.moreSummary.isEmpty, "\(name): \(g.title) says what More holds") }
                for p in g.properties where p.level == .essential {
                    t.check(S.engineWord(in: p.label) == nil, "\(name): “\(p.label)” is plain words")
                    if let row = p.partOf {
                        t.check(g.essentialRows.contains { $0.key == row }, "\(name): \(p.key) is part of an essential row")
                    }
                }
            }
        }
        // The rows §8 names, in order.
        let text = S.meterGroups("String").first { $0.title == "Text" }
        t.equal(text?.essentialRows.map(\.label), ["Text", "Font", "Size", "Color", "Align", "Effect"])
        t.equal(text?.moreLabel, "More Text Options")
        let bar = S.meterGroups("Bar").first
        t.equal(bar?.title, "Bar")
        t.equal(bar?.essentialRows.map(\.label), ["Shows", "Fill", "Empty part", "Fills toward"])
        t.equal(S.meterGroups("Bar").map(\.title), ["Bar", "When Clicked", "Layer"])
        t.equal(S.meterGroups("String").map(\.title), ["Shows", "Text", "Box Behind It", "When Clicked", "Layer"])
        t.equal(S.meterGroups("Image").first?.essentialRows.map(\.label), ["Picture", "Color", "Opacity", "Fit"])
        t.equal(S.meterGroups("Roundline").first?.essentialRows.map(\.label), ["Shows", "Color", "Thickness", "Starts at", "Sweeps"])
        t.equal(S.meterGroups("Line").first?.essentialRows.map(\.label),
                ["Shows", "Line", "Behind the graph", "New values appear on the"])
        t.equal(S.measureGroups("CPU").first?.essentialRows.map(\.label), ["Processor"])
        t.equal(S.measureGroups("CPU").first?.moreLabel, "More Live Data Options")
        let audio = S.measureGroups("Plugin", plugin: "AudioLevel")
        let child: [String: String] = ["Parent": "MeasureAudio", "Type": "Band"]
        t.equal(audio.first?.essentialRows.filter { S.isVisible($0, in: audio, values: { child[$0] }) }.map(\.label),
                ["Listens to", "Reads", "Band"])
        t.equal(audio.first?.essentialRows.filter { S.isVisible($0, in: audio, values: { _ in nil }) }.map(\.label),
                ["Listen to", "Reads", "Sensitivity", "Rises", "Falls"])
        // Quiet keys are never "in use".
        for key in ["AntiAlias", "DynamicVariables", "MeterStyle"] {
            t.equal(S.property(key, in: S.meterGroups("String"))?.level, .quiet, key)
        }
        // The copy check itself.
        t.equal(S.engineWord(in: "Refresh the skin"), "refresh")
        t.equal(S.engineWord(in: "every 25 ms"), "ms")
        t.equal(S.engineWord(in: "#Accent#"), "#Accent#")
        t.equal(S.engineWord(in: "120,200,255,255"), "120,200,255,255")
        t.equal(S.engineWord(in: "Variables.inc"), ".inc")
        t.equal(S.engineWord(in: "Sections"), "sections")
        t.equal(S.engineWord(in: "Bar color · 18 bars"), nil)
        t.equal(S.engineWord(in: "milliseconds"), nil, "whole words only")
    }

    t.suite("Editor: live data catalogue") {
        let titles = S.liveDataCatalogue.map(\.title)
        t.equal(titles, ["On This Mac", "Calculate", "From the Web"])
        func all(_ items: [S.LiveDataChoice]) -> [S.LiveDataChoice] { items.flatMap { [$0] + all($0.children) } }
        for item in all(S.liveDataCatalogue.flatMap(\.items)) where item.children.isEmpty {
            t.check(item.measureType != nil, "\(item.title) creates a known type")
            t.check(!item.detail.isEmpty, "\(item.title) is described")
        }
        t.equal(S.liveDataCatalogue.first?.items.first?.title, "CPU usage")
        t.check(!S.extraLiveDataTypes(details: false).contains { $0.name == "Memory" }, "Windows-style memory is hidden")
        t.check(!S.extraLiveDataTypes(details: false).contains { !$0.supportedOnMac }, "Windows-only only with details")
        t.check(S.extraLiveDataTypes(details: true).contains { $0.name == "Registry" })
    }

    t.suite("Editor: action summaries") {
        func sentence(_ action: String, section: String? = nil) -> String? {
            ActionSummary.sentence(for: action, section: section, name: { $0 == "MeterTitle" ? "“Audio”" : $0 },
                                   color: { $0 == "#Accent#" ? "Bar color" : "a new color" })
        }
        t.equal(sentence(#"["/System/Applications/Utilities/Activity Monitor.app"]"#), "Opens “Activity Monitor”")
        t.equal(sentence(#"["https://example.com"]"#), "Opens example.com")
        t.equal(sentence(#"["https://www.example.com/path"]"#), "Opens example.com")
        t.equal(sentence("[!ToggleMeter MeterTitle]"), "Shows or hides “Audio”")
        t.equal(sentence("[!ToggleMeter MeterTitle][!Redraw]"), "Shows or hides “Audio”", "the redraw is part of it")
        t.equal(sentence("[!Refresh][!SetVariable A 1]"), "Runs 2 commands")
        t.equal(sentence("[!SetOption MeterTitle FontColor #Accent#][!UpdateMeter MeterTitle][!Redraw]", section: "MeterTitle"),
                "Turns its text Bar color")
        // A look's hover (System's StyleLink): the layer as #CURRENTSECTION#; an empty value is its own color again.
        t.equal(sentence("[!SetOption #CURRENTSECTION# FontColor \"#Accent#\"][!UpdateMeter #CURRENTSECTION#][!Redraw]",
                         section: "MeterTitle"), "Turns its text Bar color")
        t.equal(sentence("[!SetOption #CURRENTSECTION# FontColor \"\"][!UpdateMeter #CURRENTSECTION#][!Redraw]"),
                "Turns its text back to its usual color")
        t.equal(sentence("[!SetOption #CURRENTSECTION# X 10][!UpdateMeter #CURRENTSECTION#]"), "Changes one of its settings")
        t.equal(sentence("[!Refresh]"), "Reloads the widget")
        t.equal(sentence(""), nil)
        // With a skin: its layer names.
        let (skin, _) = try makeSkin(t, "[Rainmeter]\n[MeterTitle]\nMeter=String\nText=Audio\n")
        t.equal(ActionSummary.sentence(for: "[!HideMeter MeterTitle]", in: skin),
                "Hides \(LayerNaming.layer(skin.meter(named: "MeterTitle")!, in: skin).title)")

        // The click picker reads back only what it writes.
        t.equal(ClickAction.parse(#"["https://example.com"]"#), .openWebsite("https://example.com"))
        t.equal(ClickAction.openWebsite("https://example.com").text, #"["https://example.com"]"#)
        t.equal(ClickAction.parse(#"["/Applications/Calculator.app"]"#), .openApp("/Applications/Calculator.app"))
        t.equal(ClickAction.parse("[!ToggleMeter MeterTitle][!Redraw]"), .toggleLayer("MeterTitle"))
        t.equal(ClickAction.parse("[!Refresh]"), .reload)
        t.equal(ClickAction.parse(""), .nothing)
        let custom = "[!ToggleMeter MeterTitle][!SetVariable A 1]"
        t.equal(ClickAction.parse(custom), .custom(custom), "anything else stays as written")
        t.equal(ClickAction.parse("[!ToggleMeter MeterTitle]"), .custom("[!ToggleMeter MeterTitle]"),
                "without its redraw it would be written differently: kept")
        for a in [ClickAction.openWebsite("https://a.b/c"), .toggleLayer("Meter Two"), .reload,
                  .toggleWidget(config: "Deskset\\Clock", file: "Clock.ini"),
                  .changeColor(section: "MeterTitle", key: "FontColor", color: "255,0,0,255"), .showLayer("M")] {
            t.equal(ClickAction.parse(a.text), a, "round trip: \(a.text)")
        }
    }
}
