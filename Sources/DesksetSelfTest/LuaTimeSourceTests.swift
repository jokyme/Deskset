import Darwin
import Foundation
@testable import DesksetCore

private struct LuaTimeSample {
    let name: String
    let fields: String
    let hint: Int
    let automaticTransition: Bool

    func expression(includingOffset: Bool = true) -> String {
        let format = includingOffset ? "%Y-%m-%d %H:%M:%S %z" : "%Y-%m-%d %H:%M:%S"
        let flag = hint < 0 ? "nil" : (hint == 0 ? "false" : "true")
        return """
        (function()
          local fields = \(fields)
          fields.isdst = \(flag)
          local time = os.time(fields)
          if time == nil then return 'nil' end
          return string.format('%.0f', time) .. '|' .. os.date('\(format)', time)
            .. '|' .. tostring(os.date('*t', time).isdst)
        end)()
        """
    }
}

private let luaTimeEpoch: Double = 1_790_424_000 // 2026-09-26T12:00:00Z.

private func luaTimeSamples(_ zone: String) -> [LuaTimeSample] {
    var fields: [(String, String, Bool)] = [
        ("UTC clock table", "os.date('!*t', 1790424000)", false),
        ("local clock table", "os.date('*t', 1790424000)", false),
        ("normalized fields", "{year=2025, month=13, day=0, hour=25, min=61, sec=62}", false),
    ]
    switch zone {
    case "Europe/Oslo":
        fields += [
            ("summer", "{year=2026, month=9, day=26, hour=12, min=0, sec=0}", false),
            ("winter", "{year=2026, month=1, day=15, hour=12, min=0, sec=0}", false),
            ("spring gap", "{year=2026, month=3, day=29, hour=2, min=30, sec=0}", true),
            ("autumn fold", "{year=2026, month=10, day=25, hour=2, min=30, sec=0}", true),
        ]
    case "Australia/Lord_Howe":
        fields += [
            ("summer", "{year=2026, month=1, day=15, hour=12, min=0, sec=0}", false),
            ("winter", "{year=2026, month=7, day=15, hour=12, min=0, sec=0}", false),
            ("spring gap", "{year=2026, month=10, day=4, hour=2, min=15, sec=0}", true),
            ("autumn fold", "{year=2026, month=4, day=5, hour=1, min=45, sec=0}", true),
        ]
    default:
        fields += [
            ("summer", "{year=2026, month=9, day=26, hour=12, min=0, sec=0}", false),
            ("winter", "{year=2026, month=1, day=15, hour=12, min=0, sec=0}", false),
            ("epoch", "{year=1970, month=1, day=1, hour=0, min=0, sec=0}", false),
        ]
    }
    return fields.flatMap { name, table, transition in
        [-1, 0, 1].map { hint in
            let label = hint < 0 ? "absent" : (hint == 0 ? "false" : "true")
            return LuaTimeSample(name: "\(name), isdst=\(label)", fields: table, hint: hint,
                                 automaticTransition: transition && hint < 0)
        }
    }
}

