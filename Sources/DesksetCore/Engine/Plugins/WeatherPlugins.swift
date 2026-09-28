import Foundation

// Plugin=MacWeather and Plugin=MacSun: Deskset extensions (no Rainmeter counterpart; Windows skins scrape weather
// sites with WebParser). Forecasts come from MET Norway through the shared `WeatherService`; sun and moon are computed
// on the Mac. Options, Types and every judgment call: docs/compat/weather.md.

/// A resolved `Location=`.
struct WeatherResolvedLocation {
    var status: WeatherStatus = .noLocation
    var coordinate: RoundedCoordinate?
    var name = ""
    var detail = ""
    var country = ""
    var countryCode = ""
    /// The place's own time zone (nil: the Mac's).
    var zone: TimeZone?
    var fromDevice = false
    /// Where the place comes from (`Type=LocationSource`).
    var source = WeatherLocationSource.none
    /// A compatibility note for the skin (place not found, Location Services off…).
    var note: String?
    /// A line for the skin's log, once (no city for this Mac's time zone).
    var log: String?
}

enum WeatherLocationResolver {
    static let unavailableSearchNote = "Weather: place search is unavailable; use latitude,longitude such as 59.91,10.75"

    /// Resolves a `Location=` with the service's offline lookups. `live`: this Mac's location may be asked for (skins
    /// in skin windows only; never in previews). `localTimeZone`: this Mac's zone, for `Location=TimeZone` (see
    /// `localTimeZone(_:skinClock:)`).
    static func resolve(_ spec: WeatherLocationSpec, service: WeatherService, subscription: WeatherSubscription?,
                        live: Bool, locate: Bool = false, localTimeZone: TimeZone) -> WeatherResolvedLocation {
        var r = WeatherResolvedLocation()
        r.source = WeatherLocationSource(spec)
        switch spec {
        case .none:
            r.status = .noLocation
        case .invalid(let why):
            r.status = .placeNotFound
            r.name = ""
            r.note = "Weather: \(why)"
        case .place(let query):
            switch service.lookUpPlace(query, for: subscription) {
            case .pending:
                r.status = .loading
            case .notFound:
                r.status = .placeNotFound
                r.name = query
                r.note = "Weather: can't find the place “\(query)”. Try a larger town nearby, or latitude,longitude "
                    + "such as 59.91,10.75"
            case .unavailable:
                r.status = .placeNotFound
                r.name = query
                r.note = unavailableSearchNote
            case .found(let m):
                r.status = .ready
                r.coordinate = m.place.coordinate
                r.name = m.displayName
                r.detail = m.detail
                r.country = m.countryName
                r.countryCode = m.place.country
                r.zone = TimeZone(identifier: m.place.timeZone)
            }
        case .coordinate(let c):
            r.status = .ready
            r.coordinate = c
            r.name = c.description
            r.detail = c.description
            applyNearby(c, service: service, subscription: subscription, into: &r, keepZone: true)
        case .timeZone:
            // The city of this Mac's time zone, from the offline table: no Location Services, also in previews. A zone
            // covers whole countries (all of China is Asia/Shanghai), so skins can ask "Not your city?"
            // (`Type=LocationSource` is TimeZone).
            let zone = localTimeZone
            switch service.lookUpTimeZone(zone.identifier, for: subscription) {
            case .pending:
                r.status = .loading
            case .notFound:
                r.status = .noLocation
                r.log = "Weather: no city is known for this Mac's time zone (\(zone.identifier)); set Location to a "
                    + "city"
            case .unavailable:
                r.status = .noLocation
                r.note = unavailableSearchNote
            case .found(let m):
                r.status = .ready
                r.coordinate = m.place.coordinate
                r.name = m.displayName
                r.detail = m.detail
                r.country = m.countryName
                r.countryCode = m.place.country
                r.zone = zone
            }
        case .device:
            guard live else {
                r.status = .preview
                return r
            }
            r.fromDevice = true
            switch service.deviceLocation(for: subscription, locate: locate) {
            case .pending:
                r.status = .loading
            case .denied:
                r.status = .locationDenied
                r.note = "Weather: Location Services are off for Deskset. Allow Deskset in System Settings → Privacy & "
                    + "Security → Location Services, or set Location to a city"
            case .unavailable:
                r.status = .locationUnavailable
                r.note = "Weather: this Mac's location is not known right now (Wi-Fi off?); Deskset tries again in a "
                    + "few minutes. Or set Location to a city"
            case .fix(let c):
                r.status = .ready
                r.coordinate = c
                r.name = "Current location"
                r.detail = "Current location"
                applyNearby(c, service: service, subscription: subscription, into: &r, keepZone: false)
            }
        }
        return r
    }

    private static func applyNearby(_ c: RoundedCoordinate, service: WeatherService, subscription: WeatherSubscription?,
                                    into r: inout WeatherResolvedLocation, keepZone: Bool) {
        guard case .done(let near) = service.nearby(c, for: subscription) else { return }
        if let m = near.match {
            r.name = m.displayName
            r.detail = m.detail
            r.country = m.countryName
            r.countryCode = m.place.country
        }
        if keepZone, let id = near.timeZone { r.zone = TimeZone(identifier: id) }
    }

    /// `TimeZone=`: `Place` (default), `Local`, an IANA name or hours from UTC. `DaylightSavingTime=1` adds this Mac's
    /// daylight saving offset at `date` to the hours, as the Time measure does (off by default here: hours from UTC
    /// are hours from UTC, whatever this Mac's own zone does).
    static func zone(option: String?, place: TimeZone?, daylightSavingTime: Bool, at date: Date,
                     localTimeZone: TimeZone) -> TimeZone {
        let raw = option?.trimmingCharacters(in: .whitespaces) ?? ""
        switch raw.lowercased() {
        case "", "place": return place ?? localTimeZone
        case "local": return localTimeZone
        default:
            if let z = TimeZone(identifier: raw) { return z }
            if let hours = OptionValue.number(raw) {
                return TimeFormatting.timeZone(offsetHours: hours, daylightSavingTime: daylightSavingTime, at: date,
                                               localTimeZone: localTimeZone)
            }
            return place ?? localTimeZone
        }
    }

    /// `DaylightSavingTime=` of a weather or sun measure (inherited through `Parent`): off unless set.
    static func daylightSavingTime(_ option: String?) -> Bool {
        option.flatMap { OptionValue.bool($0) } ?? false
    }

    /// The clock the plugins use: the demo's fixed clock when set; else the skin's when it was given one
    /// (`Deskset --render --clock`, tests); else the weather service's.
    static func now(_ env: WeatherEnvironment, skinClock: SkinClock) -> Date {
        if env.demo, let demoNow = env.demoNow { return demoNow }
        return skinClock.nowIsLive ? env.clock.now() : skinClock.now()
    }

