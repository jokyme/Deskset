import AppKit
import CoreWLAN
import DesksetCore

/// `Deskset --self-test MediaUI`: the media / UI plugins. Nothing here sends Apple Events, asks for a permission,
/// shows a window or touches the system volume: players are faked, scripts are only compiled.
enum MediaUITests {
    static func run(_ t: AppTestRunner) {
        MediaUIPlugins.register()
        registrationTests(t)
        nowPlayingValueTests(t)
        nowPlayingCommandTests(t)
        appleScriptTests(t)
        selectionTests(t)
        centerTests(t)
        coverRetryTests(t)
        coverLookupTests(t)
        nowPlayingMeasureTests(t)
        nowPlayingLiveStringTests(t)
        inputTextModelTests(t)
        inputTextMeasureTests(t)
        wifiTests(t)
        frostedGlassTests(t)
        chameleonTests(t)
        desktopInfoTests(t)
        testSkinTests(t)
        wiredSkinTests(t)
        MediaUIReviewTests.run(t)
    }

    // MARK: Helpers

    /// A skin (not loaded) to construct measures on.
    static func bareSkin(_ t: AppTestRunner, _ text: String = "[Rainmeter]\nUpdate=1000\n") throws -> (Skin, RenderHost) {
        let dir = t.temporaryDirectory("mediaui").appendingPathComponent("Test", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Test.ini")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let host = RenderHost()
        let skin = Skin(config: "Test", fileURL: file, skinsDirectory: dir.deletingLastPathComponent(),
                        system: SystemMonitor.shared, host: host)
        try skin.load()
        return (skin, host)
    }

    static func section(_ name: String, _ options: [(String, String)]) -> IniSection {
        IniSection(name: name, entries: options.map { IniEntry(key: $0.0, value: $0.1) })
    }

    /// Runs `body` with background work and main-thread hops made synchronous.
    static func inline(_ workers: [MediaUIWorker], _ body: () throws -> Void) rethrows {
        let saved = MediaUIMainHop.runsInline
        MediaUIMainHop.runsInline = true
        for w in workers { w.runsInline = true }
        defer {
            MediaUIMainHop.runsInline = saved
            for w in workers { w.runsInline = false }
        }
        try body()
    }

    static func playing(_ app: MediaApp = .music, state: Int = 1, position: Double = 30, duration: Double = 200,
                        id: String = "T1") -> NowPlayingSnapshot {
        var s = NowPlayingSnapshot(app: app)
        s.running = true
        s.status = NowPlayingStatus(state: state, volume: 40, shuffle: true, repeatMode: .one, position: position,
                                    trackID: id, rating: 60)
        s.track = NowPlayingTrack(title: "Song", artist: "Band", album: "Record", genre: "Jazz", lyrics: "la la",
                                  file: "/Music/song.m4a", number: 4, year: 1999, duration: duration,
                                  artworkURL: "https://example.com/a.jpg")
        s.coverPath = "/tmp/cover.jpg"
        s.polledAt = 100
        return s
    }

    // MARK: Registration

    static func registrationTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI registration") {
            for name in MediaUIPlugins.pluginNames {
                t.check(MeasureRegistry.plugin(named: name) != nil, "plugin \(name) registered")
            }
            for name in MediaUIPlugins.measureNames {
                t.check(MeasureRegistry.measure(named: name) != nil, "measure \(name) registered")
            }
            t.check(MeasureRegistry.plugin(named: "Plugins\\NowPlaying.dll") == NowPlayingMeasure.self)
            t.check(MeasureRegistry.plugin(named: "iTunesPlugin.dll") == ITunesMeasure.self)
            t.check(MeasureRegistry.measure(named: "WiFiStatus") == WiFiStatusMeasure.self)
            t.check(MeasureRegistry.plugin(named: "inputtext") == InputTextMeasure.self)
            t.check(MeasureRegistry.plugin(named: "FrostedGlass") == FrostedGlassMeasure.self)
            MediaUIPlugins.register()   // a second call changes nothing
            t.check(MeasureRegistry.plugin(named: "SysColor") == SysColorMeasure.self)
        }
    }

    // MARK: NowPlaying values

    static func nowPlayingValueTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI NowPlaying values") {
            t.equal(NowPlayingValues.clock(0), "00:00")
            t.equal(NowPlayingValues.clock(65.9), "01:05")
            t.equal(NowPlayingValues.clock(65, leadingZero: false), "1:05")
            t.equal(NowPlayingValues.clock(3725), "1:02:05")
            t.equal(NowPlayingValues.clock(-5), "00:00")
            t.equal(NowPlayingValues.clock(.nan), "00:00")
            t.equal(NowPlayingValues.clock(.infinity), "00:00")
            t.equal(NowPlayingValues.clock(1e12), "99999:59:59")

            let s = playing()
            func v(_ f: NowPlayingField, now: TimeInterval = 100) -> (Double, String?) {
                let r = NowPlayingValues.value(f, s, now: now)
                return (r.number, r.string)
            }
            t.equal(v(.title).1, "Song")
            t.equal(v(.artist).1, "Band")
            t.equal(v(.album).1, "Record")
            t.equal(v(.genre).1, "Jazz")
            t.equal(v(.lyrics).1, "la la")
            t.equal(v(.file).1, "/Music/song.m4a")
            t.equal(v(.cover).1, "/tmp/cover.jpg")
            t.equal(v(.number).0, 4)
            t.check(v(.number).1 == nil, "Number is a number-only type")
            t.equal(v(.year).0, 1999)
            t.equal(v(.duration).0, 200)
            t.equal(v(.duration).1, "03:20")
            t.equal(v(.position).0, 30)
            t.equal(v(.position).1, "00:30")
            // Interpolated while playing: 2.5 s after the poll.
            t.close(v(.position, now: 102.5).0, 32.5)
            t.close(v(.progress, now: 102.5).0, 16.25)
            t.equal(v(.rating).0, 3)
            t.equal(v(.ratingPercent).0, 60)
            t.equal(v(.repeatState).0, 1)
            t.equal(v(.repeatMode3).0, 1, "WebNowPlaying: repeat one = 1")
            t.equal(v(.shuffle).0, 1)
            t.equal(v(.state).0, 1)
            t.equal(v(.status).0, 1)
            t.equal(v(.volume).0, 40)
            t.equal(v(.player).1, "Music")
            t.equal(v(.remaining).1, "02:50")
            t.equal(v(.trackTime).1, "3:20")
            t.equal(v(.coverWebAddress).1, "https://example.com/a.jpg")
            t.equal(v(.supportsSetRating).0, 1)
            t.equal(v(.ratingSystem).0, 3)

            // Paused: no interpolation; never past the end.
            var paused = playing(state: 2, position: 199)
            t.close(NowPlayingValues.value(.position, paused, now: 150).number, 199)
            paused.status.state = 1
            t.close(NowPlayingValues.value(.position, paused, now: 150).number, 200, "clamped to the duration")

            // Closed player: empty strings, zeros, "00:00".
            let closed = NowPlayingSnapshot(app: .spotify)
            t.equal(NowPlayingValues.value(.title, closed, now: 0).string, "")
            t.equal(NowPlayingValues.value(.cover, closed, now: 0).string, "")
            t.equal(NowPlayingValues.value(.status, closed, now: 0).number, 0)
            t.equal(NowPlayingValues.value(.duration, closed, now: 0).string, "00:00")
            t.equal(NowPlayingValues.value(.duration, closed, now: 0, leadingZero: false).string, "0:00")
            t.equal(NowPlayingValues.value(.player, closed, now: 0).string, "")
            // Running without a track: status 1, state from the player, no title.
            var idle = NowPlayingSnapshot(app: .music)
            idle.running = true
            idle.track = NowPlayingTrack(title: "stale")
            t.equal(NowPlayingValues.value(.status, idle, now: 0).number, 1)
            t.equal(NowPlayingValues.value(.title, idle, now: 0).string, "", "no track id: no stale title")

            // Types.
            t.equal(NowPlayingField.nowPlaying("TITLE"), .title)
            t.equal(NowPlayingField.nowPlaying(" coverpath "), .cover)
            t.equal(NowPlayingField.nowPlaying("Repeat"), .repeatState)
            t.check(NowPlayingField.nowPlaying("Bogus") == nil)
            t.equal(NowPlayingField.webNowPlaying("Repeat"), .repeatMode3)
            t.equal(NowPlayingField.webNowPlaying("SupportsToggleShuffleActive"), .supportsToggleShuffle)
            t.equal(NowPlayingField.webNowPlaying("Artist"), .artist)
            t.equal(NowPlayingField.iTunes("GetCurrentTrackName"), .title)
            t.equal(NowPlayingField.iTunes("GetPlayerPositionPercent"), .progress)
            t.equal(NowPlayingField.iTunes("getcurrenttrackartwork"), .cover)
            t.check(NowPlayingField.iTunes("PlayPause") == nil)
            t.check(NowPlayingField.progress.isNumeric && !NowPlayingField.title.isNumeric)
            t.equal(NowPlayingField.progress.maxValue(s), 100)
            t.equal(NowPlayingField.rating.maxValue(s), 5)
            t.equal(NowPlayingField.position.maxValue(s), 200)
            t.equal(NowPlayingField.position.maxValue(closed), 1)

            // Player names.
            t.equal(NowPlayingPlayerNames.preference(for: "Spotify").app, .spotify)
            t.equal(NowPlayingPlayerNames.preference(for: "WMP").app, .music)
            t.check(NowPlayingPlayerNames.preference(for: "AIMP").known)
            t.check(!NowPlayingPlayerNames.preference(for: "VLC").known)
            t.equal(NowPlayingPlayerNames.referencedMeasure("[MeasurePlayer]"), "MeasurePlayer")
            t.equal(NowPlayingPlayerNames.referencedMeasure(" [ Main ] "), "Main")
            t.check(NowPlayingPlayerNames.referencedMeasure("iTunes") == nil)
            t.check(NowPlayingPlayerNames.referencedMeasure("[]") == nil)
            t.equal(s.trackKey, "music:T1")
            t.check(closed.trackKey == nil)
        }
    }

    // MARK: Commands

    static func nowPlayingCommandTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI NowPlaying commands") {
            t.equal(NowPlayingRequest.nowPlaying("PlayPause"), .playPause)
            t.equal(NowPlayingRequest.nowPlaying(" next "), .next)
            t.equal(NowPlayingRequest.nowPlaying("SetPosition 50"), .setPosition(50, relative: false))
            t.equal(NowPlayingRequest.nowPlaying("SetPosition +5"), .setPosition(5, relative: true))
            t.equal(NowPlayingRequest.nowPlaying("SetPosition -10"), .setPosition(-10, relative: true))
            t.equal(NowPlayingRequest.nowPlaying("SetVolume (10*2)"), .setVolume(20, relative: false))
            t.equal(NowPlayingRequest.nowPlaying("SetRating 9"), .setRating(5))
            t.equal(NowPlayingRequest.nowPlaying("SetShuffle -1"), .setShuffle(-1))
            t.equal(NowPlayingRequest.nowPlaying("SetRepeat 1"), .setRepeat(1))
            t.equal(NowPlayingRequest.nowPlaying("OpenPlayer"), .openPlayer)
            t.check(NowPlayingRequest.nowPlaying("SetVolume") == nil, "missing argument")
            t.check(NowPlayingRequest.nowPlaying("Explode") == nil)
            t.equal(NowPlayingRequest.iTunes("NextTrack"), .next)
            t.equal(NowPlayingRequest.iTunes("SoundVolumeUp"), .setVolume(5, relative: true))
            t.equal(NowPlayingRequest.iTunes("Power"), .togglePlayer)
            t.equal(NowPlayingRequest.iTunes("ToggleiTunes"), .showHidePlayer)
            t.equal(NowPlayingRequest.iTunes("Backtrack"), .backTrack)
            t.check(NowPlayingRequest.iTunes("Next") == nil, "iTunes names only")
            t.equal(NowPlayingRequest.webNowPlaying("Repeat"), .cycleRepeat)
            t.equal(NowPlayingRequest.webNowPlaying("ToggleThumbsUp"), .thumbsUp)
            t.equal(NowPlayingRequest.webNowPlaying("SetVolume -40"), .setVolume(-40, relative: true))

            let s = playing()   // position 30 of 200 (15 %), volume 40, shuffle on, repeat one, rating 60
            func r(_ q: NowPlayingRequest) -> MediaPlayerCommand? { MediaPlayerCommand.resolve(q, s, now: 100) }
            t.equal(r(.setPosition(50, relative: false)), .setPosition(100))
            t.equal(r(.setPosition(5, relative: true)), .setPosition(40))
            t.equal(r(.setPosition(-50, relative: true)), .setPosition(0))
            t.equal(r(.setVolume(20, relative: true)), .setVolume(60))
            t.equal(r(.setVolume(-80, relative: true)), .setVolume(0))
            t.equal(r(.setVolume(150, relative: false)), .setVolume(100))
            t.equal(r(.setRating(4)), .setRating(80))
            t.equal(r(.setShuffle(-1)), .setShuffle(false))
            t.equal(r(.setShuffle(1)), .setShuffle(true))
            t.equal(r(.setRepeat(-1)), .setRepeat(.off))
            t.equal(r(.setRepeat(1)), .setRepeat(.all))
            t.equal(r(.cycleRepeat), .setRepeat(.off), "one → off")
            t.equal(r(.thumbsUp), .setRating(100))
            t.equal(r(.thumbsDown), .setRating(20))
            t.equal(r(.closePlayer), .quit)
            t.equal(r(.togglePlayer), .toggleOpen)
            t.check(MediaPlayerCommand.resolve(.setPosition(50, relative: false), NowPlayingSnapshot(app: .music), now: 0) == nil,
                    "no position without a track")

            t.equal(MediaKeyCommand(argument: "NextTrack"), .nextTrack)
            t.equal(MediaKeyCommand(argument: " volumemute "), .volumeMute)
            t.check(MediaKeyCommand(argument: "Eject") == nil)
            t.equal(MediaKeys.keyType(.playPause), 16)
            t.equal(MediaKeys.keyType(.volumeUp), 0)
        }
    }

    // MARK: AppleScript

    static func appleScriptTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI AppleScript building") {
            for app in MediaApp.allCases {
                for source in [NowPlayingScripts.status(app), NowPlayingScripts.track(app)] {
                    t.check(source.hasPrefix("if application id \"\(app.bundleIdentifier)\" is not running then return"),
                            "\(app) scripts never launch the player")
                    t.check(source.contains("with timeout of 4 seconds"), "\(app) scripts time out")
                }
            }
            t.check(NowPlayingScripts.status(.music).contains("persistent ID of vTrack"))
            t.check(NowPlayingScripts.status(.spotify).contains("id of current track"))
            t.check(NowPlayingScripts.track(.music).contains("properties of current track"))
            t.check(NowPlayingScripts.track(.spotify).contains("(duration of vTrack) / 1000"))
            t.check(NowPlayingScripts.artwork(.music)?.contains("raw data of artwork 1 of current track") == true)
            t.check(NowPlayingScripts.artwork(.spotify) == nil)

            func body(_ c: MediaPlayerCommand, _ app: MediaApp) -> String? {
                guard let s = NowPlayingScripts.command(c, app) else { return nil }
                let lines = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                return lines.first { !$0.hasPrefix("if ") && !$0.hasPrefix("tell") && !$0.hasPrefix("with") }
            }
            t.equal(body(.playPause, .music), "playpause")
            t.equal(body(.stop, .music), "stop")
            t.equal(body(.stop, .spotify), "pause")
            t.equal(body(.backTrack, .music), "back track")
            t.equal(body(.backTrack, .spotify), "previous track")
            t.equal(body(.setPosition(12.5), .music), "set player position to 12.500")
            t.equal(body(.setPosition(60), .spotify), "set player position to 60")
            t.equal(body(.setVolume(150), .music), "set sound volume to 100")
            t.equal(body(.setRating(80), .music), "set rating of current track to 80")
            t.check(body(.setRating(80), .spotify) == nil, "Spotify has no ratings")
            t.equal(body(.setShuffle(true), .music), "set shuffle enabled to true")
            t.equal(body(.setShuffle(false), .spotify), "set shuffling to false")
            t.equal(body(.setRepeat(.one), .music), "set song repeat to one")
            t.equal(body(.setRepeat(.all), .spotify), "set repeating to true")
            t.equal(body(.fastForward, .spotify), "set player position to (player position + 10)")
            t.check(NowPlayingScripts.command(.open, .music) == nil)
            t.check(NowPlayingScripts.command(.quit, .spotify) == nil)
            t.equal(NowPlayingScripts.literal(1e20), "1000000000")
            t.equal(NowPlayingScripts.literal(.nan), "0")
            t.equal(NowPlayingScripts.literal(-3.25), "-3.250")

            // Replies.
            t.equal(NowPlayingScripts.parseStatus([.number(0)]), .notRunning)
            t.equal(NowPlayingScripts.parseStatus([]), .malformed)
            t.equal(NowPlayingScripts.parseStatus([.number(1), .number(2)]), .malformed)
            let reply: [AppleScriptValue] = [.number(1), .number(2), .number(55), .number(1), .number(2), .number(12.5),
                                        .text("ABC"), .number(80)]
            t.equal(NowPlayingScripts.parseStatus(reply),
                    .status(NowPlayingStatus(state: 2, volume: 55, shuffle: true, repeatMode: .one, position: 12.5,
                                             trackID: "ABC", rating: 80)))
            let weird: [AppleScriptValue] = [.number(1), .number(9), .number(500), .missing, .number(7), .number(-3),
                                        .number(42), .data(Data([1]))]
            if case .status(let s) = NowPlayingScripts.parseStatus(weird) {
                t.equal(s.state, 0)
                t.equal(s.volume, 100)
                t.equal(s.repeatMode, .off)
                t.equal(s.position, 0)
                t.equal(s.trackID, "42", "a numeric id becomes text")
            } else {
                t.check(false, "clamped status")
            }
            t.check(NowPlayingScripts.parseTrack([]) == nil)
            var items: [AppleScriptValue] = NowPlayingScripts.trackTextFields.enumerated().map { .text("t\($0.offset)") }
            items += NowPlayingScripts.trackNumberFields.enumerated().map { .number(Double($0.offset + 1)) }
            let track = NowPlayingScripts.parseTrack(items)
            t.equal(track?.title, "t0")
            t.equal(track?.file, "t10")
            t.equal(track?.artworkURL, "t11")
            t.equal(track?.number, 1)
            t.equal(track?.duration, 8)

            // Descriptor conversion.
            let list = NSAppleEventDescriptor.list()
            list.insert(NSAppleEventDescriptor(int32: 7), at: 1)
            list.insert(NSAppleEventDescriptor(string: "hi"), at: 2)
            list.insert(NSAppleEventDescriptor(boolean: true), at: 3)
            list.insert(NSAppleEventDescriptor(double: 2.5), at: 4)
            t.equal(AppleScriptNowPlayingBackend.values(list), [.number(7), .text("hi"), .number(1), .number(2.5)])
            t.equal(AppleScriptNowPlayingBackend.values(NSAppleEventDescriptor(string: "x")), [.text("x")])
        }

        t.suite("App: MediaUI AppleScript compiles") {
            // Scripts run on the worker thread (a script that targets no application: no permission involved).
            let worker = MediaUIWorker(name: "Deskset test scripts")
            var values: [AppleScriptValue]?
            var ranOnMain = true
            worker.async {
                ranOnMain = Thread.isMainThread
                var error: NSDictionary?
                let script = NSAppleScript(source: "return {1, \"a\", 2.5, true, missing value}")
                let result = script?.executeAndReturnError(&error)
                let converted = result.map(AppleScriptNowPlayingBackend.values)
                DispatchQueue.main.async { values = converted ?? [] }
            }
            AppSelfTest.spin(timeout: 10) { values != nil }
            t.check(!ranOnMain, "scripts run off the main thread")
            t.equal(values ?? [], [.number(1), .text("a"), .number(2.5), .number(1), .missing])
            // Compiling reads Music's scripting dictionary from its bundle; nothing is sent to the app.
            var sources = [NowPlayingScripts.status(.music), NowPlayingScripts.track(.music)]
            sources += [NowPlayingScripts.artwork(.music)].compactMap { $0 }
            let commands: [MediaPlayerCommand] = [.play, .pause, .playPause, .stop, .next, .previous, .backTrack,
                                             .fastForward, .rewind, .resume, .setPosition(10.5), .setVolume(20),
                                             .setRating(40), .setShuffle(true), .setRepeat(.all), .setRepeat(.one),
                                             .setRepeat(.off)]
            sources += commands.compactMap { NowPlayingScripts.command($0, .music) }
            let spotifyInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
            if spotifyInstalled {
                sources += [NowPlayingScripts.status(.spotify), NowPlayingScripts.track(.spotify)]
                sources += commands.compactMap { NowPlayingScripts.command($0, .spotify) }
            } else {
                print("    (Spotify not installed: its scripts are not compiled)")
            }
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil else {
                print("    (skipped: Music.app not found)")
                return
            }
            for source in sources {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let ok = script?.compileAndReturnError(&error) ?? false
                t.check(ok, "compiles: \(error?[NSAppleScript.errorMessage] ?? "") in\n\(source)")
            }
        }
    }

    // MARK: Selection

    static func selectionTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI whichever is playing") {
            let music = { (state: Int) in playing(.music, state: state, id: "M") }
            let spotify = { (state: Int) in playing(.spotify, state: state, id: "S") }
            let closedMusic = NowPlayingSnapshot(app: .music), closedSpotify = NowPlayingSnapshot(app: .spotify)
            func choose(_ preferred: MediaApp, _ last: MediaApp?, _ snaps: [NowPlayingSnapshot]) -> MediaApp {
                NowPlayingCenter.choose(preferred: preferred, last: last, snapshots: snaps)
            }
            t.equal(choose(.music, nil, [music(1), spotify(1)]), .music, "preferred and playing")
            t.equal(choose(.music, nil, [music(2), spotify(1)]), .spotify, "the other one plays")
            t.equal(choose(.spotify, nil, [music(1), closedSpotify]), .music)
            t.equal(choose(.music, .spotify, [music(2), spotify(2)]), .spotify, "last shown still paused")
            t.equal(choose(.music, nil, [music(2), spotify(2)]), .music, "both paused: preferred")
            t.equal(choose(.music, nil, [music(0), spotify(2)]), .spotify, "stopped vs paused")
            t.equal(choose(.music, nil, [music(0), spotify(0)]), .music, "both stopped: preferred")
            t.equal(choose(.music, nil, [closedMusic, spotify(0)]), .spotify, "only the other one runs")
            t.equal(choose(.spotify, nil, [closedMusic, closedSpotify]), .spotify, "nothing runs: preferred")
        }
    }

    // MARK: Center

    static func centerTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI NowPlaying center") {
            let backend = DemoNowPlayingBackend()
            let center = NowPlayingCenter(backend: backend)
            center.forceLive = true
            center.interval = 3600
            var now: TimeInterval = 1000
            center.clock = { now }
            var logs: [String] = []
            center.log = { logs.append($0) }
            let folder = t.temporaryDirectory("covers")
            let savedRoot = MediaUICache.root
            MediaUICache.root = folder
            defer { MediaUICache.root = savedRoot }

            inline([center.worker]) {
                var subscription: NowPlayingSubscription? = center.subscribe(live: false, wantsCover: true)
                t.check(center.isPolling, "polling while subscribed")
                let snap = center.snapshot(preferring: .music)
                t.check(snap.running)
                t.equal(snap.status.trackID, "DEMO1")
                t.equal(snap.track?.title, "Rain on Glass")
                t.check(snap.coverPath.hasPrefix(folder.path), "cover written to the cache: \(snap.coverPath)")
                t.check(snap.coverPath.hasSuffix(".png"))
                t.check(FileManager.default.fileExists(atPath: snap.coverPath))

                // Track change: new metadata and a new cover file; the old one is deleted.
                let oldCover = snap.coverPath
                backend.statuses[.music]?.trackID = "DEMO2"
                backend.tracks[.music]?.title = "Second"
                backend.artworkData = DemoNowPlayingBackend.demoCover()
                now += 1
                center.poll()
                let second = center.snapshot(preferring: .music)
                t.equal(second.track?.title, "Second")
                t.check(second.coverPath != oldCover && !FileManager.default.fileExists(atPath: oldCover),
                        "previous cover removed")
                let polls = backend.statusPolls
                center.poll()
                t.equal(backend.statusPolls, polls + 1, "one status poll per round for the running player")

                // Commands go to the player shown.
                center.perform(.playPause, preferring: .spotify, live: false)
                t.equal(backend.performed.last?.0, .playPause)
                t.equal(backend.performed.last?.1, .music, "Spotify is closed: Music is shown and commanded")
                center.perform(.setVolume(10, relative: true), preferring: .music, live: false)
                t.equal(backend.performed.last?.0, .setVolume(80))
                var control: [(MediaPlayerCommand, MediaApp)] = []
                center.appControl = { control.append(($0, $1)) }
                center.perform(.openPlayer, preferring: .spotify, live: false)
                t.equal(control.last?.0, .open)
                // A closed player is not sent playback commands.
                backend.running = []
                center.poll()
                let count = backend.performed.count
                center.perform(.play, preferring: .music, live: false)
                t.equal(backend.performed.count, count, "no command for a closed player")
                t.check(!center.snapshot(preferring: .music).running)

                // Denied permission: logged once, nothing shown.
                let denied = DeniedBackend()
                center.backend = denied
                center.poll()
                center.poll()
                t.equal(logs.filter { $0.contains("not allowed") }.count, 1, "denial logged once")
                t.equal(denied.polls, 1, "not asked again for 30 s")
                now += 31
                center.poll()
                t.equal(denied.polls, 1, "no poll while no measure reads (idle)")
                _ = center.snapshot(preferring: .music)
                t.equal(denied.polls, 2, "a read after the idle time polls again; the denial is re-checked after 30 s")

                subscription = nil
                _ = subscription
                t.check(!center.isPolling, "polling stops with the last subscription")
            }

            t.equal(NowPlayingCoverCache.imageExtension(Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
            t.equal(NowPlayingCoverCache.imageExtension(Data("GIF89a".utf8)), "gif")
            t.check(NowPlayingCoverCache.imageExtension(Data("hello".utf8)) == nil)
            t.check(NowPlayingCoverCache.write(Data("nope".utf8), app: .music, trackID: "x", folder: folder) == nil,
                    "non-image data is not written")
            let weird = NowPlayingCoverCache.write(DemoNowPlayingBackend.demoCover(), app: .spotify,
                                                   trackID: "../../etc/x:y", folder: folder)
            t.check(weird?.hasPrefix(folder.path) == true && weird?.contains("..") == false, "track ids are sanitized")
        }
    }

    final class DeniedBackend: NowPlayingBackend {
        var polls = 0
        func isRunning(_ app: MediaApp) -> Bool { app == .music }
        func status(_ app: MediaApp) -> NowPlayingPoll {
            polls += 1
            return .denied
        }
        func track(_ app: MediaApp) -> NowPlayingTrack? { nil }
        func artwork(_ app: MediaApp, track: NowPlayingTrack) -> NowPlayingArtwork? { nil }
        func perform(_ command: MediaPlayerCommand, on app: MediaApp) -> Bool { false }
    }

    // MARK: NowPlaying measures

    /// Solid-colour PNGs: distinct pictures for the cover tests.
    static func pngData(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        for x in 0..<8 { for y in 0..<8 { rep?.setColor(NSColor(deviceRed: r, green: g, blue: b, alpha: 1), atX: x, y: y) } }
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    /// Where covers come from: a file's from Music at once; a streamed track's online first, with Music's artwork as
    /// the fallback — which arrives late and, right after a change, is often the previous track's picture (never
    /// shown for the new track).
    static func coverRetryTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI cover sources") {
            let backend = DemoNowPlayingBackend()
            backend.artworkEnabled = false
            let center = NowPlayingCenter(backend: backend)
            center.forceLive = true
            center.interval = 3600
            var now: TimeInterval = 1000
            center.clock = { now }
            center.log = { _ in }
            var trace: [String] = []
            center.debugLog = { trace.append($0) }
            let online1 = pngData(1, 0, 0), musicA = pngData(0, 1, 0), musicB = pngData(0, 0, 1)
            let online2 = pngData(1, 1, 0), newer = pngData(0.5, 0.5, 0.5), albumFive = pngData(0, 1, 1)
            // What the online lookup finds, by title; a deferred lookup answers when `pending` is called.
            var online: [String: Data] = [:]
            var found: [URL: Data] = [:]
            var lookups: [String] = []
            var deferLookups = false
            var pending: (() -> Void)?
            let lookup: (NowPlayingTrack, @escaping (URL?) -> Void) -> Void = { track, done in
                lookups.append(track.title)
                let url = URL(string: "https://example.invalid/\(lookups.count).png")!
                found[url] = online[track.title]
                let answer = online[track.title] == nil ? nil : url
                if deferLookups { pending = { done(answer) } } else { done(answer) }
            }
            center.coverLookup = lookup
            center.coverDownload = { url, done in done(found[url]) }
            let folder = t.temporaryDirectory("cover-sources")
            let savedRoot = MediaUICache.root
            MediaUICache.root = folder
            defer { MediaUICache.root = savedRoot }
            func shown() -> Data? {
                let path = center.snapshot(preferring: .music).coverPath
                return path.isEmpty ? nil : FileManager.default.contents(atPath: path)
            }
            func poll(after seconds: TimeInterval) {
                now += seconds
                center.poll()
            }
            func play(_ id: String, _ title: String, album: String, file: String = "") {
                backend.statuses[.music]?.trackID = id
                backend.tracks[.music]?.title = title
                backend.tracks[.music]?.album = album
                backend.tracks[.music]?.file = file
            }

            inline([center.worker]) {
                // A streamed track (the first one seen) found online: shown at once, Music is not asked.
                online["Rain on Glass"] = online1
                let subscription = center.subscribe(live: false, wantsCover: true)
                withExtendedLifetime(subscription) {
                    t.equal(shown(), online1, "a streamed track: the online cover at once")
                    t.equal(lookups, ["Rain on Glass"])
                    poll(after: 60)
                    t.equal(backend.artworkAsks, 0, "Music is not asked when the lookup finds the cover")

                    // A file: Music's artwork at once, no lookup.
                    play("F1", "File Song", album: "Files", file: "/Music/a.m4a")
                    backend.artworkQueue = [.data(musicA)]
                    poll(after: 1)
                    t.equal(shown(), musicA, "a file: Music's artwork at once")
                    t.equal(lookups.count, 1, "no online lookup for a file with artwork")

                    // A streamed track the lookup does not find: Music's artwork is the fallback. Right after the
                    // change Music still hands out the file's picture → ignored; its own picture a second later.
                    play("S2", "Stream Two", album: "Album Two")
                    backend.artworkQueue = [.data(musicA)]
                    poll(after: 1)
                    t.equal(lookups.last, "Stream Two", "streamed: looked up online first")
                    t.equal(shown(), nil, "the previous track's picture is never shown for the new one")
                    backend.artworkQueue = [.data(musicB)]
                    poll(after: 1)
                    t.equal(shown(), musicB, "Music's own picture, asked again a second later")
                    // Looked at again 5 s later: a newer picture replaces it; one more look, then no more asks.
                    backend.artworkQueue = [.data(newer)]
                    poll(after: 5)
                    t.equal(shown(), newer, "a newer picture of Music replaces its earlier one")
                    let asks = backend.artworkAsks
                    poll(after: 10)
                    poll(after: 60)
                    t.equal(backend.artworkAsks, asks + 1, "one more look, then no more asks")
                    t.equal(shown(), newer, "no answer keeps the picture")

                    // Found online: Music is not asked.
                    play("S3", "Stream Three", album: "Album Three")
                    online["Stream Three"] = online2
                    let before = backend.artworkAsks
                    poll(after: 1)
                    t.equal(shown(), online2)
                    poll(after: 30)
                    t.equal(backend.artworkAsks, before, "Music is not asked when the lookup finds the cover")

                    // Nothing online and Music keeps handing out an earlier track's picture: never shown; the asks
                    // stop after 30 s.
                    play("S4", "Stream Four", album: "Album Four")
                    backend.artworkEnabled = true
                    backend.artworkData = newer
                    poll(after: 1)
                    for _ in 0..<40 { poll(after: 1) }
                    t.equal(shown(), nil, "an earlier track's picture is never shown")
                    let asked = backend.artworkAsks
                    for _ in 0..<10 { poll(after: 30) }
                    t.equal(backend.artworkAsks, asked, "the asks stop after 30 s")
                    t.check(trace.contains { $0.contains("another track's picture") }, "the stale picture is logged")
                    backend.artworkEnabled = false
                    backend.artworkData = nil

                    // Tracks of one album share their picture.
                    play("S5", "Stream Five", album: "Album Five")
                    backend.artworkQueue = [.data(albumFive)]
                    poll(after: 1)
                    t.equal(shown(), albumFive)
                    play("S6", "Stream Six", album: "Album Five")
                    backend.artworkQueue = [.data(albumFive)]
                    poll(after: 1)
                    t.equal(shown(), albumFive, "the same album's picture is right for the next track")

                    // A late online answer for the previous track is not shown for the new one.
                    deferLookups = true
                    online["Stream Seven"] = online1
                    play("S7", "Stream Seven", album: "Album Seven")
                    poll(after: 1)
                    let late = pending
                    play("S8", "Stream Eight", album: "Album Eight")
                    poll(after: 1)
                    late?()
                    t.equal(shown(), nil, "a late answer for the previous track is ignored")
                    pending?()
                    deferLookups = false

                    // A file without artwork is looked up online.
                    play("F10", "File Ten", album: "Files Ten", file: "/Music/b.mp3")
                    online["File Ten"] = online2
                    poll(after: 1)
                    t.equal(shown(), online2, "a file without artwork: looked up online")

                    // Lookup off: Music first for a streamed track too, its stale picture still ignored.
                    center.coverLookup = nil
                    play("S11", "Stream Eleven", album: "Album Eleven")
                    backend.artworkQueue = [.data(albumFive)]
                    poll(after: 1)
                    t.equal(shown(), nil, "lookup off: an earlier track's picture is still ignored")
                    let eleven = pngData(0.2, 0.4, 0.6)
                    backend.artworkQueue = [.data(eleven)]
                    poll(after: 1)
                    t.equal(shown(), eleven)
                    t.equal(lookups.filter { $0 == "Stream Eleven" }.count, 0, "no lookup while it is off")
                    center.coverLookup = lookup
                }
            }
        }
    }

    static func coverLookupTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI online cover lookup") {
            var track = NowPlayingTrack()
            track.artist = "Rain  Quartet"
            track.title = "Glass"
            track.album = "Weather Songs"
            let url = NowPlayingCoverLookup.searchURL(for: track, country: "CN")
            let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            t.equal(url?.host, "itunes.apple.com")
            t.equal(items.first { $0.name == "term" }?.value, "Rain Quartet Glass")
            t.equal(items.first { $0.name == "entity" }?.value, "song")
            t.equal(items.first { $0.name == "country" }?.value, "cn")
            var albumOnly = track
            albumOnly.title = ""
            let albumItems = NowPlayingCoverLookup.searchURL(for: albumOnly, country: "US")
                .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            t.equal(albumItems.first { $0.name == "entity" }?.value, "album")
            t.equal(albumItems.first { $0.name == "term" }?.value, "Rain Quartet Weather Songs")
            var noArtist = track
            noArtist.artist = ""
            t.check(NowPlayingCoverLookup.searchURL(for: noArtist, country: "US") == nil, "nothing to search for")

            func reply(_ results: [[String: String]]) -> Data {
                (try? JSONSerialization.data(withJSONObject: ["resultCount": results.count, "results": results])) ?? Data()
            }
            let art = "https://img.example.invalid/a/b/100x100bb.jpg"
            // The exact title wins over a live version; other artists never match.
            let data = reply([
                ["artistName": "Someone Else", "trackName": "Glass", "collectionName": "Weather Songs",
                 "artworkUrl100": "https://img.example.invalid/wrong/100x100bb.jpg"],
                ["artistName": "Rain Quartet", "trackName": "Glass (Live)", "collectionName": "Live",
                 "artworkUrl100": "https://img.example.invalid/live/100x100bb.jpg"],
                ["artistName": "Rain Quartet", "trackName": "Glass", "collectionName": "Weather Songs (Deluxe)",
                 "artworkUrl100": art],
            ])
            t.equal(NowPlayingCoverLookup.artworkURL(fromReply: data, track: track)?.absoluteString,
                    "https://img.example.invalid/a/b/600x600bb.jpg")
            // Album names written differently still match through the artist and title (full-width punctuation too).
            var cjk = NowPlayingTrack()
            cjk.artist = "雨滴乐队"
            cjk.title = "夜雨"
            cjk.album = "11月的雨"
            let cjkData = reply([["artistName": "雨滴乐队", "trackName": "夜雨", "collectionName": "十一月的雨",
                                  "artworkUrl100": "https://img.example.invalid/c/100x100bb.jpg"]])
            t.equal(NowPlayingCoverLookup.artworkURL(fromReply: cjkData, track: cjk)?.absoluteString,
                    "https://img.example.invalid/c/600x600bb.jpg")
            t.equal(NowPlayingCoverLookup.normalized("Don’t  Know-Why！"), "dontknowwhy")
            // Unusable replies.
            t.check(NowPlayingCoverLookup.artworkURL(fromReply: Data("not json".utf8), track: track) == nil)
            t.check(NowPlayingCoverLookup.artworkURL(fromReply: reply([["artistName": "Someone Else", "trackName": "Glass",
                                                                        "artworkUrl100": art]]), track: track) == nil,
                    "no match for the artist")
            t.check(NowPlayingCoverLookup.artworkURL(fromReply: reply([["artistName": "Rain Quartet", "trackName": "Glass",
                                                                        "artworkUrl100": "http://img.example.invalid/x.jpg"]]),
                                                     track: track) == nil, "https only")

            // Storefronts: the region's first, then Taiwan for Chinese names (else the US); never China's.
            var chinese = NowPlayingTrack()
            chinese.artist = "林雨声"
            chinese.title = "晚风"
            chinese.album = "晚风 - Single"
            t.equal(NowPlayingCoverLookup.storefronts(for: chinese, region: "JP"), ["jp", "tw"])
            t.equal(NowPlayingCoverLookup.storefronts(for: chinese, region: "CN"), ["tw", "hk"])
            t.equal(NowPlayingCoverLookup.storefronts(for: chinese, region: "TW"), ["tw", "hk"])
            t.equal(NowPlayingCoverLookup.storefronts(for: track, region: "US"), ["us"])
            t.equal(NowPlayingCoverLookup.storefronts(for: track, region: "DE"), ["de", "us"])
            t.equal(NowPlayingCoverLookup.storefronts(for: track, region: nil), ["us"])

            // A romanized artist ("Yusheng Lin" for 林雨声, as some storefronts write Chinese names).
            let romanized = reply([
                ["artistName": "Yusheng Lin", "trackName": "晚风 (伴奏)", "collectionName": "晚风 - Single",
                 "artworkUrl100": "https://img.example.invalid/inst/100x100bb.jpg"],
                ["artistName": "Yusheng Lin", "trackName": "晚风", "collectionName": "晚风 - Single",
                 "artworkUrl100": "https://img.example.invalid/song/100x100bb.jpg"],
            ])
            t.equal(NowPlayingCoverLookup.artworkURL(fromReply: romanized, track: chinese)?.absoluteString,
                    "https://img.example.invalid/song/600x600bb.jpg", "romanized artist, exact title")
            t.equal(NowPlayingCoverLookup.pinyinKey("林雨声"), "linyusheng")
            t.equal(NowPlayingCoverLookup.pinyinKey("Adele"), "")
            t.check(NowPlayingCoverLookup.romanizedMatch("Yusheng Lin", pinyin: "linyusheng"), "given name first")
            t.check(NowPlayingCoverLookup.romanizedMatch("LIN Yu-Sheng", pinyin: "linyusheng"), "family name first")
            t.check(!NowPlayingCoverLookup.romanizedMatch("Mei Chen", pinyin: "linyusheng"))
            // Traditional characters in the storefront (雨聲 for 雨声).
            var simplified = NowPlayingTrack()
            simplified.artist = "Echo"
            simplified.title = "雨声"
            simplified.album = "雨声 - Single"
            let traditional = reply([
                ["artistName": "林雨声 & Echo", "trackName": "雨聲 (Live)", "collectionName": "雨聲 (Live) - Single",
                 "artworkUrl100": "https://img.example.invalid/live/100x100bb.jpg"],
                ["artistName": "Echo", "trackName": "雨聲", "collectionName": "雨聲 - Single",
                 "artworkUrl100": "https://img.example.invalid/single/100x100bb.jpg"],
            ])
            t.equal(NowPlayingCoverLookup.artworkURL(fromReply: traditional, track: simplified)?.absoluteString,
                    "https://img.example.invalid/single/600x600bb.jpg", "Traditional and Simplified match")
            t.equal(NowPlayingCoverLookup.normalized("雨聲 ＡＢ"), "雨声ab")
            // The artist in another script ("Jay Chou" for 周杰伦): only an exact title counts.
            var jay = NowPlayingTrack()
            jay.artist = "周杰伦"
            jay.title = "晴天"
            let english = reply([["artistName": "Jay Chou", "trackName": "晴天", "collectionName": "葉惠美",
                                  "artworkUrl100": "https://img.example.invalid/jay/100x100bb.jpg"]])
            t.equal(NowPlayingCoverLookup.artworkURL(fromReply: english, track: jay)?.absoluteString,
                    "https://img.example.invalid/jay/600x600bb.jpg", "another script: the exact title")
            let live = reply([["artistName": "Jay Chou", "trackName": "晴天 (Live)",
                               "artworkUrl100": "https://img.example.invalid/jay-live/100x100bb.jpg"]])
            t.check(NowPlayingCoverLookup.artworkURL(fromReply: live, track: jay) == nil,
                    "another script and another title: no match")
            t.check(NowPlayingCoverLookup.isLatinScript("Jay Chou") && !NowPlayingCoverLookup.isLatinScript("周杰伦"))
            // Another song of the same artist is no match (a search returns the artist's other songs when it does not
            // have this one); another track of the same album is (the album's cover).
            var other = NowPlayingTrack()
            other.artist = "陈小溪"
            other.title = "等你回来 (雨夜版)"
            other.album = "等你回来 (雨夜版) - Single"
            let others = reply([["artistName": "陈小溪", "trackName": "明天见", "collectionName": "明天见 - Single",
                                 "artworkUrl100": "https://img.example.invalid/other/100x100bb.jpg"]])
            t.check(NowPlayingCoverLookup.artworkURL(fromReply: others, track: other) == nil,
                    "the artist's other songs are no match")
            let shortTitle = reply([["artistName": "陈小溪", "trackName": "等你回来", "collectionName": "等你回来 - Single",
                                     "artworkUrl100": "https://img.example.invalid/short/100x100bb.jpg"]])
            t.equal(NowPlayingCoverLookup.artworkURL(fromReply: shortTitle, track: other)?.absoluteString,
                    "https://img.example.invalid/short/600x600bb.jpg", "the title without its subtitle")
            var sunny = NowPlayingTrack()
            sunny.artist = "周杰伦"
            sunny.title = "晴天"
            sunny.album = "叶惠美"
            let sameAlbum = reply([["artistName": "周杰倫", "trackName": "東風破", "collectionName": "葉惠美",
                                    "artworkUrl100": "https://img.example.invalid/album/100x100bb.jpg"]])
            t.equal(NowPlayingCoverLookup.artworkURL(fromReply: sameAlbum, track: sunny)?.absoluteString,
                    "https://img.example.invalid/album/600x600bb.jpg", "another track of the same album")
            // Credits are split into names: a short name does not match inside another one.
            var short = NowPlayingTrack()
            short.artist = "Echo"
            short.title = "雨声"
            let inside = reply([["artistName": "Echoes of Rain", "trackName": "雨声",
                                 "artworkUrl100": "https://img.example.invalid/echoes/100x100bb.jpg"]])
            t.check(NowPlayingCoverLookup.artworkURL(fromReply: inside, track: short) == nil,
                    "\"Echo\" is not \"Echoes of Rain\"")
            t.equal(NowPlayingCoverLookup.artistNames("陈小溪, Mei Chen & 林雨声"), ["陈小溪", "Mei Chen", "林雨声"])
            t.equal(NowPlayingCoverLookup.artistNames("A feat. B x C、D"), ["A", "B", "C", "D"])
            t.equal(NowPlayingCoverLookup.baseTitle("等你回来 (雨夜版)"), "等你回来")
            t.equal(NowPlayingCoverLookup.baseTitle("Glass - Live at Home"), "glass")
            t.equal(NowPlayingCoverLookup.baseTitle("(Intro)"), "intro")
        }
    }

    /// Song information that updates its measures rarely and its meters often (TestSkins/MediaUI/NowPlayingLive): the
    /// meters show a new track at their next update, as a Rainmeter plugin's GetString is read on demand.
    static func nowPlayingLiveStringTests(_ t: AppTestRunner) {
        t.suite("App: NowPlaying strings are current between the measures' updates") {
            guard let url = Paths.repositoryFolder("TestSkins")?
                .appendingPathComponent("MediaUI/NowPlayingLive/NowPlayingLive.ini") else {
                print("    (skipped: TestSkins not found)")
                return
            }
            let skin = Skin(config: "MediaUI\\NowPlayingLive", fileURL: url,
                            skinsDirectory: url.deletingLastPathComponent().deletingLastPathComponent(),
                            system: SystemMonitor.shared, host: RenderHost())
            try skin.load()
            defer { skin.close() }
            let backend = DemoNowPlayingBackend()
            let center = NowPlayingCenter(backend: backend)
            center.forceLive = true
            center.interval = 3600
            center.clock = { 0 }
            let savedRoot = MediaUICache.root
            MediaUICache.root = t.temporaryDirectory("live-covers")
            defer { MediaUICache.root = savedRoot }
            func text(_ meter: String) -> String? { (skin.meter(named: meter) as? StringMeter)?.text }
            func cover() -> String? { (skin.meter(named: "MeterCover") as? ImageMeter)?.imagePath }
            func play(_ id: String, _ title: String, _ artist: String, _ duration: Double) {
                backend.tracks[.music] = NowPlayingTrack(title: title, artist: artist, duration: duration)
                backend.statuses[.music]?.trackID = id
                center.poll()
                skin.update()
            }
            inline([center.worker]) {
                for m in skin.measures { (m as? NowPlayingClientMeasure)?.center = center }
                center.poll()
                skin.update()
                t.equal(text("MeterTrack"), "Rain on Glass")
                t.equal(text("MeterLine"), "Deskset Ensemble - Rain on Glass (04:05)")
                t.equal(text("MeterLengthChild"), "4:05", "the main measure's DisableLeadingZero")
                guard let track = skin.measure(named: "MeasureTrack") else { return t.check(false, "MeasureTrack") }
                let updates = track.updateCount
                // The cover is fetched once a measure shows it: it arrives with the next poll, between the measure's
                // updates, and the Image meter shows it at the skin's next update.
                t.check(cover()?.hasSuffix("nocover.png") == true, "no cover yet: \(cover() ?? "nil")")
                center.poll()
                skin.update()
                t.equal(track.updateCount, updates)
                let firstCover = cover()
                t.check(firstCover?.contains("cover-") == true, "the first track's cover: \(firstCover ?? "nil")")

                // The next track: the measures update again in 20 s, the meters at every update.
                play("NEXT", "Second Song", "Someone Else", 200)
                t.equal(track.updateCount, updates, "the measure itself did not update")
                t.equal(text("MeterTrack"), "Second Song")
                t.equal(text("MeterArtist"), "Someone Else")
                t.equal(text("MeterLine"), "Someone Else - Second Song (03:20)", "[Measure] section variables too")
                t.equal(text("MeterOldTitle"), "Second Song", "iTunesPlugin")
                t.equal(text("MeterWebTitle"), "Second Song", "WebNowPlaying")
                t.equal(skin.measure(named: "MeasureDuration")?.value, 245, "the number follows the measure's updates")
                t.equal(text("MeterLengthChild"), "3:20")
                t.check(cover() != nil && cover() != firstCover, "the Image meter shows the new track's cover")
                t.equal(skin.variable("TrackChanges"), "0", "OnChangeAction runs only when the measure updates")

                // A paused measure keeps its string too, until it is unpaused.
                skin.execute("[!PauseMeasure MeasureArtist]", from: nil)
                play("FOURTH", "Fourth", "Fourth Artist", 90)
                t.equal(text("MeterArtist"), "Someone Else", "a paused measure is not read on demand")
                skin.execute("[!UnpauseMeasure MeasureArtist]", from: nil)
                skin.update()
                t.equal(text("MeterArtist"), "Fourth Artist")

                // A disabled measure keeps the string meters last saw; enabled again, it reads the player again.
                skin.execute("[!DisableMeasure MeasureArtist]", from: nil)
                play("THIRD", "Third", "Third Artist", 100)
                t.equal(text("MeterTrack"), "Third")
                t.equal(text("MeterArtist"), "Fourth Artist", "a disabled measure is not read on demand")
                skin.execute("[!EnableMeasure MeasureArtist]", from: nil)
                skin.update()
                t.equal(text("MeterArtist"), "Third Artist")

                // Substitute applies to the current string.
                play("EMPTY", "", "", 0)
                t.equal(text("MeterTrack"), "No track")

                // The player quits: MeasureGone updates to "", then MeasureQuit disables it in the same update. The
                // meter shows that update's string, not the title it read before.
                t.equal(text("MeterGone"), "Not playing")
                play("FIFTH", "Fifth", "Fifth Artist", 60)
                t.equal(text("MeterGone"), "Fifth")
                backend.running = []
                center.poll()
                skin.update()
                t.check(skin.measure(named: "MeasureGone")?.disabled == true, "the status disabled the title")
                t.equal(text("MeterGone"), "Not playing")
            }
        }

        t.suite("App: NowPlaying reads on demand of a paused skin do not keep the players polled") {
            let backend = DemoNowPlayingBackend()
            backend.artworkEnabled = false
            let center = NowPlayingCenter(backend: backend)
            center.forceLive = true
            center.interval = 3600
            var now = 0.0
            center.clock = { now }
            inline([center.worker]) {
                let subscription = center.subscribe(live: true, wantsCover: false)
                _ = center.snapshot(preferring: .music)
                now = NowPlayingCenter.idleAfter + 10
                let polls = backend.statusPolls
                // The Studio's live values read a paused skin's measures: peek, which is not a read.
                t.equal(center.peek(preferring: .music).track?.title, "Rain on Glass")
                center.poll()
                t.equal(backend.statusPolls, polls, "idle: only peeks for longer than idleAfter")
                _ = center.snapshot(preferring: .music)
                t.check(backend.statusPolls > polls, "a running skin's read wakes the poller")
                withExtendedLifetime(subscription) {}
            }
        }
    }

    static func nowPlayingMeasureTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI NowPlaying measures") {
            let (skin, host) = try bareSkin(t, "[Rainmeter]\nUpdate=1000\n[Variables]\nPlayer=Spotify\nHits=0\n")
            let backend = DemoNowPlayingBackend()
            backend.artworkEnabled = false
            backend.running = [.music, .spotify]
            backend.statuses[.spotify] = NowPlayingStatus(state: 2, volume: 20, trackID: "SP1")
            backend.tracks[.spotify] = NowPlayingTrack(title: "Paused Song", artist: "Other", duration: 100)
            let center = NowPlayingCenter(backend: backend)
            center.forceLive = true
            center.interval = 3600
            center.clock = { 0 }
            inline([center.worker]) {
                let main = NowPlayingMeasure(name: "MeasurePlayer", section: section("MeasurePlayer", [
                    ("Measure", "NowPlaying"), ("PlayerName", "#Player#"), ("PlayerType", "Duration"),
                    ("DisableLeadingZero", "1"), ("TrackChangeAction", "[!SetVariable Hits 1]"),
                ]), skin: skin, type: "nowplaying")
                main.center = center
                main.readOptions()
                t.equal(main.preferredApp, .spotify)
                // Music plays, Spotify (named) is paused: Music is shown.
                t.equal(main.computeValue(), 245)
                t.equal(main.pluginString, "4:05", "DisableLeadingZero")
                t.equal(main.automaticMaxValue, 245)
                // Track change → TrackChangeAction (not for the first track seen).
                t.equal(skin.variable("Hits"), "0")
                backend.statuses[.music]?.trackID = "NEXT"
                center.poll()
                _ = main.computeValue()
                t.equal(skin.variable("Hits"), "1", "TrackChangeAction ran")

                let itunes = ITunesMeasure(name: "mName", section: section("mName", [
                    ("Measure", "Plugin"), ("Plugin", "iTunesPlugin"), ("Command", "GetCurrentTrackTime"),
                ]), skin: skin, type: "itunesplugin")
                itunes.center = center
                itunes.readOptions()
                t.equal(itunes.computeValue(), 245)
                t.equal(itunes.pluginString, "4:05")
                let bang = ITunesMeasure(name: "mPlay", section: section("mPlay", [("Command", "PlayPause")]),
                                         skin: skin, type: "itunesplugin")
                bang.center = center
                bang.readOptions()
                t.equal(bang.bangCommand, "PlayPause")
                t.equal(bang.computeValue(), 0)
                t.check(bang.pluginString == nil)
                bang.execute(command: "")
                t.equal(backend.performed.last?.0, .playPause, "empty !CommandMeasure runs Command=")
                bang.execute(command: "SoundVolumeDown")
                t.equal(backend.performed.last?.0, .setVolume(65))

                let art = ITunesMeasure(name: "mArt", section: section("mArt", [
                    ("Command", "GetCurrentTrackArtwork"), ("DefaultArtwork", "none.png"),
                ]), skin: skin, type: "itunesplugin")
                art.center = center
                art.readOptions()
                backend.running = [.spotify]
                center.poll()
                _ = art.computeValue()
                t.check(art.pluginString?.hasSuffix("/none.png") == true, "DefaultArtwork when there is no cover")

                let wnp = WebNowPlayingMeasure(name: "W", section: section("W", [("PlayerType", "Player")]),
                                               skin: skin, type: "webnowplaying")
                wnp.center = center
                wnp.readOptions()
                _ = wnp.computeValue()
                t.equal(wnp.pluginString, "Spotify", "only Spotify runs now")
                wnp.execute(command: "Repeat")
                t.equal(backend.performed.last?.0, .setRepeat(.all))
                t.equal(backend.performed.last?.1, .spotify)

                let key = MediaKeyMeasure(name: "K", section: section("K", []), skin: skin, type: "mediakey")
                var sent: [MediaKeyCommand] = []
                MediaKeyMeasure.sink = { command, _ in sent.append(command) }
                defer { MediaKeyMeasure.sink = nil }
                key.execute(command: "PrevTrack")
                key.execute(command: "Explode")
                t.equal(sent, [.prevTrack])
                t.check(host.logs.contains { $0.contains("unknown command") }, "unknown MediaKey command logged")
            }
        }
    }

    // MARK: InputText

    static func inputTextModelTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI InputText model") {
            let c1 = InputTextCommand.parse("[!SetVariable SomeVar \"$UserInput$\"]")
            t.equal(c1.action, "[!SetVariable SomeVar \"$UserInput$\"]")
            t.equal(c1.overrides, [:])
            t.check(c1.needsInput)
            let c2 = InputTextCommand.parse("[!SetVariable SomeVar \"[MeasureName]\"] FontColor=\"255,0,0,255\"")
            t.equal(c2.action, "[!SetVariable SomeVar \"[MeasureName]\"]")
            t.equal(c2.overrides, ["fontcolor": "255,0,0,255"])
            t.check(!c2.needsInput)
            let c3 = InputTextCommand.parse("!SetVariable SecondVar \"$UserInput$\" Y=40 DefaultValue=\"Change Me Too!\"")
            t.equal(c3.action, "!SetVariable SecondVar \"$UserInput$\"")
            t.equal(c3.overrides, ["y": "40", "defaultvalue": "Change Me Too!"])
            let c4 = InputTextCommand.parse("[\"$UserInput$\"] Y=75 DefaultValue=\"Text file path and name\"")
            t.equal(c4.action, "[\"$UserInput$\"]")
            t.equal(c4.overrides["y"], "75")
            let c5 = InputTextCommand.parse("[!A][!B \"x y\"]   W=20   Y=145 DefaultValue=\"#V#\"")
            t.equal(c5.action, "[!A][!B \"x y\"]")
            t.equal(c5.overrides, ["w": "20", "y": "145", "defaultvalue": "#V#"])
            let c6 = InputTextCommand.parse("!SetVariable Var Color=red")
            t.equal(c6.action, "!SetVariable Var Color=red", "unknown option names stay in the bang")
            t.equal(InputTextCommand.parse("  ").action, "")
            t.equal(InputTextCommand.parse("Y=5").action, "Y=5", "a lone override is not stripped")
            t.equal(c1.substituted("a b"), "[!SetVariable SomeVar \"a b\"]")
            t.equal(InputTextCommand(action: "$userinput$ $UserInput$").substituted("x"), "x x")

            t.equal(InputTextBang.parse("ExecuteBatch ALL"), .all)
            t.equal(InputTextBang.parse("executebatch 3"), .range(3...3))
            t.equal(InputTextBang.parse("ExecuteBatch 1-4"), .range(1...4))
            t.equal(InputTextBang.parse("ExecuteBatch 4-2"), .range(2...4))
            t.check(InputTextBang.parse("ExecuteBatch 0") == nil, "there is no Command0")
            t.check(InputTextBang.parse("ExecuteBatch x") == nil)
            t.check(InputTextBang.parse("") == nil)
            t.equal(InputTextBang.parse("[!Log \"$UserInput$\"]"), .command("[!Log \"$UserInput$\"]"))

            t.equal(InputTextFilter.sanitize("-12.5.3a-", number: true, limit: 0), "-12.53")
            t.equal(InputTextFilter.sanitize("abc", number: true, limit: 0), "")
            t.equal(InputTextFilter.sanitize("abcdef", number: false, limit: 4), "abcd")
            t.equal(InputTextFilter.sanitize("٣4", number: true, limit: 0), "4", "ASCII digits only")

            let settings = InputTextSettings.read { key in
                ["X": "5", "Y": "(2*10)", "W": "240", "H": "25", "SolidColor": "76A0E8FF", "FontColor": "255,255,255,128",
                 "FontFace": "Georgia", "FontSize": "14", "StringStyle": "BoldItalic", "StringAlign": "Right",
                 "DefaultValue": "Change Me!", "Password": "1", "InputLimit": "10", "InputNumber": "0",
                 "TopMost": "1", "FocusDismiss": "0"][key]
            }
            t.equal(settings.x, 5)
            t.equal(settings.y, 20)
            t.equal(settings.width, 240)
            t.equal(settings.solidColor, RGBA(r: 0x76, g: 0xA0, b: 0xE8, a: 255))
            t.equal(settings.fontColor.a, 128)
            t.check(settings.bold && settings.italic)
            t.equal(settings.align, .right)
            t.check(settings.password)
            t.equal(settings.inputLimit, 10)
            t.equal(settings.topMost, true)
            t.equal(settings.focusDismiss, false)
            let defaults = InputTextSettings.read { _ in nil }
            t.check(defaults.width == nil && defaults.topMost == nil && defaults.focusDismiss)
            t.equal(defaults.solidColor, RGBA(r: 255, g: 255, b: 255, a: 255))
            t.equal(defaults.fontColor, RGBA(r: 0, g: 0, b: 0, a: 255))

            // Batch: inputs first, then the commands in order.
            let batch = InputTextBatch(steps: [
                .init(index: 1, command: InputTextCommand.parse("[!SetVariable A \"$UserInput$\"]")),
                .init(index: 2, command: InputTextCommand.parse("[!Refresh]")),
                .init(index: 3, command: InputTextCommand.parse("[!SetVariable B \"$UserInput$\"] Y=40")),
            ])
            let first = batch.nextPrompt()
            t.equal(first?.index, 1)
            batch.submit("one", for: first!)
            let second = batch.nextPrompt()
            t.equal(second?.index, 3, "commands without $UserInput$ do not prompt")
            batch.submit("two", for: second!)
            t.check(batch.nextPrompt() == nil)
            t.equal(batch.actions(), ["[!SetVariable A \"one\"]", "[!Refresh]", "[!SetVariable B \"two\"]"])

            // Frame and level of the box.
            let frame = InputTextPanelPrompt.frame(settings, skinFrame: CGRect(x: 100, y: 500, width: 300, height: 200),
                                                   skinWidth: 300, lineHeight: 18)
            t.equal(frame, CGRect(x: 105, y: 655, width: 240, height: 25))
            let auto = InputTextPanelPrompt.frame(defaults, skinFrame: CGRect(x: 0, y: 0, width: 300, height: 100),
                                                  skinWidth: 300, lineHeight: 14)
            t.equal(auto.width, 300)
            t.equal(auto.height, 20)
            t.equal(InputTextPanelPrompt.level(nil, skinLevel: .normal), .normal)
            t.check(InputTextPanelPrompt.level(true, skinLevel: .normal) > .floating)
            let topmostSkin = WindowGeometry.level(forAlwaysOnTop: 2)
            t.check(InputTextPanelPrompt.level(true, skinLevel: topmostSkin) > topmostSkin, "above Stay Topmost skins")
            t.equal(InputTextPanelPrompt.level(false, skinLevel: topmostSkin), .normal)
        }
    }

    /// Records the boxes the measure asks for and answers them from a script.
    final class FakePrompt: InputTextPrompting {
        var shown: [InputTextSettings] = []
        var answers: [String?] = []
        var cancelled = 0
        private var pending: ((String?) -> Void)?

        func show(_ settings: InputTextSettings, completion: @escaping (String?) -> Void) {
            shown.append(settings)
            if answers.isEmpty {
                pending = completion
            } else {
                completion(answers.removeFirst())
            }
        }

        func answer(_ text: String?) {
            let p = pending
            pending = nil
            p?(text)
        }

        func cancel() {
            cancelled += 1
            pending = nil
        }
    }

    static func inputTextMeasureTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI InputText measure") {
            let (skin, host) = try bareSkin(t, "[Rainmeter]\nUpdate=1000\n[Variables]\nNote=old\nFirst=a\nSecond=b\nGone=0\n")
            let fake = FakePrompt()
            InputTextMeasure.promptFactory = { _ in fake }
            defer { InputTextMeasure.promptFactory = nil }
            let m = InputTextMeasure(name: "MeasureInput", section: section("MeasureInput", [
                ("Measure", "Plugin"), ("Plugin", "InputText"), ("X", "8"), ("Y", "8"), ("W", "200"), ("H", "22"),
                ("DefaultValue", "#Note#"), ("FontSize", "11"),
                ("OnDismissAction", "[!SetVariable Gone 1]"),
                ("Command1", "[!SetVariable Note \"$UserInput$\"]"),
                ("Command2", "[!SetVariable First \"$UserInput$\"] Y=40 DefaultValue=\"#First#\""),
                ("Command3", "[!SetVariable Second \"$UserInput$\"] Y=62 InputNumber=1"),
                ("Command4", "!SetVariable Both \"#First#+#Second#\""),
            ]), skin: skin, type: "inputtext")
            m.readOptions()
            t.equal(m.computeValue(), 0)
            t.equal(m.pluginString, "")

            fake.answers = ["new note"]
            m.execute(command: "ExecuteBatch 1")
            t.equal(fake.shown.count, 1)
            t.equal(fake.shown[0].defaultValue, "old", "DefaultValue with #Note#")
            t.equal(fake.shown[0].y, 8)
            t.equal(skin.variable("Note"), "new note")
            t.equal(m.lastInput, "new note")
            t.equal(m.pluginString, "new note")
            t.check(!m.isPrompting)

            // Two inputs with per-command overrides; nothing runs before both are in.
            m.execute(command: "ExecuteBatch 2-3")
            t.equal(fake.shown.count, 2)
            t.equal(fake.shown[1].y, 40)
            t.equal(fake.shown[1].defaultValue, "a")
            t.check(m.isPrompting)
            m.execute(command: "ExecuteBatch 1")
            t.equal(fake.shown.count, 2, "ignored while a box is open")
            fake.answer("first!")
            t.equal(skin.variable("First"), "a", "commands wait for all inputs")
            t.equal(fake.shown[2].y, 62)
            t.check(fake.shown[2].inputNumber)
            fake.answer("42")
            t.equal(skin.variable("First"), "first!")
            t.equal(skin.variable("Second"), "42")
            t.equal(m.computeValue(), 42)

            // Escape: no command runs, OnDismissAction does.
            m.execute(command: "ExecuteBatch ALL")
            fake.answer(nil)
            t.equal(skin.variable("Note"), "new note")
            t.equal(skin.variable("Gone"), "1")
            t.check(!m.isPrompting)

            // ALL with every input given: commands 1-4 in order (#First# in Command4 is read when the bang runs).
            fake.answers = ["n", "f", "7"]
            m.execute(command: "ExecuteBatch All")
            t.equal(skin.variable("Note"), "n")
            t.equal(skin.variable("Second"), "7")
            t.equal(skin.variable("Both"), "first!+42", "#Variables# in a command are read when the bang runs")

            // A command given directly as the argument.
            fake.answers = ["direct"]
            m.execute(command: "[!SetVariable Note \"$UserInput$\"] Y=99")
            t.equal(skin.variable("Note"), "direct")
            t.equal(fake.shown.last?.y, 99)

            m.execute(command: "ExecuteBatch 9")
            t.check(host.logs.contains { $0.contains("no Command option") })
            m.execute(command: "Bogus x")
            t.equal(skin.variable("Note"), "direct", "an unknown command with no $UserInput$ runs as a bang (no-op)")

            // Without a skin window (render / tests without a fake) nothing is shown and nothing breaks.
            InputTextMeasure.promptFactory = nil
            let plain = InputTextMeasure(name: "P", section: section("P", [("Command1", "[!SetVariable Note \"$UserInput$\"]")]),
                                         skin: skin, type: "inputtext")
            plain.readOptions()
            plain.execute(command: "ExecuteBatch 1")
            t.check(!plain.isPrompting)
        }
    }

    // MARK: WiFi

    static func wifiTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI WiFiStatus") {
            t.equal(WiFiStatusFormat.quality(rssi: -50), 100)
            t.equal(WiFiStatusFormat.quality(rssi: -40), 100)
            t.equal(WiFiStatusFormat.quality(rssi: -75), 50)
            t.equal(WiFiStatusFormat.quality(rssi: -100), 0)
            t.equal(WiFiStatusFormat.quality(rssi: 0), 0, "0 = unknown")
            let a = WiFiNetworkInfo(ssid: "Home", rssi: -55, transmitRate: 0, encryption: "AES", auth: "WPA2-Personal",
                                    phy: "802.11ax")
            t.equal(WiFiStatusFormat.listLine(a, style: 0), "Home")
            t.equal(WiFiStatusFormat.listLine(a, style: 1), "Home @802.11ax")
            t.equal(WiFiStatusFormat.listLine(a, style: 2), "Home (AES:WPA2-Personal)")
            t.equal(WiFiStatusFormat.listLine(a, style: 7), "Home @802.11ax (AES:WPA2-Personal) [90%]")
            t.equal(WiFiStatusFormat.listLine(a, style: 99), "Home @802.11ax (AES:WPA2-Personal) [90%]")
            var weak = a
            weak.rssi = -80
            var cafe = a
            cafe.ssid = "Cafe"
            cafe.rssi = -60
            var hidden = a
            hidden.ssid = ""
            hidden.rssi = -30
            t.equal(WiFiStatusFormat.list([weak, cafe, a, hidden], style: 4, limit: 5), "Home [90%]\nCafe [80%]",
                    "deduplicated, strongest first, hidden networks left out")
            t.equal(WiFiStatusFormat.list([weak, cafe, a], style: 0, limit: 1), "Home")
            t.equal(WiFiStatusFormat.list([], style: 0, limit: 5), "")
            t.equal(WiFiStatusFormat.encryption(.wpa2Personal), "AES")
            t.equal(WiFiStatusFormat.encryption(.none), "NONE")
            t.equal(WiFiStatusFormat.encryption(.wpaPersonal), "TKIP")
            t.equal(WiFiStatusFormat.auth(.wpa3Personal), "WPA3-Personal")
            t.equal(WiFiStatusFormat.auth(.wpa2Enterprise), "WPA2-Enterprise")
            t.equal(WiFiStatusFormat.auth(.none), "Open")
            t.equal(WiFiStatusFormat.auth(.unknown), "???")
            t.equal(WiFiStatusFormat.phy(.mode11ac), "802.11ac")
            t.equal(WiFiStatusFormat.phy(.modeNone), "???")

            let (skin, _) = try bareSkin(t)
            let center = WiFiCenter()
            var reads = 0
            center.reader = { _ in
                reads += 1
                return WiFiNetworkInfo(ssid: "Office", rssi: -65, transmitRate: 573.5, encryption: "AES",
                                       auth: "WPA3-Personal", phy: "802.11ax")
            }
            center.scanner = { _ in [a, cafe] }
            var now: TimeInterval = 0
            center.clock = { now }
            func measure(_ type: String, _ extra: [(String, String)] = []) -> WiFiStatusMeasure {
                let m = WiFiStatusMeasure(name: "W\(type)", section: section("W", [("WiFiInfoType", type)] + extra),
                                          skin: skin, type: "wifistatus")
                m.center = center
                m.readOptions()
                return m
            }
            inline([center.worker]) {
                let ssid = measure("SSID")
                _ = ssid.computeValue()
                t.equal(ssid.pluginString, "Office")
                let quality = measure("Quality")
                t.equal(quality.computeValue(), 70)
                t.equal(quality.automaticMaxValue, 100)
                t.check(quality.pluginString == nil)
                t.equal(measure("TXRate").computeValue(), 573_500)
                t.equal(measure("RXRATE").computeValue(), 573_500)
                let enc = measure("Encryption")
                _ = enc.computeValue()
                t.equal(enc.pluginString, "AES")
                let auth = measure("auth")
                _ = auth.computeValue()
                t.equal(auth.pluginString, "WPA3-Personal")
                let phy = measure("PHY")
                _ = phy.computeValue()
                t.equal(phy.pluginString, "802.11ax")
                t.equal(reads, 1, "one read for all measures within 2 s")
                now = 3
                _ = phy.computeValue()
                t.equal(reads, 2, "refreshed after 2 s")
                let list = measure("LIST", [("WiFiListStyle", "5"), ("WiFiListLimit", "1")])
                t.equal(list.computeValue(), 2)
                t.equal(list.pluginString, "Home @802.11ax [90%]")
            }
            let bad = measure("Speed")
            t.equal(bad.computeValue(), 0)
            t.equal(bad.pluginString, "")
        }
    }

    // MARK: FrostedGlass

    static func frostedGlassTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI FrostedGlass options") {
            func style(_ options: [String: String]) -> FrostedGlassStyle {
                FrostedGlassStyle.read { options[$0] }
            }
            let d = style([:])
            t.equal(d.kind, .blur, "Type defaults to Blur")
            t.equal(d.cornerRadius, 0)
            t.equal(d.borders, [])
            t.check(d.borderVisible && d.enabled && d.drawsBackground)
            t.equal(d.backdrop.a, 0)
            t.equal(d.material, .hudWindow)
            t.check(d.tint == nil)
            let a = style(["Type": "Acrylic", "Corner": "Round", "Border": "Top | Bottom", "Backdrop": "255,0,0,55",
                           "BorderColor": "FF0000", "DarkMode": "1"])
            t.equal(a.kind, .acrylic)
            t.equal(a.cornerRadius, 8)
            t.equal(a.borders, [.top, .bottom])
            t.equal(a.backdrop, RGBA(r: 255, g: 0, b: 0, a: 55))
            t.equal(a.tint, RGBA(r: 255, g: 0, b: 0, a: 55))
            t.equal(a.borderColor, RGBA(r: 255, g: 0, b: 0, a: 255))
            t.check(a.darkMode)
            t.equal(style(["Corner": "RoundSmall"]).cornerRadius, 4)
            t.equal(style(["Corner": "RoundWs"]).cornerRadius, 8)
            t.equal(style(["Border": "all"]).borders, .all)
            t.equal(style(["Type": "None"]).drawsBackground, false)
            t.equal(style(["Type": "Mica"]).material, .underWindowBackground)
            t.equal(style(["Type": "MicaAlt"]).material, .windowBackground)
            let backdrop = style(["Type": "Backdrop", "Backdrop": "#10203040"])
            t.check(backdrop.material == nil)
            t.equal(backdrop.tint, RGBA(r: 16, g: 32, b: 48, a: 255), "Backdrop is opaque")
            let translucent = style(["Type": "TraslucentBackdrop", "Backdrop": "102030"])
            t.equal(translucent.backdrop.a, 0, "alpha defaults to 0")
            t.check(translucent.tint == nil)
            t.equal(style(["BorderColor": "Backdrop", "Backdrop": "1,2,3,4"]).borderColor, RGBA(r: 1, g: 2, b: 3, a: 255))
            t.equal(style(["Backdrop": "Dark2"]).backdrop, RGBA(r: 48, g: 48, b: 48, a: 128))
            t.check(!style(["BlurEnabled": "0"]).enabled)
            t.equal(style(["BlurEnabled": "0", "Corner": "Round"]).effectiveRadius, 0)
            t.equal(FrostedGlassStyle.sides("left|RIGHT|bogus"), [.left, .right])
        }

        t.suite("App: MediaUI FrostedGlass window") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            guard let c = app.activate(config: "App\\Focus", file: nil) else {
                t.check(false, "App\\Focus loads")
                return
            }
            var measure: FrostedGlassMeasure? = FrostedGlassMeasure(name: "FrostedGlass", section: section("FrostedGlass", [
                ("Measure", "Plugin"), ("Plugin", "FrostedGlass"), ("Type", "Acrylic"), ("Corner", "Round"),
            ]), skin: c.skin, type: "frostedglass")
            if let m = measure {
                m.readOptions()
                t.equal(m.computeValue(), 1)
                let backdrop = FrostedGlassBackdrop.backdrop(for: c)
                t.check(backdrop != nil, "a backdrop is attached to the skin window")
                t.equal(c.view.layer?.cornerRadius, 8, "the skin content is rounded")
                t.check(c.view.layer?.masksToBounds == true)
                t.check(backdrop?.effectWindow.isVisible == false, "headless: never shown")
                t.equal(backdrop?.effectView.material, .popover)
                m.execute(command: "ToggleBlur")
                t.equal(m.computeValue(), 0)
                t.equal(c.view.layer?.cornerRadius, 0, "disabled: no rounding")
                m.execute(command: "EnableBlur")
                m.execute(command: "DisableCorner")
                t.equal(m.style.effectiveRadius, 0)
                m.execute(command: "DarkMode")
                t.check(m.style.darkMode)
                t.equal(backdrop?.effectView.appearance?.name, .darkAqua)
                m.execute(command: "Nonsense")
                // The skin window is replaced when click-through is turned off again: the backdrop follows it.
                let firstWindow = c.window
                c.skin.execute("[!ClickThrough 1][!ClickThrough 0]", from: nil)
                t.check(c.window !== firstWindow, "a new skin window")
                AppSelfTest.spin(timeout: 2) { backdrop?.followedWindow === c.window }
                t.check(backdrop?.followedWindow === c.window, "the backdrop follows the new skin window")
            }
            // Released with the measure (skin refresh / unload).
            measure = nil
            AppSelfTest.spin(timeout: 2) { FrostedGlassBackdrop.backdrop(for: c) == nil }
            t.check(FrostedGlassBackdrop.backdrop(for: c) == nil, "backdrop removed when the measure goes")
            t.equal(c.view.layer?.cornerRadius, 0)
            c.stop()
        }
    }

    // MARK: Chameleon

    static func chameleonTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI Chameleon") {
            let navy = ChameleonColor(r: 20, g: 30, b: 70), sand = ChameleonColor(r: 230, g: 220, b: 190), rust = ChameleonColor(r: 190, g: 80, b: 30)
            let pixels = Array(repeating: navy, count: 700) + Array(repeating: sand, count: 200)
                + Array(repeating: rust, count: 100)
            guard let p = ChameleonPalette.analyze(pixels) else {
                t.check(false, "palette")
                return
            }
            t.equal(p.background1, navy)
            t.check(p.background2 == sand || p.background2 == rust)
            t.equal(p.foreground1, sand, "the most contrasting color")
            t.check(p.foreground1.contrast(with: p.background1) >= 4.5)
            t.check(p.foreground2.contrast(with: p.background1) >= 3)
            t.equal(p.light.first, p.light.max { $0.luminance < $1.luminance })
            t.equal(p.dark.first, navy)
            t.equal(p.color(named: "Dark1"), navy)
            t.equal(p.color(named: "average"), ChameleonColor(r: (20 * 700 + 230 * 200 + 190 * 100) / 1000,
                                                    g: (30 * 700 + 220 * 200 + 80 * 100) / 1000,
                                                    b: (70 * 700 + 190 * 200 + 30 * 100) / 1000))
            t.check(p.color(named: "Luminance") == nil)
            t.check(p.luminance > 0.05 && p.luminance < 0.4)
            // A flat image still gives four usable colors.
            let flat = ChameleonPalette.analyze(Array(repeating: ChameleonColor(r: 128, g: 128, b: 128), count: 50))
            t.check(flat.map { $0.foreground1.contrast(with: $0.background1) >= 4.5 } == true)
            t.check(ChameleonPalette.analyze([]) == nil)
            t.equal(ChameleonColor(r: 10, g: 171, b: 300).hex, "0AABFF")
            t.equal(ChameleonColor(r: 1, g: 2, b: 3).decimal, "1,2,3")
            t.equal(ChameleonColor(hex: "#FF8000"), ChameleonColor(r: 255, g: 128, b: 0))
            t.check(ChameleonColor(hex: "xyz") == nil)

            // From a file: left half red, right half blue; cropping and the screen aspect choose what is sampled.
            let folder = t.temporaryDirectory("chameleon")
            let url = folder.appendingPathComponent("wall.png")
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0),
               let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                ctx.cgContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
                ctx.cgContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                ctx.cgContext.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
                try rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            let all = ChameleonPalette.pixels(at: url, crop: nil, aspect: nil) ?? []
            t.check(all.count > 1000, "whole image sampled (\(all.count) px)")
            let left = ChameleonPalette.pixels(at: url, crop: CGRect(x: 0, y: 0, width: 90, height: 100), aspect: nil) ?? []
            let leftPalette = ChameleonPalette.analyze(left)
            t.check(leftPalette.map { $0.background1.r > 200 && $0.background1.b < 60 } == true, "crop: red only")
            let square = ChameleonPalette.pixels(at: url, crop: nil, aspect: 1) ?? []
            t.check(square.count < all.count, "screen aspect crops the sides")
            t.check(ChameleonPalette.pixels(at: folder.appendingPathComponent("missing.png"), crop: nil, aspect: nil) == nil)

            // Measures: parent + children, Hex and Dec, fallback colors.
            let (skin, _) = try bareSkin(t)
            let parent = ChameleonMeasure(name: "Cham", section: section("Cham", [
                ("Type", "File"), ("Path", url.path), ("Format", "Dec"), ("FallbackBG1", "112233"),
            ]), skin: skin, type: "chameleon")
            parent.readOptions()
            t.check(!parent.isChild)
            t.equal(parent.effectivePalette.background1, ChameleonColor(r: 0x11, g: 0x22, b: 0x33), "fallback before sampling")
            _ = parent.computeValue()
            t.equal(parent.pluginString, url.path, "the parent returns the image path")
            AppSelfTest.spin(timeout: 5) { parent.palette != nil }
            t.check(parent.palette != nil, "sampled in the background")
            t.equal(parent.format(ChameleonColor(r: 1, g: 2, b: 3)), "1,2,3")
        }
    }

    // MARK: SysColor / IsFullScreen / GetActiveTitle

    static func desktopInfoTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI SysColor and focused window") {
            let c = RGBA(r: 10, g: 20, b: 30, a: 255)
            t.equal(SysColorFormat.format(c, display: .all, hex: false), "10,20,30,255")
            t.equal(SysColorFormat.format(c, display: .rgb, hex: true), "0A141E")
            t.equal(SysColorFormat.format(c, display: .all, hex: true), "0A141EFF")
            t.equal(SysColorFormat.format(c, display: .green, hex: false), "20")
            t.equal(SysColorFormat.format(RGBA(r: 300, g: -5, b: 0.6, a: 0), display: .all, hex: false), "255,0,1,0")
            for name in ["Accent", "Aero", "Desktop", "Window", "WindowText", "Highlight", "HightlightText", "Menu",
                         "ButtonFace", "3DLight", "GrayText", "Hyperlink", "WIN8", "DWM_COLOR"] {
                t.check(SysColorFormat.color(name) != nil, "\(name) maps to a macOS color")
            }
            t.check(SysColorFormat.color("NoSuchColor") == nil)
            t.check(SysColorFormat.resolved(.controlAccentColor) != nil)

            let (skin, _) = try bareSkin(t)
            let accent = SysColorMeasure(name: "A", section: section("A", [("DisplayType", "RGB"), ("Hex", "1")]),
                                         skin: skin, type: "syscolor")
            accent.readOptions()
            t.equal(accent.computeValue(), 1)
            t.equal(accent.pluginString?.count, 6)
            let missing = SysColorMeasure(name: "B", section: section("B", [("ColorType", "Bogus")]), skin: skin,
                                          type: "syscolor")
            missing.readOptions()
            t.equal(missing.computeValue(), -1)

            let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
            func window(_ pid: Int32, _ layer: Int, _ r: CGRect) -> [String: Any] {
                [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer),
                 kCGWindowBounds as String: r.dictionaryRepresentation]
            }
            let menuBar = window(1, 25, CGRect(x: 0, y: 0, width: 1440, height: 24))
            t.check(FrontmostAppInfo.isFullScreen(windows: [menuBar, window(7, 0, display)], pid: 7, display: display))
            t.check(!FrontmostAppInfo.isFullScreen(windows: [window(7, 0, CGRect(x: 0, y: 25, width: 1440, height: 875))],
                                                   pid: 7, display: display), "maximized is not full screen")
            t.check(!FrontmostAppInfo.isFullScreen(windows: [window(8, 0, display)], pid: 7, display: display))
            t.check(!FrontmostAppInfo.isFullScreen(windows: [window(7, 0, CGRect(x: 10, y: 10, width: 50, height: 50)),
                                                             window(7, 0, display)], pid: 7, display: display),
                    "only the front window counts")
            t.check(!FrontmostAppInfo.isFullScreen(windows: [], pid: 0, display: display))

            let fs = IsFullScreenMeasure(name: "F", section: section("F", []), skin: skin, type: "isfullscreen")
            _ = fs.computeValue()
            AppSelfTest.spin(timeout: 3) { !FrontmostAppInfo.shared.info.processName.isEmpty }
            let v = fs.computeValue()
            t.check(v == 0 || v == 1)
            t.check(fs.pluginString != nil)
            let title = ActiveTitleMeasure(name: "T", section: section("T", []), skin: skin, type: "getactivetitle")
            t.equal(title.computeValue(), Double(title.pluginString?.count ?? -1), "number = title length")
        }
    }

    // MARK: Test skins

    static func testSkinTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI test skins") {
            guard let root = Paths.repositoryFolder("TestSkins")?.appendingPathComponent("MediaUI") else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            let files = ["NowPlaying/NowPlaying.ini", "ITunes/ITunes.ini", "WiFi/WiFi.ini", "InputText/InputText.ini",
                         "Glass/Glass.ini", "Desktop/Desktop.ini"]
            for file in files {
                let url = root.appendingPathComponent(file)
                let host = RenderHost()
                let skin = Skin(config: "MediaUI\\" + file.split(separator: "/")[0], fileURL: url,
                                skinsDirectory: root.deletingLastPathComponent(), system: SystemMonitor.shared, host: host)
                do {
                    try skin.load()
                } catch {
                    t.check(false, "\(file) loads: \(error)")
                    continue
                }
                for m in skin.measures {
                    let raw = m.rawOption("Plugin").map { MeasureRegistry.normalizedPluginName($0) } ?? m.type
                    let known = MeasureRegistry.plugin(named: raw) != nil || MeasureRegistry.measure(named: raw) != nil
                        || ["calc", "string"].contains(m.type)
                    t.check(known, "\(file): [\(m.name)] (\(raw)) has an implementation")
                }
                // With the registry wired into Skin.makeMeasure, the measures are the plugin classes.
                let wired = skin.measures.contains { $0 is MediaUIMeasure }
                if !wired { print("    (\(file): Skin.makeMeasure does not consult MeasureRegistry yet)") }
                skin.close()
            }
        }
    }

    // MARK: Skins through the engine

    /// Runs when `Skin.makeMeasure` consults `MeasureRegistry` (after the lead wires it); string checks run when the
    /// plugin strings reach `Measure.rawString`.
    static func wiredSkinTests(_ t: AppTestRunner) {
        t.suite("App: MediaUI skins through the engine") {
            guard let root = Paths.repositoryFolder("TestSkins")?.appendingPathComponent("MediaUI") else {
                print("    (skipped: TestSkins not found)")
                return
            }
            func load(_ file: String) throws -> (Skin, RenderHost)? {
                let host = RenderHost()
                let url = root.appendingPathComponent(file)
                let skin = Skin(config: "MediaUI\\" + file.split(separator: "/")[0], fileURL: url,
                                skinsDirectory: root.deletingLastPathComponent(), system: SystemMonitor.shared, host: host)
                try skin.load()
                guard skin.measures.contains(where: { $0 is MediaUIMeasure }) else {
                    print("    (skipped: Skin.makeMeasure does not consult MeasureRegistry yet)")
                    return nil
                }
                return (skin, host)
            }
            guard let (skin, _) = try load("NowPlaying/NowPlaying.ini") else { return }
            let backend = DemoNowPlayingBackend()
            let center = NowPlayingCenter(backend: backend)
            center.forceLive = true
            center.interval = 3600
            center.clock = { 0 }
            backend.statuses[.music]?.position = 83
            let savedRoot = MediaUICache.root
            MediaUICache.root = t.temporaryDirectory("wired-covers")
            defer { MediaUICache.root = savedRoot }
            inline([center.worker]) {
                for m in skin.measures { (m as? NowPlayingMeasure)?.center = center }
                skin.update()
                skin.update()
                guard let title = skin.measure(named: "MeasurePlayer") as? NowPlayingMeasure,
                      let artist = skin.measure(named: "MeasureArtist") as? NowPlayingMeasure else {
                    t.check(false, "NowPlaying measures")
                    return
                }
                t.check(artist.mainMeasure === title, "PlayerName=[MeasurePlayer]")
                t.equal(title.pluginString, "Rain on Glass")
                t.equal(artist.pluginString, "Deskset Ensemble")
                t.equal(skin.measure(named: "MeasureProgress")?.value ?? -1, 83.0 / 245 * 100, "progress")
                t.equal(skin.measure(named: "MeasureDuration")?.value, 245)
                t.equal(skin.measure(named: "MeasureDuration")?.maxValue, 245)
                t.equal(skin.measure(named: "MeasureShuffle")?.value, 1, "Plugin=Plugins\\NowPlaying.dll form")
                if title.rawString == title.pluginString {
                    t.equal(skin.measure(named: "MeasureState")?.stringValue, "Playing", "Substitute on the state")
                    t.equal(skin.measure(named: "MeasurePosition")?.stringValue, "1:23", "DisableLeadingZero of the main measure")
                    let time = skin.meter(named: "MeterTime") as? StringMeter
                    t.equal(time?.text, "1:23 / 4:05")
                } else {
                    print("    (plugin strings do not reach Measure.rawString yet: string checks skipped)")
                }
                // TrackChangeAction and commands through bangs.
                backend.statuses[.music]?.trackID = "OTHER"
                center.poll()
                skin.update()
                t.equal(skin.variable("Changes"), "1", "TrackChangeAction")
                skin.execute("[!CommandMeasure MeasurePlayer \"SetVolume +5\"]", from: nil)
                t.equal(backend.performed.last?.0, .setVolume(75))
                skin.execute("[!CommandMeasure MeasureArtist \"Next\"]", from: nil)
                t.equal(backend.performed.last?.0, .next, "commands on a child measure")
            }
            skin.close()

            guard let (input, _) = try load("InputText/InputText.ini") else { return }
            let fake = FakePrompt()
            InputTextMeasure.promptFactory = { _ in fake }
            defer { InputTextMeasure.promptFactory = nil }
            input.update()
            fake.answers = ["hello there"]
            input.execute("[!CommandMeasure MeasureInput \"ExecuteBatch 1\"]", from: nil)
            t.equal(input.variable("Note"), "hello there")
            t.equal(fake.shown.first?.fontFace, "Georgia")
            t.equal(fake.shown.first?.defaultValue, "Click here to write a note")
            fake.answers = ["x", "y"]
            input.execute("[!CommandMeasure MeasureInput \"ExecuteBatch 2-3\"]", from: nil)
            t.equal(input.variable("First"), "x")
            t.equal(input.variable("Second"), "y")
            if (input.measure(named: "MeasureInput") as? InputTextMeasure)?.rawString == "y" {
                t.equal(input.variable("Both"), "y and first", "[MeasureInput] is the latest input")
            }
            fake.answers = ["12ab"]
            input.execute("[!CommandMeasure MeasureInput \"ExecuteBatch 4\"]", from: nil)
            t.check(fake.shown.last?.inputNumber == true && fake.shown.last?.inputLimit == 4)
            t.equal(fake.shown.last?.align, .right)
            fake.answers = [nil]
            input.execute("[!CommandMeasure MeasureInput \"ExecuteBatch 5\"]", from: nil)
            t.equal(input.variable("Dismissed"), "1", "OnDismissAction")
            t.check(fake.shown.last?.password == true)
            t.equal(fake.shown.last?.y, 106, "Y=([Secret:Y]): section variables in overrides")
            input.close()
        }
    }
}
