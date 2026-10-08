import AppKit
import ImageIO
import UniformTypeIdentifiers
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Real installed folders and offscreen windows qualify the worker/Main handoff without opening a user window.
enum DeskPackageActivationSelfTests {
    private typealias S = DeskConditionalTestSupport
    private enum Failure: Error { case fixture(String) }
    private struct Package {
        let directory: URL
        let sources: [DeskWidgetSourceState]
        let instances: [DeskWidgetInstanceState]
        let picture: Data
    }
    private final class Preparation {
        let release = DispatchSemaphore(value: 0)
        let calls = Guarded(0)
        let mainThreads = Guarded<[Bool]>([])
        let ready = Guarded(false)
        let folders = Guarded<[URL]>([])
        let heldCall: Int?
        init(heldCall: Int? = nil) { self.heldCall = heldCall }
        func prepare(_ source: DeskWidgetActivation.SourceKey, _ root: URL, _ options: DeskServiceOptions,
                     _ ticket: DeskWidgetActivation.Ticket) throws -> DeskWidgetActivation.Prepared {
            let call = calls.access { $0 += 1; return $0 }
            mainThreads.access { $0.append(Thread.isMainThread) }
            let result = try DeskWidgetActivation.prepare(source: source, widgetsRoot: root, options: options,
                                                         isCancelled: { ticket.isCancelled })
            if let folder = result.resources.folder { folders.access { $0.append(folder) } }
            if call == heldCall {
                ready.access { $0 = true }
                release.wait()
            }
            // Deliberately return a successfully prepared late result after cancellation. Main owns disposal.
            return result
        }
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk package activation: worker admission uses shared styles translations latest options and immutable private pictures") {
            let root = t.temporaryDirectory("desk-package-activate"), app = makeApp(t, root)
            let package = try install(app, duplicateMain: true), preparation = Preparation(heldCall: 1)
            app.prepareDeskWidgetActivation = preparation.prepare
            t.atSuiteEnd { preparation.release.signal() }
            var result: Result<DeskWidgetWindowController, Error>?, completions = 0
            app.activateDeskWidgetAsync(instanceID: package.instances[0].id, preferredLanguages: { ["fr"] }) {
                result = $0; completions += 1
            }
            t.check(AppSelfTest.spin(timeout: 10) { preparation.ready.current })
            guard preparation.ready.current else { throw Failure.fixture("worker did not reach handoff") }
            t.equal(app.pendingDeskWidgetActivationCount, 1)
            t.check(app.deskWidgetWindows.isEmpty)
            t.equal(app.state.deskInstance(package.instances[0].id)?.active, false)
            let latest = ProgramOptionsInput(values: ["show": .boolean(false)])
            try app.state.saveDeskOptions(package.instances[0].id, sourceID: package.sources[0].id,
                                          values: DeskProgramOptionStore.encode(latest))
            app.state.updateDeskInstance(package.instances[0].id) { $0.x = 17; $0.y = 23 }
            preparation.release.signal()
            let widget = try received(t, { result })
            try started(t, widget)
            t.equal(completions, 1); t.equal(app.pendingDeskWidgetActivationCount, 0)
            t.equal(S.texts(widget.latestPresented?.scene), ["Inactif"])
            t.equal(widget.optionsSnapshot?.values, latest)
            t.equal(widget.instance.x, 17); t.equal(widget.instance.y, 23)
            t.equal(app.state.deskInstance(widget.instance.id)?.active, true)
            let host = try host(widget)
            guard let prepared = widget.owner.prepared, let picture = prepared.images["Images/tile.png"] else {
                throw Failure.fixture("private image was not prepared")
            }
            t.equal(try Data(contentsOf: URL(fileURLWithPath: picture.path)), package.picture)
            t.check(!picture.path.hasPrefix(package.directory.path + "/"))
            t.equal(prepared.capture?.files.first(where: { $0.path == "Assets/unused.bin" })?.bytes, Data([0, 1, 2, 255]))
            t.check(prepared.capture?.directories.contains(where: { $0.path == "Empty" }) == true)
            let sibling = try activate(t, app, package.instances[1].id, languages: { ["fr"] })
            try started(t, sibling)
            t.equal(S.texts(sibling.latestPresented?.scene), ["Autre"])
            t.equal(sibling.latestPresented?.scene.hitMap.entries.first(where: { $0.toolTip != nil })?.toolTip,
                    ToolTipInfo(text: "Indice", title: "Détails"))
            let independent = try activate(t, app, package.instances[2].id, languages: { ["fr"] })
            try started(t, independent)
            guard let secondPicture = independent.owner.prepared?.images["Images/tile.png"] else {
                throw Failure.fixture("second instance private image")
            }
            t.check(secondPicture.path != picture.path)
            t.equal(try Data(contentsOf: URL(fileURLWithPath: secondPicture.path)), package.picture)
            t.equal(independent.optionsSnapshot?.values.values["show"], .boolean(true))
            t.check(preparation.mainThreads.current.allSatisfy { !$0 })

