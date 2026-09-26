import Darwin
import Foundation
@testable import DesksetCore

// Process-wide state of the engine that skins on threads of their own share (suite prefix "Skin threading";
// docs/skin-threading.md §4.9, §4.10, phase 1), used from several dedicated threads at once, released together:
// - ProcessSampler: a skin joining just as the last other one leaves still gets samples;
// - the Registry measure's machine facts are worked out without holding their lock while the data source is asked;
// - !WriteKeyValue into one shared file from several skins at once: every write lands;
// - Lua: os.clock has one origin for the whole process, whichever thread opens a state first.
// The threads never call the runner (it is not thread-safe); they report into `ThreadReports`, checked afterwards.

func runSharedServiceThreadingTests(_ t: TestRunner) {
    runProcessSamplerThreadingTests(t)
    runRegistryFactsThreadingTests(t)
    runIniWriterThreadingTests(t)
    runLuaClockThreadingTests(t)
}

// MARK: - Helpers

/// What worker threads report, for the test to check afterwards.
final class ThreadReports<T> {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Runs `body(i)` for every `i` in `0..<count`, each on a thread of its own with the 8 MB stack a skin thread gets
/// (docs/skin-threading.md §5.3), all released together. False when they have not all finished within `timeout`.
func onSkinThreads(_ count: Int, timeout: TimeInterval = 60, _ body: @escaping (Int) -> Void) -> Bool {
    let gate = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    for i in 0..<count {
        let thread = Thread {
            gate.wait()
            body(i)
            finished.signal()
        }
        thread.name = "Deskset self-test thread \(i)"
        thread.stackSize = 8 << 20
        thread.start()
    }
    for _ in 0..<count { gate.signal() }
    let end = DispatchTime.now() + timeout
    for _ in 0..<count where finished.wait(timeout: end) == .timedOut { return false }
    return true
}

// MARK: - ProcessSampler

/// Cheap readings, so starting and stopping the sampler many times costs nothing.
private final class QuietProcessData: ProcessDataProvider {
    func readProcesses() -> (visible: [ProcessRecord], total: Int) { ([], 0) }
    func readCores() -> [CoreTicks] { [CoreTicks(user: 1, system: 1, idle: 8, nice: 0)] }
}

private func runProcessSamplerThreadingTests(_ t: TestRunner) {
    t.suite("Skin threading: ProcessSampler: joining as the last other skin leaves keeps the sampler running") {
        let savedProvider = ProcessSampler.provider
        ProcessSampler.provider = QuietProcessData()
        defer { ProcessSampler.provider = savedProvider }
        let sampler = ProcessSampler()
        // Two skins keep coming and going; whenever one of them is subscribed, the sampler must be running. Deciding
        // under the lock and starting or stopping after it let a stop that lost the race cancel the timer a
        // subscription that had just started it relied on.
        let stopped = ThreadReports<Int>()
        let owners = [NSObject(), NSObject()]
        t.check(onSkinThreads(2) { i in
            for round in 0..<2000 {
                sampler.subscribe(owners[i])
                if !sampler.isRunning { stopped.add(round) }
                sampler.unsubscribe(owners[i])
            }
        }, "the threads finish")
        t.equal(stopped.all.count, 0, "a subscribed skin always had a running sampler")
        t.check(!sampler.isRunning, "nobody subscribed: stopped")
        let last = NSObject()
        sampler.subscribe(last)
        t.check(sampler.isRunning)
        let end = Date().addingTimeInterval(60)
        while sampler.samples().latest == nil && Date() < end { usleep(1000) }
        t.check(sampler.samples().latest != nil, "and samples arrive")
        sampler.unsubscribe(last)
        t.check(!sampler.isRunning)
        t.check(sampler.samples().latest == nil, "the samples go with the last subscriber")
    }
}

// MARK: - Registry facts

/// A data source whose first computer-name lookup is held until `release` is signalled.
private final class SlowNameSystem: FakeSystem {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var asked = 0

