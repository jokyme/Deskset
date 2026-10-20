import Foundation
@testable import DesksetCore

/// Deliberately relies on the protocol's defaults for accumulated counters and resetting.
private final class RawNetworkSystem: SystemDataSource {
    var raw = NetworkCounters(received: 900, sent: 300)
    var requested: [String?] = []
    var processorCount: Int { 1 }
    func cpuUsage(processor: Int) -> Double { 0 }
    func memoryStatus() -> MemoryStatus { MemoryStatus() }
    func networkInterfaces() -> [String] { ["en0"] }
    func networkCounters(interface: String?) -> NetworkCounters { requested.append(interface); return raw }
    func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
    func uptime() -> TimeInterval { 0 }
    func battery() -> BatteryStatus? { nil }
    func isProcessRunning(_ name: String) -> Bool { false }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
}

private final class StatisticsNetworkSystem: FakeSystem {
    var raw: [String: NetworkCounters] = ["en0": NetworkCounters(received: 1000, sent: 500),
                                          "en1": NetworkCounters(received: 100, sent: 50)]
    var accumulated: [String: NetworkCounters] = ["en0": NetworkCounters(received: 300, sent: 40),
                                                  "en1": NetworkCounters(received: 20, sent: 5)]
    var rawRequests: [String?] = []
    var accumulatedRequests: [String?] = []
    var resets = 0
    var onAccumulated: (() -> Void)?
    var onReset: (() -> Void)?

    override func networkInterfaces() -> [String] { raw.keys.sorted() }

    override func networkCounters(interface: String?) -> NetworkCounters {
        rawRequests.append(interface)
        return counters(raw, interface: interface)
    }

    override func cumulativeNetworkCounters(interface: String?) -> NetworkCounters {
        accumulatedRequests.append(interface)
        onAccumulated?()
        return counters(accumulated, interface: interface)
    }

    override func resetNetworkStatistics() {
        resets += 1
        accumulated = accumulated.mapValues { _ in NetworkCounters() }
        onReset?()
    }

    private func counters(_ values: [String: NetworkCounters], interface: String?) -> NetworkCounters {
        if let interface { return values[interface] ?? NetworkCounters() }
        return values.values.reduce(NetworkCounters()) {
            NetworkCounters(received: $0.received &+ $1.received, sent: $0.sent &+ $1.sent)
        }
    }
}

private func networkFixture(_ definitions: [(String, String, String, Bool, Bool)]) -> String {
    definitions.map { name, type, interface, cumulative, bits in
        "[\(name)]\nMeasure=\(type)\nInterface=\(interface)\nCumulative=\(cumulative ? 1 : 0)\nUseBits=\(bits ? 1 : 0)\n"
    }.joined(separator: "\n")
}

private func networkFrames() -> SkinInputData {
    var first = SkinInputData.SystemFrame(), second = SkinInputData.SystemFrame()
    first.network = ["en0": NetworkCounters(received: 10, sent: 2), "en1": NetworkCounters(received: 5, sent: 1)]
    second.network = ["en0": NetworkCounters(received: 30, sent: 8), "en1": NetworkCounters(received: 6, sent: 4)]
    var data = SkinInputData()
    data.system = [first, second]
    return data
}

