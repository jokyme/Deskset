import AppKit
import DesksetCore

/// Command-line modes of the Deskset binary (development and build tools). Each runs and exits.
///
///     Deskset --render Skin.ini --out x.png [...]         headless skin rendering (see RenderCommand)
///     Deskset --verify-drawing-cache Skins… [...]          kept pictures against full drawings (DrawingCacheCheck)
///     Deskset --self-test [filter]                         app-level checks (window rules, state, UI, install flow)
///     Deskset --make-icon Deskset.iconset                   writes the app icon PNGs (build-app.sh)
///     Deskset --snapshot-ui manage|inspector|settings|install|icon|menubar --out x.png [--dark] [--skins-dir DIR]
///     Deskset --system-report                              prints every system reading
///     Deskset --weather-report [--location PLACE] [...]    one MET Norway forecast (see WeatherReportCommand)
///     Deskset --cover-lookup ARTIST TITLE [ALBUM]          NowPlaying's online cover lookup, every request printed
///     Deskset --help | -h                                  prints the usage
///
/// An argument starting with `--` that is not one of these flags (a typo such as `--selftest`), or option flags
/// without a mode, print the usage to stderr and exit with status 2: the menu bar app never starts on a mistyped
/// development command, where it would load and change the user's real skins and settings. Other arguments are left
/// alone, so launches by Finder / LaunchServices (`-psn_…`) and AppKit defaults such as
/// `-NSDocumentRevisionsDebugMode YES` still start the app.
enum CommandLineTools {
    /// Flags that select a mode (in none of them does audio capture start: `AudioCaptureEngine.captureAllowed`).
    static let modeFlags = ["--render", "--self-test", "--snapshot-ui", "--system-report", "--make-icon",
                            "--cover-lookup", "--weather-report", "--verify-drawing-cache", "--benchmark"]
    /// Flags that go with a mode (`--render`'s and `--snapshot-ui`'s options).
    static let optionFlags: Set<String> = ["--out", "--updates", "--interval", "--scale", "--background", "--skins-dir",
                                           "--settings-dir",
                                           "--dark", "--appearance", "--select", "--size", "--zoom",
                                           "--clock-hours", "--first-weekday", "--temperature-unit",
                                           "--clock", "--time-zone", "--seed", "--color-space", "--data", "--state",
                                           "--locale", "--languages", "--accent-color", "--screen",
                                           "--wallpaper", "--at",
                                           // The skin editor, library, code editor and Settings snapshots.
                                           "--mode", "--tab", "--code-below", "--inspector-width", "--config",
                                           "--category", "--search", "--pane",
                                           // The Manage window snapshot.
                                           "--hidden", "--coordinates",
                                           // States of the skin editor (docs/editor-friendly.md §14.0).
                                           "--hover", "--drag", "--expert", "--tip", "--expand", "--edit-text", "--scroll",
                                           // --weather-report.
                                           "--location", "--units", "--offline", "--now",
                                           // --benchmark.
                                           "--seconds", "--warmup"]
    /// Option flags of development builds only (not in the usage): `--render --legacy` draws with the frozen renderer.
    #if DEBUG
    static let debugOptionFlags: Set<String> = ["--legacy"]
    #else
    static let debugOptionFlags: Set<String> = []
    #endif