            // Qualification froze every member and asset. Later ticks and actions consume that snapshot even if
            // the installed folder has moved; only the private image collection remains a drawing prerequisite.
            let moved = root.appendingPathComponent("Moved")
            try FileManager.default.moveItem(at: package.directory, to: moved)
            try Data("widget {".utf8).write(to: moved.appendingPathComponent("A.desk"))
            try visible(t, widget); host.refresh(); try settle(t, widget)
            t.equal(S.texts(widget.latestPresented?.scene), ["Inactif"])
            guard let oldPart = widget.view.accessibilityParts.first(where: { $0.id.name == "toggle" }) else {
                throw Failure.fixture("accepted accessibility action missing")
            }
            try visible(t, widget)
            guard let beforeAction = widget.latestPresented?.scene.generation else {
                throw Failure.fixture("accepted action generation missing")
            }
            t.check(oldPart.accessibilityPerformPress()); try settle(t, widget, after: beforeAction)
            t.equal(S.texts(widget.latestPresented?.scene), ["Actif"])
            t.equal(widget.optionsSnapshot?.values.values["show"], .boolean(true))
            t.check(!oldPart.accessibilityPerformPress())
            t.equal(try Data(contentsOf: URL(fileURLWithPath: picture.path)), package.picture)
            try Data([1, 2, 3]).write(to: URL(fileURLWithPath: picture.path))
            host.refresh()
            t.check(AppSelfTest.spin(timeout: 10) { widget.lastUnavailableMessage != nil })
            t.equal(host.scene, nil); t.check(widget.latestPresented == nil)
            t.check(independent.latestPresented != nil, "another instance's private collection was not corrupted")
            t.equal(try Data(contentsOf: URL(fileURLWithPath: secondPicture.path)), package.picture)
            t.equal(completions, 1)
        }

        t.suite("App: Desk package activation: every member and package scope is admitted before a selected member can start") {
            for (packageText, siblingText, expected) in [
                (shared, "info { name: \"B\" }\nwidget {", DeskWidgetActivation.Failure.invalidPackage),
                (shared, "info { name: \"B\" }\nwidget { Label(\"Unsupported\", icon: \"wifi\") }", .compileFailed),
                (shared + "\noptions { global = Toggle(\"Shared\") }", sibling, .compileFailed),
                ("style shared { .font(cpu.coreCount) }", sibling, .compileFailed)
            ] {
                let root = t.temporaryDirectory("desk-package-denied"), app = makeApp(t, root)
                let package = try install(app, packageText: packageText, siblingText: siblingText)
                var result: Result<DeskWidgetWindowController, Error>?, callbacks = 0
                app.activateDeskWidgetAsync(instanceID: package.instances[0].id) { result = $0; callbacks += 1 }
                t.check(AppSelfTest.spin(timeout: 10) { result != nil })
                guard case .failure(let error)? = result else { throw Failure.fixture("incomplete package admitted") }
                t.equal(error as? DeskWidgetActivation.Failure, expected)
                t.equal(callbacks, 1); t.equal(app.pendingDeskWidgetActivationCount, 0)
                t.check(app.deskWidgetWindows.isEmpty)
                t.equal(app.state.deskInstance(package.instances[0].id)?.active, false)
                t.equal(try Data(contentsOf: package.directory.appendingPathComponent("A.desk")), Data(main.utf8))
            }
        }

