// Behaviour checks for the example skins that ship with the app (DefaultSkins/Deskset). Run from the repository root:
//
//     swift run --package-path TestSkins/Examples/Checks CheckExamples [path/to/DefaultSkins]
//
// Each skin is loaded by the engine over a temporary copy of the skins with fake system readings, then checked:
// no compatibility issues or warnings (also with the light theme, 12 hours, Monday and the system language),
// resolved context menus, the hover effect, clickable titles, and the behaviour of each skin (swap maths, battery
// states, missing disks, the analog hands against the clock, calendar paging compared with Foundation over 100
// years for both week starts, the today mark, the 12/24-hour and theme switches that rewrite
// @Resources/Variables.inc, variant switching). Exits with 1 when a check fails.
import Foundation
import DesksetCore

// MARK: Fakes

final class Host: SkinHost {
    var handled: [Bang] = []
    var logs: [String] = []
    func skinNeedsDisplay(_ skin: Skin) {}
    func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        handled.append(bang)
        return true
    }
    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {}
    func skin(_ skin: Skin, execute target: String, arguments: [String]) {}
    func skin(_ skin: Skin, log message: String, level: SkinLogLevel) { logs.append("\(level.rawValue): \(message)") }
    /// 7 points per character, 14 per line.
    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?) -> (width: Double, height: Double) {
        text.isEmpty ? (0, 0) : (Double(text.count) * 7, 14)
    }
    func imageSize(atPath path: String) -> (width: Double, height: Double)? { nil }
    func environment(for skin: Skin) -> SkinEnvironment { SkinEnvironment() }
}

let gigabyte = 1_073_741_824.0

final class System: SystemDataSource {
    var memory = MemoryStatus(physicalTotal: 16 * gigabyte, physicalUsed: 8 * gigabyte,
                              swapTotal: 2 * gigabyte, swapUsed: gigabyte)
    var batteryStatus: BatteryStatus? = BatteryStatus(percent: 80, isCharging: false, isPluggedIn: false,
                                                      minutesRemaining: 95)
    /// Startup disk (total, free); other paths exist only when they exist on this Mac.
    var startupDisk: (Double, Double)? = (1000, 250)
    var processorCount: Int { 8 }
    func cpuUsage(processor: Int) -> Double { 37 }
    func memoryStatus() -> MemoryStatus { memory }
    func networkInterfaces() -> [String] { ["en0"] }
    func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters(received: 5_000_000, sent: 1_000_000) }
    func diskSpace(path: String) -> (total: Double, free: Double)? {
        path == "/" ? startupDisk : (FileManager.default.fileExists(atPath: path) ? (2000, 1500) : nil)
    }
    func uptime() -> TimeInterval { 90061 }
    func battery() -> BatteryStatus? { batteryStatus }
    func isProcessRunning(_ name: String) -> Bool { false }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
    func volumeInfo(path: String) -> VolumeInfo? {
        if path == "/" { return VolumeInfo(label: "Macintosh HD", kind: .fixed) }
        return FileManager.default.fileExists(atPath: path) ? VolumeInfo(label: "External", kind: .removable) : nil
    }
}

// MARK: Helpers

var failures = 0
var checks = 0
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL: \(message())")
    }
}

let arguments = CommandLine.arguments.dropFirst()
let source = URL(fileURLWithPath: arguments.first ?? "DefaultSkins").standardizedFileURL
guard FileManager.default.fileExists(atPath: source.appendingPathComponent("Deskset").path) else {
    print("No Deskset folder in \(source.path); run from the repository root or pass the DefaultSkins folder.")
    exit(2)
}
let work = FileManager.default.temporaryDirectory.appendingPathComponent("deskset-check-examples-\(getpid())")
let skins = work.appendingPathComponent("Skins")
let variablesFile = skins.appendingPathComponent("Deskset/@Resources/Variables.inc")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)
try FileManager.default.copyItem(at: source.appendingPathComponent("Deskset"), to: skins.appendingPathComponent("Deskset"))

/// Skin.host is weak: keep the hosts alive.
var hosts: [Host] = []

