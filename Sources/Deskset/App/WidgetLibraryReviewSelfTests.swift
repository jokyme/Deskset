import AppKit
import Darwin
import DesksetCore

/// Regression self-tests for Widget Library thumbnail isolation, Loaded Skins variant selection, the visible
/// `SkinInspectorSheetView` controls, `MinimumDeskset` installer warnings, and closed-window notification overhead.
enum WidgetLibraryReviewSelfTests {
    static func run(_ t: AppTestRunner) {
        thumbnailNetworkIsolationTests(t)
        loadedSkinsVariantTests(t)
        inspectorSheetControlsTests(t)
        minimumDesksetInstallTests(t)
        closedWindowNotificationTests(t)
    }

    // MARK: - 1. Thumbnail network isolation

    private static func thumbnailNetworkIsolationTests(_ t: AppTestRunner) {
        t.suite("App: Widget Library: thumbnail rendering never starts HTTP requests") {
            guard let app = try AppSelfTest.makeApp(t),
                  let probe = LoopbackHTTPProbe() else {
                return t.check(false, "app and loopback HTTP probe")
            }
            defer { probe.stop() }

            let fm = FileManager.default
            let remoteDir = app.skinsDirectory.appendingPathComponent("RemoteFeedDemo")
            try fm.createDirectory(at: remoteDir, withIntermediateDirectories: true)
            let localFile = remoteDir.appendingPathComponent("local.txt")
            try "LocalPreviewValue".write(to: localFile, atomically: true, encoding: .utf8)
            let ini = """
            [Rainmeter]
            Update=1000
            SkinWidth=120
            SkinHeight=48

            [MeasureRemote]
            Measure=WebParser
            URL=http://127.0.0.1:\(probe.port)/demo-feed
            RegExp=(?siU)(.*)
            StringIndex=1

            [MeasureLocal]
            Measure=WebParser
            URL=file://\(localFile.path)
            RegExp=(?siU)(.*)
            StringIndex=1
            FinishAction=[!UpdateMeter MeterLabel][!Redraw]

            [MeterLabel]
            Meter=String
            MeasureName=MeasureLocal
            Text=%1
            FontSize=14
            FontColor=255,255,255,255
            W=120
            H=48
            DynamicVariables=1
            """
            try ini.write(to: remoteDir.appendingPathComponent("Card.ini"), atomically: true, encoding: .utf8)
            defer {
                try? fm.removeItem(at: remoteDir)
                app.rescanLibrary()
            }
            app.rescanLibrary()

            let cache = SkinThumbnailCache()
            // Exercise async card preview rendering (the exact path WidgetLibraryRootView triggers).
            _ = cache.thumbnail(config: "RemoteFeedDemo", file: "Card.ini", isDark: true, app: app)
            let settled = AppSelfTest.spin(timeout: 5) {
                cache.thumbnail(config: "RemoteFeedDemo", file: "Card.ini", isDark: true, app: app) != nil
                    && cache.activeSettlingCount == 0
            }
            t.check(settled, "thumbnail rendered and settled local file:// WebParser work")
            // Also exercise immediate prewarm path.
            cache.invalidateAll()
            let immediate = cache.thumbnail(
                config: "RemoteFeedDemo",
                file: "Card.ini",
                isDark: false,
                app: app,
                immediate: true
            )
            t.check(immediate != nil, "immediate thumbnail rendered")
            // Give any stray background URLSession task a brief run-loop turn to hit loopback if one had started.
            _ = AppSelfTest.spin(timeout: 0.15) { probe.hitCount > 0 }
            t.equal(probe.hitCount, 0, "rendering unloaded skin thumbnails must not make HTTP requests")
        }
    }

    // MARK: - 2. Loaded Skins variant priority

