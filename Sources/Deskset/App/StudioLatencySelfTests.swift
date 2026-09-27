import AppKit
import DesksetCore

/// "App: studio latency": how long a property edit takes to reach the canvas, and an undo, on five reference widgets —
/// printed as p50 / p95 so every change of the editing pipeline can be measured against the same numbers. Only a
/// generous sanity bound is checked; `DESKSET_STUDIO_LATENCY_BUDGET_MS` makes the p95 a budget (a CI virtual machine can
/// stall for a whole second, so it is not one by default).
///
/// One sample is one step the way a user makes it: the edit (`commit`: the text in memory, the file, the Studio's
/// instance loaded again, the inspector following) and then a frame of the canvas drawn off-screen, each in its own turn
/// of the run loop (the undo manager groups what one event registers). The desktop copy reloads on the next turn, after
/// the canvas drew the step: its time is printed as a phase of its own (`desktop`), not part of the sample. A sixth,
/// heavy widget — a Lua script that builds its text as it loads, WebParser measures, a large include — shows what the
/// second load (the desktop copy's) costs. A gesture is measured too: each step of a drag of the layer (the previews
/// and a frame of the canvas), about 60 a second, and how many of them reached the desktop copy (at most about 20 a
/// second). The app's own timing of the desktop copy is used (`AppController.defersDesktopUpdates`).
/// `DESKSET_STUDIO_LATENCY_SAMPLES` sets the number of samples of each kind (default 12).
enum StudioLatencySelfTests {
    /// The reference widgets: config and the repository folder it comes from (0.1's example widgets, now test skins:
    /// the numbers stay comparable with earlier runs).
    static let references: [(config: String, folder: String)] = [
        ("Deskset\\Clock", "TestSkins"), ("Deskset\\System", "TestSkins"), ("Deskset\\Calendar", "TestSkins"),
        ("Audio\\Visualizer", "TestSkins"), ("Mac\\Glass", "TestSkins"),
    ]

    static func run(_ t: AppTestRunner) {
        t.suite("App: studio latency") {
            // Earlier suites' widgets would keep updating on the main thread and make the numbers noisy.
            AppSelfTest.stopEarlierSkins()
            let environment = ProcessInfo.processInfo.environment
            let samples = environment["DESKSET_STUDIO_LATENCY_SAMPLES"].flatMap(Int.init).map { min(max($0, 2), 500) } ?? 12
            let budget = environment["DESKSET_STUDIO_LATENCY_BUDGET_MS"].flatMap(Double.init)
            var load = [0.0, 0.0, 0.0]
            _ = getloadavg(&load, 3)
            print(String(format: "    load average %.2f %.2f %.2f; %d samples of each kind%@", load[0], load[1], load[2],
                         samples, budget.map { String(format: "; budget %.0f ms (p95)", $0) } ?? ""))
            for reference in references {
                try measure(t, config: reference.config, samples: samples, budget: budget) {
                    try FriendlyFixtures.openEditor(t, config: reference.config, from: reference.folder)
                }
            }
            try measure(t, config: "Studio\\Heavy", samples: samples, budget: nil) {
                try openHeavy(t)
            }
        }
    }

    struct Stat {
        var samples: [Double]
        var sorted: [Double] { samples.sorted() }
        /// Nearest rank.
        func percentile(_ p: Double) -> Double {
            let s = sorted
            guard !s.isEmpty else { return .nan }
            let rank = Int((p / 100 * Double(s.count)).rounded(.up))
            return s[min(max(rank - 1, 0), s.count - 1)]
        }
        var p50: Double { percentile(50) }
        var p95: Double { percentile(95) }
        var text: String { String(format: "p50 %.1f ms · p95 %.1f ms (n=%d)", p50, p95, samples.count) }
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(since start: UInt64) -> Double { Double(now() - start) / 1e6 }