func load(_ config: String, _ file: String, system: System = System(), updates: Int = 3) throws -> (Skin, Host) {
    let host = Host()
    hosts.append(host)
    let skin = Skin(config: "Deskset\\\(config)", fileURL: skins.appendingPathComponent("Deskset/\(config)/\(file)"),
                    skinsDirectory: skins, system: system, host: host)
    try skin.load()
    for _ in 0..<updates { skin.update() }
    return (skin, host)
}

func text(_ skin: Skin, _ meter: String) -> String {
    (skin.meter(named: meter) as? StringMeter)?.text ?? "<no meter \(meter)>"
}

func hidden(_ skin: Skin, _ meter: String) -> Bool { skin.meter(named: meter)?.hidden ?? true }

func stroke(_ skin: Skin, _ meter: String) -> ShapePaint? {
    (skin.meter(named: meter) as? ShapeMeter)?.shapes.first?.stroke
}

func run(_ skin: Skin, _ meter: String) {
    guard let m = skin.meter(named: meter), let action = m.effectiveMouseAction(.leftUp) else {
        check(false, "\(meter) has a LeftMouseUpAction")
        return
    }
    skin.execute(action, from: m)
}

// MARK: Every skin

let all = [("Clock", "Clock.ini"), ("Clock", "Dial.ini"), ("System", "System.ini"), ("Network", "Network.ini"),
           ("Disk", "Disk.ini"), ("Disk", "Volumes.ini"), ("Battery", "Battery.ini"), ("Calendar", "Calendar.ini")]
for (config, file) in all {
    let name = "\(config)/\(file)"
    let (skin, host) = try load(config, file)
    check(skin.issues.isEmpty, "\(name): compatibility issues \(skin.issues)")
    let logs = host.logs.filter { !$0.hasPrefix("debug") && !$0.hasPrefix("notice") }
    check(logs.isEmpty, "\(name): log \(logs)")
    let menu = skin.contextMenuItems()
    // At most 3 entries, so the app shows them without a submenu.
    check((2...3).contains(menu.count), "\(name): \(menu.count) context menu entries")
    check(menu.last?.title == "Use Light Theme", "\(name): theme entry last, got \(menu.map(\.title))")
    for item in menu {
        check(!item.title.contains("#") && !item.title.contains("["), "\(name): unresolved menu title \(item.title)")
    }
    check(skin.settings.groups.contains("Deskset"), "\(name): in group Deskset (for !RefreshGroup)")

    guard let background = skin.meter(named: "MeterBackground") as? ShapeMeter else {
        check(false, "\(name): MeterBackground is a Shape meter")
        continue
    }
    check(background.frame.width == skin.width && background.frame.height == skin.height,
          "\(name): the panel is the whole skin (\(background.frame) in \(skin.width)x\(skin.height))")
    // The panel border brightens under the pointer and comes back when it leaves.
    let normal = stroke(skin, "MeterBackground")
    skin.mouseMoved(x: 20, y: 20)
    let hover = stroke(skin, "MeterBackground")
    skin.mouseExited()
    check(normal != hover, "\(name): hover changes the border")
    check(normal == stroke(skin, "MeterBackground"), "\(name): the border comes back")
}

// Clickable text lights up under the pointer and gets its own color back.
for (config, file, meter) in [("System", "System.ini", "MeterTitle"), ("Network", "Network.ini", "MeterTitle"),
                              ("Disk", "Disk.ini", "MeterTitle"), ("Disk", "Volumes.ini", "MeterName2"),
                              ("Battery", "Battery.ini", "MeterTitle"), ("Calendar", "Calendar.ini", "MeterTitle")] {
    let (skin, _) = try load(config, file)
    guard let m = skin.meter(named: meter) as? StringMeter else {
        check(false, "\(config)/\(file): \(meter)")
        continue
    }
    let normal = m.style.color
    skin.mouseMoved(x: m.frame.x + 2, y: m.frame.y + 2)
    let hover = (skin.meter(named: meter) as? StringMeter)?.style.color
    skin.mouseMoved(x: 1, y: skin.height - 2)
    let back = (skin.meter(named: meter) as? StringMeter)?.style.color
    check(hover != normal && back == normal, "\(config)/\(file) \(meter): link hover \(normal) → \(String(describing: hover))")
    check(m.effectiveMouseAction(.leftUp) != nil, "\(config)/\(file) \(meter): clickable")
}