    /// This Mac's time zone for `Location=TimeZone`: the skin's when it was given one, else the weather service's.
    static func localTimeZone(_ env: WeatherEnvironment, skinClock: SkinClock) -> TimeZone {
        skinClock.timeZoneIsLive ? env.localTimeZone() : skinClock.timeZone()
    }

    static func defaultTimeFormat(_ env: WeatherEnvironment) -> String {
        env.uses24HourClock() ? "%H:%M" : "%#I:%M %p"
    }

}

// MARK: - MacWeather

/// `Plugin=MacWeather`: forecasts from MET Norway (see docs/compat/weather.md).
public final class MacWeatherMeasure: Measure, PluginLifecycle, SectionVariableFunctions {
    /// What a measure shows (`Type=`).
    public enum ValueType: String, CaseIterable {
        case temperature, feelsLike, high, low, dewPoint, condition, symbol, symbolCode, isDaylight, humidity, pressure
        case cloudCover, fog, uvIndex, windSpeed, windGust, windDirection, windCardinal, beaufort, precipitation
        case precipitationChance, thunderChance, temperatureColor, temperatureCurve, time, sunrise, sunset, solarNoon
        case dayLength, daylightProgress, place, placeDetail, country, countryCode, latitude, longitude, timeZone
        case updatedAt, forecastTime, status, statusSymbol, attribution, attributionShort, attributionURL, licenseURL
        case temperatureUnit, windUnit, precipitationUnit, pressureUnit, locationSource

        /// As written in `Type=` (`FeelsLike`, `UVIndex`).
        public var optionName: String {
            self == .uvIndex ? "UVIndex" : rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }

        static func parse(_ raw: String) -> ValueType? {
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if key == "wind" { return .windSpeed }
            return allCases.first { $0.rawValue.lowercased() == key }
        }

        /// Accepts `Hour=`.
        var hourly: Bool {
            switch self {
            case .temperature, .feelsLike, .dewPoint, .condition, .symbol, .symbolCode, .isDaylight, .humidity,
                 .pressure, .cloudCover, .fog, .uvIndex, .windSpeed, .windGust, .windDirection, .windCardinal,
                 .beaufort, .precipitation, .precipitationChance, .thunderChance, .temperatureColor, .time:
                return true
            default: return false
            }
        }

        /// Accepts `Day=`.
        var daily: Bool {
            switch self {
            case .high, .low, .condition, .symbol, .symbolCode, .uvIndex, .windSpeed, .windGust, .beaufort,
                 .precipitation, .precipitationChance, .thunderChance, .temperatureColor, .time, .sunrise, .sunset,
                 .solarNoon, .dayLength:
                return true
            default: return false
            }
        }

        /// Needs forecast data (the others are about the place, the sun, the state or the units).
        var needsForecast: Bool {
            switch self {
            case .sunrise, .sunset, .solarNoon, .dayLength, .daylightProgress, .place, .placeDetail, .country,
                 .countryCode, .latitude, .longitude, .timeZone, .updatedAt, .status, .statusSymbol, .attribution,
                 .attributionShort, .attributionURL, .licenseURL, .temperatureUnit, .windUnit, .precipitationUnit,
                 .pressureUnit, .locationSource:
                return false
            default: return true
            }
        }

        var isTime: Bool { [.time, .sunrise, .sunset, .solarNoon, .updatedAt, .forecastTime].contains(self) }
    }

    /// What the root measure (the one with the Location) knows; its children read it.
    struct Binding {
        var location = WeatherResolvedLocation()
        var status = WeatherStatus.noLocation
        var snapshot: WeatherSnapshot?
        /// The time of the last refresh (the skin's clock when the binding was made, until the first one).
        var now: Date
        var locationQuery = ""

        init(now: Date) {
            self.now = now
        }
    }

    // Options (own).
    public private(set) var valueType = ValueType.temperature
    public private(set) var hour: Int?
    public private(set) var day: Int?
    private var parentName = ""
    private var ownSettings: [String: String] = [:]
    private var format: String?
    private var curveHours = 24
    private var curveWidth = 200.0
    private var curveHeight = 40.0
    private var smooth = true
    private var colorOfLow = false
    private var finishAction = ""
    private var connectErrorAction = ""
    private var locationErrorAction = ""
    private var loggedOnce: Set<String> = []

    // Root state.
    private var spec = WeatherLocationSpec.none
    private var subscription: WeatherSubscription?
    private weak var service: WeatherService?
    private(set) lazy var binding = Binding(now: skin.skinClock.now())
    private var seenVersion = 0
    /// The place whose failure streak `seenStreak` counts (nil: none seen yet, or none now).
    private var streakCoordinate: RoundedCoordinate?
    private var seenStreak = 0
    private var seenCoordinate: RoundedCoordinate?
    private var lastLocationError = false
    private var note: String?
    private var closed = false

    // Output.
    private var unavailable = false
    private var autoMin = 0.0
    private var autoMax = 1.0

    public override var automaticMinValue: Double { autoMin }
    public override var automaticMaxValue: Double { autoMax }
    public override var valueUnavailable: Bool { unavailable }

    public var status: WeatherStatus { root?.binding.status ?? binding.status }

    deinit {
        if let subscription { service?.detach(subscription) }
    }

    public func skinWillClose() {
        closed = true
        if let subscription { service?.detach(subscription) }
        subscription = nil
    }

    // MARK: Options

    static let inherited = ["Units", "TemperatureUnit", "WindUnit", "PrecipitationUnit", "PressureUnit", "TimeZone",
                            "FormatLocale", "Decimals", "UnavailableText", "NoEventText", "SymbolStyle",
                            "DaylightSavingTime"]