        t.suite("App: Desk package activation: cancellation supersession termination and named root replacement discard late resources once") {
            for action in ["deactivate", "cancel", "supersede", "terminate", "replace"] {
                let root = t.temporaryDirectory("desk-package-late"), app = makeApp(t, root)
                let package = try install(app), preparation = Preparation(heldCall: 1)
                app.prepareDeskWidgetActivation = preparation.prepare
                t.atSuiteEnd { preparation.release.signal() }
                let id = package.instances[0].id
                var first: Result<DeskWidgetWindowController, Error>?, second: Result<DeskWidgetWindowController, Error>?
                var firstCalls = 0, secondCalls = 0
                let ticket = app.activateDeskWidgetAsync(instanceID: id) { first = $0; firstCalls += 1 }
                t.check(AppSelfTest.spin(timeout: 10) { preparation.ready.current }, action)
                guard preparation.ready.current, let folder = preparation.folders.current.first else {
                    throw Failure.fixture("late resources not captured")
                }
                t.check(FileManager.default.fileExists(atPath: folder.path))
                switch action {
                case "deactivate": app.deactivateDeskWidget(instanceID: id)
                case "cancel": ticket.cancel()
                case "supersede": app.activateDeskWidgetAsync(instanceID: id) { second = $0; secondCalls += 1 }
                case "terminate": _ = app.stopAllForTermination(budget: 0)
                case "replace":
                    try FileManager.default.moveItem(at: package.directory, to: root.appendingPathComponent("Old"))
                    try FileManager.default.createDirectory(at: package.directory, withIntermediateDirectories: false)
                default: throw Failure.fixture("invalid action")
                }
                preparation.release.signal()
                t.check(AppSelfTest.spin(timeout: 10) {
                    first != nil && !FileManager.default.fileExists(atPath: folder.path) &&
                        (action != "supersede" || second != nil)
                }, action)
                guard case .failure(let error)? = first else { throw Failure.fixture("late result published: " + action) }
                t.equal(error as? DeskWidgetActivation.Failure, .cancelled, action)
                t.equal(firstCalls, 1, action)
                t.equal(app.pendingDeskWidgetActivationCount, 0, action)
                if action == "supersede" {
                    let replacement = try received(t, { second }); try started(t, replacement)
                    t.equal(secondCalls, 1); t.equal(app.deskWidgetWindows.count, 1)
                    t.check(replacement.owner.prepared?.folder != folder)
                } else {
                    t.check(app.deskWidgetWindows.isEmpty, action)
                    t.equal(app.state.deskInstance(id)?.active, false, action)
                }
            }
        }