private func luaAutomaticTimeSamples(_ zone: String) -> [LuaTimeSample] {
    var boundaries: [(String, [Int], Int)] = []
    switch zone {
    case "Europe/Oslo":
        boundaries = [("spring gap", [2026, 3, 29, 2, 0], 3600), ("autumn fold", [2026, 10, 25, 2, 0], 3600),
                      ("post-2038 fold", [2050, 10, 30, 2, 0], 3600)]
    case "Australia/Lord_Howe":
        boundaries = [("autumn fold", [2026, 4, 5, 1, 30], 1800), ("spring gap", [2026, 10, 4, 2, 0], 1800)]
    case "Europe/Dublin":
        boundaries = [("spring gap", [2026, 3, 29, 1, 0], 3600), ("autumn fold", [2026, 10, 25, 1, 0], 3600)]
    case "Africa/Casablanca":
        boundaries = [("Ramadan fold", [2026, 2, 15, 2, 0], 3600), ("Ramadan gap", [2026, 3, 22, 2, 0], 3600)]
    case "America/New_York":
        boundaries = [("spring gap", [2026, 3, 8, 2, 0], 3600), ("autumn fold", [2026, 11, 1, 1, 0], 3600)]
    case "Europe/Moscow":
        boundaries = [("standard-time fold", [2014, 10, 26, 1, 0], 3600)]
    case "Antarctica/Troll":
        boundaries = [("two-hour gap", [2026, 3, 29, 1, 0], 7200), ("two-hour fold", [2026, 10, 25, 1, 0], 7200)]
    default: break
    }
    var result = luaTimeSamples(zone).filter { $0.hint < 0 && !$0.automaticTransition }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    for (name, fields, length) in boundaries {
        let start = calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2],
                                                      hour: fields[3], minute: fields[4], second: 0))!
        // Both exact boundaries, their adjacent seconds, and interior points. Native mktime can choose different
        // occurrences within one fold; just checking the middle or assuming first/last would miss that contract.
        for offset in [-1, 0, 1, length / 4, length / 2, length * 3 / 4, length - 1, length, length + 1] {
            let date = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                               from: start.addingTimeInterval(Double(offset)))
            let table = "{year=\(date.year!), month=\(date.month!), day=\(date.day!), "
                + "hour=\(date.hour!), min=\(date.minute!), sec=\(date.second!)}"
            result.append(LuaTimeSample(name: "\(name) \(offset)s, isdst=absent", fields: table,
                                        hint: -1, automaticTransition: true))
        }
    }
    // Native mktime retains out-of-range seconds until after its first candidate search, then retries normalized
    // fields if that search falls in a gap. Test both signs, a gap crossed by normalization, and pre-epoch fields.
    let deferredSeconds: [(String, String)]
    switch zone {
    case "Europe/Oslo":
        deferredSeconds = [
            ("fold with excess seconds", "{year=2026, month=10, day=25, hour=2, min=0, sec=2700}"),
            ("fold with negative seconds", "{year=2026, month=10, day=25, hour=3, min=0, sec=-1800}"),
        ]
    case "America/New_York":
        deferredSeconds = [
            ("normalization leaves gap", "{year=2026, month=3, day=8, hour=2, min=0, sec=3600}"),
            ("negative seconds cross gap", "{year=2026, month=3, day=8, hour=3, min=30, sec=-3600}"),
            ("pre-epoch fold excess seconds", "{year=1969, month=10, day=26, hour=1, min=0, sec=2700}"),
            ("pre-epoch fold negative seconds", "{year=1969, month=10, day=26, hour=2, min=0, sec=-1800}"),
        ]
    default: deferredSeconds = []
    }
    result += deferredSeconds.map { LuaTimeSample(name: $0.0, fields: $0.1, hint: -1, automaticTransition: true) }
    if zone == "UTC" {
        // struct tm still has an Int32 year on a 64-bit time_t host. These remain inside its representable range.
        for year in [1900, 2038, 9999, 2_000_000_000] {
            result.append(LuaTimeSample(name: "year \(year), isdst=absent",
                                        fields: "{year=\(year), month=1, day=1, hour=0, min=0, sec=0}",
                                        hint: -1, automaticTransition: true))
        }
    }
    // Native mktime rejects an initial civil year before 1900. Normalizing excess seconds can bring a rejected
    // year into range, while seconds deferred from 1900 can reach 1899. Preserve those boundaries, not a blanket
    // rule that every pre-1900 result is invalid.
    let early: [(String, String)]
    switch zone {
    case "America/New_York":
        early = [
            ("1883 before standard fold", "{year=1883, month=11, day=18, hour=11, min=59, sec=59}"),
            ("1883 standard fold start", "{year=1883, month=11, day=18, hour=12, min=0, sec=0}"),
            ("1883 standard fold middle", "{year=1883, month=11, day=18, hour=12, min=2, sec=0}"),
            ("1883 standard fold end", "{year=1883, month=11, day=18, hour=12, min=3, sec=58}"),
            ("1883 excess seconds", "{year=1883, month=11, day=18, hour=12, min=0, sec=2700}"),
            ("1883 negative seconds", "{year=1883, month=11, day=18, hour=12, min=30, sec=-1800}"),
            // Accepting this rejected anchor would retain LMT's offset and put the final 1902 result 238s early.
            ("1883 excess crosses 1900", "{year=1883, month=11, day=18, hour=12, min=0, sec=600000000}"),
        ]
    case "UTC":
        early = [
            ("1899 canonical last second", "{year=1899, month=12, day=31, hour=23, min=59, sec=59}"),
            ("1900 negative second crosses 1899", "{year=1900, month=1, day=1, hour=0, min=0, sec=-1}"),
            ("1899 excess crosses 1900", "{year=1899, month=12, day=31, hour=23, min=59, sec=120}"),
            ("1899 negative seconds", "{year=1899, month=1, day=1, hour=0, min=0, sec=-1800}"),
            ("1840 canonical", "{year=1840, month=1, day=1, hour=0, min=0, sec=0}"),
            ("1840 negative seconds", "{year=1840, month=1, day=1, hour=0, min=0, sec=-1800}"),
            ("1840 excess crosses 1900", "{year=1840, month=1, day=1, hour=0, min=0, sec=2000000000}"),
        ]
    default: early = []
    }
    result += early.map { LuaTimeSample(name: $0.0, fields: $0.1, hint: -1, automaticTransition: true) }
    return result
}

