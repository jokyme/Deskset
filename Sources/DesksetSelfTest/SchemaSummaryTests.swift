import Foundation
@testable import DesksetCore

/// The schema's essentials and "More" summaries. Suites: "Editor: schema levels …", "Editor: live data
/// catalogue" (WP-C).
func runSchemaSummaryTests(_ t: TestRunner) {
    typealias S = EditorSchema

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
        t.equal(titles, ["On This Mac", "Calculate", "From the Web", "Weather and Sun"])
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

}