// MARK: System — swap is SwapMemory − PhysicalMemory

do {
    let (skin, _) = try load("System", "System.ini")
    check(text(skin, "MeterRAMValue") == "8.0 GB / 16.0 GB", "RAM text \(text(skin, "MeterRAMValue"))")
    check(text(skin, "MeterSwapValue") == "1.0 GB / 2.0 GB", "swap text \(text(skin, "MeterSwapValue"))")
    if let swap = skin.measure(named: "MeasureSwap") {
        check(abs(swap.value - gigabyte) < 1 && abs(swap.maxValue - 2 * gigabyte) < 1,
              "swap \(swap.value) of \(swap.maxValue)")
    }
    check(text(skin, "MeterUptime") == "Up 1d 1h 1m", "uptime \(text(skin, "MeterUptime"))")

    let system = System()
    system.memory.swapTotal = 0
    system.memory.swapUsed = 0
    let (noSwap, _) = try load("System", "System.ini", system: system)
    check(text(noSwap, "MeterSwapValue") == "Not in use", "no swap: \(text(noSwap, "MeterSwapValue"))")
    // macOS adds swap files as needed: the range follows.
    system.memory.swapTotal = 4 * gigabyte
    system.memory.swapUsed = 3 * gigabyte
    noSwap.update()
    check(text(noSwap, "MeterSwapValue") == "3.0 GB / 4.0 GB", "swap grows: \(text(noSwap, "MeterSwapValue"))")
    check(abs((noSwap.measure(named: "MeasureSwap")?.maxValue ?? 0) - 4 * gigabyte) < 1, "swap range follows")
}

// MARK: Battery states

func battery(_ status: BatteryStatus?) throws -> Skin {
    let system = System()
    system.batteryStatus = status
    return try load("Battery", "Battery.ini", system: system).0
}

do {
    let none = try battery(nil)
    check(!hidden(none, "MeterNoBattery") && hidden(none, "MeterGauge") && hidden(none, "MeterPercent")
          && hidden(none, "MeterBolt"), "no battery: note instead of the gauge")
    check(text(none, "MeterStatus") == "Power adapter", "no battery: \(text(none, "MeterStatus"))")

    let charging = try battery(BatteryStatus(percent: 50, isCharging: true, isPluggedIn: true))
    check(!hidden(charging, "MeterBolt") && !hidden(charging, "MeterGauge") && hidden(charging, "MeterNoBattery"),
          "charging: gauge with bolt")
    check(text(charging, "MeterStatus") == "Charging" && text(charging, "MeterPercent") == "50%",
          "charging: \(text(charging, "MeterStatus")) \(text(charging, "MeterPercent"))")

    let low = try battery(BatteryStatus(percent: 15, isCharging: false, isPluggedIn: false, minutesRemaining: 95))
    check(text(low, "MeterStatus") == "1:35 left", "on battery: \(text(low, "MeterStatus"))")
    check(low.variable("GaugeColor") == low.variable("LowColor") && hidden(low, "MeterBolt"), "low: amber, no bolt")

    let critical = try battery(BatteryStatus(percent: 4, isCharging: false, isPluggedIn: false))
    check(text(critical, "MeterStatus") == "On battery", "unknown time: \(text(critical, "MeterStatus"))")
    check(critical.variable("GaugeColor") == critical.variable("CriticalColor"), "critical: red")

    let full = try battery(BatteryStatus(percent: 100, isCharging: false, isPluggedIn: true))
    check(text(full, "MeterStatus") == "Fully charged", "full: \(text(full, "MeterStatus"))")
    check(full.variable("GaugeColor") == full.variable("BatteryColor"), "full: green")

    let held = try battery(BatteryStatus(percent: 80, isCharging: false, isPluggedIn: true))
    check(text(held, "MeterStatus") == "Not charging", "held: \(text(held, "MeterStatus"))")

    // Unplugging switches the state on the next update.
    let system = System()
    system.batteryStatus = BatteryStatus(percent: 60, isCharging: true, isPluggedIn: true)
    let (live, _) = try load("Battery", "Battery.ini", system: system)
    system.batteryStatus = BatteryStatus(percent: 60, isCharging: false, isPluggedIn: false, minutesRemaining: 250)
    live.update()
    check(text(live, "MeterStatus") == "4:10 left" && hidden(live, "MeterBolt"), "unplugged: \(text(live, "MeterStatus"))")
}

