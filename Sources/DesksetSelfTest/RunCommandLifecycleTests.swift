import Darwin
import Foundation
@testable import DesksetCore

/// A controllable process: Close may be ignored, and only the test decides when its final output arrives.
private final class RunCommandProcessProbe: SkinProcess {
    private let lock = NSLock()
    private var callback: (() -> Void)?
    private var output = Data()
    private var sentSignals: [Int32] = []
    private var didExit = false
    var exitsOnClose = false

    var onExit: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }
    var signals: [Int32] {
        lock.lock(); defer { lock.unlock() }; return sentSignals
    }
    var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }; return didExit
    }
    func resume() {}
    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        output.append(contentsOf: text.utf8)
    }
    func outputSnapshot() -> Data {
        lock.lock(); defer { lock.unlock() }; return output
    }
    @discardableResult
    func signal(_ signal: Int32) -> Bool {
        lock.lock()
        guard !didExit else { lock.unlock(); return true }
        sentSignals.append(signal)
        lock.unlock()
        if signal == SIGKILL || (signal == SIGTERM && exitsOnClose) { exit() }
        return true
    }
    func exit() {
        lock.lock()
        guard !didExit else { lock.unlock(); return }
        didExit = true
        let finished = callback
        callback = nil
        lock.unlock()
        finished?()
    }
}

/// Uses the asynchronous process-completion path, but starts no real process and records every other effect.
private final class RunCommandEffectsProbe: SideEffects {
    let isLive = true
    let recording: RecordingSideEffects
    var processes: [RunCommandProcessProbe] = []
    var fileSandbox: SkinFileSandbox? { recording.fileSandbox }

    init(directory: URL) { recording = RecordingSideEffects(directory: directory) }
    func startShellCommand(_ command: String, directory: String, maxOutput: Int, locale: Locale) throws -> SkinProcess {
        let process = RunCommandProcessProbe()
        processes.append(process)
        return process
    }
    func launch(_ executable: String, _ arguments: [String], completion: ((Int32) -> Void)?) {
        recording.launch(executable, arguments, completion: completion)
    }
    func destination(forWriting url: URL) -> URL { recording.destination(forWriting: url) }
    func temporaryDestination(for url: URL) -> URL { recording.temporaryDestination(for: url) }
    func writeFile(_ data: Data, to url: URL, makingFolder: Bool) throws {
        try recording.writeFile(data, to: url, makingFolder: makingFolder)
    }
    func removeTemporaryFile(atPath path: String) { recording.removeTemporaryFile(atPath: path) }
    func writeKeyValue(_ value: String, key: String, section: String, fileURL: URL) throws {
        try recording.writeKeyValue(value, key: key, section: section, fileURL: fileURL)
    }
    func perform(_ effect: SideEffect, live: () -> Void) { recording.record(effect) }
}

