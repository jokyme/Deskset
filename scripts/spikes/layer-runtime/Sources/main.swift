// H1 spike: showing a skin as many Core Animation layers instead of one bitmap (the first experiment of the
// layer-runtime plan; results and how to run it: results/results.md).
//
// A standalone program: it does not use Deskset's code and is not part of the Swift package. It draws synthetic
// skins (Content.swift) the way Deskset's renderers do, partitions them like the plan (Partition.swift) and shows
// them in the ways listed in Runtime.swift. Each subcommand answers one question and prints JSON:
//
//   env           machine, system, screen and color spaces
//   q1            partitioned layers vs one E layer vs today's view drawing, read back from the screen
//   q4            the draw(in:) context and the backing store per contentsFormat and window color space, and
//                 which combination brings E closest to A
//   cost          memory, CPU and wakeups of one mode in one scenario (q2 / q3; run.sh repeats and interleaves)
//   memtrace      this process's footprint every second while one mode runs a scenario (when memory settles)
//   wsmem         WindowServer's footprint when a fresh process opens several widgets of one scenario and mode
//   q5            gradients cut at box edges (pure CoreGraphics)
//   q6            base tiles sharing one image through contentsRect: memory and read-back
//   q7            ContentHost flipping: resizing, and what AppKit does to contentRoot
//   offmain       many layers committed from a skin thread at 60 Hz: frames on screen, atomicity across layers
//   glass         a glass view following a moving element through main-thread frames (50 ms bound)
//   swap          blank or doubled frames when a refresh swaps windows
//   click         interactive: click-through on transparent pixels (for a person at the Mac)
//   probes        how phys_footprint sees images and what describing a CGContext costs (memory method notes)
//
//   scripts/spikes/layer-runtime/run.sh builds it and runs everything.
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

func flag(_ name: String) -> Bool { arguments.contains(name) }

/// `--scenario` (default ten): ten, design, sixty, or static (memtrace only: 10 System widgets drawn once).
func scenarioOption() -> String {
    let s = option("--scenario") ?? "ten"
    guard ["ten", "design", "sixty", "static"].contains(s) else {
        log("--scenario \(s): expected ten, design, sixty or static")
        exit(2)
    }
    return s
}

/// The value of option `name` as one of an enum's cases (`fallback` when the option is absent); an unknown value
/// ends the program instead of quietly measuring something else.
func choice<T: RawRepresentable & CaseIterable>(_ name: String, _ fallback: T) -> T where T.RawValue == String {
    guard let raw = option(name) else { return fallback }
    guard let value = T(rawValue: raw) else {
        log("\(name) \(raw): expected one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
        exit(2)
    }
    return value
}

/// Where to write the JSON result (default: stdout).
let outPath = option("--out")
let cropDir = option("--crops")

func emit(_ result: JSON) {
    var j = result
    j["command"] = command
    j["arguments"] = Array(arguments.dropFirst())
    j["loadAverageAtEnd"] = loadAverage()
    let data = jsonData(j)
    if let outPath {
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outPath).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outPath, contents: data)
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}

/// Runs `experiment` on the main thread inside a running app (not inside a dispatch block, so nested run loops
/// keep draining the main queue), writes its result and exits.
func runApp(_ experiment: @escaping () -> JSON) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        let result = experiment()
        emit(result)
        exit(0)
    }
    app.run()
    exit(0)
}

func environment() -> JSON {
    var j: JSON = [
        "model": run("/usr/sbin/sysctl", ["-n", "hw.model"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?",
        "cpu": run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?",
        "cores": ProcessInfo.processInfo.processorCount,
        "memoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "loadAverage": loadAverage(),
        "screenCaptureAllowed": canCapture,
    ]
    var screens: [JSON] = []
    for s in NSScreen.screens {
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let cg = CGDisplayCopyColorSpace(id)
        screens.append([
            "name": s.localizedName, "main": s == NSScreen.main, "backingScale": s.backingScaleFactor,
            "points": "\(Int(s.frame.width))x\(Int(s.frame.height))",
            "colorSpace": s.colorSpace?.localizedName ?? "none",
            "colorSpaceModel": cg.model.rawValue, "iccBytes": cg.copyICCData().map { CFDataGetLength($0) } ?? 0,
            "canRepresentP3": s.canRepresent(.p3), "depthBitsPerSample": s.depth.bitsPerSample,
            "edrPotential": s.maximumPotentialExtendedDynamicRangeColorComponentValue,
            "edrNow": s.maximumExtendedDynamicRangeColorComponentValue,
            "builtIn": CGDisplayIsBuiltin(id) != 0,
            "srgbRedInDisplaySpace": primaryInDisplaySpace(cg),
        ])
    }
    j["screens"] = screens
    return j
}

/// sRGB's pure red converted to the display's color space: (1, 0, 0) means the display space is sRGB-like; a
/// wide-gamut display space gives smaller red and non-zero green and blue.
func primaryInDisplaySpace(_ space: CGColorSpace) -> [Double] {
    guard let c = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        .converted(to: space, intent: .defaultIntent, options: nil), let comps = c.components else { return [] }
    return comps.prefix(3).map { r(Double($0), 4) }
}

switch command {
case "env":
    runApp { environment() }
case "q5":
    emit(q5Gradient())
case "q1":
    runApp { q1Screen() }
case "q4":
    runApp { q4Color() }
case "cost":
    runApp { costRun() }
case "memtrace":
    runApp { memTrace() }
case "wsmem":
    runApp { windowServerMemoryRun() }
case "q6":
    runApp { q6SharedBase() }
case "q7":
    runApp { q7Flip() }
case "offmain":
    runApp { offMainCommits() }
case "glass":
    runApp { glassFollow() }
case "swap":
    runApp { refreshSwap() }
case "click":
    runApp { clickThrough() }
case "probes":
    emit(probes())
default:
    print("""
        usage: spike env | q1 | q4 | q5 | q6 | q7 | offmain | glass | swap | click | probes | cost --mode A|E1|EP|D1|DP \
        --scenario idle|ten|design|sixty [--seconds N] [--out file.json] [--crops dir]
        """)
    exit(2)
}
