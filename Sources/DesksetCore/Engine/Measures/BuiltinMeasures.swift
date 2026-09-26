import Foundation

// Built-in measure types. System readings come from `skin.system` (SystemDataSource).
// Clean-room implementation of the public manual pages /manual/measures/<type>/ and /manual/plugins/power/.

// MARK: - Calc

/// `Measure=Calc` (manual: /manual/measures/calc/).
/// - `Formula` (default 0) uses measure names as numbers (0 for measures without a number), plus the Calc-only
///   `Random` and `Counter` (number of skin updates since load, kept across a refresh when the host calls
///   `Skin.continueCounter(from:)`). A formula that cannot be evaluated keeps the previous result and is logged once.
/// - `Random`: an integer in `LowBound…HighBound` (defaults 0 / 100, bounds limited to 32-bit integers),
///   regenerated every update with `UpdateRandom=1`, otherwise generated once. `UniqueRandom=1` does not repeat a
///   value before all values were used, when the range spans at most 65535; a change of the bounds resets that.
/// - The range (MinValue/MaxValue) tracks the observed values unless set (see `Measure`).
public final class CalcMeasure: Measure {
    private var compiled: CompiledFormula?
    private var formulaSource: String?
    private var usesRandom = false
    private var lowBound = 0.0
    private var highBound = 100.0
    private var updateRandom = false
    private var uniqueRandom = false
    private var randomValue: Double?
    private var uniquePool: [Double] = []
    private var loggedEvaluationError = false
    private var loggedCompileError = false
    /// Last successfully computed formula result: a formula that fails to evaluate keeps it (returning the
    /// measure's final `value` instead would apply InvertMeasure / AverageSize a second time).
    private var lastResult = 0.0

    public override func readMeasureOptions() {
        let source = string("Formula").trimmingCharacters(in: .whitespaces)
        if source != formulaSource {
            formulaSource = source
            compiled = source.isEmpty ? nil : (try? Formula.compile(source))
            usesRandom = compiled?.identifiers.contains { $0.caseInsensitiveCompare("Random") == .orderedSame } ?? false
            // Logged once per measure: a dynamic formula may change (and fail) on every update. A formula whose
            // section variables are not resolved yet (`[Meter:X]` read at load) is checked at the first update.
            if compiled == nil && !source.isEmpty && !loggedCompileError && !awaitsSectionVariables("Formula") {
                loggedCompileError = true
                skin.log("[\(name)] invalid Formula: \(source)", level: .error)
            }
        }
        let limit = 2_147_483_647.0
        let low = double("LowBound", 0).rounded(.towardZero).clamped(-limit - 1, limit)
        let high = double("HighBound", 100).rounded(.towardZero).clamped(-limit - 1, limit)
        if low != lowBound || high != highBound {
            uniquePool = []
            if randomValue != nil { randomValue = nil }
        }
        lowBound = low
        highBound = high
        updateRandom = bool("UpdateRandom", false)
        uniqueRandom = bool("UniqueRandom", false)
    }

    public override func computeValue() -> Double {
        guard let compiled else { return 0 }
        if usesRandom && (updateRandom || randomValue == nil) { randomValue = nextRandom() }
        let counter = Double(skin.counter)
        do {
            lastResult = try compiled.evaluate { identifier in
                switch identifier.lowercased() {
                case "counter": return counter
                case "random": return self.randomValue ?? 0
                default: return self.skin.formulaValue(of: identifier, from: self)
                }
            }
        } catch {
            if !loggedEvaluationError {
                loggedEvaluationError = true
                skin.log("[\(name)] cannot evaluate Formula: \(error)", level: .error)
            }
        }
        return lastResult
    }

    private func nextRandom() -> Double {
        let lo = min(lowBound, highBound)
        let hi = max(lowBound, highBound)
        guard uniqueRandom, hi - lo <= 65_535 else { return Double(Int.random(in: Int(lo)...Int(hi))) }
        if uniquePool.isEmpty { uniquePool = stride(from: lo, through: hi, by: 1).shuffled() }
        return uniquePool.popLast() ?? lo
    }
}

// MARK: - Time

public final class TimeMeasure: Measure {
    private var format = TimeFormatting.defaultFormat
    private var hasFormatOption = false
    private var timeZone = TimeZone.current
    private var locale = TimeFormatting.defaultLocale
    private var timeStampText = ""
    private var timeStampFormat: String?
    private var timeStampLocale: Locale?
    private var loggedTimeStampError = false
    /// Windows timestamp (seconds since 1601, wall clock) of the last update; `[Measure:TimeStamp]`.
    public private(set) var timestamp = 0.0

