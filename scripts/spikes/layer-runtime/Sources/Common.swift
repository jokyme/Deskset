// Shared helpers: clock, JSON output, process and WindowServer metrics, a run-loop thread for skins.
import AppKit
import Darwin
import IOSurface
import QuartzCore

// MARK: Clock

let startTime = CACurrentMediaTime()

/// Seconds since the start (monotonic, callable from any thread).
func now() -> Double { CACurrentMediaTime() - startTime }

/// Runs the main run loop for `seconds` (the main thread keeps serving AppKit and Core Animation meanwhile). It
/// sleeps until something arrives, so it adds no wakeups of its own.
func pump(_ seconds: Double) {
    let end = Date(timeIntervalSinceNow: seconds)
    while Date() < end {
        RunLoop.main.run(mode: .default, before: end)
    }
}

/// Busy work on the calling thread until `seconds` passed (a stalled main thread).
func spin(_ seconds: Double) {
    let end = now() + seconds
    while now() < end {}
}

// MARK: JSON

typealias JSON = [String: Any]

func jsonData(_ value: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
}

/// Rounds to `digits` decimals so the JSON stays readable.
func r(_ v: Double, _ digits: Int = 3) -> Double {
    guard v.isFinite else { return 0 }
    let p = pow(10, Double(digits))
    return (v * p).rounded() / p
}

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// MARK: Statistics

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(Int((Double(sorted.count - 1) * p).rounded()), sorted.count - 1)]
}

func median(_ values: [Double]) -> Double { percentile(values, 0.5) }

// MARK: Load

/// 1, 5 and 15 minute load averages.
func loadAverage() -> [Double] {
    var l = [Double](repeating: 0, count: 3)
    getloadavg(&l, 3)
    return l.map { r($0, 2) }
}

// MARK: This process

/// `phys_footprint` of this process in bytes (what Activity Monitor calls Memory).
func physFootprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) : .nan
}

/// User + system CPU seconds of this process.
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(usage.ru_utime) + s(usage.ru_stime)
}

/// Interrupt wakeups and package idle wakeups of this process so far (the counters Activity Monitor's
/// "Idle Wake Ups" and `top`'s IDLEW are based on).
func wakeups() -> (interrupt: Double, idle: Double) {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    guard rc == 0 else { return (.nan, .nan) }
    return (Double(info.ri_interrupt_wkups), Double(info.ri_pkg_idle_wkups))
}

/// This process's footprint by category, from `footprint` (works on our own process without root): the graphics
/// memory CA and the window server charge to us (IOSurface, "owned … (graphics)", IOAccelerator) and malloc.
func footprintCategories() -> JSON {
    guard let out = run("/usr/bin/footprint", [String(getpid())]) else { return [:] }
    var j: JSON = [:]
    for line in out.split(separator: "\n") {
        // "  113 MB        0 B          0 B         50    Owned physical footprint (unmapped) (graphics)"
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 8, let dirty = Double(parts[0]) else { continue }
        let unit = String(parts[1])
        let factor: Double = unit == "GB" ? 1024 : unit == "MB" ? 1 : unit == "KB" ? 1.0 / 1024 : 1.0 / 1_048_576
        let name = parts[7...].joined(separator: " ")
        let mb = dirty * factor
        if mb >= 0.25 { j[name] = r(mb, 2) }
        if name.hasPrefix("Footprint") { break }
    }
    if let total = out.split(separator: "\n").first(where: { $0.contains("Footprint:") }) {
        j["total"] = String(total.split(separator: "Footprint:").last ?? "").trimmingCharacters(in: .whitespaces)
    }
    return j
}

// MARK: WindowServer

/// Output of a command (stdout), or nil.
func run(_ path: String, _ arguments: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

let windowServerPID: pid_t? = run("/usr/bin/pgrep", ["-x", "WindowServer"])?
    .split(separator: "\n").first.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }

/// CPU seconds WindowServer has used so far (`ps`, 10 ms resolution). It counts everything on the screen.
func windowServerCPUSeconds() -> Double? {
    guard let pid = windowServerPID,
          let time = run("/bin/ps", ["-o", "time=", "-p", String(pid)])?.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    let parts = time.split(separator: ":").compactMap { Double($0) }
    guard !parts.isEmpty else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
}

/// WindowServer's memory and idle wakeups from `top` (which reads them through the system's monitoring service, so
/// it needs no root; `footprint` and `vmmap` do). MEM is the physical footprint, printed with 1 MB resolution at
/// WindowServer's size. Also the resident size from `ps` (KB resolution, but without IOSurface and GPU memory).
func windowServerMemory() -> (mem: Double?, idleWakeups: Double?, rss: Double?) {
    guard let pid = windowServerPID else { return (nil, nil, nil) }
    var mem: Double?, idle: Double?
    if let out = run("/usr/bin/top", ["-l", "1", "-pid", String(pid), "-stats", "pid,mem,idlew"]) {
        for line in out.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, fields[0] == Substring(String(pid)) else { continue }
            mem = parseSize(String(fields[1]))
            idle = Double(fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "+-")))
        }
    }
    let rss = run("/bin/ps", ["-o", "rss=", "-p", String(pid)])
        .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.map { $0 * 1024 }
    return (mem, idle, rss)
}

/// The GPU's "In use system memory" (bytes, the whole system: every process's IOSurfaces, textures and buffers, the
/// window server's included) from the accelerator's PerformanceStatistics in the I/O Registry. No root needed, byte
/// resolution, but everything else on the screen moves it too.
func gpuInUseMemory() -> Double? {
    guard let out = run("/usr/sbin/ioreg", ["-r", "-c", "IOAccelerator", "-d", "1", "-w0"]),
          let r = out.range(of: "\"In use system memory\"=") else { return nil }
    let digits = out[r.upperBound...].prefix { $0.isNumber }
    return Double(digits)
}

/// "1006M", "12K", "3.2G", "512B" (with an optional trailing + or -) in bytes.
func parseSize(_ s: String) -> Double? {
    var t = s.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
    guard let unit = t.last else { return nil }
    let factor: Double
    switch unit {
    case "B": factor = 1
    case "K": factor = 1024
    case "M": factor = 1024 * 1024
    case "G": factor = 1024 * 1024 * 1024
    default: return Double(t)
    }
    t.removeLast()
    return Double(t).map { $0 * factor }
}

// MARK: Threads

/// A dedicated thread with its own run loop and an 8 MB stack: a skin's executor (docs: one thread per skin).
final class RunLoopThread: Thread {
    private let ready = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop?

    override func main() {
        loop = CFRunLoopGetCurrent()
        // A source keeps the run loop running while nothing else is scheduled.
        var context = CFRunLoopSourceContext()
        CFRunLoopAddSource(loop, CFRunLoopSourceCreate(nil, 0, &context), .defaultMode)
        ready.signal()
        CFRunLoopRun()
    }

    static func make(_ name: String) -> RunLoopThread {
        let t = RunLoopThread()
        t.name = name
        t.stackSize = 8 << 20
        t.qualityOfService = .userInteractive
        t.start()
        t.ready.wait()
        return t
    }

    /// Runs `block` on this thread, after the blocks already posted, in its own autorelease pool (a secondary
    /// thread's run loop never drains one: without it, what CA autoreleases every frame piles up).
    func perform(_ block: @escaping () -> Void) {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { autoreleasepool { block() } }
        CFRunLoopWakeUp(loop)
    }

    /// Runs `block` on this thread and waits for it.
    func sync<T>(_ block: @escaping () -> T) -> T {
        if Thread.current === self { return block() }
        var result: T?
        let done = DispatchSemaphore(value: 0)
        perform {
            result = block()
            done.signal()
        }
        done.wait()
        return result!
    }