    /// A widget whose load is expensive: a script that builds its text as it loads (`Initialize`), four WebParser
    /// measures reading local pages, and an include of 400 variables. Its budget is not checked.
    static func openHeavy(_ t: AppTestRunner) throws -> (app: AppController, editor: InspectorWindowController)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        let folder = app.skinsDirectory.appendingPathComponent("Studio/Heavy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = (0..<200).map { "<li>item \($0)</li>" }.joined(separator: "\n")
        try page.write(to: folder.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try ("[Variables]\n" + (0..<400).map { "Var\($0)=\($0 * 7 % 255),\($0 * 13 % 255),\($0 * 29 % 255)" }
            .joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("Vars.inc"), atomically: true,
                                                   encoding: .utf8)
        try """
            function Initialize()
              local parts = {}
              local sum = 0
              for i = 1, 3000000 do sum = sum + (i % 7) end
              for i = 1, 40 do parts[#parts + 1] = 'line ' .. i .. ' ' .. sum end
              SKIN:Bang('!SetOption', 'MeterBuilt', 'Text', table.concat(parts, ' | '))
            end
            function Update() return 0 end
            """.write(to: folder.appendingPathComponent("build.lua"), atomically: true, encoding: .utf8)
        var ini = """
            [Rainmeter]
            Update=1000

            [Variables]
            @Include=Vars.inc

            [MeasureBuild]
            Measure=Script
            ScriptFile=build.lua

            [MeterLabel]
            Meter=String
            Text=Heavy
            FontSize=12

            [MeterBuilt]
            Meter=String
            Y=20
            W=300
            H=40
            ClipString=1
            FontSize=9

            """
        for i in 0..<4 {
            ini += """

                [MeasurePage\(i)]
                Measure=WebParser
                URL=file://#CURRENTPATH#page.html
                RegExp=(?siU)<li>(.*)</li>.*<li>(.*)</li>
                StringIndex=\(i % 2 + 1)
                UpdateRate=600

                """
        }
        try ini.write(to: folder.appendingPathComponent("Heavy.ini"), atomically: true, encoding: .utf8)
        app.rescanLibrary()
        guard let c = app.activate(config: "Studio\\Heavy", file: "Heavy.ini") else {
            t.check(false, "Studio\\Heavy loads")
            return nil
        }
        app.showInspector(for: c)
        guard let editor = app.inspector else {
            t.check(false, "the editor opens")
            return nil
        }
        return (app, editor)
    }

    static func measure(_ t: AppTestRunner, config: String, samples: Int, budget: Double?,
                        open: () throws -> (app: AppController, editor: InspectorWindowController)?) throws {
        guard let (app, editor) = try open() else { return }
        defer { editor.window?.close() }
        app.defersDesktopUpdates = true
        defer { app.defersDesktopUpdates = false }
        guard let skin = editor.skin, let session = editor.session else { return t.check(false, "\(config) opens") }
        guard let target = skin.meters.first(where: { $0 is StringMeter })?.name ?? skin.meters.first?.name else {
            return t.check(false, "\(config) has a layer")
        }
        editor.select(section: target)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let files = skin.sourceFiles
        let original = files.map { (try? Data(contentsOf: $0)) ?? Data() }
        let canvas = editor.canvas
        canvas.updateSize()
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return t.check(false, "canvas") }
        func frame() { canvas.cacheDisplay(in: canvas.bounds, to: rep) }
        frame()
        let written = editor.skin?.meter(named: target)?.rawOption("FontSize").flatMap { OptionValue.number($0) } ?? 12
        let base = Int(written.isFinite ? min(max(written, 1), 400) : 12)

        var edits: [Double] = [], undos: [Double] = []
        var phases: [String: [Double]] = [:]
        for i in 0..<samples {
            // 13, 14, 13, 14…: every edit changes the file.
            let value = String(base + 1 + i % 2)
            let start = now()
            editor.commit([.init(section: target, key: "FontSize", value: value, own: true)], name: "Change Font Size")
            frame()
            edits.append(ms(since: start))
            // The desktop copy reloads on the next turn: its phase is taken once it ran.
            EditorWindowSelfTests.settle()
            session.flushDesktopRefresh()
            for (phase, time) in session.lastTimings { phases[phase, default: []].append(time) }
        }
        t.equal(editor.skin?.meter(named: target)?.rawOption("FontSize"), String(base + 1 + (samples - 1) % 2),
                "\(config): the edits reached the Studio's instance")
        var undoPhases: [String: [Double]] = [:]
        for _ in 0..<samples {
            let start = now()
            editor.window?.undoManager?.undo()
            frame()
            undos.append(ms(since: start))
            EditorWindowSelfTests.settle()
            session.flushDesktopRefresh()
            for (phase, time) in session.lastTimings { undoPhases[phase, default: []].append(time) }
        }
        t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(config): every edit undone, byte for byte")
        t.check(app.controller(for: config) != nil, "\(config) still runs")

        // A drag of the layer: every mouse event previews it (in the Studio's instance at once, on the desktop at most
        // about 20 times a second) and the canvas draws a frame.
        var gestureFrames: [Double] = []
        let sentBefore = session.desktopPreviewsSent
        if let meter = editor.skin?.meter(named: target) {
            editor.canvasSelectionChanged([target])
            let start = NSPoint(x: canvas.origin.x + CGFloat(meter.frame.x + min(meter.frame.width, 4) / 2),
                                y: canvas.origin.y + CGFloat(meter.frame.y + min(meter.frame.height, 4) / 2))
            canvas.beginGesture(.move, at: start)
            for i in 1...max(samples * 3, 30) {
                let t0 = now()
                canvas.drag(to: NSPoint(x: start.x + CGFloat(i % 20), y: start.y), snapping: false)
                frame()
                gestureFrames.append(ms(since: t0))
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
            }
            canvas.endGesture(keep: false)
            EditorWindowSelfTests.settle()
        }
        let sent = session.desktopPreviewsSent - sentBefore
        t.check(gestureFrames.isEmpty || sent <= gestureFrames.count / 2 + 1,
                "\(config): the desktop copy got \(sent) of \(gestureFrames.count) previews")
        t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(config): a cancelled drag writes nothing")

        let edit = Stat(samples: edits), undo = Stat(samples: undos)
        func breakdown(_ phases: [String: [Double]]) -> String {
            ["plan", "apply", "write", "studio", "desktop"].compactMap { phase in
                phases[phase].map { String(format: "%@ %.1f", phase, Stat(samples: $0).p50) }
            }.joined(separator: ", ")
        }
        print("    LATENCY \(config) | edit → canvas | \(edit.text) | p50 by phase (ms): \(breakdown(phases))")
        print("    LATENCY \(config) | undo → canvas | \(undo.text) | p50 by phase (ms): \(breakdown(undoPhases))")
        if !gestureFrames.isEmpty {
            print("    LATENCY \(config) | gesture frame | \(Stat(samples: gestureFrames).text) | previews on the desktop: "
                  + "\(sent) of \(gestureFrames.count)")
        }
        // A sanity bound only: a step that takes seconds is broken, whatever the machine.
        t.check(edit.p95 < 5_000 && undo.p95 < 5_000, "\(config): \(edit.text); undo \(undo.text)")
        if let budget {
            t.check(edit.p95 <= budget, "\(config): edit p95 \(edit.p95) ms over the budget of \(budget) ms")
            t.check(undo.p95 <= budget, "\(config): undo p95 \(undo.p95) ms over the budget of \(budget) ms")
        }
    }
}