        t.suite("App: Desk package activation: cancelling a superseded request may reenter activation without losing the newest completion") {
            let root = t.temporaryDirectory("desk-package-reentrant"), app = makeApp(t, root)
            let package = try install(app), preparation = Preparation(heldCall: 1)
            app.prepareDeskWidgetActivation = preparation.prepare
            t.atSuiteEnd { preparation.release.signal() }
            let id = package.instances[0].id
            var first: Result<DeskWidgetWindowController, Error>?
            var second: Result<DeskWidgetWindowController, Error>?
            var newest: Result<DeskWidgetWindowController, Error>?
            var firstCalls = 0, secondCalls = 0, newestCalls = 0
            var newestTicket: DeskWidgetActivation.Ticket?
            let firstTicket = app.activateDeskWidgetAsync(instanceID: id) { result in
                t.check(Thread.isMainThread)
                first = result; firstCalls += 1
                if case .failure(let error) = result,
                   (error as? DeskWidgetActivation.Failure) == .cancelled {
                    newestTicket = app.activateDeskWidgetAsync(instanceID: id) {
                        t.check(Thread.isMainThread)
                        newest = $0; newestCalls += 1
                    }
                }
            }
            t.check(AppSelfTest.spin(timeout: 10) { preparation.ready.current })
            guard preparation.ready.current, let abandoned = preparation.folders.current.first else {
                throw Failure.fixture("first activation did not prepare private pictures")
            }
            t.check(FileManager.default.fileExists(atPath: abandoned.path))
            // B supersedes held A. A's cancellation completion starts C while B is being issued.
            // Keep the real file worker held until C exists; queue ordering, rather than timing, selects C.
            let secondTicket = app.activateDeskWidgetAsync(instanceID: id) {
                t.check(Thread.isMainThread)
                second = $0; secondCalls += 1
            }
            t.check(AppSelfTest.spin(timeout: 10) { newestTicket != nil })
            t.check(firstTicket.isCancelled)
            preparation.release.signal()
            t.check(AppSelfTest.spin(timeout: 10) {
                app.deskWidgetWindows[id] != nil && !FileManager.default.fileExists(atPath: abandoned.path)
            })
            t.equal(firstCalls, 1)
            t.equal(secondCalls, 1)
            t.equal(newestCalls, 1, "the request created by the cancellation callback must also finish")
            for (name, result) in [("A", first), ("B", second)] {
                if case .failure(let error)? = result {
                    t.equal(error as? DeskWidgetActivation.Failure, .cancelled, name)
                } else { t.check(false, name + " must be cancelled") }
            }
            t.check(secondTicket.isCancelled, "C supersedes B")
            t.equal(newestTicket?.isCancelled, false)
            t.equal(app.pendingDeskWidgetActivationCount, 0)
            t.equal(app.deskWidgetWindows.count, 1)
            t.equal(preparation.calls.current, 2, "only held A and final C prepare resources")
            if case .success(let selected)? = newest {
                try started(t, selected)
                t.check(app.deskWidgetWindows[id] === selected, "only C may own the installed instance")
                guard let retained = selected.owner.prepared?.folder else {
                    throw Failure.fixture("final activation lost its private collection")
                }
                t.check(retained != abandoned)
                t.check(FileManager.default.fileExists(atPath: retained.path))
                for folder in preparation.folders.current where folder != retained {
                    t.check(!FileManager.default.fileExists(atPath: folder.path))
                }
                t.equal(app.state.deskInstance(id)?.active, true)
            } else { t.check(false, "C must return the final controller") }
            app.deactivateDeskWidget(instanceID: id)
            t.check(AppSelfTest.spin(timeout: 10) {
                app.deskWidgetWindows.isEmpty && preparation.folders.current.allSatisfy {
                    !FileManager.default.fileExists(atPath: $0.path)
                }
            })
            t.equal(firstCalls, 1); t.equal(secondCalls, 1); t.equal(newestCalls, 1)
            t.check(preparation.mainThreads.current.allSatisfy { !$0 })
        }

