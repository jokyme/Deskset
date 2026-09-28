import AppKit
import DesksetCore

/// `--render --data`: what a skin reads about the Mac comes from data behind each service's own protocol, so a render
/// with `--clock` and `--seed` is the same on every run; the services are the app's own again afterwards.
enum RenderDataSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: render: --data stands in for the Mac, the same on every run") {
            guard let fixtures = Paths.repositoryFolder("TestSkins")?.appendingPathComponent("Runtime/Data"),
                  let weather = Paths.repositoryFolder("TestSkins")?
                    .appendingPathComponent("Plugins/@Resources/Weather/metno-complete-oslo.json") else {
                t.check(false, "the fixtures in TestSkins/Runtime/Data")
                return
            }
            let skins = t.temporaryDirectory("data-render").appendingPathComponent("Skins")
            let dir = skins.appendingPathComponent("Data/Render")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // A desktop picture of three solid bands of different widths: Chameleon's largest color is unambiguous.
            // (The shared fixture has color bins of equal size, and Chameleon orders those by dictionary order, which
            // differs from one dictionary to the next: its Background1 would change between the two renders.)
            let desktopPicture = dir.appendingPathComponent("desktop.png")
            try writeBands(to: desktopPicture, [(50, 200, 60, 40), (30, 40, 90, 200), (10, 240, 240, 240)], height: 60)
            try """
            [Rainmeter]
            Update=1000
            DynamicWindowSize=1
            [CPU]
            Measure=CPU
            [Top]
            Measure=Plugin
            Plugin=UsageMonitor
            Alias=CPU
            Index=1
            [Temp]
            Measure=Plugin
            Plugin=MacSensors
            Sensor=cpu
            [Thermal]
            Measure=Plugin
            Plugin=MacSensors
            Sensor=thermal
            [Battery]
            Measure=Plugin
            Plugin=PowerPlugin
            PowerState=Percent
            [Title]
            Measure=NowPlaying
            PlayerName=Music
            PlayerType=Title
            [Parent]
            Measure=Plugin
            Plugin=AudioLevel
            Port=Output
            FFTSize=1024
            Bands=4
            [Level]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=Parent
            Type=RMS
            Channel=L
            [Band]
            Measure=Plugin
            Plugin=AudioLevel
            Parent=Parent
            Type=Band
            Channel=R
            BandIdx=1
            [Weather]
            Measure=Plugin
            Plugin=MacWeather
            Location=auto
            Type=Temperature
            [SSID]
            Measure=Plugin
            Plugin=WiFiStatus
            WiFiInfoType=SSID
            [Desk]
            Measure=Plugin
            Plugin=Chameleon
            Type=Desktop
            [DeskColor]
            Measure=Plugin
            Plugin=Chameleon
            Parent=Desk
            Color=Background1
            [Run]
            Measure=Plugin
            Plugin=RunCommand
            Parameter=echo from the Mac
            [Start]
            Measure=Calc
            Formula=1
            UpdateDivider=-1
            OnUpdateAction=[!CommandMeasure Run "Run"]
            [Text]
            Meter=String
            MeasureName=CPU
            MeasureName2=Title
            MeasureName3=SSID
            Text=%1 %2 %3
            FontSize=10
            FontColor=0,0,0,255
            AntiAlias=1
            """.write(to: dir.appendingPathComponent("Render.ini"), atomically: true, encoding: .utf8)
            let data = """
            {"system": {"frames": [
                {"cpu": [30, 20, 40], "uptime": 100,
                 "processes": [{"name": "Music", "pid": 20, "cpu": 12}, {"name": "Safari", "pid": 10, "cpu": 8}]},
                {"cpu": [45, 40, 50]},
                {"cpu": [60, 50, 70],
                 "processes": [{"name": "Music", "pid": 20, "cpu": 4}, {"name": "Safari", "pid": 10, "cpu": 40}]}]},
             "battery": {"level": 64},
             "sensors": {"cpu": 48.5, "thermal": 2},
             "nowPlaying": {"title": "Rain on Glass", "artist": "Deskset Ensemble", "duration": 245, "position": 10,
                            "cover": "\(fixtures.appendingPathComponent("cover.png").path)"},
             "audio": {"frames": [{"rms": [0.5, 0.25], "peak": 0.8, "bands": [[0.1, 0.2], [0.3, 0.4]]},
                                  {"rms": [0.6, 0.3], "peak": 0.9, "bands": [[0.1, 0.2], [0.35, 0.45]]},
                                  {"rms": [0.7, 0.35], "peak": 1.0, "bands": [[0.1, 0.2], [0.3, 0.6]]}]},
             "weather": "\(weather.path)",
             "wifi": {"ssid": "Deskset Test", "rssi": -52},
             "desktopImage": "\(desktopPicture.path)",
             "programs": {"echo from the Mac": "from the data"}}
            """
            let out = t.temporaryDirectory("data-render-out")
            func render(_ name: String) -> (status: Int32, png: Data?, state: JSONValue?) {
                let png = out.appendingPathComponent(name + ".png"), state = out.appendingPathComponent(name + ".json")
                let status = RenderCommand.run(["Deskset", "--render", dir.appendingPathComponent("Render.ini").path,
                                                "--out", png.path, "--updates", "3", "--scale", "1",
                                                "--clock", "2026-09-26T12:00:00Z", "--time-zone", "Europe/Oslo",
                                                "--seed", "7", "--data", data, "--state", state.path])
                return (status, try? Data(contentsOf: png),
                        (try? Data(contentsOf: state)).flatMap { try? JSONValue.parse($0) })
            }
            let first = render("first"), second = render("second")
            t.equal(first.status, 0)
            t.check(first.png != nil && first.png == second.png, "the same image on every run")
            t.check(first.state != nil && first.state == second.state,
                    "the same state on every run; measures that differ: \(differingMeasures(first.state, second.state))")
            var values: [String: (Double, String)] = [:]
            for m in first.state?["measures"]?.array ?? [] {
                guard let name = m["name"]?.string else { continue }
                values[name] = (m["value"]?.number ?? .nan, m["string"]?.string ?? "")
            }
            t.equal(values["CPU"]?.0, 60, "the third update sees the third frame")
            t.equal(values["Top"]?.1, "Safari", "processes: the frame's busiest")
            t.close(values["Top"]?.0 ?? 0, 40, accuracy: 1e-6)
            t.equal(values["Temp"]?.0, 48.5)
            t.equal(values["Thermal"]?.1, "Serious")
            t.equal(values["Battery"]?.0, 64)
            t.equal(values["Title"]?.1, "Rain on Glass", "NowPlaying: the data's track")
            t.close(values["Level"]?.0 ?? 0, 0.7, accuracy: 1e-6, "AudioLevel: the third frame's left RMS")
            t.close(values["Band"]?.0 ?? 0, 0.6, accuracy: 1e-6, "AudioLevel: the right channel's second band")
            t.close(values["Weather"]?.0 ?? 0, 16.8, accuracy: 1e-6, "MacWeather: the fixture's forecast at 14:00 in Oslo")
            t.equal(values["SSID"]?.1, "Deskset Test")
            t.equal(values["Desk"]?.1, desktopPicture.path)
            t.equal(values["DeskColor"]?.1, "C83C28", "Chameleon sampled the given picture: its widest band")
            t.check((values["Run"]?.1 ?? "").contains("from the data"), "RunCommand: the data's output: \(values["Run"]?.1 ?? "")")

            // The app's own services afterwards.
            t.check(NowPlayingCenter.current === NowPlayingCenter.shared)
            t.check(AudioLevelMeasure.sharedEngine() === AudioCaptureEngine.shared)
            t.check(WiFiStatusMeasure.sharedCenter() === WiFiCenter.shared)
            t.check(ChameleonMeasure.desktopSource is ScreenDesktopPicture)
            t.check(WeatherService.shared.environment.transport == nil, "the preview again: no transport")

            // A mistake in the data stops the render.
            let bad = RenderCommand.run(["Deskset", "--render", dir.appendingPathComponent("Render.ini").path,
                                         "--out", out.appendingPathComponent("bad.png").path,
                                         "--data", #"{"system": {"cpu": "high"}}"#])
            t.equal(bad, 1)
        }

        t.suite("App: render: covers go to the render's own cache, never the app's") {
            // A cover the running app shows: writing a new cover deletes the player's other covers in its folder, so
            // a render that wrote into the app's cache would take the desktop skin's album art away.
            guard let fixtures = Paths.repositoryFolder("TestSkins")?.appendingPathComponent("Runtime/Data") else {
                t.check(false, "the fixtures in TestSkins/Runtime/Data")
                return
            }
            let appCache = t.temporaryDirectory("app-cache")
            let live = appCache.appendingPathComponent("NowPlaying/cover-music-LIVE.png")
            try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: fixtures.appendingPathComponent("cover.png")).write(to: live)
            let savedRoot = MediaUICache.root
            MediaUICache.root = appCache
            defer { MediaUICache.root = savedRoot }

            let dir = t.temporaryDirectory("cover-render").appendingPathComponent("Skins/Cover/Render")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try """
            [Rainmeter]
            Update=1000
            [Cover]
            Measure=NowPlaying
            PlayerName=Music
            PlayerType=Cover
            [Art]
            Meter=Image
            MeasureName=Cover
            W=40
            H=40
            """.write(to: dir.appendingPathComponent("Render.ini"), atomically: true, encoding: .utf8)
            let data = """
            {"nowPlaying": {"title": "Rain on Glass", "artist": "Deskset Ensemble", "duration": 245,
                            "cover": "\(fixtures.appendingPathComponent("cover.png").path)"}}
            """
            let out = t.temporaryDirectory("cover-render-out")
            let settings = t.temporaryDirectory("cover-render-settings")
            let savedSettings = SkinController.settingsPath
            SkinController.settingsPath = settings.path + "/"
            defer { SkinController.settingsPath = savedSettings }
            let state = out.appendingPathComponent("state.json")
            let status = RenderCommand.run(["Deskset", "--render", dir.appendingPathComponent("Render.ini").path,
                                            "--out", out.appendingPathComponent("cover.png").path, "--updates", "3",
                                            "--clock", "2026-09-26T12:00:00Z", "--seed", "7", "--data", data,
                                            "--state", state.path])
            t.equal(status, 0)
            let cover = (try? Data(contentsOf: state)).flatMap { try? JSONValue.parse($0) }?["measures"]?.array?
                .first { $0["name"]?.string == "Cover" }?["string"]?.string ?? ""
            t.check(cover.hasPrefix(settings.path + "/Caches/NowPlaying/cover-music-"),
                    "the cover is in the render's settings folder: \(cover)")
            t.check(FileManager.default.fileExists(atPath: cover))
            t.equal(try FileManager.default.contentsOfDirectory(atPath: live.deletingLastPathComponent().path),
                    ["cover-music-LIVE.png"], "the app's cover is still there, and nothing was added")
            t.equal(MediaUICache.root, appCache, "the app's cache folder again after the render")
        }

        t.suite("App: render: the data's fakes") {
            // Wi-Fi.
            let wifi = FixedWiFi(.value(SkinInputData.WiFi(current: SkinInputData.WiFiNetwork(ssid: "Home", rssi: -60),
                                                           networks: [SkinInputData.WiFiNetwork(ssid: "Cafe")])))
            t.equal(wifi.info(interface: 0)?.ssid, "Home")
            t.equal(wifi.info(interface: 1)?.ssid, nil)
            t.equal(wifi.networks(interface: 0).map(\.ssid), ["Cafe"])
            t.check(FixedWiFi(.none).info(interface: 0) == nil, "null: no Wi-Fi interface")

            // NowPlaying.
            let np = DemoNowPlayingBackend(fixture: .value(SkinInputData.NowPlaying(player: "spotify", state: 2,
                                                                                    title: "T", repeatMode: 1)))
            t.check(np.isRunning(.spotify) && !np.isRunning(.music))
            if case .ok(let status) = np.status(.spotify) {
                t.equal(status.state, 2)
                t.equal(status.repeatMode, .one)
            } else {
                t.check(false, "Spotify plays")
            }
            t.equal(np.track(.spotify)?.title, "T")
            t.check(np.artwork(.spotify, track: NowPlayingTrack()) == nil, "no cover given: no artwork")
            t.check(!DemoNowPlayingBackend(fixture: .none).isRunning(.music), "null: every player closed")

            // Audio levels.
            let audio = ScriptedAudioLevels(.value(SkinInputData.Audio(frames: [
                SkinInputData.AudioFrame(rms: [0.5, 0.25], peak: [0.8, 0.4]),
                SkinInputData.AudioFrame(rms: [0.1, 0.2], peak: [0.3, 0.3], bands: [[0.9]]),
            ])))
            var settings = AudioAnalysisSettings()
            settings.fftSize = 256
            settings.bands = 2
            let analyzer = AudioAnalyzer(settings: settings)
            audio.subscribe(analyzer, to: AudioSourceKey(kind: .output, deviceID: nil))
            t.close(analyzer.rms(.index(0)), 0.5, accuracy: 1e-9)
            t.close(analyzer.rms(.sum), ((0.25 + 0.0625) / 2).squareRoot(), accuracy: 1e-9, "Sum: the mean square")
            t.close(analyzer.peak(.index(1)), 0.4, accuracy: 1e-9)
            audio.advance()
            t.close(analyzer.rms(.index(1)), 0.2, accuracy: 1e-9)
            t.close(analyzer.band(.index(0), index: 0), 0.9, accuracy: 1e-6, "one list of bands is every channel's")
            t.close(analyzer.band(.index(1), index: 1), 0, accuracy: 1e-9, "bands the data leaves out are 0")
            audio.advance()
            t.close(analyzer.rms(.index(0)), 0.1, accuracy: 1e-9, "the last frame stays")
            t.check(audio.status(for: AudioSourceKey(kind: .input, deviceID: nil)).running)
            t.check(audio.capturesNothing)
            let silent = ScriptedAudioLevels(.none)
            t.check(!silent.status(for: AudioSourceKey(kind: .output, deviceID: nil)).running, "null: no audio device")

            // The desktop picture.
            let none = FixedDesktopPicture(nil)
            t.check(none.desktop(of: nil) == nil && none.isFixture)
            if let desktop = Paths.repositoryFolder("TestSkins")?.appendingPathComponent("Runtime/Data/desktop.png") {
                let fixed = FixedDesktopPicture(desktop.path)
                t.equal(fixed.desktop(of: nil)?.picture, desktop.path)
                t.equal(fixed.desktop(of: nil)?.frame.size, CGSize(width: 640, height: 400), "the picture's own shape")
            }
            t.check(!ScreenDesktopPicture().isFixture)
        }
    }

    /// Writes a PNG of solid vertical bands, left to right: (width, red, green, blue), in sRGB.
    static func writeBands(to url: URL, _ bands: [(width: Int, r: Int, g: Int, b: Int)], height: Int) throws {
        let width = bands.reduce(0) { $0 + $1.width }
        guard let ctx = Images.bitmapContext(width: width, height: height) else { throw CocoaError(.featureUnsupported) }
        var x = 0
        for band in bands {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(band.r) / 255, green: CGFloat(band.g) / 255,
                                     blue: CGFloat(band.b) / 255, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: band.width, height: height))
            x += band.width
        }
        guard let image = ctx.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The names of the measures whose entries differ between two `--state` files (for a failure message).
    static func differingMeasures(_ a: JSONValue?, _ b: JSONValue?) -> String {
        func byName(_ state: JSONValue?) -> [String: JSONValue] {
            var result: [String: JSONValue] = [:]
            for m in state?["measures"]?.array ?? [] {
                if let name = m["name"]?.string { result[name] = m }
            }
            return result
        }
        let x = byName(a), y = byName(b)
        let names = Set(x.keys).union(y.keys).filter { x[$0] != y[$0] }.sorted()
        return names.isEmpty ? "none (the meters or variables differ)" : names.joined(separator: ", ")
    }
}
