import AppKit
import DesksetCore

/// "App: studio latency": how long a property edit takes to reach the canvas, and an undo, on five reference widgets —
/// printed as p50 / p95 so every change of the editing pipeline can be measured against the same numbers. Only a
/// generous sanity bound is checked; `DESKSET_STUDIO_LATENCY_BUDGET_MS` makes the p95 a budget (a CI virtual machine can
/// stall for a whole second, so it is not one by default).
///
/// One sample is one step the way a user makes it: the edit (`commit`: the text in memory, the file, the Studio's
/// instance loaded again, the desktop copy reloaded, the inspector following) and then a frame of the canvas drawn
/// off-screen, each in its own turn of the run loop (the undo manager groups what one event registers).
/// `DESKSET_STUDIO_LATENCY_SAMPLES` sets the number of samples of each kind (default 12).
enum StudioLatencySelfTests {
    /// The reference widgets: config and the repository folder it comes from.
    static let references: [(config: String, folder: String)] = [
        ("Deskset\\Clock", "DefaultSkins"), ("Deskset\\System", "DefaultSkins"), ("Deskset\\Calendar", "DefaultSkins"),
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
                try measure(t, config: reference.config, folder: reference.folder, samples: samples, budget: budget)
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

    static func measure(_ t: AppTestRunner, config: String, folder: String, samples: Int, budget: Double?) throws {
        guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: config, from: folder) else { return }
        defer { editor.window?.close() }
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
            for (phase, time) in session.lastTimings { phases[phase, default: []].append(time) }
            EditorWindowSelfTests.settle()
        }
        t.equal(editor.skin?.meter(named: target)?.rawOption("FontSize"), String(base + 1 + (samples - 1) % 2),
                "\(config): the edits reached the Studio's instance")
        var undoPhases: [String: [Double]] = [:]
        for _ in 0..<samples {
            let start = now()
            editor.window?.undoManager?.undo()
            frame()
            undos.append(ms(since: start))
            for (phase, time) in session.lastTimings { undoPhases[phase, default: []].append(time) }
            EditorWindowSelfTests.settle()
        }
        t.equal(files.map { (try? Data(contentsOf: $0)) ?? Data() }, original, "\(config): every edit undone, byte for byte")
        t.check(app.controller(for: config) != nil, "\(config) still runs")

        let edit = Stat(samples: edits), undo = Stat(samples: undos)
        func breakdown(_ phases: [String: [Double]]) -> String {
            ["plan", "apply", "write", "studio", "desktop"].compactMap { phase in
                phases[phase].map { String(format: "%@ %.1f", phase, Stat(samples: $0).p50) }
            }.joined(separator: ", ")
        }
        print("    LATENCY \(config) | edit → canvas | \(edit.text) | p50 by phase (ms): \(breakdown(phases))")
        print("    LATENCY \(config) | undo → canvas | \(undo.text) | p50 by phase (ms): \(breakdown(undoPhases))")
        // A sanity bound only: a step that takes seconds is broken, whatever the machine.
        t.check(edit.p95 < 5_000 && undo.p95 < 5_000, "\(config): \(edit.text); undo \(undo.text)")
        if let budget {
            t.check(edit.p95 <= budget, "\(config): edit p95 \(edit.p95) ms over the budget of \(budget) ms")
            t.check(undo.p95 <= budget, "\(config): undo p95 \(undo.p95) ms over the budget of \(budget) ms")
        }
    }
}