    func stop() {
        sync { CFRunLoopStop(CFRunLoopGetCurrent()) }
    }
}

// MARK: Windows

/// A borderless, transparent, shadowless panel like Deskset's skin windows, floating above normal windows so it is
/// on screen while measured. Clicks pass through unless `clickable`.
func makePanel(_ frame: NSRect, clickable: Bool = false) -> NSPanel {
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                        defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.ignoresMouseEvents = !clickable
    return panel
}

/// Top-left placement on the main screen's visible frame, in a grid of `columns`.
func gridOrigin(_ index: Int, size: CGSize, columns: Int, gap: CGFloat = 12, top: CGFloat = 40) -> NSPoint {
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let col = index % columns, row = index / columns
    let x = visible.minX + 20 + CGFloat(col) * (size.width + gap)
    let y = visible.maxY - top - CGFloat(row + 1) * size.height - CGFloat(row) * gap
    return NSPoint(x: x, y: y)
}

// MARK: Memory pressure

/// The system's memory state: under pressure the compressor keeps idle pages compressed, and phys_footprint counts
/// them at their compressed size (a freshly drawn, uniform 10 MB bitmap then adds well under 1 MB), so memory
/// numbers are recorded with this.
func memoryPressure() -> JSON {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    let page = Double(vm_kernel_page_size)
    let gb = 1024.0 * 1024.0 * 1024.0
    return ["pressureLevel": Int(level), "pressureLevelMeaning": "1 normal, 2 warning, 4 critical",
            "freeGB": r(Double(stats.free_count) * page / gb, 2),
            "compressorOccupiesGB": r(Double(stats.compressor_page_count) * page / gb, 2)]
}

// MARK: Nominal bitmap bytes

/// Bytes per pixel of a CA backing store format as CA names it.
private func bytesPerPixel(_ format: String) -> Int {
    switch format {
    case "RGBAh", "RGBA16", "RGBAf16", "RGhA": return 8
    case "RGBAf": return 16
    case "A8", "L8", "R8": return 1
    default: return 4
    }
}

/// The bitmap memory the layers under `root` hold, counted from their contents (uncompressed, each image or
/// surface once however many layers show it): CA backing stores (every buffer), IOSurfaces, CGImages.
func nominalBitmapBytes(_ root: CALayer) -> Int {
    var seen = Set<ObjectIdentifier>()
    var total = 0
    func visit(_ l: CALayer) {
        if var c = l.contents {
            if let t = c as? NSObject, NSStringFromClass(type(of: t)) == "CATintedImage",
               let inner = t.perform(NSSelectorFromString("image"))?.takeUnretainedValue() {
                c = inner
            }
            let o = c as AnyObject
            if seen.insert(ObjectIdentifier(o)).inserted {
                let d = CFCopyDescription(o as CFTypeRef) as String
                if d.hasPrefix("<CABackingStore") {
                    // "(buffer [w h] FORMAT)" per buffer
                    for part in d.components(separatedBy: "(buffer [").dropFirst() {
                        let fields = part.split(whereSeparator: { $0 == " " || $0 == "]" || $0 == ")" })
                        if fields.count >= 3, let w = Int(fields[0]), let h = Int(fields[1]) {
                            total += w * h * bytesPerPixel(String(fields[2]))
                        }
                    }
                } else if CFGetTypeID(o as CFTypeRef) == CGImage.typeID {
                    let img = unsafeBitCast(o, to: CGImage.self)
                    total += img.bytesPerRow * img.height
                } else if CFGetTypeID(o as CFTypeRef) == IOSurfaceGetTypeID() {
                    total += IOSurfaceGetAllocSize(unsafeBitCast(o, to: IOSurfaceRef.self))
                }
            }
        }
        for s in l.sublayers ?? [] { visit(s) }
    }
    visit(root)
    return total
}