func runNetworkStatisticsTests(_ t: TestRunner) {
    t.suite("Network statistics: default data sources remain compatible") {
        let raw = RawNetworkSystem()
        let system: SystemDataSource = raw
        t.equal(system.cumulativeNetworkCounters(interface: "en0"), raw.raw)
        t.equal(system.cumulativeNetworkCounters(interface: nil), raw.raw)
        t.equal(raw.requested, ["en0", nil], "default cumulative reads use the same raw interface argument")
        let before = raw.raw
        system.resetNetworkStatistics()
        t.equal(raw.raw, before, "the default reset is a no-op")
        t.equal(raw.requested.count, 2)
        let (skin, _) = try makeSkin(t, "[In]\nMeasure=NetIn\nCumulative=1\n", system: system)
        defer { skin.close() }
        skin.update()
        t.close(skin.measure(named: "In")?.value ?? -1, 900)
        let fake: SystemDataSource = FakeSystem()
        t.equal(fake.cumulativeNetworkCounters(interface: nil), NetworkCounters(received: 1000, sent: 500))
        fake.resetNetworkStatistics()
        t.equal(fake.networkCounters(interface: nil), NetworkCounters(received: 1000, sent: 500))
    }

    t.suite("Network statistics: existential dispatch reaches overridden provider methods") {
        let concrete = StatisticsNetworkSystem()
        let system: SystemDataSource = concrete
        t.equal(system.networkCounters(interface: "en0"), NetworkCounters(received: 1000, sent: 500))
        t.equal(system.cumulativeNetworkCounters(interface: "en0"), NetworkCounters(received: 300, sent: 40))
        t.equal(concrete.accumulatedRequests, ["en0"], "the inherited conformance dispatches to the override")
        system.resetNetworkStatistics()
        t.equal(concrete.resets, 1)
        t.equal(system.cumulativeNetworkCounters(interface: nil), NetworkCounters())
        t.equal(system.networkCounters(interface: nil), NetworkCounters(received: 1100, sent: 550))
    }

    t.suite("Network statistics: cumulative Net directions interfaces bits and reset") {
        let system = StatisticsNetworkSystem()
        let definitions = [
            ("StoredIn", "NetIn", "en0", true, false),
            ("StoredOut", "NetOut", "en0", true, false),
            ("StoredTotal", "NetTotal", "en0", true, false),
            ("StoredAll", "NetTotal", "0", true, false),
            ("StoredSecond", "NetTotal", "2", true, false),
            ("StoredBest", "NetIn", "Best", true, false),
            ("BitsIn", "NetIn", "en0", true, true),
            ("BitsOut", "NetOut", "en0", true, true),
            ("BitsTotal", "NetTotal", "en0", true, true),
        ]
        let (skin, _) = try makeSkin(t, networkFixture(definitions), system: system)
        defer { skin.close() }
        skin.update()
        for (name, expected) in [("StoredIn", 300.0), ("StoredOut", 40), ("StoredTotal", 340),
                                 ("StoredAll", 365), ("StoredSecond", 25), ("StoredBest", 300),
                                 ("BitsIn", 2400), ("BitsOut", 320), ("BitsTotal", 2720)] {
            t.close(skin.measure(named: name)?.value ?? -1, expected, name)
        }
        t.equal(system.accumulatedRequests, ["en0", "en0", "en0", nil, "en1", "en0", "en0", "en0", "en0"])
        t.check(system.rawRequests.isEmpty, "cumulative measures never use a raw rate sample")
        let rawBeforeReset = system.raw
        skin.system.resetNetworkStatistics()
        skin.update()
        t.equal(system.resets, 1)
        t.equal(system.raw, rawBeforeReset)
        for (name, _, _, _, _) in definitions { t.close(skin.measure(named: name)?.value ?? -1, 0, name) }
        system.accumulated["en0"] = NetworkCounters(received: 8, sent: 3)
        system.accumulated["en1"] = NetworkCounters(received: 1, sent: 1)
        skin.update()
        t.close(skin.measure(named: "StoredIn")?.value ?? -1, 8)
        t.close(skin.measure(named: "StoredOut")?.value ?? -1, 3)
        t.close(skin.measure(named: "StoredAll")?.value ?? -1, 13)
        t.close(skin.measure(named: "BitsTotal")?.value ?? -1, 88)
        t.check(system.rawRequests.isEmpty)
    }

    t.suite("Network statistics: resetting cumulative totals leaves ordinary rates intact") {
        let system = StatisticsNetworkSystem()
        let (skin, _) = try makeSkin(t, networkFixture([
            ("RateIn", "NetIn", "en0", false, false),
            ("RateOut", "NetOut", "en0", false, false),
            ("RateTotal", "NetTotal", "en0", false, false),
            ("RateBits", "NetTotal", "en0", false, true),
            ("Stored", "NetTotal", "en0", true, false),
        ]), system: system)
        defer { skin.close() }
        var now = 100.0
        skin.clock = { now }
        skin.update()
        for name in ["RateIn", "RateOut", "RateTotal", "RateBits"] { t.close(skin.measure(named: name)?.value ?? -1, 0) }
        system.raw["en0"] = NetworkCounters(received: 1200, sent: 550)
        now += 2
        skin.update()
        for (name, expected) in [("RateIn", 100.0), ("RateOut", 25), ("RateTotal", 125), ("RateBits", 1000)] {
            t.close(skin.measure(named: name)?.value ?? -1, expected, name)
        }
        skin.system.resetNetworkStatistics()
        system.raw["en0"] = NetworkCounters(received: 1300, sent: 630)
        now += 2
        skin.update()
        for (name, expected) in [("RateIn", 50.0), ("RateOut", 40), ("RateTotal", 90), ("RateBits", 720), ("Stored", 0)] {
            t.close(skin.measure(named: name)?.value ?? -1, expected, name)
        }
        t.equal(system.rawRequests.count, 12)
        t.equal(system.accumulatedRequests, ["en0", "en0", "en0"])
        system.raw["en0"] = NetworkCounters()
        now += 1
        skin.update()
        t.close(skin.measure(named: "RateTotal")?.value ?? -1, 0, "a backwards raw counter retains the existing zero-rate fallback")
    }

    t.suite("Network statistics: scripted frames isolate cumulative reads and resets") {
        let base = StatisticsNetworkSystem()
        let scripted = ScriptedSystemData(base: base, data: networkFrames())
        let system: SystemDataSource = scripted
        t.equal(system.cumulativeNetworkCounters(interface: nil), NetworkCounters(received: 15, sent: 3))
        t.equal(system.cumulativeNetworkCounters(interface: "en1"), NetworkCounters(received: 5, sent: 1))
        t.equal(system.cumulativeNetworkCounters(interface: "missing"), NetworkCounters())
        system.resetNetworkStatistics()
        t.equal(system.cumulativeNetworkCounters(interface: nil), NetworkCounters(received: 15, sent: 3),
                "reset never rewrites supplied frame data")
        scripted.advance()
        t.equal(system.cumulativeNetworkCounters(interface: nil), NetworkCounters(received: 36, sent: 12))
        let (skin, _) = try makeSkin(t, networkFixture([("In", "NetIn", "en0", true, true)]), system: system)
        defer { skin.close() }
        skin.update()
        t.close(skin.measure(named: "In")?.value ?? -1, 240)
        scripted.apply(SkinInputData())
        system.resetNetworkStatistics()
        t.equal(system.cumulativeNetworkCounters(interface: "en0"), NetworkCounters(received: 30, sent: 8))
        var missingNetwork = SkinInputData()
        missingNetwork.system = [SkinInputData.SystemFrame()]
        scripted.apply(missingNetwork)
        system.resetNetworkStatistics()
        t.equal(system.cumulativeNetworkCounters(interface: nil), NetworkCounters(), "an omitted network in a frame remains isolated")
        t.check(base.rawRequests.isEmpty)
        t.check(base.accumulatedRequests.isEmpty)
        t.equal(base.resets, 0)
    }

    t.suite("Network statistics: scripted sources without frames forward after releasing their lock") {
        let base = StatisticsNetworkSystem()
        let scripted = ScriptedSystemData(base: base, data: SkinInputData())
        let system: SystemDataSource = scripted
        base.onAccumulated = { scripted.apply(networkFrames()) }
        t.equal(system.cumulativeNetworkCounters(interface: "en0"), NetworkCounters(received: 300, sent: 40),
                "the no-frame snapshot forwards to the base even when its callback replaces the frame")
        t.equal(base.accumulatedRequests, ["en0"])
        t.equal(system.cumulativeNetworkCounters(interface: "en0"), NetworkCounters(received: 10, sent: 2))
        system.resetNetworkStatistics()
        t.equal(base.resets, 0)
        base.onAccumulated = nil
        var noFrames = SkinInputData()
        noFrames.system = []
        scripted.apply(noFrames)
        base.onReset = { _ = scripted.frameIndex }
        system.resetNetworkStatistics()
        t.equal(base.resets, 1, "the reset callback can reenter the scripted source")
        t.equal(system.cumulativeNetworkCounters(interface: nil), NetworkCounters())
        t.equal(system.networkCounters(interface: "en1"), NetworkCounters(received: 100, sent: 50))
        t.equal(base.accumulatedRequests, ["en0", nil])
        t.equal(base.rawRequests, ["en1"])
        base.onReset = nil
    }
}