// MARK: Disks

do {
    let (disk, _) = try load("Disk", "Disk.ini")
    check(text(disk, "MeterTitle") == "Macintosh HD", "disk title \(text(disk, "MeterTitle"))")
    check(text(disk, "MeterPercent") == "75%", "disk percent \(text(disk, "MeterPercent"))")
    check(disk.variable("BarColor") == disk.variable("DiskColor"), "disk color")

    let system = System()
    system.startupDisk = (1000, 50)
    let (full, _) = try load("Disk", "Disk.ini", system: system)
    check(text(full, "MeterPercent") == "95%" && full.variable("BarColor") == full.variable("LowColor"),
          "nearly full disk turns amber")

    // The second volume (/Volumes/Backup) is not connected here.
    let (volumes, _) = try load("Disk", "Volumes.ini")
    check(!hidden(volumes, "MeterMissing2") && hidden(volumes, "MeterFree2") && hidden(volumes, "MeterPercent2"),
          "missing volume: 'Not connected'")
    check(text(volumes, "MeterName2") == "Backup", "missing volume name \(text(volumes, "MeterName2"))")
    check(text(volumes, "MeterPercent1") == "75%", "first volume \(text(volumes, "MeterPercent1"))")

    // Disk.ini set to a disk that is not connected says so instead of "0% … 0.0 B free".
    let diskFile = skins.appendingPathComponent("Deskset/Disk/Disk.ini")
    let missingFile = skins.appendingPathComponent("Deskset/Disk/Missing.ini")
    try String(contentsOf: diskFile, encoding: .utf8)
        .replacingOccurrences(of: "\nVolume=/\n", with: "\nVolume=/Volumes/Deskset Check No Such Disk\n")
        .write(to: missingFile, atomically: true, encoding: .utf8)
    let (missing, missingHost) = try load("Disk", "Missing.ini")
    try? FileManager.default.removeItem(at: missingFile)
    check(!hidden(missing, "MeterMissing") && hidden(missing, "MeterPercent") && hidden(missing, "MeterFree")
          && hidden(missing, "MeterTotal"), "Disk.ini, missing disk: 'Not connected'")
    check(text(missing, "MeterTitle") == "/Volumes/Deskset Check No Such Disk", "missing disk title \(text(missing, "MeterTitle"))")
    check(missing.issues.isEmpty && missingHost.logs.filter { !$0.hasPrefix("debug") }.isEmpty,
          "missing disk: \(missing.issues) \(missingHost.logs)")
    check(hidden(disk, "MeterMissing") && !hidden(disk, "MeterFree"), "Disk.ini, startup disk: details shown")
}

// MARK: Calendar

