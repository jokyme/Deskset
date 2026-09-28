import AppKit
import DesksetCore

/// Options of `Deskset --render`, parsed leniently: bad numbers fall back to defaults (with a warning), values are
/// clamped to sane ranges.
struct RenderOptions: Equatable {
    var input: String
    var output: String?
    /// Skin updates before drawing (at least 1: the first update lays the skin out).
    var updates = 2
    /// Milliseconds between updates; 0 = back to back.
    var interval = 1000.0
    var scale = 2.0
    var background: RGBA?
    var skinsDirectory: String?
    /// The appearance the skin is drawn in (`#MACAPPEARANCE#`…, SysColor): Light unless `--appearance dark` / `--dark`,
    /// so renders are the same on every Mac; `--appearance system` follows the Mac's setting.
    var appearance = Appearance.light
    /// The clock, week and temperature settings the skin sees (`#MACCLOCKHOURS#`, `#MACFIRSTWEEKDAY#`,
    /// `#MACTEMPERATUREUNIT#`, and the weather plugins' default times and unit): the standard ones — 24-hour, weeks from
    /// Sunday, °C — so renders are the same on every Mac, unless `--clock-hours 12`, `--first-weekday 1`,
    /// `--temperature-unit F` say otherwise; `system` (nil here) takes the Mac's own.
    var clockHours: Int? = MacRegionalSettings.standard.clockHours
    var firstWeekday: Int? = MacRegionalSettings.standard.firstWeekday
    var temperatureUnit: TemperatureUnit? = MacRegionalSettings.standard.temperatureUnit
    /// `--clock`: the time the skin sees at its first update (nil: the Mac's clock). The skin then runs in virtual
    /// time: update i is at this time plus i intervals, and what falls due between two updates (`!Delay`, ActionTimer,
    /// transitions) runs at its own virtual time, without real waits.
    var clock: Date?
    /// `--time-zone`: the skin's local time zone (nil: UTC with `--clock`, else the Mac's).
    var timeZone: TimeZone?
    /// `--seed`: the skin's random numbers come from a generator with this seed (nil: the system's).
    var seed: UInt64?
    /// `--data`: what the skin reads about the Mac, as JSON text or the path of a JSON file (`SkinInputData`; read
    /// when the render starts).
    var data: String?
    /// `--state`: where to write the skin's state after the last update (JSON: its measures, meters and variables;
    /// `RenderCommand.state`), nil: nowhere.
    var stateOutput: String?
    /// `--color-space`: the bitmap the skin is drawn into. `device` (the default, what `--render` always drew) is the
    /// device RGB space; `srgb` is 8-bit premultiplied sRGB, the space reference images are compared in.
    var colorSpace = ColorSpace.device
    var warnings: [String] = []

    enum Appearance: String, Equatable {
        case light, dark, system
    }

    enum ColorSpace: String, Equatable {
        case device, srgb
    }

    static let maxUpdates = 100_000
    static let maxInterval = 60_000.0
    static let scaleRange = 0.25...8.0
    /// Largest bitmap side in pixels; the scale is reduced to fit.
    static let maxPixels = 16_384

    static let usage = "usage: Deskset --render Skin.ini [--out out.png] [--updates N] [--interval ms] [--scale S] "
        + "[--background R,G,B[,A]] [--appearance light|dark|system] [--dark] [--clock-hours 12|24|system] "
        + "[--first-weekday 0-6|system] [--temperature-unit C|F|system] [--clock ISO8601|UNIX] [--time-zone ID] "
        + "[--seed N] [--data FILE|JSON] [--state out.json] [--color-space device|srgb] [--skins-dir DIR]"

    /// nil when there is no `--render <file>`.
    static func parse(_ arguments: [String]) -> RenderOptions? {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            let v = arguments[i + 1]
            return v.hasPrefix("--") ? nil : v
        }
        guard let input = value("--render"), !input.isEmpty else { return nil }
        var o = RenderOptions(input: input)
        o.output = value("--out")
        o.skinsDirectory = value("--skins-dir")