    public override func readMeasureOptions() {
        let f = option("Format")
        hasFormatOption = f != nil
        format = f ?? TimeFormatting.defaultFormat
        let tz = option("TimeZone").map { raw -> String in
            OptionValue.number(raw).map { NumberFormatting.plain($0) } ?? raw
        }
        timeZone = TimeFormatting.timeZone(forOption: tz, daylightSavingTime: bool("DaylightSavingTime", true))
        locale = TimeFormatting.locale(fromOption: option("FormatLocale")) ?? TimeFormatting.defaultLocale
        timeStampText = string("TimeStamp").trimmingCharacters(in: .whitespaces)
        timeStampFormat = option("TimeStampFormat")
        timeStampLocale = TimeFormatting.locale(fromOption: option("TimeStampLocale"))
    }

    public override func computeValue() -> Double {
        if timeStampText.isEmpty {
            timestamp = TimeFormatting.measureValue(for: Date(), timeZone: timeZone)
        } else if let parsed = TimeFormatting.parseTimeStamp(timeStampText, format: timeStampFormat,
                                                              locale: timeStampLocale) {
            timestamp = parsed
        } else {
            if !loggedTimeStampError {
                loggedTimeStampError = true
                skin.log("[\(name)] TimeStamp \"\(timeStampText)\" does not match TimeStampFormat", level: .error)
            }
            timestamp = 0
        }
        let text = TimeFormatting.format(windowsTimestamp: timestamp, format: format, locale: locale,
                                         nameTimeZone: timeZone)
        rawString = text
        return hasFormatOption ? TimeFormatting.numberValue(ofFormatted: text) : timestamp
    }
}

// MARK: - Uptime

/// `Measure=Uptime` (manual: /manual/measures/uptime/): the number value is the seconds since the last restart;
/// the string value is `Format` (default `%4!i!d %3!i!:%2!02i!`). `SecondsValue` replaces the uptime with any
/// number of seconds (e.g. `SecondsValue=([MeasureNow:] - [MeasureLogon:])` with DynamicVariables).
public final class UptimeMeasure: Measure {
    private var format = UptimeFormatting.defaultFormat
    private var addDaysToHours = false
    private var secondsValue: Double?

    public override func readMeasureOptions() {
        format = option("Format") ?? UptimeFormatting.defaultFormat
        addDaysToHours = bool("AddDaysToHours", true)
        secondsValue = optionalDouble("SecondsValue")
    }

    public override func computeValue() -> Double {
        let seconds = secondsValue ?? skin.system.uptime()
        rawString = UptimeFormatting.format(seconds: seconds, format: format, addDaysToHours: addDaysToHours)
        return seconds
    }
}

// MARK: - CPU

/// `Measure=CPU`: `Processor=0` (default) is the average of all cores, N a specific core; 0…100.
public final class CPUMeasure: Measure {
    private var processor = 0

    public override var automaticMaxValue: Double { 100 }

    public override func readMeasureOptions() {
        processor = min(max(0, int("Processor", 0)), 4096)
    }

    public override func computeValue() -> Double {
        skin.system.cpuUsage(processor: processor)
    }
}

// MARK: - Memory / PhysicalMemory / SwapMemory

/// Memory measures (manual: /manual/measures/memory/). The value is the used amount in bytes (`Total=1`: the
/// total; `InvertMeasure=1`: the free amount); the range is 0…total and `MaxValue` cannot be set.
/// The manual defines PhysicalMemory as RAM, SwapMemory as "RAM + Pagefile.sys" and Memory as
/// "RAM + RAM + Pagefile.sys". On macOS the swap file(s) play the role of Pagefile.sys, so:
/// PhysicalMemory = RAM; SwapMemory = RAM + swap (used: RAM used + swap used); Memory = PhysicalMemory +
/// SwapMemory for both the total (2 × RAM + swap) and the used amount (2 × RAM used + swap used), so its free
/// amount (`InvertMeasure=1`) is the free RAM counted twice plus the free swap and never exceeds the total of the
/// two parts. `Free=1` (not in the manual, kept for compatibility) gives total − used.
public final class MemoryMeasure: Measure {
    public enum Kind { case total, physical, swap }
    private var kind = Kind.total
    private var totalMode = false
    private var freeMode = false
    private var lastTotal: Double?

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
        switch type {
        case "physicalmemory": kind = .physical
        case "swapmemory": kind = .swap
        default: kind = .total
        }
    }

    private func amounts() -> (total: Double, used: Double) {
        let m = skin.system.memoryStatus()
        switch kind {
        case .physical: return (m.physicalTotal, m.physicalUsed)
        case .swap: return (m.physicalTotal + m.swapTotal, m.physicalUsed + m.swapUsed)
        case .total: return (2 * m.physicalTotal + m.swapTotal, 2 * m.physicalUsed + m.swapUsed)
        }
    }

    public override var automaticMaxValue: Double { max(lastTotal ?? amounts().total, 1) }
    override var allowsMaxValueOption: Bool { false }

    public override func readMeasureOptions() {
        totalMode = bool("Total", false)
        freeMode = bool("Free", false)
    }

    public override func computeValue() -> Double {
        let a = amounts()
        lastTotal = a.total
        if totalMode { return a.total }
        if freeMode { return max(a.total - a.used, 0) }
        return a.used
    }
}

