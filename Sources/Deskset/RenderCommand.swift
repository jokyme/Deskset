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
    /// `--wallpaper`: a picture that stands in for the desktop picture: Chameleon `Type=Desktop` samples it, and the
    /// part under the skin is drawn behind it. Without it, `--background` stands in for a desktop of one color.
    var wallpaper: String?
    /// `--at X,Y`: the skin window's top-left corner on the screen (points; `#CURRENTCONFIGX#`, `CropDesktop=Skin`).
    var at = CGPoint.zero
    /// `--screen WxH`: the screen's size in points, with a stand-in desktop (`--wallpaper`, `--background`), so that
    /// renders are the same on every Mac.
    var screen = RenderOptions.standardScreen
    var warnings: [String] = []

    /// A 14-inch MacBook Pro's screen at its default resolution.
    static let standardScreen = CGSize(width: 1512, height: 982)

    enum Appearance: String, Equatable {
        case light, dark, system
    }

    static let maxUpdates = 100_000
    static let maxInterval = 60_000.0
    static let scaleRange = 0.25...8.0
    /// Largest bitmap side in pixels; the scale is reduced to fit.
    static let maxPixels = 16_384

    static let usage = "usage: Deskset --render Skin.ini [--out out.png] [--updates N] [--interval ms] [--scale S] "
        + "[--background R,G,B[,A]] [--appearance light|dark|system] [--dark] [--clock-hours 12|24|system] "
        + "[--first-weekday 0-6|system] [--temperature-unit C|F|system] [--wallpaper FILE] [--at X,Y] "
        + "[--screen WxH] [--skins-dir DIR]"

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
        if let raw = value("--wallpaper") {
            o.wallpaper = raw
        } else if arguments.contains("--wallpaper") {
            o.warnings.append("--wallpaper needs a picture file")
        }
        func pair(_ flag: String, separators: Set<Character>) -> (Double, Double)? {
            guard let raw = value(flag) else {
                if arguments.contains(flag) { o.warnings.append("\(flag) needs a value; using the default") }
                return nil
            }
            let parts = raw.split(whereSeparator: { separators.contains($0) })
                .map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let a = parts[0], let b = parts[1], a.isFinite, b.isFinite else {
                o.warnings.append("--\(flag.dropFirst(2)) \"\(raw)\" is not two numbers; using the default")
                return nil
            }
            return (a, b)
        }
        if let (x, y) = pair("--at", separators: [","]) {
            o.at = CGPoint(x: min(max(x, -100_000), 100_000), y: min(max(y, -100_000), 100_000))
        }
        if let (w, h) = pair("--screen", separators: ["x", "X", ","]) {
            if w >= 1, h >= 1 {
                o.screen = CGSize(width: min(w, 100_000), height: min(h, 100_000))
            } else {
                o.warnings.append("--screen \(raw(w))x\(raw(h)) is empty; using the default")
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
        return o
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

    /// The screen and desktop picture that stand in for the Mac's: `--wallpaper` (laid as macOS's default, Fill
    /// Screen), else a desktop of the `--background` color; nil without either (the Mac's own).
    var standInDesktop: ScreenDesktop? {
        let area = CGRect(origin: .zero, size: screen)
        if let wallpaper {
            let path = URL(fileURLWithPath: wallpaper).standardizedFileURL.path
            return ScreenDesktop(picture: path, frame: area, area: area)
        }
        if let background {
            func channel(_ v: Double) -> Int { v.isFinite ? Int(min(max(v, 0), 255).rounded()) : 0 }
            return ScreenDesktop(picture: "", frame: area, area: area,
                                 solid: ChameleonColor(r: channel(background.r), g: channel(background.g),
                                                       b: channel(background.b)))
        }
        return nil
    }

    /// Whole numbers without ".0". Past Int's range (`--updates -1e20`) Swift's own form ("-1e+20"): converting those
    /// to Int would trap.
    private static func raw(_ v: Double) -> String { Int(exactly: v).map(String.init) ?? String(v) }
}

/// Headless rendering for development and compatibility testing:
///
///     Deskset --render path/to/Skins/Root/Config/Skin.ini --out skin.png [--updates 3] [--interval 1000]
///            [--scale 2] [--background 30,30,30] [--appearance dark] [--clock-hours 12] [--first-weekday 1]
///            [--temperature-unit F] [--skins-dir path/to/Skins]
///
/// Loads the skin, runs the requested number of updates (`interval` ms apart, 0 = back to back), draws it
/// off-screen and writes a PNG. Compatibility issues and skin log lines go to stderr. The skin sees the Light
/// appearance unless `--appearance dark` (or `--dark`) or `--appearance system` says otherwise, and a 24-hour clock,
/// weeks from Sunday and °C unless `--clock-hours`, `--first-weekday` or `--temperature-unit` say otherwise.
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

        if let wallpaper = o.wallpaper, !FileManager.default.fileExists(atPath: wallpaper) {
            fputs("error: no such file: \(wallpaper)\n", stderr)
            return 1
        }
        // A stand-in desktop: what Chameleon samples, and the screen the skin sees.
        let standIn = o.standInDesktop
        DesktopInputs.fake.access { $0 = standIn.map { [$0] } }
        defer { DesktopInputs.fake.access { $0 = nil } }

        let (skinsDir, config) = locate(fileURL, skinsDir: o.skinsDirectory)
        let host = RenderHost()
        host.windowOrigin = o.at
        if let standIn {
            let a = SkinRect(x: 0, y: 0, width: Double(standIn.area.width), height: Double(standIn.area.height))
            host.screens = [SkinScreen(area: a, workArea: a)]
        }
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: skinsDir, system: SystemMonitor.shared,
                        host: host)
        do {
            try skin.load()
        } catch {
            fputs("error: cannot load \(fileURL.path): \(error)\n", stderr)
            return 1
        }
        Fonts.registerFonts(for: skin)
        for i in 0..<o.updates {
            if i > 0 { wait(milliseconds: o.interval) }
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
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            fputs("error: cannot create bitmap \(width)x\(height)\n", stderr)
            return 1
        }
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if let background = o.background {
            cg.setFillColor(background.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        // The wallpaper behind the skin, where it sits.
        if let standIn, !standIn.picture.isEmpty {
            let dark = skin.host?.environment(for: skin).appearance.isDark ?? false
            let picture = WallpaperImages.large(file: standIn.picture, dark: dark,
                                                maxPixels: Int(max(standIn.area.width, standIn.area.height) * scale))
            let window = CGRect(x: o.at.x, y: o.at.y, width: CGFloat(skinW), height: CGFloat(skinH))
            DesktopSampler.draw(picture, desktop: standIn, region: window.offsetBy(dx: -standIn.area.minX, dy: -standIn.area.minY),
                                into: cg, size: CGSize(width: width, height: height))
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

        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: output)
        } catch {
            fputs("error: cannot write \(output.path): \(error)\n", stderr)
            return 1
        }
        print("rendered \(config) \(Int(min(skinW, 1e9)))x\(Int(min(skinH, 1e9))) pt -> \(output.path)")
        for issue in skin.issues { fputs("issue: \(issue)\n", stderr) }
        for line in host.logs { fputs("log: \(line)\n", stderr) }
        return 0
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
    /// Where the skin window's top-left corner is (`--at`).
    var windowOrigin = CGPoint.zero
    /// The screens the skin sees instead of the Mac's (a stand-in desktop).
    var screens: [SkinScreen]?

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
        if let screens { env.screens = screens }
        env.windowFrame = SkinRect(x: Double(windowOrigin.x), y: Double(windowOrigin.y), width: skin.width,
                                   height: skin.height)
        return env
    }
}
