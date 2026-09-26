import AppKit
import DesksetCore

/// `Deskset --self-test "editor opening"`: the skin editor opens without keeping the skins waiting. Skins update and
/// draw on the main thread, so the editor's window is built in steps, a few per turn of the run loop
/// (`MainThreadSteps`, `InspectorWindowController.queueOpening`), and the main thread's steps are measured with
/// `MainThreadStallMonitor`. Built in steps or at once (headless, the default), the editor ends up the same.
enum EditorOpeningSelfTests {
    static func run(_ t: AppTestRunner) {
        // The main thread's steps are timed: from a run loop the earlier suites' skins no longer keep busy (see
        // `settle`).
        AppSelfTest.stopEarlierSkins()
        monitorTests(t)
        stepTests(t)
        openingTests(t)
        lazyPartTests(t)
    }

    typealias Editor = InspectorWindowController

    /// The longest a step of the opening should take (seconds), for an opening whose steps took `work` in all: 120 ms,
    /// or a fifth of the work on a Mac slow enough to need more. Built at once, the opening is a single step; in steps,
    /// a debug build on an M4 Pro takes some 480 ms in 50-odd steps, the longest 30-odd ms with the layout AppKit does
    /// at the end of each, and CI's Intel runner takes about three times as long. A wall-clock budget fails whenever
    /// the machine stalls for 100 ms in any step (a CI VM does, for seconds at times), so the self-test only prints it
    /// and checks what it stands for, one step of the opening per turn of the run loop.
    /// `DESKSET_EDITOR_STEP_BUDGET_MS` (profiling on a quiet Mac; CI does not set it) sets the budget, and the self-test
    /// then checks it.
    static func stepBudget(work: TimeInterval) -> TimeInterval {
        if let ms = stepBudgetSetting { return ms / 1000 }
        return max(0.12, work / 5)
    }

    /// `DESKSET_EDITOR_STEP_BUDGET_MS`, when set (a number).
    static var stepBudgetSetting: Double? {
        ProcessInfo.processInfo.environment["DESKSET_EDITOR_STEP_BUDGET_MS"].flatMap(Double.init)
    }

    static func ms(_ seconds: TimeInterval) -> String { String(format: "%.1f ms", seconds * 1000) }

    /// Runs the main run loop until it has gone 200 ms without a step of 20 ms or more, and says whether it did: what
    /// is left to do before anything is timed — closing the windows of the skins the earlier suites ran takes the
    /// run loop's next turns most of a second. A minute at most (the limit tells "slow" from "never"); when the run
    /// loop never went quiet, a note says what kept it busy, so work left over from earlier suites shows up in the
    /// timings that follow instead of being counted silently.
    @discardableResult
    static func settle() -> Bool {
        let end = Date().addingTimeInterval(60)
        var last = MainThreadStallMonitor.Steps(all: [])
        while Date() < end {
            last = MainThreadStallMonitor.shared.record { RenderCommand.wait(milliseconds: 200) }
            if (last.longest?.duration ?? 0) < 0.02 { return true }
        }
        print("    (the main run loop did not go 200 ms without a step of 20 ms or more within a minute; the last "
              + "200 ms:\n      \(describe(last, over: 0.02)))")
        return false
    }

    /// The steps at least `duration` long, with what they did, one per line (for failure messages).
    static func describe(_ steps: MainThreadStallMonitor.Steps, over duration: TimeInterval) -> String {
        steps.over(duration).map { "\(ms($0.duration)): \($0.notes.joined(separator: "; "))" }.joined(separator: "\n      ")
    }

    // MARK: The stall monitor

