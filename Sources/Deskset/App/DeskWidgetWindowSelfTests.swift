import AppKit
import Darwin
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Tests the end-to-end Desk widget window lifecycle:
/// - "Place on Desktop" from .desk code editor installs and activates an independent window.
/// - Window continues running after the editor window is closed.
/// - Dragging and position persistence.
/// - Explicit deactivation and state clearing.
/// - App restart recovery of active widgets and failure intent preservation.
/// - FIFO close teardown sequence and worker executor safety.
/// - Blocked worker queue -> creation queued -> immediate close -> release ordering and resource cleanup.
/// - Real window facts, nil to valid colorSpace recovery on same host.
/// - stopAllForTermination shares global deadline and reports late widgets.
enum DeskWidgetWindowSelfTests {
    private enum Failure: Error { case fixture }
    private static let sourceID = UUID(uuidString: "ADA061F6-14F6-4CA2-A3C5-EC6888921254")!
    private static let instanceID = UUID(uuidString: "7B38FD07-0ADB-464C-9E22-84153317742D")!
    private static let sampleDeskText = "widget { Text(\"Deskset Test 😀\").font(20) }\r\n"

    private struct Fixture {
        let root: URL
        let file: URL
        let app: AppController
        let controller: CodeFileWindowController
        var checking: DeskCodeDocumentChecking { controller.deskChecking! }
    }

    private static func fixture(_ t: AppTestRunner, text: String = sampleDeskText, presentsWindows: Bool = false) throws -> Fixture {
        let root = t.temporaryDirectory("desk-widget-window-test")
        let file = root.appendingPathComponent("Widget.desk")
        try Data(text.utf8).write(to: file)
        let stateURL = root.appendingPathComponent("state.json")
        let skinsDir = root.appendingPathComponent("Skins")
        let layoutsDir = root.appendingPathComponent("Layouts")
        let backupsDir = root.appendingPathComponent("Backups")
        let settingsDir = root.appendingPathComponent("Settings")
        let widgetsDir = root.appendingPathComponent("Widgets")
        let app = AppController(state: AppState(fileURL: stateURL),
                                skinsDirectory: skinsDir,
                                layoutsDirectory: layoutsDir,
                                backupsDirectory: backupsDir,
                                defaultSkinsSource: nil,
                                settingsDirectory: settingsDir,
                                widgetsDirectory: widgetsDir,
                                presentsWindows: presentsWindows)
        let controller = try CodeFileWindowController(file: file, app: app,
                                                       deskCheckQueue: DispatchQueue(label: "desk.window.test.check"))
        controller.codeView.idleCommitDelay = 600
        controller.codeView.typedTextDelay = 600
        t.atSuiteEnd {
            controller.deskChecking?.close()
            controller.codeView.onCommit = { _, _ in false }
            controller.codeView.onDiskConflict = { _ in .decideLater }
            controller.codeView.discardUncommittedChanges()
            controller.window?.close()
            _ = app.stopAllForTermination()
            app.endEngineThread()
        }
        return Fixture(root: root, file: file, app: app, controller: controller)
    }

    private static func waitForCheck(_ f: Fixture) -> Bool {
        AppSelfTest.spin(timeout: 10) {
            let checking = f.checking, snapshot = checking.snapshot
            guard snapshot.isChecked, checking.isCurrent(snapshot) else { return false }
            if case .pending = checking.imageResources(for: snapshot) { return false }
            return true
        }
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk widget window: place on desktop installs and activates independent window") {
            let f = try fixture(t)
            t.check(waitForCheck(f), "document is checked")

            var placedController: DeskWidgetWindowController?
            var placeError: Error?
            f.controller.placeOnDesktop(sourceID: sourceID, instanceID: instanceID) { result in
                switch result {
                case .success(let c): placedController = c
                case .failure(let err): placeError = err
                }
            }

            t.check(AppSelfTest.spin(timeout: 10) { placedController != nil || placeError != nil })
            t.check(placeError == nil, "place on desktop succeeded without error")
            guard let widgetWin = placedController else { return }

            t.equal(f.app.deskWidgetWindows[instanceID] === widgetWin, true, "window registered in AppController")

            // Wait for initial frame presentation
            t.check(AppSelfTest.spin(timeout: 10) { widgetWin.isStarted })
            t.equal(widgetWin.isStarted, true)
            t.check(widgetWin.latestPresented != nil, "first frame presented and accepted")
            t.equal(widgetWin.view.frame.size, widgetWin.latestPresented?.size)

            // Verify AppState was updated with active = true
            let instanceState = f.app.state.deskInstance(instanceID)
            t.equal(instanceState?.active, true, "instance state is active")
            t.check(instanceState?.x != nil && instanceState?.y != nil, "position was saved")

            // Closing code editor does NOT close the standalone widget window
            f.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            t.equal(widgetWin.isClosed, false, "widget window remains active after editor close")
            t.equal(f.app.deskWidgetWindows[instanceID] === widgetWin, true)
        }

