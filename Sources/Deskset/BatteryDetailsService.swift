import Darwin
import DesksetCore
import Foundation

extension Notification.Name {
    /// A completed battery-details snapshot has been published. Delivered on Main by the live service.
    static let desksetBatteryDetailsDidChange = Notification.Name("DesksetBatteryDetailsDidChange")
}

/// Slow battery metadata shared by every owner. Only this service owns its Unix-hour cache: readers never wait
/// for system_profiler, and a completed missing result is cached just like a value. No timer runs between requests.
final class BatteryDetailsService {
    static let shared = BatteryDetailsService()
    static let maximumOutputBytes = 1 << 20
    static let timeout: TimeInterval = 10

    enum Failure: Equatable {
        case start(Int32), read(Int32), wait(Int32)
        case timedOut, outputLimit, incompleteOutput, cancelled
    }

    enum ProfileResult: Equatable {
        case exited(status: Int32, output: Data)
        case failed(Failure)
    }

    /// Cancellation never waits for the child. A reader calls its completion once, after closing and reaping it,
    /// including when cancelled. Controlled readers may complete synchronously, before returning this ticket.
    final class Ticket {
        private let cancellation: Guarded<(() -> Void)?>
        init(cancel: @escaping () -> Void) { cancellation = Guarded(cancel) }
        func cancel() {
            let work = cancellation.access { value -> (() -> Void)? in
                defer { value = nil }
                return value
            }
            work?()
        }
    }

    typealias Start = (@escaping (ProfileResult) -> Void) -> Ticket

    private struct Request {
        let id: UUID
        let bucket: TimeInterval
    }
    private struct Job {
        let request: Request
        var ticket: Ticket?
    }
    private struct State {
        var wanted: Request?
        var ready: BatteryDetails?
        var job: Job?
        var stopped = false
    }

    private let state = Guarded(State())
    private let queue: DispatchQueue
    private let clock: () -> TimeInterval
    private let start: Start
    private let readRawBattery: () -> [String: Any]?
    private let scheduleMain: (@escaping () -> Void) -> Void
    private let didChange: () -> Void

    init(clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         start: @escaping Start = BatteryProfileProcess.start,
         readRawBattery: @escaping () -> [String: Any]? = IOKitSensorReaders.batteryProperties,
         queue: DispatchQueue = DispatchQueue(label: "app.deskset.battery-details", qos: .utility),
         scheduleMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         didChange: @escaping () -> Void = {
             NotificationCenter.default.post(name: .desksetBatteryDetailsDidChange, object: nil)
         }) {
        self.clock = clock
        self.start = start
        self.readRawBattery = readRawBattery
        self.queue = queue
        self.scheduleMain = scheduleMain
        self.didChange = didChange
    }

    /// Any thread. The hour is a Double so even a deliberately extreme clock cannot trap an integer conversion.
    func reading() -> BatteryDetailsReading {
        let time = clock()
        guard time.isFinite else { return .ready(BatteryDetails()) }
        let bucket = floor(time / 3_600)
        let result = state.access { s -> (BatteryDetailsReading, Bool, Ticket?) in
            guard !s.stopped else { return (.ready(BatteryDetails()), false, nil) }
            if s.wanted?.bucket == bucket {
                return (s.ready.map(BatteryDetailsReading.ready) ?? .pending, false, nil)
            }
            s.wanted = Request(id: UUID(), bucket: bucket)
            s.ready = nil
            return (.pending, true, s.job?.ticket)
        }
        result.2?.cancel()
        if result.1 { queue.async { [weak self] in self?.drive() } }
        return result.0
    }

    /// Service teardown, not widget teardown: other widgets may still use the shared service. Already running
    /// IOKit work cannot be interrupted; its result and any queued Main notification lose their publication token.
    func stop() {
        let ticket = state.access { s -> Ticket? in
            s.stopped = true
            s.wanted = nil
            s.ready = nil
            return s.job?.ticket
        }
        ticket?.cancel()
    }

    deinit { stop() }

    private func drive() {
        let request = state.access { s -> Request? in
            guard !s.stopped, s.ready == nil, s.job == nil, let wanted = s.wanted else { return nil }
            // Claim before calling injected code, which may deliver its result inline.
            s.job = Job(request: wanted, ticket: nil)
            return wanted
        }
        guard let request else { return }
        let ticket = start { [weak self] result in
            guard let self else { return }
            // Always queue: an inline completion must not run before the ticket has been installed.
            self.queue.async { [weak self] in self?.finished(request, result: result) }
        }
        let cancel = state.access { s -> Bool in
            guard s.job?.request.id == request.id else { return true }
            s.job?.ticket = ticket
            return s.stopped || s.wanted?.id != request.id
        }
        if cancel { ticket.cancel() }
    }

