import AppKit
import DesksetCore

/// Modifier, timer and prompt fixtures never read the person's keys or show a modal recovery dialog.
enum SafeStartControllerSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Safe Start: ordinary startup does not wait for the manual hold") {
            let f = Fixture()
            f.begin()
            t.equal(f.answers, [false])
            t.equal(f.scheduler.entries.count, 0)
            t.equal(f.prompter.replies.count, 0)
            t.check(f.completedOnMain)
        }

        t.suite("App: Safe Start: Control and Shift are required together") {
            for flags: NSEvent.ModifierFlags in [[], .control, .shift, .command, [.command, .shift], [.control, .option]] {
                let f = Fixture()
                f.flags = flags
                f.begin()
                t.equal(f.answers, [false], "\(flags.rawValue): no manual offer")
                t.equal(f.scheduler.entries.count, 0)
            }
            for flags: NSEvent.ModifierFlags in [[.control, .shift], [.control, .shift, .capsLock],
                                                [.control, .shift, .option], [.control, .shift, .command]] {
                let f = Fixture()
                f.flags = flags
                f.begin()
                t.check(f.answers.isEmpty)
                f.time += 1
                f.scheduler.fire()
                t.equal(f.prompter.replies.count, 1)
                f.prompter.reply(true)
                t.equal(f.answers, [true])
            }
        }

        t.suite("App: Safe Start: a continuous one-second hold offers once at the boundary") {
            let f = Fixture()
            f.flags = [.control, .shift]
            f.begin()
            t.equal(f.scheduler.entries.map(\.interval), [SafeStartController.samplingInterval])
            f.time += 0.999
            f.scheduler.fire()
            t.equal(f.prompter.replies.count, 0)
            t.check(f.answers.isEmpty)
            f.time = 101
            f.scheduler.fire()
            t.equal(f.prompter.replies.count, 1)
            t.check(f.scheduler.entries[0].work.isCancelled)
            f.scheduler.fire(bypassCancellation: true)
            t.equal(f.prompter.replies.count, 1, "an old timer cannot open another offer")
            f.prompter.reply(false)
            t.equal(f.answers, [false], "Cancel chooses normal startup")
        }

        t.suite("App: Safe Start: releasing either key ends the manual attempt") {
            for releasedFlags: NSEvent.ModifierFlags in [[], .control, .shift, [.command, .shift]] {
                let f = Fixture()
                f.flags = [.control, .shift]
                f.begin()
                f.time += 0.4
                f.flags = releasedFlags
                f.scheduler.fire()
                t.equal(f.answers, [false])
                t.check(f.scheduler.entries[0].work.isCancelled)
                f.flags = [.control, .shift]
                f.time += 2
                f.scheduler.fire(bypassCancellation: true)
                t.equal(f.prompter.replies.count, 0, "pressing again does not revive the startup attempt")
                t.equal(f.answers, [false])
            }
        }

        t.suite("App: Safe Start: two recent crashes offer without a modifier delay") {
            for count in [-1, 0, 1, 2, 3] {
                let f = Fixture()
                f.begin(count: count)
                t.equal(f.scheduler.entries.count, 0)
                if count >= 2 {
                    t.check(f.answers.isEmpty)
                    t.equal(f.prompter.replies.count, 1)
                    f.prompter.reply(true)
                    t.equal(f.answers, [true])
                } else {
                    t.equal(f.answers, [false])
                    t.equal(f.prompter.replies.count, 0)
                }
            }
        }

        t.suite("App: Safe Start: automatic and manual triggers share one offer") {
            for release in [false, true] {
                let f = Fixture()
                f.flags = [.control, .shift]
                f.begin(count: 2)
                f.time += release ? 0.2 : 1
                if release { f.flags = [] }
                f.scheduler.fire()
                t.equal(f.prompter.replies.count, 1, "a released manual chord must not hide crash recovery")
                f.time += 2
                f.scheduler.fire(bypassCancellation: true)
                f.prompter.reply(true)
                f.prompter.reply(false)
                t.equal(f.answers, [true])
                t.equal(f.prompter.replies.count, 1)
            }
        }

        t.suite("App: Safe Start: a completed manual hold survives a slow watcher and later key release") {
            let f = Fixture(), counter = CrashCounter()
            f.flags = [.control, .shift]
            f.begin(counter: counter)
            t.equal(counter.replies.count, 1, "watcher loading starts alongside modifier sampling")
            t.equal(f.scheduler.entries.count, 1)
            f.time += 1
            f.scheduler.fire()
            t.check(f.scheduler.entries[0].work.isCancelled)
            t.check(f.answers.isEmpty)
            t.equal(f.prompter.replies.count, 0, "startup waits for the watcher handshake")
            f.flags = []
            f.time += 6
            f.scheduler.fire(bypassCancellation: true)
            counter.reply(0)
            t.equal(f.prompter.replies.count, 1, "the earned manual qualification is retained")
            f.prompter.reply(true)
            t.equal(f.answers, [true])
        }

        t.suite("App: Safe Start: a slow watcher alone decides ordinary or automatic startup") {
            for count in [0, 2] {
                let f = Fixture(), counter = CrashCounter()
                f.begin(counter: counter)
                t.check(f.answers.isEmpty)
                t.equal(f.scheduler.entries.count, 0, "no arbitrary modifier delay when the chord was not held")
                t.equal(f.prompter.replies.count, 0)
                counter.reply(count)
                if count >= 2 {
                    t.equal(f.prompter.replies.count, 1)
                    f.prompter.reply(false)
                }
                t.equal(f.answers, [false])
            }
        }

        t.suite("App: Safe Start: releasing during a slow watcher still allows its crash recovery offer") {
            for watcherFirst in [false, true] {
                let f = Fixture(), counter = CrashCounter()
                f.flags = [.control, .shift]
                f.begin(counter: counter)
                if watcherFirst { counter.reply(2) }
                t.equal(f.prompter.replies.count, 0, "both decisions must complete before an offer")
                f.time += 0.2
                f.flags = .control
                f.scheduler.fire()
                if !watcherFirst {
                    t.equal(f.prompter.replies.count, 0)
                    counter.reply(2)
                }
                t.equal(f.prompter.replies.count, 1)
                f.scheduler.fire(bypassCancellation: true)
                counter.reply(2)
                t.equal(f.prompter.replies.count, 1)
                f.prompter.reply(true)
                t.equal(f.answers, [true])
            }
        }

        t.suite("App: Safe Start: only the first watcher answer belongs to the startup attempt") {
            for count in [0, 2] {
                let f = Fixture(), counter = CrashCounter()
                f.begin(counter: counter)
                counter.reply(count)
                counter.reply(count == 0 ? 2 : 0)
                if count >= 2 {
                    t.equal(f.prompter.replies.count, 1)
                    f.prompter.reply(true)
                    t.equal(f.answers, [true])
                } else {
                    t.equal(f.prompter.replies.count, 0)
                    t.equal(f.answers, [false])
                }
                let g = Fixture(), pending = CrashCounter()
                g.flags = [.control, .shift]
                g.begin(counter: pending)
                pending.reply(count)
                pending.reply(count == 0 ? 2 : 0)
                g.flags = []
                g.scheduler.fire()
                if count >= 2 {
                    t.equal(g.prompter.replies.count, 1, "duplicate count cannot replace an active recovery decision")
                    g.prompter.reply(true)
                    t.equal(g.answers, [true])
                } else {
                    t.equal(g.prompter.replies.count, 0)
                    t.equal(g.answers, [false], "duplicate count cannot replace a pending normal decision")
                }
            }
        }

        t.suite("App: Safe Start: late watcher answers cannot revive a cancelled manual attempt") {
            let f = Fixture(), counter = CrashCounter()
            f.flags = [.control, .shift]
            f.begin(counter: counter)
            f.time += 1
            f.scheduler.fire()
            f.controller.cancel()
            counter.reply(2)
            counter.reply(0)
            f.scheduler.fire(bypassCancellation: true)
            t.check(f.answers.isEmpty)
            t.equal(f.prompter.replies.count, 0)
        }

        t.suite("App: Safe Start: background watcher results return to the main-thread decision") {
            let f = Fixture(), counter = CrashCounter()
            f.begin(counter: counter)
            let reply = counter.replies[0]
            DispatchQueue.global().async { reply(0) }
            t.check(AppSelfTest.spin { f.answers == [false] })
            t.check(f.completedOnMain)
            counter.reply(2)
            t.equal(f.answers, [false])
        }

        t.suite("App: Safe Start: lifecycle cancellation while sampling calls neither startup path") {
            let f = Fixture()
            f.flags = [.control, .shift]
            f.begin(count: 2)
            f.controller.cancel()
            f.controller.cancel()
            t.check(f.scheduler.entries[0].work.isCancelled)
            f.time += 2
            f.scheduler.fire(bypassCancellation: true)
            t.check(f.answers.isEmpty)
            t.equal(f.prompter.replies.count, 0)
        }

        t.suite("App: Safe Start: cancellation closes a pending prompt and rejects late answers") {
            let f = Fixture()
            f.begin(count: 2)
            f.controller.cancel()
            t.equal(f.prompter.closures, 1)
            f.prompter.reply(true)
            f.prompter.reply(false)
            t.check(f.answers.isEmpty)
        }

        t.suite("App: Safe Start: termination while closing a prompt cannot continue startup") {
            let f = Fixture()
            f.begin(count: 2)
            f.prompter.onClose = { [weak f] in f?.controller.cancel() }
            f.prompter.reply(true)
            t.check(f.answers.isEmpty, "cancelling during native prompt teardown wins over a pending answer")
            f.prompter.reply(false)
            t.check(f.answers.isEmpty)
            t.equal(f.prompter.closures, 1)
        }

        t.suite("App: Safe Start: repeated begin and repeated answers never complete twice") {
            let f = Fixture()
            f.begin(count: 2)
            var otherAnswers = 0
            f.controller.begin(recentCrashCount: 2) { _ in otherAnswers += 1 }
            t.equal(f.prompter.replies.count, 1)
            f.prompter.reply(false)
            f.prompter.reply(true)
            f.controller.begin(recentCrashCount: 2) { _ in otherAnswers += 1 }
            t.equal(f.answers, [false])
            t.equal(otherAnswers, 0)
            f.controller.cancel()
            t.equal(f.answers, [false])
        }

        t.suite("App: Safe Start: cancellation before begin cannot later start the app") {
            let f = Fixture()
            f.controller.cancel()
            f.begin(count: 2)
            t.check(f.answers.isEmpty)
            t.equal(f.prompter.replies.count, 0)
        }

        t.suite("App: Safe Start: synchronous prompt replies and scheduling callbacks remain single-use") {
            let f = Fixture()
            f.prompter.inlineAnswer = true
            f.begin(count: 2)
            t.equal(f.answers, [true])
            f.prompter.reply(false)
            t.equal(f.answers, [true])
            let g = Fixture()
            g.flags = [.control, .shift]
            g.scheduler.inline = true
            g.scheduler.onSchedule = { [weak g] in g?.controller.cancel() }
            g.begin()
            t.check(g.scheduler.entries[0].work.isCancelled)
            g.time += 1
            g.scheduler.fire(bypassCancellation: true)
            t.check(g.answers.isEmpty)
            t.equal(g.prompter.replies.count, 0)
        }

        t.suite("App: Safe Start: background prompt replies complete only on the main thread") {
            let f = Fixture()
            f.begin(count: 2)
            let reply = f.prompter.replies[0]
            DispatchQueue.global().async { reply(true) }
            t.check(AppSelfTest.spin { f.answers == [true] })
            t.check(f.completedOnMain)
            f.prompter.reply(false)
            t.equal(f.answers, [true])
        }

        t.suite("App: Safe Start: injected timer callbacks sample only on the main thread") {
            let f = Fixture()
            f.flags = [.control, .shift]
            f.begin()
            f.time += 1
            let sample = f.scheduler.entries[0].callback
            DispatchQueue.global().async { sample() }
            t.check(AppSelfTest.spin { f.prompter.replies.count == 1 })
            f.prompter.reply(true)
            t.equal(f.answers, [true])
            t.check(f.completedOnMain)
        }

        t.suite("App: Safe Start: a queued answer cannot survive lifecycle cancellation") {
            let f = Fixture()
            f.begin(count: 2)
            let reply = f.prompter.replies[0]
            let queued = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { reply(true); queued.signal() }
            t.equal(queued.wait(timeout: .now() + 2), .success)
            f.controller.cancel()
            AppSelfTest.spin(timeout: 0.02) { false }
            t.check(f.answers.isEmpty)
        }

        t.suite("App: Safe Start: releasing the controller cancels its timer and pending prompt") {
            let scheduler = ManualScheduler(), prompter = Prompter()
            weak var weakController: SafeStartController?
            var completions = 0
            do {
                let controller = SafeStartController(flags: { [] }, schedule: scheduler.schedule, prompt: prompter.show)
                weakController = controller
                controller.begin(recentCrashCount: 2) { _ in completions += 1 }
            }
            t.check(weakController == nil)
            t.equal(prompter.closures, 1)
            prompter.reply(true)
            t.equal(completions, 0)
            do {
                let controller = SafeStartController(flags: { [.control, .shift] }, clock: { 0 },
                    schedule: scheduler.schedule, prompt: prompter.show)
                weakController = controller
                controller.begin(recentCrashCount: 0) { _ in completions += 1 }
            }
            t.check(weakController == nil)
            t.check(scheduler.entries.last?.work.isCancelled == true)
            scheduler.fire(bypassCancellation: true)
            t.equal(completions, 0)
        }

        t.suite("App: Safe Start: a corrected or invalid injected clock cannot complete a hold early") {
            let f = Fixture()
            f.flags = [.control, .shift]
            f.begin()
            f.time = 99
            f.scheduler.fire()
            f.time = 99.999
            f.scheduler.fire()
            t.equal(f.prompter.replies.count, 0)
            f.time = 100
            f.scheduler.fire()
            t.equal(f.prompter.replies.count, 1)
            f.controller.cancel()
            let g = Fixture()
            g.flags = [.control, .shift]
            g.time = .nan
            g.begin()
            t.equal(g.answers, [false])
            t.equal(g.scheduler.entries.count, 0)
        }

        t.suite("App: Safe Start: the prompt describes recovery and offers two actions") {
            // Constructing NSAlert itself requests the system icon service, even with an explicit icon.
            // Keep headless checks on the same presentation consumed by the native prompt.
            let presentation = SafeStartController.promptPresentation
            t.equal(presentation.title, "Deskset Safe Start")
            t.check(presentation.text.contains("bundled default layout"))
            t.check(presentation.text.contains("@Backup") && presentation.text.contains("skin files will be kept"))
            t.equal(presentation.buttons, ["Safe Start", "Cancel"])
        }
    }

    private final class ManualScheduler {
        struct Entry {
            var interval: TimeInterval
            var callback: () -> Void
            var work: SkinScheduledWork
        }
        var entries: [Entry] = []
        var onSchedule: (() -> Void)?
        var inline = false

        func schedule(_ interval: TimeInterval, _ callback: @escaping () -> Void) -> SkinScheduledWork {
            let work = SkinScheduledWork(repeats: true, callback)
            entries.append(Entry(interval: interval, callback: callback, work: work))
            if inline { work.fire() }
            onSchedule?()
            return work
        }

        func fire(bypassCancellation: Bool = false) {
            guard let entry = entries.last else { return }
            if bypassCancellation { entry.callback() }
            else { entry.work.fire() }
        }
    }

    private final class Prompter {
        var replies: [(Bool) -> Void] = []
        var closures = 0
        var inlineAnswer: Bool?
        var onClose: (() -> Void)?

        func show(_ reply: @escaping (Bool) -> Void) -> () -> Void {
            replies.append(reply)
            if let inlineAnswer { reply(inlineAnswer) }
            return { [weak self] in self?.closures += 1; self?.onClose?() }
        }

        func reply(_ accepted: Bool) { replies.last?(accepted) }
    }

    private final class CrashCounter {
        var replies: [(Int) -> Void] = []
        func load(_ reply: @escaping (Int) -> Void) { replies.append(reply) }
        func reply(_ count: Int) { replies.last?(count) }
    }

    private final class Fixture {
        var flags: NSEvent.ModifierFlags = []
        var time: TimeInterval = 100
        let scheduler = ManualScheduler()
        let prompter = Prompter()
        var answers: [Bool] = []
        var completedOnMain = true
        lazy var controller = SafeStartController(flags: { [weak self] in self?.flags ?? [] },
            clock: { [weak self] in self?.time ?? 0 }, schedule: scheduler.schedule, prompt: prompter.show)

        func begin(count: Int = 0) {
            controller.begin(recentCrashCount: count) { [weak self] accepted in
                self?.completedOnMain = (self?.completedOnMain ?? true) && Thread.isMainThread
                self?.answers.append(accepted)
            }
        }

        func begin(counter: CrashCounter) {
            controller.begin(loadCrashCount: counter.load) { [weak self] accepted in
                self?.completedOnMain = (self?.completedOnMain ?? true) && Thread.isMainThread
                self?.answers.append(accepted)
            }
        }
    }
}