        t.suite("App: Desk package activation: normal quit drain awaits held private copies and skips cancelled queued work") {
            let root = t.temporaryDirectory("desk-package-activation-drain"), app = makeApp(t, root)
            let package = try install(app, duplicateMain: true), preparation = Preparation(heldCall: 1)
            app.prepareDeskWidgetActivation = preparation.prepare
            t.atSuiteEnd { preparation.release.signal() }
            var results: [UUID: Result<DeskWidgetWindowController, Error>] = [:]
            var callbacks: [UUID: Int] = [:]
            func completion(_ id: UUID) -> (Result<DeskWidgetWindowController, Error>) -> Void {
                { result in
                    t.check(Thread.isMainThread)
                    results[id] = result
                    callbacks[id, default: 0] += 1
                }
            }
            let first = package.instances[0].id, queued = package.instances[1].id, unstarted = package.instances[2].id
            let firstTicket = app.activateDeskWidgetAsync(instanceID: first, completion: completion(first))
            t.check(AppSelfTest.spin(timeout: 10) { preparation.ready.current })
            guard preparation.ready.current, let folder = preparation.folders.current.first else {
                throw Failure.fixture("held private collection missing")
            }
            t.check(FileManager.default.fileExists(atPath: folder.path))
            // B has entered its Main begin turn and queued behind the held file worker. C has not begun at all.
            let queuedTicket = app.activateDeskWidgetAsync(instanceID: queued, completion: completion(queued))
            var beganQueuedRequest = false
            DispatchQueue.main.async { beganQueuedRequest = true }
            t.check(AppSelfTest.spin(timeout: 10) { beganQueuedRequest })
            let unstartedTicket = app.activateDeskWidgetAsync(instanceID: unstarted, completion: completion(unstarted))
            _ = app.stopAllForTermination(budget: 0)
            t.equal(app.pendingDeskWidgetActivationCount, 0, "request removal is not file-worker retirement")
            t.check([firstTicket, queuedTicket, unstartedTicket].allSatisfy { $0.isCancelled })
            var firstDrain = 0, secondDrain = 0
            app.cancelDeskWidgetActivationsAndDrain {
                t.check(Thread.isMainThread)
                t.check(!FileManager.default.fileExists(atPath: folder.path), "copies precede the drain ACK")
                firstDrain += 1
            }
            app.cancelDeskWidgetActivationsAndDrain { secondDrain += 1 }
            t.equal(firstDrain, 0); t.equal(secondDrain, 0)
            // Process cancellation completions and C's queued begin without releasing A. No timed wait is used.
            var cancelledOnMain = false
            DispatchQueue.main.async { cancelledOnMain = true }
            t.check(AppSelfTest.spin(timeout: 10) { cancelledOnMain })
            t.equal(firstDrain, 0); t.equal(secondDrain, 0)
            t.check(FileManager.default.fileExists(atPath: folder.path))
            t.equal(preparation.calls.current, 1)
            for instance in package.instances {
                t.equal(callbacks[instance.id], 1)
                if case .failure(let error)? = results[instance.id] {
                    t.equal(error as? DeskWidgetActivation.Failure, .cancelled)
                } else { t.check(false, "every cancelled activation completes once") }
            }
            preparation.release.signal()
            t.check(AppSelfTest.spin(timeout: 10) { firstDrain == 1 && secondDrain == 1 })
            t.check(!FileManager.default.fileExists(atPath: folder.path))
            t.equal(preparation.calls.current, 1, "cancelled queued work never enters package preparation")
            t.equal(preparation.folders.current, [folder])
            t.check(preparation.mainThreads.current.allSatisfy { !$0 })
            t.check(app.deskWidgetWindows.isEmpty)
            t.check(package.instances.allSatisfy { app.state.deskInstance($0.id)?.active == false })
            var alreadyDrained = 0
            app.cancelDeskWidgetActivationsAndDrain { alreadyDrained += 1 }
            t.equal(alreadyDrained, 1, "completed cleanup may acknowledge a new observer immediately")
            var afterAcknowledgement = false
            DispatchQueue.main.async { afterAcknowledgement = true }
            t.check(AppSelfTest.spin(timeout: 10) { afterAcknowledgement })
            t.equal(firstDrain, 1); t.equal(secondDrain, 1)
            for instance in package.instances { t.equal(callbacks[instance.id], 1) }
        }