    private static func loadedSkinsVariantTests(_ t: AppTestRunner) {
        t.suite("App: Widget Library: Loaded Skins shows and operates on the running variant") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let fm = FileManager.default
            let dir = app.skinsDirectory.appendingPathComponent("VariantSuite")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["Large.ini", "Small.ini"] {
                try """
                [Rainmeter]
                Update=-1
                [Metadata]
                Name=\(name)
                [Meter]
                Meter=String
                Text=\(name)
                """
                .write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            defer {
                app.deactivate(config: "VariantSuite")
                try? fm.removeItem(at: dir)
                app.rescanLibrary()
            }
            app.rescanLibrary()

            // 1. Open Widget Library first while VariantSuite is unloaded: Large.ini sorts before Small.ini.
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            t.equal(card(for: "VariantSuite", in: manage)?.chosenFile, "Large.ini")

            // 2. Load Small.ini from another entry point, then switch to Loaded Skins.
            guard let small = app.activate(config: "VariantSuite", file: "Small.ini") else {
                return t.check(false, "Small.ini activates")
            }
            t.check(AppSelfTest.spin { card(for: "VariantSuite", in: manage)?.activeFile == "Small.ini" })
            manage.libraryModel.switchSection(.active)
            manage.reload()
            let activeCard = card(for: "VariantSuite", in: manage)
            t.equal(activeCard?.chosenFile, "Small.ini", "Loaded Skins displays the running Small.ini variant")
            t.equal(activeCard?.activeFile, "Small.ini")

            // 3. Even if the user previews Large.ini in Installed, switching back to Loaded Skins resets to Small.ini.
            manage.libraryModel.switchSection(.installed)
            manage.reload()
            manage.selectInLibrary(config: "VariantSuite", file: "Large.ini")
            t.equal(card(for: "VariantSuite", in: manage)?.chosenFile, "Large.ini")

            manage.libraryModel.switchSection(.active)
            manage.reload()
            guard let switchedBack = card(for: "VariantSuite", in: manage) else {
                return t.check(false, "VariantSuite card in Loaded Skins")
            }
            t.equal(switchedBack.chosenFile, "Small.ini", "re-entering Loaded Skins prioritizes the running file")
            t.check(app.controller(for: "VariantSuite") === small)

            // Primary button action on the Loaded Skins card unloads Small.ini rather than replacing it with Large.ini.
            manage.testToggleLoad(config: switchedBack.config.name, file: switchedBack.chosenFile)
            t.equal(app.controller(for: "VariantSuite"), nil, "clicking primary button unloads the running skin")
        }
    }

    // MARK: - 3. Visible SkinInspectorSheetView controls

    private static func inspectorSheetControlsTests(_ t: AppTestRunner) {
        t.suite("App: Widget Library: visible SkinInspectorSheetView exposes Display monitor, exact Zoom and Load order") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.selectInLibrary(config: skin.config, file: skin.file)

            let host = manage.makeInspectorViewForTesting(config: skin.config)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                host.layoutSubtreeIfNeeded()
                _ = AppSelfTest.spin(timeout: 0.05) { false }
                host.layoutSubtreeIfNeeded()
                t.check(findView(in: host, matching: { ($0 as? NSPopUpButton)?.accessibilityLabel() == "Display monitor" }) != nil,
                        "\(appearance.rawValue): Display monitor pop-up is mounted in visible inspector")
                t.check(findView(in: host, matching: { $0 is SkinZoomStepper }) != nil,
                        "\(appearance.rawValue): SkinZoomStepper is mounted in visible inspector")
                t.check(findTextField(labelled: "Skin zoom", in: host) != nil,
                        "\(appearance.rawValue): exact Zoom text field is mounted in visible inspector")
                t.check(findTextField(labelled: "Load order:", in: host) != nil,
                        "\(appearance.rawValue): Load order text field is mounted in visible inspector")
            }

            // 1. Display monitor pull-down operates on the shared monitor choices.
            guard let monitorPopup = findView(in: host, matching: {
                ($0 as? NSPopUpButton)?.accessibilityLabel() == "Display monitor"
            }) as? NSPopUpButton, let monitorMenu = monitorPopup.menu else {
                return t.check(false, "Display monitor pop-up and menu")
            }
            t.check(monitorPopup.isEnabled)
            monitorMenu.delegate?.menuNeedsUpdate?(monitorMenu)
            let expectedMonitor = app.displayMonitorMenu(for: skin, appliesToSelection: false)
            t.equal(monitorMenu.items.dropFirst().map(\.title), expectedMonitor.items.map(\.title))
            performMenuItem(monitorMenu.item(withTitle: "@0: Virtual screen"))
            t.check(AppSelfTest.spin {
                skin.state.windowX?.contains("@0") == true && skin.state.windowY?.contains("@0") == true
            }, "selecting @0 in SkinInspectorSheetView updates WindowX/WindowY monitor selector")
            monitorMenu.delegate?.menuNeedsUpdate?(monitorMenu)
            performMenuItem(monitorMenu.item(withTitle: "Use default: Primary monitor"))
            t.check(AppSelfTest.spin {
                skin.state.windowX?.contains("@") != true && skin.state.windowY?.contains("@") != true
            })

