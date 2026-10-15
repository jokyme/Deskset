import AppKit
import DeskLanguage
import DesksetCore

/// Real package editor/install/menu paths, using only scratch sources, state and installed directories.
enum DeskPackageFlowSelfTests {
    private enum Failure: Error { case fixture }
    private static let mainText = "\u{FEFF}info { name: \"First\" }\r\nwidget { Text(\"First\").style(label) }\r\n"
    private static let otherText = "info { name: \"Second\" }\nwidget { Text(\"Second\").style(label) }\n"
    private static let manifest = """
    package {
        name: "Local widgets"
        deskVersion: 1
    }
    style label { .font(20).color(.red) }
    translations { "zh-Hans" { "First": "第一个"; "Second": "第二个" } }
    """

    private struct Fixture {
        let root: URL
        let source: URL
        let app: AppController
        let input: DeskCodePackageInput
    }

    private static func fixture(_ t: AppTestRunner) throws -> Fixture {
        let root = t.temporaryDirectory("desk-package-flow"), source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Empty/Nested"), withIntermediateDirectories: true)
        for (name, text) in [("First.desk", mainText), ("Second.desk", otherText), ("package.desk", manifest)] {
            try Data(text.utf8).write(to: source.appendingPathComponent(name))
        }
        try Data([9, 8, 7, 6]).write(to: source.appendingPathComponent("unused.bin"))
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
            skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
            backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
            settingsDirectory: root.appendingPathComponent("Settings"), widgetsDirectory: root.appendingPathComponent("Widgets"),
            presentsWindows: false)
        let input = try DispatchQueue(label: "desk.package.flow.input").sync {
            try DeskCodePackageInput(capture: DeskPackageCapture.read(root: source), member: DeskFileID(path: "First.desk"))
        }
        t.atSuiteEnd {
            for window in app.codeFileWindows {
                window.codeView.onCommit = { _, _ in false }
                window.codeView.onDiskConflict = { _ in .decideLater }
                window.codeView.discardUncommittedChanges()
                window.closeChoice = { .discard }
                window.window?.close()
            }
            var drained = false
            app.deskPackages.cancelAndDrain { drained = true }
            _ = AppSelfTest.spin(timeout: 10) { drained }
            _ = app.stopAllForTermination()
            app.endEngineThread()
        }
        return Fixture(root: root, source: source, app: app, input: input)
    }

    private static func settled(_ window: CodeFileWindowController) -> Bool {
        AppSelfTest.spin(timeout: 10) {
            guard let checking = window.deskChecking, checking.snapshot.isChecked,
                  checking.isCurrent(checking.snapshot) else { return false }
            if case .pending = checking.imageResources(for: checking.snapshot) { return false }
            return true
        }
    }

    private static func plan(_ input: DeskCodePackageInput) -> DeskWidgetInstallation.PackagePlan {
        .init(requestID: UUID(), packageID: UUID(), selected: input.member,
              members: input.package.widgetFiles.map { .init(file: $0, sourceID: UUID(), instanceID: UUID()) })
    }

    private static func bundle(_ input: DeskCodePackageInput) -> DeskCodePackageSnapshot {
        let service = DeskLanguageService(package: input.package, openFile: input.member)
        return .init(input: input, snapshot: service.snapshot)
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk package flow: explicit folder context remains separate from an open standalone buffer") {
            let f = try fixture(t)
            t.check(f.app.showCodeFile(f.input.file, line: nil))
            guard let standalone = f.app.codeFileWindows.first else { throw Failure.fixture }
            standalone.codeView.idleCommitDelay = 600
            standalone.codeView.typedTextDelay = 600
            let draft = "info { name: \"Draft\" }\nwidget { Text(\"Draft\") }\n"
            t.check(standalone.codeView.replaceAsUser(with: draft, selection: NSRange(location: 0, length: 0), actionName: "Edit"))
            var result: Result<CodeFileWindowController, Error>?
            f.app.deskPackages.open(root: f.source, member: f.input.member) { result = $0 }
            t.check(AppSelfTest.spin(timeout: 10) { result != nil })
            guard let result else { throw Failure.fixture }
            let package = try result.get()
            t.check(package !== standalone)
            t.equal(f.app.codeFileWindows.count, 2)
            t.equal(standalone.codeView.text, draft); t.check(standalone.codeView.isDirty)
            t.equal(package.codeView.text, mainText); t.check(package.packageContext?.matches(f.input) == true)
            t.check(settled(package)); t.check(package.readError == nil)
            guard let snapshot = package.deskChecking?.snapshot else { throw Failure.fixture }
            t.equal(snapshot.folder.count, 3)
            t.check(Desk.compile(snapshot.checked, catalog: snapshot.options.catalog, package: snapshot.package).program != nil)
            t.check(try f.app.showCodePackage(f.input, line: nil) === package)
            t.check(f.app.showCodeFile(f.input.file, line: nil))
            t.check(f.app.lastBroughtToFront === standalone.window)
            t.equal(try Data(contentsOf: f.input.file), f.input.memberBytes)
            let menu = MainMenu.make(app: f.app)
            let file = menu.items.compactMap(\.submenu).first { $0.title == "File" }
            t.check(file?.items.contains { $0.title == StudioText[.deskOpenPackageFolder] && $0.target === f.app.deskPackages } == true)
        }

        t.suite("App: Desk package flow: placement installs all members and the installed menu can start a sibling") {
            let f = try fixture(t), window = try f.app.showCodePackage(f.input, line: nil)
            t.check(settled(window))
            let sourceID = UUID(), instanceID = UUID()
            var result: Result<DeskWidgetWindowController, Error>?
            window.placeOnDesktop(sourceID: sourceID, instanceID: instanceID) { result = $0 }
            t.check(AppSelfTest.spin(timeout: 10) { result != nil })
            guard let result else { throw Failure.fixture }
            let controller = try result.get()
            t.check(AppSelfTest.spin(timeout: 10) { controller.isStarted })
            t.equal(f.app.state.data.deskWidgets.sources.count, 2)
            t.equal(f.app.state.data.deskWidgets.instances.count, 2)
            t.equal(f.app.state.deskInstance(instanceID)?.active, true)
            guard let selected = f.app.state.deskSource(sourceID), let packageID = selected.packageID,
                  let sibling = f.app.state.data.deskWidgets.instances.values.first(where: { $0.id != instanceID }) else {
                throw Failure.fixture
            }
            t.check(packageID != sourceID)
            t.equal(sibling.active, false)
            let installed = f.app.widgetsDirectory.appendingPathComponent(packageID.uuidString.lowercased())
            for entry in f.input.capture.files {
                t.equal(try Data(contentsOf: installed.appendingPathComponent(entry.path)), entry.bytes)
            }
            var directory: ObjCBool = false
            t.check(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Empty/Nested").path, isDirectory: &directory))
            t.check(directory.boolValue)
            t.equal(try Data(contentsOf: f.input.file), f.input.memberBytes)
            guard let menu = f.app.deskPackages.installedMenuItem().submenu,
                  let item = menu.items.first(where: { ($0.representedObject as? UUID) == sibling.id }),
                  let action = item.action else { throw Failure.fixture }
            t.equal(item.state, .off)
            t.check(NSApp.sendAction(action, to: item.target, from: item))
            t.check(AppSelfTest.spin(timeout: 10) { f.app.deskWidgetWindows[sibling.id]?.isStarted == true })
            f.app.deskPackages.menuWillOpen(menu)
            t.equal(menu.items.first { ($0.representedObject as? UUID) == sibling.id }?.state, .on)
            window.window?.close()
            t.check(!controller.isClosed)
            t.equal(f.app.state.activeDeskWidgets.count, 2)
            guard let activeItem = menu.items.first(where: { ($0.representedObject as? UUID) == sibling.id }),
                  let activeAction = activeItem.action else { throw Failure.fixture }
            t.check(NSApp.sendAction(activeAction, to: activeItem.target, from: activeItem))
            t.check(AppSelfTest.spin(timeout: 10) { f.app.deskWidgetWindows[sibling.id] == nil })
            t.equal(f.app.state.deskInstance(sibling.id)?.active, false)
            t.equal(f.app.state.deskInstance(instanceID)?.active, true)
        }

        t.suite("App: Desk package flow: installed Options More Styles opens the member with its package context") {
            let f = try fixture(t)
            let source = """
            info { name: "First" }
            options { show = Toggle("Show", default: true) }
            widget { Text("First").style(label) }
            """
            try Data(source.utf8).write(to: f.input.file)
            let input = try DispatchQueue(label: "desk.package.flow.options.input").sync {
                try DeskCodePackageInput(capture: DeskPackageCapture.read(root: f.source), member: f.input.member)
            }
            let editor = try f.app.showCodePackage(input, line: nil)
            t.check(settled(editor))
            var installed: Result<DeskWidgetWindowController, Error>?
            editor.placeOnDesktop { installed = $0 }
            t.check(AppSelfTest.spin(timeout: 10) { installed != nil })
            guard let installed else { throw Failure.fixture }
            let widget = try installed.get()
            t.check(AppSelfTest.spin(timeout: 10) { widget.isStarted && widget.optionsSnapshot != nil })
            t.check(widget.source.packageID != nil)
            let member = widget.directory.appendingPathComponent("First.desk")
            t.check(member != input.file)
            t.check(f.app.showCodeFile(member, line: nil))
            guard let standalone = f.app.codeFileWindows.first(where: { $0.file == member && $0.packageContext == nil }) else {
                throw Failure.fixture
            }
            var menu: NSMenu?
            widget.view.contextMenuPresenterForTesting = { value, _ in menu = value }
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown,
                location: widget.view.convert(NSPoint(x: 1, y: 1), to: nil), modifierFlags: [.option], timestamp: 0,
                windowNumber: widget.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw Failure.fixture
            }
            widget.view.rightMouseDown(with: event)
            guard let item = menu?.items.first(where: { $0.title == StudioText[.deskOptions] }), let action = item.action else {
                throw Failure.fixture
            }
            t.check(NSApp.sendAction(action, to: item.target, from: item))
            t.check(AppSelfTest.spin(timeout: 10) { widget.optionsSession != nil })
            guard let button = widget.optionsSession?.panel.moreStylesButton, let moreStyles = button.action else {
                throw Failure.fixture
            }
            t.check(button.sendAction(moreStyles, to: button.target))
            t.check(AppSelfTest.spin(timeout: 10) {
                f.app.codeFileWindows.contains { $0.file == member && $0.packageContext != nil }
            })
            guard let opened = f.app.codeFileWindows.first(where: { $0.file == member && $0.packageContext != nil }),
                  let context = opened.packageContext else { throw Failure.fixture }
            t.check(opened !== standalone); t.check(opened !== editor)
            t.equal(context.root, widget.directory)
            t.equal(context.member, input.member)
            t.equal(opened.codeView.text, source)
            t.check(settled(opened)); t.check(opened.readError == nil)
            guard let snapshot = opened.deskChecking?.snapshot else { throw Failure.fixture }
            t.equal(snapshot.folder.count, 3)
            t.check(snapshot.package != nil)
            t.check(Desk.compile(snapshot.checked, catalog: snapshot.options.catalog, package: snapshot.package).program != nil)
            t.check(standalone.packageContext == nil)
            t.equal(try Data(contentsOf: input.file), input.memberBytes)
            t.equal(try Data(contentsOf: member), input.memberBytes)
            t.check(!widget.isClosed)
        }

        t.suite("App: Desk package flow: later edits and editor close reject pending placement without a partial package") {
            for close in [false, true] {
                let f = try fixture(t), window = try f.app.showCodePackage(f.input, line: nil)
                window.codeView.idleCommitDelay = 600; window.codeView.typedTextDelay = 600
                t.check(settled(window))
                let queue = DispatchQueue(label: "desk.package.held.placement")
                queue.suspend()
                var resumed = false
                defer { if !resumed { queue.resume() } }
                var completions = 0, succeeded = false
                window.placeOnDesktop(prepareQueue: queue) { result in
                    completions += 1
                    if case .success = result { succeeded = true }
                }
                t.check(AppSelfTest.spin(timeout: 10) { f.app.deskPackages.hasPendingInstallations })
                if close { window.window?.close() }
                else {
                    t.check(window.codeView.replaceAsUser(with: mainText + "\n", selection: NSRange(location: 0, length: 0), actionName: "Edit"))
                }
                queue.resume(); resumed = true
                t.check(AppSelfTest.spin(timeout: 10) { completions == 1 && !f.app.deskPackages.hasPendingInstallations })
                t.check(!succeeded); t.equal(completions, 1)
                t.check(f.app.state.data.deskWidgets.isEmpty)
                t.check(f.app.deskWidgetWindows.isEmpty)
                t.equal((try? FileManager.default.contentsOfDirectory(atPath: f.app.widgetsDirectory.path)) ?? [], [])
                t.equal(try Data(contentsOf: f.input.file), f.input.memberBytes)
            }
        }

        t.suite("App: Desk package flow: editing after registration cancels placement before the worker acknowledgement") {
            let f = try fixture(t), window = try f.app.showCodePackage(f.input, line: nil)
            window.codeView.idleCommitDelay = 600; window.codeView.typedTextDelay = 600
            t.check(settled(window))
            let queue = DispatchQueue(label: "desk.package.window.registration.ack")
            var suspended = false, observing = true, registrations = 0, completions = 0
            var outcome: Result<DeskWidgetWindowController, Error>?
            defer {
                observing = false
                f.app.deskPackages.didRegisterInstallationForTesting = nil
                if suspended { queue.resume() }
            }
            f.app.deskPackages.didRegisterInstallationForTesting = {
                guard observing else { return }
                registrations += 1
                guard registrations == 1 else { return }
                t.check(Thread.isMainThread)
                t.equal(f.app.state.data.deskWidgets.sources.count, 2)
                t.equal(f.app.state.data.deskWidgets.instances.count, 2)
                t.equal(completions, 0)
                // The hook runs before finish is enqueued, so this target suspension holds that exact ACK.
                queue.suspend()
                suspended = true
            }
            let sourceID = UUID(), instanceID = UUID()
            window.placeOnDesktop(sourceID: sourceID, instanceID: instanceID, prepareQueue: queue) {
                outcome = $0; completions += 1
            }
            t.check(AppSelfTest.spin(timeout: 10) { registrations == 1 })
            guard registrations == 1, suspended,
                  let source = f.app.state.deskSource(sourceID), let packageID = source.packageID else {
                throw Failure.fixture
            }
            let registered = f.app.state.data.deskWidgets
            let directory = f.app.widgetsDirectory.appendingPathComponent(packageID.uuidString.lowercased())
            t.equal(registered.sources.count, 2); t.equal(registered.instances.count, 2)
            t.check(registered.instances.values.allSatisfy { !$0.active })
            t.equal(AppState(fileURL: f.app.state.fileURL).data.deskWidgets, registered)
            t.check(f.app.deskPackages.hasPendingInstallations)
            t.equal(completions, 0); t.check(f.app.deskWidgetWindows.isEmpty)
            let draft = mainText + "\n"
            t.check(window.codeView.replaceAsUser(with: draft, selection: NSRange(location: 0, length: 0), actionName: "Edit"))
            t.check(window.codeView.isDirty)
            t.equal(window.codeView.text, draft)
            t.equal(completions, 0)
            t.equal(try Data(contentsOf: f.input.file), f.input.memberBytes)
            queue.resume(); suspended = false
            t.check(AppSelfTest.spin(timeout: 10) {
                completions == 1 && !f.app.deskPackages.hasPendingInstallations && f.app.pendingDeskWidgetActivationCount == 0
            })
            if case .failure(let error)? = outcome {
                t.equal(error as? CodeFileWindowController.PlaceOnDesktopError, .cancelled)
            } else { t.check(false, "an edit before the registration ACK must cancel desktop placement") }
            t.equal(completions, 1); t.equal(registrations, 1)
            t.check(f.app.deskWidgetWindows.isEmpty)
            t.equal(f.app.state.data.deskWidgets, registered)
            t.equal(AppState(fileURL: f.app.state.fileURL).data.deskWidgets, registered)
            t.equal(f.app.state.deskInstance(instanceID)?.active, false)
            t.check(f.app.state.data.deskWidgets.instances.values.allSatisfy { !$0.active })
            t.equal(try FileManager.default.contentsOfDirectory(atPath: f.app.widgetsDirectory.path), [packageID.uuidString.lowercased()])
            for file in f.input.capture.files {
                t.equal(try Data(contentsOf: directory.appendingPathComponent(file.path)), file.bytes)
                t.equal(try Data(contentsOf: f.source.appendingPathComponent(file.path)), file.bytes)
            }
            var isDirectory: ObjCBool = false
            t.check(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Empty/Nested").path,
                                                   isDirectory: &isDirectory))
            t.check(isDirectory.boolValue)
            t.check(window.codeView.isDirty); t.equal(window.codeView.text, draft)
            var nextTurn = false
            DispatchQueue.main.async { nextTurn = true }
            t.check(AppSelfTest.spin(timeout: 10) { nextTurn })
            t.equal(completions, 1)
        }

        t.suite("App: Desk package flow: cancelling after state registration waits for acknowledgement and preserves installed files") {
            let f = try fixture(t), package = bundle(f.input), ids = plan(f.input)
            let queue = DispatchQueue(label: "desk.package.held.ack"), gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            var held = false, completed = 0, drained = false
            var result: DeskPackageInstallationRequest.Outcome?
            let request = f.app.deskPackages.install(package, plan: ids, queue: queue, current: {
                if !held {
                    held = true
                    queue.async { _ = gate.wait(timeout: .now() + 10) }
                }
                return true
            }) { result = $0; completed += 1 }
            t.check(AppSelfTest.spin(timeout: 10) { f.app.state.data.deskWidgets.sources.count == 2 })
            t.check(!request.isFinished); t.equal(completed, 0)
            f.app.deskPackages.cancelAndDrain { drained = true }
            t.check(!drained)
            gate.signal()
            t.check(AppSelfTest.spin(timeout: 10) { request.isFinished && drained })
            t.equal(completed, 1)
            guard let result else { throw Failure.fixture }
            let installed = try result.get()
            t.equal(installed.sources.count, 2)
            t.equal(f.app.state.activeDeskWidgets.count, 0)
            t.equal(AppState(fileURL: f.app.state.fileURL).data.deskWidgets.sources.count, 2)
            for entry in f.input.capture.files {
                t.equal(try Data(contentsOf: installed.directory.appendingPathComponent(entry.path)), entry.bytes)
            }
            var immediate = false
            request.whenFinished { immediate = true }
            t.check(immediate)
        }

        t.suite("App: Desk package flow: state save failure and cancellation drain remove only their owned installation") {
            for shouldCancel in [false, true] {
                let f = try fixture(t), package = bundle(f.input), ids = plan(f.input)
                let blocked = f.root.appendingPathComponent("blocked")
                try Data([1]).write(to: blocked)
                let state = shouldCancel ? f.app.state : AppState(fileURL: blocked.appendingPathComponent("state.json"))
                let queue = DispatchQueue(label: "desk.package.reject.request")
                queue.suspend()
                var replied = 0, rejected = false, observer = 0
                let request = DeskPackageInstallationRequest.start(snapshot: package.snapshot, capture: f.input.capture,
                    plan: ids, root: f.app.widgetsDirectory, state: state, queue: queue, current: { true }) {
                        replied += 1
                        if case .failure = $0 { rejected = true }
                    }
                request.whenFinished { observer += 1 }
                if shouldCancel { request.cancel() }
                queue.resume()
                t.check(AppSelfTest.spin(timeout: 10) { request.isFinished })
                t.equal(replied, 1); t.equal(observer, 1); t.check(rejected)
                t.check(state.data.deskWidgets.isEmpty)
                t.equal((try? FileManager.default.contentsOfDirectory(atPath: f.app.widgetsDirectory.path)) ?? [], [])
                t.equal(try Data(contentsOf: blocked), Data([1]))
                t.equal(try Data(contentsOf: f.input.file), f.input.memberBytes)
            }
        }
    }
}
