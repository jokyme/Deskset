import Foundation

/// Work done on the main thread in steps, a few per turn of the main run loop, so that between two turns the skins'
/// timers fire and their new frames are drawn (see `MainThreadStallMonitor`). Building a window at once keeps every
/// skin still for as long as it takes; built in steps, the skins go on animating while its parts appear.
///
/// A turn runs one step, or — with a `budget` — steps in order until the budget is used up (a step is never cut short,
/// so a slow step makes a slow turn: split it). A step that adds views pays for their layout and drawing at the end of
/// its turn, where the budget cannot see it: such steps want a turn of their own (no budget). Steps added by a running
/// step run right after it, before the steps that were already waiting; steps added otherwise go last.
///
/// Turns are driven by a timer in the common run-loop modes, so the work goes on while a menu is open or a window is
/// resized. Each turn comes a moment after the last (`pause`), and not before the run loop has been about to wait or
/// has left since: that is when it draws the windows. After an event or a dispatched block the run loop goes on without
/// waiting, and a turn due then would make one step with the last turn, or with the click that started them.
///
/// `finish()` runs every step left at once: for headless use (self-tests, snapshots), and before anything that needs
/// the finished work.
final class MainThreadSteps {
    typealias Step = (label: String, work: () -> Void)

    /// Named with each step in the main-thread stall log.
    let name: String
    /// How long a turn may run steps before the rest waits for the next turn (0: one step per turn).
    var budget: TimeInterval
    private var queue: [Step] = []
    /// Steps added by the step that is running (they go before the queue when it returns).
    private var added: [Step] = []
    private var isRunningStep = false
    /// `finish()` was called while a step ran: the steps left run as soon as it returns.
    private var finishing = false
    private var timer: Timer?
    /// Tells when the run loop is about to wait or leaves (`displayed`) while turns are to come.
    private var observer: CFRunLoopObserver?
    /// The run loop has been about to wait, or has left, since the last turn (or `start`).
    private var displayed = false
    /// When a turn first found the run loop not about to wait since the last: it waits so long at most.
    private var waitingSince: UInt64?
    private var completions: [() -> Void] = []
    private(set) var isCancelled = false
    /// Turns of the run loop that ran steps (self-tests).
    private(set) var turns = 0

    init(name: String, budget: TimeInterval = 0) {
        self.name = name
        self.budget = budget
    }

    deinit {
        timer?.invalidate()
        stopObserving()
    }

    /// No step is left to run.
    var isDone: Bool { queue.isEmpty && added.isEmpty && !isRunningStep }

    /// Adds a step: right after the running step when a step adds it, else last.
    func add(_ label: String, _ work: @escaping () -> Void) {
        guard !isCancelled else { return }
        if isRunningStep { added.append((label, work)) } else { queue.append((label, work)) }
    }

    /// Runs `work` when every step has run (now when none is left); never when the steps are cancelled.
    func whenDone(_ work: @escaping () -> Void) {
        guard !isCancelled else { return }
        guard isDone else { return completions.append(work) }
        work()
    }

    /// The time between two turns.
    static let pause: TimeInterval = 0.001
    /// The longest a turn waits for the run loop to be about to wait (one that never is would stop the steps).
    static let longestWaitForDisplay: TimeInterval = 0.05

    /// Runs the steps from the next turn of the main run loop on.
    func start() {
        guard !isCancelled, timer == nil, !isDone else { return }
        observe()
        displayed = false
        schedule()
    }

    private func schedule() {
        let t = Timer(timeInterval: Self.pause, repeats: false) { [weak self] _ in self?.turn() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Runs every step left, now (from inside a step: as soon as it returns).
    func finish() {
        guard !isCancelled else { return }
        timer?.invalidate()
        timer = nil
        if isRunningStep {
            finishing = true
            return
        }
        runSteps { true }
        stopObserving()
    }

    /// Drops the steps left, and what waits for them.
    func cancel() {
        isCancelled = true
        timer?.invalidate()
        timer = nil
        queue = []
        added = []
        completions = []
        stopObserving()
    }

    private func turn() {
        timer = nil
        let now = DispatchTime.now().uptimeNanoseconds
        if !displayed {
            let since = waitingSince ?? now
            waitingSince = since
            if Double(now - since) / 1_000_000_000 < Self.longestWaitForDisplay { return schedule() }
        }
        waitingSince = nil
        turns += 1
        let deadline = now + UInt64(max(budget, 0) * 1_000_000_000)
        runSteps { DispatchTime.now().uptimeNanoseconds < deadline }
        start()
        if timer == nil { stopObserving() }
    }

    private func observe() {
        guard observer == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.beforeWaiting, .exit]).rawValue, true,
                                                   0) { [weak self] _, _ in
            self?.displayed = true
        }
        guard let o else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
    }

    private func stopObserving() {
        guard let o = observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = nil
    }

    private func runSteps(while more: () -> Bool) {
        repeat {
            guard !isCancelled, !queue.isEmpty else { break }
            let step = queue.removeFirst()
            isRunningStep = true
            let start = DispatchTime.now().uptimeNanoseconds
            step.work()
            isRunningStep = false
            MainThreadStallMonitor.note("\(name): \(step.label) "
                + "\(Int((Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000).rounded())) ms")
            if !added.isEmpty {
                queue.insert(contentsOf: added, at: 0)
                added = []
            }
        } while finishing || more()
        finishing = false
        guard isDone, !isCancelled, !completions.isEmpty else { return }
        let done = completions
        completions = []
        for work in done { work() }
    }
}
