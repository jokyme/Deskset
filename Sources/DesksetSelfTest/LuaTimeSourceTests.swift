import Darwin
import Foundation
@testable import DesksetCore

private struct LuaTimeSample {
    let name: String
    let fields: String
    let hint: Int
    let automaticTransition: Bool

    var expression: String {
        let flag = hint < 0 ? "nil" : (hint == 0 ? "false" : "true")
        return """
        (function()
          local fields = \(fields)
          fields.isdst = \(flag)
          local time = os.time(fields)
          if time == nil then return 'nil' end
          return string.format('%.0f', time) .. '|' .. os.date('%Y-%m-%d %H:%M:%S %z', time)
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

private func luaTimeResults(zone name: String, fixed: Bool) throws -> [String: String] {
    guard let zone = TimeZone(identifier: name),
          let state = LuaState(memoryLimit: 8 << 20, instructionLimit: 1_000_000, secondsLimit: 2) else {
        throw NSError(domain: "LuaTimeSourceTests", code: 1)
    }
    if fixed {
        state.useTimeSource(clock: .fixed(Date(timeIntervalSince1970: luaTimeEpoch), timeZone: zone),
                            random: SkinRandom(seed: 7))
    }
    var result: [String: String] = [:]
    for sample in luaTimeSamples(name) {
        guard case .ok(let values) = state.evaluate(sample.expression), let text = values.first?.luaText else {
            throw NSError(domain: "LuaTimeSourceTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Lua did not return a result for \(sample.name)"])
        }
        result[sample.name] = text
    }
    return result
}

/// A private mode of the test executable, before TestRunner starts: the reference has its own process time zone.
/// `fixed` also emits the automatic transition cases for a separate diagnostic comparison. The explicit-hint
/// regression below does not claim that both implementations choose the same occurrence of an ambiguous time.
func runLuaTimeReferenceIfRequested() -> Int32? {
    let args = CommandLine.arguments
    guard args.dropFirst().first == "--lua-time-reference" else { return nil }
    guard args.count == 4, ["native", "fixed"].contains(args[2]),
          ProcessInfo.processInfo.environment["TZ"] == args[3] else { return 2 }
    tzset()
    do {
        let result = try luaTimeResults(zone: args[3], fixed: args[2] == "fixed")
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

func runLuaTimeSourceTests(_ t: TestRunner) {
    t.suite("Lua: fixed time source honors explicit daylight hints") {
        let originalTZ = ProcessInfo.processInfo.environment["TZ"]
        for zone in ["Europe/Oslo", "Australia/Lord_Howe", "UTC"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--lua-time-reference", "native", zone]
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
            let actual = try luaTimeResults(zone: zone, fixed: true)
            t.equal(Set(actual.keys), Set(reference.keys))
            for sample in luaTimeSamples(zone) where !sample.automaticTransition {
                t.equal(actual[sample.name], reference[sample.name], "\(zone): \(sample.name)")
            }
        }
        t.equal(ProcessInfo.processInfo.environment["TZ"], originalTZ, "no process-wide zone change in the test host")
    }
}