// MARK: - NetIn / NetOut / NetTotal

/// Net measures (manual: /manual/measures/net/): bytes per second (or cumulative bytes with `Cumulative=1`;
/// bits with `UseBits=1`).
/// - `Interface`: `Best` (default: the active interface, see `SystemDataSource.bestNetworkInterface()`), `0` for
///   all interfaces, an index into the active interfaces (1-based), or an interface name (`en0`). Judgment: a
///   Windows adapter name or alias (`Wi-Fi`, `Ethernet`) or an index that does not exist on this Mac falls back to
///   `Best` (logged once) instead of measuring nothing.
/// - MinValue / MaxValue are written in bits and divided by 8 (not with `UseBits=1`). The deprecated
///   `NetInSpeed` / `NetOutSpeed` (bytes; NetTotal uses their sum) act as MaxValue when MaxValue is not set.
///   Without either, the range tracks the observed values (manual, Measures → Percentage).
/// - Judgment: the rate uses the real time between two samples (not the nominal Update × UpdateDivider), so
///   bang-triggered or irregular updates still give bytes per second. The first update is 0; a counter that goes
///   backwards (interface change, reset) gives 0 for that update.
/// - `Cumulative=1` gives the interface counters since the system started (Deskset keeps no statistics across
///   restarts; `!ResetStats` is the host's business).
public final class NetMeasure: Measure {
    public enum Direction { case incoming, outgoing, total }
    private var direction = Direction.total
    private var interfaceName: String?
    private var cumulative = false
    private var useBits = false
    private var speedOption: Double?
    private var previous: (bytes: Double, time: TimeInterval)?
    private var loggedInterfaceFallback = false

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
        switch type {
        case "netin": direction = .incoming
        case "netout": direction = .outgoing
        default: direction = .total
        }
    }

    override var tracksValueRange: Bool { speedOption == nil }
    override var rangeOptionScale: Double { useBits ? 1 : 1.0 / 8 }
    public override var automaticMaxValue: Double { speedOption.map { useBits ? $0 * 8 : $0 } ?? 1 }

    public override func readMeasureOptions() {
        cumulative = bool("Cumulative", false)
        useBits = bool("UseBits", false)
        let inSpeed = optionalDouble("NetInSpeed"), outSpeed = optionalDouble("NetOutSpeed")
        switch direction {
        case .incoming: speedOption = inSpeed
        case .outgoing: speedOption = outSpeed
        case .total: speedOption = (inSpeed == nil && outSpeed == nil) ? nil : (inSpeed ?? 0) + (outSpeed ?? 0)
        }
        if let s = speedOption, !(s > 0) { speedOption = nil }

        let raw = string("Interface", "Best").trimmingCharacters(in: .whitespaces)
        let names = skin.system.networkInterfaces()
        let resolved: String?
        if raw.isEmpty || raw.caseInsensitiveCompare("Best") == .orderedSame {
            resolved = skin.system.bestNetworkInterface()
        } else if let index = Int(raw) {
            if index == 0 {
                resolved = nil
            } else if index > 0 && index <= names.count {
                resolved = names[index - 1]
            } else {
                resolved = fallback(raw)
            }
        } else if let match = names.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            resolved = match
        } else {
            resolved = fallback(raw)
        }
        if resolved != interfaceName { previous = nil }
        interfaceName = resolved
    }

    private func fallback(_ raw: String) -> String? {
        if !loggedInterfaceFallback {
            loggedInterfaceFallback = true
            skin.log("[\(name)] Interface=\(raw) does not exist on this Mac; using the active interface",
                     level: .notice)
        }
        return skin.system.bestNetworkInterface()
    }

    private func pick(_ c: NetworkCounters) -> Double {
        switch direction {
        case .incoming: return Double(c.received)
        case .outgoing: return Double(c.sent)
        case .total: return Double(c.received) + Double(c.sent)
        }
    }

    public override func computeValue() -> Double {
        let bytes = pick(skin.system.networkCounters(interface: interfaceName))
        let factor = useBits ? 8.0 : 1.0
        if cumulative { return bytes * factor }
        let now = skin.clock()
        defer { previous = (bytes, now) }
        guard let previous, now > previous.time else { return 0 }
        let delta = bytes - previous.bytes
        guard delta > 0 else { return 0 }
        return delta / (now - previous.time) * factor
    }
}