            // 2. Exact Zoom text field (125%) + 1% / Control-10% stepper.
            guard let zoomField = findTextField(labelled: "Skin zoom", in: host),
                  let zoomStepper = findView(in: host, matching: { $0 is SkinZoomStepper }) as? SkinZoomStepper else {
                return t.check(false, "Zoom field and stepper")
            }
            t.check(zoomField.isEnabled && zoomStepper.isEnabled)
            t.equal(zoomField.stringValue, "100")
            submitText("125", into: zoomField, window: window)
            t.check(AppSelfTest.spin {
                skin.zoomOverridePercent == 125 && skin.effectiveZoomFactor == 1.25 && zoomStepper.integerValue == 125
            }, "typing 125 into SkinInspectorSheetView sets 125% zoom")

            zoomStepper.useIncrement(for: [])
            t.equal(zoomStepper.increment, 1, "single-step zoom precision is 1 percentage point")
            zoomStepper.useIncrement(for: .control)
            t.equal(zoomStepper.increment, 10, "holding Control steps zoom by 10 percentage points")
            zoomStepper.integerValue = 126
            performControl(zoomStepper)
            t.check(AppSelfTest.spin {
                skin.zoomOverridePercent == 126 && zoomField.stringValue == "126"
            }, "stepping SkinZoomStepper updates zoom and text field to 126%")

            app.setDefaultZoom(percent: 140, force: true)
            t.check(AppSelfTest.spin {
                host.layoutSubtreeIfNeeded()
                return !zoomStepper.isEnabled && zoomField.stringValue == "140"
            }, "Force default zoom disables the inspector zoom stepper and reflects 140%")
            app.setDefaultZoom(percent: nil, force: false)
            t.check(AppSelfTest.spin {
                host.layoutSubtreeIfNeeded()
                return zoomStepper.isEnabled && zoomField.stringValue == "126"
            })

            // 3. Load order text field commits integer load order.
            guard let loadOrderField = findTextField(labelled: "Load order:", in: host) else {
                return t.check(false, "Load order field")
            }
            submitText("7", into: loadOrderField, window: window)
            t.check(AppSelfTest.spin { skin.state.loadOrder == 7 }, "Load order commits in SkinInspectorSheetView")