    public override func readMeasureOptions() {
        parentName = string("Parent").trimmingCharacters(in: .whitespaces)
        let rawType = string("Type", "Temperature")
        if let t = ValueType.parse(rawType) {
            valueType = t
        } else {
            valueType = .temperature
            logOnce("MacWeather [\(name)]: Type=\(rawType) is not a MacWeather type; using Temperature")
        }
        hour = optionalDouble("Hour").map { Int($0.clamped(0, 47)) }
        day = optionalDouble("Day").map { Int($0.clamped(0, 9)) }
        if hour != nil, day != nil {
            logOnce("MacWeather [\(name)]: Day and Hour are both set; Day is used", level: .notice)
            hour = nil
        }
        ownSettings = [:]
        for key in MacWeatherMeasure.inherited {
            if let v = option(key), !v.trimmingCharacters(in: .whitespaces).isEmpty { ownSettings[key.lowercased()] = v }
        }
        format = option("Format")
        curveHours = min(max(int("Hours", 24), 2), 48)
        curveWidth = max(double("CurveWidth", 200), 1)
        curveHeight = max(double("CurveHeight", 40), 1)
        smooth = bool("Smooth", true)
        colorOfLow = string("ColorOf", "High").trimmingCharacters(in: .whitespaces).lowercased() == "low"
        finishAction = actionOption("FinishAction")
        connectErrorAction = actionOption("OnConnectErrorAction")
        locationErrorAction = actionOption("OnLocationErrorAction")

        if parentName.isEmpty {
            let raw = string("Location")
            spec = WeatherLocationSpec.parse(raw)
            binding.locationQuery = raw.trimmingCharacters(in: .whitespaces)
            if subscription == nil {
                let hop = skin.hop()
                subscription = WeatherSubscription(hop: hop) { [weak self] in self?.weatherChanged() }
            }
        } else if option("Location") != nil {
            logOnce("MacWeather [\(name)]: Location is ignored on a measure with a Parent", level: .notice)
        }
    }

    private func logOnce(_ message: String, level: SkinLogLevel = .warning) {
        guard loggedOnce.count < 20, loggedOnce.insert(message).inserted else { return }
        skin.log(message, level: level)
    }

    /// The measure with the Location this one follows (itself without a Parent); nil when the chain is broken.
    var root: MacWeatherMeasure? {
        var m: MacWeatherMeasure = self
        for _ in 0..<9 {
            if m.parentName.isEmpty { return m }
            guard let p = skin.measure(named: m.parentName) as? MacWeatherMeasure, p !== self else { return nil }
            m = p
        }
        return nil
    }

    /// An inherited option: this measure's own value, else its parents'.
    private func setting(_ key: String) -> String? {
        var m: MacWeatherMeasure? = self
        for _ in 0..<9 {
            guard let current = m else { return nil }
            if let v = current.ownSettings[key.lowercased()] { return v }
            guard !current.parentName.isEmpty else { return nil }
            m = skin.measure(named: current.parentName) as? MacWeatherMeasure
        }
        return nil
    }

    // MARK: Update

    public override func computeValue() -> Double {
        if parentName.isEmpty {
            refreshBinding()
            checkActions(queue: true)
        } else if root == nil {
            logOnce("MacWeather [\(name)]: Parent=\(parentName) is not a MacWeather measure")
        }
        let out = output(type: valueType, hour: hour, day: day)
        return apply(out)
    }

    private func apply(_ out: Output) -> Double {
        unavailable = !out.available
        autoMin = out.range?.min ?? 0
        autoMax = out.range?.max ?? 1
        rawString = out.string
        return out.number
    }

    /// Recomputes the value between updates (a notification from the service) and publishes it.
    func publishNow() {
        guard !disabled, !paused else { return }
        let out = output(type: valueType, hour: hour, day: day)
        unavailable = !out.available
        autoMin = out.range?.min ?? 0
        autoMax = out.range?.max ?? 1
        refreshRange()
        publishAsyncResult(number: out.number, string: out.string)
    }

    /// The service says something changed (skin thread): this measure and every measure following it recompute, then
    /// FinishAction / the error actions run.
    private func weatherChanged() {
        guard !closed, !disabled, !paused, parentName.isEmpty else { return }
        refreshBinding()
        for m in skin.measures {
            guard let w = m as? MacWeatherMeasure, w.root === self else { continue }
            w.publishNow()
        }
        checkActions(queue: false)
    }

    private func refreshBinding() {
        let service = WeatherService.shared
        if service !== self.service {
            if let subscription { self.service?.detach(subscription) }
            self.service = service
            streakCoordinate = nil
        }
        let env = service.environment
        let now = WeatherLocationResolver.now(env, skinClock: skin.skinClock)
        binding.now = now
        let localZone = WeatherLocationResolver.localTimeZone(env, skinClock: skin.skinClock)
        let live = env.isLive(skin)
        let enabled = env.isEnabled()
        if !live && env.demo {
            var location = WeatherLocationResolver.resolve(spec, service: service, subscription: subscription, live: false,
                                                           localTimeZone: localZone)
            if location.coordinate == nil {
                location.coordinate = WeatherDemo.coordinate
                location.name = WeatherDemo.placeName
                location.detail = WeatherDemo.placeDetail
                location.country = "Norway"
                location.countryCode = "NO"
                location.zone = WeatherDemo.timeZone
            }
            location.status = .ready
            binding.location = location
            binding.snapshot = WeatherDemo.snapshot(now: now)
            binding.status = .ready
            setNote(nil)
            return
        }
        var location = WeatherLocationResolver.resolve(spec, service: service, subscription: subscription,
                                                       live: live && enabled, localTimeZone: localZone)
        if !enabled && location.status == .preview { location.status = .turnedOff }
        if let line = location.log { logOnce(line, level: .notice) }
        binding.location = location
        setNote(location.note.map { live || !location.fromDevice ? $0 : "" }.flatMap { $0.isEmpty ? nil : $0 })
        guard live, enabled else {
            leaveFeed()
            binding.snapshot = nil
            binding.status = !enabled ? .turnedOff : (location.status.isLocationError || location.status == .noLocation
                                                      ? location.status : .preview)
            return
        }
        // No place yet (a lookup or this Mac's location on its way: the subscription stays told about it), or none.
        guard let c = location.coordinate, location.status == .ready, let subscription else {
            leaveFeed()
            binding.snapshot = nil
            binding.status = location.status
            return
        }
        guard service.attach(subscription, to: c, persistent: !location.fromDevice) else {
            binding.snapshot = nil
            binding.status = .tooManyPlaces
            return
        }
        let snapshot = service.read(c)
        binding.snapshot = snapshot
        binding.status = WeatherService.status(of: snapshot, now: now)
        if binding.status == .refused {
            setNote("Weather: MET Norway refused the request; Deskset tries again in a day, or when it is opened again")
        }
    }

    private func leaveFeed() {
        if let subscription { service?.leaveFeed(subscription) }
    }

    private func setNote(_ text: String?) {
        guard text != note else { return }
        if let note { skin.removeIssue(note) }
        note = text
        if let text { skin.addIssue(text) }
    }