// MARK: - FreeDiskSpace

/// `Measure=FreeDiskSpace` (manual: /manual/measures/freediskspace/): free bytes (`Total=1`: total size;
/// `InvertMeasure=1`: used), range 0…total (`MaxValue` cannot be set).
/// - `Drive` (default `C:`): a Windows drive letter (`C:`, `D:\`) maps to the startup volume `/` (Deskset's
///   convention); otherwise a folder path (`/Volumes/Data`); a bare name (`Data`) means `/Volumes/Data`.
/// - `Label=1`: the string value is the volume name (the number is unchanged).
/// - `Type=1`: the drive type as number and string: 0 Error, 1 Removed (does not exist), 3 Removable, 4 Fixed,
///   5 Network, 6 CDRom, 7 Ram.
/// - `IgnoreRemovable=1` (default): removable media measure as 0 (Type and Label still work).
/// - `DiskQuota` is Windows-only; the free space is what the current user can use.
public final class FreeDiskSpaceMeasure: Measure {
    private var path = "/"
    private var totalMode = false
    private var labelMode = false
    private var typeMode = false
    private var ignoreRemovable = true
    private var lastTotal: Double?

    public override var automaticMaxValue: Double {
        max(lastTotal ?? skin.system.diskSpace(path: path)?.total ?? 1, 1)
    }
    override var allowsMaxValueOption: Bool { false }

    public override func readMeasureOptions() {
        path = FreeDiskSpaceMeasure.volumePath(string("Drive", "C:"))
        totalMode = bool("Total", false)
        labelMode = bool("Label", false)
        typeMode = bool("Type", false)
        ignoreRemovable = bool("IgnoreRemovable", true)
    }

    static func volumePath(_ raw: String) -> String {
        var drive = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        if drive.hasPrefix("\""), drive.hasSuffix("\""), drive.count >= 2 { drive = String(drive.dropFirst().dropLast()) }
        let u = Array(drive.utf8)
        let isLetter = u.count >= 2 && u[1] == UInt8(ascii: ":") && ((u[0] | 0x20) >= 0x61 && (u[0] | 0x20) <= 0x7A)
        if drive.isEmpty || (isLetter && (u.count == 2 || (u.count == 3 && u[2] == UInt8(ascii: "/")))) { return "/" }
        if drive.hasPrefix("~") { return (drive as NSString).expandingTildeInPath }
        if drive.hasPrefix("/") { return drive }
        return "/Volumes/" + drive
    }

    public override func computeValue() -> Double {
        let info = skin.system.volumeInfo(path: path)
        if typeMode {
            let type: (Double, String)
            switch info?.kind {
            case nil: type = (1, "Removed")
            case .removable?: type = (3, "Removable")
            case .fixed?: type = (4, "Fixed")
            case .network?: type = (5, "Network")
            case .cdRom?: type = (6, "CDRom")
            case .ram?: type = (7, "Ram")
            }
            rawString = type.1
            return type.0
        }
        // The string value is the label only with Label=1 (a !SetOption Label 0 / Type 0 drops the old text).
        rawString = labelMode ? (info?.label ?? "") : nil
        if ignoreRemovable && info?.kind == .removable {
            lastTotal = 0
            return 0
        }
        guard let space = skin.system.diskSpace(path: path) else {
            lastTotal = 0
            return 0
        }
        lastTotal = space.total
        return totalMode ? space.total : space.free
    }
}

// MARK: - Loop

