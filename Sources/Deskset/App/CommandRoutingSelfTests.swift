import AppKit
import DesksetCore

/// Commands run through real runtimes and temporary skin trees. External editors and media keys use their
/// existing recording seams, so these suites never open an app or change the Mac's playback or volume.
enum CommandRoutingSelfTests {
    static func run(_ t: AppTestRunner) {
        MediaUIPlugins.register()
        for mode in [SkinThreading.main, .engine, .pool] {
            lifecycleTests(t, mode)
            targetTests(t, mode)
            groupTests(t, mode)
        }
        deferredTests(t)
        hopTests(t)
        mediaTests(t)
        pluginTests(t)
    }

    private static func lifecycleTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Command routing: Skin aliases keep config lifecycle and editor routing (\(mode))") {
            let oldLocator = CodeEditorRouter.locator, oldOpener = CodeEditorRouter.opener
            let locator = CodeEditorRoutingSelfTests.FakeLocator()
            let opener = CodeEditorRoutingSelfTests.RecordingOpener()
            CodeEditorRouter.locator = locator
            CodeEditorRouter.opener = opener
            t.atSuiteEnd { CodeEditorRouter.locator = oldLocator; CodeEditorRouter.opener = oldOpener }
            guard let app = try fixture(t, mode) else { return }
            let editor = CodeEditorRoutingSelfTests.fakeApp(t.temporaryDirectory("routing-editor"), "Recorder")
            locator.apps["test.routing.editor"] = editor
            app.state.updateEditor { $0.codeEditor = .app(bundleID: "test.routing.editor", lastKnownPath: editor.path) }
            try writeSkin(app, "Source")
            try writeSkin(app, "Target")
            guard let source = load(t, app, "Source") else { return }

            execute(source, "[!Skin:Load Routing\\Target Target.ini]")
            guard wait(t, "Load activates the target", { app.controller(for: "Routing\\Target")?.isStarted == true }),
                  let first = app.controller(for: "Routing\\Target") else { return }
            t.equal(first.file, "Target.ini")
            execute(source, "[!Skin:Edit Routing\\Target Target.ini]")
            guard wait(t, "Edit reaches the existing editor router", { opener.opened.count == 1 }) else { return }
            t.equal(opener.opened.first?.urls, [first.fileURL.standardizedFileURL])
            t.equal(opener.opened.first?.app, editor)
            t.equal(opener.runs.count, 0)

            execute(source, "[!Skin:Toggle Routing\\Target Target.ini]")
            guard wait(t, "Toggle unloads a loaded config", { app.controller(for: first.config) == nil && first.hasClosed })
            else { return }
            t.equal(variable(first, "Closed"), "1", "the normal close action ran")
            t.equal(app.state.skin(first.config)?.active, false, "Toggle changes activation, not visibility")
            execute(source, "[!Skin:Toggle Routing\\Target Target.ini]")
            guard wait(t, "Toggle loads an unloaded config", { app.controller(for: first.config)?.isStarted == true }),
                  let second = app.controller(for: first.config) else { return }
            t.check(second !== first, "a fresh runtime was loaded")
            t.equal(app.state.skin(second.config)?.active, true)