    override func sysInfo(type: String, data: String) -> (number: Double, string: String?)? {
        guard type == "COMPUTER_NAME" else { return super.sysInfo(type: type, data: data) }
        lock.lock()
        asked += 1
        let first = asked == 1
        lock.unlock()
        if first {
            started.signal()
            _ = release.wait(timeout: .now() + 60)
        }
        return (0, first ? "First" : "Second")
    }
}

private func runRegistryFactsThreadingTests(_ t: TestRunner) {
    t.suite("Skin threading: Registry facts are worked out without holding their lock") {
        RegistryMeasure.Facts.forget()
        defer { RegistryMeasure.Facts.forget() }
        let system = SlowNameSystem()
        let names = ThreadReports<String>()
        let first = Thread {
            names.add(RegistryMeasure.Facts.current(system: system).computerName)
        }
        first.stackSize = 8 << 20
        first.start()
        t.check(system.started.wait(timeout: .now() + 60) == .success, "the first skin asks the data source")
        // Meanwhile a second skin needs the facts: it does not wait for the first one's data source call (which
        // could itself be waiting for something the second skin holds).
        let second = ThreadReports<String>()
        t.check(onSkinThreads(1) { _ in second.add(RegistryMeasure.Facts.current(system: system).computerName) },
                "a second skin gets the facts while the first is still asking")
        t.equal(second.all, ["Second"])
        system.release.signal()
        let end = Date().addingTimeInterval(60)
        while names.all.isEmpty && Date() < end { usleep(1000) }
        t.equal(names.all, ["Second"], "the first facts stored are kept, and every skin gets them")
        t.equal(RegistryMeasure.Facts.current(system: system).computerName, "Second")
    }
}

// MARK: - IniWriter

private func runIniWriterThreadingTests(_ t: TestRunner) {
    t.suite("Skin threading: !WriteKeyValue from several skins into one file: every write lands") {
        let dir = t.temporaryDirectory("ini-threads")
        let shared = dir.appendingPathComponent("Variables.inc")
        try "[Variables]\nShared=0\n".write(to: shared, atomically: true, encoding: .utf8)
        let other = dir.appendingPathComponent("Other.inc")
        try "[Variables]\n".write(to: other, atomically: true, encoding: .utf8)
        let threads = 8, writes = 25
        let errors = ThreadReports<String>()
        t.check(onSkinThreads(threads) { i in
            for n in 0..<writes {
                do {
                    try IniWriter.writeValue("\(i * 1000 + n)", key: "Skin\(i)Key\(n)", section: "Variables",
                                             fileURL: shared)
                    try IniWriter.writeValue("\(n)", key: "Shared", section: "Variables", fileURL: shared)
                    if n % 5 == 0 {
                        try IniWriter.writeValue("\(n)", key: "Skin\(i)", section: "Other\(i % 2)", fileURL: other)
                    }
                } catch {
                    errors.add("\(error)")
                }
            }
        }, "the threads finish")
        t.equal(errors.all, [])
        let document = IniDocument.parse(try String(contentsOf: shared, encoding: .utf8))
        let variables = document.section(named: "Variables")
        var missing: [String] = []
        for i in 0..<threads {
            for n in 0..<writes where variables?.value(forKey: "Skin\(i)Key\(n)") != "\(i * 1000 + n)" {
                missing.append("Skin\(i)Key\(n)")
            }
        }
        t.equal(missing.count, 0, "no skin's write was lost to another's (lost: \(missing.prefix(5)) …)")
        t.equal(variables?.value(forKey: "Shared"), "\(writes - 1)")
        let others = IniDocument.parse(try String(contentsOf: other, encoding: .utf8))
        for i in 0..<threads {
            t.equal(others.section(named: "Other\(i % 2)")?.value(forKey: "Skin\(i)"), "\(writes - 5)",
                    "another file, written at the same time")
        }
    }
}

// MARK: - Lua clock

private func runLuaClockThreadingTests(_ t: TestRunner) {
    t.suite("Skin threading: Lua os.clock has one origin, whichever thread opens a state") {
        LuaSupport.register()
        func clock(_ state: LuaState?) -> Double? {
            guard case .ok(let values)? = state?.evaluate("os.clock()"), case .number(let n)? = values.first
            else { return nil }
            return n
        }
        let limits = (memory: LuaSupport.memoryLimit, instructions: LuaSupport.instructionLimit)
        func open() -> LuaState? {
            LuaState(memoryLimit: limits.memory, instructionLimit: limits.instructions, secondsLimit: 5)
        }
        guard let before = clock(open()) else { return t.check(false, "os.clock on this thread") }
        let values = ThreadReports<Double?>()
        t.check(onSkinThreads(8) { _ in
            let state = open()
            for _ in 0..<20 { values.add(clock(state)) }
        }, "the threads finish")
        guard let after = clock(open()) else { return t.check(false, "os.clock on this thread") }
        let all = values.all
        t.equal(all.count, 160)
        t.check(all.allSatisfy { $0.map { $0 >= before && $0 <= after } ?? false },
                "every thread's clock reads between this thread's before and after: \(before)…\(after)")
    }
}
