import Foundation
@testable import DesksetCore

// The seams for what a skin reads from outside (the runtime design, "same inputs on both sides"): with a clock and a
// seeded random source of its own, a skin gives the same results on every run and every Mac.

/// A host whose skins see a fixed locale (the names of time zones are in it).
private final class SeamHost: FakeHost {
    var locale = Locale(identifier: "en_US")

    override func environment(for skin: Skin) -> SkinEnvironment { SkinEnvironment(locale: locale) }
}

private var retainedSeamHosts: [SeamHost] = []

/// Like `makeSkin`, but the skin gets `clock` and `random` before it loads.
private func seamSkin(_ t: TestRunner, _ ini: String, files: [String: String] = [:], clock: SkinClock,
                      random: SkinRandom) throws -> Skin {
    let skins = t.temporaryDirectory("seams").appendingPathComponent("Skins")
    let dir = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try ini.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
    for (path, text) in files {
        let url = skins.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let host = SeamHost()
    retainedSeamHosts.append(host)  // Skin.host is weak.
    let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                    system: FakeSystem(), host: host)
    skin.skinClock = clock
    skin.random = random
    try skin.load()
    return skin
}

private func string(_ skin: Skin, _ measure: String) -> String { skin.measure(named: measure)?.stringValue ?? "<none>" }
private func value(_ skin: Skin, _ measure: String) -> Double { skin.measure(named: measure)?.value ?? .nan }

/// Spins the main run loop until `condition` holds (true) or `timeout` passes (false).
private func spinUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

/// 2026-12-31 23:59:58 UTC.
private let newYearsEve = Date(timeIntervalSince1970: 1_798_761_598)

private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