        func number(_ flag: String) -> Double? {
            guard let raw = value(flag) else {
                if arguments.contains(flag) { o.warnings.append("\(flag) needs a value; using the default") }
                return nil
            }
            guard let v = Double(raw.trimmingCharacters(in: .whitespaces)), v.isFinite else {
                o.warnings.append("\(flag) \"\(raw)\" is not a number; using the default")
                return nil
            }
            return v
        }
        if let v = number("--updates") {
            o.updates = Int(min(max(v.rounded(.down), 1), Double(maxUpdates)))
            if v < 1 { o.warnings.append("--updates \(raw(v)): at least one update is needed to lay the skin out") }
        }
        if let v = number("--interval") {
            o.interval = min(max(v, 0), maxInterval)
        }
        if let v = number("--scale") {
            o.scale = min(max(v, scaleRange.lowerBound), scaleRange.upperBound)
        }
        if let raw = value("--background") {
            if let c = OptionValue.color(raw) { o.background = c } else {
                o.warnings.append("--background \"\(raw)\" is not a color; using transparent")
            }
        }
        if arguments.contains("--dark") { o.appearance = .dark }
        if let raw = value("--appearance") {
            if let a = Appearance(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) { o.appearance = a } else {
                o.warnings.append("--appearance \"\(raw)\" is not light, dark or system; using \(o.appearance.rawValue)")
            }
        } else if arguments.contains("--appearance") {
            o.warnings.append("--appearance needs a value; using \(o.appearance.rawValue)")
        }
        // The clock, week and temperature settings: a value, or `system` for the Mac's own.
        func setting<T>(_ flag: String, _ current: T?, expected: String, _ read: (String) -> T?) -> T? {
            guard let raw = value(flag) else {
                if arguments.contains(flag) { o.warnings.append("\(flag) needs a value; using the standard one") }
                return current
            }
            let word = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if word == "system" { return nil }
            guard let v = read(word) else {
                o.warnings.append("\(flag) \"\(raw)\" is not \(expected); using the standard one")
                return current
            }
            return v
        }
        o.clockHours = setting("--clock-hours", o.clockHours, expected: "12, 24 or system") {
            $0 == "12" ? 12 : $0 == "24" ? 24 : nil
        }
        o.firstWeekday = setting("--first-weekday", o.firstWeekday, expected: "0 (Sunday) to 6 (Saturday) or system") {
            Int($0).flatMap { (0...6).contains($0) ? $0 : nil }
        }
        o.temperatureUnit = setting("--temperature-unit", o.temperatureUnit, expected: "C, F or system") {
            switch $0 {
            case "c", "celsius": return TemperatureUnit.celsius
            case "f", "fahrenheit": return TemperatureUnit.fahrenheit
            default: return nil
            }
        }
        // The skin's clock, time zone and random numbers (the Mac's own unless given).
        if let raw = value("--time-zone") {
            if let zone = timeZone(raw) { o.timeZone = zone } else {
                o.warnings.append("--time-zone \"\(raw)\" is not a time zone (such as Europe/Oslo or UTC); using "
                                  + "the default")
            }
        } else if arguments.contains("--time-zone") {
            o.warnings.append("--time-zone needs a value; using the default")
        }
        if let raw = value("--clock") {
            if let date = date(raw, zone: o.timeZone ?? TimeZone(identifier: "UTC")!) { o.clock = date } else {
                o.warnings.append("--clock \"\(raw)\" is not an ISO 8601 date and time or a Unix time; using the "
                                  + "Mac's clock")
            }
        } else if arguments.contains("--clock") {
            o.warnings.append("--clock needs a value; using the Mac's clock")
        }
        if let raw = value("--seed") {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if let v = UInt64(text) { o.seed = v } else if let v = Int64(text) { o.seed = UInt64(bitPattern: v) } else {
                o.warnings.append("--seed \"\(raw)\" is not a whole number; using the system's random numbers")
            }
        } else if arguments.contains("--seed") {
            o.warnings.append("--seed needs a value; using the system's random numbers")
        }
        if let raw = value("--data") {
            o.data = raw
        } else if arguments.contains("--data") {
            o.warnings.append("--data needs a file or JSON text; the skin reads this Mac")
        }
        o.stateOutput = value("--state")
        if o.stateOutput == nil, arguments.contains("--state") {
            o.warnings.append("--state needs a file; the state is not written")
        }
        if let raw = value("--color-space") {
            let word = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let space = ColorSpace(rawValue: word) {
                o.colorSpace = space
            } else {
                o.warnings.append("--color-space \"\(raw)\" is not device or srgb; using device")
            }
        } else if arguments.contains("--color-space") {
            o.warnings.append("--color-space needs a value; using device")
        }
        return o
    }

    /// An IANA time zone name (`Europe/Oslo`), `UTC` / `GMT`, or an abbreviation macOS knows (`CET`).
    static func timeZone(_ raw: String) -> TimeZone? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return TimeZone(identifier: name) ?? TimeZone(abbreviation: name)
    }

    /// `--clock`: seconds since 1970 (`1790000000`, `1790000000.5`), or an ISO 8601 date and time with or without a
    /// UTC offset and fractional seconds (`2026-12-31T23:59:58+08:00`, `2026-12-31T23:59:58Z`,
    /// `2026-12-31T23:59:58` in `zone`), or a date alone (midnight in `zone`).
    static func date(_ raw: String, zone: TimeZone) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(text), seconds.isFinite, abs(seconds) < 1e11 { return Date(timeIntervalSince1970: seconds) }
        let iso = ISO8601DateFormatter()
        iso.timeZone = zone
        let local: ISO8601DateFormatter.Options = [.withFullDate, .withTime, .withDashSeparatorInDate,
                                                   .withColonSeparatorInTime]
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
            local, local.union(.withFractionalSeconds), [.withFullDate, .withDashSeparatorInDate],
        ] {
            iso.formatOptions = options
            if let d = iso.date(from: text) { return d }
        }
        return nil
    }

    /// The virtual time the skin runs in with `--clock` (its time zone UTC unless `--time-zone` says otherwise); nil
    /// without `--clock` (the main executor and the Mac's clock, with `--time-zone`'s zone if given). Made on the
    /// thread that renders, which owns the skin.
    func virtualTime() -> VirtualTimeExecutor? {
        guard let clock else { return nil }
        return VirtualTimeExecutor(start: clock, timeZone: timeZone ?? TimeZone(identifier: "UTC")!)
    }

    /// The settings the skin sees, with `system` ones taken from `mac`.
    func regional(system mac: @autoclosure () -> MacRegionalSettings) -> MacRegionalSettings {
        guard let clockHours, let firstWeekday, let temperatureUnit else {
            let m = mac()
            return MacRegionalSettings(clockHours: self.clockHours ?? m.clockHours,
                                       firstWeekday: self.firstWeekday ?? m.firstWeekday,
                                       temperatureUnit: self.temperatureUnit ?? m.temperatureUnit)
        }
        return MacRegionalSettings(clockHours: clockHours, firstWeekday: firstWeekday, temperatureUnit: temperatureUnit)
    }

    /// Whole numbers without ".0". Past Int's range (`--updates -1e20`) Swift's own form ("-1e+20"): converting those
    /// to Int would trap.
    private static func raw(_ v: Double) -> String { Int(exactly: v).map(String.init) ?? String(v) }
}