private final class RunCommandLifecycleFixture {
    let executor = ManualExecutor()
    let host = FakeHost()
    let skin: Skin
    let effects: RunCommandEffectsProbe
    var measure: RunCommandMeasure { skin.measure(named: "Run") as! RunCommandMeasure }
    var savedOutput: String? {
        effects.recording.files.copy(of: skin.directory.appendingPathComponent("output.txt").path)
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    init(_ t: TestRunner, state: String = "Hide", timeout: Int = -1) throws {
        let root = t.temporaryDirectory("runcommand-lifecycle")
        let file = root.appendingPathComponent("Skin.ini")
        try """
        [Rainmeter]
        Update=-1
        [Variables]
        Done=
        [Run]
        Measure=RunCommand
        Parameter=echo fixture
        State=\(state)
        Timeout=\(timeout)
        OutputType=UTF8
        OutputFile=output.txt
        FinishAction=[!SetVariable Done "[#Done]x"]
        """.write(to: file, atomically: true, encoding: .utf8)
        effects = RunCommandEffectsProbe(directory: root.appendingPathComponent("Recorded"))
        skin = Skin(config: "Fixture", fileURL: file, skinsDirectory: root, system: FakeSystem(), host: host)
        skin.executor = executor
        skin.sideEffects = effects
        try skin.load()
        skin.update()
    }

    /// Deliver a process exit, then the separately decoded/saved output, through the skin's executor.
    func finishExit(_ t: TestRunner) {
        executor.runPending(where: { $0 == .async })
        finishOutput(t)
    }
    func finishOutput(_ t: TestRunner) {
        t.check(executor.waitForAsync(), "decoded output returns through the executor")
        executor.runPending(where: { $0 == .async })
    }
}

func runRunCommandLifecycleTests(_ t: TestRunner) {
    t.suite("Plugin: RunCommand Close retains output and rejects another Run") {
        let f = try RunCommandLifecycleFixture(t)
        defer { f.skin.close() }
        f.measure.execute(command: "Run")
        let process = f.effects.processes[0]
        process.append("early\n")
        f.measure.execute(command: "Close")
        f.measure.execute(command: "Close")
        t.equal(process.signals, [SIGTERM, SIGTERM])
        t.equal(f.executor.pendingKinds, [], "Close schedules no forced finish, even when repeated")
        f.executor.runPending()
        t.check(f.measure.isRunning && !process.hasExited)
        t.equal(f.measure.value, 0)
        t.equal(f.skin.variable("Done"), "")
        t.equal(f.savedOutput, nil, "no early OutputFile")
        f.measure.execute(command: "Run")
        t.equal(f.measure.value, 101)
        t.equal(f.effects.processes.count, 1, "no second process while Close is pending")

        process.append("late\n")
        process.exit()
        t.equal(f.skin.variable("Done"), "", "the exit must return through the executor")
        f.executor.runPending(where: { $0 == .async })
        f.measure.execute(command: "Run")
        t.equal(f.measure.value, 101, "still busy until output has been saved")
        f.finishOutput(t)
        t.check(!f.measure.isRunning)
        t.equal(f.measure.runningJobCount, 0)
        t.equal(f.measure.value, 1)
        t.equal(f.measure.stringValue, "early\nlate\n")
        t.equal(f.savedOutput, "early\nlate\n")
        t.equal(f.skin.variable("Done"), "x")
        process.exit()
        f.executor.runPending()
        t.equal(f.skin.variable("Done"), "x", "FinishAction runs only once")
        f.measure.execute(command: "Close")
        t.equal(f.measure.value, 102)
    }

    t.suite("Plugin: RunCommand cooperative Close and Kill finish on exit") {
        for command in ["Close", "Kill"] {
            let f = try RunCommandLifecycleFixture(t)
            defer { f.skin.close() }
            f.measure.execute(command: "Run")
            let process = f.effects.processes[0]
            process.exitsOnClose = command == "Close"
            process.append("kept\n")
            if command == "Kill" { f.measure.execute(command: "Close") }
            f.measure.execute(command: command)
            t.equal(process.signals, command == "Close" ? [SIGTERM] : [SIGTERM, SIGKILL])
            t.check(f.measure.isRunning, "completion is not inline with the signal")
            f.finishExit(t)
            t.check(!f.measure.isRunning && process.hasExited)
            t.equal(f.measure.stringValue, "kept\n")
            t.equal(f.skin.variable("Done"), "x")
        }
    }

    t.suite("Plugin: RunCommand Timeout still finishes an ignored Close") {
        let f = try RunCommandLifecycleFixture(t, state: "Show", timeout: 1000)
        defer { f.skin.close() }
        f.measure.execute(command: "Run")
        let first = f.effects.processes[0]
        first.append("before timeout\n")
        f.measure.execute(command: "Close")
        t.equal(f.executor.pendingKinds, [.after(1)], "Close neither replaces nor cancels Timeout")
        f.executor.runPending(where: { $0 == .after(1) })
        first.append("after timeout\n")
        f.finishOutput(t)
        t.equal(first.signals, [SIGTERM, SIGTERM])
        t.check(!first.hasExited && !f.measure.isRunning, "only Timeout may finish before exit")
        t.equal(f.measure.stringValue, "before timeout\n")
        t.equal(f.savedOutput, "before timeout\n")
        t.equal(f.skin.variable("Done"), "x")

        f.measure.execute(command: "Run")
        first.exit()
        f.executor.runPending(where: { $0 == .async })
        t.check(f.measure.isRunning, "the old exit must not finish the newer run")
        t.equal(f.measure.value, 0)
        t.equal(f.skin.variable("Done"), "x")
        let second = f.effects.processes[1]
        second.append("second run\n")
        f.measure.execute(command: "Kill")
        f.finishExit(t)
        t.equal(f.measure.stringValue, "second run\n")
        t.equal(f.skin.variable("Done"), "xx")
    }

    t.suite("Plugin: RunCommand unload after Close cancels Timeout and drops completion") {
        for state in ["Hide", "Show"] {
            let f = try RunCommandLifecycleFixture(t, state: state, timeout: 60_000)
            f.measure.execute(command: "Run")
            let process = f.effects.processes[0]
            process.append("discarded\n")
            f.measure.execute(command: "Close")
            let timeout = f.executor.pending.first { $0.kind == .after(60) }?.work
            f.skin.close()  // The old skin follows this same path during a refresh.
            t.equal(process.signals, state == "Hide" ? [SIGTERM, SIGKILL] : [SIGTERM])
            t.check(timeout?.isCancelled == true)
            t.check(!f.measure.isRunning)
            process.exit()
            f.executor.runPending()
            t.equal(f.savedOutput, nil)
            t.equal(f.skin.variable("Done"), "", "unload never runs FinishAction")
        }

        let f = try RunCommandLifecycleFixture(t)
        f.measure.execute(command: "Run")
        f.measure.execute(command: "Close")
        f.effects.processes[0].exit()
        t.equal(f.executor.pendingKinds, [.async])
        f.skin.close()
        f.executor.runPending()
        t.equal(f.savedOutput, nil, "an exit queued before unload is dropped too")
        t.equal(f.skin.variable("Done"), "")
    }

    t.suite("Plugin: RunCommand disposal after Close releases the skin and kills hidden work") {
        var f: RunCommandLifecycleFixture? = try RunCommandLifecycleFixture(t, timeout: 60_000)
        weak var skin = f?.skin
        weak var measure = f?.measure
        let executor = f!.executor
        f!.measure.execute(command: "Run")
        f!.measure.execute(command: "Close")
        let process = f!.effects.processes[0]
        let timeout = executor.pending.first { $0.kind == .after(60) }?.work
        f = nil  // No explicit close, as for a discarded preview.
        t.check(skin == nil && measure == nil, "the process watcher does not retain the skin or measure")
        t.equal(process.signals, [SIGTERM, SIGKILL])
        t.check(timeout?.isCancelled == true)
        executor.runPending()
        t.equal(executor.pendingKinds, [])
    }
}
