import AppKit
import DesksetCore

/// "App: studio latency": how long a property edit takes to reach the canvas, and an undo, on five reference widgets —
/// printed as p50 / p95 so every change of the editing pipeline can be measured against the same numbers. Only a
/// generous sanity bound is checked; `DESKSET_STUDIO_LATENCY_BUDGET_MS` makes the p95 a budget (a CI virtual machine can
/// stall for a whole second, so it is not one by default).
///
/// One sample is one step the way a user makes it: the edit (`commit`: the text in memory, the file, the Studio's
/// instance patched (`studio.patch`) or loaded again (`studio.reload`), the inspector following) and then a frame of the canvas drawn off-screen, each in its own turn
/// of the run loop (the undo manager groups what one event registers). The desktop copy reloads on the next turn, after
/// the canvas drew the step: its time is printed as a phase of its own (`desktop`), not part of the sample. Every phase
/// is printed as p50 / p95 (`EditingSession.lastTimings`: the Studio's reload split into loading, its first update and
/// the window's parts; `frame`: the canvas drawn), and each widget runs three kinds of step (`Run`): a font size and a
/// text color in design mode, and the font size again with the code pane open (split), which follows every step. A sixth,
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
            // `DESKSET_STUDIO_LATENCY_ONLY` (part of a config, e.g. "Calendar"): only the widgets it names.
            let only = environment["DESKSET_STUDIO_LATENCY_ONLY"]?.lowercased()
            for reference in references where only.map({ reference.config.lowercased().contains($0) }) ?? true {
                try measure(t, config: reference.config, samples: samples, budget: budget) {
                    try FriendlyFixtures.openEditor(t, config: reference.config, from: reference.folder)
                }
            }
            if let only, !"studio\\heavy".contains(only) { return }
            try measure(t, config: "Studio\\Heavy", samples: samples, budget: nil, runs: [.fontSize]) {
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

    /// One kind of step measured on a widget: the centre the Studio shows (`design`: the canvas only; `split`: the
    /// code pane too, which follows every step) and the option each edit writes into the layer's own section.
    struct Run {
        var mode: InspectorWindowController.Mode
        var key: String
        var undoName: String
        /// The value of the `i`-th edit, from the value written before the run: every edit changes the file.
        var value: (_ written: String?, _ i: Int) -> String
        var label: String { "\(mode.rawValue) · \(key)" }

        static let fontSize = Run(mode: .design, key: "FontSize", undoName: "Change Font Size") { written, i in
            let number = written.flatMap { OptionValue.number($0) } ?? 12
            let base = Int(number.isFinite ? min(max(number, 1), 400) : 12)
            // 13, 14, 13, 14…
            return String(base + 1 + i % 2)
        }
        static let fontColor = Run(mode: .design, key: "FontColor", undoName: "Change Text Color") { _, i in
            i % 2 == 0 ? "13,121,201,254" : "201,81,13,253"
        }
        static let splitFontSize = Run(mode: .split, key: fontSize.key, undoName: fontSize.undoName, value: fontSize.value)
        /// What each reference widget runs, in this order (the first one also measures a gesture).
        static let all: [Run] = [fontSize, fontColor, splitFontSize]
    }

    /// The phases printed, in the order a step runs them (`EditingSession.lastTimings`, and `frame`: the canvas drawn
    /// after the step); phases not listed here follow in alphabetical order.
    static let phaseOrder = ["plan", "apply", "write", "studio", "studio.patch", "studio.reload", "studio.load",
                             "studio.update", "window", "window.widget",
                             "window.canvas", "window.layers", "window.inspector", "window.live values", "window.code",
                             "frame", "desktop"]

    /// "plan 0.7/0.9, apply 0.2/0.3, …": p50 / p95 of each phase measured.
    static func breakdown(_ phases: [String: [Double]]) -> String {
        let known = phaseOrder.filter { phases[$0] != nil }
        let others = phases.keys.filter { !phaseOrder.contains($0) && $0 != "total" }.sorted()
        return (known + others).map { phase in
            let stat = Stat(samples: phases[phase] ?? [])
            return String(format: "%@ %.1f/%.1f", phase, stat.p50, stat.p95)
        }.joined(separator: ", ")
    }

    static func measure(_ t: AppTestRunner, config: String, samples: Int, budget: Double?, runs: [Run] = Run.all,
                        open: () throws -> (app: AppController, editor: InspectorWindowController)?) throws {
        guard let (app, editor) = try open() else { return }
        defer { editor.window?.close() }
        app.defersDesktopUpdates = true
        defer { app.defersDesktopUpdates = false }
        guard let skin = editor.skin, editor.session != nil else { return t.check(false, "\(config) opens") }
        guard let target = skin.meters.first(where: { $0 is StringMeter })?.name ?? skin.meters.first?.name else {
            return t.check(false, "\(config) has a layer")
        }
        editor.select(section: target)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var load = [0.0, 0.0, 0.0]
        _ = getloadavg(&load, 3)
        print(String(format: "    LATENCY %@ | layer %@ | load average %.2f", config, target, load[0]))
        let files = skin.sourceFiles
        let original = files.map { (try? Data(contentsOf: $0)) ?? Data() }
        // `DESKSET_STUDIO_LATENCY_RUNS` (part of a run's label, e.g. "FontColor"): only the runs it names.
        let only = ProcessInfo.processInfo.environment["DESKSET_STUDIO_LATENCY_RUNS"]?.lowercased()
        for (i, run) in runs.enumerated() where only.map({ run.label.lowercased().contains($0) }) ?? true {
            if editor.mode != run.mode {
                editor.setMode(run.mode)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            measure(t, config: config, run: run, target: target, samples: samples, budget: budget, gesture: i == 0,
                    editor: editor, app: app, files: files, original: original)
        }
        if editor.mode != .design { editor.setMode(.design) }
    }

    static func measure(_ t: AppTestRunner, config: String, run: Run, target: String, samples: Int, budget: Double?,
                        gesture: Bool, editor: InspectorWindowController, app: AppController, files: [URL],
                        original: [Data]) {
        guard let session = editor.session else { return t.check(false, "\(config) has a session") }
        let name = "\(config) | \(run.label)"
        let canvas = editor.canvas
        canvas.updateSize()
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return t.check(false, "canvas") }
        func frame() { canvas.cacheDisplay(in: canvas.bounds, to: rep) }
        frame()
        let written = editor.skin?.meter(named: target)?.rawOption(run.key)

        var edits: [Double] = [], undos: [Double] = []
        var phases: [String: [Double]] = [:]
        // How the inspector followed the steps: in place, or built again (and why, the last time).
        let inPlaceBefore = editor.inPlace.updates, rebuildsBefore = editor.inspectorRebuildCount
        var fallbacks: [String: Int] = [:]
        var last = written
        for i in 0..<samples {
            let value = run.value(written, i)
            let start = now()
            editor.commit([.init(section: target, key: run.key, value: value, own: true)], name: run.undoName)
            let committed = now()
            frame()
            edits.append(ms(since: start))
            phases["frame", default: []].append(ms(since: committed))
            // The desktop copy reloads on the next turn: its phase is taken once it ran.
            EditorWindowSelfTests.settle()
            session.flushDesktopRefresh()
            for (phase, time) in session.lastTimings { phases[phase, default: []].append(time) }
            if let why = editor.inPlace.lastFallback { fallbacks[why, default: 0] += 1 }
            last = value
        }
        t.equal(editor.skin?.meter(named: target)?.rawOption(run.key), last, "\(name): the edits reached the Studio's instance")
        var undoPhases: [String: [Double]] = [:]
        for _ in 0..<samples {
            let start = now()
            editor.window?.undoManager?.undo()
            let undone = now()
            frame()
            undos.append(ms(since: start))
            undoPhases["frame", default: []].append(ms(since: undone))
            EditorWindowSelfTests.settle()
            session.flushDesktopRefresh()
            for (phase, time) in session.lastTimings { undoPhases[phase, default: []].append(time) }
            if let why = editor.inPlace.lastFallback { fallbacks[why, default: 0] += 1 }
        }
        let inPlaceSteps = editor.inPlace.updates - inPlaceBefore, rebuilt = editor.inspectorRebuildCount - rebuildsBefore
        t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(name): every edit undone, byte for byte")
        t.check(app.controller(for: config) != nil, "\(config) still runs")

        // A drag of the layer: every mouse event previews it (in the Studio's instance at once, on the desktop at most
        // about 20 times a second) and the canvas draws a frame.
        var gestureFrames: [Double] = []
        let sentBefore = session.desktopPreviewsSent
        if gesture, let meter = editor.skin?.meter(named: target) {
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
                "\(name): the desktop copy got \(sent) of \(gestureFrames.count) previews")
        t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(name): a cancelled drag writes nothing")

        let edit = Stat(samples: edits), undo = Stat(samples: undos)
        print("    LATENCY \(name) | edit → canvas | \(edit.text)")
        print("    LATENCY \(name) | edit phases, p50/p95 ms | \(breakdown(phases))")
        print("    LATENCY \(name) | undo → canvas | \(undo.text)")
        print("    LATENCY \(name) | undo phases, p50/p95 ms | \(breakdown(undoPhases))")
        print("    LATENCY \(name) | inspector | in place \(inPlaceSteps), built again \(rebuilt)"
              + (fallbacks.isEmpty ? "" : " (\(fallbacks.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: "; ")))"))
        if !gestureFrames.isEmpty {
            print("    LATENCY \(name) | gesture frame | \(Stat(samples: gestureFrames).text) | previews on the desktop: "
                  + "\(sent) of \(gestureFrames.count)")
        }
        // One line to compare runs with: the step's p50 / p95 and the p50 of the phases that matter most.
        func p50(_ phase: String, in phases: [String: [Double]]) -> Double {
            phases[phase].map { Stat(samples: $0).p50 } ?? 0
        }
        print(String(format: "    LATENCY SUMMARY %@ | edit p50 %.0f / p95 %.0f ms: inspector %.0f, layers %.0f, patch %.1f, "
                     + "load %.0f, update %.0f, code %.0f, frame %.0f | undo p50 %.0f / p95 %.0f ms",
                     name, edit.p50, edit.p95, p50("window.inspector", in: phases), p50("window.layers", in: phases),
                     p50("studio.patch", in: phases), p50("studio.load", in: phases), p50("studio.update", in: phases),
                     p50("window.code", in: phases), p50("frame", in: phases), undo.p50, undo.p95))
        // A value edit and its undo reach the Studio's instance as a patch: it never loads again.
        t.check(phases["studio.reload"] == nil && undoPhases["studio.reload"] == nil,
                "\(name): the Studio's instance took the edits and the undos without loading again")
        // A sanity bound only: a step that takes seconds is broken, whatever the machine.
        t.check(edit.p95 < 5_000 && undo.p95 < 5_000, "\(name): \(edit.text); undo \(undo.text)")
        if let budget {
            t.check(edit.p95 <= budget, "\(name): edit p95 \(edit.p95) ms over the budget of \(budget) ms")
            t.check(undo.p95 <= budget, "\(name): undo p95 \(undo.p95) ms over the budget of \(budget) ms")
        }
    }
}
