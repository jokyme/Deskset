import Foundation
@testable import DesksetCore

// Seeding a new instance of a widget with what a running one has shown (`SkinRuntimeState`, `Skin.runtimeState`,
// `Skin.seed(from:)`, `Skin.seedGraphs(from:)`): the counter, variables set while it ran, the measures' values,
// averages, observed ranges and WebParser results, and the graphs.

/// A second instance of `skin`'s widget, loaded from its files (the Studio's instance next to the desktop copy).
private func twin(of skin: Skin, system: FakeSystem = FakeSystem(), ini: String? = nil) throws -> Skin {
    if let ini { try ini.write(to: skin.fileURL, atomically: true, encoding: .utf8) }
    let host = FakeHost()
    seedingHosts.append(host)
    let other = Skin(config: skin.config, fileURL: skin.fileURL, skinsDirectory: skin.skinsDirectory, system: system,
                     host: host)
    try other.load()
    return other
}

private var seedingHosts: [FakeHost] = []

@discardableResult
private func spin(_ timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return true
}

func runSeedingTests(_ t: TestRunner) {
    t.suite("Session: seeding — the counter, as a mirror and as a successor") {
        let (source, _) = try makeSkin(t, """
            [MeasureCount]
            Measure=Calc
            Formula=Counter

            [MeterCount]
            Meter=String
            MeasureName=MeasureCount
            """)
        for _ in 0..<5 { source.update() }
        t.equal(source.counter, 5)
        let mirror = try twin(of: source)
        mirror.seed(from: source.runtimeState(as: .mirror))
        mirror.update()
        t.equal(mirror.counter, 5, "a mirror's first update computes what the source's last one did")
        t.equal(text(mirror, "MeterCount"), text(source, "MeterCount"))
        let successor = try twin(of: source)
        successor.seed(from: source.runtimeState(as: .successor, including: .counter))
        successor.update()
        t.equal(successor.counter, 6, "a successor goes on counting")
        let fresh = try twin(of: source)
        fresh.seed(from: source.runtimeState(as: .successor, including: .graphs))
        fresh.update()
        t.equal(fresh.counter, 1, "the counter only when taken")
    }

    t.suite("Session: seeding — variables set while the widget ran") {
        let ini = """
            [Variables]
            Page=1
            Theme=Light

            [MeterPage]
            Meter=String
            Text=Page #Page# #Theme# #Extra#
            DynamicVariables=1
            """
        let (source, _) = try makeSkin(t, ini)
        source.update()
        source.setVariable("Page", "3")
        source.setVariable("Extra", "x")
        source.update()
        t.equal(text(source, "MeterPage"), "Page 3 Light x")
        // An editor preview's values are not what the widget runs.
        source.previewVariables(["Theme": "Dark", "Page": "9"])
        let state = source.runtimeState(as: .mirror)
        source.endPreview()
        t.equal(state.variables["page"], SkinRuntimeState.Variable(value: "3", definition: "1"))
        t.equal(state.variables["extra"], SkinRuntimeState.Variable(value: "x", definition: nil))
        t.equal(state.variables["theme"], nil, "a preview's value is not taken")
        t.equal(state, source.runtimeState(as: .mirror), "a value: taking it again gives the same")

        let studio = try twin(of: source)
        studio.seed(from: state)
        studio.update()
        t.equal(text(studio, "MeterPage"), "Page 3 Light x", "the variables set by clicks show on the new instance")

        // The files define Page differently now: the value set over the old definition is not taken.
        let redefined = try twin(of: source, ini: ini.replacingOccurrences(of: "Page=1", with: "Page=2"))
        redefined.seed(from: state)
        redefined.update()
        t.equal(text(redefined, "MeterPage"), "Page 2 Light x", "a variable whose definition changed follows the file")
    }

    t.suite("Session: seeding — measure values, averages and observed ranges") {
        let system = FakeSystem()
        let ini = """
            [Variables]
            Scale=10

            [MeasureCPU]
            Measure=CPU
            AverageSize=4

            [MeasureSteps]
            Measure=Calc
            Formula=MeasureSteps + #Scale#

            [MeasureRange]
            Measure=Calc
            Formula=MeasureCPU

            [MeterCPU]
            Meter=String
            MeasureName=MeasureCPU
            """
        let (source, _) = try makeSkin(t, ini, system: system)
        for cpu in [10.0, 20, 30] {
            system.cpu = cpu
            source.update()
        }
        t.equal(source.measure(named: "MeasureCPU")?.value, 20, "the average of three samples")
        t.equal(source.measure(named: "MeasureSteps")?.value, 30)
        t.equal(source.measure(named: "MeasureRange")?.maxValue, 20)
        let state = source.runtimeState(as: .mirror)
        t.equal(state.measures["measurecpu"]?.average, SkinRuntimeState.Average(samples: [10, 20, 30], next: 3))

        system.cpu = 40
        let studio = try twin(of: source, system: system)
        studio.seed(from: state)
        t.equal(studio.measure(named: "MeasureRange")?.maxValue, 20, "the observed range before the first update")
        studio.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 25, "the average goes on: (10 + 20 + 30 + 40) / 4")
        t.equal(studio.measure(named: "MeasureSteps")?.value, 40, "a Calc that reads itself goes on from its value")
        t.equal(studio.measure(named: "MeasureRange")?.maxValue, 25)

        // A measure written another way, or reading a variable defined another way now, starts afresh.
        let changed = ini.replacingOccurrences(of: "AverageSize=4", with: "AverageSize=4\nMinValue=0")
            .replacingOccurrences(of: "Scale=10", with: "Scale=5")
        let other = try twin(of: source, system: system, ini: changed)
        other.seed(from: state)
        other.update()
        t.equal(other.measure(named: "MeasureCPU")?.value, 40, "its own options changed: no average taken")
        t.equal(other.measure(named: "MeasureSteps")?.value, 5, "it reads #Scale#, defined another way now")
        t.equal(other.measure(named: "MeasureRange")?.maxValue, 40, "an unchanged measure still takes its range")

        // Another type under the same name is not seeded.
        let retyped = try twin(of: source, system: system, ini: ini.replacingOccurrences(of: "[MeasureCPU]\nMeasure=CPU",
                                                                                          with: "[MeasureCPU]\nMeasure=Calc\nFormula=7"))
        retyped.seed(from: state)
        retyped.update()
        t.equal(retyped.measure(named: "MeasureCPU")?.value, 7)
    }

    t.suite("Session: seeding — Line and Histogram graphs") {
        let system = FakeSystem()
        let ini = """
            [MeasureCPU]
            Measure=CPU

            [MeterLine]
            Meter=Line
            MeasureName=MeasureCPU
            W=20
            H=10

            [MeterHistogram]
            Meter=Histogram
            MeasureName=MeasureCPU
            W=20
            H=10
            """
        let (source, _) = try makeSkin(t, ini, system: system)
        for cpu in [5.0, 15, 25, 35] {
            system.cpu = cpu
            source.update()
        }
        let line = { (s: Skin) in (s.meter(named: "MeterLine") as? LineMeter)?.lines.first?.history.samples ?? [] }
        let histogram = { (s: Skin) in (s.meter(named: "MeterHistogram") as? HistogramMeter)?.primaryHistory.samples ?? [] }
        t.equal(line(source), [5, 15, 25, 35])
        let state = source.runtimeState(as: .mirror)
        let studio = try twin(of: source, system: system)
        studio.seed(from: state)
        studio.update()
        studio.seedGraphs(from: state)
        t.equal(line(studio), line(source), "the Line's samples")
        t.equal(histogram(studio), histogram(source), "the Histogram's samples")
        studio.update()
        t.equal(line(studio).count, 5, "and it goes on adding")
    }

    t.suite("Session: seeding — a WebParser result shows before the new instance fetches") {
        let (source, _) = try makeSkin(t, """
            [MeasureParent]
            Measure=WebParser
            URL=file://#CURRENTPATH#page.txt
            RegExp=(?siU)<b>(.*)</b>.*<i>(.*)</i>
            UpdateRate=600

            [MeasureChild]
            Measure=WebParser
            URL=[MeasureParent]
            StringIndex=2

            [MeterChild]
            Meter=String
            MeasureName=MeasureChild
            """, files: ["Root/Sub/page.txt": "<b>one</b> <i>two</i>"])
        let parent = { (s: Skin) in s.measure(named: "MeasureParent") as? WebParserMeasure }
        source.update()
        let inFlight = source.runtimeState(as: .mirror)
        t.check(spin { parent(source)?.isFetching == false }, "the page was read")
        source.update()
        t.equal(text(source, "MeterChild"), "two")
        let state = source.runtimeState(as: .mirror)
        t.equal(state.measures["measureparent"]?.webParser?.captures, ["<b>one</b> <i>two</i>", "one", "two"])
        t.equal(state.measures["measureparent"]?.webParser?.updateCounter, 2, "where the parent is in its cycle")
        t.equal(state.measures["measurechild"]?.webParser?.result, "two")

        let studio = try twin(of: source)
        studio.seed(from: state)
        studio.update()
        t.equal(text(studio, "MeterChild"), "two", "the result shows on the new instance's first update")
        t.equal(parent(studio)?.fetchCount, 0, "without fetching the page again: its cycle goes on from the source's")
        t.equal(parent(studio)?.captures, parent(source)?.captures)
        // The Studio's instance loaded again after a step: its successor goes on in the same cycle, without fetching.
        let seeded = studio.runtimeState(as: .successor)
        t.equal(seeded.measures["measureparent"]?.webParser?.updateCounter, 3,
                "a seeded parent passes on where it is in its cycle, although it fetched nothing itself")
        let successor = try twin(of: source)
        successor.seed(from: seeded)
        successor.update()
        t.equal(text(successor, "MeterChild"), "two")
        t.equal(parent(successor)?.fetchCount, 0, "the successor does not fetch either")

        // Taken while the first page was still on its way: nothing to show, and the new instance fetches.
        t.equal(inFlight.measures["measureparent"]?.webParser, nil)
        let early = try twin(of: source)
        early.seed(from: inFlight)
        early.update()
        t.equal(parent(early)?.fetchCount, 1, "it reads the page itself")
        t.check(spin { parent(early)?.isFetching == false })
    }
}