/// Headless rendering for development and compatibility testing:
///
///     Deskset --render path/to/Skins/Root/Config/Skin.ini --out skin.png [--updates 3] [--interval 1000]
///            [--scale 2] [--background 30,30,30] [--appearance dark] [--clock-hours 12] [--first-weekday 1]
///            [--temperature-unit F] [--clock 2026-12-31T23:59:58+08:00] [--time-zone Asia/Shanghai] [--seed 7]
///            [--data data.json] [--state state.json] [--color-space srgb] [--skins-dir path/to/Skins]
///
/// Loads the skin, runs the requested number of updates (`interval` ms apart, 0 = back to back), draws it
/// off-screen and writes a PNG. Compatibility issues and skin log lines go to stderr. The skin sees the Light
/// appearance unless `--appearance dark` (or `--dark`) or `--appearance system` says otherwise, and a 24-hour clock,
/// weeks from Sunday and °C unless `--clock-hours`, `--first-weekday` or `--temperature-unit` say otherwise.
/// `--clock` runs the skin in virtual time from the given moment (a `VirtualTimeExecutor`; its time zone is UTC unless
/// `--time-zone` says otherwise): update i is at the given time plus i intervals, `!Delay`, ActionTimer and the other
/// timers run at their own virtual times, and nothing waits in real time. Its background work comes back as ordinary
/// work at the next step: a local file is read as a fixture and the weather service is the preview; work without a
/// fake (the network, programs, live system state) runs for real, gets up to one interval of real time to come back
/// before each update, and is listed on stderr as not verifiable. `--time-zone` alone only changes the zone, and
/// `--seed` makes its random numbers (Calc Random, QuotePlugin, Lua's math.random…) the same in every run.
/// `--data` gives what the skin reads about the Mac (system readings, battery, sensors, NowPlaying, audio levels, the
/// weather, Wi-Fi, the desktop picture; `RenderData`): with `--clock` and `--seed`, the same image on every run and
/// every Mac. `--state` writes what the skin ended up with (its measures' values and strings, its meters' frames and
/// texts, its variables) as JSON, to compare runs where pixels may differ (the x86_64 build under Rosetta draws edges
/// a little differently).
enum RenderCommand {
    static func run(_ arguments: [String]) -> Int32 {
        guard let o = RenderOptions.parse(arguments) else {
            fputs(RenderOptions.usage + "\n", stderr)
            return 2
        }
        Log.fileLoggingEnabled = false
        for w in o.warnings { fputs("warning: \(w)\n", stderr) }
        // The settings are fixed for this render only (the self-tests render in the same process as other suites).
        MacRegional.fix(o.regional(system: MacRegionalSettings.system()))
        defer {
            MacRegional.fix(nil)
            MacAppearance.current.refresh()
        }
        applyAppearance(o.appearance)
        // Weather: no network, place names from the bundled table; DESKSET_WEATHER_DEMO=1 draws a demo forecast.
        WeatherWiring.installPreview()
        let fileURL = URL(fileURLWithPath: o.input).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            fputs("error: no such file: \(fileURL.path)\n", stderr)
            return 1
        }
        let output = URL(fileURLWithPath: o.output ?? fileURL.deletingPathExtension().lastPathComponent + ".png")