/// `Measure=Loop` (manual: /manual/measures/loop/): StartValue (default 1) for one update, then +Increment
/// (default 1) per update, EndValue (default 100) for one update — a last step that would overshoot is shortened
/// to end exactly at EndValue — then again from StartValue; `LoopCount` loops (0 = endless), after which the
/// measure stays at EndValue. Values are whole numbers (fractions truncated). The range is min…max of Start/End
/// and cannot be set; AverageSize is ignored. A change of any of the four options or of InvertMeasure resets the
/// loop, as does `!CommandMeasure … "Reset"`.
/// Judgment: the loop always moves from StartValue towards EndValue by |Increment| (an Increment of the wrong sign
/// would never reach EndValue); Increment=0 stays at StartValue.
public final class LoopMeasure: Measure {
    private var startValue = 1.0
    private var endValue = 100.0
    private var increment = 1.0
    private var loopCount = 0
    private var current: Double?
    private var loops = 0
    private var finished = false
    private var signature: [Double]?

    public override var automaticMinValue: Double { min(startValue, endValue) }
    public override var automaticMaxValue: Double { max(startValue, endValue) }
    override var allowsMinValueOption: Bool { false }
    override var allowsMaxValueOption: Bool { false }
    override var allowsAverage: Bool { false }

    public override func readMeasureOptions() {
        func whole(_ key: String, _ defaultValue: Double) -> Double {
            double(key, defaultValue).rounded(.towardZero).clamped(-1e15, 1e15)
        }
        startValue = whole("StartValue", 1)
        endValue = whole("EndValue", 100)
        increment = whole("Increment", 1)
        loopCount = Int(whole("LoopCount", 0).clamped(0, 1e9))
        let newSignature = [startValue, endValue, increment, Double(loopCount), bool("InvertMeasure", false) ? 1 : 0]
        if let signature, signature != newSignature { reset() }
        signature = newSignature
    }

    private func reset() {
        current = nil
        loops = 0
        finished = false
    }

    public override func computeValue() -> Double {
        guard let c = current else {
            current = startValue
            return startValue
        }
        if finished { return endValue }
        let step = abs(increment)
        guard step > 0 else { return c }
        if c == endValue {
            loops += 1
            if loopCount > 0 && loops >= loopCount {
                finished = true
                return endValue
            }
            current = startValue
            return startValue
        }
        var next = endValue >= startValue ? c + step : c - step
        if (endValue >= startValue && next > endValue) || (endValue < startValue && next < endValue) {
            next = endValue
        }
        current = next
        return next
    }

    public override func execute(command: String) {
        if command.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Reset") == .orderedSame {
            reset()
        } else {
            super.execute(command: command)
        }
    }
}

// MARK: - String

/// `Measure=String`: the `String` option (formulas are not evaluated). The number value is the string read as a
/// number (0 when it is not one). InvertMeasure does not apply.
public final class StringMeasure: Measure {
    override var allowsInvert: Bool { false }
    /// `String`, read with the other options (so section variables in it follow the rules of every option).
    private var stringOption = ""

    public override func readMeasureOptions() {
        stringOption = string("String")
    }

    public override func computeValue() -> Double {
        let s = stringOption
        rawString = s
        return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
    }
}

// MARK: - Process

/// `Measure=Process` (also `Plugin=Process`): 1 while `ProcessName` (e.g. `Firefox.exe`; `.exe` is dropped) runs,
/// -1 otherwise.
public final class ProcessMeasure: Measure {
    private var processName = ""

    public override var automaticMinValue: Double { -1 }

    public override func readMeasureOptions() {
        var n = string("ProcessName").trimmingCharacters(in: .whitespaces)
        if n.lowercased().hasSuffix(".exe") { n = String(n.dropLast(4)) }
        processName = n
    }

    public override func computeValue() -> Double {
        processName.isEmpty ? -1 : (skin.system.isProcessRunning(processName) ? 1 : -1)
    }
}

// MARK: - SysInfo