func runClockRandomSeamTests(_ t: TestRunner) {
    t.suite("Seams: clock and random: the live clock and random source are the system's") {
        let live = SkinClock.live
        t.check(live.isLive && live.nowIsLive && live.uptimeIsLive && live.timeZoneIsLive)
        t.check(abs(live.now().timeIntervalSinceNow) < 5)
        t.close(live.uptime(), ProcessInfo.processInfo.systemUptime, accuracy: 5)
        t.equal(live.timeZone().identifier, TimeZone.current.identifier)
        var partly = SkinClock.live
        partly.timeZone = { zone("UTC") }
        t.check(partly.nowIsLive && partly.uptimeIsLive && !partly.timeZoneIsLive, "only the part replaced")
        let random = SkinRandom.live()
        t.check(random.isLive)
        t.equal(random.seed, nil)
        t.check((1...6).contains(random.int(in: 1...6)))
        t.equal(Set(random.shuffled([1, 2, 3])), [1, 2, 3])
        t.equal(random.uuidString().count, 36)
        let skin = Skin(config: "A", fileURL: URL(fileURLWithPath: "/nowhere/A.ini"),
                        skinsDirectory: URL(fileURLWithPath: "/nowhere"), system: FakeSystem(), host: nil)
        t.check(skin.skinClock.isLive && skin.random.isLive, "a skin reads the system unless given a clock")
        skin.clock = { 42 }
        t.equal(skin.clock(), 42, "Skin.clock is the monotonic part of the skin's clock")
        t.equal(skin.skinClock.uptime(), 42)
        t.check(skin.skinClock.nowIsLive && !skin.skinClock.uptimeIsLive)
    }

    t.suite("Seams: clock and random: seeded streams are the same on every run") {
        let a = SkinRandom(seed: 7), b = SkinRandom(seed: 7), c = SkinRandom(seed: 8)
        let first = (0..<8).map { _ in a.next() }
        t.equal(first, (0..<8).map { _ in b.next() })
        t.check(first != (0..<8).map { _ in c.next() }, "another seed, other numbers")
        // xoshiro256** seeded by SplitMix64: the numbers are part of what a seed means (baselines keep them).
        t.equal(Array(first.prefix(3)), [0xB358_FAF7_4EF9_765A, 0x475C_3D96_4F48_2CD2, 0xD6F1_D349_952C_7996])
        // Streams of one seed do not depend on each other or on the order they are made in.
        let skinA = SkinRandom(seed: 7, stream: "Suite\\Clock"), skinB = SkinRandom(seed: 7, stream: "Suite\\Weather")
        t.check(skinA.next() != skinB.next())
        t.equal(SkinRandom(seed: 7, stream: "Suite\\Clock").next(), SkinRandom(seed: 7, stream: "Suite\\Clock").next())
        let ints = (0..<50).map { _ in SkinRandom(seed: 3).int(in: 1...6) }
        t.check(ints.allSatisfy { (1...6).contains($0) })
        let uuid = SkinRandom(seed: 7).uuidString()
        t.equal(uuid, SkinRandom(seed: 7).uuidString())
        t.equal(UUID(uuidString: uuid)?.uuidString, uuid, "a valid UUID")
        t.equal(Array(uuid)[14], "4", "version 4")
        // Lua's stream: separate from the skin's, and math.randomseed(n) starts it again from n.
        let lua = SkinRandom(seed: 7)
        let u1 = lua.luaUnit()
        t.check(u1 >= 0 && u1 < 1)
        t.equal(u1, SkinRandom(seed: 7).luaUnit())
        lua.luaSeed(42)
        let reseeded = lua.luaUnit()
        let other = SkinRandom(seed: 99)
        other.luaSeed(42)
        t.equal(other.luaUnit(), reseeded, "the same randomseed gives the same numbers in any skin")
    }

    t.suite("Seams: clock and random: Time measure") {
        func skin() throws -> Skin {
            try seamSkin(t, """
            [Rainmeter]
            [Local]
            Measure=Time
            [Text]
            Measure=Time
            Format=%Y-%m-%d %H:%M:%S %Z
            [Offset]
            Measure=Time
            TimeZone=-5
            DaylightSavingTime=0
            Format=%H:%M
            [Named]
            Measure=Time
            Format=%A %#d %B
            FormatLocale=Local
            """, clock: SkinClock.fixed(newYearsEve, timeZone: zone("Asia/Shanghai")), random: SkinRandom(seed: 1))
        }
        let s = try skin()
        s.update()
        t.equal(value(s, "Local"), 13_443_263_998, "the local wall time of the injected clock and zone")
        t.equal(string(s, "Local"), "07:59:58")
        t.equal(string(s, "Text"), "2027-01-01 07:59:58 China Standard Time", "%Z in the skin's locale")
        t.equal(string(s, "Offset"), "18:59")
        t.equal(string(s, "Named"), "Friday 1 January", "FormatLocale=Local is the skin's locale")
        let again = try skin()
        again.update()
        for name in ["Local", "Text", "Offset", "Named"] {
            t.equal(string(again, name), string(s, name), name)
            t.equal(value(again, name), value(s, name), name)
        }
        s.close()
        again.close()

        // Stepped: update i sees the start plus i intervals.
        let stepped = SteppedSkinClock(start: newYearsEve, timeZone: zone("UTC"))
        let st = try seamSkin(t, "[Rainmeter]\n[T]\nMeasure=Time\nFormat=%Y %H:%M:%S\n", clock: stepped.clock,
                              random: SkinRandom(seed: 1))
        st.update()
        t.equal(string(st, "T"), "2026 23:59:58")
        stepped.elapsed = 2
        st.update()
        t.equal(string(st, "T"), "2027 00:00:00")
        st.close()
    }

    t.suite("Seams: clock and random: TimeStamp codes and SysInfo read the skin's zone") {
        let s = try seamSkin(t, """
        [Rainmeter]
        [DST]
        Measure=Time
        TimeStamp=DSTNextStart
        [IsDST]
        Measure=SysInfo
        SysInfoType=TIMEZONE_ISDST
        [Bias]
        Measure=SysInfo
        SysInfoType=TIMEZONE_BIAS
        [Standard]
        Measure=SysInfo
        SysInfoType=TIMEZONE_STANDARD_NAME
        [Daylight]
        Measure=SysInfo
        SysInfoType=TIMEZONE_DAYLIGHT_NAME
        """, clock: SkinClock.fixed(newYearsEve, timeZone: zone("America/New_York")), random: SkinRandom(seed: 1))
        s.update()
        t.equal(value(s, "DST"), 13_449_463_200, "the next start of daylight saving time in New York: 14 March 2027")
        t.equal(value(s, "IsDST"), 0)
        t.equal(value(s, "Bias"), 300)
        t.equal(string(s, "Standard"), "Eastern Standard Time")
        t.equal(string(s, "Daylight"), "Eastern Daylight Time")
        s.close()
    }

    t.suite("Seams: clock and random: Calc Random and UniqueRandom") {
        func run(seed: UInt64) throws -> (random: [Double], unique: [Double]) {
            let s = try seamSkin(t, """
            [Rainmeter]
            [Random]
            Measure=Calc
            Formula=Random
            LowBound=1
            HighBound=1000
            UpdateRandom=1
            [Unique]
            Measure=Calc
            Formula=Random
            LowBound=1
            HighBound=5
            UpdateRandom=1
            UniqueRandom=1
            """, clock: SkinClock.fixed(newYearsEve, timeZone: zone("UTC")), random: SkinRandom(seed: seed))
            var random: [Double] = [], unique: [Double] = []
            for _ in 0..<5 {
                s.update()
                random.append(value(s, "Random"))
                unique.append(value(s, "Unique"))
            }
            s.close()
            return (random, unique)
        }
        let first = try run(seed: 7)
        // The measures draw in file order, one number each per update.
        let r = SkinRandom(seed: 7)
        var expectedRandom: [Double] = [], expectedUnique: [Double] = []
        var pool: [Double] = []
        for _ in 0..<5 {
            expectedRandom.append(Double(r.int(in: 1...1000)))
            if pool.isEmpty { pool = r.shuffled(Array(stride(from: 1.0, through: 5.0, by: 1))) }
            expectedUnique.append(pool.removeLast())
        }
        t.equal(first.random, expectedRandom)
        t.equal(first.unique, expectedUnique)
        t.equal(Set(first.unique), [1, 2, 3, 4, 5], "no value twice before all were used")
        let second = try run(seed: 7)
        t.equal(second.random, first.random, "the same seed, the same numbers")
        t.equal(second.unique, first.unique)
        t.check(try run(seed: 8).random != first.random, "another seed, other numbers")
    }

    t.suite("Seams: clock and random: QuotePlugin") {
        let items = ["alpha", "beta", "gamma", "delta", "epsilon"]
        func run(seed: UInt64) throws -> [String] {
            let s = try seamSkin(t, """
            [Rainmeter]
            [Quote]
            Measure=Plugin
            Plugin=QuotePlugin
            PathName=quotes.txt
            """, files: ["Root/Sub/quotes.txt": items.joined(separator: "\n")],
                                 clock: SkinClock.fixed(newYearsEve, timeZone: zone("UTC")), random: SkinRandom(seed: seed))
            guard let quote = s.measure(named: "Quote") as? QuoteMeasure else { return [] }
            s.update()
            guard spinUntil(10, { !quote.isLoading && quote.itemCount == items.count }) else { return ["<not loaded>"] }
            var picks = [quote.stringValue]
            for _ in 0..<4 {
                s.update()
                picks.append(quote.stringValue)
            }
            s.close()
            return picks
        }
        // What QuotePlugin picks: a random item, drawn again once when it is the one shown.
        let r = SkinRandom(seed: 7)
        var expected: [String] = []
        var current: String?
        for _ in 0..<5 {
            var choice = items[r.int(in: 0..<items.count)]
            if choice == current { choice = items[r.int(in: 0..<items.count)] }
            if choice == current, let other = items.first(where: { $0 != current }) { choice = other }
            current = choice
            expected.append(choice)
        }
        let first = try run(seed: 7)
        t.equal(first, expected)
        t.equal(try run(seed: 7), first, "the same seed, the same quotes")
    }

    t.suite("Seams: clock and random: MacSun reads the skin's clock") {
        var env = WeatherEnvironment.offline
        env.placesTable = WeatherFixtures.placesFixture
        env.waitsForLookups = true
        env.uses24HourClock = { true }
        WeatherService.install(env)
        let when = Date(timeIntervalSince1970: 1_782_907_200)  // 2026-07-01 12:00 UTC
        func run() throws -> [Double] {
            let s = try seamSkin(t, """
            [Rainmeter]
            [Sun]
            Measure=Plugin
            Plugin=MacSun
            Location=59.91,10.75
            Type=SunElevation
            [Moon]
            Measure=Plugin
            Plugin=MacSun
            Type=MoonPhase
            [Zone]
            Measure=Plugin
            Plugin=MacSun
            Parent=Sun
            TimeZone=Local
            Type=TimeZone
            """, clock: SkinClock.fixed(when, timeZone: zone("Asia/Tokyo")), random: SkinRandom(seed: 1))
            s.update()
            defer { s.close() }
            return [value(s, "Sun"), value(s, "Moon"), value(s, "Zone")]
        }
        let first = try run()
        t.close(first[0], SolarCalculator.position(at: when, latitude: 59.91, longitude: 10.75).elevation,
                accuracy: 1e-9, "the sun where the skin's clock says it is")
        t.close(first[1], MoonPhase.phase(at: when), accuracy: 1e-12)
        t.equal(first[2], 9, "TimeZone=Local is the skin's zone")
        t.equal(try run(), first)
        WeatherService.install(.offline)
    }

    t.suite("Seams: clock and random: Lua os.date, os.time, os.clock and math.random") {
        LuaSupport.register()
        let script = """
        function Update()
          local parts = {
            os.date('%Y-%m-%d %H:%M:%S %z'),
            tostring(os.time()),
            tostring(os.clock()),
            tostring(os.time({ year = 2027, month = 1, day = 1, hour = 0 })),
            os.date('!%H:%M', 0),
            os.date('%#d/%#m'),
            tostring(os.date('*t').hour),
            tostring(math.random()),
            tostring(math.random(100)),
            tostring(math.random(5, 10)),
          }
          math.randomseed(42)
          parts[#parts + 1] = tostring(math.random())
          return table.concat(parts, '|')
        end
        """
        func run(seed: UInt64) throws -> String {
            let s = try seamSkin(t, """
            [Rainmeter]
            [Lua]
            Measure=Script
            ScriptFile=seams.lua
            """, files: ["Root/Sub/seams.lua": script],
                                 clock: SkinClock.fixed(newYearsEve, timeZone: zone("Asia/Shanghai"), uptime: 1234.5),
                                 random: SkinRandom(seed: seed))
            s.update()
            defer { s.close() }
            return string(s, "Lua")
        }
        let r = SkinRandom(seed: 7)
        let u1 = r.luaUnit(), u2 = r.luaUnit(), u3 = r.luaUnit()
        r.luaSeed(42)
        let u4 = r.luaUnit()
        let expected = ["2027-01-01 07:59:58 +0800", "1798761598", "1234.5", "1798732800", "00:00", "1/1", "7",
                        LuaState.format(u1), LuaState.format(floor(u2 * 100) + 1), LuaState.format(floor(u3 * 6) + 5),
                        LuaState.format(u4)].joined(separator: "|")
        let first = try run(seed: 7)
        t.equal(first, expected)
        t.equal(try run(seed: 7), first, "the same seed, the same results")
        t.check(try run(seed: 8) != first, "another seed, other numbers")
    }

    t.suite("Seams: clock and random: Lua os.tmpname takes its name from the skin's random numbers") {
        LuaSupport.register()
        let script = """
        function Update()
          local name = os.tmpname()
          local f = io.open(name, 'r')
          local made = f ~= nil
          if f then f:close() end
          os.remove(name)
          return name .. '|' .. tostring(made)
        end
        """
        func run(seed: UInt64) throws -> String {
            let s = try seamSkin(t, """
            [Rainmeter]
            [Lua]
            Measure=Script
            ScriptFile=tmp.lua
            """, files: ["Root/Sub/tmp.lua": script], clock: SkinClock.fixed(newYearsEve, timeZone: zone("UTC")),
                                 random: SkinRandom(seed: seed))
            s.update()
            defer { s.close() }
            return string(s, "Lua")
        }
        let first = try run(seed: 7)
        let parts = first.split(separator: "|").map(String.init)
        t.equal(parts.count, 2)
        let name = parts.first ?? ""
        t.check(name.hasPrefix("/tmp/lua_") && name.count == 15, "a name like the C library's: \(name)")
        t.equal(parts.last, "true", "the file was made")
        t.check(!FileManager.default.fileExists(atPath: name), "and removed by the script")
        t.equal(try run(seed: 7), first, "the same seed, the same name")
        t.check(try run(seed: 8) != first, "another seed, another name")
    }

    t.suite("Seams: clock and random: Lua keeps the C library when the skin's clock is the system's") {
        LuaSupport.register()
        let s = try seamSkin(t, """
        [Rainmeter]
        [Lua]
        Measure=Script
        ScriptFile=live.lua
        """, files: ["Root/Sub/live.lua": "function Update() return os.time() .. '|' .. os.date('%z') end"],
                             clock: .live, random: .live())
        s.update()
        let parts = string(s, "Lua").split(separator: "|").map(String.init)
        t.equal(parts.count, 2)
        t.check(abs((Double(parts.first ?? "") ?? 0) - Date().timeIntervalSince1970) < 5, "time()")
        let offset = TimeZone.current.secondsFromGMT()
        let sign = offset < 0 ? "-" : "+"
        t.equal(parts.last, String(format: "%@%02d%02d", sign, abs(offset) / 3600, abs(offset) % 3600 / 60),
                "the process time zone")
        s.close()
    }
}
