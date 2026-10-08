import AppKit
import Darwin
import ImageIO
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

    private static func fixture(_ t: AppTestRunner, text: String = sampleDeskText, presentsWindows: Bool = false,
                                images: [String: Data] = [:]) throws -> Fixture {
        let root = t.temporaryDirectory("desk-widget-window-test")
        let file = root.appendingPathComponent("Widget.desk")
        try Data(text.utf8).write(to: file)
        for (path, bytes) in images {
            let image = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: image)
        }
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
        presetAccessibilityTests(t)
        pointerEventTests(t)
        reviewRegressionTests(t)
        mainDeliveryTests(t)
        compositionPreflightTests(t)
        conditionalBackgroundTests(t)
        gaugeTests(t)
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

            // 3. Restore the actual destination profile, not just another RGB profile.
            let factsValidCS = widgetWin.currentFacts()
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
                colorSpace: widgetWin.window.colorSpace?.cgColorSpace,
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
            // the queued unavailable and frame-delivery blocks have run.
            var staleReceiptsDrained = false
            DispatchQueue.main.async {
                // Check at the FIFO boundary itself: rejecting a stale delivery now asks for fresh facts and
                // can accept a current-epoch recovery later in this same RunLoop spin.
                t.equal(widgetWin.lastUnavailableMessage, nil, "queued stale unavailable receipt was rejected on epoch mismatch")
                t.equal(widgetWin.lastAcceptedEpoch, initialEpoch, "queued stale presented receipt was rejected on epoch mismatch")
                t.equal(widgetWin.latestPresented?.scene.generation, initialPresented.scene.generation,
                        "latestPresented preserved from initial until a qualified recovery")
                staleReceiptsDrained = true
            }
            t.check(AppSelfTest.spin(timeout: 5) { staleReceiptsDrained }, "queued stale receipts processed before assertion")

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
                colorSpace: widgetWin.window.colorSpace?.cgColorSpace,
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
                                      clock: SkinClock = .live,
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
                                               clock: clock,
                                               actionServices: recorder.services)
        func presentationState() -> String {
            "started=\(widget.isStarted), closing=\(widget.isClosing), closed=\(widget.isClosed), " +
            "unavailable=\(String(describing: widget.lastUnavailableMessage)), " +
            "epoch=\(widget.destinationEpoch), acceptedEpoch=\(widget.lastAcceptedEpoch), " +
            "generation=\(String(describing: widget.latestPresented?.scene.generation)), " +
            "origin=\(String(describing: widget.latestPresented?.origin)), size=\(String(describing: widget.latestPresented?.size)), " +
            "scale=\(widget.window.backingScaleFactor), appearance=\(widget.window.effectiveAppearance.name.rawValue), " +
            "colorSpace=\(String(describing: widget.window.colorSpace))"
        }
        try beforePresentation?(widget)
        t.check(AppSelfTest.spin(timeout: 10) {
            (executor as? VirtualTimeExecutor)?.runUntilIdle()
            return widget.isStarted && widget.latestPresented != nil
        }, "first presentation: \(presentationState())")
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
        t.check(AppSelfTest.spin(timeout: 10) {
            (executor as? VirtualTimeExecutor)?.runUntilIdle()
            return delivered && widget.latestPresented != nil
        }, "controlled facts delivered=\(delivered): \(presentationState())")
        // Main acceptance now precedes an owner FIFO ACK. Pointer tests must start after that receipt.
        let generation = widget.latestPresented?.scene.generation
        var acknowledged = false
        executor.async { [owner = widget.owner] in
            let accepted = owner.host?.presented?.scene.generation == generation
            DispatchQueue.main.async { acknowledged = accepted }
        }
        t.check(AppSelfTest.spin(timeout: 10) {
            (executor as? VirtualTimeExecutor)?.runUntilIdle()
            return acknowledged
        }, "the owner acknowledged Main's accepted picture")
        return widget
    }

    private static func compositionPreflightTests(_ t: AppTestRunner) {
        t.suite("App: Desk composition preflight: rejected fallback option preserves accepted state pixels and persistence") {
            let fallback = SkinGlassViews.forcesFallback
            SkinGlassViews.forcesFallback = true
            t.atSuiteEnd { SkinGlassViews.forcesFallback = fallback }
            let widget = try actionFixture(t, recorder: ActionRecorder(), text: compositionPreflightSource())
            guard let host = widget.owner.host, let presented = widget.latestPresented,
                  let image = widget.content.shown.image else { throw Failure.fixture }
            let initial = try host.optionsSnapshot(), scene = host.scene
            let pixels = try DeskConditionalTestSupport.bytes(image)
            let stored = widget.app.state.deskInstance(widget.instance.id)?.optionValues
            let serial = widget.lastPresentationSerial
            t.equal(host.presented?.scene.generation, presented.scene.generation, "the red bitmap has received its owner ACK")
            t.equal(scene?.generation, presented.scene.generation)
            t.check(!host.frames.bitmapCompositionSupportsSystemGlass, "the destination captured the controlled fallback mode")
            t.equal(initial.values.values["glass"], .boolean(false))
            checkCompositionColor(t, pixels, blue: false)
            var clears = 0
            let forward = host.frames.requestBitmapDelivery
            host.frames.requestBitmapDelivery = { request in
                if case .clear = request { clears += 1 }
                forward?(request)
            }

            var values = initial.values.values
            values["glass"] = .boolean(true)
            var replies: [Result<ProgramOptionsSnapshot, Error>] = []
            host.updateOptions(.init(values: values), expectedRevision: initial.revision) { replies.append($0) }
            t.equal(replies.count, 1)
            if let reply = replies.first, case .failure = reply { t.check(true) }
            else { t.check(false, "overlapping fallback glass must reject the candidate before reporting option success") }
            host.frames.runLoopTurn(.beforeWaiting)
            reviewDrainOwner(widget, t); reviewDrainOwner(widget, t)
            t.equal(try host.optionsSnapshot(), initial)
            t.equal(host.scene, scene)
            t.equal(host.state, .ready)
            t.equal(widget.latestPresented?.scene, presented.scene)
            t.equal(host.presented?.scene, presented.scene)
            t.equal(widget.optionsSnapshot, initial)
            t.equal(widget.lastPresentationSerial, serial)
            t.equal(clears, 0, "a rejected option must not enqueue a destructive Main clear")
            t.check(widget.content.shown.image === image)
            if let shown = widget.content.shown.image {
                t.equal(try DeskConditionalTestSupport.bytes(shown), pixels)
            } else { t.check(false, "the accepted red pixels must remain available") }
            t.check(widget.nativeComposition.isHidden && widget.nativeComposition.shownPieces.isEmpty)
            t.equal(widget.app.state.deskInstance(widget.instance.id)?.optionValues, stored,
                    "a failed projection cannot become a durable option value")
            t.equal(widget.lastUnavailableMessage, nil)

            // Use the current revision to qualify a subsequent legal change.
            let current = try host.optionsSnapshot()
            values = current.values.values
            values["glass"] = .boolean(false); values["blue"] = .boolean(true)
            var recovered: Result<ProgramOptionsSnapshot, Error>?
            host.updateOptions(.init(values: values), expectedRevision: current.revision) { recovered = $0 }
            guard let recovered else { throw Failure.fixture }
            let accepted = try recovered.get()
            t.equal(accepted.revision, initial.revision + 1, "only the legal change advances the option revision")
            t.equal(accepted.values.values["glass"], .boolean(false))
            t.equal(accepted.values.values["blue"], .boolean(true))
            host.frames.runLoopTurn(.beforeWaiting)
            t.check(AppSelfTest.spin(timeout: 10) {
                widget.latestPresented?.scene.generation == host.scene?.generation
                    && widget.content.shown.image != nil && !host.frames.hasBitmapDelivery
            }, "the legal blue bitmap is accepted and acknowledged after the rejected candidate")
            guard let blueImage = widget.content.shown.image else { throw Failure.fixture }
            checkCompositionColor(t, try DeskConditionalTestSupport.bytes(blueImage), blue: true)
            t.check(blueImage !== image)
            t.equal(host.state, .ready)
            t.equal(widget.lastUnavailableMessage, nil)
            t.equal(clears, 0)
        }

        t.suite("App: Desk composition preflight: rejected fallback click commits neither option nor copy effects") {
            let fallback = SkinGlassViews.forcesFallback
            SkinGlassViews.forcesFallback = true
            t.atSuiteEnd { SkinGlassViews.forcesFallback = fallback }
            let recorder = ActionRecorder()
            let widget = try actionFixture(t, recorder: recorder, text: compositionPreflightSource(click: true))
            guard let host = widget.owner.host, let presented = widget.latestPresented,
                  let image = widget.content.shown.image, let token = widget.issueClickToken() else { throw Failure.fixture }
            let initial = try host.optionsSnapshot(), scene = host.scene
            let pixels = try DeskConditionalTestSupport.bytes(image)
            let stored = widget.app.state.deskInstance(widget.instance.id)?.optionValues
            t.equal(host.presented?.scene.generation, presented.scene.generation)
            t.check(!host.frames.bitmapCompositionSupportsSystemGlass)
            checkCompositionColor(t, pixels, blue: false)
            var clears = 0
            let forward = host.frames.requestBitmapDelivery
            host.frames.requestBitmapDelivery = { request in
                if case .clear = request { clears += 1 }
                forward?(request)
            }
            var rejectedGenerations: [UInt64] = []
            let forwardRejection = host.didRejectProjection
            host.didRejectProjection = { message, generation in
                t.check(!message.isEmpty)
                rejectedGenerations.append(generation)
                forwardRejection?(message, generation)
            }
            let point = SkinPoint(x: 20, y: 20)
            widget.owner.primaryPress(at: point, expectedGeneration: token.sourceGeneration, epoch: token.epoch)
            var batches: [[ProgramEffect]] = []
            widget.owner.primaryRelease(at: point, token: token) { returned, effects in
                batches.append(effects)
                widget.handleEffects(effects, token: returned, issuedToken: token)
            }
            t.equal(batches, [], "the failed composition must not release a frozen effect batch")
            t.equal(recorder.calls, [], "the injected copy service must not run before qualification")
            t.equal(rejectedGenerations, [presented.scene.generation], "the rejection names the retained accepted scene")
            t.equal(widget.lastActionFailure, nil, "owner rejection reaches feedback through the Main hop")
            host.frames.runLoopTurn(.beforeWaiting)
            reviewDrainOwner(widget, t); reviewDrainOwner(widget, t)
            t.equal(try host.optionsSnapshot(), initial)
            t.equal(host.scene, scene)
            t.equal(host.state, .ready)
            t.equal(widget.latestPresented?.scene, presented.scene)
            t.equal(host.presented?.scene, presented.scene)
            t.equal(clears, 0)
            t.check(widget.content.shown.image === image)
            if let shown = widget.content.shown.image {
                t.equal(try DeskConditionalTestSupport.bytes(shown), pixels)
            } else { t.check(false, "a failed click keeps the previously accepted red pixels") }
            t.check(widget.nativeComposition.isHidden && widget.nativeComposition.shownPieces.isEmpty)
            t.equal(widget.app.state.deskInstance(widget.instance.id)?.optionValues, stored)
            t.equal(recorder.calls, [])
            t.equal(widget.lastUnavailableMessage, nil)
            t.equal(widget.lastActionFailure, StudioText[.deskOptionsChangeFailed])
            t.equal(widget.view.toolTip, StudioText[.deskOptionsChangeFailed])
        }

        t.suite("App: Desk composition preflight: qualified glass and bitmap switches replace native views and pixels") {
            let fallback = SkinGlassViews.forcesFallback
            SkinGlassViews.forcesFallback = true
            t.atSuiteEnd { SkinGlassViews.forcesFallback = fallback }
            let source = """
            options { glass = Toggle("Glass"); oversized = Toggle("Oversized") }
            widget {
                Freeform {
                    if options.oversized {
                        Column { }.size(2049).position(x: 0, y: 0).background(.glass)
                    } else if options.glass {
                        Column { }.size(80, 40).position(x: 0, y: 0).background(.glass)
                        Rectangle().size(16, 12).position(x: 8, y: 6).fill("#0000FF")
                    } else {
                        Rectangle().size(80, 40).position(x: 0, y: 0).fill("#FF0000")
                    }
                }.size(80, 40)
            }
            """
            let widget = try actionFixture(t, recorder: ActionRecorder(), text: source)
            guard let host = widget.owner.host, let original = widget.latestPresented,
                  let redImage = widget.content.shown.image else { throw Failure.fixture }
            let initial = try host.optionsSnapshot()
            checkCompositionColor(t, try DeskConditionalTestSupport.bytes(redImage), blue: false)
            t.check(!host.frames.bitmapCompositionSupportsSystemGlass)
            var clears = 0
            let forward = host.frames.requestBitmapDelivery
            host.frames.requestBitmapDelivery = { request in
                if case .clear = request { clears += 1 }
                forward?(request)
            }

            var values = initial.values.values
            values["oversized"] = .boolean(true)
            var budgetReply: Result<ProgramOptionsSnapshot, Error>?
            host.updateOptions(.init(values: values), expectedRevision: initial.revision) { budgetReply = $0 }
            guard let budgetReply else { throw Failure.fixture }
            if case .failure(let error) = budgetReply {
                t.equal(error as? SkinBitmapComposer.Failure, .bitmapBudgetExceeded,
                        "the oversized scratch is rejected by the real composer before allocation")
            } else { t.check(false, "the composition scratch exceeds the 16 MiB budget") }
            host.frames.runLoopTurn(.beforeWaiting)
            reviewDrainOwner(widget, t); reviewDrainOwner(widget, t)
            t.equal(try host.optionsSnapshot(), initial)
            t.equal(widget.latestPresented?.scene, original.scene)
            t.equal(host.presented?.scene, original.scene)
            t.check(widget.content.shown.image === redImage)
            t.equal(clears, 0)
            t.equal(widget.lastUnavailableMessage, nil)

            values = initial.values.values
            values["glass"] = .boolean(true)
            var glassReply: Result<ProgramOptionsSnapshot, Error>?
            host.updateOptions(.init(values: values), expectedRevision: initial.revision) { glassReply = $0 }
            guard let glassReply else { throw Failure.fixture }
            let glassOptions = try glassReply.get()
            t.equal(glassOptions.revision, initial.revision + 1)
            host.frames.runLoopTurn(.beforeWaiting)
            t.check(host.frames.hasBitmapDelivery)
            t.check(widget.content.shown.image === redImage && widget.nativeComposition.isHidden,
                    "qualification alone cannot replace Main's accepted picture")
            t.equal(host.presented?.scene, original.scene)
            t.check(AppSelfTest.spin(timeout: 10) {
                widget.latestPresented?.scene.generation == host.scene?.generation
                    && !host.frames.hasBitmapDelivery && !widget.nativeComposition.isHidden
            })
            guard let piece = widget.nativeComposition.shownPieces.first,
                  let pixelLayer = widget.nativeComposition.shownPixels.first,
                  let contents = pixelLayer.contents,
                  CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { throw Failure.fixture }
            let blueImage = contents as! CGImage
            t.equal(widget.nativeComposition.shownPieces.count, 1)
            t.equal(widget.nativeComposition.shownPixels.count, 1)
            t.equal(widget.nativeComposition.subviews.count, 2)
            t.check(widget.nativeComposition.subviews.first === piece.frameView)
            t.equal(piece.frameView.frame, NSRect(x: 0, y: 0, width: 80, height: 40))
            t.equal((piece.glass as? NSVisualEffectView)?.blendingMode, .behindWindow)
            t.equal(widget.nativeComposition.subviews.last?.frame, NSRect(x: 0, y: 0, width: 80, height: 40))
            let scale = pixelLayer.contentsScale
            guard scale.isFinite, scale > 0 else { throw Failure.fixture }
            t.equal(scale, widget.window.backingScaleFactor)
            t.equal(blueImage.width, Int(ceil(80 * scale)))
            t.equal(blueImage.height, Int(ceil(40 * scale)))
            let rgba = try DeskConditionalTestSupport.bytes(blueImage)
            guard rgba.count == blueImage.width * blueImage.height * 4 else { throw Failure.fixture }
            let blueRect = CGRect(x: 8 * scale, y: 6 * scale, width: 16 * scale, height: 12 * scale)
            var bluePixels = 0, hitPixels = 0
            var firstMismatch: String?
            for y in 0..<blueImage.height {
                for x in 0..<blueImage.width {
                    let minX = CGFloat(x), minY = CGFloat(y), maxX = CGFloat(x + 1), maxY = CGFloat(y + 1)
                    let inside = minX >= blueRect.minX && maxX <= blueRect.maxX &&
                        minY >= blueRect.minY && maxY <= blueRect.maxY
                    let outside = maxX <= blueRect.minX || minX >= blueRect.maxX ||
                        maxY <= blueRect.minY || minY >= blueRect.maxY
                    let offset = (y * blueImage.width + x) * 4
                    let pixel = Array(rgba[offset..<(offset + 4)])
                    let valid: Bool
                    if inside {
                        bluePixels += 1
                        valid = pixel[0] <= 2 && pixel[1] <= 2 && pixel[2] >= 250 && pixel[3] == 255
                    } else if outside {
                        hitPixels += 1
                        valid = pixel == [0, 0, 0, 1]
                    } else { continue } // A fractional-scale boundary may contain antialiased coverage.
                    if !valid, firstMismatch == nil { firstMismatch = "(\(x), \(y)): \(pixel)" }
                }
            }
            t.check(bluePixels > 0 && hitPixels > 0, "both the blue rectangle and surrounding native hit area are sampled")
            t.equal(firstMismatch, nil,
                    "every interior pixel at (8,6) is opaque blue; every exterior pixel is only the alpha-1 hit area")
            t.check(widget.content.shown.image == nil, "the foreground crop cannot become a whole-window glass cover")
            t.equal(host.presented?.scene, widget.latestPresented?.scene)

            values["glass"] = .boolean(false)
            var bitmapReply: Result<ProgramOptionsSnapshot, Error>?
            host.updateOptions(.init(values: values), expectedRevision: glassOptions.revision) { bitmapReply = $0 }
            guard let bitmapReply else { throw Failure.fixture }
            t.equal(try bitmapReply.get().revision, initial.revision + 2)
            host.frames.runLoopTurn(.beforeWaiting)
            t.check(piece.frameView.superview === widget.nativeComposition && pixelLayer.contents != nil)
            t.check(AppSelfTest.spin(timeout: 10) {
                widget.latestPresented?.scene.generation == host.scene?.generation
                    && !host.frames.hasBitmapDelivery && widget.content.shown.image != nil
            })
            guard let restoredImage = widget.content.shown.image else { throw Failure.fixture }
            checkCompositionColor(t, try DeskConditionalTestSupport.bytes(restoredImage), blue: false)
            t.check(widget.nativeComposition.isHidden && widget.nativeComposition.subviews.isEmpty)
            t.check(widget.nativeComposition.shownPieces.isEmpty && widget.nativeComposition.shownPixels.isEmpty)
            t.check(piece.frameView.superview == nil && pixelLayer.contents == nil,
                    "held native objects no longer retain the replaced glass or image")
            t.equal(host.presented?.scene, widget.latestPresented?.scene)
            t.equal(clears, 0, "successful format switches share frame delivery rather than independent clear requests")
        }

        t.suite("App: Desk composition preflight: rejection feedback cannot outlive its session epoch or accepted scene") {
            let widget = try actionFixture(t, recorder: ActionRecorder(), text: compositionPreflightSource())
            guard let host = widget.owner.host, let original = widget.latestPresented,
                  let redImage = widget.content.shown.image else { throw Failure.fixture }
            let session = widget.sessionID, epoch = widget.destinationEpoch
            let generation = original.scene.generation
            guard epoch > 0, generation > 0, generation < UInt64.max else { throw Failure.fixture }
            widget.handleRejectedProjection(session: UUID(), epoch: epoch, generation: generation)
            widget.handleRejectedProjection(session: session, epoch: epoch - 1, generation: generation)
            widget.handleRejectedProjection(session: session, epoch: epoch, generation: generation + 1)
            t.equal(widget.lastActionFailure, nil)
            t.equal(widget.view.toolTip, nil)
            widget.handleRejectedProjection(session: session, epoch: epoch, generation: generation)
            t.equal(widget.lastActionFailure, StudioText[.deskOptionsChangeFailed])
            t.equal(widget.view.toolTip, StudioText[.deskOptionsChangeFailed])
            t.equal(widget.latestPresented?.scene, original.scene)
            t.check(widget.content.shown.image === redImage)

            let initial = try host.optionsSnapshot()
            var values = initial.values.values
            values["blue"] = .boolean(true)
            var reply: Result<ProgramOptionsSnapshot, Error>?
            host.updateOptions(.init(values: values), expectedRevision: initial.revision) { reply = $0 }
            guard let reply else { throw Failure.fixture }
            _ = try reply.get()
            host.frames.runLoopTurn(.beforeWaiting)
            t.check(AppSelfTest.spin(timeout: 10) {
                widget.latestPresented?.scene.generation == host.scene?.generation && !host.frames.hasBitmapDelivery
            })
            guard let next = widget.latestPresented, let blueImage = widget.content.shown.image else { throw Failure.fixture }
            t.check(next.scene.generation > generation)
            checkCompositionColor(t, try DeskConditionalTestSupport.bytes(blueImage), blue: true)
            t.equal(widget.lastActionFailure, nil, "an accepted recovery clears the earlier rejection feedback")
            widget.handleRejectedProjection(session: session, epoch: epoch, generation: generation)
            t.equal(widget.lastActionFailure, nil, "a delayed rejection cannot overwrite a newer accepted scene")

            let isDark = widget.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard let alternate = NSAppearance(named: isDark ? .aqua : .darkAqua) else { throw Failure.fixture }
            widget.window.appearance = alternate
            _ = widget.currentFacts()
            t.check(widget.destinationEpoch > epoch)
            widget.handleRejectedProjection(session: session, epoch: epoch, generation: next.scene.generation)
            widget.handleRejectedProjection(session: session, epoch: widget.destinationEpoch, generation: next.scene.generation)
            t.equal(widget.lastActionFailure, nil, "both the destination and accepted epoch must match")
            t.check(widget.content.shown.image === blueImage)
            widget.close(deactivate: false)
            widget.handleRejectedProjection(session: session, epoch: epoch, generation: next.scene.generation)
            t.equal(widget.lastActionFailure, nil)
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            widget.handleRejectedProjection(session: widget.sessionID, epoch: widget.destinationEpoch,
                                            generation: next.scene.generation)
            t.equal(widget.lastActionFailure, nil)
            t.check(widget.latestPresented == nil && widget.content.shown.image == nil)
        }
    }

    private static func compositionPreflightSource(click: Bool = false) -> String {
        """
        options { glass = Toggle("Glass"); blue = Toggle("Blue") }
        widget {
            Freeform {
                Rectangle().size(80, 40).position(x: 0, y: 0).fill("#FF0000")
                    .fill("#0000FF", if: options.blue)
                if options.glass {
                    Column { }.size(80, 40).position(x: 0, y: 0).background(.glass)
                }
            }.size(80, 40)\(click ? ".onClick { options.glass = true; copy(\"changed\") }" : "")
        }
        """
    }

    private static func checkCompositionColor(_ t: AppTestRunner, _ rgba: Data, blue: Bool) {
        guard rgba.count >= 4 else { return t.check(false, "the accepted bitmap exposes RGBA pixels") }
        t.check(rgba[blue ? 2 : 0] >= 250 && rgba[blue ? 0 : 2] <= 2 && rgba[1] <= 2 && rgba[3] == 255,
                "the accepted bitmap contains the independently expected opaque \(blue ? "blue" : "red") fill")
    }

    private static func conditionalBackgroundTests(_ t: AppTestRunner) {
        t.suite("App: Desk conditional backgrounds: held Main delivery switches one box between pixels glass and no background") {
            let fallback = SkinGlassViews.forcesFallback
            SkinGlassViews.forcesFallback = true
            t.atSuiteEnd { SkinGlassViews.forcesFallback = fallback }
            let source = """
            options { colored = Toggle("Colored", default: true); glass = Toggle("Glass") }
            widget { Freeform {
                Rectangle().size(16, 12).position(x: 8, y: 6).fill("#0000FF").name(button)
                    .voiceOver("Button").onClick { copy("button") }
            }.size(80, 40).name(panel)
                .background("#FF0000", if: options.colored)
                .background(.glass, tint: "#00FF0080", if: options.glass) }
            """
            let recorder = ActionRecorder()
            let widget = try actionFixture(t, recorder: recorder, text: source)
            guard let host = widget.owner.host, let original = widget.latestPresented,
                  let originalImage = widget.content.shown.image else { throw Failure.fixture }
            let initial = try host.optionsSnapshot()
            let frames = original.scene.elements.map(\.frame), ids = original.scene.elements.map(\.id)
            let hitMap = original.scene.hitMap
            t.check(!host.frames.bitmapCompositionSupportsSystemGlass)
            try checkConditionalBackgroundPixels(t, originalImage, scale: original.scale, outside: [255, 0, 0, 255])

            let forward = host.frames.requestBitmapDelivery
            var held: [SkinBitmapDelivery] = [], clears = 0
            host.frames.requestBitmapDelivery = { request in
                switch request {
                case .frame(let delivery): held.append(delivery)
                case .clear: clears += 1; forward?(request)
                }
            }
            defer { host.frames.requestBitmapDelivery = forward }
            var values = initial.values.values
            values["glass"] = .boolean(true)
            var reply: Result<ProgramOptionsSnapshot, Error>?
            host.updateOptions(.init(values: values), expectedRevision: initial.revision) { reply = $0 }
            guard let reply else { throw Failure.fixture }
            let glassOptions = try reply.get()
            t.equal(glassOptions.revision, initial.revision + 1)
            host.frames.runLoopTurn(.beforeWaiting)
            t.equal(held.count, 1)
            guard let delivery = held.first, case .composition = delivery.content else { throw Failure.fixture }
            t.equal(delivery.state, .pending)
            t.equal(widget.latestPresented?.scene, original.scene)
            t.equal(host.presented?.scene, original.scene)
            t.check(widget.content.shown.image === originalImage && widget.nativeComposition.isHidden)
            t.equal(host.scene?.elements.map(\.frame), frames); t.equal(host.scene?.elements.map(\.id), ids)
            t.equal(host.scene?.hitMap, hitMap)

            // Resume the real Main hop and FIFO owner ACK after inspecting the held immutable candidate.
            host.frames.requestBitmapDelivery = { request in
                if case .clear = request { clears += 1 }
                forward?(request)
            }
            forward?(.frame(delivery))
            var mainCommitted = false
            DispatchQueue.main.async {
                t.equal(widget.latestPresented?.scene.generation, delivery.scene.generation)
                t.equal(host.presented?.scene, original.scene, "native geometry and pixels precede the queued owner ACK")
                mainCommitted = true
            }
            t.check(AppSelfTest.spin(timeout: 10) { mainCommitted && !host.frames.hasBitmapDelivery })
            guard let piece = widget.nativeComposition.shownPieces.first,
                  let layer = widget.nativeComposition.shownPixels.first,
                  let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { throw Failure.fixture }
            let foreground = contents as! CGImage
            t.equal(widget.nativeComposition.shownPieces.count, 1)
            t.equal(widget.nativeComposition.shownPixels.count, 1)
            t.equal(widget.nativeComposition.subviews.count, 2)
            t.check(widget.nativeComposition.subviews.first === piece.frameView)
            t.equal(piece.frameView.frame, NSRect(x: 0, y: 0, width: 80, height: 40))
            t.equal((piece.glass as? NSVisualEffectView)?.blendingMode, .behindWindow)
            t.equal(try DeskConditionalTestSupport.element(widget.latestPresented?.scene, "panel").glass?.tint,
                    RGBA(r: 0, g: 255, b: 0, a: 128))
            t.check(widget.content.shown.image == nil, "the earlier conditional red fill does not become a bitmap covering glass")
            try checkConditionalBackgroundPixels(t, foreground, scale: layer.contentsScale, outside: [0, 0, 0, 1])
            t.equal(host.presented?.scene, widget.latestPresented?.scene)

            values["colored"] = .boolean(false); values["glass"] = .boolean(false)
            var noneReply: Result<ProgramOptionsSnapshot, Error>?
            host.updateOptions(.init(values: values), expectedRevision: glassOptions.revision) { noneReply = $0 }
            guard let noneReply else { throw Failure.fixture }
            let noneOptions = try noneReply.get()
            t.equal(noneOptions.revision, initial.revision + 2)
            host.frames.runLoopTurn(.beforeWaiting)
            t.check(piece.frameView.superview === widget.nativeComposition && layer.contents != nil,
                    "removing the background on the owner does not dismantle Main's accepted glass")
            t.check(AppSelfTest.spin(timeout: 10) {
                widget.latestPresented?.scene.generation == host.scene?.generation
                    && !host.frames.hasBitmapDelivery && widget.content.shown.image != nil
            })
            guard let noneImage = widget.content.shown.image, let noneScene = widget.latestPresented?.scene else { throw Failure.fixture }
            try checkConditionalBackgroundPixels(t, noneImage, scale: widget.window.backingScaleFactor, outside: [0, 0, 0, 0])
            let panel = try DeskConditionalTestSupport.element(noneScene, "panel")
            t.equal(panel.backing, .content); t.equal(panel.glass, nil); t.equal(panel.items, [])
            t.equal(noneScene.elements.map(\.frame), frames); t.equal(noneScene.elements.map(\.id), ids)
            t.equal(noneScene.hitMap, hitMap)
            t.equal(noneScene.elements.map(\.accessibilityLabel), original.scene.elements.map(\.accessibilityLabel))
            t.check(widget.nativeComposition.isHidden && widget.nativeComposition.subviews.isEmpty)
            t.check(widget.nativeComposition.shownPieces.isEmpty && widget.nativeComposition.shownPixels.isEmpty)
            t.check(piece.frameView.superview == nil && layer.contents == nil)

            values["colored"] = .boolean(true)
            var restored: Result<ProgramOptionsSnapshot, Error>?
            host.updateOptions(.init(values: values), expectedRevision: noneOptions.revision) { restored = $0 }
            guard let restored else { throw Failure.fixture }
            t.equal(try restored.get().revision, initial.revision + 3)
            host.frames.runLoopTurn(.beforeWaiting)
            t.check(AppSelfTest.spin(timeout: 10) {
                widget.latestPresented?.scene.generation == host.scene?.generation && !host.frames.hasBitmapDelivery
            })
            guard let image = widget.content.shown.image else { throw Failure.fixture }
            t.equal(try DeskConditionalTestSupport.bytes(image), try DeskConditionalTestSupport.bytes(originalImage))
            t.equal(clears, 0); t.equal(recorder.calls, [])
            widget.close(deactivate: false)
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            t.check(widget.latestPresented == nil && widget.nativeComposition.subviews.isEmpty && widget.content.shown.image == nil)
        }

        t.suite("App: Desk conditional backgrounds: fallback option and action rejection preserve values pixels persistence and effects") {
            let fallback = SkinGlassViews.forcesFallback
            SkinGlassViews.forcesFallback = true
            t.atSuiteEnd { SkinGlassViews.forcesFallback = fallback }
            for click in [false, true] {
                let source = """
                options { glass = Toggle("Glass"); blue = Toggle("Blue") }
                widget { Freeform {
                    Rectangle().size(80, 40).position(x: 0, y: 0).fill("#FF0000").fill("#0000FF", if: options.blue)
                    Column { }.size(80, 40).position(x: 0, y: 0).name(panel).background(.glass, if: options.glass)
                }.size(80, 40)\(click ? ".onClick { options.glass = true; copy(\"changed\") }" : "") }
                """
                let recorder = ActionRecorder()
                let widget = try actionFixture(t, recorder: recorder, text: source)
                guard let host = widget.owner.host, let presented = widget.latestPresented,
                      let image = widget.content.shown.image else { throw Failure.fixture }
                let initial = try host.optionsSnapshot(), scene = host.scene
                let pixels = try DeskConditionalTestSupport.bytes(image)
                let stored = widget.app.state.deskInstance(widget.instance.id)?.optionValues
                let storedBytes = try Data(contentsOf: widget.app.state.fileURL)
                let serial = widget.lastPresentationSerial
                t.equal(host.presented?.scene, presented.scene)
                t.check(!host.frames.bitmapCompositionSupportsSystemGlass)
                var clears = 0
                let forward = host.frames.requestBitmapDelivery
                host.frames.requestBitmapDelivery = { request in
                    if case .clear = request { clears += 1 }
                    forward?(request)
                }
                var rejected: [UInt64] = []
                let rejection = host.didRejectProjection
                host.didRejectProjection = { message, generation in
                    t.check(message.contains("unsupportedFallbackOverlap"))
                    rejected.append(generation); rejection?(message, generation)
                }
                if click {
                    guard let token = widget.issueClickToken() else { throw Failure.fixture }
                    let point = SkinPoint(x: 20, y: 20)
                    widget.owner.primaryPress(at: point, expectedGeneration: token.sourceGeneration, epoch: token.epoch)
                    var effects: [[ProgramEffect]] = []
                    widget.owner.primaryRelease(at: point, token: token) { returned, batch in
                        effects.append(batch); widget.handleEffects(batch, token: returned, issuedToken: token)
                    }
                    t.equal(effects, [], "a rejected conditional background cannot release its copy effect")
                    t.equal(rejected, [presented.scene.generation])
                } else {
                    var values = initial.values.values; values["glass"] = .boolean(true)
                    var replies: [Result<ProgramOptionsSnapshot, Error>] = []
                    host.updateOptions(.init(values: values), expectedRevision: initial.revision) { replies.append($0) }
                    t.equal(replies.count, 1)
                    if let reply = replies.first, case .failure(let error) = reply {
                        t.equal(error as? SkinBitmapComposer.Failure, .unsupportedFallbackOverlap)
                    } else { t.check(false, "the real fallback compositor rejects an overlapping earlier element") }
                    t.equal(rejected, [], "option errors use their own completion")
                }
                host.frames.runLoopTurn(.beforeWaiting)
                reviewDrainOwner(widget, t); reviewDrainOwner(widget, t)
                t.equal(try host.optionsSnapshot(), initial); t.equal(widget.optionsSnapshot, initial)
                t.equal(host.scene, scene); t.equal(host.state, .ready)
                t.equal(widget.latestPresented?.scene, presented.scene); t.equal(host.presented?.scene, presented.scene)
                t.equal(widget.lastPresentationSerial, serial); t.equal(clears, 0)
                t.check(widget.content.shown.image === image)
                guard let shown = widget.content.shown.image else { throw Failure.fixture }
                t.equal(try DeskConditionalTestSupport.bytes(shown), pixels)
                t.check(widget.nativeComposition.isHidden && widget.nativeComposition.shownPieces.isEmpty)
                t.equal(widget.app.state.deskInstance(widget.instance.id)?.optionValues, stored)
                t.equal(try Data(contentsOf: widget.app.state.fileURL), storedBytes)
                t.equal(recorder.calls, []); t.equal(widget.lastUnavailableMessage, nil)
                t.equal(widget.lastActionFailure, click ? StudioText[.deskOptionsChangeFailed] : nil)

                var values = initial.values.values; values["blue"] = .boolean(true)
                var recovered: Result<ProgramOptionsSnapshot, Error>?
                host.updateOptions(.init(values: values), expectedRevision: initial.revision) { recovered = $0 }
                guard let recovered else { throw Failure.fixture }
                let accepted = try recovered.get()
                t.equal(accepted.revision, initial.revision + 1)
                t.equal(accepted.values.values["glass"], .boolean(false))
                host.frames.runLoopTurn(.beforeWaiting)
                t.check(AppSelfTest.spin(timeout: 10) {
                    widget.latestPresented?.scene.generation == host.scene?.generation && !host.frames.hasBitmapDelivery
                })
                guard let blue = widget.content.shown.image else { throw Failure.fixture }
                checkCompositionColor(t, try DeskConditionalTestSupport.bytes(blue), blue: true)
                t.check(blue !== image)
                t.equal(host.scene?.elements.map(\.id), scene?.elements.map(\.id))
                t.equal(host.scene?.elements.map(\.frame), scene?.elements.map(\.frame))
                t.equal(widget.lastActionFailure, nil); t.equal(recorder.calls, []); t.equal(clears, 0)
                widget.close(deactivate: false)
                t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            }
        }
    }

    private static func checkConditionalBackgroundPixels(_ t: AppTestRunner, _ image: CGImage,
                                                        scale: CGFloat, outside expected: [UInt8]) throws {
        guard scale.isFinite, scale > 0, expected.count == 4 else { throw Failure.fixture }
        t.equal(image.width, Int(ceil(80 * scale))); t.equal(image.height, Int(ceil(40 * scale)))
        let bytes = try DeskConditionalTestSupport.bytes(image)
        guard bytes.count == image.width * image.height * 4 else { throw Failure.fixture }
        let blue = CGRect(x: 8 * scale, y: 6 * scale, width: 16 * scale, height: 12 * scale)
        var interior = 0, exterior = 0
        var firstMismatch: String?
        for y in 0..<image.height {
            for x in 0..<image.width {
                let minX = CGFloat(x), minY = CGFloat(y), maxX = CGFloat(x + 1), maxY = CGFloat(y + 1)
                let inside = minX >= blue.minX && maxX <= blue.maxX && minY >= blue.minY && maxY <= blue.maxY
                let outside = maxX <= blue.minX || minX >= blue.maxX || maxY <= blue.minY || minY >= blue.maxY
                guard inside || outside else { continue } // Exclude only fractional edge coverage.
                let offset = (y * image.width + x) * 4
                let pixel = Array(bytes[offset..<(offset + 4)])
                let matches: Bool
                if inside {
                    interior += 1
                    matches = pixel[0] <= 2 && pixel[1] <= 2 && pixel[2] >= 250 && pixel[3] == 255
                } else {
                    exterior += 1
                    if expected[3] <= 1 { matches = pixel == expected }
                    else { matches = pixel[0] >= 250 && pixel[1] <= 2 && pixel[2] <= 2 && pixel[3] == 255 }
                }
                if !matches, firstMismatch == nil { firstMismatch = "(\(x), \(y)): \(pixel)" }
            }
        }
        t.check(interior > 0 && exterior > 0)
        t.equal(firstMismatch, nil, "every blue interior and background exterior pixel matches its independent color/alpha oracle")
    }

    private static func gaugeTests(_ t: AppTestRunner) {
        t.suite("App: Desk gauge: value and geometry publish together and stale presses do not replay") {
            let source = #"widget { variable level = 25%; variable start = 0deg; variable thickness = 6pt; Gauge(level, shape: .arc, start: start, sweep: 180deg, thickness: thickness).size(96).onClick { level = 75%; start = 90deg; thickness = 10pt } }"#
            let widget = try actionFixture(t, recorder: ActionRecorder(), text: source)
            guard let host = widget.owner.host, let original = widget.latestPresented,
                  let image = widget.content.shown.image else { throw Failure.fixture }
            func roundlines(_ scene: WidgetScene) -> [RoundlineDraw] {
                scene.drawingItems.compactMap { if case .roundline(let draw) = $0 { return draw }; return nil }
            }
            let initial = roundlines(original.scene)
            t.equal(initial.count, 2, "track followed by the filled arc")
            guard initial.count == 2,
                  case .sector(_, _, let inner, let outer, let start, let sweep) = initial[1].shape else { throw Failure.fixture }
            t.close(inner, 42); t.close(outer, 48)
            t.close(start, -.pi / 2); t.close(sweep, .pi / 4)
            let point = SkinPoint(x: 80, y: 16)
            host.primaryPress(at: point); host.primaryRelease(at: point)
            host.frames.runLoopTurn(.beforeWaiting)
            guard let exported = host.scene else { throw Failure.fixture }
            t.check(exported.generation > original.scene.generation)
            t.check(host.frames.hasBitmapDelivery)
            t.check(widget.content.shown.image === image, "owner projection cannot publish pixels before Main")
            t.equal(widget.latestPresented?.scene.generation, original.scene.generation)
            let next = roundlines(exported)
            guard next.count == 2,
                  case .sector(_, _, let nextInner, let nextOuter, let nextStart, let nextSweep) = next[1].shape else { throw Failure.fixture }
            t.close(nextInner, 38); t.close(nextOuter, 48)
            t.close(nextStart, 0); t.close(nextSweep, .pi * 0.75)
            host.primaryPress(at: point); host.primaryRelease(at: point)
            t.equal(host.scene?.generation, exported.generation, "a press against unaccepted pixels is ignored")
            t.check(AppSelfTest.spin(timeout: 10) {
                widget.latestPresented?.scene.generation == exported.generation && !host.frames.hasBitmapDelivery
            })
            t.equal(host.presented?.scene.generation, exported.generation)
            t.check(widget.content.shown.image !== image)
            if let before = image.dataProvider?.data, let after = widget.content.shown.image?.dataProvider?.data {
                t.check((before as Data) != (after as Data), "the accepted value and geometry changed actual pixels")
            } else { t.check(false, "both immutable pictures expose their pixel data") }
            t.equal(widget.view.frame.size, NSSize(width: 96, height: 96))
            widget.close(deactivate: false)
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            t.check(widget.content.shown.image == nil && widget.latestPresented == nil)
        }
    }

    private static func mainDeliveryTests(_ t: AppTestRunner) {
        t.suite("App: Desk native glass: text pixels glass and window size commit before the owner ACK") {
            let source = #"widget { variable n = 0; Text("{n}").font(20).padding(6).background(.glass).rounded(6).onClick { n = n + 100000 } }"#
            let widget = try actionFixture(t, recorder: ActionRecorder(), text: source)
            guard let host = widget.owner.host, let original = widget.latestPresented,
                  let element = original.scene.elements.first, let glass = element.glass else { throw Failure.fixture }
            t.check(widget.content.shown.image == nil, "a whole-window bitmap cannot cover the glass")
            t.equal(widget.nativeComposition.subviews.count, 2, "native glass then foreground pixels")
            guard let oldGlass = widget.nativeComposition.subviews.first as? SkinGlassFrameView else { throw Failure.fixture }
            let oldFrame = oldGlass.frame, oldWindow = widget.window.frame
            t.equal(oldFrame.size, NSSize(width: glass.rect.width, height: glass.rect.height))
            t.check(widget.nativeComposition.hitTest(NSPoint(x: 8, y: 8)) == nil, "the parent keeps mouse handling")
            let point = SkinPoint(x: element.frame.x + element.frame.width / 2 - original.origin.x,
                                  y: element.frame.y + element.frame.height / 2 - original.origin.y)
            host.primaryPress(at: point); host.primaryRelease(at: point)
            host.frames.runLoopTurn(.beforeWaiting)
            guard let exported = host.scene else { throw Failure.fixture }
            t.check(host.frames.hasBitmapDelivery)
            t.equal(oldGlass.frame, oldFrame, "owner rendering cannot change AppKit geometry")
            t.equal(widget.window.frame, oldWindow)
            var committed = false
            DispatchQueue.main.async {
                t.equal(widget.latestPresented?.scene.generation, exported.generation)
                t.equal(widget.nativeComposition.frame.size, widget.view.frame.size)
                t.equal(widget.window.frame.size, widget.view.frame.size)
                t.check(widget.window.frame.width > oldWindow.width)
                t.equal(widget.nativeComposition.subviews.first?.frame.size, widget.view.frame.size)
                t.check(widget.content.shown.image == nil)
                t.equal(host.presented?.scene.generation, original.scene.generation, "Main committed before the FIFO ACK")
                committed = true
            }
            t.check(AppSelfTest.spin(timeout: 10) { committed && !host.frames.hasBitmapDelivery })
            t.equal(host.presented?.scene.generation, exported.generation)
        }

        t.suite("App: Desk native glass: negative viewport clear recovery and close retain no stale views") {
            let source = #"widget { Freeform { Text("Glass").font(20).size(80, 32).position(x: -30, y: -20).background(.clearGlass).rounded(8) } }"#
            let widget = try actionFixture(t, recorder: ActionRecorder(), text: source)
            guard let host = widget.owner.host, let original = widget.latestPresented else { throw Failure.fixture }
            t.equal(original.origin, SkinPoint(x: -30, y: -20))
            t.equal(widget.nativeComposition.subviews.first?.frame, NSRect(x: 0, y: 0, width: 80, height: 32))
            let serial = widget.lastPresentationSerial
            let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
                                                                 scale: widget.window.backingScaleFactor)
            host.take(widget.currentFacts(), input: input); host.frames.releaseUnseen()
            t.check(AppSelfTest.spin(timeout: 10) { widget.latestPresented == nil && widget.nativeComposition.subviews.isEmpty })
            t.check(widget.content.shown.image == nil && widget.view.accessibilityParts.isEmpty)
            host.drawFirstFrame()
            t.check(AppSelfTest.spin(timeout: 10) { widget.latestPresented != nil && !host.frames.hasBitmapDelivery })
            t.equal(widget.latestPresented?.scene.generation, original.scene.generation)
            t.check(widget.lastPresentationSerial > serial)
            t.equal(widget.nativeComposition.subviews.first?.frame.origin, .zero)
            // Resume the controlled visible state before requesting an ordinary frame.
            // drawFirstFrame intentionally does nothing once released contents have recovered.
            var visible = widget.currentFacts()
            visible.isOrderedIn = true; visible.isVisible = true
            host.take(visible, input: input)
            host.refresh(); host.frames.runLoopTurn(.beforeWaiting)
            t.check(host.frames.hasBitmapDelivery, "the visible owner queued a frame before close")
            widget.close(deactivate: false)
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            t.check(widget.nativeComposition.subviews.isEmpty && widget.content.shown.image == nil)
            t.check(widget.latestPresented == nil && widget.view.accessibilityParts.isEmpty)
        }

        t.suite("App: Desk Main delivery: held pixels and geometry commit together before the owner ACK") {
            let source = #"widget { variable n = 0; Text("{n}").font(20).onClick { n = n + 100000 } }"#
            let widget = try actionFixture(t, recorder: ActionRecorder(), text: source)
            guard let host = widget.owner.host, let original = widget.latestPresented,
                  let image = widget.content.shown.image,
                  let element = original.scene.elements.first else { throw Failure.fixture }
            let firstCount = widget.content.state.presented, oldFrame = widget.window.frame
            let point = SkinPoint(x: element.frame.x + element.frame.width / 2 - original.origin.x,
                                  y: element.frame.y + element.frame.height / 2 - original.origin.y)
            var ownerReceipts: [UInt64] = []
            host.didPresent = { ownerReceipts.append($0.scene.generation) }
            host.primaryPress(at: point); host.primaryRelease(at: point)
            host.frames.runLoopTurn(.beforeWaiting)
            guard let exported = host.scene else { throw Failure.fixture }
            t.check(host.frames.hasBitmapDelivery, "Main has not run the exported request")
            t.check(exported.size.width > original.size.width, "the accepted assignment needs a wider native window")
            host.refresh() // Logic may advance, while the exported scene and its private capture stay fixed.
            t.check((host.scene?.generation ?? 0) > exported.generation)
            t.check(widget.content.shown.image === image, "owner drawing does not replace provider pixels")
            t.equal(widget.content.state.presented, firstCount)
            t.equal(widget.window.frame, oldFrame)
            t.equal(widget.view.frame.size, original.size)
            t.equal(host.presented?.scene.generation, original.scene.generation)
            var mainCommitted = false
            DispatchQueue.main.async {
                t.equal(widget.latestPresented?.scene.generation, exported.generation)
                t.equal(widget.content.state.presented, firstCount + 1)
                t.equal(widget.content.shown.bounds.size, widget.view.frame.size)
                t.equal(widget.window.frame.size, widget.view.frame.size)
                t.check(widget.window.frame.width > oldFrame.width)
                t.equal(host.presented?.scene.generation, original.scene.generation, "the owner ACK is still queued")
                mainCommitted = true
            }
            t.check(AppSelfTest.spin(timeout: 10) { mainCommitted && ownerReceipts.count == 2 })
            t.equal(ownerReceipts.first, exported.generation, "an accepted picture remains the presented scene even when logic is newer")
            t.equal(host.presented?.scene.generation, host.scene?.generation)
            t.equal(widget.latestPresented?.scene.generation, host.presented?.scene.generation)
            t.check(!host.frames.hasBitmapDelivery)
        }

        t.suite("App: Desk Main delivery: repeated failures retain feedback and cancelled clears cannot erase recovery") {
            let widget = try actionFixture(t, recorder: ActionRecorder())
            guard let host = widget.owner.host else { throw Failure.fixture }
            let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
                                                                 scale: widget.window.backingScaleFactor)
            var invalid = widget.currentFacts()
            invalid.colorSpace = nil
            let shown = widget.content.shown.image, count = widget.content.state.presented
            widget.owner.take(invalid, input: input)
            host.refresh(); host.drawFirstFrame()
            t.check(widget.content.shown.image === shown, "a failed owner queues its clear rather than writing Main's layer")
            t.check(host.presented == nil)
            t.check(AppSelfTest.spin(timeout: 10) { widget.lastUnavailableMessage != nil && widget.content.shown.image == nil })
            t.check(widget.latestPresented == nil)
            t.equal(widget.content.state.presented, count, "clears do not masquerade as a successful picture")
            let prefix = "Desk widget unavailable (\(widget.source.entry)):"
            t.equal(Log.recent.filter { $0.message.hasPrefix(prefix) }.count, 1)
            host.refresh(); host.drawFirstFrame()
            var repeatedErrorDrained = false
            DispatchQueue.main.async {
                t.equal(Log.recent.filter { $0.message.hasPrefix(prefix) }.count, 1,
                        "a replacement clear retains feedback without repeating the same warning")
                repeatedErrorDrained = true
            }
            t.check(AppSelfTest.spin(timeout: 10) { repeatedErrorDrained })
            let valid = widget.currentFacts()
            widget.owner.take(valid, input: input)
            t.check(AppSelfTest.spin(timeout: 10) { widget.latestPresented != nil && host.presented != nil })
            t.check(widget.lastUnavailableMessage == nil)

            let recovered = widget.content.shown.image
            widget.owner.take(invalid, input: input)
            host.refresh(); host.drawFirstFrame()
            var oldErrorsDrained = false
            DispatchQueue.main.async {
                t.check(widget.lastUnavailableMessage == nil, "recovery cancelled every replaced clear and its old error")
                t.check(widget.content.shown.image === recovered)
                oldErrorsDrained = true
            }
            widget.owner.take(valid, input: input)
            t.check(AppSelfTest.spin(timeout: 10) {
                oldErrorsDrained && widget.latestPresented != nil && host.presented != nil && !host.frames.hasBitmapDelivery
            })
            t.check(widget.lastUnavailableMessage == nil)
        }

        t.suite("App: Desk Main delivery: a different RGB profile and duplicate receipt never publish pixels") {
            let widget = try actionFixture(t, recorder: ActionRecorder())
            guard let host = widget.owner.host, let original = widget.latestPresented else { throw Failure.fixture }
            var captured: SkinBitmapDelivery?
            let forward = host.frames.requestBitmapDelivery
            host.frames.requestBitmapDelivery = { request in
                if case .frame(let frame) = request { captured = frame }
                forward?(request)
            }
            host.refresh(); host.frames.runLoopTurn(.beforeWaiting)
            guard let delivery = captured else { throw Failure.fixture }
            let alternate = [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace(name: CGColorSpace.displayP3)!]
                .first { $0 != delivery.space }!
            let bad = SkinBitmapDelivery(content: delivery.content, scene: delivery.scene, origin: delivery.origin,
                space: alternate, appearance: delivery.appearance, panelGeneration: delivery.panelGeneration,
                serial: delivery.serial, lifecycle: delivery.lifecycle)
            let count = widget.content.state.presented, image = widget.content.shown.image
            widget.handleBitmapRequest(.frame(bad), session: widget.sessionID)
            t.equal(bad.state, .finished(accepted: false))
            t.equal(widget.content.state.presented, count)
            t.check(widget.content.shown.image === image)
            t.equal(widget.latestPresented?.scene.generation, original.scene.generation)
            t.check(AppSelfTest.spin(timeout: 10) { delivery.state == .finished(accepted: true) && !host.frames.hasBitmapDelivery })
            let acceptedCount = widget.content.state.presented, acceptedSerial = widget.lastPresentationSerial
            widget.handleBitmapRequest(.frame(delivery), session: widget.sessionID)
            t.equal(widget.content.state.presented, acceptedCount)
            t.equal(widget.lastPresentationSerial, acceptedSerial)
            host.frames.requestBitmapDelivery = forward
        }

        t.suite("App: Desk Main delivery: a queued frame cannot revive a closing window") {
            let widget = try actionFixture(t, recorder: ActionRecorder())
            guard let host = widget.owner.host else { throw Failure.fixture }
            host.refresh(); host.frames.runLoopTurn(.beforeWaiting)
            t.check(host.frames.hasBitmapDelivery)
            let count = widget.content.state.presented
            widget.close(deactivate: false)
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            t.equal(widget.content.state.presented, count)
            t.check(widget.content.shown.image == nil)
            t.check(widget.latestPresented == nil)
            t.equal(host.state, .closed)
        }

        t.suite("App: Desk Main delivery: released contents repaint the same scene with a new serial") {
            let widget = try actionFixture(t, recorder: ActionRecorder())
            guard let host = widget.owner.host, let original = widget.latestPresented else { throw Failure.fixture }
            let count = widget.content.state.presented, serial = widget.lastPresentationSerial
            let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
                                                                 scale: widget.window.backingScaleFactor)
            let orderedOut = widget.currentFacts()
            t.check(!orderedOut.isOrderedIn, "the test has not ordered a native window on screen")
            host.take(orderedOut, input: input); host.frames.releaseUnseen()
            t.check(AppSelfTest.spin(timeout: 10) { widget.latestPresented == nil && widget.content.shown.image == nil })
            t.equal(host.scene?.generation, original.scene.generation)
            host.drawFirstFrame()
            t.check(AppSelfTest.spin(timeout: 10) {
                widget.latestPresented != nil && !host.frames.hasBitmapDelivery && widget.content.state.presented == count + 1
            })
            t.equal(widget.latestPresented?.scene.generation, original.scene.generation)
            t.equal(host.presented?.scene.generation, original.scene.generation)
            t.check(widget.lastPresentationSerial > serial)
        }
    }

    private static func reviewRegressionTests(_ t: AppTestRunner) {
        t.suite("App: Desk review regressions: real images place and restart with exclusive prepared resources") {
            let png = try reviewImageData()
            let text = #"widget { Row(spacing: 0) { Image(".photos/asset.png").size(48, 40); Image(".PHOTOS/ASSET.PNG").size(24, 20) } }"#
            let f = try fixture(t, text: text, images: [".photos/asset.png": png])
            t.check(waitForCheck(f))
            t.check(f.checking.snapshot.diagnostics.allSatisfy { $0.severity != .error })
            var placed: DeskWidgetWindowController?, failure: Error?, completed = false
            f.controller.placeOnDesktop(sourceID: UUID(), instanceID: UUID()) { result in
                completed = true
                switch result {
                case .success(let widget): placed = widget
                case .failure(let error): failure = error
                }
            }
            t.check(AppSelfTest.spin(timeout: 10) { completed })
            t.check(failure == nil, "valid installed pictures must reach activation: \(String(describing: failure))")
            guard let widget = placed else { return }
            t.check(AppSelfTest.spin(timeout: 10) { widget.isStarted && widget.latestPresented != nil })
            t.equal(widget.view.frame.size, NSSize(width: 72, height: 40))
            t.equal(try Data(contentsOf: widget.directory.appendingPathComponent(".photos/asset.png")), png)
            guard let prepared = widget.owner.prepared,
                  let privateImage = prepared.images[".photos/asset.png"] else { throw Failure.fixture }
            t.equal(prepared.images[".PHOTOS/ASSET.PNG"], privateImage, "case aliases share one safely prepared picture")
            t.check(!privateImage.path.hasPrefix(widget.directory.path + "/"), "the host draws its own immutable copy")
            f.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            t.check(prepared.unchanged(), "closing the editor cannot discard the desktop host's resources")
            let instanceID = widget.instance.id
            widget.close(deactivate: false)
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            t.check(!FileManager.default.fileExists(atPath: privateImage.path))
            f.app.state.saveNow()
            let restarted = reviewRestartedApp(f.app)
            defer { _ = restarted.stopAllForTermination(); restarted.endEngineThread() }
            restarted.loadActiveDeskWidgets()
            t.check(restarted.deskRestorationFailures.isEmpty)
            t.check(AppSelfTest.spin(timeout: 10) { restarted.deskWidgetWindows[instanceID]?.isStarted == true })
            guard let recovered = restarted.deskWidgetWindows[instanceID],
                  let nextImage = recovered.owner.prepared?.images[".photos/asset.png"] else { throw Failure.fixture }
            t.check(recovered.latestPresented != nil)
            t.check(nextImage.path != privateImage.path, "restart owns a fresh preparation")
            t.equal(restarted.state.deskInstance(instanceID)?.active, true)
            t.equal(try Data(contentsOf: URL(fileURLWithPath: nextImage.path)), png)
        }

        t.suite("App: Desk review regressions: missing and linked images cannot activate or lose restart intent") {
            let f = try fixture(t), png = try reviewImageData()
            let outside = f.root.appendingPathComponent("outside.png")
            try png.write(to: outside)
            var instanceIDs: [UUID] = []
            for kind in ["missing", "linked file", "linked ancestor"] {
                let sourceID = UUID(), instanceID = UUID()
                let name = sourceID.uuidString.lowercased()
                let directory = f.root.appendingPathComponent("Widgets").appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let literal = kind == "linked ancestor" ? "assets/outside.png" : "asset.png"
                try Data("widget { Image(\"\(literal)\").size(48, 40) }".utf8).write(to: directory.appendingPathComponent("Main.desk"))
                if kind == "linked file" {
                    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(literal), withDestinationURL: outside)
                } else if kind == "linked ancestor" {
                    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("assets"), withDestinationURL: f.root)
                }
                let source = DeskWidgetSourceState(id: sourceID, entry: name + "/Main.desk")
                let instance = DeskWidgetInstanceState(id: instanceID, sourceID: sourceID)
                try f.app.state.registerDeskInstallation(source: source, instance: instance)
                f.app.state.updateDeskInstance(instanceID) { $0.active = true }
                do {
                    _ = try f.app.activateDeskWidget(instanceID: instanceID)
                    t.check(false, "\(kind) must fail before accepting a desktop presentation")
                } catch {
                    t.check(f.app.deskWidgetWindows[instanceID] == nil, "\(kind) creates no host")
                }
                t.equal(f.app.state.deskInstance(instanceID)?.active, true)
                instanceIDs.append(instanceID)
            }
            f.app.state.saveNow()
            let restarted = reviewRestartedApp(f.app)
            defer { _ = restarted.stopAllForTermination(); restarted.endEngineThread() }
            restarted.loadActiveDeskWidgets()
            t.check(restarted.deskWidgetWindows.isEmpty)
            t.equal(restarted.deskRestorationFailures.count, 3)
            for id in instanceIDs { t.equal(restarted.state.deskInstance(id)?.active, true) }
            t.equal(try Data(contentsOf: outside), png, "unsafe paths cannot alter or consume the outside file")
        }

        t.suite("App: Desk review regressions: primary held press cannot cross an accepted destination epoch") {
            for workerOwned in [false, true] {
                let worker = workerOwned ? SkinThreadExecutor(name: "Desk primary epoch regression") : nil
                let executor: SkinExecutor
                if let worker { executor = worker } else { executor = MainSkinExecutor.shared }
                let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, executor: executor)
                defer {
                    widget.close(deactivate: false)
                    t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
                    worker?.stop()
                }
                try pointerMouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: widget)
                reviewDrainOwner(widget, t)
                let oldEpoch = widget.destinationEpoch, oldGeneration = widget.latestPresented?.scene.generation ?? 0
                let dark = widget.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                widget.window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
                _ = widget.currentFacts()
                let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
                                                                      scale: widget.window.backingScaleFactor)
                guard let space = widget.window.colorSpace?.cgColorSpace else { throw Failure.fixture }
                let facts = SkinWindowFacts(frame: widget.window.frame, isVisible: true, isOrderedIn: true,
                    scale: widget.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
                    takesPointer: true, sequence: 200, panelGeneration: widget.destinationEpoch)
                executor.async { [owner = widget.owner] in
                    owner.take(facts, input: input)
                    owner.host?.frames.runLoopTurn(.beforeWaiting)
                }
                t.check(AppSelfTest.spin(timeout: 10) {
                    widget.lastAcceptedEpoch == widget.destinationEpoch && widget.destinationEpoch != oldEpoch
                        && (widget.latestPresented?.scene.generation ?? 0) > oldGeneration
                })
                try pointerMouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
                reviewDrainOwner(widget, t)
                t.check(recorder.calls.isEmpty, "a new accepted frame cannot adopt the old primary press")
                try pointerMouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: widget)
                try pointerMouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: widget)
                reviewDrainOwner(widget, t)
                t.equal(recorder.calls, ["copy:1", "open:https://example.com/1", "copy:done😀"], "a fresh primary gesture still executes once")
            }
        }

        t.suite("App: Desk review regressions: Remove persists before held close acknowledgement and termination deadline") {
            for removeWhileClosing in [false, true] {
                let worker = SkinThreadExecutor(name: "Desk Remove persistence regression")
                let widget = try actionFixture(t, recorder: ActionRecorder(), executor: worker)
                let release = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
                defer {
                    release.signal()
                    widget.close(deactivate: false)
                    t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
                    worker.stop()
                }
                worker.async { entered.signal(); release.wait() }
                t.check(entered.wait(timeout: .now() + 10) == .success)
                t.equal(widget.app.state.deskInstance(widget.instance.id)?.active, true)
                if removeWhileClosing {
                    widget.close(deactivate: false)
                    t.equal(widget.app.state.deskInstance(widget.instance.id)?.active, true, "ordinary close preserves active intent")
                }
                widget.app.deactivateDeskWidget(instanceID: widget.instance.id)
                t.check(widget.isClosing && !widget.isClosed, "physical teardown still waits behind owner work")
                t.equal(widget.app.state.deskInstance(widget.instance.id)?.active, false, "Remove intent is synchronous on Main")
                let late = widget.app.stopAllForTermination(budget: 0)
                t.check(late.contains(widget.source.entry))
                widget.app.state.saveNow()
                let reloaded = AppState(fileURL: widget.app.state.fileURL)
                t.equal(reloaded.deskInstance(widget.instance.id)?.active, false, "quit saves Remove even before ACK")
                t.check(reloaded.activeDeskWidgets.isEmpty, "restart must not revive the removed widget")
                widget.app.state.updateDeskInstance(widget.instance.id) { $0.active = true }
                release.signal()
                t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
                t.equal(widget.app.state.deskInstance(widget.instance.id)?.active, true, "an old close ACK cannot overwrite later Main intent")
                widget.close(deactivate: true)
                t.equal(widget.app.state.deskInstance(widget.instance.id)?.active, false, "Remove remains immediate on an already closed object")
            }
        }

        t.suite("App: Desk review regressions: clock and timezone notifications refresh immediately and realign the next minute") {
            guard let utc = TimeZone(secondsFromGMT: 0), let shifted = TimeZone(secondsFromGMT: 7200) else { throw Failure.fixture }
            let time = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_790_553_600), timeZone: utc)
            let widget = try actionFixture(t, recorder: ActionRecorder(), executor: time, clock: time.clock,
                                          text: #"widget { Text("{time.now, format: "HH:mm"}").size(160, 40) }"#)
            defer {
                widget.close(deactivate: false)
                time.runUntilIdle()
                t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            }
            widget.window.orderFront(nil)
            widget.publishFacts()
            time.runUntilIdle()
            widget.owner.host?.frames.runLoopTurn(.beforeWaiting)
            reviewDrainOwner(widget, t)
            func awaitPresentation(_ generation: UInt64) throws {
                let input = try DeskWidgetWindowController.makeInput(for: widget.window.effectiveAppearance,
                                                                      scale: widget.window.backingScaleFactor)
                guard let space = widget.window.colorSpace?.cgColorSpace else { throw Failure.fixture }
                // The real notification may report an occluded desktop window. Like actionFixture, these
                // same-destination facts qualify bitmap delivery after the notification's scene assertions.
                let facts = SkinWindowFacts(frame: widget.window.frame, isVisible: true, isOrderedIn: true,
                    scale: widget.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
                    takesPointer: true, sequence: 200, panelGeneration: widget.destinationEpoch)
                time.async { [owner = widget.owner] in owner.take(facts, input: input) }
                t.check(AppSelfTest.spin(timeout: 10) {
                    time.runUntilIdle()
                    widget.owner.host?.frames.runLoopTurn(.beforeWaiting)
                    return widget.latestPresented?.scene.generation == generation
                }, "the current bitmap is accepted by Main after visible facts")
                t.equal(widget.latestPresented?.scene.generation, generation)
                t.equal(widget.owner.host?.scene?.generation, generation, "delivery does not add another projection")
            }
            for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
                let generation = widget.owner.host?.scene?.generation ?? 0
                let before = reviewSceneTexts(widget)
                if name == .NSSystemClockDidChange { time.setWallClock(time.wallClock.addingTimeInterval(7207)) }
                else { time.timeZone = shifted }
                NotificationCenter.default.post(name: name, object: nil)
                time.runUntilIdle()
                widget.owner.host?.frames.runLoopTurn(.beforeWaiting)
                reviewDrainOwner(widget, t)
                t.equal(time.now, 0, "no scheduled clock tick was allowed to run")
                t.equal(widget.owner.host?.scene?.generation, generation + 1, "the notification causes one projection")
                t.check(reviewSceneTexts(widget) != before, "the changed clock input reaches the scene immediately")
                try awaitPresentation(generation + 1)
            }
            let generation = widget.owner.host?.scene?.generation ?? 0, before = reviewSceneTexts(widget)
            time.advance(until: 52.999)
            t.equal(widget.owner.host?.scene?.generation, generation, "no clock tick occurs before the new minute boundary")
            t.equal(reviewSceneTexts(widget), before)
            time.advance(until: 53)
            t.equal(widget.owner.host?.scene?.generation, generation + 1, "the clock ticks exactly at the realigned minute")
            t.check(reviewSceneTexts(widget) != before, "the first scheduled tick displays the next minute")
            try awaitPresentation(generation + 1)
        }
    }

    private static func reviewDrainOwner(_ widget: DeskWidgetWindowController, _ t: AppTestRunner) {
        var drained = false
        widget.executor.async { DispatchQueue.main.async { drained = true } }
        t.check(AppSelfTest.spin(timeout: 10) {
            (widget.executor as? VirtualTimeExecutor)?.runUntilIdle()
            return drained
        })
    }

    private static func reviewSceneTexts(_ widget: DeskWidgetWindowController) -> [String] {
        widget.owner.host?.scene?.drawingItems.compactMap { if case .text(let value) = $0 { return value.text }; return nil } ?? []
    }

    private static func reviewRestartedApp(_ app: AppController) -> AppController {
        let root = app.state.fileURL.deletingLastPathComponent()
        return AppController(state: AppState(fileURL: app.state.fileURL), skinsDirectory: root.appendingPathComponent("Skins"),
            layoutsDirectory: root.appendingPathComponent("Layouts"), backupsDirectory: root.appendingPathComponent("Backups"),
            defaultSkinsSource: nil, settingsDirectory: root.appendingPathComponent("Settings"),
            widgetsDirectory: root.appendingPathComponent("Widgets"), presentsWindows: false)
    }

    private static func reviewImageData() throws -> Data {
        guard let provider = CGDataProvider(data: Data([24, 168, 72, 255, 216, 88, 16, 255]) as CFData),
              let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                  space: SkinFrameProducer.sRGB,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.fixture }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw Failure.fixture }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw Failure.fixture }
        return output as Data
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
        t.suite("App: Desk icon accessibility: explicit labels work for static missing hidden and actionable symbols") {
            let worker = SkinThreadExecutor(name: "Desk icon accessibility worker test")
            var created: DeskWidgetWindowController?
            defer {
                if let created {
                    created.close(deactivate: false)
                    t.check(AppSelfTest.spin(timeout: 10) { created.isClosed })
                }
                worker.stop()
            }
            let source = """
            widget { variable count = 0; Column {
                Icon("wifi").size(40).voiceOver("Wireless").name(wifi)
                Icon("deskset.nonexistent.symbol.87fc2").size(40).voiceOver("Missing symbol").name(missing)
                Icon("wifi").size(40).voiceOver("Hidden").hidden()
                Icon("wifi").size(40)
                Icon(count == 0 ? "bolt.fill" : "powerplug.fill").size(40).voiceOver("Charge {count}").name(charge)
                    .onClick { count = count + 1; copy("charge {count}") }
            } }
            """
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, executor: worker, text: source)
            created = widget
            t.equal(widget.view.accessibilityParts.count, 3, "hidden and undescribed icons are omitted")
            guard let staticIcon = widget.view.accessibilityParts.first(where: { $0.id.name == "wifi" }),
                  let missing = widget.view.accessibilityParts.first(where: { $0.id.name == "missing" }),
                  let action = widget.view.accessibilityParts.first(where: { $0.id.name == "charge" }),
                  let presented = widget.latestPresented else { throw Failure.fixture }
            t.equal(staticIcon.accessibilityRole(), .image)
            t.equal(staticIcon.accessibilityLabel(), "Wireless")
            t.equal(missing.accessibilityRole(), .image)
            t.equal(missing.accessibilityLabel(), "Missing symbol", "the explicit description survives unavailable native pixels")
            t.check(!staticIcon.accessibilityPerformPress() && !missing.accessibilityPerformPress())
            t.equal(action.accessibilityRole(), .button)
            t.equal(action.accessibilityLabel(), "Charge 0")
            for child in [staticIcon, missing, action] {
                guard let element = presented.scene.elements.first(where: { $0.id == child.id }) else { throw Failure.fixture }
                let local = NSRect(x: element.frame.x - presented.origin.x, y: element.frame.y - presented.origin.y,
                                   width: element.frame.width, height: element.frame.height)
                t.equal(child.accessibilityFrame(), NSAccessibility.screenRect(fromView: widget.view, rect: local))
            }
            t.check(action.accessibilityPerformPress())
            t.check(!action.accessibilityPerformPress())
            t.check(AppSelfTest.spin(timeout: 10) {
                recorder.calls == ["copy:charge 1"] &&
                widget.view.accessibilityParts.first(where: { $0.id.name == "charge" })?.accessibilityLabel() == "Charge 1"
            })
            t.equal(recorder.calls, ["copy:charge 1"], "a newly prepared native symbol completes the issued action once")
            t.check(recorder.mainThreads.allSatisfy { $0 })
            t.check(!action.accessibilityPerformPress())
            t.equal(action.accessibilityFrame(), .zero)
        }

        t.suite("App: Desk explicit accessibility: roles labels and empty descriptions use the accepted scene") {
            let source = """
            widget { Column {
                Text("Painted").size(100, 20).voiceOver("Spoken").name(label)
                Rectangle().size(40, 20).voiceOver("Rectangle").name(rectangle)
                Circle().size(20).voiceOver("Circle").name(circle)
                Progress(50%).size(40, 8).voiceOver("Half full").name(bar)
                Gauge(25%).size(30).voiceOver("Quarter full").name(gauge)
                Text("Silent").size(100, 20).voiceOver("").name(empty)
                Text("Hidden").size(100, 20).voiceOver("Hidden label").hidden()
                Text("Legacy").size(100, 20)
                Row { Text("Inside row").size(100, 20) }.voiceOver("Row group").name(rowGroup)
                Freeform { Text("Inside freeform").size(100, 20) }.voiceOver("Freeform group").name(freeformGroup)
            }.voiceOver("Group").name(group) }
            """
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, text: source)
            guard let presented = widget.latestPresented else { throw Failure.fixture }
            let expected: [String: (String, NSAccessibility.Role)] = [
                "label": ("Spoken", .staticText), "rectangle": ("Rectangle", .image),
                "circle": ("Circle", .image), "bar": ("Half full", .image),
                "gauge": ("Quarter full", .image), "empty": ("", .staticText), "group": ("Group", .group),
                "rowgroup": ("Row group", .group), "freeformgroup": ("Freeform group", .group)
            ]
            t.equal(widget.view.accessibilityParts.count, expected.count)
            for child in widget.view.accessibilityParts {
                guard let (label, role) = expected[child.id.name],
                      let element = presented.scene.elements.first(where: { $0.id == child.id }) else { throw Failure.fixture }
                t.equal(child.accessibilityLabel(), label)
                t.equal(child.accessibilityRole(), role)
                t.equal(element.accessibilityLabel, label)
                t.check(!child.canPress && !child.accessibilityPerformPress(), "a description does not invent a click action")
                let local = NSRect(x: element.frame.x - presented.origin.x, y: element.frame.y - presented.origin.y,
                                   width: element.frame.width, height: element.frame.height)
                t.equal(child.accessibilityFrame(), NSAccessibility.screenRect(fromView: widget.view, rect: local))
            }
            t.check(recorder.calls.isEmpty)
            let old = widget.view.accessibilityParts
            widget.close(deactivate: false)
            t.check(widget.view.accessibilityParts.isEmpty)
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            for child in old { t.equal(child.accessibilityFrame(), .zero); t.check(!child.accessibilityPerformPress()) }
        }

        t.suite("App: Desk explicit accessibility: description and pixels change together before owner acknowledgement") {
            let source = #"widget { variable count = 0; Text("Visible {count}").size(180, 40).voiceOver("Spoken {count}").onClick { count = count + 1; copy("{count}") } }"#
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, text: source)
            guard let host = widget.owner.host, let old = widget.view.accessibilityParts.first,
                  let original = widget.latestPresented, let image = widget.content.shown.image else { throw Failure.fixture }
            t.equal(old.accessibilityLabel(), "Spoken 0")
            t.equal(old.accessibilityRole(), .button)
            guard let token = widget.issueClickToken() else { throw Failure.fixture }
            widget.owner.primaryPress(at: SkinPoint(x: 20, y: 20), expectedGeneration: original.scene.generation,
                                      epoch: widget.destinationEpoch)
            widget.owner.primaryRelease(at: SkinPoint(x: 20, y: 20), token: token) { returned, effects in
                widget.handleEffects(effects, token: returned, issuedToken: token)
            }
            host.frames.runLoopTurn(.beforeWaiting)
            guard let scene = host.scene else { throw Failure.fixture }
            t.check(scene.generation > original.scene.generation)
            t.equal(scene.elements.first?.accessibilityLabel, "Spoken 1")
            t.check(widget.view.accessibilityParts.first === old)
            t.equal(old.accessibilityLabel(), "Spoken 0", "an unaccepted owner projection cannot update the Main label")
            t.check(widget.content.shown.image === image)
            t.check(AppSelfTest.spin(timeout: 10) {
                widget.view.accessibilityParts.first?.accessibilityLabel() == "Spoken 1" &&
                host.presented?.scene.generation == scene.generation && recorder.calls == ["copy:1"]
            })
            t.check(widget.content.shown.image !== image)
            t.check(!old.accessibilityPerformPress(), "a held description cannot adopt the new action generation")
            guard let current = widget.view.accessibilityParts.first else { throw Failure.fixture }
            t.check(current.accessibilityPerformPress())
            t.check(!current.accessibilityPerformPress())
            t.check(AppSelfTest.spin(timeout: 10) {
                widget.view.accessibilityParts.first?.accessibilityLabel() == "Spoken 2" && recorder.calls == ["copy:1", "copy:2"]
            })
            t.check(recorder.mainThreads.allSatisfy { $0 })
        }

        t.suite("App: Desk explicit accessibility: negative preset geometry keeps a labelled action aligned") {
            let source = """
            info { size: .small }
            widget { Freeform {
                Rectangle().size(80, 40).position(x: -100, y: -60).voiceOver("Open detail").name(detail)
                    .onClick { copy("detail") }
            }.size(240, 200) }
            """
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, text: source)
            guard let child = widget.view.accessibilityParts.first, let presented = widget.latestPresented,
                  let element = presented.scene.elements.first(where: { $0.id == child.id }) else { throw Failure.fixture }
            t.equal(widget.view.accessibilityParts.count, 1)
            t.equal(child.accessibilityLabel(), "Open detail")
            t.equal(child.accessibilityRole(), .button)
            t.equal(presented.scene.size, SkinSize(width: 170, height: 170))
            t.check(element.frame.width < 80 && element.frame.height < 40, "the preset maps actual overflow into its fixed bounds")
            let local = NSRect(x: element.frame.x - presented.origin.x, y: element.frame.y - presented.origin.y,
                               width: element.frame.width, height: element.frame.height)
            t.equal(child.accessibilityFrame(), NSAccessibility.screenRect(fromView: widget.view, rect: local))
            t.equal(presented.scene.hitMap.entry(at: element.frame.x + element.frame.width / 2,
                element.frame.y + element.frame.height / 2, handling: .leftUp, images: nil)?.elementID, child.id)
            t.check(child.accessibilityPerformPress())
            t.check(AppSelfTest.spin(timeout: 10) { recorder.calls == ["copy:detail"] })
            widget.handleUnavailable("invalidEnvironment", session: widget.sessionID, epoch: widget.destinationEpoch)
            t.check(widget.view.accessibilityParts.isEmpty)
            t.equal(child.accessibilityFrame(), .zero)
            t.check(!child.accessibilityPerformPress())
        }

        t.suite("App: Desk background accessibility: decorated preset Text preserves its label and action") {
            for background in [".background(.red).rounded(6)", ".background(.glass).rounded(.full)"] {
                let source = """
                info { size: .small }
                widget { variable count = 0; Freeform {
                    Text("Value {count}😀").font(20).size(80, 40).padding(4).position(x: -20, y: -10)
                        \(background).onClick { count = count + 1; copy("{count}") }
                }.size(200) }
                """
                let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, text: source)
                t.equal(widget.view.accessibilityParts.count, 1)
                guard let child = widget.view.accessibilityParts.first, let presented = widget.latestPresented,
                      let element = presented.scene.elements.first(where: { $0.id == child.id }) else { throw Failure.fixture }
                t.equal(child.accessibilityLabel(), "Value 0😀")
                let frame = NSRect(x: element.frame.x - presented.origin.x, y: element.frame.y - presented.origin.y,
                                   width: element.frame.width, height: element.frame.height)
                t.equal(child.accessibilityFrame(), NSAccessibility.screenRect(fromView: widget.view, rect: frame))
                t.check(child.accessibilityPerformPress())
                t.check(AppSelfTest.spin(timeout: 10) {
                    recorder.calls == ["copy:1"] && widget.view.accessibilityParts.first?.accessibilityLabel() == "Value 1😀"
                })
                t.check(!child.accessibilityPerformPress(), "decorations do not bypass stale-frame guards")
                widget.close(deactivate: false)
                t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            }
        }

        t.suite("App: Desk Freeform accessibility: actual negative Text frame maps to screen and activates once from a worker") {
            let worker = SkinThreadExecutor(name: "Desk Freeform accessibility worker test")
            var created: DeskWidgetWindowController?
            defer {
                if let created {
                    created.close(deactivate: false)
                    t.check(AppSelfTest.spin(timeout: 10) { created.isClosed })
                }
                worker.stop()
            }
            let source = """
            widget { variable n = 0; Freeform {
                Text("{n}").font(20).size(40, 32).position(x: -60, y: -50).onClick { n = n + 1; copy("{n}") }
                Text("H").font(20).size(40, 32).position(x: -70, y: -60).hidden().onClick { copy("hidden") }
            } }
            """
            let recorder = ActionRecorder()
            let widget = try actionFixture(t, recorder: recorder, executor: worker, text: source)
            created = widget
            t.equal(widget.view.accessibilityParts.count, 1, "hidden overlapping Text is absent from the actual AX tree")
            guard let child = widget.view.accessibilityParts.first, let presented = widget.latestPresented,
                  let element = presented.scene.elements.first(where: { $0.id == child.id }) else { throw Failure.fixture }
            t.equal(presented.scene.size, SkinSize())
            t.equal(element.frame, SkinRect(x: -60, y: -50, width: 40, height: 32))
            t.equal(presented.origin, SkinPoint(x: -60, y: -50))
            t.equal(presented.size, CGSize(width: 61, height: 51))
            t.equal(child.accessibilityRole(), .button)
            t.equal(child.accessibilityLabel(), "0")
            let localFrame = NSRect(x: 0, y: 0, width: 40, height: 32)
            let expectedScreen = NSAccessibility.screenRect(fromView: widget.view, rect: localFrame)
            t.equal(child.accessibilityFrame(), expectedScreen, "AX subtracts the accepted viewport origin exactly once")
            t.check(expectedScreen != NSAccessibility.screenRect(fromView: widget.view,
                rect: NSRect(x: -60, y: -50, width: 40, height: 32)), "omitting the scene-to-view conversion must fail")
            t.equal(presented.scene.hitMap.entry(at: -40, -34, handling: .leftUp, images: nil)?.elementID, child.id)
            t.check(presented.scene.hitMap.entry(at: 20, 16, handling: .leftUp, images: nil) == nil,
                    "using bitmap coordinates directly would miss this fully negative action")
            t.check(child.accessibilityPerformPress())
            t.check(!child.accessibilityPerformPress(), "the held AX child cannot enqueue a second transaction")
            t.check(AppSelfTest.spin(timeout: 10) { recorder.calls.count == 1 })
            t.equal(recorder.calls, ["copy:1"])
            t.check(recorder.mainThreads.allSatisfy { $0 })
            t.check(AppSelfTest.spin(timeout: 10) { widget.view.accessibilityParts.first?.accessibilityLabel() == "1" })
            t.check(!child.accessibilityPerformPress(), "the previous negative-coordinate child is stale after redraw")
        }

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
            guard let image = widget.content.shown.image, let space = widget.window.colorSpace?.cgColorSpace,
                  let host = widget.owner.host else { throw Failure.fixture }
            var captured: SkinBitmapDelivery?
            let forward = host.frames.requestBitmapDelivery
            host.frames.requestBitmapDelivery = { request in
                if case .frame(let frame) = request { captured = frame }
                forward?(request)
            }
            host.refresh(); host.frames.runLoopTurn(.beforeWaiting)
            guard let captured else { throw Failure.fixture }
            host.frames.requestBitmapDelivery = forward
            let covered = SkinBitmapDelivery(frame: SkinFrame(image: image, scale: original.scale), scene: scene,
                origin: origin, space: space, appearance: scene.environment.appearance.name,
                panelGeneration: widget.destinationEpoch, serial: captured.serial, lifecycle: captured.lifecycle)
            widget.handleBitmapRequest(.frame(covered), session: widget.sessionID)
            guard let child = widget.view.accessibilityParts.first else { throw Failure.fixture }
            let localFrame = NSRect(x: element.frame.x - origin.x, y: element.frame.y - origin.y,
                                   width: element.frame.width, height: element.frame.height)
            t.equal(child.accessibilityFrame(), NSAccessibility.screenRect(fromView: widget.view, rect: localFrame))
            t.check(!originalChild.accessibilityPerformPress())
            t.check(!child.accessibilityPerformPress(), "center resolves to the overlay rather than the exposed Text")
            t.check(recorder.calls.isEmpty)
        }
    }

    private static func presetAccessibilityTests(_ t: AppTestRunner) {
        t.suite("App: Desk preset accessibility: transformed Text frames and worker AX actions stay in displayed points") {
            let worker = SkinThreadExecutor(name: "Desk preset accessibility worker test")
            var created: DeskWidgetWindowController?
            defer {
                if let created {
                    created.close(deactivate: false)
                    t.check(AppSelfTest.spin(timeout: 10) { created.isClosed })
                }
                worker.stop()
            }
            let source = """
            info { size: .small }
            widget { variable points = 20; Freeform {
                Text("Preset").font(points).color(.accent).position(x: 20, y: 140).name(label)
                    .onClick { points = 80; copy("preset") }
            }.size(170) }
            """
            let recorder = ActionRecorder(), widget = try actionFixture(t, recorder: recorder, executor: worker, text: source)
            created = widget
            t.equal(widget.view.frame.size, NSSize(width: 170, height: 170))
            t.equal(widget.view.accessibilityParts.count, 1)
            func naturalSize(points: Double) -> CGSize {
                var style = TextStyle()
                style.fontFace = "System"; style.fontSize = points * 0.75; style.fontWeight = 400
                style.horizontalAlign = .center; style.verticalAlign = .center
                style.accurateText = true; style.antiAlias = true; style.trailingSpaces = true
                let measured = DrawContext(fonts: AppFontResolver()).text.layout("Preset", style: style, wrapWidth: nil, cycle: 1).size
                return CGSize(width: measured.width, height: measured.height)
            }
            func checkFrame(_ child: DeskWidgetAccessibilityElement, points: Double) throws -> (NSRect, Double) {
                let natural = naturalSize(points: points)
                let factor = min(1, min(170 / max(170, 20 + Double(natural.width)),
                                        170 / max(170, 140 + Double(natural.height))))
                let local = NSRect(x: 20 * factor, y: 140 * factor,
                                   width: Double(natural.width) * factor, height: Double(natural.height) * factor)
                guard let presented = widget.latestPresented,
                      let element = presented.scene.elements.first(where: { $0.id.name == "label" }) else { throw Failure.fixture }
                t.equal(presented.scene.size, SkinSize(width: 170, height: 170))
                t.equal(presented.origin, SkinPoint(), "Core already maps overflow into the final preset point coordinates")
                t.close(element.frame.x, Double(local.minX)); t.close(element.frame.y, Double(local.minY))
                t.close(element.frame.width, Double(local.width)); t.close(element.frame.height, Double(local.height))
                t.equal(child.accessibilityLabel(), "Preset", "AX finds the Text within the actual transformed drawing group")
                t.equal(child.accessibilityRole(), .button)
                let screen = NSAccessibility.screenRect(fromView: widget.view, rect: local)
                let actual = child.accessibilityFrame()
                t.close(actual.minX, screen.minX); t.close(actual.minY, screen.minY)
                t.close(actual.width, screen.width); t.close(actual.height, screen.height)
                t.equal(presented.scene.hitMap.entry(at: local.midX, local.midY, handling: .leftUp, images: nil)?.elementID,
                        child.id, "the displayed AX center hits the same actual action leaf")
                return (local, factor)
            }
            guard let first = widget.view.accessibilityParts.first else { throw Failure.fixture }
            let (_, originalFactor) = try checkFrame(first, points: 20)
            t.equal(originalFactor, 1, "the initial native text fits without enlargement")
            let generation = widget.latestPresented?.scene.generation ?? 0
            t.check(first.accessibilityPerformPress())
            t.check(!first.accessibilityPerformPress(), "the same held AX child queues at most one worker transaction")
            t.check(AppSelfTest.spin(timeout: 10) {
                recorder.calls.count == 1 && (widget.latestPresented?.scene.generation ?? 0) > generation
            })
            t.equal(recorder.calls, ["copy:preset"])
            t.check(recorder.mainThreads.allSatisfy { $0 }, "a worker projection releases the fake service on Main")
            t.check(!first.accessibilityPerformPress(), "the old child's source generation remains stale after resizing content")
            guard let current = widget.view.accessibilityParts.first, let presented = widget.latestPresented else { throw Failure.fixture }
            let (local, factor) = try checkFrame(current, points: 80)
            t.check(factor > 0 && factor < 1, "the larger font produces real overflow and a proportional fit")
            let natural = naturalSize(points: 80)
            t.check(presented.scene.hitMap.entry(at: 20 + Double(natural.width) / 2, 140 + Double(natural.height) / 2,
                handling: .leftUp, images: nil) == nil, "using the unfitted center must miss")
            t.check(presented.scene.hitMap.entry(at: local.midX * factor, local.midY * factor,
                handling: .leftUp, images: nil) == nil, "applying preset scaling twice must miss")
            var drained = false
            widget.executor.async { [owner = widget.owner] in
                owner.host?.refresh(); owner.host?.frames.runLoopTurn(.beforeWaiting)
                DispatchQueue.main.async { drained = true }
            }
            let currentGeneration = presented.scene.generation
            t.check(AppSelfTest.spin(timeout: 10) {
                drained && (widget.latestPresented?.scene.generation ?? 0) > currentGeneration
            })
            t.equal(recorder.calls, ["copy:preset"], "a cached redraw cannot replay the last action")
            t.check(!current.accessibilityPerformPress())
            guard let afterRedraw = widget.view.accessibilityParts.first else { throw Failure.fixture }
            _ = try checkFrame(afterRedraw, points: 80)
            let dark = widget.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard let alternate = NSAppearance(named: dark ? .aqua : .darkAqua) else { throw Failure.fixture }
            widget.window.appearance = alternate
            _ = widget.currentFacts()
            t.check(widget.destinationEpoch != afterRedraw.epoch)
            t.check(!afterRedraw.accessibilityPerformPress(), "a destination change rejects the held transformed AX child")
            widget.close(deactivate: false)
            t.check(!afterRedraw.accessibilityPerformPress(), "close does not wait for the worker ACK to invalidate AX")
            t.check(AppSelfTest.spin(timeout: 10) { widget.isClosed })
            t.equal(afterRedraw.accessibilityFrame(), .zero)
            t.equal(recorder.calls, ["copy:preset"])
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
