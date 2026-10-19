import AppKit
import DesksetCore

enum DebugSelfTests {
    static func run(_ t: AppTestRunner) {
        entryPoints(t)
        logTests(t)
        pluginAndWindowTests(t)
        logFileTests(t)
    }

    private static func entryPoints(_ t: AppTestRunner) {
        t.suite("App: Debug: entry points and skin selection") {
            guard let app = try AppSelfTest.makeApp(t),
                  let focus = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            defer { DebugWindowController.window(for: app)?.close(); AboutWindowController.window(for: app)?.close() }
            t.equal(DebugWindowController.Tab.allCases.map(\.rawValue), ["Log", "Skins", "Display", "Network", "Plugins"])
            t.equal(DebugWindowController.Tab.parse("sKiN"), .skins)
            t.equal(DebugWindowController.Tab.parse("Network"), .network)
            let menu = NSMenu(); app.buildMainMenu(menu)
            t.check(menu.item(withTitle: "Debug") != nil)
            let skinMenu = app.skinMenu(for: focus, includeCustomItems: true)
            t.check(skinMenu.item(withTitle: "Debug Skin") != nil)
            app.openLogAction()
            guard let debug = DebugWindowController.window(for: app) else { return t.check(false, "Debug opens") }
            t.equal(debug.selectedTab, .log)
            focus.skin.execute("[!Debug Skin]", from: nil)
            t.check(AppSelfTest.spin { debug.selectedTab == .skins && debug.skinInspector.selectedSkinConfig == focus.config })
            focus.skin.execute("[!Debug Display]", from: nil)
            t.check(AppSelfTest.spin { debug.selectedTab == .display })
            focus.skin.execute("[!Debug Network]", from: nil)
            t.check(AppSelfTest.spin { debug.selectedTab == .network })
            focus.skin.execute("[!Debug Plugins]", from: nil)
            t.check(AppSelfTest.spin { debug.selectedTab == .plugins })
            app.aboutAction()
            t.equal(AboutWindowController.window(for: app)?.selectedTab, .version)
            t.equal(debug.selectedTab, .plugins)
            app.handleStatusItemClick(type: .leftMouseUp, modifiers: [.control])
            t.equal(debug.selectedTab, .log)
            app.finishLayoutCommandStartup()
            let channel = LayoutCommandsSelfTests.MemoryChannel()
            let name = "DesksetTests.Debug.\(UUID().uuidString)"
            let server = LayoutCommandServer(channel: channel, namespace: name, pid: 777) { request, completion in
                app.receiveLayoutCommand(request, completion: completion)
            }
            defer { server.stop() }
            let client = LayoutCommandClient(channel: channel, namespace: name)
            t.equal(client.send(.command(.debug(.skins, config: focus.config)), to: 777, timeout: 0.2), .succeeded)
            t.equal(debug.selectedTab, .skins)
            t.equal(debug.skinInspector.selectedSkinConfig, focus.config)
        }
    }