    static let usage = """
        usage: Deskset                   start the menu bar app
               Deskset --render Skin.ini [--out out.png] [--updates N] [--interval ms] [--scale S]
                      [--background R,G,B[,A]] [--appearance light|dark|system] [--dark] [--skins-dir DIR]
                      [--clock-hours 12|24|system] [--first-weekday 0-6|system] [--temperature-unit C|F|system]
                      [--clock ISO8601|UNIX] [--time-zone ID] [--seed N] [--data FILE|JSON]
                      [--state out.json] [--color-space device|srgb] [--settings-dir DIR]
                      [--locale ID|system] [--languages LIST|system] [--accent-color R,G,B[,A]|system]
                      [--wallpaper FILE] [--at X,Y] [--screen WxH|system]
                                        draw a skin without a window into a PNG (--wallpaper: a picture that
                                        stands in for the desktop, drawn behind the skin at --at; --background
                                        alone stands in for a desktop of one color)
               Deskset --verify-drawing-cache SkinsFolder|Skin.ini… [--updates N] [--scale S] [--skins-dir DIR]
                                        check that skin windows' kept pictures match full drawings
               Deskset --benchmark Skin.ini… [--seconds N] [--warmup N] [--scale S] [--appearance light|dark]
                      [--skins-dir DIR]
                                        run skins without a window and print what an update and a drawing cost
               Deskset --self-test [filter]
                                        run the app's self-tests
               Deskset --snapshot-ui manage|inspector|settings|codeeditor|library|install|install-zip|icon|menubar
                      [--out x.png] [--dark] [--select NAME|A,B|none] [--size WxH] [--zoom N] [--skins-dir DIR]
                      [--mode design|split|code] [--tab add|layers|live] [--code-below] [--inspector-width N]
                      [--config NAME] [--category NAME] [--search TEXT] [--pane general|editor]
                      [--hover NAME] [--drag NAME:DX,DY] [--expert] [--tip N] [--expand NAME] [--edit-text NAME]
                      [--scroll "CARD TITLE"] [--hidden] [--coordinates X,Y]
                                        draw app UI off-screen into a PNG
               Deskset --system-report   print every system reading skins can get
               Deskset --weather-report [--location PLACE|LAT,LON|timezone] [--units auto|metric|imperial]
                      [--offline FILE] [--now ISO8601]
                                        get one forecast from MET Norway (sends the place's rounded coordinates)
               Deskset --cover-lookup ARTIST TITLE [ALBUM]
                                        look a cover up online as NowPlaying does (sends the names to Apple)
               Deskset --make-icon Output.iconset
                                        write the app icon images
               Deskset --help            print this help

        Every mode gives skins a temporary #SETTINGSPATH# (removed at exit) unless --settings-dir DIR names one, so
        skins that keep settings or caches there never read or write the app's real settings folder.
        """

    enum Validation: Equatable {
        /// No command-line mode flag: start the app.
        case app
        /// A mode flag: run that mode.
        case mode
        case help
        /// The message printed before the usage.
        case invalid(String)
    }

