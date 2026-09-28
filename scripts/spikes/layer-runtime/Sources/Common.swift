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

/// Placement on the main screen's visible frame in a grid of at most `columns` (fewer when they would not fit),
/// anchored at the bottom right and growing left and up: the top left of the screen is where the Mac's owner keeps
/// their own widgets, so the spike's windows stay away from it.
func gridOrigin(_ index: Int, size: CGSize, columns: Int, gap: CGFloat = 12, top: CGFloat = 40) -> NSPoint {
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let fit = max(1, Int((visible.width - 40 + gap) / (size.width + gap)))
    let cols = max(1, min(columns, fit))
    let col = index % cols, row = index / cols
    let x = visible.maxX - 20 - CGFloat(col + 1) * size.width - CGFloat(col) * gap
    let y = visible.minY + 20 + CGFloat(row) * (size.height + gap)
    return NSPoint(x: x, y: y)
}

/// The rectangle covering the first `count` grid cells of `gridOrigin`, grown by `margin`.
func gridFrame(count: Int, size: CGSize, columns: Int, margin: CGFloat = 6) -> NSRect {
    var frame = NSRect.null
    for i in 0..<max(count, 1) {
        frame = frame.union(NSRect(origin: gridOrigin(i, size: size, columns: columns), size: size))
    }
    return frame.insetBy(dx: -margin, dy: -margin)
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

// MARK: Counters that separate work from placement (proc_pid_rusage v6)

/// CPU time says how long this process ran, not how much it did: the same work takes longer on an efficiency core
/// or on a core that has not ramped up. These counters (all threads of this process, since it started) tell them
/// apart: instructions retired (the work), cycles (instructions / cycles = how fast), the share of both on
/// performance cores, energy, and time spent runnable but waiting for a core.
struct ProcCounters {
    var cpu = 0.0, pCoreCPU = 0.0, runnable = 0.0          // seconds
    /// System time other processes (the window server) spent on this process's behalf and billed to it, and time
    /// this process spent serving others (seconds).
    var billedSystem = 0.0, servicedSystem = 0.0
    var instructions = 0.0, pInstructions = 0.0, cycles = 0.0, pCycles = 0.0
    var energyJ = 0.0, pEnergyJ = 0.0
    var interruptWakeups = 0.0, idleWakeups = 0.0

    /// The rates between `self` (earlier) and `later`, over `seconds` of wall time.
    func rates(to later: ProcCounters, seconds: Double) -> JSON {
        let d = { (k: KeyPath<ProcCounters, Double>) in later[keyPath: k] - self[keyPath: k] }
        let cpu = d(\.cpu), instructions = d(\.instructions), cycles = d(\.cycles)
        var j: JSON = ["cpuPercentOfOneCore": r(cpu / seconds * 100, 3),
                       "pCoreShareOfCPU": cpu > 0 ? r(d(\.pCoreCPU) / cpu, 3) : 0,
                       "instructionsMillionsPerSecond": r(instructions / seconds / 1e6, 2),
                       "cyclesMillionsPerSecond": r(cycles / seconds / 1e6, 2),
                       "pCoreShareOfInstructions": instructions > 0 ? r(d(\.pInstructions) / instructions, 3) : 0,
                       "pCoreShareOfCycles": cycles > 0 ? r(d(\.pCycles) / cycles, 3) : 0,
                       "energyMilliwatts": r(d(\.energyJ) / seconds * 1000, 2),
                       "runnableMsPerSecond": r(d(\.runnable) / seconds * 1000, 2),
                       "billedSystemMsPerSecond": r(d(\.billedSystem) / seconds * 1000, 3),
                       "servicedSystemMsPerSecond": r(d(\.servicedSystem) / seconds * 1000, 3)]
        if instructions > 0 { j["cyclesPerInstruction"] = r(cycles / instructions, 3) }
        if cpu > 0 { j["averageGHz"] = r(cycles / cpu / 1e9, 3) }
        return j
    }
}

private let machTicksToSeconds: Double = {
    var tb = mach_timebase_info()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom) / 1e9
}()