            // 4. Selecting an unloaded variant disables Display monitor for the running variant.
            manage.selectInLibrary(config: skin.config, file: "Focus.ini")
            t.check(AppSelfTest.spin {
                host.layoutSubtreeIfNeeded()
                return !monitorPopup.isEnabled
            }, "inspecting an unloaded variant disables Display monitor")
        }
    }

    // MARK: - 4. MinimumDeskset warning in InstallSummary & confirmation UI

    private static func minimumDesksetInstallTests(_ t: AppTestRunner) {
        t.suite("App: Installer: MinimumDeskset warns in confirmation summary and accessory view") {
            let previousConfirm = SkinInstallFlow.confirmForTesting
            let previousOptions = SkinInstallFlow.optionsForTesting
            defer {
                SkinInstallFlow.confirmForTesting = previousConfirm
                SkinInstallFlow.optionsForTesting = previousOptions
            }

            guard let app = try AppSelfTest.makeApp(t) else { return }
            let package = try AppSelfTest.makePackage(t, name: "MinDeskset9.rmskin", files: [
                "RMSKIN.ini": Data("[rmskin]\nName=FutureWidget\nMinimumDeskset=9.0.0\n".utf8),
                "Skins/FutureWidget/Card.ini": Data("[Rainmeter]\nUpdate=-1\n".utf8),
            ])
            defer {
                try? FileManager.default.removeItem(at: app.skinsDirectory.appendingPathComponent("FutureWidget"))
                app.rescanLibrary()
            }

            let inspection = try RmskinPackage.inspect(package)
            defer { inspection.cleanup() }
            let summary = InstallSummary(inspection, packageName: package.lastPathComponent, skinsDirectory: app.skinsDirectory)
            t.equal(summary.warnings.filter { $0.contains("Deskset 9.0.0 or later") }.count, 1, "\(summary.warnings)")

            let accessory = SkinInstallFlow.accessoryView(summary, headerImage: nil)
            let renderedWarning = findView(in: accessory, matching: {
                ($0 as? NSTextField)?.stringValue.contains("Deskset 9.0.0 or later") == true
            })
            t.check(renderedWarning != nil, "confirmation accessoryView displays the MinimumDeskset warning")

            var confirmedSummary: InstallSummary?
            SkinInstallFlow.optionsForTesting = { _, defaults in
                var o = defaults
                o.backupSkins = false
                return o
            }
            SkinInstallFlow.confirmForTesting = { captured, _ in
                confirmedSummary = captured
                return true
            }
            app.installer.open([package])
            t.check(AppSelfTest.spin(timeout: 5) { app.installer.isIdle })
            t.equal(confirmedSummary?.warnings.filter { $0.contains("Deskset 9.0.0 or later") }.count, 1)
            t.check(FileManager.default.fileExists(
                atPath: app.skinsDirectory.appendingPathComponent("FutureWidget/Card.ini").path
            ))
        }
    }

    // MARK: - 5. Closed Widget Library notification overhead

    private static func closedWindowNotificationTests(_ t: AppTestRunner) {
        t.suite("App: Widget Library: closing the window stops .desksetSkinsChanged metadata rescans") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let fm = FileManager.default
            let bulkRoot = app.skinsDirectory.appendingPathComponent("BulkBenchSuite")
            let padding = String(repeating: "; padding line for realistic 19 KB skin file metadata scan\n", count: 320)
            for idx in 0..<60 {
                let dir = bulkRoot.appendingPathComponent(String(format: "Skin%02d", idx))
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let content = """
                [Rainmeter]
                Update=-1
                [Metadata]
                Name=Bulk Skin \(idx)
                Author=Deskset
                Information=Benchmark config \(idx)
                Version=1.0
                \(padding)
                [Meter]
                Meter=String
                Text=\(idx)
                """
                try content.write(to: dir.appendingPathComponent("Main.ini"), atomically: true, encoding: .utf8)
            }
            defer {
                try? fm.removeItem(at: bulkRoot)
                app.rescanLibrary()
            }
            app.rescanLibrary()

            let manage = ManageWindowController(app: app)
            let revWhenOpen = manage.libraryModel.revision
            manage.close()

            // Post .desksetSkinsChanged three times while closed: libraryModel must not rebuild on the main thread.
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<3 {
                NotificationCenter.default.post(name: .desksetSkinsChanged, object: app)
            }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            t.equal(manage.libraryModel.revision, revWhenOpen,
                    "closed Widget Library defers model & metadata rebuilds")
            t.check(elapsedMs < 20, "three .desksetSkinsChanged notifications while closed took \(elapsedMs) ms")

            // Reopening catches up with changes that happened while closed.
            guard let loaded = app.activate(config: "BulkBenchSuite\\Skin00", file: "Main.ini") else {
                return t.check(false, "BulkBenchSuite\\Skin00 activates")
            }
            defer { app.deactivate(config: loaded.config) }
            t.equal(manage.libraryModel.revision, revWhenOpen, "still deferred before reopening")
            manage.prepareForPresentation()
            t.check(manage.libraryModel.revision != revWhenOpen, "reopening flushes deferred reload")
            t.equal(card(for: "BulkBenchSuite\\Skin00", in: manage)?.activeFile, "Main.ini")
        }
    }

    // MARK: - Helpers

    private static func card(for config: String, in manage: ManageWindowController) -> WidgetLibraryViewModel.CardItem? {
        manage.libraryModel.cards.first { $0.config.name.caseInsensitiveCompare(config) == .orderedSame }
    }

    private static func findView(in root: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(root) { return root }
        for child in root.subviews {
            if let found = findView(in: child, matching: predicate) { return found }
        }
        return nil
    }

    private static func findTextField(labelled label: String, in root: NSView) -> NSTextField? {
        findView(in: root, matching: { view in
            guard let field = view as? NSTextField, field.isEditable else { return false }
            return field.accessibilityLabel() == label
        }) as? NSTextField
    }

    private static func submitText(_ value: String, into field: NSTextField, window: NSWindow) {
        _ = window
        field.stringValue = value
        performControl(field)
    }

    private static func performControl(_ control: NSControl) {
        guard let action = control.action else { return }
        _ = control.sendAction(action, to: control.target)
    }

    private static func performMenuItem(_ item: NSMenuItem?) {
        guard let item, item.isEnabled, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// Minimal loopback TCP listener counting incoming HTTP connections for thumbnail isolation tests.
private final class LoopbackHTTPProbe: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var hits = 0
    private var stopped = false

    var hitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return hits
    }

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { break }
            lock.lock()
            let done = stopped
            if !done { hits += 1 }
            lock.unlock()
            if done {
                Darwin.close(client)
                break
            }
            var buf = [UInt8](repeating: 0, count: 1024)
            _ = recv(client, &buf, buf.count, 0)
            let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
            _ = reply.withCString { send(client, $0, strlen($0), 0) }
            Darwin.close(client)
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    deinit {
        stop()
    }
}
