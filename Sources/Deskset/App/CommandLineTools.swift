import AppKit
import DesksetCore

/// Command-line modes of the Deskset binary (development and build tools). Each runs and exits.
///
///     Deskset --render Skin.ini --out x.png [...]         headless skin rendering (see RenderCommand)
///     Deskset --self-test [filter]                         app-level checks (window rules, state, UI, install flow)
///     Deskset --make-icon Deskset.iconset                   writes the app icon PNGs (build-app.sh)
///     Deskset --snapshot-ui manage|inspector|settings|install|icon|menubar --out x.png [--dark] [--skins-dir DIR]
///     Deskset --system-report                              prints every system reading
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
                            "--cover-lookup"]
    /// Flags that go with a mode (`--render`'s and `--snapshot-ui`'s options).
    static let optionFlags: Set<String> = ["--out", "--updates", "--interval", "--scale", "--background", "--skins-dir",
                                           "--dark", "--select", "--size", "--zoom",
                                           // The skin editor, library, code editor and Settings snapshots.
                                           "--mode", "--tab", "--code-below", "--inspector-width", "--config",
                                           "--category", "--search", "--pane",
                                           // States of the skin editor (docs/editor-friendly.md §14.0).
                                           "--hover", "--drag", "--expert", "--tip", "--expand", "--edit-text", "--scroll"]

    static let usage = """
        usage: Deskset                   start the menu bar app
               Deskset --render Skin.ini [--out out.png] [--updates N] [--interval ms] [--scale S]
                      [--background R,G,B[,A]] [--skins-dir DIR]
                                        draw a skin without a window into a PNG
               Deskset --self-test [filter]
                                        run the app's self-tests
               Deskset --snapshot-ui manage|inspector|settings|codeeditor|library|install|install-zip|icon|menubar
                      [--out x.png] [--dark] [--select NAME|A,B|none] [--size WxH] [--zoom N] [--skins-dir DIR]
                      [--mode design|split|code] [--tab add|layers|live] [--code-below] [--inspector-width N]
                      [--config NAME] [--category NAME] [--search TEXT] [--pane general|editor]
                      [--hover NAME] [--drag NAME:DX,DY] [--expert] [--tip N] [--expand NAME] [--edit-text NAME]
                      [--scroll "CARD TITLE"]
                                        draw app UI off-screen into a PNG
               Deskset --system-report   print every system reading skins can get
               Deskset --cover-lookup ARTIST TITLE [ALBUM]
                                        look a cover up online as NowPlaying does (sends the names to Apple)
               Deskset --make-icon Output.iconset
                                        write the app icon images
               Deskset --help            print this help
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
        let known = Set(modeFlags).union(optionFlags)
        let unknown = args.filter { $0.hasPrefix("--") && !known.contains($0) }
        if !unknown.isEmpty {
            let shown = unknown.prefix(5).map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 }
            return .invalid("unknown option" + (unknown.count == 1 ? " " : "s ") + shown.joined(separator: ", "))
        }
        if args.contains(where: { modeFlags.contains($0) }) { return .mode }
        if let option = args.first(where: { optionFlags.contains($0) }) {
            return .invalid("\(option) needs one of --render, --snapshot-ui")
        }
        return .app
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
        if arguments.contains("--render") {
            return RenderCommand.run(arguments)
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
        return 0
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
