import AppKit
import DesksetCore

/// Regression tests for defects found by the adversarial review of the media / UI plugins (part of
/// `Deskset --self-test MediaUI`). Like `MediaUITests`: no Apple Events, no permission prompts, no window on screen.
enum MediaUIReviewTests {
    static func run(_ t: AppTestRunner) {
        inputTextFrameTests(t)
        permissionTests(t)
        macPermissionTests(t)
        commandWithoutPollTests(t)
        playerNameTests(t)
        wifiScanTests(t)
        chameleonTests(t)
        inputTextOverrideTests(t)
    }

    // MARK: InputText: hostile X / Y

    static func inputTextFrameTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI review: InputText box frame") {
            // AppKit raises an uncaught NSInternalInconsistencyException (the app quits) for a window frame outside
            // the 32-bit range; a skin formula can easily produce one.
            let skinFrame = CGRect(x: 100, y: 500, width: 300, height: 200)
            let limit = CGFloat(Int32.max) / 2
            for (x, y) in [(1e300, -1e300), (-3e9, 3e9), (5e9, 7), (12, -1e12)] {
                var s = InputTextSettings()
                s.x = x
                s.y = y
                let frame = InputTextPanelPrompt.frame(s, skinFrame: skinFrame, skinWidth: 300, lineHeight: 16)
                t.check(abs(frame.minX) < limit && abs(frame.minY) < limit && abs(frame.maxX) < limit
                        && abs(frame.maxY) < limit, "X=\(x) Y=\(y) → \(frame) stays inside AppKit's range")
                t.check(frame.width >= 4 && frame.height >= 4 && frame.width <= 8192)
                // Creating (never showing) the panel is what used to raise.
                let panel = InputTextPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: true)
                t.check(!panel.isVisible)
                panel.close()
            }
            var normal = InputTextSettings()
            normal.x = 5
            normal.y = 20
            normal.width = 240
            normal.height = 25
            t.equal(InputTextPanelPrompt.frame(normal, skinFrame: skinFrame, skinWidth: 300, lineHeight: 18),
                    CGRect(x: 105, y: 655, width: 240, height: 25), "ordinary values unchanged")
            var noWidth = InputTextSettings()
            noWidth.x = 1e300
            let w = InputTextPanelPrompt.frame(noWidth, skinFrame: skinFrame, skinWidth: .nan, lineHeight: 16).width
            t.equal(w, 40, "a missing W with a hostile X or skin width falls back to the minimum")
        }
    }

    // MARK: Automation permission

    static func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let d = NSAppleEventDescriptor.list()
        for (i, item) in items.enumerated() { d.insert(item, at: i + 1) }
        return d
    }

    static func permissionTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI review: Automation permission") {
            let statusReply = list([.init(int32: 1), .init(int32: 1), .init(int32: 55), .init(int32: 0), .init(int32: 1),
                                    .init(double: 12.5), .init(string: "PID1"), .init(int32: 80)])
            var trackItems = NowPlayingScripts.trackTextFields.map { NSAppleEventDescriptor(string: "text \($0)") }
            trackItems += NowPlayingScripts.trackNumberFields.map { _ in NSAppleEventDescriptor(int32: 7) }
            let trackReply = list(trackItems)
            func backend(check: OSStatus, scriptError: Int = 0) -> (AppleScriptNowPlayingBackend, () -> [String]) {
                let b = AppleScriptNowPlayingBackend()
                var sent: [String] = []
                b.permissionCheck = { _ in check }
                b.scriptRunner = { source in
                    sent.append(source)
                    if scriptError != 0 { return (nil, scriptError) }
                    return (source.contains("persistent ID") ? statusReply : trackReply, 0)
                }
                return (b, { sent })
            }

            // Not decided and the wildcard check did not ask: the script is sent (its Apple Event asks the user).
            let (undecided, sentUndecided) = backend(check: OSStatus(AppleScriptNowPlayingBackend.wouldRequireConsent))
            if case .ok(let s) = undecided.status(.music) {
                t.equal(s.trackID, "PID1")
                t.equal(s.volume, 55)
            } else {
                t.check(false, "errAEEventWouldRequireUserConsent from the check is not a refusal")
            }
            t.equal(sentUndecided().count, 1, "the status script was sent")
            t.equal(undecided.track(.music)?.title, "text title", "metadata is read once a script got through")
            t.check(undecided.perform(.playPause, on: .music), "commands are sent too")

            // Refused: nothing is sent.
            let (refused, sentRefused) = backend(check: OSStatus(AppleScriptNowPlayingBackend.notPermitted))
            t.equal(refused.status(.music), .denied)
            t.check(!refused.perform(.next, on: .music))
            t.equal(sentRefused().count, 0, "no Apple Event after a refusal")

            // Refused when the script's own event asked: denied, and no metadata reads afterwards.
            let (answeredNo, _) = backend(check: OSStatus(AppleScriptNowPlayingBackend.wouldRequireConsent),
                                          scriptError: AppleScriptNowPlayingBackend.notPermitted)
            t.equal(answeredNo.status(.music), .denied)
            t.check(answeredNo.track(.music) == nil)

            // Player quit between the running check and the permission check.
            let (gone, sentGone) = backend(check: OSStatus(procNotFound))
            t.equal(gone.status(.spotify), .notRunning)
            t.equal(sentGone().count, 0)
        }
    }

    // MARK: PlayerType=MacPermission

    /// A player whose Automation permission the test decides: `answer` is what the status poll gets, `peeked` what the
    /// check without a prompt says.
    final class PermissionBackend: NowPlayingBackend {
        var running: Set<MediaApp> = [.music]
        var peeked: [MediaApp: NowPlayingPermission] = [:]
        var answers: [MediaApp: NowPlayingPoll] = [:]
        private(set) var peeks = 0
        func isRunning(_ app: MediaApp) -> Bool { running.contains(app) }
        func status(_ app: MediaApp) -> NowPlayingPoll {
            guard running.contains(app) else { return .notRunning }
            return answers[app] ?? .ok(NowPlayingStatus())
        }
        func track(_ app: MediaApp) -> NowPlayingTrack? { NowPlayingTrack(title: "Song \(app.displayName)", duration: 100) }
        func artwork(_ app: MediaApp, track: NowPlayingTrack) -> NowPlayingArtwork? { nil }
        func perform(_ command: MediaPlayerCommand, on app: MediaApp) -> Bool { false }
        func permission(_ app: MediaApp) -> NowPlayingPermission? {
            peeks += 1
            return running.contains(app) ? peeked[app] : nil
        }
    }

    static func macPermissionTests(_ t: AppTestRunner) {
        t.suite("App: NowPlaying MacPermission: the rule") {
            func value(_ preferred: MediaApp, shown: NowPlayingSnapshot, running: Set<MediaApp>,
                       _ permissions: [MediaApp: NowPlayingPermission]) -> String {
                let v = NowPlayingValues.permission(preferred: preferred, shown: shown, running: running,
                                                    permissions: permissions)
                return "\(Int(v.number)) \(v.string)"
            }
            let closedMusic = NowPlayingSnapshot(app: .music), closedSpotify = NowPlayingSnapshot(app: .spotify)
            t.equal(value(.music, shown: closedMusic, running: [], [:]), "0 Music", "nothing runs: the preferred player")
            t.equal(value(.spotify, shown: closedSpotify, running: [], [:]), "0 Spotify")
            t.equal(value(.music, shown: closedMusic, running: [.music], [.music: .refused]), "1 Music")
            t.equal(value(.music, shown: closedMusic, running: [], [.music: .refused]), "0 Music",
                    "a refused player that is closed hides nothing")
            t.equal(value(.music, shown: MediaUITests.playing(.spotify), running: [.music, .spotify],
                          [.music: .refused, .spotify: .allowed]), "0 Spotify",
                    "another player's track shows: the refusal hides nothing")
            var pausedNoTrack = NowPlayingSnapshot(app: .spotify)
            pausedNoTrack.running = true
            pausedNoTrack.status.state = 2
            t.equal(value(.music, shown: pausedNoTrack, running: [.music, .spotify], [.music: .refused]), "1 Music",
                    "a player without a track does not hide the refusal")
            t.equal(value(.music, shown: closedMusic, running: [.music, .spotify],
                          [.music: .notDetermined, .spotify: .refused]), "1 Spotify", "a refusal before an undecided one")
            t.equal(value(.spotify, shown: closedSpotify, running: [.music, .spotify],
                          [.music: .refused, .spotify: .refused]), "1 Spotify", "the preferred player first")
            t.equal(value(.music, shown: closedMusic, running: [.music], [.music: .notDetermined]), "2 Music")
            t.equal(value(.music, shown: closedMusic, running: [.music], [.music: .allowed]), "0 Music")
            t.equal(NowPlayingField.nowPlaying(" macPERMISSION "), .macPermission)
            t.equal(NowPlayingField.webNowPlaying("MacPermission"), .macPermission)
            t.equal(NowPlayingField.nowPlaying("Permission"), nil, "only the Mac-prefixed name")
            t.equal(NowPlayingField.macPermission.maxValue(closedMusic), 2)
        }

        t.suite("App: NowPlaying MacPermission: read without asking") {
            let b = AppleScriptNowPlayingBackend()
            var peekAnswer = OSStatus(0)
            var peeks = 0
            var asks = 0
            b.permissionPeek = { _ in
                peeks += 1
                return peekAnswer
            }
            b.permissionCheck = { _ in
                asks += 1
                return 0
            }
            b.scriptRunner = { _ in (nil, -1708) }
            let cases: [(OSStatus, NowPlayingPermission?)] = [
                (0, .allowed), (OSStatus(AppleScriptNowPlayingBackend.notPermitted), .refused),
                (OSStatus(AppleScriptNowPlayingBackend.wouldRequireConsent), .notDetermined),
                (OSStatus(procNotFound), nil), (-50, nil),
            ]
            for (answer, expected) in cases {
                peekAnswer = answer
                t.equal(b.permission(.music), expected, "\(answer)")
            }
            t.equal(asks, 0, "reading the permission never uses the check that may ask")
            // Once a check allowed it, the answer is known without another check.
            _ = b.status(.music)
            let before = peeks
            t.equal(b.permission(.music), .allowed)
            t.equal(peeks, before)
            t.equal(DemoNowPlayingBackend().permission(.music), .allowed)
            t.equal(DemoNowPlayingBackend().permission(.spotify), nil, "not running")
        }

        t.suite("App: NowPlaying MacPermission: the center and the measure") {
            let backend = PermissionBackend()
            backend.running = []
            let center = NowPlayingCenter(backend: backend)
            center.forceLive = true
            center.interval = 3600
            var now: TimeInterval = 1000
            center.clock = { now }
            center.log = { _ in }
            let (skin, _) = try MediaUITests.bareSkin(t)
            func measure(_ name: String, _ options: [(String, String)]) -> NowPlayingMeasure {
                let m = NowPlayingMeasure(name: name, section: MediaUITests.section(name, [("Measure", "NowPlaying")]
                                                                                      + options),
                                          skin: skin, type: "nowplaying")
                m.center = center
                m.readOptions()
                return m
            }
            func read(_ m: NowPlayingMeasure) -> String { "\(Int(m.computeValue())) \(m.currentRawString ?? "nil")" }
            MediaUITests.inline([center.worker]) {
                // (made here, so their subscriptions' first poll runs inline too)
                let access = measure("Access", [("PlayerName", "Music"), ("PlayerType", "MacPermission")])
                let spotifyAccess = measure("SpotifyAccess", [("PlayerName", "Spotify"), ("PlayerType", "MacPermission")])
                t.equal(read(access), "0 Music", "before the first poll")
                t.equal(access.automaticMaxValue, 2)

                // Music opens and has not been asked: macOS's prompt is up while the status poll waits for it.
                backend.running = [.music]
                backend.peeked[.music] = .notDetermined
                backend.answers[.music] = .failed("waiting for the prompt")
                center.poll()
                t.equal(center.permission(.music), .notDetermined)
                t.equal(read(access), "2 Music")
                t.equal(read(spotifyAccess), "2 Music", "a Spotify widget is told Music keeps it from showing anything")

                // Refused.
                backend.peeked[.music] = .refused
                backend.answers[.music] = .denied
                center.poll()
                t.equal(read(access), "1 Music")
                t.check(center.isDenied(.music))
                t.equal(center.snapshot(preferring: .music).running, false, "the refused player looks closed")

                // Spotify plays meanwhile: its track shows, so nothing is hidden.
                backend.running = [.music, .spotify]
                backend.answers[.spotify] = .ok(NowPlayingStatus(state: 1, trackID: "S1"))
                now += 1
                center.poll()
                t.equal(read(access), "0 Spotify")
                backend.answers[.spotify] = .ok(NowPlayingStatus(state: 0, trackID: ""))
                now += 1
                center.poll()
                t.equal(read(access), "1 Music", "Spotify stopped: Music's refusal shows again")

                // Music quits: nothing to read, not playing is true.
                backend.running = [.spotify]
                now += 1
                center.poll()
                t.equal(read(access), "0 Spotify", "the running Spotify is what the measure shows")
                t.equal(center.permission(.music), .refused, "known, for when it opens again")

                // Allowed later in System Settings: the re-check (every 30 s) reads it without asking.
                backend.running = [.music]
                backend.peeked[.music] = .allowed
                backend.answers[.music] = .ok(NowPlayingStatus(state: 2, trackID: ""))
                now += 31
                _ = center.snapshot(preferring: .music)   // the first read after a quiet spell polls
                t.equal(read(access), "0 Music")
                t.equal(center.permission(.music), .allowed)
                t.check(!center.isDenied(.music))
                let peeks = backend.peeks
                now += 1
                center.poll()
                t.equal(backend.peeks, peeks, "an allowed player is not checked again")
            }

            // The demo's refused Music (DESKSET_NOWPLAYING_DEMO=refused, for previews).
            let demo = DemoNowPlayingBackend()
            demo.permissions[.music] = .refused
            let demoCenter = NowPlayingCenter(backend: demo)
            demoCenter.forceLive = true
            demoCenter.interval = 3600
            demoCenter.log = { _ in }
            MediaUITests.inline([demoCenter.worker]) {
                let subscription = demoCenter.subscribe(live: true)
                demoCenter.poll()
                let v = demoCenter.permissionValue(preferring: .music)
                t.equal("\(Int(v.number)) \(v.string)", "1 Music")
                t.equal(demoCenter.snapshot(preferring: .music).hasTrack, false)
                withExtendedLifetime(subscription) {}
            }
        }
    }

    // MARK: Commands when the center has not polled (MediaKey)

    static func commandWithoutPollTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI review: commands without a poll") {
            // MediaKey measures send track keys through the center without subscribing, so the center may never have
            // polled: the players' running state must be checked when the command comes.
            let backend = DemoNowPlayingBackend()
            backend.running = [.spotify]
            let center = NowPlayingCenter(backend: backend)
            center.forceLive = true
            center.interval = 3600
            center.clock = { 50 }
            MediaUITests.inline([center.worker]) {
                t.check(!center.isPolling, "nothing subscribed: no polling")
                center.perform(.next, preferring: nil, live: false)
                t.equal(backend.performed.count, 1, "Next reaches the running player")
                t.equal(backend.performed.last?.1, .spotify)
                center.perform(.playPause, preferring: nil, live: false)
                t.equal(backend.performed.last?.0, .playPause)
                t.equal(backend.performed.last?.1, .spotify)
                // Never polled: a relative value or a toggle would start from an unknown state and is dropped;
                // absolute values are fine.
                let sent = backend.performed.count
                center.perform(.setVolume(10, relative: true), preferring: nil, live: false)
                center.perform(.setShuffle(-1), preferring: nil, live: false)
                center.perform(.cycleRepeat, preferring: nil, live: false)
                t.equal(backend.performed.count, sent, "no SetVolume +10 → 10 % on an unpolled player")
                center.perform(.setVolume(30, relative: false), preferring: nil, live: false)
                t.equal(backend.performed.last?.0, .setVolume(30))
                t.check(NowPlayingRequest.setVolume(5, relative: true).dependsOnPlayerState)
                t.check(!NowPlayingRequest.setRepeat(1).dependsOnPlayerState)
                t.check(NowPlayingRequest.setRepeat(-1).dependsOnPlayerState)

                // Nothing runs: nothing is sent (and nothing is launched).
                backend.running = []
                let count = backend.performed.count
                center.perform(.playPause, preferring: nil, live: false)
                t.equal(backend.performed.count, count, "no command without a running player")

                // A player launched since the last poll is commanded right away.
                let subscription = center.subscribe(live: false)
                t.check(!center.snapshot(preferring: .music).running, "polled while Music was closed")
                backend.running = [.music]
                center.perform(.play, preferring: .music, live: false)
                t.equal(backend.performed.last?.0, .play)
                t.equal(backend.performed.last?.1, .music, "Music launched after the poll gets the command")
                withExtendedLifetime(subscription) {}
            }
        }
    }

    // MARK: PlayerName with the nested variable form

    static func playerNameTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI review: PlayerName forms") {
            let (skin, _) = try MediaUITests.bareSkin(t, """
            [Rainmeter]
            Update=1000
            [Variables]
            Player=Spotify
            Main=MeasurePlayer
            """)
            let center = NowPlayingCenter(backend: DemoNowPlayingBackend())
            center.interval = 3600
            func measure(_ name: String, _ playerName: String) -> NowPlayingMeasure {
                let m = NowPlayingMeasure(name: name, section: MediaUITests.section(name, [
                    ("Measure", "NowPlaying"), ("PlayerName", playerName), ("PlayerType", "Title"),
                ]), skin: skin, type: "nowplaying")
                m.center = center
                m.readOptions()
                return m
            }
            t.equal(measure("A", "#Player#").preferredApp, .spotify, "#Var#")
            let nested = measure("B", "[#Player]")
            t.equal(nested.preferredApp, .spotify, "nested variable form [#Var]")
            t.check(nested.parentName == nil, "[#Player] is a variable, not a measure name")
            t.equal(measure("C", "[MeasurePlayer]").parentName, "MeasurePlayer", "[MainMeasure]")
            t.equal(measure("D", "[#Main]").parentName, nil, "[#Main] is the variable's text (MeasurePlayer), a player name")
            t.equal(measure("E", "[[#Main]]").parentName, "MeasurePlayer", "[[#Main]]: a measure named by a variable")
        }
    }

    // MARK: WiFiStatus LIST: no active scan every 30 s

    static func wifiScanTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI review: WiFi scans") {
            let now: TimeInterval = 10_000
            t.check(WiFiCenter.needsActiveScan(cachedCount: 5, lastScan: nil, now: now), "first time: scan once")
            t.check(!WiFiCenter.needsActiveScan(cachedCount: 5, lastScan: now - 30, now: now),
                    "the system's cached results are used between scans")
            t.check(!WiFiCenter.needsActiveScan(cachedCount: 5, lastScan: now - 299, now: now))
            t.check(WiFiCenter.needsActiveScan(cachedCount: 5, lastScan: now - 300, now: now), "every 5 minutes")
            t.check(!WiFiCenter.needsActiveScan(cachedCount: 0, lastScan: now - 30, now: now),
                    "an empty cache does not force a scan every 30 s")
            t.check(WiFiCenter.needsActiveScan(cachedCount: 0, lastScan: now - 60, now: now), "…but once a minute")
        }
    }

    // MARK: Chameleon: file system off the main thread

    static func chameleonTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI review: Chameleon files") {
            let folder = t.temporaryDirectory("chameleon-review")
            func writeImage(_ name: String, red: CGFloat) throws -> URL {
                let url = folder.appendingPathComponent(name)
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return url }
                ctx.cgContext.setFillColor(CGColor(red: red, green: 0.1, blue: 1 - red, alpha: 1))
                ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                return url
            }
            let walls = folder.appendingPathComponent("Walls", isDirectory: true)
            try FileManager.default.createDirectory(at: walls, withIntermediateDirectories: true)
            let b = try writeImage("Walls/b.png", red: 0)
            _ = try writeImage("Walls/a.png", red: 1)
            try Data("not an image".utf8).write(to: walls.appendingPathComponent("0-readme.txt"))
            t.equal(URL(fileURLWithPath: ChameleonMeasure.wallpaperFile(walls.path)).lastPathComponent, "a.png",
                    "a wallpaper folder → its first image")
            t.equal(ChameleonMeasure.wallpaperFile(b.path), b.path)
            t.equal(ChameleonMeasure.wallpaperFile(""), "")
            let missing = folder.appendingPathComponent("nope.png").path
            t.equal(ChameleonMeasure.wallpaperFile(missing), missing)

            // Type=File: the path is the string right away; the colors follow when the file changes.
            let (skin, _) = try MediaUITests.bareSkin(t, "[Rainmeter]\nUpdate=1000\n[Variables]\nImage=\(b.path)\n")
            let parent = ChameleonMeasure(name: "Cham", section: MediaUITests.section("Cham", [
                ("Type", "File"), ("Path", "#Image#"),
            ]), skin: skin, type: "chameleon")
            parent.readOptions()
            _ = parent.computeValue()
            t.equal(parent.pluginString, b.path, "the parent's string is the image path at once")
            AppSelfTest.spin(timeout: 5) { parent.palette != nil }
            t.check(parent.palette.map { $0.background1.b > 200 } == true, "sampled off the main thread")

            t.equal(parent.palette.map { parent.format($0.background1).count }, 6, "colors as RRGGBB")

            // A missing file: fallback colors, no crash.
            let gone = ChameleonMeasure(name: "Gone", section: MediaUITests.section("Gone", [
                ("Type", "File"), ("Path", missing), ("FallbackBG1", "123456"),
            ]), skin: skin, type: "chameleon")
            gone.readOptions()
            _ = gone.computeValue()
            AppSelfTest.spin(timeout: 2) { false }
            _ = gone.computeValue()
            t.check(gone.palette == nil)
            t.equal(gone.effectivePalette.background1, ChameleonColor(hex: "123456"))
        }
    }
}