/// `Measure=SysInfo` (also `Plugin=SysInfo`; manual: /manual/measures/sysinfo/).
///
/// The engine answers the types it can compute portably — monitors (from `SkinEnvironment`: NUM_MONITORS,
/// SCREEN_SIZE, SCREEN_WIDTH/HEIGHT, VIRTUAL_SCREEN_*, WORK_AREA*; `SysInfoData=N` selects monitor N, 1-based),
/// time zone (TIMEZONE_*), OS_BITS and PAGESIZE. Everything else is asked from `SystemDataSource.sysInfo`, with
/// fallbacks for COMPUTER_NAME, USER_NAME, HOST_NAME, OS_VERSION and OS_PRODUCT_NAME. Unknown types give 0 / ""
/// and a compatibility issue. String types have the number 0; number types have no separate string.
/// Judgments: SCREEN_SIZE / WORK_AREA are formatted `"1920 x 1080"` (the manual's "width x height");
/// VIRTUAL_SCREEN_TOP/LEFT with SysInfoData give that monitor's position; TIMEZONE_ISDST is -1 for zones without
/// daylight saving time.
public final class SysInfoMeasure: Measure {
    private var infoType = ""
    private var infoData = ""
    /// The last value asked for a documented type that has no answer on the Mac (e.g. USER_SID, ADAPTER_GUID).
    private var unanswered = false

    /// A documented type without a Mac answer: on Windows it has a value, so String meters keep its line.
    public override var valueUnavailable: Bool { unanswered }

    /// Every SysInfoType the manual documents (/manual/measures/sysinfo/). Another value is a mistake in the skin that
    /// gives nothing in Rainmeter either: a log line, not a compatibility note.
    static let documentedTypes: Set<String> = [
        "COMPUTER_NAME", "USER_NAME", "USER_SID", "USER_LOGONTIME", "LAST_SLEEP_TIME", "LAST_WAKE_TIME",
        "OS_PRODUCT_NAME", "OS_VERSION", "OS_BITS", "PAGESIZE", "IDLE_TIME", "HOST_NAME", "DOMAIN_NAME",
        "DOMAIN_WORKGROUP", "DNS_SERVER", "ADAPTER_DESCRIPTION", "ADAPTER_TYPE", "ADAPTER_ALIAS", "ADAPTER_GUID",
        "ADAPTER_STATE", "ADAPTER_STATUS", "ADAPTER_TRANSMIT_SPEED", "ADAPTER_RECEIVE_SPEED", "MAC_ADDRESS",
        "NET_MASK", "IP_ADDRESS", "GATEWAY_ADDRESS", "GATEWAY_ADDRESS_V4", "GATEWAY_ADDRESS_V6", "LAN_CONNECTIVITY",
        "LAN_CONNECTIVITY_V4", "LAN_CONNECTIVITY_V6", "INTERNET_CONNECTIVITY", "INTERNET_CONNECTIVITY_V4",
        "INTERNET_CONNECTIVITY_V6", "NUM_MONITORS", "SCREEN_SIZE", "SCREEN_WIDTH", "SCREEN_HEIGHT",
        "VIRTUAL_SCREEN_TOP", "VIRTUAL_SCREEN_LEFT", "VIRTUAL_SCREEN_WIDTH", "VIRTUAL_SCREEN_HEIGHT", "WORK_AREA",
        "WORK_AREA_TOP", "WORK_AREA_LEFT", "WORK_AREA_WIDTH", "WORK_AREA_HEIGHT", "TIMEZONE_ISDST", "TIMEZONE_BIAS",
        "TIMEZONE_STANDARD_NAME", "TIMEZONE_STANDARD_BIAS", "TIMEZONE_DAYLIGHT_NAME", "TIMEZONE_DAYLIGHT_BIAS",
    ]

    public override func readMeasureOptions() {
        infoType = string("SysInfoType").trimmingCharacters(in: .whitespaces).uppercased()
        infoData = string("SysInfoData").trimmingCharacters(in: .whitespaces)
    }

    public override func computeValue() -> Double {
        guard !infoType.isEmpty else {
            unanswered = false
            rawString = ""
            return 0
        }
        let result = engineValue() ?? skin.system.sysInfo(type: infoType, data: infoData) ?? fallbackValue()
        guard let result else {
            if SysInfoMeasure.documentedTypes.contains(infoType) {
                unanswered = true
                skin.addIssue("SysInfoType=\(infoType) is not supported on macOS")
            } else {
                skin.logOnce("[\(name)] SysInfoType=\(infoType) is not a SysInfo type", level: .warning)
            }
            rawString = ""
            return 0
        }
        unanswered = false
        rawString = result.string
        return result.number.isFinite ? result.number : 0
    }

    private func number(_ v: Double) -> (number: Double, string: String?) { (v, nil) }
    private func text(_ s: String) -> (number: Double, string: String?) { (0, s) }

