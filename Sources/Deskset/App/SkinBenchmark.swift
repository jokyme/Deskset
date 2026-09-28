import AppKit
import DesksetCore

/// What a skin costs while it runs, measured without a window:
///
///     Deskset --benchmark Skin.ini… [--seconds N] [--warmup N] [--scale S] [--appearance light|dark] [--skins-dir DIR]
///
/// Each skin updates at its own `Update` rate on the skin's executor, as a skin window's timer does, and every update
/// draws the window's picture as a skin window does (`SkinBitmapDrawing`, kept pictures included). After `--warmup`
/// seconds (default 2) it measures for `--seconds` (default 10): the time of an update and of a drawing, the main
/// thread's CPU time and the whole process's (the audio analysis and the demo signal included) per wall second, and
/// what the kept pictures did. Not included: what Core Animation and the window server do with the picture afterwards.
///
/// Like `--render` it never asks for a permission and captures no audio: `DESKSET_AUDIO_DEMO=1` gives visualizers the
/// demo signal, `DESKSET_NOWPLAYING_DEMO=1` a playing track. Skins run one after another, from a temporary copy of
/// their Skins folder (whatever they write stays there).
enum SkinBenchmark {
    struct Options: Equatable {
        var paths: [String] = []
        var seconds = 10.0
        var warmup = 2.0
        var scale: CGFloat = 2
        var appearance = RenderOptions.Appearance.light
        var skinsDirectory: String?
    }

    struct Result {
        var config = ""
        var file = ""
        var seconds = 0.0
        var updates = 0
        /// Milliseconds per update and per drawing (means), and the slowest drawing.
        var updateMs = 0.0
        var drawMs = 0.0
        var worstDrawMs = 0.0
        /// CPU time per wall second, in percent of one core.
        var mainThreadPercent = 0.0
        var processPercent = 0.0
        /// Per drawing: kept pictures copied, pictures made, meters drawn directly.
        var copied = 0.0
        var made = 0.0
        var drawn = 0.0
    }

    static let usage = "usage: Deskset --benchmark Skin.ini… [--seconds N] [--warmup N] [--scale S] "
        + "[--appearance light|dark] [--skins-dir DIR]"

    static func parse(_ arguments: [String]) -> Options? {
        guard let start = arguments.firstIndex(of: "--benchmark") else { return nil }
        var o = Options()
        var i = start + 1
        while i < arguments.count {
            let a = arguments[i]
            let v = i + 1 < arguments.count ? arguments[i + 1] : ""
            switch a {
            case "--seconds":
                if let n = Double(v), n.isFinite { o.seconds = min(max(n, 0.5), 600) }
                i += 2
            case "--warmup":
                if let n = Double(v), n.isFinite { o.warmup = min(max(n, 0), 60) }
                i += 2
            case "--scale":
                if let n = Double(v), n.isFinite { o.scale = CGFloat(min(max(n, 0.5), 4)) }
                i += 2
            case "--appearance":
                if let a = RenderOptions.Appearance(rawValue: v.lowercased()) { o.appearance = a }
                i += 2
            case "--skins-dir":
                o.skinsDirectory = v
                i += 2
            default:
                if !a.hasPrefix("--") { o.paths.append(a) }
                i += 1
            }
        }
        return o.paths.isEmpty ? nil : o
    }