    private func finished(_ request: Request, result: ProfileResult) {
        let current = state.access { s in
            s.job?.request.id == request.id && !s.stopped && s.wanted?.id == request.id
        }
        // Do not do raw hardware work for a cancelled bucket. A stale completion still releases its job before
        // starting the newest requested bucket, so two profiler children never overlap.
        var details = BatteryDetails()
        if current {
            if case .exited(status: 0, output: let output) = result,
               output.count <= Self.maximumOutputBytes {
                details = Self.profileDetails(output)
            }
            if details.health == nil, let raw = readRawBattery(), let health = Self.rawHealth(raw) {
                details = BatteryDetails(health: health, cycles: details.cycles)
            }
        }
        let accepted = state.access { s -> Bool in
            guard s.job?.request.id == request.id else { return false }
            s.job = nil
            guard !s.stopped, s.wanted?.id == request.id else { return false }
            s.ready = details
            return true
        }
        if accepted {
            scheduleMain { [weak self] in
                guard let self else { return }
                let time = self.clock()
                guard time.isFinite, floor(time / 3_600) == request.bucket else { return }
                let valid = self.state.access { s in
                    !s.stopped && s.wanted?.id == request.id && s.ready != nil
                }
                guard valid else { return }
                self.didChange()
            }
        }
        drive()
    }

    /// Reads only the battery-health dictionary; other hardware fields are neither retained nor logged.
    static func profileDetails(_ data: Data) -> BatteryDetails {
        guard data.count <= maximumOutputBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let power = root["SPPowerDataType"] as? [[String: Any]],
              let healthInfo = power.first?["sppower_battery_health_info"] as? [String: Any] else {
            return BatteryDetails()
        }
        var health: Double?
        if let raw = healthInfo["sppower_battery_health_maximum_capacity"] as? String {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("%"), let number = Double(text.dropLast().trimmingCharacters(in: .whitespaces)),
               number.isFinite, (0...100).contains(number) { health = number }
        }
        var cycles: Double?
        if let number = healthInfo["sppower_battery_cycle_count"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            if value.isFinite, value >= 0 { cycles = value }
        }
        return BatteryDetails(health: health, cycles: cycles)
    }

    static func rawHealth(_ properties: [String: Any]) -> Double? {
        // Reject Boolean/nonfinite metadata at this boundary without changing legacy MacSensors' decoding.
        var capacities: [String: Any] = [:]
        for key in ["DesignCapacity", "AppleRawMaxCapacity", "MaxCapacity"] {
            if let number = properties[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite { capacities[key] = number }
        }
        guard let value = SensorReadings.batteryHealth(capacities), value.isFinite,
              (0...100).contains(value) else { return nil }
        return value
    }
}

/// A fixed system_profiler invocation. Like RunCommandJob, it owns a process group, drains a nonblocking pipe,
/// and reaps on a private queue. Unlike the INI output reader it rejects truncation and nonzero exit status.
final class BatteryProfileProcess: @unchecked Sendable {
    typealias Service = BatteryDetailsService
    private let queue = DispatchQueue(label: "app.deskset.battery-profile", qos: .utility)
    private let cancelled = Guarded(false)
    private let executable: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private var completion: ((Service.ProfileResult) -> Void)?
    private var pid: pid_t?
    private var output = Data()
    private var failure: Service.Failure?
    private var status: Int32?
    private var observedExit = false
    private var stdoutClosed = false
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var timeoutSource: DispatchSourceTimer?
    private var stdoutFD: Int32 = -1

    private init(executable: String, arguments: [String], timeout: TimeInterval,
                 completion: @escaping (Service.ProfileResult) -> Void) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.completion = completion
    }

    static func start(_ completion: @escaping (Service.ProfileResult) -> Void) -> Service.Ticket {
        start(executable: "/usr/sbin/system_profiler", arguments: ["SPPowerDataType", "-json"],
              timeout: Service.timeout, completion: completion)
    }

    /// Internal child-reader seam for fixed local self-test scripts. Production always uses start(_:) above.
    static func start(executable: String, arguments: [String], timeout: TimeInterval,
                      completion: @escaping (Service.ProfileResult) -> Void) -> Service.Ticket {
        let process = BatteryProfileProcess(executable: executable, arguments: arguments, timeout: timeout,
                                            completion: completion)
        process.queue.async { process.launch() }
        return Service.Ticket {
            process.cancelled.access { $0 = true }
            process.queue.async { process.fail(.cancelled) }
        }
    }

