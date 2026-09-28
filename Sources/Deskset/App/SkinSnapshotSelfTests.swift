import AppKit
import DesksetCore

/// A skin's snapshot (docs/skin-threading.md §5.5, phase 2 step 2): the runtime publishes it after each piece of the
/// skin's work, and the window, the menus, the Manage window and the app's lookups read it instead of the skin. Every
/// app suite also compares the window's answers from the snapshot with the live skin in debug builds (`SnapshotAudit`);
/// these suites check what that cannot: that a snapshot is read without waiting for a busy skin, that only changes the
/// main thread acts on are posted, and what building snapshots costs.
enum SkinSnapshotSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: skin snapshot: a skin redrawing 60 times a second with a stable layout posts nothing") {
            let window = RecordingWindow()
            let runtime = try SkinRuntimeSelfTests.makeRuntime(t, busySkin, executor: MainSkinExecutor.shared,
                                                               window: window)
            _ = try runtime.load()
            runtime.send(.start)
            for _ in 0..<5 { runtime.send(.update(hops: 0)) }
            window.snapshotPosts = []
            let resizes = window.resizes.count
            let generation = runtime.snapshot.generation
            for _ in 0..<120 { runtime.send(.update(hops: 0)) }
            t.equal(window.snapshotPosts.count, 0, "posted: \(window.snapshotPosts.map(\.rawValue))")
            t.equal(window.resizes.count, resizes, "nor is the window asked to resize: its frames go to its content layer")
            t.check(runtime.snapshot.generation != generation, "rebuilt meanwhile (a tooltip shows a measure)")
            t.equal(runtime.snapshot.updateCount, runtime.skin.updateCount, "the snapshot follows the updates")
            t.equal(runtime.snapshot.counter, runtime.skin.counter)
            t.check(runtime.snapshot.hitMap.toolTipInfo(at: 5, 45)?.text.hasPrefix("Count ") == true)
            t.equal(runtime.snapshot.hitMap.toolTipInfo(at: 5, 45), runtime.skin.toolTipInfo(at: 5, 45),
                    "its tooltip shows the counter as it is")

            // What the main thread acts on is posted, once per piece of work.
            runtime.send(.execute("[!HideMeter MeterTip][!Redraw]", section: nil))
            t.equal(window.snapshotPosts, [.toolTips], "a tooltip area went")
            window.snapshotPosts = []
            runtime.send(.execute("[!LoadLayout Other]", section: nil))
            t.equal(window.snapshotPosts, [.issues], "a compatibility note")
            window.snapshotPosts = []
            runtime.send(.execute("[!DisableMouseAction MeterBox LeftMouseUpAction][!SetVariable A 1]", section: nil))
            t.equal(window.snapshotPosts, [], "the hit map is read when needed, not posted")
            t.equal(runtime.snapshot.hitMap.handles(.leftUp, x: 10, y: 10), true, "a disabled action still catches")
            t.equal(runtime.snapshot.hitMap.pointerCursorName(at: 10, 10), nil, "and shows the arrow")
            runtime.send(.close(fadeOut: false))
        }

        t.suite("App: skin snapshot: the main thread reads a skin on a thread without waiting for it") {
            let executor = TestThreadExecutor(name: "Skin snapshot test")
            let window = RecordingWindow()
            defer { withExtendedLifetime(window) {} }
            var runtime: SkinRuntime? = try SkinRuntimeSelfTests.makeRuntime(t, busySkin, executor: executor,
                                                                            window: window)
            defer { SkinRuntimeSelfTests.finish(t, &runtime, executor) }
            guard let r = runtime, SkinRuntimeSelfTests.load(t, r, on: executor) else { return }
            t.check(AppSelfTest.spin(timeout: 30) { r.snapshot.updateCount >= 1 }, "the first update is published")
            t.equal(r.snapshot.hitMap.hasAction(.leftUp, x: 10, y: 10), true, "from the main thread")
            t.equal(r.snapshot.toolTipAreas.count, 2)

            // The skin's thread is busy: the snapshot answers at once.
            let gate = DispatchSemaphore(value: 0)
            let parked = DispatchSemaphore(value: 0)
            executor.async {
                parked.signal()
                _ = gate.wait(timeout: .now() + 30)
            }
            _ = parked.wait(timeout: .now() + 30)
            let start = ProcessInfo.processInfo.systemUptime
            let answers = (0..<200).map { i in r.snapshot.hitMap.hasAction(.leftUp, x: Double(i % 40), y: 10) }
            let seconds = ProcessInfo.processInfo.systemUptime - start
            t.check(answers.allSatisfy { $0 }, "the box, all along")
            t.check(seconds < 5, "200 answers while the skin is busy: \(seconds) s")
            // Work queued behind the busy piece: its snapshot comes once it ran, with a post for the main thread.
            window.snapshotPosts = []
            r.send(.execute("[!HideMeter MeterBox][!HideMeter MeterTip][!Redraw]", section: nil))
            t.equal(r.snapshot.hitMap.hasAction(.leftUp, x: 10, y: 10), true, "not yet")
            gate.signal()
            t.check(AppSelfTest.spin(timeout: 30) { r.snapshot.toolTipAreas.isEmpty }, "published")
            t.check(AppSelfTest.spin(timeout: 30) { window.snapshotPosts.contains { $0.contains(.toolTips) } },
                    "the change is posted to the main thread")
            t.equal(r.snapshot.hitMap.hasAction(.leftUp, x: 10, y: 10), false, "and read there")
            t.equal(r.snapshot.toolTipAreas.count, 0)
            r.send(.close(fadeOut: false))
            _ = r.exclusive(timeout: 30) { _ in true }
        }

        t.suite("App: skin snapshot: the Manage window and the menus hear of new compatibility notes") {
            guard let app = try AppSelfTest.makeApp(t), let c = app.activate(config: "App\\Counter", file: nil)
            else { return }
            AppSelfTest.spin(timeout: 0.2) { false }
            var notified = 0
            let token = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged, object: app,
                                                               queue: nil) { _ in notified += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            c.runtime.send(.execute("[!LoadLayout Other][!LoadLayout Another]", section: nil))
            t.check(c.runtime.snapshot.issues.contains { $0.localizedCaseInsensitiveContains("LoadLayout") },
                    "\(c.runtime.snapshot.issues)")
            t.equal(notified, 0, "not in the middle of the skin's work")
            t.check(AppSelfTest.spin(timeout: 10) { notified > 0 }, "on a later turn")
            AppSelfTest.spin(timeout: 0.2) { false }
            t.equal(notified, 1, "once")
            let menu = app.skinMenu(for: c, includeCustomItems: false)
            t.check(menu.items.contains { $0.title.hasPrefix("Compatibility Notes") }, "the skin menu shows it")
            app.stopAllForTermination()
        }

        t.suite("App: skin snapshot: the debug comparison reports a difference") {
            let window = RecordingWindow()
            let runtime = try SkinRuntimeSelfTests.makeRuntime(t, busySkin, executor: MainSkinExecutor.shared,
                                                               window: window)
            _ = try runtime.load()
            #if DEBUG
            var reported: [String] = []
            let before = SnapshotAudit.differences
            SnapshotAudit.capturing({ reported.append($0) }) {
                SnapshotAudit.compare("a test", runtime, snapshot: 1, live: 2)
                SnapshotAudit.compare("a test", runtime, snapshot: 3, live: 3)
                t.equal(SnapshotAudit.check("a live answer", runtime, snapshot: 5, live: { _ in 6 }), 5,
                        "the snapshot's answer is the one used")
            }
            t.equal(reported.count, 2, "\(reported)")
            t.check(reported.first?.contains("the snapshot says 1, the skin 2") == true)
            t.equal(SnapshotAudit.differences, before, "a test's own differences are not the run's")
            #endif
            runtime.send(.close(fadeOut: false))
            t.check(!SnapshotAudit.isActive(runtime), "not for a closed skin")
        }

        t.suite("App: skin snapshot: what building snapshots costs on the busiest default skins") {
            snapshotCost(t)
        }
    }

    /// Updates 60 times a second (like a visualizer), with a stable layout: a box with a click action, a tooltip that
    /// shows a counter, a text that changes inside a fixed frame.
    static let busySkin = """
        [Rainmeter]
        Update=16

        [Variables]
        A=0

        [MeasureCount]
        Measure=Calc
        Formula=Counter

        [MeterBox]
        Meter=Shape
        Shape=Rectangle 0,0,40,40 | Fill Color 255,0,0,255
        LeftMouseUpAction=[!SetVariable A 1]
        ToolTipText=Box

        [MeterTip]
        Meter=Image
        Y=40
        W=40
        H=20
        SolidColor=0,0,0,1
        ToolTipText=Count %1
        MeasureName=MeasureCount

        [MeterText]
        Meter=String
        X=40
        W=80
        H=20
        MeasureName=MeasureCount
        Text=%1

        """

    // MARK: Cost

    /// Measures, for the busiest default skins, an update and the snapshot work that follows it, as `SkinRuntime` does
    /// it (`SkinSnapshot.next`, which builds the snapshot again only when the skin's snapshot generation moved), and a
    /// full build for comparison. Skins run off-screen (`RenderHost`), so nothing reaches a player or starts a capture;
    /// with `DESKSET_AUDIO_DEMO=1` the visualizers move. Printed, and written down in docs/skin-threading.md §15.
    static func snapshotCost(_ t: AppTestRunner) {
        guard let repository = Paths.repositoryFolder("DefaultSkins") else {
            print("    (skipped: DefaultSkins not found; run from the repository)")
            return
        }
        let root = t.temporaryDirectory("snapshot-cost")
        do {
            try FileManager.default.copyItem(at: repository.appendingPathComponent("Stationery"),
                                             to: root.appendingPathComponent("Stationery"))
        } catch {
            t.check(false, "copied the default skins: \(error)")
            return
        }
        let now = { ProcessInfo.processInfo.systemUptime }
        for (config, file) in [("Stationery\\Spectrum", "Medium.ini"), ("Stationery\\Spectrum", "Strip.ini"),
                               ("Stationery\\StudioVU", "Medium.ini"), ("Stationery\\System", "Large.ini")] {
            let url = SkinLibrary.directory(for: config, root: root).appendingPathComponent(file)
            let host = RenderHost()
            let skin = Skin(config: config, fileURL: url, skinsDirectory: root, system: SystemMonitor.shared, host: host)
            do { try skin.load() } catch {
                t.check(false, "\(config)\\\(file) loads: \(error)")
                continue
            }
            defer { skin.close() }
            var built: Int?
            var snapshot = SkinSnapshot.next(after: SkinSnapshot(), of: skin, builtGeneration: &built) ?? SkinSnapshot()
            for _ in 0..<30 {
                skin.update()
                snapshot = SkinSnapshot.next(after: snapshot, of: skin, builtGeneration: &built) ?? snapshot
            }
            let updates = 240
            var updateTime = 0.0, snapshotTime = 0.0, rebuilds = 0
            for _ in 0..<updates {
                // With the demo signal, the sound arrives between the updates, as it does on the desktop.
                if AudioCaptureEngine.demoSignal { RenderCommand.wait(milliseconds: 16) }
                let t0 = now()
                skin.update()
                let t1 = now()
                let generation = built
                if let next = SkinSnapshot.next(after: snapshot, of: skin, builtGeneration: &built) { snapshot = next }
                snapshotTime += now() - t1
                updateTime += t1 - t0
                if built != generation { rebuilds += 1 }
            }
            let fullBuilds = 60
            let t2 = now()
            for _ in 0..<fullBuilds { snapshot.rebuild(from: skin, generation: skin.snapshotGeneration) }
            let fullBuild = (now() - t2) / Double(fullBuilds)
            let update = updateTime / Double(updates)
            let perUpdate = snapshotTime / Double(updates)
            let line = String(format: "%@\\%@: update %.3f ms; snapshot after it %.4f ms (%.2f %%), rebuilt after "
                              + "%d of %d updates; a full build %.4f ms (%.2f %%); %d meters the mouse finds",
                              config, file, update * 1000, perUpdate * 1000, perUpdate / update * 100, rebuilds, updates,
                              fullBuild * 1000, fullBuild / update * 100, snapshot.hitMap.entries.count)
            print("    snapshot cost: " + line)
            t.check(update > 0 && fullBuild > 0, line)
        }
    }
}