    /// FinishAction for new data (or a place newly resolved); OnConnectErrorAction when a request failed, once per run
    /// of failures (a place this measure sees for the first time — a new skin, a refresh, another Location — counts
    /// only while its last request failed, not for failures already over); OnLocationErrorAction when the place cannot
    /// be found. The measures that follow this one (`Parent=`) run theirs with it, after it. During an update they
    /// run after it.
    private func checkActions(queue: Bool) {
        var finished = false, connectFailed = false
        let b = binding
        if let s = b.snapshot {
            if s.version != seenVersion, s.forecast != nil {
                seenVersion = s.version
                finished = true
            } else if b.location.coordinate != seenCoordinate, b.location.coordinate != nil, s.forecast != nil {
                finished = true
            }
            if b.location.coordinate != streakCoordinate {
                streakCoordinate = b.location.coordinate
                seenStreak = s.failureStreak
                connectFailed = s.lastFailure != nil
            } else if s.failureStreak > seenStreak {
                seenStreak = s.failureStreak
                connectFailed = true
            }
        } else {
            streakCoordinate = nil
        }
        seenCoordinate = b.location.coordinate
        let locationError = b.status.isLocationError
        let locationFailed = locationError && !lastLocationError
        lastLocationError = locationError
        guard finished || connectFailed || locationFailed else { return }
        let measures = [self] + skin.measures.compactMap { m -> MacWeatherMeasure? in
            guard let w = m as? MacWeatherMeasure, w !== self, !w.disabled, !w.paused, w.root === self else { return nil }
            return w
        }
        var runs: [(action: String, measure: MacWeatherMeasure)] = []
        for (happened, action) in [(finished, \MacWeatherMeasure.finishAction),
                                   (connectFailed, \MacWeatherMeasure.connectErrorAction),
                                   (locationFailed, \MacWeatherMeasure.locationErrorAction)] where happened {
            for m in measures where !m[keyPath: action].isEmpty { runs.append((m[keyPath: action], m)) }
        }
        guard !runs.isEmpty else { return }
        if queue {
            skin.async { [weak self] in
                guard let self, !self.closed else { return }
                for r in runs { self.skin.execute(r.action, from: r.measure) }
            }
        } else {
            for r in runs { skin.execute(r.action, from: r.measure) }
        }
    }

    public override func execute(command: String) {
        let c = command.trimmingCharacters(in: .whitespaces).lowercased()
        guard let root else { return }
        let service = root.service ?? WeatherService.shared
        switch c {
        case "refresh":
            if let coordinate = root.binding.location.coordinate, service.environment.isLive(skin) {
                service.refresh(coordinate)
            }
        case "locate":
            if case .device = root.spec, service.environment.isLive(skin) {
                _ = service.deviceLocation(for: root.subscription, locate: true)
            }
        default:
            skin.log("MacWeather [\(name)]: unknown command \(command)", level: .warning)
        }
    }

    // MARK: Values

    struct Output {
        var number = 0.0
        var string: String?
        var available = true
        var range: (min: Double, max: Double)?
    }