func procCounters() -> ProcCounters {
    var info = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
    }
    guard rc == 0 else { return ProcCounters() }
    let t = machTicksToSeconds
    return ProcCounters(
        cpu: Double(info.ri_user_time + info.ri_system_time) * t,
        pCoreCPU: Double(info.ri_user_ptime + info.ri_system_ptime) * t,
        runnable: Double(info.ri_runnable_time) * t,
        billedSystem: Double(info.ri_billed_system_time) * t, servicedSystem: Double(info.ri_serviced_system_time) * t,
        instructions: Double(info.ri_instructions), pInstructions: Double(info.ri_pinstructions),
        cycles: Double(info.ri_cycles), pCycles: Double(info.ri_pcycles),
        energyJ: Double(info.ri_energy_nj) / 1e9, pEnergyJ: Double(info.ri_penergy_nj) / 1e9,
        interruptWakeups: Double(info.ri_interrupt_wkups), idleWakeups: Double(info.ri_pkg_idle_wkups))
}

/// CPU seconds of the calling thread (for the cost of one update without the time it was preempted).
func threadCPUSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

// MARK: GPU and system memory

/// The GPU's performance statistics from the I/O Registry (whole system): memory in use and the utilization CA and
/// the window server's compositing add to.
func gpuStatistics() -> (inUseMB: Double?, device: Double?, renderer: Double?, tiler: Double?) {
    guard let out = run("/usr/sbin/ioreg", ["-r", "-c", "IOAccelerator", "-d", "1", "-w0"]) else {
        return (nil, nil, nil, nil)
    }
    func value(_ key: String) -> Double? {
        guard let r = out.range(of: "\"\(key)\"=") else { return nil }
        return Double(out[r.upperBound...].prefix { $0.isNumber })
    }
    return (value("In use system memory").map { $0 / 1_048_576 }, value("Device Utilization %"),
            value("Renderer Utilization %"), value("Tiler Utilization %"))
}

/// System-wide pages (MB): what every process and the kernel hold. Anonymous memory (internal), wired memory (which
/// includes memory the GPU has pinned), and the compressor (both what it occupies and what it holds uncompressed).
func systemMemoryMB() -> JSON {
    var s = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    let page = Double(vm_kernel_page_size) / 1_048_576
    let internalMB = Double(s.internal_page_count) * page, wired = Double(s.wire_count) * page
    let occupied = Double(s.compressor_page_count) * page
    let held = Double(s.total_uncompressed_pages_in_compressor) * page
    return ["internal": r(internalMB, 1), "wired": r(wired, 1), "compressorOccupies": r(occupied, 1),
            "compressorHolds": r(held, 1), "free": r(Double(s.free_count) * page, 1),
            "fileBacked": r(Double(s.external_page_count) * page, 1),
            "anonymousWiredCompressed": r(internalMB + wired + occupied, 1)]
}

/// This process's memory as `footprint --vmObjectDirty` sees it: dirty (and compressed) pages of every VM object
/// mapped into the process, counted in full even when another process (the window server) maps the same object.
/// phys_footprint leaves out the pages of CGImages that Core Animation handed to the window server while the window
/// is on screen; this view does not. No root needed for our own process. Total and a few categories, in MB.
func vmObjectDirtyFootprint() -> JSON {
    guard let out = run("/usr/bin/footprint", ["--vmObjectDirty", "-w", "-f", "bytes", "-p", String(getpid())])
    else { return [:] }
    var j: JSON = [:]
    for line in out.split(separator: "\n") {
        if let r = line.range(of: "Footprint: ") {
            let digits = line[r.upperBound...].prefix { $0.isNumber }
            if let v = Double(digits) { j["totalMB"] = (v / 1_048_576 * 100).rounded() / 100 }
            continue
        }
        // "   8192000 B      0 B      0 B      0 B      0 B     30    CG raster data" (dirty, swapped, clean, …)
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 12, parts[1] == "B", let dirty = Double(parts[0]), let swapped = Double(parts[2]) else {
            continue
        }
        let name = parts[11...].joined(separator: " ")
        guard ["CG image", "CG raster data", "CoreAnimation", "IOSurface", "IOAccelerator", "IOAccelerator (graphics)",
               "MALLOC_SMALL", "MALLOC_LARGE", "untagged (VM_ALLOCATE)"].contains(name) else { continue }
        j[name] = ((dirty + swapped) / 1_048_576 * 100).rounded() / 100
    }
    return j
}