            execute(source, "[!Skin:Unload Routing\\Target]")
            guard wait(t, "Unload follows the normal close path", { second.hasClosed && app.controller(for: second.config) == nil })
            else { return }
            t.equal(variable(second, "Closed"), "1")
            execute(source, "[!Skin:Load Routing\\Target Target.ini]")
            guard wait(t, "the target can be loaded again", { app.controller(for: first.config)?.isStarted == true }),
                  let third = app.controller(for: first.config) else { return }
            execute(source, "[!Skin:Unload *]")
            guard wait(t, "Unload * includes the sending config", { app.sortedControllers.isEmpty && source.hasClosed && third.hasClosed })
            else { return }
            t.equal(variable(source, "Closed"), "1")
            t.equal(variable(third, "Closed"), "1")
        }
    }

    private static func targetTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Command routing: explicit Skin targets preserve literals and classic argument order (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            try writeSkin(app, "Source")
            try writeSkin(app, "Target", extra: "[Media]\nMeasure=Plugin\nPlugin=MediaKey\n")
            guard let source = load(t, app, "Source"), let target = load(t, app, "Target") else { return }
            let untouched = source.topLeftPosition
            execute(source, "[!Skin:Move Routing\\Target 137 149]"
                + "[!Skin:SetVariable Routing\\Target Formula \(literal("(1+1)"))]"
                + "[!Skin:SetVariable Routing\\Target Bracket \(literal("[MeasureProbe]"))]"
                + "[!Skin:SetOption Routing\\Target MeterText Text \(literal("(1+1)"))]"
                + "[!Skin:SetOption Routing\\Target MeterText ToolTipText \(literal("[MeasureProbe]"))]"
                + "[!Skin:SetVariable Routing\\Target Done target-first]")
            guard wait(t, "all target-first commands arrive", { variable(target, "Done", timeout: 0.25) == "target-first"
                && target.topLeftPosition == (x: 137, y: 149) }) else { return }
            t.check(source.topLeftPosition == untouched, "only the explicit config moves")
            t.equal(variable(target, "Formula"), "(1+1)")
            t.equal(variable(target, "Bracket"), "[MeasureProbe]")
            t.equal(option(target, "MeterText", "Text"), "(1+1)")
            t.equal(option(target, "MeterText", "ToolTipText"), "[MeasureProbe]")

            execute(source, "[!Move 163 181 Routing\\Target]"
                + "[!SetVariable Legacy \(literal("(2+3)")) Routing\\Target]"
                + "[!SetOption MeterText Text \(literal("[MeasureProbe]")) Routing\\Target]"
                + "[!SetVariable Done classic Routing\\Target]")
            guard wait(t, "classic target-last commands still arrive", { variable(target, "Done", timeout: 0.25) == "classic"
                && target.topLeftPosition == (x: 163, y: 181) }) else { return }
            t.equal(variable(target, "Legacy"), "(2+3)")
            t.equal(option(target, "MeterText", "Text"), "[MeasureProbe]")

            let recording = RecordingSideEffects()
            t.equal(target.runtime.exclusive(timeout: 30) { skin -> Bool in
                skin.sideEffects = recording
                return skin.measure(named: "Media") is MediaKeyMeasure
            }, true, "the app's real plugin measure was loaded")
            execute(source, "[!Skin:CommandMeasure Routing\\Target Media NextTrack]")
            guard wait(t, "an explicit config and full command payload reach the plugin", { recording.records.count == 1 })
            else { return }
            t.equal(recording.records, [.mediaKey("NextTrack")], "the target's side-effects policy is respected")
        }
    }

    private static func groupTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Command routing: skin OR and AND selectors agree with snapshots and visit members once (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            let names = ["Source", "OnlyA", "OnlyB", "Outside"]
            for (name, group) in zip(names, ["a|b", "a", "b", "c"]) { try writeSkin(app, name, group: group) }
            let loaded = names.compactMap { load(t, app, $0) }
            guard loaded.count == names.count else { return t.check(false, "all group fixtures started") }
            let source = loaded[0]
            // Also protect the existing live matcher normalization; repeated prefixes are not a Windows claim.
            for selector in ["Group=a|b", "Group=a&b", "Group=a|b&c", "a", "Group=Group=a",
                             " group=GROUP=a&b ", "Group=Group=Group=a"] {
                for c in loaded {
                    t.equal(c.runtime.snapshot.isInSkinGroup(selector),
                            c.runtime.exclusive(timeout: 30) { $0.isInSkinGroup(selector) } ?? false,
                            "snapshot/live agree for \(c.config), \(selector)")
                }
            }
            t.equal(app.controllers(forConfigArgument: "Group=a|b", current: source).map(\.config).sorted(),
                    loaded.prefix(3).map(\.config).sorted(), "the App selector returns the OR set once")
            t.equal(app.controllers(forConfigArgument: "Group=a&b", current: source).map(\.config), [source.config])

            let before = loaded.map { $0.runtime.snapshot.updateCount }
            execute(source, "[!Skin:Update Group=a|b]")
            guard wait(t, "all OR members update", { zip(loaded.prefix(3), before).allSatisfy {
                $0.0.runtime.snapshot.updateCount >= $0.1 + 1
            } }) else { return }
            drain(t, app, source)
            t.equal(zip(loaded, before).map { $0.0.runtime.snapshot.updateCount - $0.1 }, [1, 1, 1, 0],
                    "the source belongs to both groups but updates only once")
            let next = loaded.map { $0.runtime.snapshot.updateCount }
            execute(source, "[!Skin:Update Group=a&b]")
            guard wait(t, "the intersection updates", { source.runtime.snapshot.updateCount > next[0] }) else { return }
            drain(t, app, source)
            t.equal(zip(loaded, next).map { $0.0.runtime.snapshot.updateCount - $0.1 }, [1, 0, 0, 0])

            execute(source, "[!Skin:SetVariable Group=a|b Shared \(literal("(1+1)"))]"
                + "[!Skin:SetOption Group=a&b MeterText Text \(literal("[MeasureProbe]"))]"
                + "[!Skin:Move Group=a&b 201 213]")
            guard wait(t, "group values and window commands arrive", { loaded.prefix(3).allSatisfy {
                variable($0, "Shared", timeout: 0.25) == "(1+1)"
            } && source.topLeftPosition == (x: 201, y: 213) }) else { return }
            t.equal(option(source, "MeterText", "Text"), "[MeasureProbe]")
            t.equal(option(loaded[1], "MeterText", "Text"), "original")
            t.equal(variable(loaded[3], "Shared"), "initial")

            let untouched = loaded.map { $0.runtime.snapshot.updateCount }
            execute(source, "[!Skin:Update Group=a|b&c][!Skin:SetVariable Group=a|b&c Shared mixed]")
            drain(t, app, source)
            t.equal(loaded.map { $0.runtime.snapshot.updateCount }, untouched, "mixed OR/AND matches no skin")
            t.equal(loaded.map { variable($0, "Shared") }, ["(1+1)", "(1+1)", "(1+1)", "initial"])
        }
    }

    private static func deferredTests(_ t: AppTestRunner) {
        t.suite("App: Command routing: pending loads preserve literal arguments and retirement rejects late peers") {
            guard let app = try fixture(t, .pool) else { return }
            try writeSkin(app, "Source")
            try writeSkin(app, "Late", group: "a|b")
            guard let source = load(t, app, "Source") else { return }
            execute(source, "[!Skin:Load Routing\\Late Late.ini]"
                + "[!Skin:SetVariable Routing\\Late Formula \(literal("(1+1)"))]"
                + "[!Skin:SetOption Routing\\Late MeterText Text \(literal("[MeasureProbe]"))]"
                + "[!Skin:Move Routing\\Late 144 177]")
            guard wait(t, "peer commands wait behind the alias load", {
                guard let target = app.controller(for: "Routing\\Late"), target.isStarted else { return false }
                return variable(target, "Formula", timeout: 0.25) == "(1+1)"
                    && target.topLeftPosition == (x: 144, y: 177)
            }), let target = app.controller(for: "Routing\\Late") else { return }
            t.equal(option(target, "MeterText", "Text"), "[MeasureProbe]", "literal metadata survives the main forward")
            drain(t, app, source)
            let before = target.runtime.snapshot.updateCount
            app.later(loading: target.config) { _ in }
            source.apply(.forward(Bang(name: "setvariable", args: ["Formula", "queued"]),
                                  toConfig: target.config, hops: 0), from: source.runtime)
            source.retiredByLayout = true
            source.runtime.retireForLayout()
            execute(source, "[!Skin:SetVariable Routing\\Late Formula retired]"
                + "[!Skin:SetVariable Group=a|b Formula retired-group][!Skin:Update Group=a|b]"
                + "[!Skin:Move Routing\\Late 400 400]")
            drain(t, app, source)
            t.equal(variable(target, "Formula"), "(1+1)", "neither queued nor newly normalized requests escape retirement")
            t.equal(target.runtime.snapshot.updateCount, before)
            t.check(target.topLeftPosition == (x: 144, y: 177))
        }
    }

    private static func hopTests(_ t: AppTestRunner) {
        t.suite("App: Command routing: namespaced cross-worker updates retain the existing hop limit") {
            guard let app = try fixture(t, .pool) else { return }
            let names = (1...9).map { "Ring\($0)" }
            for (index, name) in names.enumerated() {
                let text = SkinWindowModelSelfTests.pingSkin("Routing\\\(names[(index + 1) % names.count])")
                    .replacingOccurrences(of: "[!Update ", with: "[!Skin:Update ")
                try writeSkin(app, name, text: text)
            }
            let ring = names.compactMap { load(t, app, $0) }
            guard ring.count == names.count else { return t.check(false, "the ring started") }
            t.check(ring.contains { $0.runtime.executor !== ring[0].runtime.executor }, "the chain crosses workers")
            for c in ring {
                t.equal(c.runtime.exclusive(timeout: 30) { skin -> Bool in
                    skin.executeInput("[!SetVariable Armed 1]", from: nil)
                    return skin.variable("Armed") == "1"
                }, true)
            }
            let before = ring.map { $0.runtime.snapshot.updateCount }
            ring[0].runtime.send(.update(hops: 0))
            guard wait(t, "the normalized chain stops at the existing hop bound", {
                ring[7].runtime.exclusive(timeout: 0.25) { _ in ring[7].runtime.droppedHops } == 1
            }) else { return }
            t.equal(zip(ring, before).map { $0.0.runtime.snapshot.updateCount - $0.1 }, [2, 2, 2, 2, 2, 2, 2, 2, 1])
            t.equal(ring.map { c in c.runtime.exclusive(timeout: 30) { _ in c.runtime.hopLimitLogs } ?? -1 },
                    [0, 0, 0, 0, 0, 0, 0, 1, 0])
        }
    }

    private static func mediaTests(_ t: AppTestRunner) {
        t.suite("App: Command routing: SendKey uses the existing media sender and respects recording on every executor") {
            let oldSink = MediaKeyMeasure.sink, oldPermission = MediaKeyMeasure.canPostEvents
            let sent = Guarded<[String]>([]), probes = Guarded(0), trusted = Guarded(false)
            MediaKeyMeasure.sink = { key, viaHID in sent.access { $0.append("\(key.rawValue):\(viaHID)") } }
            MediaKeyMeasure.canPostEvents = { probes.access { $0 += 1 }; return trusted.current }
            t.atSuiteEnd { MediaKeyMeasure.sink = oldSink; MediaKeyMeasure.canPostEvents = oldPermission }
            let names = ["MediaNextTrack", "MediaPrevTrack", "MediaStop", "MediaPlayPause", "VolumeMute", "VolumeDown", "VolumeUp"]
            let keys: [MediaKeyCommand] = [.nextTrack, .prevTrack, .stop, .playPause, .volumeMute, .volumeDown, .volumeUp]
            let invalid = "[!SendKey][!SendKey NextTrack][!SendKey A][!SendKey \"Ctrl+C\"][!SendKey VolumeUp extra]"
            for mode in [SkinThreading.main, .engine, .pool] {
                guard let app = try fixture(t, mode) else { return }
                try writeSkin(app, "Keys")
                guard let source = load(t, app, "Keys") else { return }
                for permitted in [false, true] {
                    trusted.access { $0 = permitted }
                    sent.access { $0 = [] }; probes.access { $0 = 0 }
                    execute(source, names.map { "[!SendKey \($0.uppercased())]" }.joined() + invalid)
                    drain(t, app, source)
                    t.equal(sent.current, keys.map { "\($0.rawValue):\(permitted && $0 != .stop)" },
                            "\(mode), trusted=\(permitted): seven keys only; Stop is never a HID play/pause")
                    t.equal(probes.current, 7, "invalid commands do not probe or send")
                }
                let recording = RecordingSideEffects()
                _ = source.runtime.exclusive(timeout: 30) { $0.sideEffects = recording }
                sent.access { $0 = [] }; probes.access { $0 = 0 }
                execute(source, names.map { "[!SendKey \($0)]" }.joined() + invalid)
                drain(t, app, source)
                t.equal(recording.records, keys.map { .mediaKey($0.manualName) }, "record canonical media commands")
                t.equal(sent.current, [], "recording sends no event and changes no player or volume")
                t.equal(probes.current, 0, "recording does not even ask for Accessibility state")
            }
        }
    }

    private static func pluginTests(_ t: AppTestRunner) {
        t.suite("App: Command routing: explicit plugin namespace commands use the loaded plugin and recording policy") {
            let oldCenter = NowPlayingCenter.current
            let backend = DemoNowPlayingBackend()
            backend.artworkEnabled = false
            let center = NowPlayingCenter(backend: backend)
            center.interval = 3600
            NowPlayingCenter.current = center
            t.atSuiteEnd { NowPlayingCenter.current = oldCenter }
            let (skin, host) = try MediaUITests.bareSkin(t, """
                [Rainmeter]
                Update=-1
                [Now]
                Measure=Plugin
                Plugin=NowPlaying
                PlayerType=Title
                """)
            t.atSuiteEnd { skin.close(); withExtendedLifetime(host) {} }
            t.check(skin.measure(named: "Now") is NowPlayingMeasure, "the app plugin is registered")
            let recording = RecordingSideEffects()
            skin.sideEffects = recording
            skin.executeInput("[!NowPlaying:PlayPause Now][!NowPlaying:SetVolume Now 25]", from: nil)
            t.equal(recording.records, [.media(plugin: "NowPlaying", command: "PlayPause"),
                                        .media(plugin: "NowPlaying", command: "SetVolume 25")])
            t.equal(backend.performed.count, 0, "the real plugin's command path respects recording")
        }
    }

    // MARK: Fixtures

    private static func fixture(_ t: AppTestRunner, _ mode: SkinThreading) throws -> AppController? {
        guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return nil }
        t.atSuiteEnd {
            let threads = (app.engineThread.map { [$0] } ?? []) + (app.skinThreadPool?.activeWorkers ?? [])
            app.stopAllForTermination()
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { threads.allSatisfy(\.hasExited) }, "fixture executors stopped")
        }
        return app
    }

    private static func writeSkin(_ app: AppController, _ name: String, group: String = "",
                                  extra: String = "", text: String? = nil) throws {
        let folder = app.skinsDirectory.appendingPathComponent("Routing/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (text ?? """
            [Rainmeter]
            Update=-1
            Group=\(group)
            OnCloseAction=[!SetVariable Closed 1]
            [Variables]
            Closed=0
            Shared=initial
            [MeasureProbe]
            Measure=Calc
            Formula=42
            [MeterText]
            Meter=String
            Text=original
            W=80
            H=24

            """ + extra).write(to: folder.appendingPathComponent("\(name).ini"), atomically: true, encoding: .utf8)
        app.state.update("Routing\\\(name)") { $0.file = "\(name).ini"; $0.keepOnScreen = false }
        app.rescanLibrary()
    }

    private static func load(_ t: AppTestRunner, _ app: AppController, _ name: String) -> SkinWindowController? {
        guard let c = app.activate(config: "Routing\\\(name)", file: "\(name).ini") else {
            t.check(false, "fixture \(name) activates")
            return nil
        }
        guard wait(t, "fixture \(name) starts", { c.isStarted }) else { return nil }
        return c
    }

    private static func execute(_ c: SkinWindowController, _ action: String) {
        c.runtime.send(.execute(action, section: nil))
    }

    private static func variable(_ c: SkinWindowController, _ name: String, timeout: TimeInterval = 30) -> String? {
        c.runtime.exclusive(timeout: timeout) { $0.variable(name) } ?? nil
    }

    private static func option(_ c: SkinWindowController, _ section: String, _ key: String) -> String? {
        c.runtime.exclusive(timeout: 30) { $0.section(named: section)?.rawOption(key) } ?? nil
    }

    private static func literal(_ text: String) -> String { "\"\"\"" + text + "\"\"\"" }

    private static func wait(_ t: AppTestRunner, _ message: String, _ condition: () -> Bool) -> Bool {
        let completed = AppSelfTest.spin(timeout: 30, until: condition)
        t.check(completed, message)
        return completed
    }

    /// The sender has finished enqueuing requests before the main queue and then each receiver are drained.
    private static func drain(_ t: AppTestRunner, _ app: AppController, _ source: SkinWindowController) {
        t.equal(source.runtime.exclusive(timeout: 30) { _ in true }, true, "sender finished")
        t.check(ServiceThreadingSelfTests.drainMainQueue(), "main requests drained")
        var turnFinished = false
        app.later { _ in turnFinished = true }
        _ = wait(t, "deferred app actions drained", { turnFinished })
        for c in app.sortedControllers {
            t.equal(c.runtime.exclusive(timeout: 30) { _ in true }, true, "receiver finished: \(c.config)")
        }
    }
}