    private static func logTests(_ t: AppTestRunner) {
        t.suite("App: Debug: 50 log entries, filters, selection and frozen copy") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            for index in 1...55 { Log.write("History-\(index)", source: "DebugTest") }
            let debug = DebugWindowController.show(app: app)
            defer { debug.close() }
            t.equal(debug.displayedLogs.count, 50)
            t.equal(debug.displayedLogs.first?.message, "History-55")
            t.equal(debug.displayedLogs.last?.message, "History-6")
            debug.testLogTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            debug.menuNeedsUpdate(debug.testLogMenu)
            Log.write("New message"); debug.pollLogNow()
            t.equal(debug.testLogTable.selectedRow, 1)
            debug.testLogMenu.performActionForItem(at: 0)
            t.equal(NSPasteboard.general.string(forType: .string), "History-55")
            t.check(NSApp.sendAction(#selector(NSText.copy(_:)), to: debug.testLogTable, from: nil))
            t.equal(NSPasteboard.general.string(forType: .string), "History-55")
            debug.clearLogPanel()
            let recentCount = Log.recent.count
            debug.pollLogNow(); t.equal(debug.displayedLogs.count, 0)
            t.equal(Log.recent.count, recentCount)
            debug.setLogFilter(error: false, notice: false)
            Log.write("Hidden error", level: .error)
            Log.write("Visible warning", level: .warning)
            debug.setLogFilter(error: true, notice: true)
            t.equal(debug.displayedLogs.map(\.message), ["Visible warning"])
            Log.write("Visible notice"); debug.setLogFilter(notice: false)
            t.equal(debug.displayedLogs.first?.message, "Visible notice")
            debug.testLogTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            for index in 1...(Log.recentLimit + 5) { Log.write("Flood-\(index)", level: .warning) }
            debug.pollLogNow()
            t.equal(debug.displayedLogs.count, Log.recentLimit)
            t.equal(debug.testLogTable.selectedRow, -1)
            debug.close()
            t.check(DebugWindowController.window(for: app) == nil)
            let reopened = DebugWindowController.show(app: app)
            defer { reopened.close() }
            t.equal(reopened.displayedLogs.count, 50)
        }
    }

    private static func pluginAndWindowTests(_ t: AppTestRunner) {
        t.suite("App: Debug: bundled metadata and five panes in light and dark") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let debug = DebugWindowController.show(app: app, tab: .plugins)
            defer { debug.close() }
            t.equal(debug.testPluginsTable.tableColumns.map(\.title), ["Name", "Version", "Author"])
            let names = debug.plugins.map(\.name)
            t.check(names.count >= 15)
            t.equal(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
            t.equal(names.filter { $0.lowercased().hasPrefix("itunes") }.count, 1)
            t.check(debug.plugins.allSatisfy { $0.version == "\(AppVersion.current) (bundled)" && $0.author == "jokyme" })
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                debug.window?.appearance = NSAppearance(named: appearance)
                debug.window?.setContentSize(NSSize(width: 680, height: 398))
                for tab in DebugWindowController.Tab.allCases {
                    debug.selectTab(tab)
                    let rep = debug.snapshot()
                    let scale = debug.window?.backingScaleFactor ?? 1
                    t.equal(rep?.pixelsWide, Int(680 * scale))
                    t.equal(rep?.pixelsHigh, Int(398 * scale))
                    t.equal(debug.window?.contentView?.bounds.width, 680)
                }
            }
        }
    }

    private static func logFileTests(_ t: AppTestRunner) {
        t.suite("App: Debug: stopped log deletion and restart") {
            let originalDirectory = Log.directory
            let originalEnabled = Log.fileLoggingEnabled
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DesksetDebugLog-\(UUID().uuidString)")
            defer {
                Log.fileLoggingEnabled = false; Log.directory = originalDirectory
                Log.fileLoggingEnabled = originalEnabled
                try? FileManager.default.removeItem(at: directory)
            }
            Log.directory = directory
            Log.fileLoggingEnabled = true
            Log.write("Before stop"); Log.flush()
            t.check(FileManager.default.fileExists(atPath: Log.fileURL.path))
            try Log.deleteFile()
            t.check(!FileManager.default.fileExists(atPath: Log.fileURL.path), "deleting the file stops active logging")
            t.check(!Log.fileLoggingEnabled)
            Log.fileLoggingEnabled = true
            Log.write("Before stop"); Log.flush()
            Log.fileLoggingEnabled = false
            Log.write("Memory only"); Log.flush()
            t.check(!(try String(contentsOf: Log.fileURL, encoding: .utf8)).contains("Memory only"))
            try Log.deleteFile()
            t.check(!FileManager.default.fileExists(atPath: Log.fileURL.path))
            Log.fileLoggingEnabled = true
            Log.write("After restart"); Log.flush()
            let contents = try String(contentsOf: Log.fileURL, encoding: .utf8)
            t.check(contents.contains("After restart") && !contents.contains("Before stop"))
        }
    }
}