do {
    let (skin, _) = try load("Calendar", "Calendar.ini")
    let thisMonth = text(skin, "MeterTitle")
    check(!hidden(skin, "MeterToday") && !hidden(skin, "MeterTodayCircle"), "today is marked")
    let dayCells = (0..<42).filter { !text(skin, "MeterCell\($0)").isEmpty }.count + 1
    check(Double(dayCells) == skin.measure(named: "MeasureDays")?.value, "\(dayCells) day cells")
    check((0..<7).map { text(skin, "MeterHead\($0)") } == ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"],
          "weekday names \((0..<7).map { text(skin, "MeterHead\($0)") })")

    run(skin, "MeterNext")
    check(text(skin, "MeterTitle") != thisMonth, "next month")
    check(hidden(skin, "MeterToday") && hidden(skin, "MeterTodayCircle"), "no today mark in another month")
    for _ in 0..<13 { run(skin, "MeterPrevious") }
    check(skin.variable("MonthOffset") == "-12", "a year back: offset \(skin.variable("MonthOffset") ?? "")")
    let lastYear = text(skin, "MeterTitle")
    check(lastYear.hasSuffix(String(Int(thisMonth.suffix(4)).map { $0 - 1 } ?? 0)), "a year back: \(lastYear)")
    run(skin, "MeterTitle")
    check(text(skin, "MeterTitle") == thisMonth && !hidden(skin, "MeterToday"), "the title returns to today")

    // Arrows light up under the pointer.
    guard let next = skin.meter(named: "MeterNext") else { fatalError() }
    let normal = stroke(skin, "MeterNext")
    skin.mouseMoved(x: next.frame.x + 10, y: next.frame.y + 10)
    let hover = stroke(skin, "MeterNext")
    skin.mouseMoved(x: 5, y: 150)
    check(normal != nil && hover != normal && stroke(skin, "MeterNext") == normal, "arrow hover")
}

// MARK: Calendar against Foundation's Gregorian calendar

func variables() -> String { (try? String(contentsOf: variablesFile, encoding: .utf8)) ?? "" }

/// Runs `body` with @Resources/Variables.inc edited by `edit` (each pair replaces a whole "Key=value" line), then
/// puts the file back.
func withVariables(_ edit: [(String, String)], _ body: () throws -> Void) rethrows {
    let original = variables()
    var lines = original.components(separatedBy: "\n")
    for (key, value) in edit {
        if let i = lines.firstIndex(where: { $0.hasPrefix(key + "=") }) { lines[i] = key + "=" + value } else {
            check(false, "Variables.inc has no \(key)=")
        }
    }
    try? lines.joined(separator: "\n").write(to: variablesFile, atomically: true, encoding: .utf8)
    defer { try? original.write(to: variablesFile, atomically: true, encoding: .utf8) }
    try body()
}

var gregorian = Calendar(identifier: .gregorian)
gregorian.timeZone = TimeZone.current
let english = DateFormatter()
english.locale = Locale(identifier: "en_US_POSIX")
english.dateFormat = "MMMM yyyy"

/// Pages through 50 years on each side of this month and compares every shown month with Foundation: title, number
/// of days, the column of the 1st, every cell and the today mark.
func calendarSweep(_ skin: Skin, weekStart: Int) {
    let now = Date()
    guard let thisMonth = gregorian.date(from: gregorian.dateComponents([.year, .month], from: now)) else { return }
    let today = gregorian.component(.day, from: now)
    var failed = 0
    for offset in -600...600 where failed < 5 {
        skin.execute("[!SetVariable MonthOffset \(offset)][!Update]", from: nil)
        guard let first = gregorian.date(byAdding: .month, value: offset, to: thisMonth),
              let days = gregorian.range(of: .day, in: .month, for: first)?.count else { continue }
        let start = (gregorian.component(.weekday, from: first) - 1 - weekStart + 7) % 7
        let todayShown = offset == 0 ? today : 0
        var problems: [String] = []
        if text(skin, "MeterTitle") != english.string(from: first) { problems.append("title \(text(skin, "MeterTitle"))") }
        if skin.measure(named: "MeasureDays")?.value != Double(days) { problems.append("days") }
        if skin.measure(named: "MeasureStart")?.value != Double(start) { problems.append("start") }
        for cell in 0..<42 {
            let day = cell - start + 1
            let expected = (1...days).contains(day) && day != todayShown ? String(day) : ""
            if text(skin, "MeterCell\(cell)") != expected { problems.append("cell \(cell) \"\(text(skin, "MeterCell\(cell)"))\"") }
        }
        if hidden(skin, "MeterToday") != (todayShown == 0) { problems.append("today mark") }
        if !problems.isEmpty {
            failed += 1
            check(false, "calendar (week start \(weekStart)) \(english.string(from: first)): \(problems.prefix(4))")
        }
    }
    check(failed == 0, "calendar sweep, week start \(weekStart)")
    skin.execute("[!SetVariable MonthOffset 0][!Update]", from: nil)
}