private func luaTimeResults(zone name: String, fixed: Bool, automatic: Bool = false) throws -> [String: String] {
    guard let zone = TimeZone(identifier: name),
          let state = LuaState(memoryLimit: 8 << 20, instructionLimit: 1_000_000, secondsLimit: 2) else {
        throw NSError(domain: "LuaTimeSourceTests", code: 1)
    }
    if fixed {
        state.useTimeSource(clock: .fixed(Date(timeIntervalSince1970: luaTimeEpoch), timeZone: zone),
                            random: SkinRandom(seed: 7))
    }
    var result: [String: String] = [:]
    for sample in automatic ? luaAutomaticTimeSamples(name) : luaTimeSamples(name) {
        // Historical %z uses the native process's current offset for some zones. This matrix checks mktime's
        // epoch choice and its round-tripped civil fields/isdst; the existing explicit-hint cases still check %z.
        guard case .ok(let values) = state.evaluate(sample.expression(includingOffset: !automatic)),
              let text = values.first?.luaText else {
            throw NSError(domain: "LuaTimeSourceTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Lua did not return a result for \(sample.name)"])
        }
        result[sample.name] = text
    }
    return result
}

/// A private mode of the test executable, before TestRunner starts: the reference has its own process time zone.
/// `native-auto` and `fixed-auto` emit the broader automatic-transition matrix, without changing the explicit-hint
/// comparison's cases. Both matrices can also be saved by external diagnostics.
func runLuaTimeReferenceIfRequested() -> Int32? {
    let args = CommandLine.arguments
    guard args.dropFirst().first == "--lua-time-reference" else { return nil }
    guard args.count == 4, ["native", "fixed", "native-auto", "fixed-auto"].contains(args[2]),
          ProcessInfo.processInfo.environment["TZ"] == args[3] else { return 2 }
    tzset()
    do {
        let result = try luaTimeResults(zone: args[3], fixed: args[2].hasPrefix("fixed"),
                                        automatic: args[2].hasSuffix("-auto"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output = try encoder.encode(result)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([10]))
        return 0
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 1
    }
}

private func compareLuaTimeSources(_ t: TestRunner, zones: [String], automatic: Bool) throws {
    let originalTZ = ProcessInfo.processInfo.environment["TZ"]
    for zone in zones {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--lua-time-reference", automatic ? "native-auto" : "native", zone]
        var environment = ProcessInfo.processInfo.environment
        environment["TZ"] = zone
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        t.equal(child.terminationStatus, 0, "\(zone): the native Lua reference completes in its own process")
        let reference = try JSONDecoder().decode([String: String].self, from: bytes)
        let actual = try luaTimeResults(zone: zone, fixed: true, automatic: automatic)
        t.equal(Set(actual.keys), Set(reference.keys))
        let samples = automatic ? luaAutomaticTimeSamples(zone) : luaTimeSamples(zone)
        for sample in samples where automatic || !sample.automaticTransition {
            t.equal(actual[sample.name], reference[sample.name], "\(zone): \(sample.name)")
        }
    }
    t.equal(ProcessInfo.processInfo.environment["TZ"], originalTZ, "no process-wide zone change in the test host")
}

func runLuaTimeSourceTests(_ t: TestRunner) {
    t.suite("Lua: fixed time source honors explicit daylight hints") {
        try compareLuaTimeSources(t, zones: ["Europe/Oslo", "Australia/Lord_Howe", "UTC"], automatic: false)
    }
    t.suite("Lua: fixed time source resolves automatic transitions like native Lua") {
        try compareLuaTimeSources(t, zones: ["Europe/Oslo", "Australia/Lord_Howe", "Europe/Dublin",
                                           "Africa/Casablanca", "America/New_York", "Europe/Moscow",
                                           "Antarctica/Troll", "UTC"], automatic: true)
    }
}
