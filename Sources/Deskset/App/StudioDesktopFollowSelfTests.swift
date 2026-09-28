import AppKit
import DesksetCore

/// "App: studio desktop": the widget on the desktop follows value steps as a patch — the same copy, its graphs and
/// counter kept, the new value in effect — and loads again for structural ones; the Studio's instance opens on what the
/// desktop copy shows (variables set by clicks, a WebParser result, averages).
enum StudioDesktopFollowSelfTests {
    static func run(_ t: AppTestRunner) {
        patchTests(t)
        seedingTests(t)
    }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    static func patchTests(_ t: AppTestRunner) {
        t.suite("App: studio desktop: the desktop copy's graphs survive value steps and their undo") {
            let graphs = StudioSessionSelfTests.graphs
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "DeskGraphs", graphs) else { return }
            guard let session = editor.session, let c = app.controller(for: "Studio\\DeskGraphs") else {
                return t.check(false, "loaded")
            }
            for _ in 0..<5 { c.skin.update() }
            let shown = StudioSessionSelfTests.samples(c.skin), counter = c.skin.counter
            t.check(shown.allSatisfy { $0.count >= 5 }, "the desktop's graphs have samples: \(shown)")
            func title() -> Meter? { c.skin.meter(named: "MeterTitle") }
            let height = title()?.frame.height ?? 0
            let counts = session.desktopPatchCounts

            editor.select(section: "MeterTitle")
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "20", own: true)], name: "Change Font Size")
            t.check(read(url).contains("FontSize=20\n"), "written")
            t.check(app.controller(for: "Studio\\DeskGraphs") === c, "the same desktop copy")
            t.equal(StudioSessionSelfTests.samples(c.skin), shown, "its graphs keep their samples")
            t.equal(c.skin.counter, counter, "and its counter")
            t.equal(title()?.rawOption("FontSize"), "20")
            t.check((title()?.frame.height ?? 0) > height, "the new size in effect: \(title()?.frame.height ?? 0) > \(height)")
            t.equal(session.desktopPatchCounts.applied, counts.applied + 1, "one patch")
            t.equal(session.desktopPatchCounts.refused, counts.refused, "none refused")
            settle()

            editor.window?.undoManager?.undo()
            t.equal(read(url), graphs, "undone, byte for byte")
            t.check(app.controller(for: "Studio\\DeskGraphs") === c, "the undo is a patch too")
            t.equal(StudioSessionSelfTests.samples(c.skin), shown, "the graphs still keep their samples")
            t.equal(title()?.rawOption("FontSize"), "12")
            t.equal(title()?.frame.height, height, "the old size in effect")
            settle()
            editor.window?.undoManager?.redo()
            t.check(app.controller(for: "Studio\\DeskGraphs") === c, "and so is the redo")
            t.equal(title()?.rawOption("FontSize"), "20")
            t.equal(StudioSessionSelfTests.samples(c.skin), shown)
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // Structural steps still load the desktop copy again.
            let added = graphs + "[MeterNew]\nMeter=String\nText=New\nY=40\n"
            try session.apply("Add Layer", [.editSource(file: url, text: added, encoding: nil)])
            guard let now = app.controller(for: "Studio\\DeskGraphs") else { return t.check(false, "still loaded") }
            t.check(now !== c, "a layer added: the desktop copy loaded again")
            t.check(now.skin.meter(named: "MeterNew") != nil)
            settle()
            try session.apply("Change Update", [.setValue(file: url, section: "Rainmeter", key: "Update", value: "-2",
                                                          afterIncludes: false)])
            t.check(app.controller(for: "Studio\\DeskGraphs") !== now, "a [Rainmeter] option: loaded again")
            editor.window?.close()
        }

        t.suite("App: studio desktop: a step that moves the widget's window moves it after the patch") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "DeskMove", StudioSessionSelfTests.graphs)
            else { return }
            guard let session = editor.session, let c = app.controller(for: "Studio\\DeskMove") else {
                return t.check(false, "loaded")
            }
            let from = c.topLeftPosition
            let to = WidgetPosition(x: 820, y: 640)
            try session.apply("Fit Widget", [.setValue(file: url, section: "MeterTitle", key: "FontSize", value: "18",
                                                       afterIncludes: false)],
                              commands: [.moveWidget(from: WidgetPosition(x: from.x, y: from.y), to: to)])
            t.check(app.controller(for: "Studio\\DeskMove") === c, "patched")
            t.equal(c.skin.meter(named: "MeterTitle")?.rawOption("FontSize"), "18")
            t.equal(c.topLeftPosition.x, to.x, "moved")
            t.equal(c.topLeftPosition.y, to.y)
            settle()
            editor.window?.undoManager?.undo()
            t.check(app.controller(for: "Studio\\DeskMove") === c, "the undo is a patch")
            t.equal(c.topLeftPosition.x, from.x, "moved back")
            t.equal(c.topLeftPosition.y, from.y)
            editor.window?.close()
        }
    }

    static func seedingTests(_ t: AppTestRunner) {
        t.suite("App: studio desktop: the Studio opens on what the desktop copy shows") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("Studio/Shown")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "<b>one</b> <i>two</i>".write(to: folder.appendingPathComponent("page.txt"), atomically: true,
                                              encoding: .utf8)
            try """
                [Rainmeter]
                Update=-1

                [Variables]
                Page=1

                [MeasureTens]
                Measure=Calc
                Formula=Counter * 10
                AverageSize=8

                [MeasureParent]
                Measure=WebParser
                URL=file://#CURRENTPATH#page.txt
                RegExp=(?siU)<b>(.*)</b>.*<i>(.*)</i>
                UpdateRate=600

                [MeasureChild]
                Measure=WebParser
                URL=[MeasureParent]
                StringIndex=2

                [MeterNext]
                Meter=Image
                SolidColor=0,0,0
                W=20
                H=20
                LeftMouseUpAction=[!SetVariable Page 3][!UpdateMeter *][!Redraw]

                [MeterPage]
                Meter=String
                Y=24
                Text=Page #Page#
                DynamicVariables=1

                [MeterChild]
                Meter=String
                MeasureName=MeasureChild
                Y=44

                """.write(to: folder.appendingPathComponent("Shown.ini"), atomically: true, encoding: .utf8)
            guard let c = app.activate(config: "Studio\\Shown", file: "Shown.ini") else { return t.check(false, "loads") }
            func parent(_ skin: Skin?) -> WebParserMeasure? { skin?.measure(named: "MeasureParent") as? WebParserMeasure }
            func text(_ skin: Skin?, _ meter: String) -> String? { (skin?.meter(named: meter) as? StringMeter)?.text }
            // The desktop copy read its page, counted its updates (one as it loaded) and was clicked to page 3.
            c.skin.update()
            t.check(AppSelfTest.spin(timeout: 10) { parent(c.skin)?.isFetching == false }, "the page was read")
            c.skin.update()
            c.skin.update()
            c.skin.mouseEvent(.leftUp, x: 5, y: 5)
            t.equal(c.skin.variable("Page"), "3", "clicked")
            t.equal(text(c.skin, "MeterPage"), "Page 3")
            t.equal(text(c.skin, "MeterChild"), "two")
            let averaged = c.skin.runtimeState(as: .mirror).measures["measuretens"]?.average?.samples
            t.equal(averaged, [0, 10, 20, 30], "the desktop copy averages the samples of its four updates")

            app.showInspector(for: c)
            guard let editor = app.inspector, let studio = editor.skin, studio !== c.skin else {
                return t.check(false, "the Studio opens its own instance")
            }
            t.equal(text(studio, "MeterPage"), "Page 3", "the variable set by the click shows on the canvas")
            t.equal(text(studio, "MeterChild"), "two", "the WebParser result shows on the canvas")
            t.equal(parent(studio)?.fetchCount, 0, "before the Studio's instance fetched anything")
            let samples = studio.runtimeState(as: .mirror).measures["measuretens"]?.average?.samples
            t.equal(samples.map { Array($0.prefix(4)) }, [0, 10, 20, 30], "the average goes on from the desktop's samples")
            t.equal(samples?.count, 5)
            t.equal(studio.measure(named: "MeasureTens")?.value, (0 + 10 + 20 + 30 + 30) / 5.0,
                    "its first update computes the counter the desktop's last one did")
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            t.equal(parent(studio)?.fetchCount, 0, "and it does not fetch the page again: its cycle goes on")
            editor.window?.close()
        }
    }
}