    /// Types computed by the engine (they take precedence over the data source).
    private func engineValue() -> (number: Double, string: String?)? {
        switch infoType {
        case "OS_BITS": return number(64)
        case "PAGESIZE": return number(Double(getpagesize()))
        case "NUM_MONITORS", "SCREEN_SIZE", "SCREEN_WIDTH", "SCREEN_HEIGHT", "VIRTUAL_SCREEN_TOP",
             "VIRTUAL_SCREEN_LEFT", "VIRTUAL_SCREEN_WIDTH", "VIRTUAL_SCREEN_HEIGHT", "WORK_AREA", "WORK_AREA_TOP",
             "WORK_AREA_LEFT", "WORK_AREA_WIDTH", "WORK_AREA_HEIGHT":
            return monitorValue(skin.currentEnvironment().screens)
        case "TIMEZONE_ISDST", "TIMEZONE_BIAS", "TIMEZONE_STANDARD_BIAS", "TIMEZONE_DAYLIGHT_BIAS",
             "TIMEZONE_STANDARD_NAME", "TIMEZONE_DAYLIGHT_NAME":
            return SysInfoMeasure.timeZoneValue(infoType, zone: TimeZone.current, at: Date())
        default:
            return nil
        }
    }

    private func monitorValue(_ screens: [SkinScreen]) -> (number: Double, string: String?)? {
        let requested = Int(infoData).flatMap { $0 >= 1 && $0 <= screens.count ? $0 - 1 : nil }
        let screen = screens.isEmpty ? nil : screens[requested ?? 0]
        func size(_ r: SkinRect) -> String { "\(Int(r.width.clamped(0, 1e9))) x \(Int(r.height.clamped(0, 1e9)))" }
        var virtual = screens.first?.area ?? SkinRect()
        for s in screens.dropFirst() {
            let minX = min(virtual.x, s.area.x), minY = min(virtual.y, s.area.y)
            let maxX = max(virtual.maxX, s.area.maxX), maxY = max(virtual.maxY, s.area.maxY)
            virtual = SkinRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        switch infoType {
        case "NUM_MONITORS": return number(Double(screens.count))
        case "SCREEN_SIZE": return text(size(screens.first?.area ?? SkinRect()))
        case "WORK_AREA": return text(size(screens.first?.workArea ?? SkinRect()))
        case "SCREEN_WIDTH": return number(screen?.area.width ?? 0)
        case "SCREEN_HEIGHT": return number(screen?.area.height ?? 0)
        case "VIRTUAL_SCREEN_TOP": return number(requested != nil ? (screen?.area.y ?? 0) : virtual.y)
        case "VIRTUAL_SCREEN_LEFT": return number(requested != nil ? (screen?.area.x ?? 0) : virtual.x)
        case "VIRTUAL_SCREEN_WIDTH": return number(virtual.width)
        case "VIRTUAL_SCREEN_HEIGHT": return number(virtual.height)
        case "WORK_AREA_TOP": return number(screen?.workArea.y ?? 0)
        case "WORK_AREA_LEFT": return number(screen?.workArea.x ?? 0)
        case "WORK_AREA_WIDTH": return number(screen?.workArea.width ?? 0)
        case "WORK_AREA_HEIGHT": return number(screen?.workArea.height ?? 0)
        default: return nil
        }
    }

    /// Windows semantics: "UTC = standard local time + bias" (minutes); daylight bias is the extra offset while
    /// daylight saving time is in effect (usually -60).
    static func timeZoneValue(_ infoType: String, zone: TimeZone,
                              at date: Date) -> (number: Double, string: String?)? {
        func number(_ v: Double) -> (number: Double, string: String?) { (v, nil) }
        func text(_ s: String) -> (number: Double, string: String?) { (0, s) }
        let isDST = zone.isDaylightSavingTime(for: date)
        let usesDST = isDST || zone.nextDaylightSavingTimeTransition(after: date) != nil
        let standardOffset = Double(zone.secondsFromGMT(for: date)) - zone.daylightSavingTimeOffset(for: date)
        switch infoType {
        case "TIMEZONE_ISDST": return number(usesDST ? (isDST ? 1 : 0) : -1)
        case "TIMEZONE_BIAS": return number(-standardOffset / 60)
        case "TIMEZONE_STANDARD_BIAS": return number(0)
        case "TIMEZONE_DAYLIGHT_BIAS":
            guard usesDST else { return number(0) }
            var dstOffset = zone.daylightSavingTimeOffset(for: date)
            if !isDST, let next = zone.nextDaylightSavingTimeTransition(after: date) {
                dstOffset = zone.daylightSavingTimeOffset(for: next.addingTimeInterval(3600))
            }
            return number(-dstOffset / 60)
        case "TIMEZONE_STANDARD_NAME":
            return text(zone.localizedName(for: .standard, locale: .current) ?? zone.identifier)
        case "TIMEZONE_DAYLIGHT_NAME":
            return text(zone.localizedName(for: .daylightSaving, locale: .current) ?? zone.identifier)
        default: return nil
        }
    }

    private static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()

    /// Looked up once: `Host.current()` can block on name resolution, and this runs on every update.
    private static let computerName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    /// Portable answers used when the data source has none.
    private func fallbackValue() -> (number: Double, string: String?)? {
        switch infoType {
        case "USER_NAME": return text(NSUserName())
        case "COMPUTER_NAME", "HOST_NAME": return text(SysInfoMeasure.computerName)
        case "OS_VERSION", "OS_PRODUCT_NAME": return text(SysInfoMeasure.osVersion)
        default: return nil
        }
    }
}

// MARK: - Plugin=PowerPlugin

/// `Measure=Plugin`, `Plugin=PowerPlugin` (manual: /manual/plugins/power/). `PowerState` (case-insensitive):
/// - `ACLine`: 1 plugged in (also for Macs without a battery), 0 on battery.
/// - `Status`: 0 no battery, 1 charging, 2 critical (< 5 %), 3 low (< 33 %), 4 above low.
/// - `Status2`: Windows `BatteryFlag` bits: 1 high (> 66 %), 2 low (< 33 %), 4 critical (< 5 %), 8 charging,
///   128 no battery.
/// - `Lifetime`: seconds of battery time left, the string formatted with `Format` (default `%H:%M`, Time measure
///   syntax); -1 / "Unknown" while unknown or on AC power.
/// - `Percent` (default): battery charge 0…100 (100 without a battery).
/// - `Hz` / `MHz`: rated CPU frequency when the system reports one, else 0.
public final class PowerPluginMeasure: Measure {
    private var state = "PERCENT"
    private var format = "%H:%M"