extension MediaUIReviewTests {
    // MARK: InputText: overrides with spaced formulas

    static func inputTextOverrideTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI review: InputText overrides") {
            // A formula with spaces used to split into several tokens: the override was lost and its text stayed in
            // the action, where it would run as a file / web address to open.
            let c = InputTextCommand.parse("[!SetVariable V \"$UserInput$\"] X=(#W# - 10) Y=5")
            t.equal(c.action, "[!SetVariable V \"$UserInput$\"]")
            t.equal(c.overrides, ["x": "(#W# - 10)", "y": "5"])
            let nested = InputTextCommand.parse("!SetVariable V \"$UserInput$\" W=((#A# + 2) * 3) H=(20)")
            t.equal(nested.action, "!SetVariable V \"$UserInput$\"")
            t.equal(nested.overrides, ["w": "((#A# + 2) * 3)", "h": "(20)"])
            // A parenthesised bang argument stays in the bang.
            let argument = InputTextCommand.parse("!SetVariable Sum (1 + 2)")
            t.equal(argument.action, "!SetVariable Sum (1 + 2)")
            t.equal(argument.overrides, [:])
            // Unbalanced text never loops or crashes.
            let broken = InputTextCommand.parse("[!Log \"$UserInput$\"] X=(5 Y=\"a")
            t.check(!broken.action.isEmpty)
            let closing = InputTextCommand.parse(")) ]] X=1")
            t.equal(closing.overrides, ["x": "1"])
        }
    }
}