do {
    let (skin, _) = try load("Calendar", "Calendar.ini")
    calendarSweep(skin, weekStart: 0)

    // A fixed "today" (Time measures with a TimeStamp): 4 March 2026, a Wednesday in a month starting on Sunday.
    // Early days of the month must not get a leading zero in the today mark.
    for measure in ["MeasureToday", "MeasureThisMonth", "MeasureThisYear"] {
        skin.execute("[!SetOption \(measure) TimeStampFormat \"%Y-%m-%d\"][!SetOption \(measure) TimeStamp \"2026-03-04\"]",
                     from: nil)
    }
    skin.execute("[!Update]", from: nil)
    check(text(skin, "MeterTitle") == "March 2026", "fixed today: \(text(skin, "MeterTitle"))")
    check(text(skin, "MeterToday") == "4", "today mark without a leading zero: \"\(text(skin, "MeterToday"))\"")
    check(text(skin, "MeterCell3").isEmpty && text(skin, "MeterCell2") == "3" && text(skin, "MeterCell4") == "5",
          "today's cell is left to the mark")
    if let circle = skin.meter(named: "MeterTodayCircle"), let cell = skin.meter(named: "MeterCell3"),
       let mark = skin.meter(named: "MeterToday") {
        check(abs(circle.frame.x + circle.frame.width / 2 - cell.frame.x) < 0.5
              && abs(circle.frame.y + circle.frame.height / 2 - cell.frame.y) < 0.5,
              "today circle on its cell: \(circle.frame) vs \(cell.frame)")
        // Both are centred (StringAlign=CenterCenter): compare the centres of what they draw.
        check(abs(mark.frame.x + mark.frame.width / 2 - cell.frame.x - cell.frame.width / 2) < 0.5
              && abs(mark.frame.y + mark.frame.height / 2 - cell.frame.y - cell.frame.height / 2) < 0.5,
              "today number on its cell: \(mark.frame) vs \(cell.frame)")
    }
}

// MARK: Analog clock

func circularDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 1)
    return min(d, 1 - d)
}

do {
    let (dial, _) = try load("Clock", "Dial.ini", updates: 1)
    let c = gregorian.dateComponents([.hour, .minute, .second], from: Date())
    let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
    let seconds = Double(hour * 3600 + minute * 60 + second)
    for (meter, turn) in [("MeterHourHand", 43200.0), ("MeterMinuteHand", 3600.0), ("MeterSecondHand", 60.0)] {
        guard let hand = dial.meter(named: meter) as? RoundlineMeter else {
            check(false, "\(meter) is a Roundline meter")
            continue
        }
        let expected = seconds.truncatingRemainder(dividingBy: turn) / turn
        check(circularDistance(hand.fraction, expected) < 2.5 / turn, "\(meter) at \(hand.fraction), expected \(expected)")
    }

    // Everything follows Size, including the date (with a readable minimum).
    let dialFile = skins.appendingPathComponent("Deskset/Clock/Dial.ini")
    let original = try String(contentsOf: dialFile, encoding: .utf8)
    for (size, dayFont) in [(368, 16.0), (184, 8.0), (120, 7.0)] {
        let sized = skins.appendingPathComponent("Deskset/Clock/Sized.ini")
        try original.replacingOccurrences(of: "\nSize=184\n", with: "\nSize=\(size)\n")
            .write(to: sized, atomically: true, encoding: .utf8)
        let (skin, _) = try load("Clock", "Sized.ini")
        try? FileManager.default.removeItem(at: sized)
        check(skin.width == Double(size) && skin.height == Double(size), "Size=\(size): \(skin.width)x\(skin.height)")
        let font = (skin.meter(named: "MeterDay") as? StringMeter)?.style.fontSize
        check(font.map { abs($0 - dayFont) < 0.01 } ?? false, "Size=\(size): date font \(String(describing: font))")
        check(skin.issues.isEmpty, "Size=\(size): \(skin.issues)")
    }
}

// MARK: Every skin with the other settings (light theme, 12 hours, Monday, system language)

