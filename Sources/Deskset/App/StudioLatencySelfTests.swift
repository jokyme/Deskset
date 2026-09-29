import AppKit
import DesksetCore

/// "App: studio latency": how long a property edit takes to reach the screen, and an undo, on five reference widgets —
/// printed as p50 / p95 so every change of the editing pipeline can be measured against the same numbers. Only a
/// generous sanity bound is checked; `DESKSET_STUDIO_LATENCY_BUDGET_MS` makes the p95 a budget (a CI virtual machine can
/// stall for a whole second, so it is not one by default). Design §9.5's target (≤ 50 ms at p95 on an M4 Pro) is for a
/// release build; a debug build's numbers are printed for information (the build is printed with them).
///
/// One sample is one step the way a user makes it: the edit (`commit`: the text in memory, the file, the Studio's
/// instance patched (`studio.patch`) or loaded again (`studio.reload`), the inspector following) and then the Studio
/// window's display pass (`window.displayIfNeeded()`: the layout and drawing of everything the step changed — the
/// canvas's planes, the inspector's rows, the layer list, the code — with the window ordered in off every display), each
/// in its own turn of the run loop (the undo manager groups what one event registers). Every value is new (a font size
/// one larger each time, a color from a long sequence): nothing the widget laid out before is cached for it. The
/// canvas drawn alone off-screen is a phase of its own (`frame`, not part of the sample). What is named from the whole
/// widget (`names`) and the desktop copy's patch (`desktop`) follow on the next turn, after the window drew the step:
/// their times are printed as phases, not part of the sample, and a value step that loads the desktop copy again fails
/// the suite. Steps in a row (`back to back`: a held ⌘Z, a stepper's repeat) are measured too: each step starts as the
/// one before it drew, so it waits for that one's names and desktop patch — printed as the main thread's work between
/// steps.
///
/// Every phase is printed as p50 / p95 (`EditingSession.lastTimings`: the Studio's reload split into loading, its first
/// update and the window's parts), and each widget runs three kinds of step (`Run`): a font size and a text color in
/// design mode, and the font size again with the code pane open (split), which follows every step by its edits; the split
/// run also times typed code (the value typed over in the code pane) from the end of the typing pause to the window's
/// display, nothing written until the commit, and a layer typed in two pauses, which waits for the commit (no load at a
/// pause) and loads the Studio's instance once when saved. A sixth, heavy widget — a Lua script that builds its text as it
/// loads, WebParser measures, a large include — shows that a step costs no load there either (neither the Studio's
/// instance nor the desktop copy loads again). A gesture is measured too: each step of a drag of the layer (the previews
/// and a frame of the canvas), about 60 a second, and how many of them reached the desktop copy (at most about 20 a
/// second). The app's own timing of the desktop copy is used (`AppController.defersDesktopUpdates`).
/// `DESKSET_STUDIO_LATENCY_SAMPLES` sets the number of samples of each kind (default 40: the p95 is then not the
/// slowest sample, which one scheduling hiccup decides).
enum StudioLatencySelfTests {
    /// The reference widgets: config and the repository folder it comes from (0.1's example widgets, now test skins:
    /// the numbers stay comparable with earlier runs).
    static let references: [(config: String, folder: String)] = [
        ("Deskset\\Clock", "TestSkins"), ("Deskset\\System", "TestSkins"), ("Deskset\\Calendar", "TestSkins"),
        ("Audio\\Visualizer", "TestSkins"), ("Mac\\Glass", "TestSkins"),
    ]

