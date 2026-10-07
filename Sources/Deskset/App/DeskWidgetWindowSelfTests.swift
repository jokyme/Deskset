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
        clickActionTests(t)
        accessibilityTests(t)
        pointerEventTests(t)
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

    private final class ActionRecorder {
        var calls: [String] = []
        var mainThreads: [Bool] = []
        var opensSucceed = true
        var onCopy: ((String) -> Void)?
        var services: DeskProgramActionServices {
            DeskProgramActionServices(resolver: DeskProgramOpenResolver(application: { _ in nil },
                applicationNamed: { _ in nil }, exists: { _ in false }), copy: { text in
                    self.mainThreads.append(Thread.isMainThread)
                    self.calls.append("copy:" + text)
                    self.onCopy?(text)
                    return true
                }, open: { url in
                    self.mainThreads.append(Thread.isMainThread)
                    self.calls.append("open:" + url.absoluteString)
                    return self.opensSucceed
                })
        }
    }

    private static let actionSource = #"widget { variable n = 0; computed caption = "{n}"; Text(caption).font(20).size(160, 40).onClick { n = n + 1; copy(caption); open("https://example.com/{n}"); copy("done😀") } }"#

    private static func actionFixture(_ t: AppTestRunner, recorder: ActionRecorder,
                                      executor: SkinExecutor = MainSkinExecutor.shared,
                                      text: String = actionSource,
                                      beforePresentation: ((DeskWidgetWindowController) throws -> Void)? = nil) throws -> DeskWidgetWindowController {
        let f = try fixture(t, text: text)
        let result = Desk.compile(Desk.check(Desk.parse(text, fileName: "Main.desk")))
        t.check(result.issues.isEmpty, "\(result.issues)")
        guard let program = result.program else { throw Failure.fixture }
        let sourceID = UUID(), instanceID = UUID()
        let source = DeskWidgetSourceState(id: sourceID, entry: sourceID.uuidString.lowercased() + "/Main.desk")
        let instance = DeskWidgetInstanceState(id: instanceID, sourceID: sourceID)
        let directory = f.root.appendingPathComponent("Widgets").appendingPathComponent(sourceID.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: directory.appendingPathComponent("Main.desk"))
        try f.app.state.registerDeskInstallation(source: source, instance: instance)
        let widget = DeskWidgetWindowController(source: source, instance: instance, directory: directory,
                                               program: program, prepared: nil, app: f.app, executor: executor,
                                               actionServices: recorder.services)
        try beforePresentation?(widget)
        t.check(AppSelfTest.spin(timeout: 10) { widget.isStarted && widget.latestPresented != nil })
        let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
                                                             scale: widget.window.backingScaleFactor)
        guard let space = widget.window.colorSpace?.cgColorSpace else { throw Failure.fixture }
        // Existing controlled-facts fixture: no visible window is ordered in during an automated action test.
        let facts = SkinWindowFacts(frame: widget.window.frame, isVisible: true, isOrderedIn: true,
            scale: widget.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
            takesPointer: true, sequence: 100, panelGeneration: widget.destinationEpoch)
        var delivered = false
        executor.async { [owner = widget.owner] in
            owner.take(facts, input: input)
            owner.host?.frames.runLoopTurn(.beforeWaiting)
            DispatchQueue.main.async { delivered = true }
        }
        t.check(AppSelfTest.spin(timeout: 10) { delivered && widget.latestPresented != nil })
        return widget
    }

    private static func frozenActionBatch(_ widget: DeskWidgetWindowController) throws -> (DeskWidgetClickToken, [ProgramEffect]) {
        guard let token = widget.issueClickToken() else { throw Failure.fixture }
        let point = SkinPoint(x: 20, y: 20)
        widget.owner.primaryPress(at: point, expectedGeneration: token.sourceGeneration, epoch: token.epoch)
        var batch: (DeskWidgetClickToken, [ProgramEffect])?
        widget.owner.primaryRelease(at: point, token: token) { batch = ($0, $1) }
        guard let batch else { throw Failure.fixture }
        return batch
    }

    private static func pointerMouse(_ type: NSEvent.EventType, at point: NSPoint,
                                     in widget: DeskWidgetWindowController, flags: NSEvent.ModifierFlags = []) throws {
        let location = widget.view.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0,
            windowNumber: widget.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw Failure.fixture
        }
        switch type {
        case .leftMouseDown: widget.view.mouseDown(with: event)
        case .leftMouseDragged: widget.view.mouseDragged(with: event)
        case .leftMouseUp: widget.view.mouseUp(with: event)
        case .rightMouseDown: widget.view.rightMouseDown(with: event)
        case .rightMouseDragged: widget.view.rightMouseDragged(with: event)
        case .rightMouseUp: widget.view.rightMouseUp(with: event)
        default: throw Failure.fixture
        }
    }

    private static let pointerSource = #"widget { variable n = 0; Row(spacing: 0) { Text(n).font(20).size(80, 40).onClick { copy("primary") }.onRightClick { n = n + 1; copy("{n}"); open("https://example.com/{n}") }; Text("Right only").size(100, 40).onRightClick { copy("other") }; Text("Empty").size(80, 40).onRightClick { }; Text("Menu").size(80, 40).onClick { copy("last primary") } } }"#

    private static func pointerEventTests(_ t: AppTestRunner) {
        t.suite("App: Desk pointer events: desktop startup and new Option presses retain the native menu during a pending destination") {
            let recorder = ActionRecorder()
            var menus = 0
            let widget = try actionFixture(t, recorder: recorder, text: pointerSource, beforePresentation: { widget in
                t.check(!widget.isStarted && widget.latestPresented == nil, "the actual first Main presentation is still queued")
                widget.view.contextMenuPresenterForTesting = { _, _ in menus += 1 }
                try pointerMouse(.rightMouseDown, at: NSPoint(x: 0.5, y: 0.5), in: widget, flags: [.option])
                try pointerMouse(.rightMouseUp, at: NSPoint(x: 0.5, y: 0.5), in: widget)
                try pointerMouse(.leftMouseDown, at: NSPoint(x: 0.5, y: 0.5), in: widget, flags: [.control])
                try pointerMouse(.leftMouseUp, at: NSPoint(x: 0.5, y: 0.5), in: widget)
                t.equal(menus, 2)
            })
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget)
            let epoch = widget.destinationEpoch
            let dark = widget.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            widget.window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            _ = widget.currentFacts()
            t.check(widget.destinationEpoch != epoch && widget.latestPresented != nil,
                    "the old accepted picture remains while the destination changes")
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget, flags: [.option])
            t.equal(menus, 2, "a held old-epoch Option release cancels instead of adopting the new window")
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget, flags: [.option])
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            try pointerMouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: widget, flags: [.control, .option])
            try pointerMouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            t.equal(menus, 4, "new Option secondary presses reach the native menu before a replacement picture")
            t.check(recorder.calls.isEmpty)
        }

        t.suite("App: Desk pointer events: desktop worker secondary Control and primary AX share qualified FIFO delivery") {
            let worker = SkinThreadExecutor(name: "Desk secondary pointer worker test")
            var created: DeskWidgetWindowController?
            defer {
                if let created {
                    created.close(deactivate: false)
                    t.check(AppSelfTest.spin(timeout: 10) { created.isClosed })
                }
                worker.stop()
            }
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, executor: worker, text: pointerSource)
            created = widget
            var menus = 0
            widget.view.contextMenuPresenterForTesting = { menu, _ in
                menus += 1
                t.equal(menu.items.map(\.title), [StudioText[.removeWidgetFromDesktop]], "the actual component menu stays reachable")
            }
            t.equal(widget.view.accessibilityParts.count, 2, "right-only and empty-secondary Text expose no primary AX button")
            let first = widget.latestPresented?.scene.generation ?? 0
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget)
            t.check(recorder.calls.isEmpty, "secondary actions wait for release")
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            t.check(AppSelfTest.spin(timeout: 10) {
                recorder.calls.count == 2 && (widget.latestPresented?.scene.generation ?? 0) > first
            })
            t.equal(recorder.calls, ["copy:1", "open:https://example.com/1"])
            let second = widget.latestPresented?.scene.generation ?? 0
            try pointerMouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: widget, flags: [.control])
            try pointerMouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            t.check(AppSelfTest.spin(timeout: 10) {
                recorder.calls.count == 4 && (widget.latestPresented?.scene.generation ?? 0) > second
            })
            t.equal(recorder.calls, ["copy:1", "open:https://example.com/1", "copy:2", "open:https://example.com/2"],
                    "releasing Control before mouse-up preserves the initially selected secondary event")
            let third = widget.latestPresented?.scene.generation ?? 0
            try pointerMouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: widget)
            try pointerMouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: widget, flags: [.control])
            t.check(AppSelfTest.spin(timeout: 10) {
                recorder.calls.count == 5 && (widget.latestPresented?.scene.generation ?? 0) > third
            })
            t.equal(recorder.calls.last, "copy:primary", "adding Control at release cannot change a primary press")
            guard let child = widget.view.accessibilityParts.first else { throw Failure.fixture }
            t.check(child.accessibilityPerformPress())
            t.check(AppSelfTest.spin(timeout: 10) { recorder.calls.count == 6 })
            t.equal(recorder.calls.last, "copy:primary", "AX Press always activates the primary handler")
            t.check(recorder.mainThreads.allSatisfy { $0 })
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 280, y: 20), in: widget)
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 280, y: 20), in: widget)
            t.equal(menus, 1, "missing right handler opens the component menu at the original press boundary")
            t.equal(recorder.calls.count, 6)
        }

        t.suite("App: Desk pointer events: desktop secondary cross-leaf drag nil cancellation empty and Option menu routing") {
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, text: pointerSource)
            var menus = 0
            widget.view.contextMenuPresenterForTesting = { _, _ in menus += 1 }
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget)
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 100, y: 20), in: widget)
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget)
            try pointerMouse(.rightMouseDragged, at: NSPoint(x: 100, y: 20), in: widget)
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            try pointerMouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: widget, flags: [.control])
            try pointerMouse(.leftMouseDragged, at: NSPoint(x: 100, y: 20), in: widget)
            try pointerMouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            var drained = false
            widget.executor.async { DispatchQueue.main.async { drained = true } }
            t.check(AppSelfTest.spin(timeout: 10) { drained })
            t.check(recorder.calls.isEmpty, "cross-leaf release and both secondary drag paths cancel without primary leakage")
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget)
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget, flags: [.option])
            try pointerMouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: widget, flags: [.control, .option])
            try pointerMouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget, flags: [.option])
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            t.equal(menus, 3, "Option at press or release reaches the menu exactly once, including Control+Option")
            let generation = widget.latestPresented?.scene.generation ?? 0
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 200, y: 20), in: widget)
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 200, y: 20), in: widget)
            t.check(AppSelfTest.spin(timeout: 10) { (widget.latestPresented?.scene.generation ?? 0) > generation })
            t.equal(menus, 3, "an empty right handler consumes the click instead of falling through to the menu")
            guard let token = widget.issueClickToken() else { throw Failure.fixture }
            widget.owner.secondaryPress(at: SkinPoint(x: 20, y: 20), expectedGeneration: token.sourceGeneration, epoch: token.epoch)
            widget.owner.secondaryRelease(at: nil, expectedGeneration: nil)
            widget.sendSecondaryRelease(at: SkinPoint(x: 20, y: 20))
            drained = false
            widget.executor.async { DispatchQueue.main.async { drained = true } }
            t.check(AppSelfTest.spin(timeout: 10) { drained })
            t.check(recorder.calls.isEmpty)
            widget.view.isHidden = true
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget, flags: [.option])
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            widget.view.isHidden = false
            t.equal(menus, 3, "an invisible view exposes neither secondary actions nor a menu")
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget)
            widget.handleUnavailable("invalidEnvironment", session: widget.sessionID, epoch: widget.destinationEpoch)
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget, flags: [.option])
            t.equal(menus, 4, "same-epoch Option release remains a native menu when the program becomes unavailable")
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget, flags: [.option])
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            try pointerMouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: widget, flags: [.control])
            try pointerMouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
            t.equal(menus, 6, "an unavailable widget retains the original native Remove menu")
            t.check(recorder.calls.isEmpty)
        }

        t.suite("App: Desk pointer events: desktop secondary epoch close and delayed batch guards reject stale activation") {
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, text: pointerSource)
            var menus = 0
            widget.view.contextMenuPresenterForTesting = { _, _ in menus += 1 }
            try pointerMouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: widget)
            guard let token = widget.issueClickToken() else { throw Failure.fixture }
            widget.owner.secondaryPress(at: SkinPoint(x: 20, y: 20), expectedGeneration: token.sourceGeneration, epoch: token.epoch)
            var effects: [ProgramEffect]?
            widget.owner.secondaryRelease(at: SkinPoint(x: 20, y: 20), token: token) { _, value in effects = value }
            guard let effects else { throw Failure.fixture }
            let dark = widget.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            widget.window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            _ = widget.currentFacts()
            t.check(widget.destinationEpoch != token.epoch)
            try pointerMouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: widget, flags: [.option])
            widget.handleEffects(effects, token: token, issuedToken: token)
            t.equal(menus, 0, "a stale press cannot adopt a new destination to open a menu")
            t.check(recorder.calls.isEmpty)
            widget.close(deactivate: false)
            widget.handleEffects(effects, token: token, issuedToken: token)
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            t.check(recorder.calls.isEmpty)
        }
    }

    private static func accessibilityTests(_ t: AppTestRunner) {
        t.suite("App: Desk accessibility: projected Text label and AX press execute once on Main from a worker") {
            let worker = SkinThreadExecutor(name: "Desk accessibility worker test")
            var created: DeskWidgetWindowController?
            defer {
                if let created {
                    created.close(deactivate: false)
                    t.check(AppSelfTest.spin(timeout: 10) { created.isClosed })
                }
                worker.stop()
            }
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, executor: worker)
            created = widget
            t.equal(widget.view.accessibilityParts.count, 1)
            guard let child = widget.view.accessibilityParts.first, let presented = widget.latestPresented,
                  let element = presented.scene.elements.first(where: { $0.id == child.id }),
                  case .text(let text)? = element.items.first else { throw Failure.fixture }
            t.equal(child.accessibilityRole(), .button)
            t.equal(child.accessibilityLabel(), text.text)
            t.equal(child.accessibilityLabel(), "0")
            t.check((child.accessibilityParent() as? DeskWidgetView) === widget.view)
            t.equal(widget.view.accessibilityChildren()?.count, 1)
            let localFrame = NSRect(x: element.frame.x - presented.origin.x, y: element.frame.y - presented.origin.y,
                                   width: element.frame.width, height: element.frame.height)
            t.equal(child.accessibilityFrame(), NSAccessibility.screenRect(fromView: widget.view, rect: localFrame))
            let beforeMove = child.accessibilityFrame()
            widget.window.setFrameOrigin(NSPoint(x: widget.window.frame.origin.x + 11, y: widget.window.frame.origin.y + 7))
            t.close(child.accessibilityFrame().origin.x - beforeMove.origin.x, 11)
            t.close(child.accessibilityFrame().origin.y - beforeMove.origin.y, 7)
            t.check(child.accessibilityPerformPress())
            t.check(!child.accessibilityPerformPress(), "a held child cannot queue a second activation")
            t.check(AppSelfTest.spin(timeout: 10) { recorder.calls.count == 3 })
            t.equal(recorder.calls, ["copy:1", "open:https://example.com/1", "copy:done😀"])
            t.check(recorder.mainThreads.allSatisfy { $0 }, "all injected services execute on Main")
            t.check(AppSelfTest.spin(timeout: 10) { widget.view.accessibilityParts.first?.accessibilityLabel() == "1" })
            t.check(!child.accessibilityPerformPress(), "the previous frame's child remains invalid after presentation")
        }

        t.suite("App: Desk accessibility: redraw replaces held children without replaying actions and unavailable clears them") {
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder)
            guard let child = widget.view.accessibilityParts.first else { throw Failure.fixture }
            widget.owner.host?.refresh()
            widget.owner.host?.frames.runLoopTurn(.beforeWaiting)
            t.check(AppSelfTest.spin(timeout: 10) { (widget.latestPresented?.scene.generation ?? 0) > child.generation })
            t.check(widget.view.accessibilityParts.first !== child)
            t.check(!child.accessibilityPerformPress(), "AX must not synthesize a fresh generation for a held child")
            t.equal(child.accessibilityFrame(), .zero)
            t.check(recorder.calls.isEmpty, "ordinary projection and AX tree refresh have no effects")
            guard let current = widget.view.accessibilityParts.first else { throw Failure.fixture }
            widget.handleUnavailable("invalidEnvironment", session: widget.sessionID, epoch: widget.destinationEpoch)
            t.equal(widget.view.accessibilityChildren()?.count, 0)
            t.check(!current.accessibilityPerformPress())
            t.equal(current.accessibilityFrame(), .zero)
            t.check(recorder.calls.isEmpty)
        }

        t.suite("App: Desk accessibility: epoch transition and close invalidate children before any queued effect") {
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder)
            guard let child = widget.view.accessibilityParts.first else { throw Failure.fixture }
            let dark = widget.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard let alternate = NSAppearance(named: dark ? .aqua : .darkAqua) else { throw Failure.fixture }
            widget.window.appearance = alternate
            _ = widget.currentFacts()
            t.check(widget.destinationEpoch != child.epoch)
            t.equal(widget.view.accessibilityParts.count, 0)
            t.check(!child.accessibilityPerformPress(), "epoch guard applies before a replacement frame arrives")
            t.check(recorder.calls.isEmpty)
            let closeRecorder = ActionRecorder(), closing = try actionFixture(t, recorder: closeRecorder)
            guard let closingChild = closing.view.accessibilityParts.first else { throw Failure.fixture }
            closing.close(deactivate: false)
            t.equal(closing.view.accessibilityParts.count, 0)
            t.check(!closingChild.accessibilityPerformPress(), "close invalidates AX before owner ACK")
            t.check(AppSelfTest.spin(timeout: 10) { closing.isClosed })
            t.check(!closingChild.accessibilityPerformPress())
            t.equal(closingChild.accessibilityFrame(), .zero)
            t.check(closeRecorder.calls.isEmpty)
        }

        t.suite("App: Desk accessibility: hidden Text has no child and pointer-ineligible facts suppress activation") {
            let recorder = ActionRecorder()
            let source = #"widget { Column { Text("Hidden").size(160, 40).hidden().onClick { copy("hidden") }; Text("Visible").size(160, 40).onClick { copy("visible") } } }"#
            let widget = try actionFixture(t, recorder: recorder, text: source)
            t.equal(widget.view.accessibilityParts.count, 1)
            guard let child = widget.view.accessibilityParts.first else { throw Failure.fixture }
            t.equal(child.accessibilityLabel(), "Visible")
            let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
                                                                 scale: widget.window.backingScaleFactor)
            guard let space = widget.window.colorSpace?.cgColorSpace else { throw Failure.fixture }
            let facts = SkinWindowFacts(frame: widget.window.frame, isVisible: true, isOrderedIn: true,
                scale: widget.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
                takesPointer: false, sequence: 101, panelGeneration: widget.destinationEpoch)
            widget.owner.take(facts, input: input)
            t.check(child.accessibilityPerformPress(), "Main queues explicit AX activation; owner qualifies pointer facts")
            var drained = false
            widget.executor.async { DispatchQueue.main.async { drained = true } }
            t.check(AppSelfTest.spin(timeout: 10) { drained })
            t.check(recorder.calls.isEmpty, "AX cannot bypass the owner's pointer eligibility guard")
        }

        t.suite("App: Desk accessibility: accepted viewport origin and actual center hit reject an overlapped handler") {
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder)
            guard let original = widget.latestPresented, let originalChild = widget.view.accessibilityParts.first,
                  let element = original.scene.elements.first(where: { $0.id == originalChild.id }),
                  let coveredEntry = original.scene.hitMap.entries.first else { throw Failure.fixture }
            var scene = original.scene
            scene.generation += 1
            let overlay = SkinHitMap.Entry(name: "overlay", frame: coveredEntry.frame, shape: coveredEntry.shape,
                container: coveredEntry.container, glass: coveredEntry.glass, isButton: coveredEntry.isButton,
                actions: coveredEntry.actions, cursor: coveredEntry.cursor, cursorName: coveredEntry.cursorName,
                toolTip: coveredEntry.toolTip, elementID: ElementID(name: "overlay", index: 999))
            scene.hitMap.entries.insert(overlay, at: 0)
            let origin = SkinPoint(x: -11, y: -17)
            let covered = DeskProgramHost.Presented(scene: scene, origin: origin, size: original.size, scale: original.scale)
            widget.handlePresented(covered, session: widget.sessionID, epoch: widget.destinationEpoch)
            guard let child = widget.view.accessibilityParts.first else { throw Failure.fixture }
            let localFrame = NSRect(x: element.frame.x - origin.x, y: element.frame.y - origin.y,
                                   width: element.frame.width, height: element.frame.height)
            t.equal(child.accessibilityFrame(), NSAccessibility.screenRect(fromView: widget.view, rect: localFrame))
            t.check(!originalChild.accessibilityPerformPress())
            t.check(!child.accessibilityPerformPress(), "center resolves to the overlay rather than the exposed Text")
            t.check(recorder.calls.isEmpty)
        }
    }

    private static func clickActionTests(_ t: AppTestRunner) {
        t.suite("App: Desk click actions: worker release delivers exactly once on Main") {
            let worker = SkinThreadExecutor(name: "Desk click action worker test")
            var created: DeskWidgetWindowController?
            defer {
                if let created {
                    created.close(deactivate: false)
                    t.check(AppSelfTest.spin(timeout: 10) { created.isClosed })
                }
                worker.stop()
            }
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, executor: worker)
            created = widget
            guard let presented = widget.latestPresented else { throw Failure.fixture }
            let point = SkinPoint(x: 20, y: 20), epoch = widget.lastAcceptedEpoch
            worker.async { [owner = widget.owner] in
                owner.primaryPress(at: point, expectedGeneration: presented.scene.generation, epoch: epoch)
            }
            widget.sendPrimaryRelease(at: point)
            t.check(AppSelfTest.spin(timeout: 10) { recorder.calls.count == 3 })
            t.equal(recorder.calls, ["copy:1", "open:https://example.com/1", "copy:done😀"])
            t.check(recorder.mainThreads.allSatisfy { $0 }, "every injected service executes on Main")
            // A release without a new press must not execute any service, even if a newer frame was accepted.
            widget.sendPrimaryRelease(at: point)
            var drained = false
            worker.async { DispatchQueue.main.async { drained = true } }
            t.check(AppSelfTest.spin(timeout: 10) { drained })
            t.equal(recorder.calls.count, 3)
        }

        t.suite("App: Desk click actions: newer accepted frames keep captured effects and duplicate batches are consumed") {
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder)
            let (token, effects) = try frozenActionBatch(widget)
            widget.owner.host?.refresh()
            widget.owner.host?.frames.runLoopTurn(.beforeWaiting)
            t.check(AppSelfTest.spin(timeout: 10) {
                (widget.latestPresented?.scene.generation ?? 0) > token.sourceGeneration
            }, "a normal later projection is accepted before the delayed action batch")
            widget.handleEffects(effects, token: token, issuedToken: token)
            t.equal(recorder.calls, ["copy:1", "open:https://example.com/1", "copy:done😀"],
                    "resolved strings retain the clicked transaction, not a later frame")
            widget.handleEffects(effects, token: token, issuedToken: token)
            t.equal(recorder.calls.count, 3, "duplicate callback cannot execute a batch twice")
            guard let another = widget.issueClickToken() else { throw Failure.fixture }
            widget.handleEffects(effects, token: another, issuedToken: token)
            t.equal(recorder.calls.count, 3, "returned token must equal the token captured by Main's input closure")
        }

        t.suite("App: Desk click actions: destination epoch and close cancel delayed batches") {
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder)
            let (token, effects) = try frozenActionBatch(widget)
            let appearance = widget.window.effectiveAppearance
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard let alternate = NSAppearance(named: dark ? .aqua : .darkAqua) else { throw Failure.fixture }
            widget.window.appearance = alternate
            _ = widget.currentFacts()
            t.check(widget.destinationEpoch != token.epoch)
            widget.handleEffects(effects, token: token, issuedToken: token)
            t.check(recorder.calls.isEmpty, "the destination transition invalidates pending user requests")
            widget.close(deactivate: false)
            widget.handleEffects(effects, token: token, issuedToken: token)
            t.check(recorder.calls.isEmpty, "closing invalidates pending requests before owner ACK")
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            widget.handleEffects(effects, token: token, issuedToken: token)
            t.check(recorder.calls.isEmpty)
            let closeRecorder = ActionRecorder(), closingWidget = try actionFixture(t, recorder: closeRecorder)
            let (closeToken, closeEffects) = try frozenActionBatch(closingWidget)
            closingWidget.close(deactivate: false)
            closingWidget.handleEffects(closeEffects, token: closeToken, issuedToken: closeToken)
            t.check(closeRecorder.calls.isEmpty, "close alone cancels an otherwise valid current-epoch batch")
            t.check(AppSelfTest.spin(timeout: 10) { closingWidget.isClosed })
        }

        t.suite("App: Desk click actions: failed open gives localized feedback and later requests still run") {
            let recorder = ActionRecorder()
            recorder.opensSucceed = false
            let widget = try actionFixture(t, recorder: recorder)
            let (token, effects) = try frozenActionBatch(widget)
            widget.handleEffects(effects, token: token, issuedToken: token)
            t.equal(recorder.calls, ["copy:1", "open:https://example.com/1", "copy:done😀"])
            t.equal(widget.lastActionFailure, StudioText.format(.deskActionOpenFailed, "https://example.com/1"))
            t.equal(widget.view.toolTip, widget.lastActionFailure)
        }

        t.suite("App: Desk click actions: service reentrant close suppresses later requests and replay") {
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder)
            let (token, effects) = try frozenActionBatch(widget)
            recorder.onCopy = { [weak widget] _ in widget?.close(deactivate: false) }
            widget.handleEffects(effects, token: token, issuedToken: token)
            t.equal(recorder.calls, ["copy:1"], "a service-triggered close stops the remaining open/copy requests")
            widget.handleEffects(effects, token: token, issuedToken: token)
            t.equal(recorder.calls, ["copy:1"], "the batch was consumed before the reentrant service call")
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
        }

        t.suite("App: Desk click actions: resolver uses fake targets and services without opening the Mac") {
            let directory = t.temporaryDirectory("desk-action-targets")
            let file = directory.appendingPathComponent("notes.txt")
            let folder = directory.appendingPathComponent("Folder")
            let app = directory.appendingPathComponent("Example.app")
            var bundleLookups: [String] = [], nameLookups: [String] = []
            let resolver = DeskProgramOpenResolver(application: { name in
                bundleLookups.append(name); return name == "com.example.app" ? app : nil
            }, applicationNamed: { name in
                nameLookups.append(name); return name == "Example" ? app : nil
            }, exists: { [file.path, folder.path].contains($0.path) })
            t.equal(resolver.resolve("notes.txt", directory: directory), file)
            t.equal(resolver.resolve(folder.path, directory: directory), folder)
            t.equal(resolver.resolve(file.absoluteString, directory: directory), file)
            t.equal(resolver.resolve("com.example.app", directory: directory), app)
            t.equal(resolver.resolve("Example", directory: directory), app)
            t.equal(resolver.resolve("https://example.com/page", directory: directory)?.absoluteString, "https://example.com/page")
            for invalid in ["", "   ", "https://", "https:///?x=1", "missing/file.txt", "bad\0target"] {
                t.check(resolver.resolve(invalid, directory: directory) == nil, "invalid target: \(invalid)")
            }
            t.check(bundleLookups.contains("com.example.app") && nameLookups.contains("Example"))
            var copied: [String] = [], opened: [URL] = []
            let services = DeskProgramActionServices(resolver: resolver, copy: { copied.append($0); return false },
                                                     open: { opened.append($0); return true })
            t.equal(services.perform(.copy("text😀"), directory: directory), StudioText[.deskActionCopyFailed])
            t.equal(copied, ["text😀"])
            t.equal(services.perform(.open("notes.txt"), directory: directory), nil)
            t.equal(opened, [file])
            t.equal(services.perform(.open("missing/file.txt"), directory: directory),
                    StudioText.format(.deskActionOpenFailed, "missing/file.txt"))
            t.equal(opened, [file], "an unresolved target never reaches even the fake opener")
            let oldLanguage = StudioText.languageOverride
            defer { StudioText.languageOverride = oldLanguage }
            StudioText.languageOverride = .chinese
            let target = "missing/\u{E000}文档\u{E001}.txt"
            t.equal(services.perform(.open(target), directory: directory),
                    String(format: StudioText[.deskActionOpenFailed], target),
                    "open feedback preserves legitimate private-use characters in the exact target")
            t.equal(opened, [file], "the unresolved private-use target never reaches the fake opener")
        }
    }
}
