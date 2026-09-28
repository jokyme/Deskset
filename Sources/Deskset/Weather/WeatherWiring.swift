import AppKit
import DesksetCore

/// Connects the weather service (DesksetCore, `WeatherService`) to the app (docs/compat/weather.md): which skins may
/// reach the network, the real transport, the cache folder, the place table, this Mac's location, the unit settings,
/// sleep and wake. Installed by `AppController` when the menu bar app launches — never in the command-line modes or
/// the self-tests, which keep the offline core default (or a preview without network, `installPreview`).
enum WeatherWiring {
    /// `defaults write app.deskset.Deskset WeatherEnabled -bool NO` turns weather downloads off (skins show
    /// "Weather is turned off"); read at every use.
    static let enabledKey = "WeatherEnabled"
    /// `defaults write app.deskset.Deskset WeatherDebug -bool YES`: rounded coordinates of places written in skins
    /// (never this Mac's location) and timings in the log.
    static let debugKey = "WeatherDebug"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// `Deskset/<version> (+https://github.com/jokyme/Deskset)`; `Deskset/dev` outside a bundled app.
    static var userAgent: String {
        METNorway.userAgent(version: Paths.isAppBundle
                            ? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String : nil)
    }

    /// Skins in skin windows are live, and so is the Studio's own instance of the widget it edits (`LiveSkinHost`);
    /// previews, thumbnails, `--render` and the Manage window's dry runs are not.
    static func isLive(_ skin: Skin) -> Bool { skin.host is LiveSkinHost }

    /// `Units=Auto`: the macOS Temperature setting (System Settings ▸ General ▸ Language & Region), else the region's
    /// unit for weather — the same answer as `#MACTEMPERATUREUNIT#` (`MacRegionalSettings.temperatureUnit`); the other
    /// quantities by the region's measurement system.
    static func systemUnits(defaults: UserDefaults = .standard, locale: Locale = .current) -> WeatherUnits {
        var units = WeatherUnits.automatic(temperatureSetting: nil, measurementSystem: locale.measurementSystem.identifier)
        units.temperature = MacRegionalSettings.temperatureUnit(setting: defaults.string(forKey: "AppleTemperatureUnit"),
                                                                locale: locale)
        return units
    }

    /// `Units=Auto` as skins get it (asked for at every weather value): the region's measurement system, with the
    /// temperature unit skins see (`#MACTEMPERATUREUNIT#`, kept by `MacRegional`, which `--render` fixes).
    static func skinUnits(locale: Locale = .current) -> WeatherUnits {
        var units = WeatherUnits.automatic(temperatureSetting: nil, measurementSystem: locale.measurementSystem.identifier)
        units.temperature = MacRegional.current.temperatureUnit
        return units
    }

    /// The live environment of the menu bar app.
    static func liveEnvironment() -> WeatherEnvironment {
        var env = WeatherEnvironment()
        env.isLive = isLive
        env.isEnabled = { isEnabled }
        env.transport = URLSessionWeatherTransport()
        env.userAgent = userAgent
        env.cacheDirectory = MediaUICache.folder("Weather")
        env.placesTable = Paths.placesTable
        env.deviceLocation = LocationCenter.shared
        env.preferredUnits = { skinUnits() }
        env.uses24HourClock = { MacRegional.current.clockHours == 24 }
        env.debug = UserDefaults.standard.bool(forKey: debugKey)
        env.log = { Log.write($0) }
        return env
    }

    /// No network and no location, but place names resolve (sun times work): `--render` and other previews. Lookups
    /// finish before the skin's update goes on, so images do not depend on how fast the place table loads.
    /// `demo`: synthetic forecasts (`DESKSET_WEATHER_DEMO=1`, clock from `DESKSET_WEATHER_DEMO_NOW`, ISO 8601).
    static func previewEnvironment(demo: Bool = demoRequested, demoNow: Date? = demoClock) -> WeatherEnvironment {
        var env = WeatherEnvironment()
        env.placesTable = Paths.placesTable
        env.waitsForLookups = true
        env.preferredUnits = { skinUnits() }
        env.uses24HourClock = { MacRegional.current.clockHours == 24 }
        env.demo = demo
        env.demoNow = demoNow
        if let demoNow { env.clock = VirtualWeatherClock(now: demoNow) }
        return env
    }

    /// `--render --data`'s `weather`: the render's skin is live, and its requests get the given MET Norway response
    /// (or fail as offline) through `FixtureWeatherTransport`; `Location=auto` is the forecast's own point, a given
    /// point, or none; `Location=timezone` is the city of `timeZone` (the skin's). Place names resolve from the
    /// bundled table before the update goes on; nothing is cached on disk, nothing reaches the network or asks for
    /// Location Services. `clock`: the service's clock (the virtual one of a render with `--clock`).
    static func fixtureEnvironment(_ weather: SkinInputData.Given<SkinInputData.Weather>,
                                   timeZone: @escaping () -> TimeZone,
                                   clock: WeatherClock? = nil) -> WeatherEnvironment {
        var env = previewEnvironment(demo: false, demoNow: nil)
        env.isLive = { _ in true }
        let w = weather.value
        env.transport = FixtureWeatherTransport(body: w?.forecast, status: w?.status ?? 200)
        let point: RoundedCoordinate?
        switch w?.location ?? .none {
        case .forecast: point = w?.forecastPoint.map { RoundedCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        case .coordinate(let lat, let lon): point = RoundedCoordinate(latitude: lat, longitude: lon)
        case .none: point = nil
        }
        env.deviceLocation = FixedDeviceLocation(point)
        env.localTimeZone = timeZone
        env.random = { 0 }
        if let clock { env.clock = clock }
        return env
    }

    static var demoRequested: Bool { ProcessInfo.processInfo.environment["DESKSET_WEATHER_DEMO"] == "1" }

    static var demoClock: Date? {
        ProcessInfo.processInfo.environment["DESKSET_WEATHER_DEMO_NOW"].flatMap(METNorway.parseISO8601)
    }

    // MARK: Launch

    private static var observers: [NSObjectProtocol] = []

    /// At launch (`AppController.applicationDidFinishLaunching`).
    static func install() {
        WeatherService.install(liveEnvironment())
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            WeatherService.shared.systemWillSleep()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            WeatherService.shared.systemDidWake()
        })
    }

    /// `--render` and the other command-line previews.
    static func installPreview() {
        WeatherService.install(previewEnvironment())
    }

    // MARK: Skin menu

    /// Menu items for a skin that shows MET Norway's data (any skin with a MacWeather measure, so third-party skins
    /// credit the source too): "Weather: Based on data from MET Norway ↗" (opens api.met.no) and "Updated 12:05".
    static func menuItems(for skin: Skin, target: AnyObject, action: Selector) -> [NSMenuItem] {
        let info = MacWeatherMeasure.attributionInfo(for: skin)
        guard info.uses else { return [] }
        let credit = NSMenuItem(title: "Weather: \(METNorway.attribution) ↗", action: action, keyEquivalent: "")
        credit.target = target
        credit.representedObject = METNorway.attributionURL
        credit.toolTip = "Opens api.met.no. Weather data from MET Norway under CC BY 4.0."
        var items = [credit]
        if let updated = info.updated {
            let line = NSMenuItem(title: "Updated \(updated)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            items.append(line)
        }
        return items
    }

    /// The About panel's credits line.
    static let credits = "Weather data: MET Norway (CC BY 4.0). Place names: GeoNames (CC BY 4.0)."
}
