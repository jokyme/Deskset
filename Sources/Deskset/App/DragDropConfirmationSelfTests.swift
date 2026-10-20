import AppKit
import DesksetCore

enum DragDropConfirmationSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: DragDrop confirmation: presentation identifies files with a bounded batch summary") {
            let one = FileTrashConfirmation.presentation(paths: ["/temporary/Report.txt"])
            t.check(one.message.contains("Report.txt"))
            t.check(one.detail.contains("restore"))
            let many = FileTrashConfirmation.presentation(paths: ["/temporary/One.txt", "/temporary/Two.txt"])
            t.check(many.message.contains("2 items"))
            t.check(many.detail.contains("One.txt") && many.detail.contains("Two.txt"))
            let large = FileTrashConfirmation.presentation(paths: (1...100).map { "/temporary/File\($0).txt" })
            t.check(large.message.contains("100 items"), "the count covers every selected file")
            t.equal(large.detail.components(separatedBy: "\n").count, 9, "the summary stays bounded")
            t.check(large.detail.contains("File8.txt") && large.detail.contains("92 more items"))
        }

        t.suite("App: DragDrop confirmation: a runtime without a window declines once") {
            let root = t.temporaryDirectory("dragdrop-no-window")
            let runtime = SkinRuntime(config: "Headless", file: "Headless.ini", skinsDirectory: root)
            var answers: [Bool] = []
            runtime.skin(runtime.skin, confirmFileTrash: ["/temporary/No operation.txt"]) { answers.append($0) }
            t.equal(answers, [false])
            runtime.send(.close(fadeOut: false))
        }

        for mode in [SkinThreading.main, .engine, .pool] {
            headlessTests(t, mode: mode)
            queueAndCloseTests(t, mode: mode)
        }
    }

    private static func headlessTests(_ t: AppTestRunner, mode: SkinThreading) {
        t.suite("App: DragDrop confirmation: headless windows decline on the owner executor (\(mode))") {
            guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return }
            defer { app.stopAllForTermination(); app.endEngineThread() }
            try writeFixture(app)
            guard let controller = app.activate(config: "DragDrop\\Confirm", file: "Confirm.ini") else {
                return t.check(false, "fixture loads")
            }
            t.check(AppSelfTest.spin { controller.isStarted })
            let runtime = controller.runtime
            let answers = Guarded<[Answer]>([])
            runtime.executor.async {
                runtime.skin(runtime.skin, confirmFileTrash: ["/temporary/Not trashed.txt"]) { confirmed in
                    answers.access { $0.append(Answer(label: "headless", confirmed: confirmed,
                                                     onOwner: runtime.executor.isCurrent)) }
                }
            }
            t.check(AppSelfTest.spin { answers.current.count == 1 })
            t.equal(answers.current, [Answer(label: "headless", confirmed: false, onOwner: true)])
            t.equal(controller.companions.openFileTrashConfirmations, 0)
        }
    }

    private static func queueAndCloseTests(_ t: AppTestRunner, mode: SkinThreading) {
        t.suite("App: DragDrop confirmation: replies are serialized once and close cancels the queue (\(mode))") {
            guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return }
            defer { app.stopAllForTermination(); app.endEngineThread() }
            try writeFixture(app)
            guard let controller = app.activate(config: "DragDrop\\Confirm", file: "Confirm.ini") else {
                return t.check(false, "fixture loads")
            }
            t.check(AppSelfTest.spin { controller.isStarted })
            var prompts: [FakeConfirmation] = []
            var mainPresentations: [Bool] = []
            SkinWindowCompanions.fileTrashPromptFactory = { _ in
                mainPresentations.append(Thread.isMainThread)
                let prompt = FakeConfirmation()
                prompts.append(prompt)
                return prompt
            }
            defer { SkinWindowCompanions.fileTrashPromptFactory = nil }
            let runtime = controller.runtime
            let answers = Guarded<[Answer]>([])
            runtime.executor.async {
                for label in ["first", "second", "third", "fourth"] {
                    runtime.skin(runtime.skin, confirmFileTrash: ["/temporary/\(label).txt"]) { confirmed in
                        answers.access { $0.append(Answer(label: label, confirmed: confirmed,
                                                         onOwner: runtime.executor.isCurrent)) }
                    }
                }
            }
            t.check(AppSelfTest.spin { controller.companions.openFileTrashConfirmations == 4 })
            t.equal(prompts.count, 1, "one sheet is presented at a time")
            guard let first = prompts.first else { return }
            t.equal(first.paths, ["/temporary/first.txt"])
            let initialWindowChanges = first.windowChanges
            controller.companions.windowChanged()
            t.equal(first.windowChanges, initialWindowChanges + 1, "the active confirmation follows window changes")
            first.answer(true)
            t.check(AppSelfTest.spin { answers.current.count == 1 && prompts.count == 2 })
            t.equal(answers.current, [Answer(label: "first", confirmed: true, onOwner: true)])
            first.answer(false)
            t.equal(prompts.count, 2, "a duplicate completion cannot advance the queue")
            guard prompts.count >= 2 else { return }
            prompts[1].answer(false)
            t.check(AppSelfTest.spin { answers.current.count == 2 && prompts.count == 3 })
            t.equal(answers.current, [Answer(label: "first", confirmed: true, onOwner: true),
                                      Answer(label: "second", confirmed: false, onOwner: true)])
            t.equal(mainPresentations, [true, true, true], "presentation stays on the main thread")
            guard prompts.count >= 3 else { return }
            let third = prompts[2]
            controller.stop(keepsWindow: true)
            t.check(AppSelfTest.spin { runtime.didClose })
            t.equal(third.cancellations, 1, "a retained replacement window still closes its active prompt")
            t.equal(controller.companions.openFileTrashConfirmations, 0, "queued prompts are discarded")
            third.answer(true)
            runtime.send(.fileTrashAnswered(id: 3, confirmed: true))
            _ = runtime.exclusive(timeout: 30) { _ in () }
            t.equal(answers.current.count, 2, "neither a stale presenter nor a late reply runs closed callbacks")
            t.equal(prompts.count, 3, "the fourth prompt was never opened")
            controller.companions.tearDown()
            t.equal(third.cancellations, 1, "teardown is idempotent")
            let changesAfterTeardown = third.windowChanges
            controller.companions.windowChanged()
            t.equal(third.windowChanges, changesAfterTeardown, "a torn-down confirmation no longer follows the window")
            controller.closeReplacedWindow(by: controller)
        }
    }

    private static func writeFixture(_ app: AppController) throws {
        let folder = app.skinsDirectory.appendingPathComponent("DragDrop/Confirm", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
            [Rainmeter]
            Update=-1
            [Meter]
            Meter=Shape
            Shape=Rectangle 0,0,100,40
            """.write(to: folder.appendingPathComponent("Confirm.ini"), atomically: true, encoding: .utf8)
        app.rescanLibrary()
    }

    private struct Answer: Equatable {
        var label: String
        var confirmed: Bool
        var onOwner: Bool
    }

    private final class FakeConfirmation: FileTrashConfirming {
        private var completion: ((Bool) -> Void)?
        private(set) var paths: [String] = []
        private(set) var cancellations = 0
        private(set) var windowChanges = 0

        func show(paths: [String], completion: @escaping (Bool) -> Void) {
            self.paths = paths
            self.completion = completion
        }
        func answer(_ confirmed: Bool) { completion?(confirmed) }
        func cancel() { cancellations += 1 }
        func windowChanged() { windowChanges += 1 }
    }
}
