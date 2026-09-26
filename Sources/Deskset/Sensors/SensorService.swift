import DesksetCore
import Foundation

/// The Mac's hardware sensors for every skin (`SystemMonitor` hands them on as `HardwareSensorSource`).
///
/// Reads only what skins ask for, in the background, and answers from the last reading:
/// - a catalog key belongs to one or two groups (`SensorGroup`); asking for it marks them wanted;
/// - when a wanted group's reading is older than `maxAge` (0.9 s), the next question starts one refresh on the
///   service's serial queue, which reads every wanted group at once and publishes the result; the answer to that
///   question is still the previous reading (nil before the first: `sensorPending` is true then);
/// - a group nobody asked for during `idleAfter` (30 s) is no longer read, its reading is dropped and the hardware lets
///   go of it (the IOReport subscription). Nothing runs while no skin asks: there is no timer.
///
/// Any thread: the state is behind one lock (`Guarded`), held only to look up or store; the hardware is used on the
/// queue alone. A sensor that loses its reading for a moment (a CPU cluster powered down between two samples) keeps
/// its last value for up to `holdFor` (10 s).
final class SensorService {
    static let shared = SensorService(hardware: LiveSensorHardware())

    static let maxAge: TimeInterval = 0.9
    static let idleAfter: TimeInterval = 30
    static let holdFor: TimeInterval = 10

    private struct Reading {
        var group: SensorGroupReading
        var time: TimeInterval
        /// When each value was read (for holding values across a missing reading).
        var valueTimes: [String: TimeInterval]
    }

    private struct State {
        var asked: [SensorGroup: TimeInterval] = [:]
        var readings: [SensorGroup: Reading] = [:]
        var refreshing = false
        var refreshes = 0
        var list: [SensorInfo] = []
        var infos: [String: SensorInfo] = [:]
        var waiters: [([SensorInfo]) -> Void] = []
    }

    private let state = Guarded(State())
    private let queue = DispatchQueue(label: "app.deskset.sensors", qos: .utility)
    private let hardware: SensorHardware
    private let clock: () -> TimeInterval

    init(hardware: SensorHardware, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.hardware = hardware
        self.clock = clock
    }

    // MARK: Questions (any thread)

    /// The last reading of `key` (canonical), nil when there is none; starts a refresh when it is stale.
    func value(_ key: String) -> Double? {
        let groups = SensorGroup.groups(for: key)
        guard !groups.isEmpty else { return nil }
        let now = clock()
        let (value, start) = state.access { s -> (Double?, Bool) in
            for g in groups { s.asked[g] = now }
            var value: Double?
            for g in groups where value == nil { value = s.readings[g]?.group.values[key] }
            return (value, SensorService.claimRefresh(&s, groups: groups, now: now))
        }
        if start { queue.async { self.refresh() } }
        return value
    }

    /// True while a group that can answer `key` has not been read yet.
    func isPending(_ key: String) -> Bool {
        let groups = SensorGroup.groups(for: key)
        guard !groups.isEmpty else { return false }
        return state.access { s in groups.contains { s.readings[$0] == nil } }
    }

    /// The sensors known so far, in catalog order.
    func list() -> [SensorInfo] {
        state.access { $0.list }
    }

    func info(_ key: String) -> SensorInfo? {
        state.access { $0.infos[key] }
    }

    /// The nominal junction limit, once the Mac has shown it has a CPU temperature.
    func tjMax() -> Double? {
        _ = value(SensorKeys.cpu)
        return info(SensorKeys.cpu) == nil ? nil : hardware.tjMax
    }

    /// Asks for every group and calls `done` (on the service's queue) with the list once all of them were read.
    func discover(_ done: @escaping ([SensorInfo]) -> Void) {
        let now = clock()
        let start = state.access { s -> Bool in
            for g in SensorGroup.allCases { s.asked[g] = now }
            s.waiters.append(done)
            guard !s.refreshing else { return false }
            s.refreshing = true
            return true
        }
        if start { queue.async { self.refresh() } }
    }

    /// Reads every group now and waits for it (the command line's report; never on a skin's thread).
    func readAll() -> [SensorInfo] {
        let now = clock()
        state.access { s in
            for g in SensorGroup.allCases { s.asked[g] = now }
        }
        queue.sync { refresh() }
        return list()
    }

