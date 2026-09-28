import AppKit
import DesksetCore

/// `Deskset --render --data`: puts the fakes of `SkinInputData` in place for one render and takes them away after
/// (the self-tests render in the same process as other suites). Each fake stands behind the protocol its service
/// already has:
///
///   system, battery, sensors, desktopImage  `ScriptedSystemData` as the skin's `SystemDataSource`
///   nowPlaying                               a NowPlaying center of the render's own with a fixture backend
///   audio                                    `ScriptedAudioLevels` as the AudioLevel measures' engine
///   weather                                  the weather service with `FixtureWeatherTransport`
///   wifi                                     `FixedWiFi` as the WiFiStatus measures' reader
///   desktopImage                             `FixedDesktopPicture` as Chameleon's desktop
///   programs                                 `RecordingSideEffects` as the skin's side effects (nothing runs)
///
/// Frames (`system`, `audio`) move on right before every update after the first: update i sees frame i. Main thread.
final class RenderData {
    let data: SkinInputData
    /// The skin's system readings (nil when the data gives none of them).
    private(set) var system: ScriptedSystemData?
    private var audio: ScriptedAudioLevels?
    /// The skin's side effects when the data gives its programs: what it started and wrote.
    private(set) var recording: RecordingSideEffects?
    private var restores: [() -> Void] = []

    init(_ data: SkinInputData) {
        self.data = data
    }

    /// The system data source to give the skin: `base` behind the data's system readings, battery, sensors and
    /// desktop picture (`base` itself when the data gives none of them).
    func systemSource(base: SystemDataSource) -> SystemDataSource {
        guard data.system != nil || data.battery != nil || data.sensors != nil || data.thermalState != nil
            || data.desktopImage != nil else { return base }
        let scripted = ScriptedSystemData(base: base, data: data)
        system = scripted
        return scripted
    }

    /// Puts the other fakes in place, after the skin is made and its clock set and before it loads (the weather's
    /// `Location=timezone` is the city of the skin's time zone). `virtual`: the render's virtual time, if any.
    func install(for skin: Skin, virtual: VirtualTimeExecutor?) {
        let clock = skin.skinClock
        if data.programs != nil {
            // Programs only recorded: each exits at once with the data's output. The skin's own writes
            // (!WriteKeyValue…) go to a copy of its files, where it reads them back.
            let effects = RecordingSideEffects(skinsDirectory: skin.skinsDirectory)
            let data = self.data
            effects.programOutput = { Data(data.programOutput(for: $0).utf8) }
            skin.sideEffects = effects
            if skin.sourceProvider == nil { skin.sourceProvider = effects }
            recording = effects
            virtual?.background.setFake(.fixture, for: .runCommandProcess)
        }
        if let desktop = data.desktopImage {
            let saved = ChameleonMeasure.desktopSource
            ChameleonMeasure.desktopSource = FixedDesktopPicture(desktop.value)
            restores.append { ChameleonMeasure.desktopSource = saved }
        }
        if let nowPlaying = data.nowPlaying {
            let center = NowPlayingCenter(backend: DemoNowPlayingBackend(fixture: nowPlaying))
            center.forceLive = true
            if let virtual { center.clock = { virtual.uptime } }
            NowPlayingCenter.current = center
            restores.append { NowPlayingCenter.current = .shared }
        }
        if let audio = data.audio {
            let levels = ScriptedAudioLevels(audio)
            self.audio = levels
            let saved = AudioLevelMeasure.sharedEngine
            AudioLevelMeasure.sharedEngine = { levels }
            restores.append { AudioLevelMeasure.sharedEngine = saved }
        }
        if let weather = data.weather {
            let skinClock = clock
            var clock: VirtualWeatherClock?
            if let virtual {
                let c = VirtualWeatherClock(now: virtual.wallClock)
                clock = c
                // The service's clock follows virtual time: what it scheduled runs when that time comes.
                virtual.background.addSettleHook { c.advance(to: virtual.wallClock) }
            }
            WeatherService.install(WeatherWiring.fixtureEnvironment(weather, timeZone: { skinClock.timeZone() },
                                                                    clock: clock))
            restores.append { WeatherWiring.installPreview() }
        }
        if let wifi = data.wifi {
            let fixed = FixedWiFi(wifi)
            let saved = WiFiStatusMeasure.sharedCenter
            WiFiStatusMeasure.sharedCenter = { fixed }
            restores.append { WiFiStatusMeasure.sharedCenter = saved }
        }
    }

    /// The next frame of the system readings and the audio levels (before every update after the first).
    func advance() {
        system?.advance()
        audio?.advance()
    }

    /// Takes the fakes away again (the services the app and later suites use).
    func restore() {
        for r in restores.reversed() { r() }
        restores = []
    }
}
