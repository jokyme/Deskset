import Foundation

/// Watches the main thread for stalls. Skins update and draw on the main thread, from timers of the main run loop, so
/// whatever keeps the main thread from getting back to its run loop — a window being built, a large layout — freezes
/// every skin for that long, and an animated one (an audio visualizer at 60 frames per second) visibly skips frames.
///
/// A *step* is what the main thread does between waking up and being ready to sleep again — timers, events, dispatched
/// blocks, and the display pass that ends it (AppKit lays out and draws windows, a skin's new frame included, when the
/// run loop is about to wait, or leaves). The time asleep is left out, so the longest step is the longest a skin's
/// next frame can be kept from the screen.
///
/// - `defaults write app.deskset.Deskset MainThreadStallLog -int 50` logs every step of 50 ms or more to Deskset.log
///   (`-bool YES`: 50 ms), with what the app said it was doing then (`note`). Read at launch; off by default.
/// - Self-tests `record` the steps of what they run (`Steps.longest`).
final class MainThreadStallMonitor {
    static let shared = MainThreadStallMonitor()

    /// The user default that turns the log on (milliseconds, or YES for `defaultThreshold`).
    static let defaultsKey = "MainThreadStallLog"
    static let defaultThreshold: TimeInterval = 0.05

    /// One step of the main thread.
    struct Step: Equatable {
        var duration: TimeInterval
        /// What the app noted during the step (`note`), first to last.
        var notes: [String]
    }

    /// Steps recorded by `record`.
    struct Steps {
        var all: [Step]
        var longest: Step? { all.max { $0.duration < $1.duration } }
        /// The steps at least `duration` long, longest first.
        func over(_ duration: TimeInterval) -> [Step] {
            all.filter { $0.duration >= duration }.sorted { $0.duration > $1.duration }
        }
    }

    /// Steps at least this long are logged (0 = no log).
    private(set) var logThreshold: TimeInterval = 0
    /// Where logged stalls go (tests replace it).
    var log: (String) -> Void = { Log.write($0, level: .warning, source: "Stall") }

    private var observers: [CFRunLoopObserver] = []
    /// When the current step began (nil while the run loop sleeps).
    private var stepStart: UInt64?
    private var notes: [String] = []
    private var recordings: [[Step]] = []

    private var isActive: Bool { !observers.isEmpty }
    /// Whether the main run loop is watched (the log is on, or something records).
    var isWatching: Bool { isActive }

    /// Turns the log on or off from the user defaults (at launch).
    func configure(from defaults: UserDefaults) {
        setLogThreshold(Self.threshold(from: defaults.object(forKey: Self.defaultsKey)))
    }

    /// The threshold a `MainThreadStallLog` value asks for: milliseconds (a number or a string of one), YES for
    /// `defaultThreshold`; 0 (off) for anything else.
    static func threshold(from value: Any?) -> TimeInterval {
        guard let value else { return 0 }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? defaultThreshold : 0 }
            let ms = number.doubleValue
            return ms.isFinite && ms > 0 ? ms / 1000 : 0
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            if ["yes", "true"].contains(trimmed) { return defaultThreshold }
            if let ms = Double(trimmed), ms.isFinite, ms > 0 { return ms / 1000 }
        }
        return 0
    }

    func setLogThreshold(_ threshold: TimeInterval) {
        let wasLogging = logThreshold > 0
        logThreshold = threshold.isFinite ? max(threshold, 0) : 0
        updateObservers()
        if logThreshold > 0, !wasLogging {
            log("Main-thread stall log on: steps of \(Int((logThreshold * 1000).rounded())) ms or more are logged")
        }
    }

    /// Names what the main thread is doing now, for the step it is part of (a logged stall shows it). Cheap when
    /// nothing watches.
    static func note(_ text: @autoclosure () -> String) {
        let monitor = shared
        guard monitor.isActive, Thread.isMainThread else { return }
        if monitor.notes.count < 16 { monitor.notes.append(text()) }
    }

    /// Runs `body` (which runs the main run loop, or not) and returns the steps of the main thread meanwhile. The
    /// time from the call to the first run-loop activity, and from the last one to the return, are steps too.
    func record(_ body: () -> Void) -> Steps {
        precondition(Thread.isMainThread)
        recordings.append([])
        updateObservers()
        beginStep()
        body()
        endStep()
        beginStep()
        let steps = recordings.removeLast()
        updateObservers()
        return Steps(all: steps)
    }

    // MARK: Observing

    private func updateObservers() {
        let wanted = logThreshold > 0 || !recordings.isEmpty
        guard wanted != isActive else { return }
        let main = CFRunLoopGetMain()
        if !wanted {
            for observer in observers { CFRunLoopRemoveObserver(main, observer, .commonModes) }
            observers = []
            return
        }
        // Waking up starts a step, before any other observer; going to sleep or leaving the run loop ends it, after
        // every other observer (the display pass and Core Animation's commit, which also runs when the run loop is
        // left, are part of the step). The event loop leaves the run loop after every timer or event it handles.
        let first = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.afterWaiting, .entry]).rawValue, true,
                                                       CFIndex(Int32.min)) { [weak self] _, _ in
            self?.wake()
        }
        let last = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.beforeWaiting, .exit]).rawValue, true,
                                                      CFIndex(Int32.max)) { [weak self] _, activity in
            self?.endStep()
            // Leaving a run loop goes on with the code that ran it.
            if activity == .exit { self?.beginStep() }
        }
        observers = [first, last].compactMap { $0 }
        for observer in observers { CFRunLoopAddObserver(main, observer, .commonModes) }
        beginStep()
    }

    private func wake() {
        if stepStart == nil { beginStep() }
    }

    private func beginStep() {
        stepStart = DispatchTime.now().uptimeNanoseconds
    }

    private func endStep() {
        guard let start = stepStart else { return }
        stepStart = nil
        let duration = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
        let step = Step(duration: duration, notes: notes)
        notes.removeAll(keepingCapacity: true)
        for i in recordings.indices { recordings[i].append(step) }
        if logThreshold > 0, duration >= logThreshold {
            log("Main thread busy for \(Int((duration * 1000).rounded())) ms"
                + (step.notes.isEmpty ? "" : " (\(step.notes.joined(separator: "; ")))"))
        }
    }
}