    private var units: WeatherUnits {
        var u: WeatherUnits
        switch setting("Units")?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "metric"?: u = .metric
        case "imperial"?: u = .imperial
        default: u = (service ?? WeatherService.shared).environment.preferredUnits()
        }
        if let t = setting("TemperatureUnit")?.trimmingCharacters(in: .whitespaces).uppercased(),
           let v = TemperatureUnit(rawValue: t.hasPrefix("F") ? "F" : t.hasPrefix("C") ? "C" : t) { u.temperature = v }
        if let w = setting("WindUnit")?.trimmingCharacters(in: .whitespaces).lowercased() {
            let normalized = w.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: " ", with: "")
            if let v = WindUnit(rawValue: normalized == "kph" ? "kmh" : normalized == "knots" ? "kn" : normalized) {
                u.wind = v
            }
        }
        if let p = setting("PrecipitationUnit")?.trimmingCharacters(in: .whitespaces).lowercased(),
           let v = PrecipitationUnit(rawValue: p == "inch" || p == "inches" ? "in" : p) { u.precipitation = v }
        if let p = setting("PressureUnit")?.trimmingCharacters(in: .whitespaces).lowercased() {
            u.pressure = PressureUnit.allCases.first { $0.rawValue.lowercased() == p } ?? u.pressure
        }
        return u
    }

    private var decimals: Int? { setting("Decimals").flatMap { OptionValue.number($0) }.map { Int($0.clamped(0, 6)) } }
    private var unavailableText: String { setting("UnavailableText") ?? "" }

    private func displayZone(_ b: Binding) -> TimeZone {
        WeatherLocationResolver.zone(option: setting("TimeZone"), place: b.location.fromDevice ? nil : b.location.zone,
                                     daylightSavingTime: WeatherLocationResolver.daylightSavingTime(setting("DaylightSavingTime")),
                                     at: b.now, localTimeZone: skin.skinClock.timeZone())
    }

    private var locale: Locale {
        TimeFormatting.locale(fromOption: setting("FormatLocale"), local: skin.locale) ?? TimeFormatting.defaultLocale
    }

    /// The value of `type` for now, hour N or day N.
    func output(type: ValueType, hour requestedHour: Int?, day requestedDay: Int?, decimalsOverride: Int? = nil) -> Output {
        let b = root?.binding ?? Binding(now: skin.skinClock.now())
        let env = (root?.service ?? WeatherService.shared).environment
        let u = units
        let zone = displayZone(b)
        let places = decimalsOverride ?? decimals
        var out = Output()
        func none() -> Output {
            // Symbol names stay empty, so `ImageName=sf:%1` draws nothing until there is data.
            Output(number: 0, string: type == .symbol || type == .statusSymbol ? "" : unavailableText,
                   available: false, range: nil)
        }
        func number(_ v: Double?) -> Output {
            guard let v, v.isFinite else { return none() }
            return Output(number: places.map { WeatherUnits.round(v, decimals: $0) } ?? v, string: nil)
        }
        func text(_ s: String) -> Output { Output(number: 0, string: s) }
        func time(_ date: Date?, zone: TimeZone, defaultFormat: String) -> Output {
            guard let date else { return none() }
            let f = format ?? defaultFormat
            return Output(number: TimeFormatting.measureValue(for: date, timeZone: zone),
                          string: TimeFormatting.format(date, format: f, timeZone: zone, locale: locale,
                                                        systemLocale: skin.locale))
        }
        let defaultTime = WeatherLocationResolver.defaultTimeFormat(env)
        // Times that are not about the place (when the data was fetched) are in this Mac's zone: the skin's.
        let localZone = skin.skinClock.timeZone()

        // Not about the forecast.
        switch type {
        case .status:
            return Output(number: Double(b.status.rawValue), string: statusText(b, env: env))
        case .statusSymbol:
            return Output(number: Double(b.status.rawValue), string: WeatherSymbols.status(b.status))
        case .attribution: return text(METNorway.attribution)
        case .attributionShort: return text(METNorway.attributionShort)
        case .attributionURL: return text(METNorway.attributionURL)
        case .licenseURL: return text(METNorway.licenseURL)
        case .temperatureUnit: return text(u.temperature.symbol)
        case .windUnit: return text(u.wind.symbol)
        case .precipitationUnit: return text(u.precipitation.symbol)
        case .pressureUnit: return text(u.pressure.symbol)
        case .locationSource:
            let source = b.location.source
            return Output(number: Double(source.rawValue), string: source.name, available: true, range: (0, 4))
        default: break
        }
        let location = b.location
        let hasPlace = location.coordinate != nil && b.status.hasCoordinate
        switch type {
        case .place: return hasPlace || !location.name.isEmpty ? text(location.name) : none()
        case .placeDetail: return hasPlace ? text(location.detail) : none()
        case .country: return hasPlace && !location.country.isEmpty ? text(location.country) : none()
        case .countryCode: return hasPlace && !location.countryCode.isEmpty ? text(location.countryCode) : none()
        case .latitude: return hasPlace ? number(location.coordinate?.latitude) : none()
        case .longitude: return hasPlace ? number(location.coordinate?.longitude) : none()
        case .timeZone:
            guard hasPlace else { return none() }
            return Output(number: Double(zone.secondsFromGMT(for: b.now)) / 3600, string: zone.identifier)
        case .updatedAt:
            guard b.status.showsData else { return none() }
            return time(b.snapshot?.validatedAt, zone: localZone, defaultFormat: defaultTime)
        case .forecastTime:
            guard b.status.showsData else { return none() }
            return time(b.snapshot?.forecast?.updatedAt, zone: localZone, defaultFormat: defaultTime)
        case .sunrise, .sunset, .solarNoon, .dayLength, .daylightProgress:
            guard hasPlace, let c = location.coordinate else { return none() }
            let offset = type == .daylightProgress ? 0 : (requestedDay ?? 0)
            let sun = SolarCalculator.day(containing: b.now, zone: zone, latitude: c.latitude, longitude: c.longitude,
                                          offset: offset)
            switch type {
            case .sunrise, .sunset:
                guard let date = (type == .sunrise ? sun.sunrise : sun.sunset).date else {
                    // Midnight sun or polar night: MacSun's NoEventText, not the text for "no data".
                    return Output(number: 0, string: setting("NoEventText") ?? "--:--", available: false, range: nil)
                }
                return time(date, zone: zone, defaultFormat: defaultTime)
            case .solarNoon: return time(sun.solarNoon, zone: zone, defaultFormat: defaultTime)
            case .dayLength:
                return Output(number: sun.length, string: SolarCalculator.durationText(sun.length), available: true,
                              range: (0, 86_400))
            default:
                return Output(number: sun.progress(at: b.now), string: nil, available: true, range: (0, 1))
            }
        default: break
        }

        // Forecast values.
        guard b.status.showsData, let snapshot = b.snapshot, let forecast = snapshot.forecast else { return none() }
        let useDay = requestedDay.flatMap { type.daily ? $0 : nil }
            ?? (type.daily && !type.hourly ? 0 : nil)
        let hourIndex: Int?
        if useDay == nil {
            hourIndex = requestedHour.flatMap { type.hourly ? WeatherTimeline.hourIndex(forecast, now: b.now, hour: $0) : nil }
                ?? (requestedHour != nil && type.hourly ? nil : WeatherTimeline.nowIndex(forecast, now: b.now))
        } else {
            hourIndex = nil
        }
        let daySummary: WeatherDay? = useDay.flatMap { n in
            let days = snapshot.days(zone: zone, now: b.now)
            guard n >= 0, n < days.count, days[n].available else { return nil }
            return days[n]
        }
        if useDay != nil && daySummary == nil { return none() }
        let step = hourIndex.map { forecast.steps[$0] }
        if useDay == nil && step == nil { return none() }
        let period: WeatherPeriod? = requestedHour != nil ? step?.next1h : step?.shortestPeriod
        let symbol: WeatherSymbol? = daySummary?.symbol ?? (step?.next1h ?? step?.next6h ?? step?.next12h)?.symbol

        func temp(_ c: Double?) -> Double? { c.map { u.temperature.convert(celsius: $0) } }
        func wind(_ v: Double?) -> Double? { v.map { u.wind.convert(metersPerSecond: $0) } }
        func tempRange(_ value: @escaping (WeatherStep) -> Double?) -> (min: Double, max: Double)? {
            guard let r = WeatherTimeline.range(forecast, now: b.now, value) else { return nil }
            return (u.temperature.convert(celsius: r.min), max(u.temperature.convert(celsius: r.max),
                                                               u.temperature.convert(celsius: r.min) + 1))
        }
        // Ranges of daily values span every day the forecast has (0–9), so the bars of a forecast strip line up.
        func weekRange() -> (min: Double, max: Double)? {
            let days = snapshot.days(zone: zone, now: b.now).filter(\.available)
            let lows = days.compactMap(\.low), highs = days.compactMap(\.high)
            guard let lo = lows.min(), let hi = highs.max() else { return nil }
            return (u.temperature.convert(celsius: lo), max(u.temperature.convert(celsius: hi),
                                                            u.temperature.convert(celsius: lo) + 1))
        }
        func largestOfDays(_ value: (WeatherDay) -> Double?) -> Double? {
            snapshot.days(zone: zone, now: b.now).filter(\.available).compactMap(value).max()
        }

        switch type {
        case .temperature:
            out = number(temp(step?.instant.temperature))
            out.range = tempRange { $0.instant.temperature }
        case .feelsLike:
            guard let s = step, let t = s.instant.temperature else { return none() }
            out = number(temp(WeatherUnits.feelsLike(temperature: t, humidity: s.instant.humidity,
                                                     windSpeed: s.instant.windSpeed, apparent: s.instant.apparentTemperature)))
            out.range = tempRange { st in
                st.instant.temperature.map { WeatherUnits.feelsLike(temperature: $0, humidity: st.instant.humidity,
                                                                    windSpeed: st.instant.windSpeed,
                                                                    apparent: st.instant.apparentTemperature) }
            }
        case .high, .low:
            out = number(temp(type == .high ? daySummary?.high : daySummary?.low))
            out.range = weekRange()
        case .dewPoint:
            out = number(temp(step?.instant.dewPoint))
            out.range = tempRange { $0.instant.dewPoint }
        case .condition, .symbol, .symbolCode:
            guard let symbol else { return none() }
            if symbol.condition == nil {
                logOnce("MacWeather: unknown MET Norway symbol code \(symbol.raw)", level: .notice)
            }
            let outline = setting("SymbolStyle")?.trimmingCharacters(in: .whitespaces).lowercased() == "outline"
            let s = type == .condition ? symbol.description : type == .symbol ? symbol.sfSymbol(outline: outline) : symbol.raw
            out = Output(number: Double(symbol.number), string: s, available: true, range: (0, 50))
        case .isDaylight:
            // From the sun for every condition (only half of MET's codes come in day / night / polar twilight forms,
            // so their variant would switch with the clouds): now at this moment, hour N in the middle of that hour.
            guard let s = step, let c = location.coordinate else { return none() }
            let at = requestedHour == nil ? b.now : s.time.addingTimeInterval(1800)
            out = number(Double(SolarCalculator.daylight(at: at, latitude: c.latitude, longitude: c.longitude, zone: zone)))
            out.range = (0, 2)
        case .humidity:
            out = number(step?.instant.humidity)
            out.range = (0, 100)
        case .pressure:
            out = number(step?.instant.pressure.map { u.pressure.convert(hectopascals: $0) })
            out.range = (u.pressure.convert(hectopascals: 950), u.pressure.convert(hectopascals: 1050))
        case .cloudCover:
            out = number(step?.instant.cloudCover)
            out.range = (0, 100)
        case .fog:
            out = number(step?.instant.fog)
            out.range = (0, 100)
        case .uvIndex:
            out = number(daySummary != nil ? daySummary?.uvMax : step?.instant.uvIndex)
            out.range = (0, 11)
        case .windSpeed, .windGust:
            let raw = type == .windSpeed ? (daySummary != nil ? daySummary?.windMax : step?.instant.windSpeed)
                : (daySummary != nil ? daySummary?.gustMax : step?.instant.windGust)
            out = number(wind(raw))
            // A day's highest against the highest of any day; the next hours against the next 24 hours.
            let largest = daySummary != nil ? largestOfDays { type == .windSpeed ? $0.windMax : $0.gustMax }
                : WeatherTimeline.range(forecast, now: b.now) { type == .windSpeed ? $0.instant.windSpeed : $0.instant.windGust }?.max
            out.range = (0, max(wind(largest) ?? 1, u.wind == .bft ? 12 : 1))
        case .windDirection, .windCardinal:
            guard let d = step?.instant.windDirection else { return none() }
            out = number(d)
            if type == .windCardinal { out.string = WeatherUnits.cardinal(degrees: d) }
            out.range = (0, 360)
        case .beaufort:
            guard let v = daySummary != nil ? daySummary?.windMax : step?.instant.windSpeed else { return none() }
            let force = WeatherUnits.beaufort(metersPerSecond: v)
            out = Output(number: Double(force), string: WeatherUnits.beaufortNames[force], available: true, range: (0, 12))
        case .precipitation:
            let mm = daySummary != nil ? daySummary?.precipitation : period?.precipitation
            out = number(mm.map { u.precipitation.convert(millimeters: $0) })
            // A day's total against the largest daily total; an hour's amount against the next 24 hours'.
            let largest = daySummary != nil ? largestOfDays { $0.precipitation }
                : WeatherTimeline.range(forecast, now: b.now) { $0.next1h?.precipitation }?.max
            let floor = u.precipitation == .mm ? 1 : 0.04
            out.range = (0, max(u.precipitation.convert(millimeters: largest ?? 0), floor))
        case .precipitationChance:
            out = number(daySummary != nil ? daySummary?.precipitationChance : period?.precipitationChance)
            out.range = (0, 100)
        case .thunderChance:
            out = number(daySummary != nil ? daySummary?.thunderChance : period?.thunderChance)
            out.range = (0, 100)
        case .temperatureColor:
            let c = daySummary.map { colorOfLow ? $0.low : $0.high } ?? step?.instant.temperature
            guard let celsius = c else { return none() }
            let rgb = WeatherUnits.color(celsius: celsius)
            out = Output(number: temp(celsius) ?? 0, string: "\(rgb.r),\(rgb.g),\(rgb.b)")
            out.range = daySummary != nil ? weekRange() : tempRange { $0.instant.temperature }
        case .temperatureCurve:
            guard let curve = temperatureCurve(forecast, now: b.now, units: u) else { return none() }
            out = Output(number: 0, string: curve.path, available: true, range: (curve.min, curve.max))
        case .time:
            if let daySummary {
                out = time(daySummary.start, zone: zone, defaultFormat: "%a")
            } else {
                out = time(step?.time, zone: zone, defaultFormat: env.uses24HourClock() ? "%H:%M" : "%#I %p")
            }
        default:
            return none()
        }
        return out
    }

    private func statusText(_ b: Binding, env: WeatherEnvironment) -> String {
        let updated = b.snapshot?.validatedAt.map {
            TimeFormatting.format($0, format: format ?? WeatherLocationResolver.defaultTimeFormat(env),
                                  timeZone: skin.skinClock.timeZone(), locale: locale, systemLocale: skin.locale)
        } ?? ""
        switch b.status {
        case .ready: return "Updated \(updated)"
        case .loading: return "Loading weather…"
        case .stale:
            switch b.snapshot?.lastFailure {
            case .offline?: return "Offline · updated \(updated)"
            case nil: return "Updated \(updated)"
            default: return "Weather service busy · updated \(updated)"
            }
        case .noLocation: return "Set a location"
        case .placeNotFound:
            let q = b.locationQuery.isEmpty ? b.location.name : b.locationQuery
            return "Can't find “\(q)”"
        case .locationDenied: return "Location access is off"
        case .locationUnavailable: return "Can't find this Mac's location"
        case .notCovered: return "No forecast for this place"
        case .refused: return "The weather service refused the request"
        case .rateLimited: return "Weather service busy · retrying"
        case .offline: return "Offline · retrying"
        case .turnedOff: return "Weather is turned off in Deskset settings"
        case .preview: return "Preview · live weather shows on the desktop"
        case .tooManyPlaces: return "Too many weather places"
        }
    }

    /// A Shape `Path` of the next `Hours` hourly temperatures in `CurveWidth` × `CurveHeight` (lowest at the bottom),
    /// Catmull-Rom smoothed into cubic Béziers with `Smooth=1`; numbers with at most 2 decimals.
    func temperatureCurve(_ forecast: WeatherForecast, now: Date,
                          units u: WeatherUnits) -> (path: String, min: Double, max: Double)? {
        guard let n = WeatherTimeline.nowIndex(forecast, now: now) else { return nil }
        var temps: [Double] = []
        var expected = forecast.steps[n].time
        for s in forecast.steps[n...] {
            guard temps.count < curveHours, s.time == expected, let t = s.instant.temperature else { break }
            temps.append(u.temperature.convert(celsius: t))
            expected = expected.addingTimeInterval(3600)
        }
        guard temps.count >= 2, let lo = temps.min(), let hi = temps.max() else { return nil }
        let w = curveWidth, h = curveHeight
        let points: [(Double, Double)] = temps.enumerated().map { i, t in
            let x = w * Double(i) / Double(temps.count - 1)
            let y = hi > lo ? h - (t - lo) / (hi - lo) * h : h / 2
            return (x, y)
        }
        func f(_ v: Double) -> String { NumberFormatting.plain((v * 100).rounded() / 100) }
        var parts = ["\(f(points[0].0)), \(f(points[0].1))"]
        for i in 1..<points.count {
            let p1 = points[i - 1], p2 = points[i]
            if smooth {
                let p0 = i >= 2 ? points[i - 2] : p1
                let p3 = i + 1 < points.count ? points[i + 1] : p2
                let c1 = (p1.0 + (p2.0 - p0.0) / 6, p1.1 + (p2.1 - p0.1) / 6)
                let c2 = (p2.0 - (p3.0 - p1.0) / 6, p2.1 - (p3.1 - p1.1) / 6)
                parts.append("CurveTo \(f(p2.0)), \(f(p2.1)), \(f(c1.0)), \(f(c1.1)), \(f(c2.0)), \(f(c2.1))")
            } else {
                parts.append("LineTo \(f(p2.0)), \(f(p2.1))")
            }
        }
        return (parts.joined(separator: " | "), lo, hi)
    }

    // MARK: Section variables

    /// `[&MeasureWeather:Now(Humidity, 0)]`, `[&MeasureWeather:Hour(3, Temperature, 0)]`,
    /// `[&MeasureWeather:Day(1, High, 0)]`: the string, or the number with those decimals. The index and the decimals
    /// are clamped as the options are (hour 0–47, day 0–9, decimals 0–6): they come from the skin.
    public func sectionVariableFunction(_ call: String) -> String? {
        let trimmed = call.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return nil }
        let function = trimmed[..<open].trimmingCharacters(in: .whitespaces).lowercased()
        let args = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        var index: Int?
        var rest = args
        switch function {
        case "now": break
        case "hour", "day":
            guard let first = rest.first, let v = OptionValue.number(first), v.isFinite else { return nil }
            index = function == "hour" ? Int(v.clamped(0, 47)) : Int(v.clamped(0, 9))
            rest.removeFirst()
        default: return nil
        }
        guard let typeName = rest.first, let type = ValueType.parse(typeName) else { return nil }
        let places = rest.count > 1
            ? OptionValue.number(rest[1]).flatMap { $0.isFinite ? Int($0.clamped(0, 6)) : nil } : nil
        let out = output(type: type, hour: function == "hour" ? index : nil, day: function == "day" ? index : nil,
                         decimalsOverride: places)
        if let s = out.string { return s }
        guard out.available else { return unavailableText }
        return places.map { NumberFormatting.format(out.number, minValue: 0, maxValue: 1,
                                                    options: NumberFormatOptions(numOfDecimals: $0)) }
            ?? NumberFormatting.plain(out.number)
    }

    // MARK: Menu

    /// For the skin menu: whether the skin shows MET Norway data, and when it was last updated ("12:05").
    public static func attributionInfo(for skin: Skin) -> (uses: Bool, updated: String?) {
        let roots = skin.measures.compactMap { $0 as? MacWeatherMeasure }.filter { $0.parentName.isEmpty }
        guard !roots.isEmpty else { return (false, nil) }
        let env = WeatherService.shared.environment
        let dates = roots.compactMap { $0.binding.status.showsData ? $0.binding.snapshot?.validatedAt : nil }
        let updated = dates.max().map {
            TimeFormatting.format($0, format: WeatherLocationResolver.defaultTimeFormat(env),
                                  timeZone: skin.skinClock.timeZone(), locale: TimeFormatting.defaultLocale)
        }
        return (true, updated)
    }
}

