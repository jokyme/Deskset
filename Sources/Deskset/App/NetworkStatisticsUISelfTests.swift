import AppKit
import DesksetCore

/// Debug ▸ Network's native action uses the app's injected provider; fixtures never reset the Mac's live statistics.
enum NetworkStatisticsUISelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Network statistics: Debug Network resets the provider shared by all skin windows") {
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
            let debug = DebugWindowController.show(app: app, tab: .network)
            defer { debug.close() }
            let button = debug.networkInfo.testResetStatisticsButton
            t.equal(button.title, "Reset statistics")
            t.equal(button.accessibilityLabel(), "Reset statistics")
            t.equal(button.cell?.accessibilityRole(), .button, "AppKit exposes the standard button through its cell")
            t.check(button.isEnabled && button.target === debug.networkInfo && button.action != nil,
                    "the native button has its real action")
            t.equal(system.resetCount, 0, "opening Debug Network does not reset statistics")
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
            debug.selectTab(.log)
            debug.selectTab(.network)
            t.equal(system.resetCount, 2, "switching tabs does not invoke the reset action")
            checkLayout(t, debug)
        }
    }

    private static func checkLayout(_ t: AppTestRunner, _ debug: DebugWindowController) {
        guard let window = debug.window else {
            return t.check(false, "the Debug Network pane exists")
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 680, height: 420))
            debug.networkInfo.layoutSubtreeIfNeeded()
            let view = debug.networkInfo
            let button = view.testResetStatisticsButton
            let virtualCheck = view.testVirtualCheckbox
            t.check(button.bounds.width + 0.01 >= button.intrinsicContentSize.width,
                    "\(appearance.rawValue): the complete button title fits")
            let resetRect = button.convert(button.bounds, to: view)
            let virtualRect = virtualCheck.convert(virtualCheck.bounds, to: view)
            t.check(resetRect.width > 0 && resetRect.height > 0 && view.bounds.contains(resetRect),
                    "\(appearance.rawValue): Reset statistics stays visible")
            t.check(!resetRect.intersects(virtualRect),
                    "\(appearance.rawValue): Reset statistics does not overlap Show virtual interfaces")
            t.check(debug.snapshot() != nil, "\(appearance.rawValue): Debug Network renders off-screen")
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
