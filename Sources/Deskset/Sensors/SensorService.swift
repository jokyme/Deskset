import DesksetCore
import Foundation

/// The Mac's hardware sensors for every skin (`SystemMonitor` hands them on as `HardwareSensorSource`).
///
/// Reads only what skins ask for, in the background, and answers from the last reading:
/// - a catalog key belongs to one or two groups (`SensorGroup`); asking for it while a group's reading is older than
///   `maxAge` (0.9 s), or missing, marks the group wanted and starts one refresh on the service's serial queue, which
///   reads the wanted groups at once and publishes the result; the answer to that question is still the previous
///   reading (nil before the first: `sensorPending` is true then). So each group is read at the pace of its most
///   frequent asker, at most about once a second, and not at all while nobody asks;
/// - a group nobody asked for during its hold time lets go of its hardware (the IOReport subscription): `idleAfter`
///   (30 s), or twice the time between its questions when they come less often, at most `forgetAfter`. Its reading
///   stays, so that a measure that updates rarely gets the value read at its previous update;
/// - a reading nobody asked for during `forgetAfter` (10 minutes), or twice the time between its questions, is
///   forgotten: the next question gets nothing, as after loading.
/// While a group holds hardware or a reading, a cleanup is scheduled on the queue to let go of it without waiting for a
/// question: it wakes about once every `idleAfter` while skins ask, and stops once nothing is held.
///
/// Any thread: the state is behind one lock (`Guarded`), held only to look up or store; the hardware is used on the
/// queue alone. A sensor that loses its reading for a moment (a CPU cluster powered down between two samples) keeps
/// its last value for up to `holdFor` (10 s).
final class SensorService {
    static let shared = SensorService(hardware: LiveSensorHardware())

    static let maxAge: TimeInterval = 0.9
    static let holdFor: TimeInterval = 10

    /// How long a group nobody asks for keeps its hardware at least (30 s), and its reading at least (10 minutes).
    let idleAfter: TimeInterval
    let forgetAfter: TimeInterval

    private struct Reading {
        var group: SensorGroupReading
        var time: TimeInterval
        /// When each value was read (for holding values across a missing reading).
        var valueTimes: [String: TimeInterval]
    }

    private struct State {
        /// When each group was last asked for.
        var asked: [SensorGroup: TimeInterval] = [:]
        /// The time between a group's last two questions (questions less than `maxAge` apart count as one).
        var gaps: [SensorGroup: TimeInterval] = [:]
        /// Groups asked for while their reading was stale or missing: the next refresh reads them.
        var wanted: Set<SensorGroup> = []
        /// Groups the running refresh reads.
        var inFlight: Set<SensorGroup> = []
        /// Groups read since their hardware was last let go.
        var held: Set<SensorGroup> = []
        /// Held groups whose hold time ran out before a question came (the cleanup was late): let go before reading.
        var lapsed: Set<SensorGroup> = []
        var readings: [SensorGroup: Reading] = [:]
        var refreshing = false
        var refreshes = 0
        var list: [SensorInfo] = []
        var infos: [String: SensorInfo] = [:]
        var waiters: [([SensorInfo]) -> Void] = []
        /// When the scheduled cleanup runs (the service's clock); nil when none is scheduled.
        var cleanupAt: TimeInterval?
    }

    private let state = Guarded(State())
    private let queue = DispatchQueue(label: "app.deskset.sensors", qos: .utility)
    private let hardware: SensorHardware
    private let clock: () -> TimeInterval

    init(hardware: SensorHardware, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         idleAfter: TimeInterval = 30, forgetAfter: TimeInterval = 600) {
        self.hardware = hardware
        self.clock = clock
        self.idleAfter = idleAfter
        self.forgetAfter = max(forgetAfter, idleAfter)
    }

    // MARK: Questions (any thread)

    /// The last reading of `key` (canonical), nil when there is none; starts a refresh when it is stale.
    func value(_ key: String) -> Double? {
        let groups = SensorGroup.groups(for: key)
        guard !groups.isEmpty else { return nil }
        let now = clock()
        let (value, start) = state.access { s -> (Double?, Bool) in
            var value: Double?
            for g in groups {
                ask(&s, g, now: now)
                if value == nil { value = s.readings[g]?.group.values[key] }
            }
            return (value, SensorService.claimRefresh(&s))
        }
        if start { queue.async { self.refresh() } }
        return value
    }