try withVariables([("Theme", "Light"), ("ClockHours", "12"), ("WeekStart", "1"), ("Locale", "Local")]) {
    for (config, file) in all {
        let (skin, host) = try load(config, file)
        check(skin.issues.isEmpty, "\(config)/\(file) (other settings): compatibility issues \(skin.issues)")
        let logs = host.logs.filter { !$0.hasPrefix("debug") && !$0.hasPrefix("notice") }
        check(logs.isEmpty, "\(config)/\(file) (other settings): log \(logs)")
        check(skin.contextMenuItems().last?.title == "Use Dark Theme", "\(config)/\(file): dark theme entry")
    }
}

// AM / PM follows Locale like the weekday and the date.
try withVariables([("ClockHours", "12"), ("Locale", "zh-CN")]) {
    let (clock, _) = try load("Clock", "Clock.ini")
    check(["上午", "下午"].contains(text(clock, "MeterSuffix")), "localized AM/PM \(text(clock, "MeterSuffix"))")
    check(text(clock, "MeterWeekday").hasPrefix("星期"), "localized weekday \(text(clock, "MeterWeekday"))")
}

// MARK: Switches that rewrite Variables.inc

do {
    let (clock, host) = try load("Clock", "Clock.ini")
    let menu = clock.contextMenuItems()
    check(menu.first?.title == "Use 12-Hour Time", "clock menu \(menu.map(\.title))")
    clock.execute(menu.first?.action ?? "", from: nil)
    check(variables().contains("\nClockHours=12\n"), "12-hour switch writes ClockHours=12")
    check(host.handled.contains { $0.name == "refresh" }, "12-hour switch refreshes")

    let (clock12, _) = try load("Clock", "Clock.ini")
    check(clock12.contextMenuItems().first?.title == "Use 24-Hour Time", "12-hour menu")
    let time = text(clock12, "MeterTime")
    check(!time.hasPrefix("0") && time.count <= 5, "12-hour time \(time)")
    check(["AM", "PM"].contains(text(clock12, "MeterSuffix")), "AM/PM \(text(clock12, "MeterSuffix"))")
    clock12.execute(clock12.contextMenuItems().first?.action ?? "", from: nil)
    let (clock24, _) = try load("Clock", "Clock.ini")
    check(text(clock24, "MeterSuffix").isEmpty && variables().contains("\nClockHours=24\n"), "back to 24 hours")

    // Variants switch to each other.
    clock24.execute(clock24.contextMenuItems()[1].action, from: nil)
    let (dial, dialHost) = try load("Clock", "Dial.ini")
    dial.execute(dial.contextMenuItems()[0].action, from: nil)
    check(dialHost.handled.contains { $0.name == "activateconfig" && $0.args == ["Deskset\\Clock", "Clock.ini"] },
          "Dial → Clock.ini \(dialHost.handled)")

    // Calendar week start.
    let (calendar, _) = try load("Calendar", "Calendar.ini")
    calendar.execute(calendar.contextMenuItems()[0].action, from: nil)
    check(variables().contains("\nWeekStart=1\n"), "week start switch writes WeekStart=1")
    let (monday, _) = try load("Calendar", "Calendar.ini")
    check(text(monday, "MeterHead0") == "MON" && text(monday, "MeterHead6") == "SUN", "week starts on Monday")
    check(monday.contextMenuItems()[0].title == "Start Week on Sunday", "week start menu")
    calendarSweep(monday, weekStart: 1)

    // Theme: every skin's last menu entry writes Theme and refreshes the Deskset group.
    let (system, systemHost) = try load("System", "System.ini")
    system.execute(system.contextMenuItems().last?.action ?? "", from: nil)
    check(variables().contains("\nTheme=Light\n") && variables().contains("\n@IncludeTheme="), "theme switch writes Theme=Light")
    check(systemHost.handled.contains { $0.name == "refreshgroup" && $0.args == ["Deskset"] }, "theme switch refreshes the group")
    let (light, _) = try load("System", "System.ini")
    check(light.variable("PanelTop") != system.variable("PanelTop"), "light theme loaded")
    check(light.contextMenuItems().last?.title == "Use Dark Theme", "light theme menu")
}

try? FileManager.default.removeItem(at: work)
print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