        let (skinsDir, config) = locate(fileURL, skinsDir: o.skinsDirectory)
        // --data: what the skin reads about the Mac.
        var inputs: RenderData?
        if let argument = o.data {
            do {
                let data = try SkinInputData.load(argument, directory: URL(fileURLWithPath:
                    FileManager.default.currentDirectoryPath))
                for key in data.unknownKeys { fputs("warning: --data: \(key) is not a data key; ignored\n", stderr) }
                inputs = RenderData(data)
            } catch {
                fputs("error: --data: \(error)\n", stderr)
                return 1
            }
        }
        let host = RenderHost()
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: skinsDir,
                        system: inputs?.systemSource(base: SystemMonitor.shared) ?? SystemMonitor.shared, host: host)
        // --clock / --time-zone / --seed: the skin's clock and random numbers (the Mac's own otherwise).
        let virtual = o.virtualTime()
        var restoreServices: () -> Void = {}
        defer { restoreServices() }
        if let virtual {
            skin.runInVirtualTime(virtual)
            // The weather service installed above is the preview (no network, place lookups at once): a fake service.
            virtual.background.setFake(.service, for: .weather)
            virtual.background.setFake(.service, for: .sun)
            virtual.background.addSettleHook { WeatherService.shared.drain() }
            // NowPlaying's position runs on the centre's clock: the virtual one for this render (the demo player then
            // gives the same image on every run).
            let savedClock = NowPlayingCenter.shared.clock
            NowPlayingCenter.shared.clock = { virtual.uptime }
            restoreServices = { NowPlayingCenter.shared.clock = savedClock }
        } else if let zone = o.timeZone {
            skin.skinClock.timeZone = { zone }
        }
        if let seed = o.seed { skin.random = SkinRandom(seed: seed) }
        inputs?.install(for: skin, virtual: virtual)
        defer { inputs?.restore() }
        do {
            try skin.load()
        } catch {
            fputs("error: cannot load \(fileURL.path): \(error)\n", stderr)
            return 1
        }
        Fonts.registerFonts(for: skin)
        for i in 0..<o.updates {
            if i > 0 {
                if let virtual {
                    // Update i is at exactly the start plus i intervals.
                    step(virtual, until: Double(i) * o.interval / 1000,
                         deadline: Date().addingTimeInterval(o.interval / 1000))
                } else {
                    wait(milliseconds: o.interval)
                }
                // --data: frame i of the readings is what update i sees.
                inputs?.advance()
            }
            skin.update()
        }

        let skinW = skin.width.isFinite ? max(skin.width, 1) : 1
        let skinH = skin.height.isFinite ? max(skin.height, 1) : 1
        var scale = o.scale
        let largest = max(skinW, skinH) * scale
        if largest > Double(RenderOptions.maxPixels) {
            scale = Double(RenderOptions.maxPixels) / max(skinW, skinH)
            fputs("warning: skin is \(Int(min(skinW, 1e9)))x\(Int(min(skinH, 1e9))) pt; scale reduced to "
                  + String(format: "%.3f", scale) + "\n", stderr)
        }
        let width = min(max(Int(ceil(skinW * scale)), 1), RenderOptions.maxPixels)
        let height = min(max(Int(ceil(skinH * scale)), 1), RenderOptions.maxPixels)
        guard let png = draw(skin, width: width, height: height, scale: scale, options: o) else {
            fputs("error: cannot create bitmap \(width)x\(height)\n", stderr)
            return 1
        }
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: output)
        } catch {
            fputs("error: cannot write \(output.path): \(error)\n", stderr)
            return 1
        }
        if let stateOutput = o.stateOutput {
            do {
                try state(of: skin).text(pretty: true).appending("\n")
                    .write(toFile: stateOutput, atomically: true, encoding: .utf8)
            } catch {
                fputs("error: cannot write \(stateOutput): \(error)\n", stderr)
                return 1
            }
        }
        print("rendered \(config) \(Int(min(skinW, 1e9)))x\(Int(min(skinH, 1e9))) pt -> \(output.path)")
        for issue in skin.issues { fputs("issue: \(issue)\n", stderr) }
        for line in host.logs { fputs("log: \(line)\n", stderr) }
        for work in virtual?.background.unverifiable ?? [] {
            fputs("note: not verifiable in virtual time: \(work)\n", stderr)
        }
        return 0
    }

    /// `--state`: the skin as it stands — its size, each measure's value, string and whether it is disabled or paused,
    /// each meter's frame, visibility and text (String meters), and its variables (`Skin.runtimeVariables`).
    static func state(of skin: Skin) -> JSONValue {
        func number(_ v: Double) -> JSONValue { v.isFinite ? .number(v) : .string(String(v)) }
        let measures: [JSONValue] = skin.measures.map { m in
            .object(["name": .string(m.name), "value": number(m.value), "string": .string(m.stringValue),
                     "disabled": .bool(m.disabled), "paused": .bool(m.paused)])
        }
        let meters: [JSONValue] = skin.meters.map { m in
            var o: [String: JSONValue] = ["name": .string(m.name), "type": .string(m.type),
                                          "frame": .array([m.frame.x, m.frame.y, m.frame.width, m.frame.height]
                                            .map(number)),
                                          "hidden": .bool(m.hidden)]
            if let text = (m as? StringMeter)?.text { o["text"] = .string(text) }
            return .object(o)
        }
        var variables: [String: JSONValue] = [:]
        for v in skin.runtimeVariables { variables[v.name] = .string(v.value) }
        return .object(["config": .string(skin.config), "width": number(skin.width), "height": number(skin.height),
                        "measures": .array(measures), "meters": .array(meters), "variables": .object(variables)])
    }

    /// Draws the skin into a new bitmap of `width` × `height` pixels at `scale` and returns it as PNG: in the device
    /// RGB space (`--color-space device`, the default: the bytes `--render` always wrote), or in 8-bit premultiplied
    /// sRGB (`--color-space srgb`). nil when the bitmap cannot be made.
    static func draw(_ skin: Skin, width: Int, height: Int, scale: Double, options o: RenderOptions) -> Data? {
        func paint(_ cg: CGContext) {
            cg.clear(CGRect(x: 0, y: 0, width: width, height: height))
            if let background = o.background {
                cg.setFillColor(background.cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            // Flip to Rainmeter's top-left origin and scale to the requested backing scale.
            cg.translateBy(x: 0, y: CGFloat(height))
            cg.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
            let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = flipped
            // No window, so MacGlass shows as a stand-in, drawn for the background when one is given.
            SkinRenderer.draw(skin, in: cg, glass: .placeholder(dark: o.background.map(GlassPlaceholder.isDark)))
            NSGraphicsContext.restoreGraphicsState()
        }
        switch o.colorSpace {
        case .device:
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            paint(context.cgContext)
            return rep.representation(using: .png, properties: [:])
        case .srgb:
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            paint(cg)
            guard let image = cg.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
    }

    /// Makes the app's appearance the one asked for, and publishes it for the skin (`MacAppearance`, SysColor).
    static func applyAppearance(_ appearance: RenderOptions.Appearance) {
        _ = NSApplication.shared
        switch appearance {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
        MacAppearance.current.refresh()
        DesktopInputs.appearance.refresh()
    }

    /// Waits between updates while letting queued main-thread work run (!Delay, asynchronous results). The run
    /// loop returns at once when nothing is scheduled, so the rest of the time is slept rather than spun.
    static func wait(milliseconds: Double) {
        let until = Date().addingTimeInterval(max(milliseconds, 0) / 1000)
        repeat {
            if !RunLoop.main.run(mode: .default, before: until) {
                let left = until.timeIntervalSinceNow
                if left > 0 { Thread.sleep(forTimeInterval: min(left, 0.01)) }
            }
        } while Date() < until
    }

    /// Virtual time, between two updates: moves the skin's executor on to `time`, running what falls due. Real work —
    /// the skin's background work without a fake, and the services' own threads — gets until `deadline` (one interval
    /// of real time, as long as the wait without `--clock`) to hand its results over first, and so does real work that
    /// the step itself started: it then comes back as work due now, before the update.
    static func step(_ virtual: VirtualTimeExecutor, until time: TimeInterval, deadline: Date) {
        virtual.background.settle(timeout: deadline.timeIntervalSinceNow)
        settleServices(before: deadline)
        virtual.advance(until: time)
        while virtual.background.outstanding > 0, Date() < deadline {
            virtual.background.settle(timeout: deadline.timeIntervalSinceNow)
            settleServices(before: deadline)
            virtual.runUntilIdle()
        }
    }

    /// Virtual time, before each update: the services outside the skin that work on threads of their own (NowPlaying,
    /// Wi-Fi, the focused window) finish what they have under way, and what they and other services queued for the
    /// main thread is delivered, so that it reaches the skin as it did during a real wait. Waits for conditions, never
    /// for a fixed time, and not past `deadline`.
    static func settleServices(before deadline: Date) {
        for _ in 0..<8 {
            MediaUIWorker.waitForAll(before: deadline)
            var delivered = false
            while Date() < deadline, CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource { delivered = true }
            if !delivered { return }
        }
    }

    /// Finds the Skins folder (an ancestor named "Skins", else the file's grandparent) and the config name.
    static func locate(_ file: URL, skinsDir: String?) -> (URL, String) {
        let parent = file.deletingLastPathComponent()
        var root: URL
        if let skinsDir {
            root = URL(fileURLWithPath: skinsDir).standardizedFileURL
        } else {
            root = parent.deletingLastPathComponent()
            var cursor = parent
            while cursor.pathComponents.count > 1 {
                let name = cursor.lastPathComponent
                if name.caseInsensitiveCompare("Skins") == .orderedSame || name == "DefaultSkins" || name == "TestSkins" {
                    root = cursor
                    break
                }
                cursor.deleteLastPathComponent()
            }
        }
        let rootComponents = root.pathComponents
        let parentComponents = parent.pathComponents
        let config = parentComponents.starts(with: rootComponents)
            ? parentComponents.dropFirst(rootComponents.count).joined(separator: "\\") : ""
        return (root, config.isEmpty ? parent.lastPathComponent : config)
    }
}

/// SkinHost used by `--render` and for checking skins that are not loaded: same metrics as the app, no window.
final class RenderHost: SkinHost {
    var logs: [String] = []

    func skinNeedsDisplay(_ skin: Skin) {}
    func skin(_ skin: Skin, handle bang: Bang) -> Bool { true }
    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {}
    func skin(_ skin: Skin, execute target: String, arguments: [String]) {}
    func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {
        if logs.count < 10_000 { logs.append("[\(level.rawValue)] \(message)") }
    }
    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
        SkinRenderer.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
    }
    func imageSize(atPath path: String) -> (width: Double, height: Double)? { Images.size(atPath: path) }
    func environment(for skin: Skin) -> SkinEnvironment {
        var env = SkinController.environment(windowFrame: nil)
        env.windowFrame = SkinRect(width: skin.width, height: skin.height)
        return env
    }
}
