import AppKit
import DesksetCore

/// General's native action uses the app's injected provider; fixtures never reset the Mac's live statistics.
enum NetworkStatisticsUISelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Network statistics: General resets the provider shared by all skin windows") {
            let system = NetworkStatisticsRuntimeSelfTests.TestSystem()
            guard let app = try AppSelfTest.makeApp(t, system: system) else { return }
            t.atSuiteEnd { app.stopAllForTermination(); app.endEngineThread() }
            var windows: [SkinWindowController] = []
            for name in ["A", "B"] {
                guard let controller = try load(t, app: app, name: name) else { return }
                windows.append(controller)
            }
            let before = windows.map(\.state)
            t.check(app.system === system, "the app retains the injected provider")
            for controller in windows {
                t.equal(controller.runtime.exclusive { $0.system === system }, true,
                        "every window receives the app's provider")
                t.equal(controller.runtime.exclusive { $0.system.cumulativeNetworkCounters(interface: nil) },
                        NetworkCounters(received: 300, sent: 500))
            }
            CodeEditorRoutingSelfTests.withFakes(CodeEditorRoutingSelfTests.FakeLocator(),
                                                 CodeEditorRoutingSelfTests.RecordingOpener()) {
                let settings = SettingsWindowController(app: app)
                defer { settings.close() }
                settings.select(.general)
                let button = settings.resetStatisticsButton
                t.equal(button.title, "Reset statistics")
                t.equal(button.accessibilityLabel(), "Reset statistics")
                t.equal(button.cell?.accessibilityRole(), .button, "AppKit exposes the standard button through its cell")
                t.check(button.isEnabled && button.target === settings && button.action != nil,
                        "the native button has its real action")
                t.equal(system.resetCount, 0, "opening General does not reset statistics")
                button.performClick(nil)
                t.equal(system.resetCount, 1, "one click resets once without a confirmation")
                for controller in windows {
                    t.equal(controller.runtime.exclusive { $0.system.cumulativeNetworkCounters(interface: nil) },
                            NetworkCounters(), "the reset is shared by every skin")
                    t.equal(controller.runtime.exclusive { $0.system.networkCounters(interface: nil) },
                            NetworkCounters(received: 1000, sent: 2000), "rate counters are unchanged")
                    t.check(app.controller(for: controller.config) === controller && !controller.isStopped,
                            "resetting does not replace or unload a skin")
                }
                t.equal(windows.map(\.state), before, "the action does not change skin settings")
                system.setTotals(NetworkCounters(received: 75, sent: 125))
                button.performClick(nil)
                t.equal(system.resetCount, 2, "the button remains usable after more traffic")
                t.equal(system.cumulativeNetworkCounters(interface: nil), NetworkCounters())
                settings.select(.editor)
                settings.select(.general)
                t.equal(system.resetCount, 2, "switching panes does not invoke the reset action")
                checkLayout(t, settings)
            }
        }
    }

    private static func checkLayout(_ t: AppTestRunner, _ settings: SettingsWindowController) {
        guard let window = settings.window, let content = window.contentView else {
            return t.check(false, "the General pane exists")
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            t.close(content.bounds.width, SettingsWindowController.contentWidth)
            t.check(content.bounds.height >= ceil(content.fittingSize.height),
                    "\(appearance.rawValue): the compact pane fits its controls")
            let controls: [NSView] = [settings.defaultZoomField, settings.defaultZoomStepper,
                                     settings.forceZoomBox, settings.disableDraggingBox,
                                     settings.resetStatisticsButton, settings.automaticUpdatesBox,
                                     settings.checkUpdatesButton]
            for control in controls {
                let rect = control.convert(control.bounds, to: content)
                t.check(rect.width > 0 && rect.height > 0 && content.bounds.contains(rect),
                        "\(appearance.rawValue): General's controls remain fully visible")
            }
            let button = settings.resetStatisticsButton
            t.check(button.bounds.width + 0.01 >= button.intrinsicContentSize.width,
                    "\(appearance.rawValue): the complete button title fits")
            let reset = button.convert(button.bounds, to: content)
            let dragging = settings.disableDraggingBox.convert(settings.disableDraggingBox.bounds, to: content)
            let updates = settings.automaticUpdatesBox.convert(settings.automaticUpdatesBox.bounds, to: content)
            t.check(!reset.intersects(dragging) && !reset.intersects(updates),
                    "\(appearance.rawValue): the button does not overlap adjacent settings")
            t.check(settings.snapshot() != nil, "\(appearance.rawValue): General renders off-screen")
        }
    }

    private static func load(_ t: AppTestRunner, app: AppController, name: String) throws -> SkinWindowController? {
        let config = "NetworkUI\\\(name)"
        let folder = SkinLibrary.directory(for: config, root: app.skinsDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        [Rainmeter]
        Update=-1
        [Face]
        Meter=String
        Text=Network statistics
        """.write(to: folder.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
        app.state.update(config) { $0.file = "Skin.ini" }
        app.rescanLibrary()
        guard let controller = app.activate(config: config, file: "Skin.ini") else {
            t.check(false, "the UI fixture loads")
            return nil
        }
        guard AppSelfTest.spin(until: { controller.isStarted }) else {
            t.check(false, "the UI fixture starts")
            return nil
        }
        return controller
    }
}
