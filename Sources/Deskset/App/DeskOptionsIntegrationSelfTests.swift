import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

enum DeskOptionsIntegrationSelfTests {
    private typealias S = DeskConditionalTestSupport
    private enum Failure: Error { case fixture(String), write }

    private static let source = """
    options {
        show = Toggle("Show", default: true)
        amount = Slider("Amount", min: 1, max: 20, default: 2)
        title = Input("Title", default: "Start")
        look = Picker("Look", [Choice(.mono, "One color"), Choice(.full, "Full color")])
    }
    widget { variable count = 0
        Text("{options.title} / {options.amount} / {count}").size(250, 40).name(label)
            .onClick { count = count + 1; options.title = "Clicked" }
    }
    """

    private static func replacing(_ input: ProgramOptionsInput, _ name: String, _ value: ProgramOptionValue) -> ProgramOptionsInput {
        var values = input.values
        values[name] = value
        return .init(values: values)
    }

    static func run(_ t: AppTestRunner) {
        storage(t)
        host(t)
        preview(t)
        session(t)
        desktop(t)
    }

    private static func storage(_ t: AppTestRunner) {
        t.suite("App: Desk options: typed records survive restart with isolated instances and visible write failure") {
            let program = try S.program(source)
            let initial = try DeskProgramOptionStore.restore([:], for: program)
            let root = t.temporaryDirectory("desk-options-storage")
            let url = root.appendingPathComponent("state.json")
            let state = AppState(fileURL: url)
            let firstSource = UUID(), secondSource = UUID(), first = UUID(), second = UUID()
            for (source, instance) in [(firstSource, first), (secondSource, second)] {
                try state.registerDeskInstallation(source: .init(id: source, entry: source.uuidString.lowercased() + "/Widget.desk"),
                    instance: .init(id: instance, sourceID: source))
            }
            let firstValue = replacing(initial.input, "title", .string("A \"quoted\" 中文 😀\nline"))
            let secondValue = replacing(initial.input, "look", .localCase(option: "look", name: "full"))
            try state.saveDeskOptions(first, sourceID: firstSource, values: DeskProgramOptionStore.encode(firstValue))
            try state.saveDeskOptions(second, sourceID: secondSource, values: DeskProgramOptionStore.encode(secondValue))
            let reloaded = AppState(fileURL: url)
            t.equal(try DeskProgramOptionStore.restore(reloaded.deskInstance(first)?.optionValues ?? [:], for: program).input, firstValue)
            t.equal(try DeskProgramOptionStore.restore(reloaded.deskInstance(second)?.optionValues ?? [:], for: program).input, secondValue)
            t.equal(try DeskProgramOptionStore.restore([:], for: program).input, initial.input)
            var malformed = try DeskProgramOptionStore.encode(firstValue)
            malformed["show"] = .object(["version": .number(2), "kind": .string("bool"), "value": .bool(false)])
            malformed["amount"] = .object(["version": .number(1), "kind": .string("number"),
                "dimension": .string("plain"), "value": .number(99)])
            malformed["look"] = .object(["version": .number(1), "kind": .string("case"),
                "option": .string("other"), "value": .string("full")])
            let recovered = try DeskProgramOptionStore.restore(malformed, for: program)
            t.equal(recovered.restoredNames, Set(["show", "amount", "look"]))
            t.equal(recovered.input.values["title"], firstValue.values["title"], "one corrupt value does not discard its neighbors")
            for key in recovered.restoredNames { t.equal(recovered.input.values[key], initial.input.values[key]) }
            let before = state.deskInstance(first)
            let original = try Data(contentsOf: url)
            let backup = root.appendingPathComponent("saved-state.json")
            try FileManager.default.moveItem(at: url, to: backup)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            var failed = false
            do { try state.saveDeskOptions(first, sourceID: firstSource, values: DeskProgramOptionStore.encode(secondValue)) }
            catch { failed = true }
            t.check(failed, "a directory at the state path deterministically rejects the atomic write")
            t.equal(state.deskInstance(first), before, "failed disk writes do not advance durable in-memory state")
            t.equal(try Data(contentsOf: backup), original)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: backup, to: url)
            var wrongSource = false
            do { try state.saveDeskOptions(first, sourceID: secondSource, values: [:]) } catch { wrongSource = true }
            t.check(wrongSource)
            t.equal(state.deskInstance(first), before)
            let oversized = replacing(initial.input, "title", .string(String(repeating: "x", count: DeskProgramOptionStore.maximumValueBytes)))
            var limited = false
            do { _ = try DeskProgramOptionStore.encode(oversized) } catch { limited = true }
            t.check(limited, "encoded record overhead counts toward the value limit")
        }
    }

    private static func host(_ t: AppTestRunner) {
        t.suite("App: Desk options: region refresh republishes formatted panel metadata without changing option revision") {
            let program = try S.program("""
            options { title = Input("Value {2.5}") }
            widget { Text("A").size(40, 30) }
            """)
            let time = try S.clock(), input = S.input(), provider = S.Provider()
            let host = try DeskProgramHost(program: program, executor: time, provider: provider,
                input: input, clock: time.clock, system: S.System())
            t.atSuiteEnd { host.close(); time.runUntilIdle() }
            var snapshots: [ProgramOptionsSnapshot] = []
            host.didChangeOptions = { snapshots.append($0) }
            host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame(); S.flush(host, time)
            guard case .option(let first)? = snapshots.last?.items.first else { throw Failure.fixture("initial option title") }
            t.equal(first.title, "Value 2.5")
            let region = DeskProgramHost.Input(environment: input.environment, colors: input.colors,
                                                locale: Locale(identifier: "de_DE"))
            host.take(S.facts(region), input: region); S.flush(host, time)
            guard case .option(let next)? = snapshots.last?.items.first else { throw Failure.fixture("regional option title") }
            t.equal(next.title, "Value 2,5")
            t.equal(snapshots.map(\.revision), [0, 0])
            t.equal(try host.optionsSnapshot(), snapshots.last)
        }

        t.suite("App: Desk options: host updates preserve variables and reject stale or failed candidates") {
            let program = try S.program(source)
            let time = try S.clock(), provider = S.Provider(), input = S.input()
            let host = try DeskProgramHost(program: program, executor: time, provider: provider,
                input: input, clock: time.clock, system: S.System())
            t.atSuiteEnd { host.close(); time.runUntilIdle() }
            var snapshots: [ProgramOptionsSnapshot] = []
            host.didChangeOptions = { snapshots.append($0) }
            host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame(); S.flush(host, time)
            t.equal(S.texts(host.scene), ["Start / 2 / 0"])
            _ = try S.click(host, "label"); S.flush(host, time)
            t.equal(S.texts(host.scene), ["Clicked / 2 / 1"])
            let old = try host.optionsSnapshot()
            t.equal(old.values.values["title"], .string("Clicked"))
            t.equal(old.revision, 1)
            var replies: [Result<ProgramOptionsSnapshot, Error>] = []
            host.updateOptions(replacing(old.values, "amount", .number(.init(7, dimension: .plain))),
                               expectedRevision: old.revision) { replies.append($0) }
            S.flush(host, time)
            t.equal(replies.count, 1)
            t.equal(try replies[0].get().revision, 2)
            t.equal(S.texts(host.scene), ["Clicked / 7 / 1"], "panel changes do not restart variables")
            let accepted = host.scene?.generation
            host.updateOptions(old.values, expectedRevision: old.revision) { replies.append($0) }
            t.equal(replies.count, 2)
            if case .failure(let error) = replies[1] { t.equal(error as? DeskProgramHost.Failure, .staleOptions) }
            else { t.check(false, "stale option revision must fail") }
            t.equal(host.scene?.generation, accepted)
            t.equal(host.state, .ready)
            let current = try host.optionsSnapshot()
            host.updateOptions(replacing(current.values, "amount", .number(.init(500, dimension: .plain))),
                               expectedRevision: current.revision) { replies.append($0) }
            t.equal(replies.count, 3)
            if case .success = replies[2] { t.check(false, "range failure must not commit") } else { t.check(true) }
            t.equal(try host.optionsSnapshot(), current)
            t.equal(host.scene?.generation, accepted)
            t.equal(S.texts(host.scene), ["Clicked / 7 / 1"])
            t.equal(snapshots.map(\.revision), [0, 1, 2])
        }

        t.suite("App: Desk options: pending symbol changes cancel cleanly and resource failures keep accepted pixels") {
            let program = try S.program("""
            options { red = Toggle("Red") }
            widget { Icon("star.fill").size(40, 40).color("#0000FF").color("#FF0000", if: options.red) }
            """)
            let time = try S.clock(), provider = S.Provider(), prepare = S.Preparation(), input = S.input()
            let host = try DeskProgramHost(program: program, executor: time, provider: provider,
                input: input, clock: time.clock, system: S.System(), prepareIcons: prepare.submit)
            t.atSuiteEnd { host.close(); time.runUntilIdle() }
            host.take(S.facts(input), input: input); host.start(); host.drawFirstFrame()
            t.equal(prepare.calls.count, 1)
            try prepare.succeed(0); S.flush(host, time)
            let first = try host.optionsSnapshot(), pixels = try S.bytes(provider.image())
            var replies: [Result<ProgramOptionsSnapshot, Error>] = []
            let red = replacing(first.values, "red", .boolean(true))
            host.updateOptions(red, expectedRevision: first.revision) { replies.append($0) }
            t.check(host.isPreparingIcons); t.equal(replies.count, 0)
            t.equal(try prepare.call(0).demands.first?.request.style.color, S.blue)
            t.equal(try prepare.call(1).demands.first?.request.style.color, S.red)
            t.equal(try host.optionsSnapshot(), first)
            t.equal(try S.bytes(provider.image()), pixels)
            host.updateOptions(first.values, expectedRevision: first.revision) { replies.append($0) }
            t.equal(replies.count, 2)
            if case .failure(let error) = replies[0] { t.equal(error as? DeskProgramHost.Failure, .optionsCancelled) }
            else { t.check(false, "the cancelled transaction must report failure exactly once") }
            try prepare.succeed(1); S.flush(host, time)
            t.equal(replies.count, 2)
            t.equal(try host.optionsSnapshot(), first)
            t.equal(try S.bytes(provider.image()), pixels)
            host.updateOptions(red, expectedRevision: first.revision) { replies.append($0) }
            t.equal(prepare.calls.count, 3)
            try prepare.fail(2); S.flush(host, time)
            t.equal(replies.count, 3)
            t.equal(host.state, .ready)
            t.equal(try host.optionsSnapshot(), first)
            t.equal(try S.bytes(provider.image()), pixels)
            t.check(!host.isPreparingIcons)
        }
    }

    private static func preview(_ t: AppTestRunner) {
        t.suite("App: Desk options: preview drafts survive language reload without changing source or desktop settings") {
            let file = DeskFileID(path: "Options.desk")
            let text = """
            translations { "zh-Hans" { "Title": "标题" } }
            """ + "\n" + source
            let service = DeskLanguageService(openFile: file, files: [file: text])
            let time = try S.clock()
            var languages = ["en"]
            var acceptanceCalls = 0, rejectAcceptance: Int?
            let p = DeskProgramPreviewController(clock: time.clock, executor: time, preferredLanguages: { languages },
                system: S.System(), presentsTooltips: false, presentsMenus: false, presentsOptions: false) {
                acceptanceCalls += 1
                return acceptanceCalls != rejectAcceptance && $0.file == file && $0.tree.version == service.snapshot.tree.version
            }
            let window = NSWindow(contentViewController: p)
            t.atSuiteEnd { p.close(); window.close(); time.runUntilIdle() }
            p.show(service.snapshot, readError: nil); p.setVisible(true)
            t.equal(p.state, .ready)
            let old = try p.optionsSnapshot()
            var reply: Result<ProgramOptionsSnapshot, Error>?
            p.updateOptions(replacing(old.values, "title", .string("Draft")), expectedRevision: old.revision) { reply = $0 }
            t.equal(try reply?.get().values.values["title"], .string("Draft"))
            t.equal(S.texts(p.scene), ["Draft / 2 / 0"])
            p.showOptions()
            t.check(p.optionsSession != nil)
            languages = ["zh-Hans"]
            p.refreshDateInput()
            t.equal(try p.optionsSnapshot().values.values["title"], .string("Draft"))
            t.check(p.optionsSession == nil, "a language reload retires the previous panel lease")
            t.equal(S.texts(p.scene), ["Draft / 2 / 0"])
            t.equal(service.snapshot.text, text)
            t.equal(p.recordedEffects, [])
            // The first two checks admit the request and its initial projection; the final source check retires
            // it before commit. It has not entered an asynchronous pending slot, but still owes one reply.
            acceptanceCalls = 0; rejectAcceptance = 3
            let beforeRetirement = try p.optionsSnapshot()
            var retiredReplies = 0
            p.updateOptions(replacing(beforeRetirement.values, "title", .string("Retired")),
                            expectedRevision: beforeRetirement.revision) { result in
                retiredReplies += 1
                if case .success = result { t.check(false, "source retirement must reject the option update") }
                else { t.check(true) }
            }
            t.equal(retiredReplies, 1, "a preflight retirement finishes even before a pending resource slot exists")
            rejectAcceptance = nil
            t.equal(try p.optionsSnapshot(), beforeRetirement)
            p.showOptions()
            guard let panelSession = p.optionsSession,
                  let row = panelSession.panel.pageView.itemView("title") as? StudioRowView,
                  let input = row.numberBox, let panelWindow = panelSession.panel.window else {
                throw Failure.fixture("preview closing editor")
            }
            t.check(panelWindow.makeFirstResponder(input.field))
            guard let editor = input.field.currentEditor() as? NSTextView else { throw Failure.fixture("preview field editor") }
            editor.string = String(repeating: "x", count: 32_769)
            t.check(!panelSession.panel.windowShouldClose(panelWindow))
            t.check(p.optionsSession === panelSession && !panelSession.isClosed,
                    "a synchronous rejected final field stays open with its error")
            t.equal(panelSession.panel.feedbackLabel.stringValue, StudioText[.deskOptionsChangeFailed])
            t.equal(try p.optionsSnapshot(), beforeRetirement)
            input.type("Fixed")
            p.optionsSession?.requestClose()
            t.check(p.optionsSession == nil, "preview panel close requires no persistence service")
        }
    }

    private static func session(_ t: AppTestRunner) {
        t.suite("App: Desk options: synchronous final field rejection cancels both native and requested close") {
            let program = try S.program(source), environment = S.input().environment
            let defaults = try ProgramOptionsSchema(options: program.options).defaults
            for nativeClose in [true, false] {
                var runtime = try ProgramRuntime(program: program)
                let original = try runtime.resolveOptions()
                var saves = 0, replies = 0
                let session = DeskProgramOptionsSession(snapshot: original, defaults: defaults, isPreview: true,
                    presentsWindows: false, update: { input, revision, completion in
                        replies += 1
                        do {
                            guard try runtime.updateOptions(input, expectedRevision: revision, environment: environment,
                                measure: { _, _, _ in SkinSize(width: 60, height: 12) }) != nil else {
                                throw DeskProgramHost.Failure.staleOptions
                            }
                            completion(.success(try runtime.resolveOptions()))
                        } catch { completion(.failure(error)) }
                    }, save: { _ in saves += 1 }, moreStyles: {})
                t.atSuiteEnd { session.close() }
                guard let row = session.panel.pageView.itemView("title") as? StudioRowView,
                      let input = row.numberBox, let window = session.panel.window else {
                    throw Failure.fixture("synchronous close editor")
                }
                t.check(window.makeFirstResponder(input.field))
                guard let editor = input.field.currentEditor() as? NSTextView else { throw Failure.fixture("synchronous field editor") }
                editor.string = String(repeating: "x", count: 32_769)
                if nativeClose { t.check(!session.panel.windowShouldClose(window)) }
                else { session.requestClose() }
                t.equal(replies, 1); t.equal(saves, 0)
                t.check(!session.isClosed)
                t.equal(session.snapshot, original)
                t.equal(session.panel.feedbackLabel.stringValue, StudioText[.deskOptionsChangeFailed])
                input.type("Fixed")
                t.equal(replies, 2); t.equal(saves, 0)
                t.check(!session.isClosed, "a rejected close is not retried by a later successful edit")
                session.requestClose()
                t.equal(saves, 1); t.check(session.isClosed)
            }
        }

        t.suite("App: Desk options: panel close waits for accepted changes and keeps unsaved settings on write failure") {
            let program = try S.program(source)
            let runtime = try ProgramRuntime(program: program)
            let original = try runtime.resolveOptions(), defaults = try ProgramOptionsSchema(options: program.options).defaults
            var saveAttempts = 0, failSave = true
            var requests: [(input: ProgramOptionsInput, revision: UInt64,
                            finish: (Result<ProgramOptionsSnapshot, Error>) -> Void)] = []
            var expected = original.values
            let session = DeskProgramOptionsSession(snapshot: original, defaults: defaults, isPreview: false,
                presentsWindows: false, update: { requests.append(($0, $1, $2)) }, save: { input in
                    t.equal(input, expected)
                    saveAttempts += 1
                    if failSave { throw Failure.write }
                }, moreStyles: {})
            t.atSuiteEnd { session.close() }
            func edit(_ name: String, _ value: ProgramOptionValue) {
                session.panel.onChange?(.init(id: UUID(), lease: session.lease, revision: session.snapshot.revision,
                                              name: name, value: value, finished: true))
            }
            func accepted(_ input: ProgramOptionsInput, revision: UInt64) throws -> ProgramOptionsSnapshot {
                let resolved = try ProgramRuntime(program: program, options: input).resolveOptions()
                return .init(revision: revision, values: resolved.values, items: resolved.items)
            }
            edit("title", .string("First"))
            edit("title", .string("Latest"))
            edit("amount", .number(.init(7, dimension: .plain)))
            t.equal(requests.count, 1)
            session.requestClose()
            t.equal(saveAttempts, 0, "close waits for pending accepted values")
            let first = try accepted(requests[0].input, revision: 1)
            session.receive(first)
            requests[0].finish(.success(first))
            t.check(AppSelfTest.spin(timeout: 2) { requests.count == 2 })
            guard requests.count == 2 else { return }
            t.equal(requests[1].revision, 1)
            t.equal(requests[1].input.values["title"], .string("Latest"))
            t.equal(requests[1].input.values["amount"], .number(.init(7, dimension: .plain)))
            guard let row = session.panel.pageView.itemView("title") as? StudioRowView,
                  let field = row.numberBox?.field, let window = session.panel.window else {
                throw Failure.fixture("input while close awaits resources")
            }
            t.check(window.makeFirstResponder(field))
            guard let editor = field.currentEditor() as? NSTextView else { throw Failure.fixture("late field editor") }
            editor.string = "Typed while closing"
            expected = requests[1].input
            let second = try accepted(expected, revision: 2)
            session.receive(second)
            requests[1].finish(.success(second))
            t.check(AppSelfTest.spin(timeout: 2) { requests.count == 3 })
            guard requests.count == 3 else { return }
            t.equal(saveAttempts, 0, "the final field-editor flush is accepted before saving")
            t.equal(requests[2].input.values["title"], .string("Typed while closing"))
            expected = requests[2].input
            let third = try accepted(expected, revision: 3)
            session.receive(third)
            requests[2].finish(.success(third))
            t.check(AppSelfTest.spin(timeout: 2) { saveAttempts == 1 })
            t.equal(saveAttempts, 1)
            t.check(!session.isClosed)
            failSave = false
            session.requestClose()
            t.equal(saveAttempts, 2)
            t.check(session.isClosed)
            session.requestClose()
            t.equal(saveAttempts, 2, "a closed panel never saves again")
        }
    }

    private static func desktop(_ t: AppTestRunner) {
        t.suite("App: Desk options: native desktop menu edits save per instance and survive language session replacement") {
            let root = t.temporaryDirectory("desk-options-desktop"), stateURL = root.appendingPathComponent("state.json")
            let app = AppController(state: AppState(fileURL: stateURL),
                skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                settingsDirectory: root.appendingPathComponent("Settings"), widgetsDirectory: root.appendingPathComponent("Widgets"),
                presentsWindows: false)
            t.atSuiteEnd { _ = app.stopAllForTermination(); app.endEngineThread() }
            var languages = ["en"]
            func install() throws -> DeskWidgetWindowController {
                let sourceID = UUID(), instanceID = UUID(), directory = app.widgetsDirectory.appendingPathComponent(sourceID.uuidString.lowercased())
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(source.utf8).write(to: directory.appendingPathComponent("Widget.desk"))
                try app.state.registerDeskInstallation(source: .init(id: sourceID, entry: sourceID.uuidString.lowercased() + "/Widget.desk"),
                    instance: .init(id: instanceID, sourceID: sourceID))
                return try app.activateDeskWidget(instanceID: instanceID, preferredLanguages: { languages })
            }
            let first = try install(), second = try install()
            t.check(AppSelfTest.spin(timeout: 10) { first.isStarted && second.isStarted && first.optionsSnapshot != nil })
            guard first.isStarted, second.isStarted else { throw Failure.fixture("initial desktop options frames") }
            let input = try DeskWidgetWindowController.makeInput(for: first.window.effectiveAppearance,
                scale: first.window.backingScaleFactor, program: first.program, preferredLanguages: languages)
            guard let space = first.window.colorSpace?.cgColorSpace else { throw Failure.fixture("desktop color space") }
            // Match the existing desktop action fixture: only the owner receives controlled visible facts;
            // no native window is ordered in, and production facts continue to describe the real window.
            let facts = SkinWindowFacts(frame: first.window.frame, isVisible: true, isOrderedIn: true,
                scale: first.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
                takesPointer: true, sequence: 100, panelGeneration: first.destinationEpoch)
            var delivered = false
            first.owner.executor.async { [owner = first.owner] in
                owner.take(facts, input: input)
                owner.host?.frames.runLoopTurn(.beforeWaiting)
                DispatchQueue.main.async { delivered = true }
            }
            t.check(AppSelfTest.spin(timeout: 10) { delivered })
            var menu: NSMenu?
            first.view.contextMenuPresenterForTesting = { shown, _ in menu = shown }
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [.option],
                timestamp: 1, windowNumber: first.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw Failure.fixture("context menu event")
            }
            first.view.rightMouseDown(with: event)
            guard let item = menu?.items.first(where: { $0.title == StudioText[.deskOptions] }), let action = item.action else {
                throw Failure.fixture("native Options menu entry")
            }
            NSApp.sendAction(action, to: item.target, from: item)
            guard let options = first.optionsSession else { throw Failure.fixture("desktop options panel") }
            options.panel.onChange?(.init(id: UUID(), lease: options.lease, revision: options.snapshot.revision,
                name: "title", value: .string("First instance"), finished: true))
            t.check(AppSelfTest.spin(timeout: 10) { first.optionsSnapshot?.values.values["title"] == .string("First instance") })
            t.check(AppSelfTest.spin(timeout: 10) { S.texts(first.latestPresented?.scene) == ["First instance / 2 / 0"] })
            t.equal(second.optionsSnapshot?.values.values["title"], .string("Start"))
            t.equal(app.state.deskInstance(first.instance.id)?.optionValues, [:], "an open panel keeps its accepted draft unsaved")
            options.requestClose()
            t.check(AppSelfTest.spin(timeout: 10) { first.optionsSession == nil })
            let persisted = AppState(fileURL: stateURL)
            t.equal(try DeskProgramOptionStore.restore(persisted.deskInstance(first.instance.id)?.optionValues ?? [:],
                for: first.program).input.values["title"], .string("First instance"))
            t.equal(persisted.deskInstance(second.instance.id)?.optionValues, [:])
            first.showOptions()
            guard let draft = first.optionsSession else { throw Failure.fixture("reopened options") }
            draft.panel.onChange?(.init(id: UUID(), lease: draft.lease, revision: draft.snapshot.revision,
                name: "title", value: .string("Language draft"), finished: true))
            t.check(AppSelfTest.spin(timeout: 10) { first.optionsSnapshot?.values.values["title"] == .string("Language draft") })
            languages = ["zh-Hans"]
            first.refreshDateInput()
            t.check(AppSelfTest.spin(timeout: 10) {
                guard let replacement = app.deskWidgetWindows[first.instance.id], replacement !== first else { return false }
                return replacement.isStarted && replacement.optionsSnapshot != nil
            })
            guard let replacement = app.deskWidgetWindows[first.instance.id], replacement !== first else {
                throw Failure.fixture("language replacement")
            }
            t.check(first.isClosed && draft.isClosed)
            t.equal(replacement.optionsSnapshot?.values.values["title"], .string("Language draft"))
            t.equal(S.texts(replacement.latestPresented?.scene), ["Language draft / 2 / 0"])
            t.equal(second.optionsSnapshot?.values.values["title"], .string("Start"))
            let before = replacement.optionsSnapshot
            draft.panel.onChange?(.init(id: UUID(), lease: draft.lease, revision: draft.snapshot.revision,
                name: "title", value: .string("Stale"), finished: true))
            t.equal(replacement.optionsSnapshot, before)
        }
    }
}