// MARK: - MacSun

/// `Plugin=MacSun`: sun and moon times computed on the Mac (never the network).
public final class MacSunMeasure: Measure, PluginLifecycle {
    public enum ValueType: String, CaseIterable {
        case sunrise, sunset, solarNoon, civilDawn, civilDusk, nauticalDawn, nauticalDusk, astronomicalDawn
        case astronomicalDusk, goldenHourMorningEnd, goldenHourEveningStart, dayLength, daylightProgress
        case sunElevation, sunAzimuth, isDaylight, sunState, moonPhase, moonIllumination, moonPhaseName, moonSymbol
        case place, timeZone, locationSource

        public var optionName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        static func parse(_ raw: String) -> ValueType? {
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            return allCases.first { $0.rawValue.lowercased() == key }
        }

        var event: SolarEvent? {
            switch self {
            case .sunrise: return .sunrise
            case .sunset: return .sunset
            case .civilDawn: return .civilDawn
            case .civilDusk: return .civilDusk
            case .nauticalDawn: return .nauticalDawn
            case .nauticalDusk: return .nauticalDusk
            case .astronomicalDawn: return .astronomicalDawn
            case .astronomicalDusk: return .astronomicalDusk
            case .goldenHourMorningEnd: return .goldenHourMorningEnd
            case .goldenHourEveningStart: return .goldenHourEveningStart
            default: return nil
            }
        }
    }