    /// How many refreshes ran, and whether one is claimed or running (tests).
    var refreshCount: Int { state.access { $0.refreshes } }
    var isRefreshing: Bool { state.access { $0.refreshing } }

    /// Claims the refresh when one of `groups` is stale and none runs (with the lock held).
    private static func claimRefresh(_ s: inout State, groups: [SensorGroup], now: TimeInterval) -> Bool {
        guard !s.refreshing else { return false }
        let stale = groups.contains { g in s.readings[g].map { now - $0.time >= maxAge } ?? true }
        guard stale else { return false }
        s.refreshing = true
        return true
    }

    // MARK: Refresh (the queue)

    private func refresh() {
        let start = clock()
        // What skins asked for lately; everything while someone waits for the whole list.
        let wanted = state.access { s -> Set<SensorGroup> in
            s.waiters.isEmpty ? Set(s.asked.filter { start - $0.value < SensorService.idleAfter }.keys)
                : Set(SensorGroup.allCases)
        }
        let fresh = wanted.isEmpty ? [:] : hardware.read(wanted, now: start)
        let idle = Set(SensorGroup.allCases).subtracting(wanted)
        hardware.release(idle)
        let (done, list, again) = state.access { s -> ([([SensorInfo]) -> Void], [SensorInfo], Bool) in
            for group in wanted {
                s.readings[group] = SensorService.merge(previous: s.readings[group], fresh[group] ?? SensorGroupReading(),
                                                        now: start)
            }
            for group in idle where start - (s.asked[group] ?? -.infinity) >= SensorService.idleAfter {
                s.readings[group] = nil
                s.asked[group] = nil
            }
            s.refreshes += 1
            SensorService.rebuildList(&s)
            // Waiters asked for every group: done once every group has been read.
            let complete = SensorGroup.allCases.allSatisfy { s.readings[$0] != nil }
            let done = complete ? s.waiters : []
            if complete { s.waiters = [] }
            // A group asked for while this refresh ran, and never read: read it now rather than at the next question.
            let missed = s.asked.keys.contains { s.readings[$0] == nil }
            let again = !s.waiters.isEmpty || missed
            s.refreshing = again
            return (done, s.list, again)
        }
        for waiter in done { waiter(list) }
        if again { queue.async { self.refresh() } }
    }

    /// A group's new reading: values missing now but read less than `holdFor` ago keep their last value.
    private static func merge(previous: Reading?, _ fresh: SensorGroupReading, now: TimeInterval) -> Reading {
        var group = fresh
        var times: [String: TimeInterval] = [:]
        for key in fresh.values.keys { times[key] = now }
        if let previous {
            for info in fresh.infos where fresh.values[info.key] == nil {
                guard let old = previous.group.values[info.key], let at = previous.valueTimes[info.key],
                      now - at < holdFor else { continue }
                group.values[info.key] = old
                times[info.key] = at
            }
        }
        return Reading(group: group, time: now, valueTimes: times)
    }

    /// The catalog from every group's reading: each key once (the first group that lists it), in catalog order.
    private static func rebuildList(_ s: inout State) {
        var infos: [String: SensorInfo] = [:]
        var list: [SensorInfo] = []
        for group in SensorGroup.allCases {
            for info in s.readings[group]?.group.infos ?? [] where infos[info.key] == nil {
                infos[info.key] = info
                list.append(info)
            }
        }
        s.list = list.sorted { SensorGroupReading.order($0.key) < SensorGroupReading.order($1.key) }
        s.infos = infos
    }
}

// MARK: - SystemMonitor

extension SystemMonitor: HardwareSensorSource {
    func sensorList() -> [SensorInfo] { sensors.list() }
    func sensorInfo(_ key: String) -> SensorInfo? { sensors.info(key) }
    func sensorValue(_ key: String) -> Double? { sensors.value(key) }
    func sensorPending(_ key: String) -> Bool { sensors.isPending(key) }
    func discoverSensors(_ done: @escaping ([SensorInfo]) -> Void) { sensors.discover(done) }
    func cpuTjMax() -> Double? { sensors.tjMax() }
}