    private func launch() {
        guard !cancelled.current else { complete(.failed(.cancelled)); return }
        guard timeout.isFinite, timeout > 0, timeout <= Service.timeout else {
            complete(.failed(.start(EINVAL)))
            return
        }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { complete(.failed(.start(errno))); return }
        guard descriptors.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }),
              fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else {
            let error = errno
            close(descriptors[0]); close(descriptors[1])
            complete(.failed(.start(error)))
            return
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else {
            close(descriptors[0]); close(descriptors[1])
            complete(.failed(.start(actionsResult)))
            return
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            close(descriptors[0]); close(descriptors[1])
            complete(.failed(.start(attributesResult)))
            return
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        let configuration = [
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], 1),
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_addchdir_np(&actions, "/"),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
                                                       | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setsigdefault(&attributes, &allSignals),
            posix_spawnattr_setsigmask(&attributes, &noSignals)
        ]
        if let error = configuration.first(where: { $0 != 0 }) {
            close(descriptors[0]); close(descriptors[1])
            complete(.failed(.start(error)))
            return
        }
        var child: pid_t = 0
        // No shell, caller arguments, or inherited locale-dependent text output.
        let result = Self.withCStrings([executable] + arguments) { argv in
            Self.withCStrings(["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8"]) { envp in
                posix_spawn(&child, executable, &actions, &attributes, argv, envp)
            }
        }
        close(descriptors[1])
        guard result == 0 else {
            close(descriptors[0])
            complete(.failed(.start(result)))
            return
        }
        pid = child
        stdoutFD = descriptors[0]
        let out = DispatchSource.makeReadSource(fileDescriptor: stdoutFD, queue: queue)
        out.setEventHandler { [self] in drain() }
        out.setCancelHandler { [self] in
            close(stdoutFD)
            stdoutFD = -1
            stdoutClosed = true
            finishIfDone()
        }
        readSource = out
        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        exit.setEventHandler { [self] in observeExit(retry: true) }
        exitSource = exit
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + self.timeout)
        timeout.setEventHandler { [self] in fail(.timedOut) }
        timeoutSource = timeout
        out.resume()
        exit.resume()
        timeout.resume()
        // The child can exit before its process source is armed.
        observeExit(retry: false)
        if cancelled.current { fail(.cancelled) }
    }

    private func drain() {
        guard readSource != nil else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = bytes.withUnsafeMutableBytes { read(stdoutFD, $0.baseAddress, $0.count) }
            if count > 0 {
                guard count <= Service.maximumOutputBytes - output.count else { fail(.outputLimit); return }
                output.append(contentsOf: bytes.prefix(count))
                continue
            }
            if count == 0 { closeOutput(); return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            fail(.read(errno))
            return
        }
    }

    private func fail(_ reason: Service.Failure) {
        guard completion != nil else { return }
        if failure == nil { failure = reason }
        output.removeAll(keepingCapacity: false)
        if let pid {
            // Signals and waitpid run on this one queue, so a reaped pid is never signalled after reuse.
            if kill(-pid, SIGKILL) != 0 { _ = kill(pid, SIGKILL) }
        }
        closeOutput()
        finishIfDone()
    }

    private func closeOutput() {
        readSource?.cancel()
        readSource = nil
    }

    private func observeExit(retry: Bool) {
        guard let child = pid, !observedExit else { return }
        // Leave the exited leader waitable until stdout has closed and its group has been cleaned up. Otherwise
        // a descendant can retain stdout after the leader was reaped, when signalling that pid is no longer safe.
        var info = siginfo_t()
        var result: Int32
        repeat { result = waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT) }
        while result == -1 && errno == EINTR
        if result == 0, info.si_pid == 0 {
            if retry { queue.asyncAfter(deadline: .now() + 0.001) { [self] in observeExit(retry: true) } }
            return
        }
        if result == -1 {
            let error = errno
            failure = failure ?? .wait(error)
            if error == ECHILD {
                pid = nil
                status = -1
                observedExit = true
                exitSource?.cancel()
                exitSource = nil
                closeOutput()
                finishIfDone()
            } else {
                // If observing failed, terminate while the child identity is still ours, then use the same
                // nonblocking reap path. Do not leave a killed child waiting for another dispatch exit event.
                observedExit = true
                exitSource?.cancel()
                exitSource = nil
                fail(.wait(error))
            }
            return
        }
        observedExit = true
        exitSource?.cancel()
        exitSource = nil
        drain()
        if readSource != nil {
            // A descendant holding stdout open is not complete JSON. Allow the pending bytes to arrive, then
            // reject rather than accepting a prefix as a successful snapshot.
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                drain()
                if readSource != nil { fail(.incompleteOutput) }
                finishIfDone()
            }
        }
        finishIfDone()
    }

    private func finishIfDone() {
        guard observedExit, stdoutClosed else { return }
        if let child = pid {
            // WNOWAIT still reserves the leader's identity, including when its descendants closed stdout early.
            // Clean the entire group before reaping, not after the numeric pid could have been reused.
            if kill(-child, SIGKILL) != 0 { _ = kill(child, SIGKILL) }
            var raw: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(child, &raw, WNOHANG) } while result == -1 && errno == EINTR
            if result == 0 {
                queue.asyncAfter(deadline: .now() + 0.001) { [self] in finishIfDone() }
                return
            }
            if result == -1 {
                failure = failure ?? .wait(errno)
                status = -1
            } else {
                // WIFEXITED/WEXITSTATUS are C macros; decode Darwin's wait status.
                status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
            }
            pid = nil
        }
        guard let status else { return }
        complete(failure.map(Service.ProfileResult.failed) ?? .exited(status: status, output: output))
    }

    private func complete(_ result: Service.ProfileResult) {
        guard let callback = completion else { return }
        completion = nil
        timeoutSource?.cancel()
        timeoutSource = nil
        output.removeAll(keepingCapacity: false)
        callback(result)
    }

    private static func withCStrings<T>(_ values: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> T) -> T {
        var strings = values.map { strdup($0) }
        strings.append(nil)
        defer { strings.forEach { free($0) } }
        return body(strings)
    }
}