        t.suite("App: Desk widget window: dragging updates and persists coordinates") {
            let f = try fixture(t)
            t.check(waitForCheck(f))

            var placedController: DeskWidgetWindowController?
            f.controller.placeOnDesktop(sourceID: UUID(), instanceID: UUID()) { result in
                if case .success(let c) = result { placedController = c }
            }
            t.check(AppSelfTest.spin(timeout: 10) { placedController?.isStarted == true })
            guard let widgetWin = placedController else { return }

            let initialOrigin = widgetWin.window.frame.origin
            // Simulate dragging by 50 points
            widgetWin.window.setFrameOrigin(NSPoint(x: initialOrigin.x + 50, y: initialOrigin.y + 30))
            widgetWin.savePosition()

            let updatedInstance = f.app.state.deskInstance(widgetWin.instance.id)
            let ph = WindowGeometry.primaryHeight(WindowGeometry.currentScreens())
            let expectedTopLeft = WindowGeometry.topLeft(of: widgetWin.window.frame, primaryHeight: ph)
            t.close(updatedInstance?.x ?? 0, expectedTopLeft.x, "persisted x matches dragged position")
            t.close(updatedInstance?.y ?? 0, expectedTopLeft.y, "persisted y matches dragged position")
        }

        t.suite("App: Desk widget window: explicit deactivation marks inactive and tears down") {
            let f = try fixture(t)
            t.check(waitForCheck(f))

            let instID = UUID()
            var placedController: DeskWidgetWindowController?
            f.controller.placeOnDesktop(sourceID: UUID(), instanceID: instID) { result in
                if case .success(let c) = result { placedController = c }
            }
            t.check(AppSelfTest.spin(timeout: 10) { placedController?.isStarted == true })
            guard let widgetWin = placedController else { return }

            var closedAck = false
            widgetWin.close(deactivate: true) {
                closedAck = true
            }

            t.check(AppSelfTest.spin(timeout: 10) { closedAck && widgetWin.isClosed })
            t.equal(widgetWin.isClosed, true)
            t.equal(f.app.deskWidgetWindows[instID], nil, "removed from AppController mapping")
            t.equal(f.app.state.deskInstance(instID)?.active, false, "marked inactive in AppState on explicit stop")
        }