    /// What the arguments ask for (`arguments[0]` is the program).
    static func validate(_ arguments: [String]) -> Validation {
        let args = Array(arguments.dropFirst())
        if args.contains(where: { $0 == "--help" || $0 == "-h" }) { return .help }
        let known = Set(modeFlags).union(optionFlags).union(debugOptionFlags)
        let unknown = args.filter { $0.hasPrefix("--") && !known.contains($0) }
        if !unknown.isEmpty {
            let shown = unknown.prefix(5).map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 }
            return .invalid("unknown option" + (unknown.count == 1 ? " " : "s ") + shown.joined(separator: ", "))
        }
        if args.contains(where: { modeFlags.contains($0) }) { return .mode }
        if let option = args.first(where: { optionFlags.contains($0) || debugOptionFlags.contains($0) }) {
            return .invalid("\(option) needs one of --render, --snapshot-ui, --weather-report, --benchmark")
        }
        return .app
    }

    /// The Windows "ANSI" code page that legacy skin files are read and written in (`TextDecoding.ansiCodePage`): the
    /// one of the Mac's first preferred language (zh-Hans → 936 GBK, zh-Hant → 950 Big5, ja → 932, ru → 1251…), as
    /// Rainmeter uses the Windows locale's. It applies to the menu bar app (with the Skin Studio and the installer) and
    /// to every command-line mode. nil under `--self-test`: the checks keep the core's 1252 so they read the same on
    /// every Mac, and suites that need another code page set it and restore it.
    static func ansiCodePage(for arguments: [String],
                             preferredLanguages: [String] = SkinEnvironment.systemPreferredLanguages()) -> Int? {
        if arguments.dropFirst().contains("--self-test") { return nil }
        return TextDecoding.defaultANSICodePage(preferredLanguages: preferredLanguages)
    }

    /// Sets `TextDecoding.ansiCodePage` for these arguments (see `ansiCodePage(for:)`). Called first thing at startup:
    /// the setting is not synchronised, so it must be in place before any skin loads, on any thread.
    static func useANSICodePage(for arguments: [String],
                                preferredLanguages: [String] = SkinEnvironment.systemPreferredLanguages()) {
        if let codePage = ansiCodePage(for: arguments, preferredLanguages: preferredLanguages) {
            TextDecoding.ansiCodePage = codePage
        }
    }

    /// `--render` runs again as a new process image with `SWIFT_DETERMINISTIC_HASHING=1` when that is not set yet:
    /// Swift seeds the order of every set and dictionary at random in each process (and for each instance), and a few
    /// places still let that order reach a skin (Chameleon's colors of equal weight), so without it two renders with
    /// the same `--clock`, `--seed` and `--data` could differ. Called first thing at startup; returns only when there is
    /// nothing to do or the new image could not be started (the render then goes on with the process's own seed).
    static func makeHashingDeterministic(for arguments: [String]) {
        guard arguments.dropFirst().contains("--render"),
              ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == nil,
              let path = Bundle.main.executablePath else { return }
        setenv("SWIFT_DETERMINISTIC_HASHING", "1", 1)
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        execv(path, &argv)
        unsetenv("SWIFT_DETERMINISTIC_HASHING")
    }

    /// Temporary settings folders more than a day old: left by a mode that was killed or crashed before it could remove
    /// its own (both spellings, since earlier builds named them "Deskset-settings-…").
    static func removeStaleHeadlessSettingsFolders(now: Date = Date()) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix("DesksetSettings-") || name.hasPrefix("Deskset-settings-") {
            let url = root.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > 24 * 3600 else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Points `SkinController.settingsPath` at `folder` (created if missing), or at a new temporary folder that the
    /// caller removes: returned so it can. Either way it holds a `Stationery.inc` as the app's does (made only when
    /// missing), so the Stationery widgets save as they do in the app.
    static func useHeadlessSettingsFolder(_ folder: String?) -> URL? {
        let fm = FileManager.default
        let temporary = folder == nil
        if temporary { removeStaleHeadlessSettingsFolders() }
        let url = folder.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            // Not "Deskset-…": the core self-tests count those in the shared temporary folder as their own leftovers, and a
            // render running next to them would show up there.
            ?? fm.temporaryDirectory.appendingPathComponent("DesksetSettings-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        let suiteFile = url.appendingPathComponent(DefaultSkins.stationeryFileName)
        if !fm.fileExists(atPath: suiteFile.path) {
            fm.createFile(atPath: suiteFile.path, contents: Data(DefaultSkins.stationeryFileHeader.utf8))
        }
        SkinController.settingsPath = url.path + "/"
        return temporary ? url : nil
    }

    static func run(_ arguments: [String]) -> Int32? {
        switch validate(arguments) {
        case .app:
            return nil
        case .help:
            print(usage)
            return 0
        case .invalid(let message):
            fputs("Deskset: \(message)\n\(usage)\n", stderr)
            return 2
        case .mode:
            break
        }
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count,
                  !arguments[i + 1].hasPrefix("--") else { return nil }
            return arguments[i + 1]
        }
        // #SETTINGSPATH# of every skin a mode loads: the folder --settings-dir names, else a temporary one. Skins keep
        // what people type and cached icons there (the Stationery widgets' Stationery.inc), so a render must never
        // write into the app's real settings folder. The self-tests and the drawing check set their own on top.
        let temporarySettings = useHeadlessSettingsFolder(value(after: "--settings-dir"))
        defer { if let temporarySettings { try? FileManager.default.removeItem(at: temporarySettings) } }
        if arguments.contains("--render") {
            return RenderCommand.run(arguments)
        }
        if arguments.contains("--verify-drawing-cache") {
            prepareHeadless()
            return DrawingCacheCheck.run(arguments)
        }
        if arguments.contains("--benchmark") {
            prepareHeadless()
            return SkinBenchmark.run(arguments)
        }
        if arguments.contains("--make-icon") {
            guard let dir = value(after: "--make-icon") else {
                fputs("usage: Deskset --make-icon Output.iconset\n", stderr)
                return 2
            }
            do {
                try AppIcon.writeIconset(to: URL(fileURLWithPath: dir))
                print("wrote \(AppIcon.iconsetEntries.count) icon images to \(dir)")
                return 0
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        if arguments.contains("--self-test") {
            prepareHeadless()
            return AppSelfTest.run(filter: value(after: "--self-test"))
        }
        if arguments.contains("--snapshot-ui") {
            prepareHeadless()
            return UISnapshot.run(arguments)
        }
        if arguments.contains("--cover-lookup") {
            Log.fileLoggingEnabled = false
            return NowPlayingCoverLookup.runCommand(arguments)
        }
        if arguments.contains("--system-report") {
            Log.fileLoggingEnabled = false
            _ = NSApplication.shared
            return SystemReport.run()
        }
        if arguments.contains("--weather-report") {
            _ = NSApplication.shared
            return WeatherReportCommand.run(arguments)
        }
        return nil
    }

    /// AppKit without a Dock icon, menu bar or visible windows, and without touching the user's log.
    static func prepareHeadless() {
        Log.fileLoggingEnabled = false
        Log.mirrorsToStandardError = false
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }
}

/// `Deskset --system-report`: every reading the skins can get, for comparing with `top`, `vm_stat`, `netstat -ib`,
/// `df`, `pmset -g batt`, `sysctl`.
enum SystemReport {
    static func run() -> Int32 {
        let m = SystemMonitor.shared
        func gb(_ v: Double) -> String { String(format: "%.2f GB", v / 1_073_741_824) }
        _ = m.cpuUsage(processor: 0)
        RenderCommand.wait(milliseconds: 1000)
        let cpu = m.cpuUsage(processor: 0)
        print(String(format: "CPU total: %.1f%% (%d cores)", cpu, m.processorCount))
        let cores = (1...m.processorCount).map { String(format: "%.0f", m.cpuUsage(processor: $0)) }
        print("CPU per core: " + cores.joined(separator: " "))
        let mem = m.memoryStatus()
        print("Physical memory: used \(gb(mem.physicalUsed)) of \(gb(mem.physicalTotal))")
        print("Swap: used \(gb(mem.swapUsed)) of \(gb(mem.swapTotal))")
        print("Active interfaces: \(m.networkInterfaces().joined(separator: ", "))")
        print("Best interface: \(m.resolveAdapter("Best") ?? "-")")
        let all = m.networkCounters(interface: nil)
        print("All interfaces: in \(all.received) B, out \(all.sent) B")
        for name in m.networkInterfaces() {
            let c = m.networkCounters(interface: name)
            print("  \(name): in \(c.received) B, out \(c.sent) B")
        }
        if let disk = m.diskSpace(path: "/") {
            print("Disk /: free \(Int64(disk.free / 1024)) KiB of \(Int64(disk.total / 1024)) KiB")
            let available = SystemMonitor.availableSpace(atPath: "/")
            print("Disk /: available \(Int64(available / 1024)) KiB (as Finder counts it: FreeDiskSpace MacAvailable=1)")
        }
        print(String(format: "Uptime: %.0f s", m.uptime()))
        if let b = m.battery() {
            print(String(format: "Battery: %.0f%% charging=%@ plugged=%@ minutes=%@", b.percent,
                         b.isCharging ? "yes" : "no", b.isPluggedIn ? "yes" : "no",
                         b.minutesRemaining.map { String(Int($0)) } ?? "-"))
        } else {
            print("Battery: none")
        }
        if let power = m.cpuFrequency() { print(String(format: "CPU frequency: %.0f MHz", power / 1_000_000)) }
        if let gpu = m.graphicsAdapterName() { print("Graphics processor: \(gpu)") }
        for (type, text) in sysInfoValues() { print("SysInfo \(type): \(text)") }
        for line in sensorLines(m) { print(line) }
        for line in weatherLines() { print(line) }
        return 0
    }

    /// The hardware sensors skins can read (`Plugin=MacSensors` keys), with labels, readings and sources.
    static func sensorLines(_ m: SystemMonitor) -> [String] {
        let started = ProcessInfo.processInfo.systemUptime
        let list = m.sensors.readAll()
        let seconds = ProcessInfo.processInfo.systemUptime - started
        var lines = [String(format: "Sensors (%@, read in %.0f ms): %d", ChipFamily.current.description, seconds * 1000,
                            list.count)]
        if list.isEmpty { lines.append("  none: this Mac (or virtual machine) reports no hardware sensors") }
        let width = min(list.map(\.key.count).max() ?? 0, 28)
        for info in list {
            let reading = m.sensorValue(info.key).map { SensorKeys.text($0, kind: info.kind) } ?? "no reading"
            var range = ""
            if let lo = info.minimum, let hi = info.maximum {
                range = " [\(SensorKeys.text(lo, kind: info.kind))–\(SensorKeys.text(hi, kind: info.kind))]"
            }
            let key = info.key.padding(toLength: max(width, info.key.count), withPad: " ", startingAt: 0)
            lines.append("  \(key)  \(reading)\(range)  \(info.label) (\(info.source))")
        }
        if let tj = m.cpuTjMax() { lines.append("  CoreTemp TjMax: \(SensorKeys.text(tj, kind: .temperature)) (nominal)") }
        return lines
    }

    /// Every SysInfo type as a skin sees it (the engine answers some types itself, the app the others), with
    /// "(unsupported)" for types neither can answer.
    static func sysInfoValues(data: String = "") -> [(type: String, text: String)] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesksetSysInfo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let config = folder.appendingPathComponent("Report", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var ini = "[Rainmeter]\nUpdate=-1\n"
        for (i, type) in sysInfoTypes.enumerated() {
            ini += "[M\(i)]\nMeasure=SysInfo\nSysInfoType=\(type)\nSysInfoData=\(data)\n"
        }
        let file = config.appendingPathComponent("Report.ini")
        let host = RenderHost()
        let skin = Skin(config: "Report", fileURL: file, skinsDirectory: folder, system: SystemMonitor.shared, host: host)
        do {
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try ini.write(to: file, atomically: true, encoding: .utf8)
            try skin.load()
        } catch {
            return sysInfoTypes.map { ($0, "(error: \(error.localizedDescription))") }
        }
        skin.update()
        return withExtendedLifetime(host) {
            sysInfoTypes.enumerated().map { i, type in
                let unsupported = skin.issues.contains { $0.contains("SysInfoType=\(type) ") }
                guard !unsupported, let measure = skin.measure(named: "M\(i)") else { return (type, "(unsupported)") }
                return (type, measure.stringValue)
            }
        }
    }

    /// Every SysInfoType in the manual.
    static let sysInfoTypes = [
        "COMPUTER_NAME", "USER_NAME", "USER_LOGONTIME", "LAST_SLEEP_TIME", "LAST_WAKE_TIME", "OS_PRODUCT_NAME",
        "OS_VERSION", "OS_BITS", "PAGESIZE", "IDLE_TIME", "HOST_NAME", "DOMAIN_NAME", "DOMAIN_WORKGROUP",
        "DNS_SERVER", "ADAPTER_DESCRIPTION", "ADAPTER_TYPE", "ADAPTER_ALIAS", "ADAPTER_STATE", "ADAPTER_STATUS",
        "ADAPTER_TRANSMIT_SPEED", "ADAPTER_RECEIVE_SPEED", "MAC_ADDRESS", "NET_MASK", "IP_ADDRESS", "GATEWAY_ADDRESS",
        "GATEWAY_ADDRESS_V4", "GATEWAY_ADDRESS_V6", "LAN_CONNECTIVITY", "LAN_CONNECTIVITY_V4", "LAN_CONNECTIVITY_V6",
        "INTERNET_CONNECTIVITY", "INTERNET_CONNECTIVITY_V4", "INTERNET_CONNECTIVITY_V6", "NUM_MONITORS",
        "SCREEN_SIZE", "SCREEN_WIDTH", "SCREEN_HEIGHT", "VIRTUAL_SCREEN_TOP", "VIRTUAL_SCREEN_LEFT",
        "VIRTUAL_SCREEN_WIDTH", "VIRTUAL_SCREEN_HEIGHT", "WORK_AREA", "WORK_AREA_TOP", "WORK_AREA_LEFT",
        "WORK_AREA_WIDTH", "WORK_AREA_HEIGHT", "TIMEZONE_ISDST", "TIMEZONE_BIAS", "TIMEZONE_STANDARD_NAME",
        "TIMEZONE_STANDARD_BIAS", "TIMEZONE_DAYLIGHT_NAME", "TIMEZONE_DAYLIGHT_BIAS",
    ]
}