        t.suite("App: Desk package activation: restart restores independent members and reports all failed members after the asynchronous batch") {
            let root = t.temporaryDirectory("desk-package-restart"), first = makeApp(t, root)
            let good = try install(first)
            let bad = try install(first, siblingText: "info { name: \"B\" }\nwidget {")
            for instance in good.instances + bad.instances { first.state.updateDeskInstance(instance.id) { $0.active = true } }
            try first.state.saveDeskOptions(good.instances[0].id, sourceID: good.sources[0].id,
                values: DeskProgramOptionStore.encode(.init(values: ["show": .boolean(false)])))
            first.state.saveNow()
            let app = makeApp(t, root), preparation = Preparation()
            app.prepareDeskWidgetActivation = preparation.prepare
            var completed = 0
            app.loadActiveDeskWidgets { completed += 1 }
            t.check(AppSelfTest.spin(timeout: 10) { completed == 1 })
            t.equal(app.pendingDeskWidgetActivationCount, 0)
            t.equal(Set(app.deskWidgetWindows.keys), Set(good.instances.map(\.id)))
            for instance in good.instances { guard let widget = app.deskWidgetWindows[instance.id] else {
                throw Failure.fixture("good restoration missing")
            }; try started(t, widget) }
            t.equal(app.deskWidgetWindows[good.instances[0].id]?.optionsSnapshot?.values.values["show"], .boolean(false))
            t.equal(Set(app.deskRestorationFailures.map(\.entry)), Set(bad.sources.map(\.entry)))
            t.check(app.lastAlert?.text.contains(bad.sources[0].entry) == true)
            t.check(app.lastAlert?.text.contains(bad.sources[1].entry) == true)
            t.check((good.instances + bad.instances).allSatisfy { app.state.deskInstance($0.id)?.active == true })
            t.check(preparation.mainThreads.current.allSatisfy { !$0 })
            t.equal(completed, 1)
        }

