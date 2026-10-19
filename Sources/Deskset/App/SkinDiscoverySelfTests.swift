import AppKit
import DesksetCore

/// Changes a temporary Skins folder as an external file manager would, then uses actual application entry points.
enum SkinDiscoverySelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: skin discovery: additions, deletions and renames preserve running instances") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
            skin.pauseUpdates()
            t.check(!app.discoverSkins(), "the cached library already matches the disk")
            let runtime = skin.runtime
            let updates = runtime.snapshot.updateCount
            let saved = skin.state
            var notices = 0
            let token = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged, object: app,
                                                               queue: nil) { _ in notices += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            let added = try write(app, config: "External\\Clock", file: "A.ini")
            let variant = try write(app, config: skin.config, file: "External.ini")
            t.check(app.discoverSkins())
            t.equal(notices, 1)
            t.check(app.library.contains { $0.name == "External\\Clock" && $0.files == ["A.ini"] })
            t.check(app.library.first { $0.name == skin.config }?.files.contains("External.ini") == true)
            t.check(!app.discoverSkins())
            t.equal(notices, 1, "an unchanged list does not notify Manage")
            try "[Rainmeter]\nUpdate=-1\n[Meter]\nMeter=String\nText=changed\n"
                .write(to: added, atomically: true, encoding: .utf8)
            t.check(!app.discoverSkins(), "content edits do not change the installed skin list")
            t.equal(notices, 1)
            let renamed = added.deletingLastPathComponent().appendingPathComponent("Renamed.ini")
            try FileManager.default.moveItem(at: added, to: renamed)
            try FileManager.default.removeItem(at: variant)
            t.check(app.discoverSkins())
            t.equal(notices, 2)
            t.equal(app.library.first { $0.name == "External\\Clock" }?.files, ["Renamed.ini"])
            t.check(app.library.first { $0.name == skin.config }?.files.contains("External.ini") == false)
            try FileManager.default.removeItem(at: renamed.deletingLastPathComponent())
            t.check(app.discoverSkins())
            t.equal(notices, 3)
            t.check(!app.library.contains { $0.name == "External\\Clock" })
            t.check(app.controller(for: skin.config)?.runtime === runtime && !skin.isStopped)
            t.equal(runtime.snapshot.updateCount, updates, "list discovery does not refresh the loaded skin")
            t.equal(skin.state, saved)
        }

        t.suite("App: skin discovery: main and skin menus discover external files") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
            skin.pauseUpdates()
            let runtime = skin.runtime
            try write(app, config: "External\\Calendar", file: "Calendar.ini")
            let main = NSMenu()
            app.buildMainMenu(main)
            t.check(hasChoice(main.item(withTitle: "Skins")?.submenu,
                              config: "External\\Calendar", file: "Calendar.ini"),
                    "opening the main menu discovers a new folder")
            let newFile = try write(app, config: skin.config, file: "External.ini")
            let context = app.skinMenu(for: skin, includeCustomItems: true)
            t.check(context.item(withTitle: "Variants")?.submenu?.item(withTitle: "External.ini") != nil,
                    "opening a skin menu discovers a new variant")
            try FileManager.default.removeItem(at: newFile)
            let removed = app.skinMenu(for: skin, includeCustomItems: true)
            t.equal(removed.item(withTitle: "Variants")?.submenu?.item(withTitle: "External.ini"), nil)
            t.check(app.controller(for: skin.config)?.runtime === runtime && !skin.isStopped)
        }

        t.suite("App: skin discovery: opening Manage updates an existing outline") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
            skin.pauseUpdates()
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: skin.config, file: skin.file)
            let added = try write(app, config: "External\\Manage", file: "New.ini")
            app.showManageWindow(selecting: "External\\Manage", file: "New.ini")
            manage.select(config: "External\\Manage", file: "New.ini")
            t.check(manage.testRowLabel(config: "External\\Manage", file: "New.ini") != nil,
                    "the existing outline receives the newly discovered file")
            t.equal(manage.testLoadButtonTitle, "Load")
            let renamed = added.deletingLastPathComponent().appendingPathComponent("Renamed.ini")
            try FileManager.default.moveItem(at: added, to: renamed)
            app.showManageWindow(selecting: "External\\Manage", file: "Renamed.ini")
            manage.select(config: "External\\Manage", file: "Renamed.ini")
            t.check(manage.testRowLabel(config: "External\\Manage", file: "Renamed.ini") != nil)
            t.equal(manage.testRowLabel(config: "External\\Manage", file: "New.ini"), nil)
            t.check(app.controller(for: skin.config) === skin && !skin.isStopped)
        }

        t.suite("App: skin discovery: same-turn activation finds new variants and configs") {
            guard let app = try AppSelfTest.makeApp(t),
                  let peer = app.activate(config: "App\\Counter", file: nil),
                  let old = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
            peer.pauseUpdates()
            old.pauseUpdates()
            try write(app, config: old.config, file: "Added.ini")
            guard let added = app.activate(config: old.config, file: "Added.ini") else {
                return t.check(false, "an existing config's new file loads")
            }
            t.equal(added.file, "Added.ini", "activation must not fall back to the cached earlier variant")
            t.check(old.isStopped)
            added.pauseUpdates()
            try write(app, config: "External\\Activate", file: "New.ini")
            t.equal(app.activate(config: "External\\Activate", file: "New.ini")?.file, "New.ini")
            try write(app, config: old.config, file: "Bang.ini")
            app.activateFromBang(config: old.config, file: "Bang.ini", sender: peer.config)
            t.equal(app.controller(for: old.config)?.file, "Bang.ini")
            try write(app, config: "External\\Bang", file: "Bang.ini")
            app.activateFromBang(config: "External\\Bang", file: "Bang.ini", sender: peer.config)
            t.equal(app.controller(for: "External\\Bang")?.file, "Bang.ini")
            t.check(app.controller(for: peer.config) === peer && !peer.isStopped,
                    "discovering targets does not replace other running skins")
        }

        t.suite("App: skin discovery: OnRefresh creates and activates a new variant") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let source = try write(app, config: "External\\Generated", file: "A.ini")
            let generated = source.deletingLastPathComponent().appendingPathComponent("B.ini")
            try """
            function Create()
              local file = assert(io.open(SKIN:MakePathAbsolute('B.ini'), 'w'))
              file:write('[Rainmeter]\\nUpdate=-1\\n[Meter]\\nMeter=String\\nText=generated\\n')
              file:close()
            end
            """.write(to: source.deletingLastPathComponent().appendingPathComponent("Generate.lua"),
                      atomically: true, encoding: .utf8)
            try """
            [Rainmeter]
            Update=-1
            OnRefreshAction=[!CommandMeasure Generator "Create()"][!ActivateConfig "External\\Generated" "B.ini"]
            [Generator]
            Measure=Script
            ScriptFile=#CURRENTPATH#Generate.lua
            [Meter]
            Meter=String
            Text=generator
            """.write(to: source, atomically: true, encoding: .utf8)
            guard let writer = app.activate(config: "External\\Generated", file: "A.ini") else {
                return t.check(false, "the generating variant loads")
            }
            t.check(FileManager.default.fileExists(atPath: generated.path), "OnRefresh creates the variant")
            t.check(AppSelfTest.spin { app.controller(for: writer.config)?.file == "B.ini" },
                    "the queued activation discovers the file written by OnRefresh")
            t.equal(app.controller(for: writer.config)?.fileURL, generated)
            t.check(writer.isStopped)
        }

        t.suite("App: skin discovery: 300-config scans and menu construction report their cost") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            _ = app.library
            for index in 0..<300 {
                try write(app, config: String(format: "Bulk\\Skin%03d", index), file: "A.ini")
            }
            let scanStart = ProcessInfo.processInfo.systemUptime
            let scanned = SkinLibrary.scan(app.skinsDirectory)
            let scanMilliseconds = (ProcessInfo.processInfo.systemUptime - scanStart) * 1000
            t.equal(scanned.filter { $0.name.hasPrefix("Bulk\\") }.count, 300)
            var discoveryMilliseconds: [Double] = []
            for index in 0..<3 {
                let start = ProcessInfo.processInfo.systemUptime
                let changed = app.discoverSkins()
                discoveryMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                t.equal(changed, index == 0, "only the initial list replacement reports a change")
            }
            let menuStart = ProcessInfo.processInfo.systemUptime
            let menu = NSMenu()
            app.buildMainMenu(menu)
            let menuMilliseconds = (ProcessInfo.processInfo.systemUptime - menuStart) * 1000
            t.equal(choiceCount(menu.item(withTitle: "Skins")?.submenu, configPrefix: "Bulk\\"), 300)
            t.check(hasChoice(menu.item(withTitle: "Skins")?.submenu, config: "Bulk\\Skin000", file: "A.ini"))
            t.check(hasChoice(menu.item(withTitle: "Skins")?.submenu, config: "Bulk\\Skin299", file: "A.ini"))
            let repeated = discoveryMilliseconds.map { String(format: "%.2f", $0) }.joined(separator: ", ")
            print(String(format: "    300-config library: scan %.2f ms, discover [", scanMilliseconds)
                  + repeated + String(format: "] ms, menu %.2f ms", menuMilliseconds))
        }
    }

    @discardableResult
    private static func write(_ app: AppController, config: String, file: String) throws -> URL {
        let directory = SkinLibrary.directory(for: config, root: app.skinsDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file)
        try "[Rainmeter]\nUpdate=-1\n[Meter]\nMeter=String\nText=discovery\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func hasChoice(_ menu: NSMenu?, config: String, file: String) -> Bool {
        menu?.items.contains {
            ($0.representedObject as? [String]) == [config, file] || hasChoice($0.submenu, config: config, file: file)
        } == true
    }

    private static func choiceCount(_ menu: NSMenu?, configPrefix: String) -> Int {
        menu?.items.reduce(0) { count, item in
            let target = item.representedObject as? [String]
            let isChoice = target?.count == 2 && target?.first?.hasPrefix(configPrefix) == true
            return count + (isChoice ? 1 : 0) + choiceCount(item.submenu, configPrefix: configPrefix)
        } ?? 0
    }
}