    static func run(_ t: AppTestRunner) {
        let environment = ProcessInfo.processInfo.environment
        // 40 samples: the p95 is then not the slowest one. A CI machine (about 3 times slower) takes fewer, so each
        // widget's suite stays well inside the watchdog's time.
        let samples = environment["DESKSET_STUDIO_LATENCY_SAMPLES"].flatMap(Int.init).map { min(max($0, 2), 500) }
            ?? (environment["CI"] == nil ? 40 : 12)
        let budget = environment["DESKSET_STUDIO_LATENCY_BUDGET_MS"].flatMap(Double.init)
        // `DESKSET_STUDIO_LATENCY_ONLY` (part of a config, e.g. "Calendar"): only the widgets it names.
        let only = environment["DESKSET_STUDIO_LATENCY_ONLY"]?.lowercased()
        func header() {
            // Earlier suites' widgets would keep updating on the main thread and make the numbers noisy.
            AppSelfTest.stopEarlierSkins()
            var load = [0.0, 0.0, 0.0]
            _ = getloadavg(&load, 3)
            print(String(format: "    %@ build; load average %.2f %.2f %.2f; %d samples of each kind%@", build, load[0],
                         load[1], load[2], samples, budget.map { String(format: "; budget %.0f ms (p95)", $0) } ?? ""))
        }
        // One suite per widget: each one's time stays inside the watchdog's.
        for reference in references where only.map({ reference.config.lowercased().contains($0) }) ?? true {
            t.suite("App: studio latency: \(reference.config)") {
                header()
                try measure(t, config: reference.config, samples: samples, budget: budget) {
                    try FriendlyFixtures.openEditor(t, config: reference.config, from: reference.folder)
                }
            }
        }
        if let only, !"studio\\heavy".contains(only) { return }
        t.suite("App: studio latency: Studio\\Heavy") {
            header()
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

    /// The build the numbers are for (design §9.5's target is for release).
    static var build: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
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

        /// One larger each time, twelve sizes in turn (13 … 24 from 12): none was laid out in the last eleven steps, so
        /// no cached text layout serves it, and the sizes stay ones a user picks (much larger ones would push the text
        /// out of the widget and change what the steps are).
        static let fontSize = Run(mode: .design, key: "FontSize", undoName: "Change Font Size") { written, i in
            let number = written.flatMap { OptionValue.number($0) } ?? 12
            let base = Int(number.isFinite ? min(max(number, 1), 380) : 12)
            let size: Int = base + 1 + i % 12
            return String(size)
        }
        /// A new color each time (alpha 254 or 253, which no reference widget writes).
        static let fontColor = Run(mode: .design, key: "FontColor", undoName: "Change Text Color") { _, i in
            let r: Int = (13 + 37 * i) % 256, g: Int = (121 + 53 * i) % 256, b: Int = (201 + 71 * i) % 256
            let a: Int = 254 - i % 2
            return "\(r),\(g),\(b),\(a)"
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
                             "frame", "names", "desktop"]

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
        // Ordered in (off every display): a display pass lays out and draws the window as on screen.
        StudioMemorySelfTests.orderInOffScreen(editor.window)
        app.defersDesktopUpdates = true
        defer { app.defersDesktopUpdates = false }
        // As on screen: what is named from the whole widget follows a turn after the canvas (`followUpInPlace`), timed
        // as a phase of its own (`names`).
        InspectorInPlace.defersNamingForTests = true
        defer { InspectorInPlace.defersNamingForTests = nil }
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
        /// The canvas alone, drawn off-screen (the `frame` phase).
        func frame() { canvas.cacheDisplay(in: canvas.bounds, to: rep) }
        /// The window's display pass: what a step changed is laid out and drawn, as on screen at the end of the turn.
        func display() { editor.window?.displayIfNeeded() }
        frame()
        display()
        // Which of the canvas's planes a step asks to draw again (before the display pass draws them): the widget's area
        // of the content and the overlay, all of the work surface only when what it shows changed.
        var asked = [0, 0]
        let surfaceBefore = canvas.planes.surfaceAsks
        func noteAsked() {
            for (i, plane) in canvas.planes.all.enumerated() where plane.layer?.needsDisplay() ?? false { asked[i] += 1 }
        }
        let written = editor.skin?.meter(named: target)?.rawOption(run.key)

        let desktop = app.controller(for: config)
        let patchesBefore = session.desktopPatchCounts
        var edits: [Double] = [], undos: [Double] = []
        var phases: [String: [Double]] = [:]
        // How the inspector followed the steps: in place, or built again (and why, the last time).
        let inPlaceBefore = editor.inPlace.updates, rebuildsBefore = editor.inspectorRebuildCount
        var fallbacks: [String: Int] = [:]
        var last = written
        /// One step as the user makes it, `step` then the display pass (the sample), then the canvas alone and what
        /// follows on the next turn — the names, the desktop copy — as phases.
        func sample(_ step: () -> Void, into times: inout [Double], _ phases: inout [String: [Double]]) {
            // What the step autoreleased goes when it ends, as the app's event loop drains it after each event (the old
            // inspector rows, the old layer rows): otherwise they pile up until the suite ends, and later steps slow.
            autoreleasepool { measureSample(step, into: &times, &phases) }
        }
        func measureSample(_ step: () -> Void, into times: inout [Double], _ phases: inout [String: [Double]]) {
            let start = now()
            step()
            let stepped = now()
            noteAsked()
            display()
            times.append(ms(since: start))
            phases["window display", default: []].append(ms(since: stepped))
            let shown = now()
            frame()
            phases["frame", default: []].append(ms(since: shown))
            let framed = now()
            editor.flushInPlaceFollowUp()
            phases["names", default: []].append(ms(since: framed))
            // The desktop copy follows on the next turn: its phase is taken once it ran.
            EditorWindowSelfTests.settle()
            session.flushDesktopPatch()
            session.flushDesktopRefresh()
            for (phase, time) in session.lastTimings { phases[phase, default: []].append(time) }
            if let why = editor.inPlace.lastFallback { fallbacks[why, default: 0] += 1 }
        }
        for i in 0..<samples {
            let value = run.value(written, i)
            sample({ editor.commit([.init(section: target, key: run.key, value: value, own: true)], name: run.undoName) },
                   into: &edits, &phases)
            last = value
        }
        t.equal(editor.skin?.meter(named: target)?.rawOption(run.key), last, "\(name): the edits reached the Studio's instance")
        var undoPhases: [String: [Double]] = [:]
        for _ in 0..<samples {
            sample({ editor.window?.undoManager?.undo() }, into: &undos, &undoPhases)
        }
        let surfaceAsks = canvas.planes.surfaceAsks - surfaceBefore
        let inPlaceSteps = editor.inPlace.updates - inPlaceBefore, rebuilt = editor.inspectorRebuildCount - rebuildsBefore
        t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(name): every edit undone, byte for byte")

        // Steps in a row: each one starts as the one before it drew, in the next turn of the run loop — which first runs
        // what that one left for it (its names, the desktop copy's patch) — and ends with its own display pass.
        var backToBack: [Double] = [], backToBackUndos: [Double] = [], busy: [Double] = []
        var busyParts: [String: [Double]] = [:]
        func inARow(_ step: () -> Void, into times: inout [Double]) {
            autoreleasepool { measureInARow(step, into: &times) }
        }
        func measureInARow(_ step: () -> Void, into times: inout [Double]) {
            let start = now()
            // The next turn: the names and the desktop patch the step before left for it, then what the run loop does
            // besides (the undo manager closes the step's group, the window draws what the names changed).
            editor.flushInPlaceFollowUp()
            let named = now()
            session.flushDesktopPatch()
            let patched = now()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            busy.append(ms(since: start))
            busyParts["names", default: []].append(Double(named - start) / 1e6)
            busyParts["desktop", default: []].append(Double(patched - named) / 1e6)
            busyParts["turn", default: []].append(ms(since: patched))
            step()
            display()
            times.append(ms(since: start))
        }
        for i in 0..<samples {
            let value = run.value(written, samples + i)
            inARow({ editor.commit([.init(section: target, key: run.key, value: value, own: true)], name: run.undoName) },
                   into: &backToBack)
        }
        for _ in 0..<samples { inARow({ editor.window?.undoManager?.undo() }, into: &backToBackUndos) }
        EditorWindowSelfTests.settle()
        session.flushDesktopPatch()
        session.flushDesktopRefresh()
        t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(name): the steps in a row undone too")

        t.check(app.controller(for: config) != nil, "\(config) still runs")
        // The desktop copy took every edit and undo as a patch: the same copy, nothing loaded again.
        let patches = session.desktopPatchCounts
        t.check(app.controller(for: config) === desktop, "\(name): the desktop copy was not loaded again")
        t.equal(patches.refused - patchesBefore.refused, 0, "\(name): the desktop copy took every step as a patch")
        t.check(patches.applied - patchesBefore.applied >= 2, "\(name): \(patches.applied - patchesBefore.applied) patches")

        // With the code pane open: typed code reaches the window once typing pauses (not written, no step).
        var typed: [Double] = []
        var typedPhases: [String: [Double]] = [:]
        var typedLayer = TypedLayerTimes()
        if run.mode == .split, let code = editor.loadedCodeView {
            measureTypedCode(t, name: name, run: run, target: target, samples: samples, editor: editor, code: code,
                             display: display, times: &typed, phases: &typedPhases)
            t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(name): the typed code undone too")
            measureTypedLayer(t, name: name, samples: min(samples, 8), editor: editor, code: code, display: display,
                              times: &typedLayer)
            t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(name): the typed layer undone too")
        }

        // A drag of the layer: every mouse event previews it (in the Studio's instance at once, on the desktop at most
        // about 20 times a second) and the canvas draws a frame.
        var gestureFrames: [Double] = []
        let sentBefore = session.desktopPreviewsSent
        var gestureSeconds = 0.0
        if gesture, let meter = editor.skin?.meter(named: target) {
            editor.canvasSelectionChanged([target])
            let start = NSPoint(x: canvas.origin.x + CGFloat(meter.frame.x + min(meter.frame.width, 4) / 2),
                                y: canvas.origin.y + CGFloat(meter.frame.y + min(meter.frame.height, 4) / 2))
            let began = now()
            canvas.beginGesture(.move, at: start)
            for i in 1...min(max(samples * 3, 30), 90) {
                let t0 = now()
                canvas.drag(to: NSPoint(x: start.x + CGFloat(i % 20), y: start.y), snapping: false)
                display()
                gestureFrames.append(ms(since: t0))
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
            }
            canvas.endGesture(keep: false)
            gestureSeconds = ms(since: began) / 1000
            EditorWindowSelfTests.settle()
        }
        let sent = session.desktopPreviewsSent - sentBefore
        // At most one preview per `desktopPreviewInterval` of the gesture, and the first at once: a busy or slow machine
        // takes longer over the steps, and more previews go out in that time.
        let allowed = Int((gestureSeconds / EditingSession.desktopPreviewInterval).rounded(.up)) + 1
        t.check(gestureFrames.isEmpty || sent <= min(allowed, gestureFrames.count),
                "\(name): the desktop copy got \(sent) of \(gestureFrames.count) previews in "
                + "\(String(format: "%.2f", gestureSeconds)) s (at most \(allowed))")
        t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(name): a cancelled drag writes nothing")

        let edit = Stat(samples: edits), undo = Stat(samples: undos)
        let inRow = Stat(samples: backToBack), inRowUndo = Stat(samples: backToBackUndos), between = Stat(samples: busy)
        print("    LATENCY \(name) | edit → window | \(edit.text)")
        print("    LATENCY \(name) | edit phases, p50/p95 ms | \(breakdown(phases))")
        print("    LATENCY \(name) | undo → window | \(undo.text)")
        print("    LATENCY \(name) | undo phases, p50/p95 ms | \(breakdown(undoPhases))")
        print("    LATENCY \(name) | back to back: edit → window \(inRow.text) · undo → window \(inRowUndo.text) · "
              + "main thread busy per step before it \(between.text): \(breakdown(busyParts))")
        print("    LATENCY \(name) | inspector | in place \(inPlaceSteps), built again \(rebuilt)"
              + (fallbacks.isEmpty ? "" : " (\(fallbacks.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: "; ")))"))
        print("    LATENCY \(name) | canvas planes asked to draw again in \(2 * samples) steps | content \(asked[0]) "
              + "(all of the work surface \(surfaceAsks)), overlay \(asked[1])")
        if !gestureFrames.isEmpty {
            print("    LATENCY \(name) | gesture frame | \(Stat(samples: gestureFrames).text) | previews on the desktop: "
                  + "\(sent) of \(gestureFrames.count)")
        }
        let code = Stat(samples: typed)
        if !typed.isEmpty {
            print("    LATENCY \(name) | code → window, after the pause | \(code.text)")
            print("    LATENCY \(name) | code phases, p50/p95 ms | \(breakdown(typedPhases))")
        }
        if !typedLayer.pauses.isEmpty {
            print("    LATENCY \(name) | typed layer: pause → window (waits) \(Stat(samples: typedLayer.pauses).text) · "
                  + "save → window (one load) \(Stat(samples: typedLayer.saves).text)")
        }
        // One line to compare runs with: the step's p50 / p95 and the p50 of the phases that matter most.
        func p50(_ phase: String, in phases: [String: [Double]]) -> Double {
            phases[phase].map { Stat(samples: $0).p50 } ?? 0
        }
        print(String(format: "    LATENCY SUMMARY %@ | %@ | edit p50 %.0f / p95 %.0f ms: inspector %.0f, layers %.0f, patch %.1f, "
                     + "load %.0f, update %.0f, code %.0f, display %.0f | undo p50 %.0f / p95 %.0f ms | in a row p95 %.0f / %.0f ms, "
                     + "busy %.0f | frame %.0f | desktop patch %.1f",
                     name, build, edit.p50, edit.p95, p50("window.inspector", in: phases), p50("window.layers", in: phases),
                     p50("studio.patch", in: phases), p50("studio.load", in: phases), p50("studio.update", in: phases),
                     p50("window.code", in: phases), p50("window display", in: phases), undo.p50, undo.p95, inRow.p95,
                     inRowUndo.p95, between.p50, p50("frame", in: phases), p50("desktop", in: phases))
              + (typed.isEmpty ? "" : String(format: " | code → window p50 %.0f / p95 %.0f ms", code.p50, code.p95)))
        // A value edit and its undo reach the Studio's instance as a patch: it never loads again.
        t.check(phases["studio.reload"] == nil && undoPhases["studio.reload"] == nil,
                "\(name): the Studio's instance took the edits and the undos without loading again")
        // A sanity bound only: a step that takes seconds is broken, whatever the machine.
        t.check(edit.p95 < 5_000 && undo.p95 < 5_000, "\(name): \(edit.text); undo \(undo.text)")
        t.check(typedPhases["studio.reload"] == nil, "\(name): typed code reached the Studio's instance as a patch")
        if let budget {
            t.check(edit.p95 <= budget, "\(name): edit p95 \(edit.p95) ms over the budget of \(budget) ms")
            t.check(undo.p95 <= budget, "\(name): undo p95 \(undo.p95) ms over the budget of \(budget) ms")
            if !typed.isEmpty {
                t.check(code.p95 <= budget, "\(name): code → window p95 \(code.p95) ms over the budget of \(budget) ms")
            }
        }
    }

    /// Times of a layer typed in the code pane: each pause (which shows nothing new: the instance waits for the commit)
    /// and each save (which loads the Studio's instance once), both to the window's display pass.
    struct TypedLayerTimes {
        var pauses: [Double] = []
        var saves: [Double] = []
    }

    /// A layer typed at the end of the file in two pauses (its header, then `Meter=` and a text), `samples` times: at
    /// neither pause does the Studio's instance load again (it waits for the commit and the capsule says so); saving
    /// (⌘S) writes one "Edit Code" step and loads the instance once, which the step's undo takes back.
    static func measureTypedLayer(_ t: AppTestRunner, name: String, samples: Int, editor: InspectorWindowController,
                                  code: CodeEditorView, display: () -> Void, times: inout TypedLayerTimes) {
        guard let session = editor.session else { return t.check(false, "\(name): a session") }
        func typeAtEnd(_ text: String) {
            let end = (code.text as NSString).length
            code.textView.setSelectedRange(NSRange(location: end, length: 0))
            code.textView.insertText(text, replacementRange: code.textView.selectedRange())
        }
        for _ in 0..<samples {
            let instance = editor.skin
            for part in ["\n[MeterLatencyTyped]\n", "Meter=String\nText=Typed\nY=2\n"] {
                typeAtEnd(part)
                let start = now()
                guard code.fireTypedText() else { return t.check(false, "\(name): the pause is waited for") }
                display()
                times.pauses.append(ms(since: start))
            }
            t.check(editor.skin === instance, "\(name): a typed layer does not load the Studio's instance at a pause")
            t.check(editor.typedCodeWaits != nil, "\(name): it waits for the commit")
            let start = now()
            t.check(code.commitNow(explicit: true), "\(name): saved")
            display()
            times.saves.append(ms(since: start))
            t.check(editor.skin !== instance && editor.skin?.meter(named: "MeterLatencyTyped") != nil,
                    "\(name): saving loads the instance, which shows the layer")
            EditorWindowSelfTests.settle()
            session.flushDesktopPatch()
            session.flushDesktopRefresh()
            editor.window?.undoManager?.undo()
            EditorWindowSelfTests.settle()
            session.flushDesktopPatch()
            session.flushDesktopRefresh()
        }
    }

    /// Typed code, `samples` times: the layer's value typed over in the code pane (after one step gives it its own), and
    /// from the end of the pause (`CodeEditorView.fireTypedText`) to the window's display pass showing it. Nothing is
    /// written meanwhile and no step is made; the commit then writes one "Edit Code" step, and both steps are undone.
    static func measureTypedCode(_ t: AppTestRunner, name: String, run: Run, target: String, samples: Int,
                                 editor: InspectorWindowController, code: CodeEditorView, display: () -> Void,
                                 times: inout [Double], phases: inout [String: [Double]]) {
        guard let session = editor.session, let skin = editor.skin else { return t.check(false, "\(name): a session") }
        let written = skin.meter(named: target)?.rawOption(run.key)
        editor.commit([.init(section: target, key: run.key, value: run.value(written, 0), own: true)], name: run.undoName)
        EditorWindowSelfTests.settle()
        session.flushDesktopPatch()
        session.flushDesktopRefresh()
        guard let file = editor.skin?.sources.location(section: target)?.file else {
            return t.check(false, "\(name): where \(target) is written")
        }
        code.show(file: editor.codeFile(for: file))
        let bytes = (try? Data(contentsOf: file)) ?? Data()
        let step = session.undoStack.undoActionName
        /// The value of the layer's own `key=` line in the code.
        func valueRange() -> NSRange? {
            guard let lines = code.lineRange(ofSection: target) else { return nil }
            let text = code.text as NSString
            let document = CodeDocument(text: code.text)
            let prefix = run.key.lowercased() + "="
            for line in lines {
                let range = document.range(ofLine: line)
                guard text.substring(with: range).lowercased().hasPrefix(prefix) else { continue }
                let length = (prefix as NSString).length
                return NSRange(location: range.location + length, length: range.length - length)
            }
            return nil
        }
        for i in 1...samples {
            let value = run.value(written, i)
            guard let range = valueRange() else { return t.check(false, "\(name): \(run.key) of \(target) in the code") }
            // What the pause autoreleased goes with it, as after an event in the app.
            let paused = autoreleasepool { () -> Bool in
                code.textView.setSelectedRange(range)
                code.textView.insertText(value, replacementRange: range)
                let start = now()
                guard code.fireTypedText() else { return false }
                display()
                times.append(ms(since: start))
                for (phase, time) in session.reloadPhases.phases { phases[phase, default: []].append(time) }
                t.equal(editor.skin?.meter(named: target)?.rawOption(run.key), value, "\(name): typed code \(i) shows")
                EditorWindowSelfTests.settle()
                return true
            }
            guard paused else { return t.check(false, "\(name): the pause is waited for") }
        }
        // Should the last value typed be the one the step wrote: one more, not timed, to have typing to commit.
        if !code.isDirty, let range = valueRange() {
            code.textView.setSelectedRange(range)
            code.textView.insertText(run.value(written, 1), replacementRange: range)
            code.fireTypedText()
        }
        t.equal((try? Data(contentsOf: file)) ?? Data(), bytes, "\(name): typed code is not written")
        t.equal(session.undoStack.undoActionName, step, "\(name): typed code makes no step")
        t.check(code.fireIdleCommit(), "\(name): the typed code is committed")
        EditorWindowSelfTests.settle()
        t.equal(session.undoStack.undoActionName, "Edit Code", "\(name): as one step")
        t.check((try? Data(contentsOf: file)) != bytes, "\(name): written")
        for _ in 0..<2 {
            editor.window?.undoManager?.undo()
            EditorWindowSelfTests.settle()
            session.flushDesktopPatch()
            session.flushDesktopRefresh()
        }
    }
}