        t.suite("App: Desk widget window: restart recovers active widgets and preserves intent on failure") {
            let root = t.temporaryDirectory("desk-widget-restart-test")
            let stateURL = root.appendingPathComponent("state.json")
            let appState = AppState(fileURL: stateURL)
            let sourceID = UUID()
            let activeInstID = UUID()
            let brokenInstID = UUID()

            // Prepare valid source directory in isolated widgets directory
            let widgetsRoot = root.appendingPathComponent("Widgets")
            let sourceDir = widgetsRoot.appendingPathComponent(sourceID.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            let deskFile = sourceDir.appendingPathComponent("Main.desk")
            try Data(sampleDeskText.utf8).write(to: deskFile)

            let source = DeskWidgetSourceState(id: sourceID, entry: sourceID.uuidString.lowercased() + "/Main.desk")
            let activeInstance = DeskWidgetInstanceState(id: activeInstID, sourceID: sourceID, active: false, x: 100, y: 100)
            try appState.registerDeskInstallation(source: source, instance: activeInstance)
            appState.updateDeskInstance(activeInstID) { $0.active = true }

            let brokenSourceID = UUID()
            let brokenSource = DeskWidgetSourceState(id: brokenSourceID, entry: brokenSourceID.uuidString.lowercased() + "/Missing.desk")
            let brokenInstance = DeskWidgetInstanceState(id: brokenInstID, sourceID: brokenSourceID, active: false, x: 200, y: 200)
            try appState.registerDeskInstallation(source: brokenSource, instance: brokenInstance)
            appState.updateDeskInstance(brokenInstID) { $0.active = true }
            appState.saveNow()

            // Construct new app instance to simulate restart
            let app = AppController(state: AppState(fileURL: stateURL),
                                    skinsDirectory: root.appendingPathComponent("Skins"),
                                    layoutsDirectory: root.appendingPathComponent("Layouts"),
                                    backupsDirectory: root.appendingPathComponent("Backups"),
                                    defaultSkinsSource: nil,
                                    settingsDirectory: root.appendingPathComponent("Settings"),
                                    widgetsDirectory: widgetsRoot,
                                    presentsWindows: false)

            app.loadActiveDeskWidgets()

            // Valid active widget should be recovered
            t.check(AppSelfTest.spin(timeout: 10) { app.deskWidgetWindows[activeInstID]?.isStarted == true })
            let recovered = app.deskWidgetWindows[activeInstID]
            t.check(recovered != nil, "valid widget successfully recovered")

            // Broken widget recovery fails, but active intent MUST be preserved (contract)
            t.equal(app.deskWidgetWindows[brokenInstID], nil, "broken widget window not created")
            t.equal(app.state.deskInstance(brokenInstID)?.active, true, "failure preserves active intent; does not write false")
            t.equal(app.deskRestorationFailures.count, 1, "recorded single restoration failure")
            t.equal(app.lastAlert != nil, true, "aggregated restoration failure alert generated without modal flood")

            // Cleanup
            _ = app.stopAllForTermination()
            app.endEngineThread()
        }

        t.suite("App: Desk widget window: teardown wait queues and worker executor safety") {
            let f = try fixture(t)
            t.check(waitForCheck(f))

            let instID = UUID()
            var placedController: DeskWidgetWindowController?
            f.controller.placeOnDesktop(sourceID: UUID(), instanceID: instID) { result in
                if case .success(let c) = result { placedController = c }
            }
            t.check(AppSelfTest.spin(timeout: 10) { placedController?.isStarted == true })
            guard let widgetWin = placedController else { return }

            // Concurrent or duplicate close calls wait for the actual ACK
            var ack1 = false, ack2 = false
            widgetWin.close(deactivate: false) { ack1 = true }
            widgetWin.close(deactivate: false) { ack2 = true }

            t.check(AppSelfTest.spin(timeout: 10) { ack1 && ack2 && widgetWin.isClosed })
            t.equal(ack1, true)
            t.equal(ack2, true)
            t.equal(widgetWin.isClosed, true)
        }

        t.suite("App: Desk widget window: blocked worker queue -> creation queued -> immediate close -> release ordering and resource cleanup") {
            let worker = SkinThreadExecutor(name: "Desk widget blocked worker test")
            defer { worker.stop() }

            let root = t.temporaryDirectory("desk-blocked-worker-test")
            let sourceID = UUID()
            let instID = UUID()

            let widgetsRoot = root.appendingPathComponent("Widgets")
            let sourceDir = widgetsRoot.appendingPathComponent(sourceID.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

            let deskFile = sourceDir.appendingPathComponent("Main.desk")
            try Data(sampleDeskText.utf8).write(to: deskFile)

            let stateURL = root.appendingPathComponent("state.json")
            let app = AppController(state: AppState(fileURL: stateURL),
                                    skinsDirectory: root.appendingPathComponent("Skins"),
                                    layoutsDirectory: root.appendingPathComponent("Layouts"),
                                    backupsDirectory: root.appendingPathComponent("Backups"),
                                    defaultSkinsSource: nil,
                                    settingsDirectory: root.appendingPathComponent("Settings"),
                                    widgetsDirectory: widgetsRoot,
                                    presentsWindows: false)
            defer {
                _ = app.stopAllForTermination()
                app.endEngineThread()
            }

            let source = DeskWidgetSourceState(id: sourceID, entry: sourceID.uuidString.lowercased() + "/Main.desk")
            let instance = DeskWidgetInstanceState(id: instID, sourceID: sourceID, active: false)
            try app.state.registerDeskInstallation(source: source, instance: instance)

            // Block worker queue
            let blockSema = DispatchSemaphore(value: 0)
            let workerEntered = DispatchSemaphore(value: 0)
            worker.async {
                workerEntered.signal()
                blockSema.wait()
            }
            workerEntered.wait()

            // On Main thread: activateDeskWidget with worker executor
            // Because worker is blocked, owner.start will be queued behind the block
            let catalog = DeskCatalog.current
            let doc = try DeskProgramResources.document(at: deskFile, maximumBytes: catalog.limits.maximumFileBytes)
            guard case .text(_, let fileID) = Desk.load(doc.bytes, fileName: "Main.desk") else {
                return t.check(false, "decode desk file")
            }
            let package = PackageLoader.load(deskData: doc.bytes, fileName: "Main.desk", limits: catalog.limits)
            let service = DeskLanguageService(package: package, openFile: fileID,
                                              options: DeskServiceOptions(catalog: catalog))
            let compileResult = Desk.compile(service.snapshot.checked, catalog: catalog)
            guard let program = compileResult.program else {
                return t.check(false, "compile program")
            }
            let prepared = DeskProgramResources.prepare(root: sourceDir, literals: compileResult.imageSources,
                                                        maximumBytes: 1_000_000, maximumFiles: 10, language: .english)

            let widgetWin = DeskWidgetWindowController(source: source, instance: instance, directory: sourceDir,
                                                       program: program, prepared: prepared, app: app,
                                                       executor: worker, clock: .live)
            // Immediately close on Main thread: owner.close is queued behind owner.start
            var closeAck = false
            widgetWin.close(deactivate: true) {
                closeAck = true
            }

            // Unblock worker
            blockSema.signal()

            // Spin on Main until closeAck is received
            t.check(AppSelfTest.spin(timeout: 10) { closeAck && widgetWin.isClosed }, "closed cleanly after worker unblocked")
            t.equal(widgetWin.isClosed, true)
            t.equal(widgetWin.owner.isClosed, true, "owner marked closed on worker")
            t.check(widgetWin.owner.host == nil, "host cleared on worker")
            t.check(widgetWin.owner.prepared == nil, "prepared cleared on worker")
        }

        t.suite("App: Desk widget window: real facts, nil to valid colorSpace recovery on same host") {
            let f = try fixture(t)
            t.check(waitForCheck(f))

            let instID = UUID()
            var placedController: DeskWidgetWindowController?
            f.controller.placeOnDesktop(sourceID: UUID(), instanceID: instID) { result in
                if case .success(let c) = result { placedController = c }
            }
            t.check(AppSelfTest.spin(timeout: 10) { placedController?.isStarted == true })
            guard let widgetWin = placedController else { return }

            // 1. Initial valid facts
            let facts = widgetWin.currentFacts()
            t.equal(facts.isOrderedIn, widgetWin.window.isVisible, "isOrderedIn matches window.isVisible, not occluded")
            t.equal(facts.sequence > 0, true, "sequence increments")

            let initialHost = widgetWin.owner.host
            t.check(initialHost != nil, "initial host exists")
            t.check(widgetWin.latestPresented != nil, "initial frame presented")
            let initialGen = widgetWin.latestPresented?.scene.generation ?? 0

            // 2. Deliver facts with nil colorSpace
            var factsNilCS = widgetWin.currentFacts()
            factsNilCS.colorSpace = nil
            let input = try DeskWidgetWindowController.makeInput(for: widgetWin.window.effectiveAppearance,
                                                                 scale: widgetWin.window.backingScaleFactor)
            let hostOwner = widgetWin.owner
            widgetWin.executor.async { [hostOwner] in
                hostOwner.take(factsNilCS, input: input)
            }

            // Assert: host clears presentation and Main records unavailable
            t.check(AppSelfTest.spin(timeout: 10) {
                widgetWin.latestPresented == nil && widgetWin.lastUnavailableMessage != nil
            }, "presentation cleared and unavailable state set on nil colorSpace")

            // 3. Restore valid RGB colorSpace
            var factsValidCS = widgetWin.currentFacts()
            factsValidCS.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            widgetWin.executor.async { [hostOwner] in
                hostOwner.take(factsValidCS, input: input)
            }

            // Assert: host re-projects and Main accepts new generation on same host
            t.check(AppSelfTest.spin(timeout: 10) {
                widgetWin.latestPresented != nil && (widgetWin.latestPresented?.scene.generation ?? 0) > initialGen
            }, "new frame accepted after colorSpace restored")
            t.check(widgetWin.lastUnavailableMessage == nil, "cleared unavailable message")
            t.check(widgetWin.owner.host === initialHost, "same host instance retained without onLoad replay")
        }

        t.suite("App: Desk widget window: stopAllForTermination shares global deadline and reports late widgets") {
            let worker = SkinThreadExecutor(name: "Desk widget late termination worker")
            defer { worker.stop() }

            let root = t.temporaryDirectory("desk-late-termination-test")
            let sourceID = UUID(), instID = UUID()

            let widgetsRoot = root.appendingPathComponent("Widgets")
            let sourceDir = widgetsRoot.appendingPathComponent(sourceID.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

            let deskFile = sourceDir.appendingPathComponent("Main.desk")
            try Data(sampleDeskText.utf8).write(to: deskFile)

            let stateURL = root.appendingPathComponent("state.json")
            let app = AppController(state: AppState(fileURL: stateURL),
                                    skinsDirectory: root.appendingPathComponent("Skins"),
                                    layoutsDirectory: root.appendingPathComponent("Layouts"),
                                    backupsDirectory: root.appendingPathComponent("Backups"),
                                    defaultSkinsSource: nil,
                                    settingsDirectory: root.appendingPathComponent("Settings"),
                                    widgetsDirectory: widgetsRoot,
                                    presentsWindows: false)

            let source = DeskWidgetSourceState(id: sourceID, entry: sourceID.uuidString.lowercased() + "/Main.desk")
            let instance = DeskWidgetInstanceState(id: instID, sourceID: sourceID, active: false)
            try app.state.registerDeskInstallation(source: source, instance: instance)

            let catalog = DeskCatalog.current
            let doc = try DeskProgramResources.document(at: deskFile, maximumBytes: catalog.limits.maximumFileBytes)
            guard case .text(_, let fileID) = Desk.load(doc.bytes, fileName: "Main.desk") else {
                return t.check(false, "decode desk file")
            }
            let package = PackageLoader.load(deskData: doc.bytes, fileName: "Main.desk", limits: catalog.limits)
            let service = DeskLanguageService(package: package, openFile: fileID, options: DeskServiceOptions(catalog: catalog))
            guard let program = Desk.compile(service.snapshot.checked, catalog: catalog).program else {
                return t.check(false, "compile program")
            }
            let prepared = DeskProgramResources.prepare(root: sourceDir, literals: [], maximumBytes: 100_000,
                                                        maximumFiles: 5, language: .english)

            let widgetWin = DeskWidgetWindowController(source: source, instance: instance, directory: sourceDir,
                                                       program: program, prepared: prepared, app: app,
                                                       executor: worker, clock: .live)
            t.check(AppSelfTest.spin(timeout: 10) { widgetWin.isStarted })

            // Block worker to force deadline timeout
            let blockSema = DispatchSemaphore(value: 0)
            let entered = DispatchSemaphore(value: 0)
            worker.async {
                entered.signal()
                blockSema.wait()
            }
            entered.wait()

            // Run stopAllForTermination with tight budget
            let late = app.stopAllForTermination(budget: 0.05)
            t.check(late.contains(source.entry), "timed out widget reported in late array")
            t.equal(widgetWin.isClosed, false, "widget remained open during timeout")

            // Release block and let widget complete teardown
            blockSema.signal()
            t.check(AppSelfTest.spin(timeout: 10) { widgetWin.isClosed }, "widget closed cleanly after worker released")
            app.endEngineThread()
        }

        t.suite("App: Desk widget window: queued stale presentation or unavailable receipt is rejected on epoch mismatch") {
            let f = try fixture(t)
            t.check(waitForCheck(f))

            var placedController: DeskWidgetWindowController?
            f.controller.placeOnDesktop(sourceID: UUID(), instanceID: UUID()) { result in
                if case .success(let c) = result { placedController = c }
            }
            t.check(AppSelfTest.spin(timeout: 10) { placedController?.isStarted == true })
            guard let widgetWin = placedController else { return }

            guard let initialPresented = widgetWin.latestPresented else {
                return t.check(false, "initialPresented must exist")
            }
            let initialEpoch = widgetWin.destinationEpoch
            t.equal(widgetWin.lastAcceptedEpoch, initialEpoch, "initial accepted epoch matches destination epoch")

            // Controlled facts pattern (DeskProgramDrawingSelfTests):
            // Using the real owner on Main, deliver nil-profile facts then valid facts.
            // Because callbacks are dispatched async to Main, they are enqueued on DispatchQueue.main
            // but have not yet executed because we are running synchronously on Main.
            let scale = widgetWin.window.backingScaleFactor
            let input = try DeskWidgetWindowController.makeInput(for: widgetWin.window.effectiveAppearance, scale: scale)
            let staleEpoch = widgetWin.destinationEpoch

            let nilFacts = SkinWindowFacts(
                frame: widgetWin.window.frame,
                screen: 0,
                isVisible: true,
                isOrderedIn: true,
                scale: scale,
                colorSpace: nil,
                appearance: input.environment.appearance.name,
                takesPointer: true,
                sequence: 100,
                panelGeneration: staleEpoch
            )
            widgetWin.owner.take(nilFacts, input: input)

            let validFacts = SkinWindowFacts(
                frame: widgetWin.window.frame,
                screen: 0,
                isVisible: true,
                isOrderedIn: true,
                scale: scale,
                colorSpace: SkinFrameProducer.sRGB,
                appearance: input.environment.appearance.name,
                takesPointer: true,
                sequence: 101,
                panelGeneration: staleEpoch
            )
            widgetWin.owner.take(validFacts, input: input)

            // Do NOT pump Main yet.
            // Capture real initial effectiveAppearance, select a distinct alternate B, then restore to initial A.
            // Avoids assuming initial light Aqua, which would fail epochB > staleEpoch on dark systems.
            let initialAppearance = widgetWin.window.effectiveAppearance
            let isInitialDark = initialAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let alternateName: NSAppearance.Name = isInitialDark ? .aqua : .darkAqua
            guard let alternateAppearance = NSAppearance(named: alternateName) else {
                return t.check(false, "alternate appearance could not be created")
            }

            widgetWin.window.appearance = alternateAppearance
            _ = widgetWin.currentFacts()
            let epochB = widgetWin.destinationEpoch
            t.check(epochB > staleEpoch, "destinationEpoch incremented for alternate appearance")

            widgetWin.window.appearance = initialAppearance
            _ = widgetWin.currentFacts()
            let restoredEpoch = widgetWin.destinationEpoch
            t.check(restoredEpoch > epochB, "destinationEpoch incremented for restored appearance")

            // Enqueue a Main queue sentinel after the queued stale receipts.
            // Because DispatchQueue.main is serial FIFO, the sentinel executes strictly after
            // the queued handleUnavailable and handlePresented blocks have run.
            var staleReceiptsDrained = false
            DispatchQueue.main.async {
                staleReceiptsDrained = true
            }
            t.check(AppSelfTest.spin(timeout: 5) { staleReceiptsDrained }, "queued stale receipts processed before assertion")

            // Assert that the queued stale receipts (from staleEpoch) were rejected:
            // 1. The queued unavailable receipt did not overwrite lastUnavailableMessage
            t.equal(widgetWin.lastUnavailableMessage, nil, "queued stale unavailable receipt was rejected on epoch mismatch")
            // 2. The queued presented receipt did not update lastAcceptedEpoch
            t.equal(widgetWin.lastAcceptedEpoch, initialEpoch, "queued stale presented receipt was rejected on epoch mismatch")
            // 3. latestPresented was not overwritten by stale callback
            t.equal(widgetWin.latestPresented?.scene.generation, initialPresented.scene.generation, "latestPresented preserved from initial")

            // Now test real recovery under current restoredEpoch:
            // Deliver nil-profile facts under restoredEpoch -> clears latestPresented and sets lastUnavailableMessage
            let nilFactsRestored = SkinWindowFacts(
                frame: widgetWin.window.frame,
                screen: 0,
                isVisible: true,
                isOrderedIn: true,
                scale: scale,
                colorSpace: nil,
                appearance: input.environment.appearance.name,
                takesPointer: true,
                sequence: 102,
                panelGeneration: restoredEpoch
            )
            widgetWin.owner.take(nilFactsRestored, input: input)
            t.check(AppSelfTest.spin(timeout: 5) {
                widgetWin.latestPresented == nil && widgetWin.lastUnavailableMessage != nil
            }, "current epoch nil-profile unavailable receipt accepted and cleared latestPresented")

            // Deliver valid facts under restoredEpoch -> restores latestPresented and clears lastUnavailableMessage
            let validFactsRestored = SkinWindowFacts(
                frame: widgetWin.window.frame,
                screen: 0,
                isVisible: true,
                isOrderedIn: true,
                scale: scale,
                colorSpace: SkinFrameProducer.sRGB,
                appearance: input.environment.appearance.name,
                takesPointer: true,
                sequence: 103,
                panelGeneration: restoredEpoch
            )
            widgetWin.owner.take(validFactsRestored, input: input)
            t.check(AppSelfTest.spin(timeout: 5) {
                widgetWin.latestPresented != nil && widgetWin.lastAcceptedEpoch == restoredEpoch
            }, "current epoch valid presentation accepted and restored latestPresented")
            t.equal(widgetWin.lastUnavailableMessage, nil, "lastUnavailableMessage cleared on valid presentation")
        }
    }
}
