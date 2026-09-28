import AppKit
import DesksetCore

/// "App: studio2 latency": the new Studio's steps timed on five widgets — a text size changed through the editing
/// session until the canvas has drawn it and the inspector shows it, and its undo — printed as p50 / p95 with the
/// session's phases. Only a sanity bound is checked; `DESKSET_STUDIO2_LATENCY_BUDGET_MS` makes the p95 a budget (a CI
/// virtual machine can stall for a second, so there is none by default). `DESKSET_STUDIO2_LATENCY_SAMPLES` sets the
/// number of samples of each kind (default 12).
enum Studio2LatencySelfTests {
    /// The widgets measured: the designed screens' (Stationery's System and Weather, the Nocturne Rainmeter skin, the
    /// CPU card) and Stationery's Clock.
    static let references = ["03-customize", "03b-weather", "13b-compat", "09-every-setting", "clock"]

    static func run(_ t: AppTestRunner) {
        t.suite("App: studio2 latency") {
            Studio2SelfTests.prepare(t)
            // Earlier suites' widgets would keep updating on the main thread and make the numbers noisy.
            AppSelfTest.stopEarlierSkins()
            let environment = ProcessInfo.processInfo.environment
            let samples = environment["DESKSET_STUDIO2_LATENCY_SAMPLES"].flatMap(Int.init).map { min(max($0, 2), 500) } ?? 12
            let budget = environment["DESKSET_STUDIO2_LATENCY_BUDGET_MS"].flatMap(Double.init)
            var load = [0.0, 0.0, 0.0]
            _ = getloadavg(&load, 3)
            print(String(format: "    load average %.2f %.2f %.2f; %d samples of each kind%@", load[0], load[1], load[2],
                         samples, budget.map { String(format: "; budget %.0f ms (p95)", $0) } ?? ""))
            for name in references {
                measure(t, name, samples: samples, budget: budget)
            }
        }
    }

    static func screen(_ name: String) -> StudioScreen? {
        if name == "clock" {
            return StudioScreen(name: "latency-clock", fixture: .init(source: "DefaultSkins", root: "Stationery",
                                                                    config: "Stationery\\Clock", file: "Medium.ini"),
                                zoom: 1.5)
        }
        guard var s = StudioScreen.named(name) else { return nil }
        s.selection = nil
        s.everySetting = false
        s.colorPopover = nil
        s.previewPopover = false
        s.hoverSwatch = nil
        return s
    }

    typealias Stat = StudioLatencySelfTests.Stat

    static func measure(_ t: AppTestRunner, _ name: String, samples: Int, budget: Double?) {
        guard let screen = screen(name), let opened = StudioSnapshot.open(screen) else {
            return t.check(false, "\(name) opens")
        }
        defer { opened.close() }
        let studio = opened.controller, app = opened.app
        app.defersDesktopUpdates = true
        defer { app.defersDesktopUpdates = false }
        guard let session = studio.session, let skin = studio.skin,
              let target = skin.meters.first(where: { $0 is StringMeter && !$0.hidden })?.name else {
            return t.check(false, "\(name): a text to change")
        }
        let files = [skin.fileURL] + skin.includedFiles
        let original = files.map { (try? Data(contentsOf: $0)) ?? Data() }
        let canvas = studio.canvasController.canvas
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return t.check(false, "canvas") }
        func frame() {
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            studio.widgetPage.refresh()
        }
        frame()
        let written = skin.meter(named: target)?.rawOption("FontSize").flatMap { OptionValue.number($0) } ?? 12
        let base = Int(written.isFinite ? min(max(written, 1), 400) : 12)
        var edits: [Double] = [], undos: [Double] = []
        var phases: [String: [Double]] = [:], undoPhases: [String: [Double]] = [:]
        for i in 0..<samples {
            guard let live = studio.skin else { break }
            let value = String(base + 1 + i % 2)
            let ops = WriteScopes.ops(.element, meter: target, key: "FontSize", value: value, in: live)
            let start = StudioLatencySelfTests.now()
            _ = try? session.apply(StudioText[.undoTextSize], ops)
            frame()
            edits.append(StudioLatencySelfTests.ms(since: start))
            EditorWindowSelfTests.settle()
            session.flushDesktopRefresh()
            for (phase, time) in session.lastTimings { phases[phase, default: []].append(time) }
        }
        t.equal(studio.skin?.meter(named: target)?.rawOption("FontSize"), String(base + 1 + (samples - 1) % 2),
                "\(name): the edits reached the Studio's instance")
        for _ in 0..<samples {
            let start = StudioLatencySelfTests.now()
            session.undoStack.undo()
            frame()
            undos.append(StudioLatencySelfTests.ms(since: start))
            EditorWindowSelfTests.settle()
            session.flushDesktopRefresh()
            for (phase, time) in session.lastTimings { undoPhases[phase, default: []].append(time) }
        }
        t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(name): every edit undone, byte for byte")
        t.check(app.controller(for: screen.fixture.config) != nil, "\(name) still runs on the desktop")
        let edit = Stat(samples: edits), undo = Stat(samples: undos)
        func breakdown(_ phases: [String: [Double]]) -> String {
            ["plan", "apply", "write", "studio", "desktop"].compactMap { phase in
                phases[phase].map { String(format: "%@ %.1f", phase, Stat(samples: $0).p50) }
            }.joined(separator: ", ")
        }
        let config = screen.fixture.config
        print("    LATENCY2 \(config) | edit → canvas and page | \(edit.text) | p50 by phase (ms): \(breakdown(phases))")
        print("    LATENCY2 \(config) | undo → canvas and page | \(undo.text) | p50 by phase (ms): \(breakdown(undoPhases))")
        // A sanity bound only: a step that takes seconds is broken, whatever the machine.
        t.check(edit.p95 < 5_000 && undo.p95 < 5_000, "\(name): \(edit.text); undo \(undo.text)")
        if let budget {
            t.check(edit.p95 <= budget, "\(name): edit p95 \(edit.p95) ms over the budget of \(budget) ms")
            t.check(undo.p95 <= budget, "\(name): undo p95 \(undo.p95) ms over the budget of \(budget) ms")
        }
    }
}