    public private(set) var valueType = ValueType.sunrise
    private var parentName = ""
    private var day = 0
    private var format: String?
    private var ownSettings: [String: String] = [:]
    private var spec = WeatherLocationSpec.none
    private var subscription: WeatherSubscription?
    private weak var service: WeatherService?
    private(set) var location = WeatherResolvedLocation()
    private var note: String?
    private var closed = false
    private var unavailable = false
    private var autoMin = 0.0
    private var autoMax = 1.0
    private var loggedOnce: Set<String> = []

    public override var automaticMinValue: Double { autoMin }
    public override var automaticMaxValue: Double { autoMax }
    public override var valueUnavailable: Bool { unavailable }

    static let inherited = ["TimeZone", "FormatLocale", "NoEventText", "UnavailableText", "DaylightSavingTime"]

    deinit {
        if let subscription { service?.detach(subscription) }
    }

    public func skinWillClose() {
        closed = true
        if let subscription { service?.detach(subscription) }
        subscription = nil
    }

    public override func readMeasureOptions() {
        parentName = string("Parent").trimmingCharacters(in: .whitespaces)
        let rawType = string("Type", "Sunrise")
        if let t = ValueType.parse(rawType) {
            valueType = t
        } else {
            valueType = .sunrise
            if loggedOnce.insert(rawType).inserted {
                skin.log("MacSun [\(name)]: Type=\(rawType) is not a MacSun type; using Sunrise", level: .warning)
            }
        }
        day = Int(double("Day", 0).clamped(-1, 30))
        format = option("Format")
        ownSettings = [:]
        for key in MacSunMeasure.inherited {
            if let v = option(key) { ownSettings[key.lowercased()] = v }
        }
        if parentName.isEmpty {
            spec = WeatherLocationSpec.parse(string("Location"))
            if subscription == nil {
                let hop = skin.hop()
                subscription = WeatherSubscription(hop: hop) { [weak self] in self?.locationChanged() }
            }
        }
    }

