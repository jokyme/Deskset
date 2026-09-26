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
    var warnings: [String] = []

    static let maxUpdates = 100_000
    static let maxInterval = 60_000.0
    static let scaleRange = 0.25...8.0
    /// Largest bitmap side in pixels; the scale is reduced to fit.
    static let maxPixels = 16_384

    static let usage = "usage: Deskset --render Skin.ini [--out out.png] [--updates N] [--interval ms] [--scale S] "
        + "[--background R,G,B[,A]] [--skins-dir DIR]"

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
        return o
    }

    private static func raw(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
}

/// Headless rendering for development and compatibility testing:
///
///     Deskset --render path/to/Skins/Root/Config/Skin.ini --out skin.png [--updates 3] [--interval 1000]
///            [--scale 2] [--background 30,30,30] [--skins-dir path/to/Skins]
///
/// Loads the skin, runs the requested number of updates (`interval` ms apart, 0 = back to back), draws it
/// off-screen and writes a PNG. Compatibility issues and skin log lines go to stderr.
enum RenderCommand {
    static func run(_ arguments: [String]) -> Int32 {
        guard let o = RenderOptions.parse(arguments) else {
            fputs(RenderOptions.usage + "\n", stderr)
            return 2
        }
        Log.fileLoggingEnabled = false
        for w in o.warnings { fputs("warning: \(w)\n", stderr) }
        let fileURL = URL(fileURLWithPath: o.input).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            fputs("error: no such file: \(fileURL.path)\n", stderr)
            return 1
        }
        let output = URL(fileURLWithPath: o.output ?? fileURL.deletingPathExtension().lastPathComponent + ".png")

        let (skinsDir, config) = locate(fileURL, skinsDir: o.skinsDirectory)
        let host = RenderHost()
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
        // Flip to Rainmeter's top-left origin and scale to the requested backing scale.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        SkinRenderer.draw(skin, in: cg)
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