    static func run(_ arguments: [String]) -> Int32 {
        guard let o = parse(arguments) else {
            fputs(usage + "\n", stderr)
            return 2
        }
        MacRegional.fix(MacRegionalSettings.standard)
        defer { MacRegional.fix(nil) }
        RenderCommand.applyAppearance(o.appearance)
        WeatherWiring.installPreview()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesksetBenchmark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var failed = false
        for (index, path) in o.paths.enumerated() {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                fputs("error: no such file: \(url.path)\n", stderr)
                failed = true
                continue
            }
            let (root, _) = RenderCommand.locate(url, skinsDir: o.skinsDirectory)
            let copy = temporary.appendingPathComponent("Skins\(index)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: root, to: copy)
            } catch {
                fputs("error: cannot copy \(root.path): \(error.localizedDescription)\n", stderr)
                failed = true
                continue
            }
            let file = copy.appendingPathComponent(String(url.path.dropFirst(root.path.count)))
            guard let result = measure(file, skinsRoot: copy, options: o) else {
                failed = true
                continue
            }
            print(report(result))
        }
        return failed ? 1 : 0
    }

    static func report(_ r: Result) -> String {
        func f(_ v: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", v) }
        let rate = r.seconds > 0 ? Double(r.updates) / r.seconds : 0
        return """
            \(r.config) \(r.file): \(r.updates) updates in \(f(r.seconds, 1)) s (\(f(rate, 1)) a second)
              update \(f(r.updateMs)) ms · drawing \(f(r.drawMs)) ms (slowest \(f(r.worstDrawMs, 2)) ms)
              pictures per drawing: \(f(r.copied, 2)) copied, \(f(r.made, 2)) made, \(f(r.drawn, 2)) meters drawn
              CPU: main thread \(f(r.mainThreadPercent, 2)) % · process \(f(r.processPercent, 2)) % of one core
            """
    }

    /// Runs one skin and measures it; nil when it does not load.
    static func measure(_ file: URL, skinsRoot: URL, options o: Options) -> Result? {
        let parent = file.deletingLastPathComponent().standardizedFileURL.pathComponents
        let config = parent.dropFirst(skinsRoot.standardizedFileURL.pathComponents.count).joined(separator: "\\")
        var result = Result(config: config, file: file.lastPathComponent)
        let host = RenderHost()
        let skin = Skin(config: config, fileURL: file, skinsDirectory: skinsRoot, system: SystemMonitor.shared, host: host)
        do {
            try skin.load()
        } catch {
            fputs("error: cannot load \(file.path): \(error)\n", stderr)
            return nil
        }
        defer { skin.close() }
        Fonts.registerFonts(for: skin)
        // The main display's color space, as a skin window on it draws in.
        guard let space = NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let drawing = SkinBitmapDrawing()
        var measuring = false
        var updates = 0
        var updateTime = 0.0, drawTime = 0.0, worstDraw = 0.0
        var copied = 0, made = 0, drawn = 0
        var lastInterval = SkinController.updateInterval(skin.settings.update)
        var timer: SkinScheduledWork?

        func tick() {
            let t0 = ProcessInfo.processInfo.systemUptime
            skin.update()
            let t1 = ProcessInfo.processInfo.systemUptime
            let size = CGSize(width: max(skin.width, 1), height: max(skin.height, 1))
            let image = drawing.picture(of: skin, size: size, scale: o.scale, space: space, appearance: "benchmark")
            let t2 = ProcessInfo.processInfo.systemUptime
            withExtendedLifetime(image) {}
            if measuring {
                updates += 1
                updateTime += t1 - t0
                drawTime += t2 - t1
                worstDraw = max(worstDraw, t2 - t1)
                copied += drawing.lastStats.copied
                made += drawing.lastStats.made
                drawn += drawing.lastStats.drawn
            }
            // A skin that changes its own Update (a tempo switch without a refresh) gets a new clock, as in a window.
            let interval = SkinController.updateInterval(skin.settings.update)
            if interval != lastInterval {
                lastInterval = interval
                schedule()
            }
        }
        func schedule() {
            timer?.cancel()
            timer = nil
            guard let interval = lastInterval else { return }
            timer = skin.executor.timer(interval: interval, leeway: SkinController.timerTolerance(interval),
                                        repeats: true) { tick() }
        }

        tick()
        schedule()
        RenderCommand.wait(milliseconds: o.warmup * 1000)
        measuring = true
        let wall0 = ProcessInfo.processInfo.systemUptime
        let main0 = threadCPUTime(), process0 = processCPUTime()
        RenderCommand.wait(milliseconds: o.seconds * 1000)
        let wall = ProcessInfo.processInfo.systemUptime - wall0
        let main = threadCPUTime() - main0, process = processCPUTime() - process0
        measuring = false
        timer?.cancel()

        result.seconds = wall
        result.updates = updates
        let n = Double(max(updates, 1))
        result.updateMs = updateTime / n * 1000
        result.drawMs = drawTime / n * 1000
        result.worstDrawMs = worstDraw * 1000
        result.copied = Double(copied) / n
        result.made = Double(made) / n
        result.drawn = Double(drawn) / n
        result.mainThreadPercent = wall > 0 ? main / wall * 100 : 0
        result.processPercent = wall > 0 ? process / wall * 100 : 0
        for issue in skin.issues { fputs("issue: \(issue)\n", stderr) }
        return withExtendedLifetime(host) { result }
    }

    /// CPU time (user + system) of the calling thread, in seconds.
    static func threadCPUTime() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        func seconds(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1_000_000 }
        return seconds(info.user_time) + seconds(info.system_time)
    }

    /// CPU time (user + system) of the whole process, in seconds.
    static func processCPUTime() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