    private var root: MacSunMeasure? {
        var m: MacSunMeasure = self
        for _ in 0..<9 {
            if m.parentName.isEmpty { return m }
            guard let p = skin.measure(named: m.parentName) as? MacSunMeasure, p !== self else { return nil }
            m = p
        }
        return nil
    }

    private func setting(_ key: String) -> String? {
        var m: MacSunMeasure? = self
        for _ in 0..<9 {
            guard let current = m else { return nil }
            if let v = current.ownSettings[key.lowercased()] { return v }
            guard !current.parentName.isEmpty else { return nil }
            m = skin.measure(named: current.parentName) as? MacSunMeasure
        }
        return nil
    }

    private func resolve() {
        let service = WeatherService.shared
        self.service = service
        let env = service.environment
        let live = env.isLive(skin) && env.isEnabled()
        location = WeatherLocationResolver.resolve(spec, service: service, subscription: subscription, live: live,
                                                   localTimeZone: WeatherLocationResolver.localTimeZone(
                                                       env, skinClock: skin.skinClock))
        if let line = location.log, loggedOnce.insert(line).inserted { skin.log("MacSun [\(name)]: " + line, level: .notice) }
        let text = location.note
        if text != note {
            if let note { skin.removeIssue(note) }
            note = text
            if let text { skin.addIssue(text) }
        }
    }

    private func locationChanged() {
        guard !closed, !disabled, !paused, parentName.isEmpty else { return }
        resolve()
        for m in skin.measures {
            guard let s = m as? MacSunMeasure, s.root === self, !s.disabled, !s.paused else { continue }
            let out = s.compute()
            s.refreshRange()
            s.publishAsyncResult(number: out.number, string: out.string)
        }
    }

    public override func computeValue() -> Double {
        if parentName.isEmpty { resolve() }
        let out = compute()
        rawString = out.string
        return out.number
    }

    private func compute() -> (number: Double, string: String?) {
        let env = (root?.service ?? WeatherService.shared).environment
        let now = WeatherLocationResolver.now(env, skinClock: skin.skinClock)
        let localZone = skin.skinClock.timeZone()
        let unavailableText = setting("UnavailableText") ?? ""
        let noEventText = setting("NoEventText") ?? "--:--"
        let daylightSavingTime = WeatherLocationResolver.daylightSavingTime(setting("DaylightSavingTime"))
        autoMin = 0
        autoMax = 1
        unavailable = false
        func none(_ text: String) -> (Double, String?) {
            unavailable = true
            return (0, text)
        }
        let dayOffset = day
        // The moon does not need a place.
        switch valueType {
        case .moonPhase, .moonIllumination, .moonPhaseName, .moonSymbol:
            let zone = WeatherLocationResolver.zone(option: setting("TimeZone"), place: nil,
                                                    daylightSavingTime: daylightSavingTime, at: now,
                                                    localTimeZone: localZone)
            var at = now
            if dayOffset != 0 {
                var c = Calendar(identifier: .gregorian)
                c.timeZone = zone
                let start = c.date(byAdding: .day, value: dayOffset, to: c.startOfDay(for: now)) ?? now
                at = SolarCalculator.localNoonInstant(dayStart: start, zone: zone)
            }
            let phase = MoonPhase.phase(at: at)
            switch valueType {
            case .moonPhase: return (phase, nil)
            case .moonIllumination:
                autoMax = 100
                return (MoonPhase.illumination(phase: phase), nil)
            case .moonPhaseName: return (phase, MoonPhase.names[MoonPhase.eighth(phase: phase)])
            default: return (phase, WeatherSymbols.moon[MoonPhase.eighth(phase: phase)])
            }
        default: break
        }
        guard let r = root else { return none(unavailableText) }
        let loc = r.location
        if valueType == .locationSource {
            autoMax = 4
            return (Double(loc.source.rawValue), loc.source.name)
        }
        guard let c = loc.coordinate else { return none(unavailableText) }
        let zone = WeatherLocationResolver.zone(option: setting("TimeZone"), place: loc.fromDevice ? nil : loc.zone,
                                                daylightSavingTime: daylightSavingTime, at: now,
                                                localTimeZone: localZone)
        let locale = TimeFormatting.locale(fromOption: setting("FormatLocale"), local: skin.locale)
            ?? TimeFormatting.defaultLocale
        func time(_ date: Date) -> (Double, String?) {
            let f = format ?? WeatherLocationResolver.defaultTimeFormat(env)
            return (TimeFormatting.measureValue(for: date, timeZone: zone),
                    TimeFormatting.format(date, format: f, timeZone: zone, locale: locale, systemLocale: skin.locale))
        }
        switch valueType {
        case .place: return (0, loc.name)
        case .timeZone: return (Double(zone.secondsFromGMT(for: now)) / 3600, zone.identifier)
        case .sunElevation, .sunAzimuth, .isDaylight:
            let p = SolarCalculator.position(at: now, latitude: c.latitude, longitude: c.longitude)
            switch valueType {
            case .sunElevation:
                autoMin = -90
                autoMax = 90
                return (p.elevation, nil)
            case .sunAzimuth:
                autoMax = 360
                return (p.azimuth, nil)
            default: return (p.elevation > -0.833 ? 1 : 0, nil)
            }
        default: break
        }
        let sun = SolarCalculator.day(containing: now, zone: zone, latitude: c.latitude, longitude: c.longitude,
                                      offset: valueType == .daylightProgress || valueType == .sunState ? 0 : dayOffset)
        switch valueType {
        case .solarNoon: return time(sun.solarNoon)
        case .dayLength:
            autoMax = 86_400
            return (sun.length, SolarCalculator.durationText(sun.length))
        case .daylightProgress: return (sun.progress(at: now), nil)
        case .sunState:
            autoMax = 2
            return (Double(sun.state), nil)
        default:
            guard let event = valueType.event else { return none(unavailableText) }
            let result = SolarCalculator.event(event, dayStart: sun.dayStart, zone: zone, latitude: c.latitude,
                                               longitude: c.longitude)
            guard let date = result.date else { return none(noEventText) }
            return time(date)
        }
    }
}