        t.suite("App: Desk package activation: language reload waits for owner close and uses the latest preference and accepted option values") {
            let root = t.temporaryDirectory("desk-package-language"), app = makeApp(t, root)
            let package = try install(app), preparation = Preparation(heldCall: 2)
            app.prepareDeskWidgetActivation = preparation.prepare
            let worker = SkinThreadExecutor(name: "Desk package activation fixture")
            t.atSuiteEnd { worker.stop() }
            // This cleanup precedes the worker stop (LIFO) so close can drain on that real owner.
            t.atSuiteEnd {
                _ = app.stopAllForTermination()
                _ = AppSelfTest.spin(timeout: 10) { app.deskWidgetWindows.values.allSatisfy(\.isClosed) }
            }
            let ownerRelease = DispatchSemaphore(value: 0), ownerHeld = Guarded(false)
            t.atSuiteEnd { preparation.release.signal(); ownerRelease.signal() }
            app.skinExecutor = { _ in worker }
            var languages = ["en"]
            let old = try activate(t, app, package.instances[0].id, languages: { languages }); try started(t, old)
            let oldSession = old.sessionID, oldFolder = preparation.folders.current.first
            let oldPart = old.view.accessibilityParts.first(where: { $0.id.name == "toggle" })
            worker.async { ownerHeld.access { $0 = true }; ownerRelease.wait() }
            t.check(AppSelfTest.spin(timeout: 10) { ownerHeld.current })
            languages = ["fr"]
            old.refreshDateInput()
            t.check(old.isClosing); t.check(!old.isClosed)
            t.check(old.sessionID != oldSession)
            t.equal(oldPart?.accessibilityPerformPress(), false)
            t.equal(preparation.calls.current, 1, "no worker package read precedes the old close ACK")
            ownerRelease.signal()
            t.check(AppSelfTest.spin(timeout: 10) { preparation.ready.current })
            t.check(old.isClosed)
            if let oldFolder { t.check(!FileManager.default.fileExists(atPath: oldFolder.path)) }
            // Change again after the second capture. Its result must be discarded, then a third attempt may hand off.
            languages = ["fr-CA"]
            let latest = ProgramOptionsInput(values: ["show": .boolean(false)])
            try app.state.saveDeskOptions(old.instance.id, sourceID: old.source.id, values: DeskProgramOptionStore.encode(latest))
            app.deskOptionDrafts[old.instance.id] = .init(sourceID: old.source.id, values: latest)
            preparation.release.signal()
            t.check(AppSelfTest.spin(timeout: 10) {
                app.deskWidgetWindows[old.instance.id].map { $0 !== old && $0.isStarted && $0.latestPresented != nil } == true
            })
            guard let next = app.deskWidgetWindows[old.instance.id], next !== old else {
                throw Failure.fixture("language reload did not replace the session")
            }
            t.equal(preparation.calls.current, 3)
            t.equal(S.texts(next.latestPresented?.scene), ["Inactif"])
            t.equal(next.optionsSnapshot?.values, latest)
            t.check(next.sessionID != oldSession)
            t.equal(oldPart?.accessibilityPerformPress(), false)
            t.equal(app.state.deskInstance(old.instance.id)?.active, true)
            let folders = preparation.folders.current
            t.equal(folders.count, 3)
            if folders.count == 3 {
                t.check(!FileManager.default.fileExists(atPath: folders[1].path))
                t.check(FileManager.default.fileExists(atPath: folders[2].path))
            }
            t.check(preparation.mainThreads.current.allSatisfy { !$0 })
            let cancelled = Preparation(heldCall: 1)
            app.prepareDeskWidgetActivation = cancelled.prepare
            t.atSuiteEnd { cancelled.release.signal() }
            languages = ["en"]
            next.refreshDateInput()
            t.check(AppSelfTest.spin(timeout: 10) { cancelled.ready.current })
            guard let abandoned = cancelled.folders.current.first else { throw Failure.fixture("reload collection") }
            app.deactivateDeskWidget(instanceID: next.instance.id)
            t.equal(app.state.deskInstance(next.instance.id)?.active, false)
            cancelled.release.signal()
            t.check(AppSelfTest.spin(timeout: 10) {
                app.pendingDeskWidgetActivationCount == 0 && !FileManager.default.fileExists(atPath: abandoned.path)
            })
            t.check(app.deskWidgetWindows.isEmpty, "late reload cannot reactivate an explicitly removed member")
        }
    }

    private static let shared = """
    style shared { .font(12).color(.blue).tooltip("Package hint", title: "Package title") }
    translations {
        "fr" {
            "On": "Actif"
            "Off": "Inactif"
            "Sibling": "Autre"
            "Package hint": "Indice"
            "Package title": "Détails"
        }
    }
    """
    private static let main = """
    info { name: "A" }
    options { show = Toggle("Show", default: true) }
    widget { Column(spacing: 0, align: .left) {
        Image("Images/tile.png").size(16, 12)
        Text(options.show ? "On" : "Off").style(shared).size(80, 24).name(toggle)
            .voiceOver("Toggle").onClick { options.show = not options.show }
    } }
    """
    private static let sibling = """
    info { name: "B" }
    widget { Text("Sibling").style(shared).size(80, 24) }
    """

    private static func makeApp(_ t: AppTestRunner, _ root: URL) -> AppController {
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
            skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
            backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
            settingsDirectory: root.appendingPathComponent("Settings"), widgetsDirectory: root.appendingPathComponent("Widgets"),
            presentsWindows: false)
        t.atSuiteEnd {
            _ = app.stopAllForTermination()
            _ = AppSelfTest.spin(timeout: 10) { app.deskWidgetWindows.values.allSatisfy(\.isClosed) }
            app.endEngineThread()
        }
        return app
    }

    private static func install(_ app: AppController, packageText: String = shared, siblingText: String = sibling,
                                duplicateMain: Bool = false) throws -> Package {
        let packageID = UUID(), directory = app.widgetsDirectory.appendingPathComponent(packageID.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        for (name, text) in [("package.desk", packageText), ("A.desk", main), ("B.desk", siblingText)] {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        let picture = try png()
        try picture.write(to: directory.appendingPathComponent("Images/tile.png"))
        try Data([0, 1, 2, 255]).write(to: directory.appendingPathComponent("Assets/unused.bin"))
        let sources = ["A.desk", "B.desk"].map {
            DeskWidgetSourceState(id: UUID(), entry: packageID.uuidString.lowercased() + "/" + $0, packageID: packageID)
        }
        var instances = sources.map { DeskWidgetInstanceState(id: UUID(), sourceID: $0.id) }
        if duplicateMain { instances.append(DeskWidgetInstanceState(id: UUID(), sourceID: sources[0].id)) }
        try app.state.registerDeskInstallation(sources: sources, instances: instances)
        return Package(directory: directory, sources: sources, instances: instances, picture: picture)
    }

    private static func png() throws -> Data {
        let pixels = Data(Array(repeating: [UInt8(0), 120, 240, 255], count: 8 * 6).flatMap { $0 })
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                space: SkinFrameProducer.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.fixture("PNG image")
        }
        let bytes = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.fixture("PNG destination")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw Failure.fixture("PNG finalize") }
        return bytes as Data
    }

    private static func received(_ t: AppTestRunner, _ result: () -> Result<DeskWidgetWindowController, Error>?) throws -> DeskWidgetWindowController {
        t.check(AppSelfTest.spin(timeout: 10) { result() != nil })
        guard let result = result() else { throw Failure.fixture("activation did not complete") }
        return try result.get()
    }
    private static func activate(_ t: AppTestRunner, _ app: AppController, _ id: UUID,
                                 languages: @escaping () -> [String] = { ["en"] }) throws -> DeskWidgetWindowController {
        var result: Result<DeskWidgetWindowController, Error>?
        app.activateDeskWidgetAsync(instanceID: id, preferredLanguages: languages) { result = $0 }
        return try received(t, { result })
    }
    private static func started(_ t: AppTestRunner, _ widget: DeskWidgetWindowController) throws {
        t.check(AppSelfTest.spin(timeout: 10) { widget.isStarted && widget.latestPresented != nil })
        guard widget.isStarted, widget.latestPresented != nil else { throw Failure.fixture("first presentation") }
        t.check(!widget.window.isVisible)
    }
    private static func host(_ widget: DeskWidgetWindowController) throws -> DeskProgramHost {
        guard let result = widget.owner.host else { throw Failure.fixture("Main host unavailable") }
        return result
    }
    private static func visible(_ t: AppTestRunner, _ widget: DeskWidgetWindowController) throws {
        var drained = false
        widget.executor.async { DispatchQueue.main.async { drained = true } }
        t.check(AppSelfTest.spin(timeout: 10) { drained })
        let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
            scale: widget.window.backingScaleFactor, program: widget.program, preferredLanguages: ["fr"])
        guard let space = widget.window.colorSpace?.cgColorSpace else { throw Failure.fixture("destination profile") }
        let facts = SkinWindowFacts(frame: widget.window.frame, isVisible: true, isOrderedIn: true,
            scale: widget.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
            takesPointer: true, sequence: 100, panelGeneration: widget.destinationEpoch)
        widget.owner.take(facts, input: input)
        try settle(t, widget)
    }
    private static func settle(_ t: AppTestRunner, _ widget: DeskWidgetWindowController,
                               after generation: UInt64? = nil) throws {
        let host = try host(widget)
        t.check(AppSelfTest.spin(timeout: 10) {
            host.frames.runLoopTurn(.beforeWaiting)
            return !host.frames.hasBitmapDelivery && host.scene != nil &&
                (generation.map { (host.scene?.generation ?? 0) > $0 } ?? true) &&
                host.scene?.generation == host.presented?.scene.generation &&
                host.presented?.scene.generation == widget.latestPresented?.scene.generation
        }, "scene/presented/Main generations: \(String(describing: host.scene?.generation))/" +
            "\(String(describing: host.presented?.scene.generation))/\(String(describing: widget.latestPresented?.scene.generation))")
    }
}