    static func monitorTests(_ t: AppTestRunner) {
        t.suite("App: editor opening: the main-thread stall monitor") {
            typealias Monitor = MainThreadStallMonitor
            // `defaults write app.deskset.Deskset MainThreadStallLog …`: milliseconds, YES for 50 ms, else off.
            t.equal(Monitor.threshold(from: nil), 0)
            t.equal(Monitor.threshold(from: kCFBooleanTrue), 0.05)
            t.equal(Monitor.threshold(from: kCFBooleanFalse), 0)
            t.close(Monitor.threshold(from: NSNumber(value: 30)), 0.03)
            t.close(Monitor.threshold(from: "25"), 0.025)
            t.equal(Monitor.threshold(from: "yes"), 0.05)
            t.equal(Monitor.threshold(from: "soon"), 0)
            t.equal(Monitor.threshold(from: NSNumber(value: -5)), 0)
            t.equal(Monitor.threshold(from: NSNumber(value: Double.nan)), 0)

            let monitor = Monitor.shared
            let log = monitor.log
            defer {
                monitor.setLogThreshold(0)
                monitor.log = log
            }
            var lines: [String] = []
            monitor.log = { lines.append($0) }
            settle()
            monitor.setLogThreshold(0.06)
            t.equal(lines, ["Main-thread stall log on: steps of 60 ms or more are logged"])
            t.check(monitor.isWatching)
            // A timer keeps the main thread busy for 150 ms: one step, with what it said it was doing. The run loop
            // sleeps before and after it, and sleeping is no step. (Earlier suites' skins still run, in steps of their
            // own.) Recorded until the timer has run, whenever the machine gets to fire it, and 600 ms after.
            var busyRan = false
            let busy = Timer(timeInterval: 0.05, repeats: false) { _ in
                Monitor.note("busy")
                let end = Date().addingTimeInterval(0.15)
                while Date() < end {}
                busyRan = true
            }
            RunLoop.main.add(busy, forMode: .common)
            var fired = false
            let start = DispatchTime.now().uptimeNanoseconds
            let steps = monitor.record {
                fired = AppSelfTest.spin(timeout: 60) { busyRan }
                RenderCommand.wait(milliseconds: 600)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            t.check(fired, "the busy timer fires")
            let busySteps = steps.all.filter { $0.notes.contains("busy") }
            t.equal(busySteps.count, 1, "one step: \(describe(steps, over: 0.03))")
            t.check((busySteps.first?.duration ?? 0) >= 0.15, "as long as the timer")
            t.equal(busySteps.first?.notes, ["busy"], "it says what it did")
            // Measured against the recording's own length: a machine that stalls inside a step adds as much to both,
            // and most of the 600 ms after the busy step is asleep.
            let total = steps.all.reduce(0) { $0 + $1.duration }
            t.check(elapsed - total >= 0.2, "the time asleep is left out: steps \(ms(total)) in \(ms(elapsed)): "
                    + describe(steps, over: 0.03))
            let logged = lines.compactMap { line -> Int? in
                guard line.hasPrefix("Main thread busy for "), line.hasSuffix(" ms (busy)") else { return nil }
                return Int(line.dropFirst("Main thread busy for ".count).dropLast(" ms (busy)".count))
            }
            t.check(logged.count == 1 && logged[0] >= 150, "logged: \(lines)")
            // Off again: no more watching.
            monitor.setLogThreshold(0)
            t.check(!monitor.isWatching)
            // A note is dropped when nothing watches.
            Monitor.note("unheard")
            let quiet = monitor.record {}
            t.check(quiet.all.allSatisfy { !$0.notes.contains("unheard") })
        }
    }

    // MARK: Steps

    static func stepTests(_ t: AppTestRunner) {
        t.suite("App: editor opening: work done in steps on the main thread") {
            var log: [String] = []
            let steps = MainThreadSteps(name: "Test")
            steps.add("a") {
                log.append("a")
                steps.add("a2") { log.append("a2") }
            }
            steps.add("b") { log.append("b") }
            steps.whenDone { log.append("done") }
            t.check(!steps.isDone)
            steps.start()
            t.equal(log, [], "nothing runs before the run loop turns")
            // (Waits of a minute: the turns come from 1 ms timers, which a busy machine fires late; the limit only
            // tells "late" from "never".)
            t.check(AppSelfTest.spin(timeout: 60) { steps.isDone }, "the steps run")
            t.equal(log, ["a", "a2", "b", "done"], "a step's own steps come right after it")
            t.equal(steps.turns, 3, "one step per turn")
            var later = false
            steps.whenDone { later = true }
            t.check(later, "done: at once")

            // finish() runs the rest now; from inside a step, as soon as that step returns.
            log = []
            let rushed = MainThreadSteps(name: "Test")
            rushed.add("x") {
                log.append("x")
                rushed.finish()
                log.append("x ends")
            }
            rushed.add("y") { log.append("y") }
            rushed.start()
            t.check(AppSelfTest.spin(timeout: 60) { rushed.isDone }, "the rushed steps run")
            t.equal(log, ["x", "x ends", "y"])
            t.equal(rushed.turns, 1)

            // cancel() drops the steps left and what waits for them (a window closed while it is built).
            log = []
            let dropped = MainThreadSteps(name: "Test")
            dropped.add("1") {
                log.append("1")
                dropped.cancel()
            }
            dropped.add("2") { log.append("2") }
            dropped.whenDone { log.append("done") }
            dropped.start()
            AppSelfTest.spin(timeout: 60) { !log.isEmpty }
            RenderCommand.wait(milliseconds: 50)
            t.equal(log, ["1"])
            t.check(dropped.isCancelled && dropped.isDone)
            dropped.add("3") { log.append("3") }
            dropped.finish()
            t.equal(log, ["1"], "nothing more once cancelled")

            // A budget runs quick steps together.
            var count = 0
            let quick = MainThreadSteps(name: "Test", budget: 1)
            for _ in 0..<5 { quick.add("tick") { count += 1 } }
            quick.start()
            t.check(AppSelfTest.spin(timeout: 60) { quick.isDone }, "the quick steps run")
            t.equal(count, 5)
            t.equal(quick.turns, 1)
        }
    }

    // MARK: Opening

    /// A headless app with a copy of TestSkins/Audio running (the visualizer: 26 layers, 40 updates a second).
    static func visualizerApp(_ t: AppTestRunner) throws -> (AppController, SkinController)? {
        guard let app = try AppSelfTest.makeApp(t), let skins = Paths.repositoryFolder("TestSkins") else { return nil }
        try FileManager.default.copyItem(at: skins.appendingPathComponent("Audio"),
                                         to: app.skinsDirectory.appendingPathComponent("AudioTest"))
        app.rescanLibrary()
        guard let c = app.activate(config: "AudioTest\\Visualizer", file: nil) else {
            t.check(false, "the visualizer loads")
            return nil
        }
        return (app, c)
    }

    /// Unloads the visualizer at the end of a suite: the self-tests' apps live until the process ends, and each one's
    /// 40 updates a second would slow the suites that follow.
    static func unloadVisualizer(_ apps: AppController...) {
        for app in apps { app.deactivate(config: "AudioTest\\Visualizer") }
    }

    /// Opens the editor on `c` in steps, as the app does, and runs the run loop until it is built and has made the Add
    /// library (the first of the steps that follow the opening), with every step of the main thread recorded; says
    /// whether the opening finished and whether the library was made. The window is laid out and drawn at the end of
    /// each turn, as AppKit does with a window on screen (a headless one is laid out, not always drawn).
    ///
    /// The waits are a minute: some 50 turns, each driven by a 1 ms timer and the display pass, take several seconds on
    /// a machine that fires timers late or is busy (CI); the limits only tell "late" from "never".
    static func openInSteps(_ app: AppController, _ c: SkinController, afterClick: (Editor) -> Void = { _ in })
    -> (editor: Editor?, steps: MainThreadStallMonitor.Steps, finished: Bool, libraryMade: Bool) {
        let display = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.beforeWaiting, .exit]).rawValue, true,
                                                         CFIndex(Int32.max - 1)) { _, _ in
            guard let window = app.inspector?.window else { return }
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), display, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), display, .commonModes) }
        app.opensEditorInSteps = true
        var editor: Editor?
        var finished = false
        var libraryMade = false
        let steps = MainThreadStallMonitor.shared.record {
            MainThreadStallMonitor.note("click")
            app.showInspector(for: c)
            editor = app.inspector
            guard let editor else { return }
            afterClick(editor)
            finished = AppSelfTest.spin(timeout: 60) { !editor.isOpening }
            // What follows the opening, in steps of its own: the library, which the callers check, then the font
            // menus' faces, recorded for a while (for the timings only: nothing checked depends on how far they got).
            libraryMade = finished && AppSelfTest.spin(timeout: 60) { editor.loadedLibraryView != nil }
            RenderCommand.wait(milliseconds: 300)
        }
        return (editor, steps, finished, libraryMade)
    }

    static func openingTests(_ t: AppTestRunner) {
        t.suite("App: editor opening: the skin editor opens in steps") {
            guard let (app, c) = try visualizerApp(t) else { return }
            defer { unloadVisualizer(app) }
            settle()
            var atShow: (parts: Int, rows: Int, canvasSkin: Bool)?
            var atClick: (opening: Bool, built: Int, toolbar: Bool)?
            let (opened, steps, finished, libraryMade) = openInSteps(app, c) { editor in
                atClick = (editor.isOpening, editor.inspectorRebuildCount, editor.window?.toolbar != nil)
                editor.whenReadyToShow {
                    atShow = (editor.inspectorStack.arrangedSubviews.count, editor.outline.numberOfRows,
                              editor.canvas.skinProvider() != nil && editor.canvas.frame.width > 100)
                }
            }
            guard let editor = opened else { return t.check(false, "the editor opens") }
            t.check(finished, "the opening finished")
            t.check(atClick?.opening == true && atClick?.built == 0 && atClick?.toolbar == false,
                    "the click only starts building the window: \(String(describing: atClick))")
            t.check(!editor.isOpening, "built")
            t.check(app.lastBroughtToFront === editor.window, "the window comes to the front")
            t.check(atShow?.canvasSkin == true, "it shows once the widget is on the canvas")
            t.equal(atShow?.parts, 0, "before the inspector is built")
            t.equal(atShow?.rows, 0, "and the layers")
            t.equal(editor.inspectorRebuildCount, 1, "the inspector is built once")
            t.check(editor.outline.numberOfRows == editor.listItems.count && editor.listItems.count > 10,
                    "every layer in the list")
            t.check(editor.loadedCodeView == nil, "Design: no code editor made")
            t.check(libraryMade, "the library is made after the opening")
            t.check(editor.loadedLibraryView?.isHidden == true, "hidden")
            // No step of the opening keeps the skins waiting long: it is split into many steps, each in a turn of the
            // run loop of its own (a turn ends when the run loop is about to wait or leaves, as a recorded step does).
            let opening = steps.all.filter { $0.notes.contains { $0 == "click" || $0.hasPrefix("Skin editor: ") } }
            t.check(opening.count >= 20, "the opening takes many steps: \(opening.count)")
            let crowded = steps.all.filter { $0.notes.filter { $0.hasPrefix("Skin editor: ") }.count > 1 }
            t.check(crowded.isEmpty, "one opening step per turn:\n      "
                    + describe(MainThreadStallMonitor.Steps(all: crowded), over: 0))
            // How long they took depends on the machine and its load: checked only when asked for (`stepBudget`).
            let work = opening.reduce(0) { $0 + $1.duration }
            let budget = stepBudget(work: work)
            let longest = steps.longest?.duration ?? 0
            if stepBudgetSetting != nil {
                t.check(longest <= budget, "the longest step, \(ms(longest)), within \(ms(budget)) (the opening's "
                        + "steps: \(ms(work))):\n      " + describe(steps, over: budget / 2))
            } else {
                print("    (longest step \(ms(longest)), budget \(ms(budget)), opening \(ms(work)) in \(opening.count) "
                      + "steps)")
            }
            editor.window?.close()
        }

        t.suite("App: editor opening: built in steps, the skin editor is the one built at once") {
            guard let (atOnceApp, atOnceSkin) = try visualizerApp(t), let (inStepsApp, inStepsSkin) = try visualizerApp(t)
            else { return }
            defer { unloadVisualizer(atOnceApp, inStepsApp) }
            settleScrollerStyle()
            // The capsule over the zoom control shows once the sound data has been silent for 2 seconds: one stopped
            // clock for both editors, or the one built first could get there while the other is built.
            let clock = Date()
            atOnceApp.showInspector(for: atOnceSkin)
            atOnceApp.inspector?.overlayClock = { clock }
            let (opened, _, finished, libraryMade) = openInSteps(inStepsApp, inStepsSkin) { $0.overlayClock = { clock } }
            guard let atOnce = atOnceApp.inspector, let inSteps = opened else { return t.check(false, "both open") }
            t.check(finished, "the opening finished")
            t.check(libraryMade, "the library is made once the window is built")
            // (What follows compares finished windows.)
            guard finished, libraryMade else { return }
            // (Made when first needed otherwise.)
            _ = atOnce.libraryView
            for editor in [atOnce, inSteps] { editor.window?.contentView?.layoutSubtreeIfNeeded() }
            t.equal(inSteps.window?.toolbar?.items.map(\.itemIdentifier), atOnce.window?.toolbar?.items.map(\.itemIdentifier),
                    "the toolbar")
            t.equal(inSteps.window?.frame, atOnce.window?.frame, "the window")
            t.equal(inSteps.canvas.zoom, atOnce.canvas.zoom, "the canvas zoom")
            t.equal(inSteps.listItems.map(\.display), atOnce.listItems.map(\.display), "the layers")
            func inputs(_ editor: Editor, _ app: AppController) -> String? {
                editor.lastInspectorInputs?.replacingOccurrences(of: app.skinsDirectory.path, with: "Skins")
            }
            t.equal(inputs(inSteps, inStepsApp), inputs(atOnce, atOnceApp), "what the inspector shows")
            let a = fingerprint(atOnce), b = fingerprint(inSteps)
            t.equal(b.count, a.count, "as many views")
            if let i = zip(a, b).map({ $0 != $1 }).firstIndex(of: true) {
                t.check(false, "the views differ from #\(i):\n      \(a[i])\n      \(b[i])")
            }
            // Both behave alike: select a layer.
            for editor in [atOnce, inSteps] { editor.select(section: "MeterTitle") }
            t.equal(fingerprint(inSteps), fingerprint(atOnce), "after selecting a layer")
            atOnce.window?.close()
            inSteps.window?.close()
        }

        t.suite("App: editor opening: the skin editor refreshed or closed while it opens") {
            guard let (app, c) = try visualizerApp(t) else { return }
            defer { unloadVisualizer(app) }
            app.opensEditorInSteps = true
            app.showInspector(for: c)
            guard let editor = app.inspector else { return t.check(false, "the editor opens") }
            AppSelfTest.spin(timeout: 60) { editor.isReadyToShow }
            t.check(editor.isOpening, "still being built")
            // The skin reloads (saved elsewhere): the rest is built first, then the editor follows the new skin.
            app.refresh(c)
            t.check(!editor.isOpening, "built at once")
            t.check(editor.controller === app.controller(for: "AudioTest\\Visualizer") && editor.controller !== c,
                    "on the reloaded skin")
            t.equal(editor.outline.numberOfRows, editor.listItems.count)
            t.check(!editor.inspectorStack.arrangedSubviews.isEmpty, "the inspector is there")
            let rebuilt = editor.inspectorRebuildCount
            RenderCommand.wait(milliseconds: 200)
            t.equal(editor.inspectorRebuildCount, rebuilt, "and nothing is left to build")
            editor.window?.close()

            // Closed before it is built: what is left is dropped.
            weak var closed: Editor?
            autoreleasepool {
                app.showInspector(for: app.controller(for: "AudioTest\\Visualizer") ?? c)
                closed = app.inspector
                AppSelfTest.spin(timeout: 60) { closed?.isReadyToShow == true }
                closed?.window?.close()
            }
            t.check(app.inspector == nil, "the app lets it go")
            RenderCommand.wait(milliseconds: 200)
            t.check(closed?.opening?.isCancelled ?? true, "its steps are dropped")
            t.check(AppSelfTest.spin(timeout: 60) { closed == nil }, "and it goes away")
        }

        t.suite("App: editor opening: code revealed in the skin editor once it is built") {
            guard let (app, c) = try visualizerApp(t) else { return }
            defer { unloadVisualizer(app) }
            app.opensEditorInSteps = true
            let file = c.skin.fileURL
            t.check(CodeEditorRouter.openBuiltIn(file: file, line: 30, app: app), "the built-in editor takes it")
            guard let editor = app.inspector else { return t.check(false, "the editor opens") }
            t.check(editor.isOpening && editor.mode == .design, "nothing is revealed before the window is built")
            t.check(AppSelfTest.spin(timeout: 60) { !editor.isOpening }, "built")
            t.equal(editor.mode, .split, "then the code shows")
            t.equal(editor.codeView.currentFile.map(CodeEditorRouter.comparablePath), CodeEditorRouter.comparablePath(file))
            t.equal(editor.codeView.caretLine, 30, "at the line")
            editor.window?.close()
        }
    }

    /// A headless process takes the system's scroller style (overlay or not, which the inspector's controls follow)
    /// once it first draws a window; in the app the skins' windows have long been drawn.
    static func settleScrollerStyle() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scroll.hasVerticalScroller = true
        window.contentView?.addSubview(scroll)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RenderCommand.wait(milliseconds: 50)
        window.close()
    }

    /// What the editor window shows, view by view (depth first): kind, identifier, place and size, whether hidden, the
    /// words and state of labels and controls, and the priority that keeps the inspector from widening. Left out: what
    /// hidden views hold.
    static func fingerprint(_ editor: Editor) -> [String] {
        var lines: [String] = []
        func visit(_ view: NSView, depth: Int) {
            let f = view.frame
            // (AppKit's own views name what they belong to by its address.)
            let identifier = (view.identifier?.rawValue ?? "-")
                .replacingOccurrences(of: "0x[0-9a-fA-F]+", with: "0x…", options: .regularExpression)
            var line = "\(depth) \(type(of: view)) \(identifier) "
                + String(format: "%.1f,%.1f %.1fx%.1f", f.minX, f.minY, f.width, f.height)
                + (view.isHidden ? " hidden" : "")
                + " cr\(Int(view.contentCompressionResistancePriority(for: .horizontal).rawValue))"
            if let field = view as? NSTextField { line += " “\(field.stringValue)”" }
            if let popup = view as? NSPopUpButton { line += " [\(popup.titleOfSelectedItem ?? "")]" }
            if let button = view as? NSButton, !(view is NSPopUpButton) { line += " ‹\(button.title)› \(button.state.rawValue)" }
            if let segments = view as? NSSegmentedControl { line += " seg\(segments.selectedSegment)" }
            lines.append(line)
            guard !view.isHidden else { return }
            for subview in view.subviews { visit(subview, depth: depth + 1) }
        }
        if let content = editor.window?.contentView { visit(content, depth: 0) }
        return lines
    }

    // MARK: Parts made when first needed

    static func lazyPartTests(_ t: AppTestRunner) {
        t.suite("App: editor opening: the library and the code editor are made when first needed") {
            guard let (app, c) = try visualizerApp(t) else { return }
            defer { unloadVisualizer(app) }
            app.showInspector(for: c)
            guard let editor = app.inspector, let window = editor.window else { return t.check(false, "the editor opens") }
            t.check(editor.loadedLibraryView == nil, "no library before Add is chosen")
            editor.selectSidebarTab(.library)
            t.check(editor.loadedLibraryView?.superview === editor.sidebarPane, "made in the sidebar")
            t.check(editor.loadedLibraryView?.isHidden == false, "and shown")
            editor.selectSidebarTab(.layers)
            t.check(editor.loadedLibraryView?.isHidden == true, "hidden with the list")
            t.check(editor.loadedCodeView == nil, "no code editor in Design")
            t.check(editor.flushCode() && editor.windowShouldClose(window), "nothing to commit")
            editor.setMode(.split)
            t.check(editor.loadedCodeView?.superview === editor.codePane, "made in the code pane")
            t.check(editor.codeView.scrollView.contentView.bounds.minX < 0, "laid out with the window (line numbers)")
            window.close()
        }

        t.suite("App: editor opening: the font menus name their own family before listing every one") {
            t.equal(FontFamilies.installed("helvetica neue"), "Helvetica Neue", "as the system spells it")
            t.equal(FontFamilies.installed("No Such Family Here"), nil)
            t.equal(FontFamilies.installed(""), nil)
            t.equal(FontFamilies.title("Helvetica Neue").string, "Helvetica Neue")
            t.equal((FontFamilies.title("Helvetica Neue").attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName,
                    "Helvetica Neue", "in its own face")
            let all = FontFamilies.all
            t.check(all.contains { $0.name == "Helvetica Neue" } && !all.contains { $0.name.hasPrefix(".") },
                    "every family, hidden ones left out")
            // The faces made beforehand (`prepare`, from the fonts' own index) are the menus' families, the font
            // panel's. (The menus' list is made once, when one first opens; AppKit's follows a font registered since —
            // an earlier suite's test font — a turn of the run loop later.)
            RenderCommand.wait(milliseconds: 50)
            let panel = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
            t.equal(Set(panel), Set(Fonts.installedFamilyNames), "the families the fonts are looked up in")
        }

        t.suite("App: editor opening: component thumbnails measure network speeds on their own clock") {
            guard let loaded = ComponentThumbnails.loadSkin("network") else { return t.check(false, "network loads") }
            defer { loaded.close() }
            t.equal(loaded.skin.measure(named: "MeasureNetIn")?.value, 2_400_000, "exactly, without waiting")
            t.equal(loaded.skin.measure(named: "MeasureNetOut")?.value, 310_000)
        }
    }
}