    public override var automaticMaxValue: Double {
        switch state {
        case "PERCENT": return 100
        case "STATUS": return 4
        default: return 1
        }
    }

    public override func readMeasureOptions() {
        state = string("PowerState", "PERCENT").trimmingCharacters(in: .whitespaces).uppercased()
        format = option("Format") ?? "%H:%M"
    }

    public override func computeValue() -> Double {
        let battery = skin.system.battery()
        rawString = nil   // only Lifetime has a string of its own (PowerState may change with !SetOption)
        switch state {
        case "ACLINE":
            return (battery?.isPluggedIn ?? true) ? 1 : 0
        case "STATUS":
            guard let b = battery else { return 0 }
            if b.isCharging { return 1 }
            if b.percent < 5 { return 2 }
            if b.percent < 33 { return 3 }
            return 4
        case "STATUS2":
            guard let b = battery else { return 128 }
            var flags = 0.0
            if b.percent > 66 { flags += 1 }
            if b.percent < 33 { flags += 2 }
            if b.percent < 5 { flags += 4 }
            if b.isCharging { flags += 8 }
            return flags
        case "LIFETIME":
            guard let b = battery, !b.isPluggedIn, let minutes = b.minutesRemaining, minutes.isFinite,
                  minutes >= 0 else {
                rawString = "Unknown"
                return -1
            }
            let seconds = min(minutes, 1e7) * 60
            let date = Date(timeIntervalSince1970: seconds)
            rawString = TimeFormatting.format(date, format: format, timeZone: TimeZone(secondsFromGMT: 0) ?? .current)
            return seconds
        case "HZ":
            return skin.system.cpuFrequency() ?? 0
        case "MHZ":
            return (skin.system.cpuFrequency() ?? 0) / 1_000_000
        default:
            return battery?.percent ?? 100
        }
    }
}

/// Placeholder for measure types that cannot work on macOS (Registry, Script, Windows plugins…): 0 and "".
public final class UnsupportedMeasure: Measure {
    /// False when the section is not a valid measure in Rainmeter either (a mistyped `Measure=` or a
    /// `Measure=Plugin` without `Plugin=`): its missing value is then not a Mac difference.
    public internal(set) var isMacDifference = true

    public override var valueUnavailable: Bool { isMacDifference }

    public override func computeValue() -> Double {
        rawString = ""
        return 0
    }

    public override func execute(command: String) {}
}