    /// True while a group that can answer `key` has not been read yet (or its reading was forgotten).
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
            for g in SensorGroup.allCases { ask(&s, g, now: now) }
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
            for g in SensorGroup.allCases { ask(&s, g, now: now) }
        }
        queue.sync { refresh() }
        return list()
    }

    /// Lets go of what nobody asked for lately now, as the scheduled cleanup does (tests; waits for it).
    func cleanUpNow() {
        queue.sync { cleanUp(scheduledAt: nil) }
    }

    /// How many refreshes ran, and whether one is claimed or running (tests).
    var refreshCount: Int { state.access { $0.refreshes } }
    var isRefreshing: Bool { state.access { $0.refreshing } }

    /// How long a group asked for every `gap` seconds keeps its hardware, and its reading.
    private func holdTime(_ gap: TimeInterval?) -> TimeInterval { min(max(idleAfter, 2 * (gap ?? 0)), forgetAfter) }
    private func forgetTime(_ gap: TimeInterval?) -> TimeInterval { max(forgetAfter, 2 * (gap ?? 0)) }

    /// Notes a question for group `g` (with the lock held): forgets a reading nobody asked for too long, notes the time
    /// between questions, and marks the group wanted when its reading is stale or missing.
    private func ask(_ s: inout State, _ g: SensorGroup, now: TimeInterval) {
        if let last = s.asked[g] {
            let since = now - last
            if s.held.contains(g), since >= holdTime(s.gaps[g]) { s.lapsed.insert(g) }
            if since >= forgetTime(s.gaps[g]) {
                SensorService.forget(&s, g)
                SensorService.rebuildList(&s)
            } else if since >= SensorService.maxAge {
                s.gaps[g] = since
            }
        }
        s.asked[g] = now
        let stale = s.readings[g].map { now - $0.time >= SensorService.maxAge } ?? true
        if stale, !s.inFlight.contains(g) { s.wanted.insert(g) }
    }

    /// Claims the refresh when a group is wanted and none runs (with the lock held).
    private static func claimRefresh(_ s: inout State) -> Bool {
        guard !s.refreshing, !s.wanted.isEmpty else { return false }
        s.refreshing = true
        return true
    }

    private static func forget(_ s: inout State, _ g: SensorGroup) {
        s.readings[g] = nil
        s.asked[g] = nil
        s.gaps[g] = nil
    }

    // MARK: Refresh and cleanup (the queue)

    private func refresh() {
        let start = clock()
        let (read, lapsed) = state.access { s -> (Set<SensorGroup>, Set<SensorGroup>) in
            let read = s.wanted
            s.wanted = []
            s.inFlight = read
            let lapsed = s.lapsed
            s.lapsed = []
            s.held.subtract(lapsed)
            s.held.formUnion(read)
            return (read, lapsed)
        }
        // Hardware kept past its hold time is let go before it is read again (the IOReport base would be old).
        if !lapsed.isEmpty { hardware.release(lapsed) }
        let fresh = read.isEmpty ? [:] : hardware.read(read)
        let (done, list, again, release, next) = state.access {
            s -> ([([SensorInfo]) -> Void], [SensorInfo], Bool, Set<SensorGroup>, TimeInterval?) in
            for group in read {
                s.readings[group] = SensorService.merge(previous: s.readings[group], fresh[group] ?? SensorGroupReading(),
                                                        now: start)
            }
            s.refreshes += 1
            let (release, next) = idle(&s, now: start)
            s.inFlight = []
            SensorService.rebuildList(&s)
            // Waiters asked for every group: done once every group has been read.
            let complete = SensorGroup.allCases.allSatisfy { s.readings[$0] != nil }
            let done = complete ? s.waiters : []
            if complete { s.waiters = [] }
            for g in SensorGroup.allCases where !s.waiters.isEmpty && s.readings[g] == nil { s.wanted.insert(g) }
            // Groups asked for while this refresh ran, stale or never read: read them now rather than at the next
            // question.
            let again = !s.wanted.isEmpty
            s.refreshing = again
            return (done, s.list, again, release, next)
        }
        if !release.isEmpty { hardware.release(release) }
        for waiter in done { waiter(list) }
        if again { queue.async { self.refresh() } }
        scheduleCleanup(next)
    }

    /// The groups whose hold time ran out (their hardware is let go) and the readings nobody asked for during their
    /// forget time (dropped), except the groups just read; returns what to let go and when to look again (nil:
    /// nothing is held).
    private func idle(_ s: inout State, now: TimeInterval) -> (release: Set<SensorGroup>, next: TimeInterval?) {
        var release = Set<SensorGroup>()
        var next: TimeInterval?
        for g in SensorGroup.allCases {
            guard let asked = s.asked[g] else {
                if s.held.remove(g) != nil { release.insert(g) }
                continue
            }
            let holdUntil = asked + holdTime(s.gaps[g]), forgetAt = asked + forgetTime(s.gaps[g])
            let busy = s.inFlight.contains(g) || s.wanted.contains(g)
            if now >= forgetAt, !busy {
                SensorService.forget(&s, g)
                if s.held.remove(g) != nil { release.insert(g) }
                s.lapsed.remove(g)
                continue
            }
            if s.held.contains(g), now >= holdUntil, !busy {
                s.held.remove(g)
                s.lapsed.remove(g)
                release.insert(g)
            }
            // A group being read now is looked at again a little later.
            let due = max(s.held.contains(g) ? holdUntil : forgetAt, now + 1)
            next = min(next ?? due, due)
        }
        return (release, next)
    }

    /// Schedules the cleanup for `at` (the service's clock) unless one runs sooner.
    private func scheduleCleanup(_ at: TimeInterval?) {
        guard let at else { return }
        let schedule = state.access { s -> Bool in
            if let pending = s.cleanupAt, pending <= at { return false }
            s.cleanupAt = at
            return true
        }
        guard schedule else { return }
        let delay = max(at - clock(), 0) + 0.1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.cleanUp(scheduledAt: at) }
    }

    /// Lets go of what nobody asked for lately, and schedules the next cleanup while something is held. A cleanup
    /// that was replaced by a sooner one does nothing.
    private func cleanUp(scheduledAt at: TimeInterval?) {
        let now = clock()
        let result = state.access { s -> (release: Set<SensorGroup>, next: TimeInterval?)? in
            if let at {
                guard s.cleanupAt == at else { return nil }
                s.cleanupAt = nil
            }
            let result = idle(&s, now: now)
            SensorService.rebuildList(&s)
            return result
        }
        guard let result else { return }
        if !result.release.isEmpty { hardware.release(result.release) }
        scheduleCleanup(result.next)
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
