import AppKit
import DesksetCore

enum MenuNavigationSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: menu navigation: config title opens only its captured folder") {
            guard let (app, skin) = try fixture(t),
                  let first = app.activate(config: "App\\Focus", file: "Focus.ini"),
                  let second = app.activate(config: "App\\Controls", file: "Controls.ini") else { return }
            var opened: [URL] = []
            app.openMenuURL = { opened.append($0) }
            app.skinSelection.toggle(first)
            app.skinSelection.toggle(second)
            let menu = app.skinMenu(for: skin, includeCustomItems: true)
            t.equal(menu.items.first?.title, "Suite\\Clock")
            t.equal(menu.items.dropFirst().first?.title, "Select skin")
            t.check(menu.items.first?.isEnabled == true)
            t.equal(menu.items.first?.representedObject as? [String], [skin.config])
            t.equal(app.menuFacts(for: skin).name, "Friendly clock", "metadata facts keep their existing API")
            t.check(menu.item(withTitle: "Friendly clock") == nil, "metadata does not replace ConfigName")
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: "Deskset\\Clock", file: "Clock.ini")
            app.skinSelection.clear()
            app.skinSelection.toggle(second)
            perform(menu.items.first, t)
            let expected = SkinLibrary.directory(for: skin.config, root: app.skinsDirectory)
            t.equal(opened.map(\.standardizedFileURL), [expected.standardizedFileURL])
            perform(menu.item(withTitle: "Open Skin Folder"), t)
            t.equal(opened.map(\.standardizedFileURL), [expected.standardizedFileURL, expected.standardizedFileURL])
            t.check(app.controller(for: first.config) === first && app.controller(for: second.config) === second)
            t.check(app.controller(for: skin.config) === skin, "folder navigation never refreshes a skin")
            let loadedMenu = app.skinMenu(for: skin, includeCustomItems: false)
            t.equal(loadedMenu.items.first?.title, skin.config, "loaded-skin submenus have the same clickable title")
            perform(loadedMenu.items.first, t)
            t.equal(opened.count, 3)
        }

        t.suite("App: menu navigation: stale folder actions do not open files or missing paths") {
            guard let (app, skin) = try fixture(t) else { return }
            var opened: [URL] = []
            app.openMenuURL = { opened.append($0) }
            let menu = app.skinMenu(for: skin, includeCustomItems: true)
            let folder = skin.fileURL.deletingLastPathComponent()
            try FileManager.default.removeItem(at: folder)
            perform(menu.items.first, t)
            perform(menu.item(withTitle: "Open Skin Folder"), t)
            t.equal(opened, [])
            try "a file".write(to: folder, atomically: true, encoding: .utf8)
            perform(menu.items.first, t)
            t.equal(opened, [], "a regular file at the old directory path is not opened")
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            perform(menu.items.first, t)
            t.equal(opened.map(\.standardizedFileURL), [folder.standardizedFileURL], "the captured folder need not still contain an INI")
            t.check(app.controller(for: skin.config) === skin && !skin.isStopped)
        }

        t.suite("App: menu navigation: root config keeps folder hierarchy and exact root boundaries") {
            guard let (app, skin) = try fixture(t),
                  let root = rootMenu(in: app.skinMenu(for: skin, includeCustomItems: true), named: "Suite") else {
                return t.check(false, "root menu exists")
            }
            let menu = app.skinMenu(for: skin, includeCustomItems: true)
            guard let variants = menu.items.firstIndex(where: { $0.title == "Variants" }),
                  let rootIndex = menu.items.firstIndex(where: { $0.title == "Suite" && $0.submenu != nil }),
                  let zoom = menu.items.firstIndex(where: { $0.title == "Zoom" }) else {
                return t.check(false, "Variants, root and Zoom are present")
            }
            t.check(variants < rootIndex && rootIndex < zoom)
            t.equal(root.items.map(\.title), ["Clock", "Nested", "Other", "Root.ini"])
            t.equal(root.item(withTitle: "Clock")?.submenu?.items.map(\.title), ["A.ini", "B.ini"])
            t.equal(root.item(withTitle: "Nested")?.submenu?.items.map(\.title), ["Deep"])
            t.equal(root.item(withTitle: "Nested")?.submenu?.item(withTitle: "Deep")?.submenu?.items.map(\.title), ["Deep.ini"])
            t.equal(root.item(withTitle: "Other")?.submenu?.items.map(\.title), ["Other.ini"])
            let choices = allChoices(root)
            t.equal(Set(choices.compactMap { ($0.representedObject as? [String])?.first }),
                    Set(["Suite", "Suite\\Clock", "Suite\\Nested\\Deep", "Suite\\Other"]))
            t.check(!choices.contains { ($0.representedObject as? [String])?.first?.hasPrefix("SuiteExtra") == true })
            t.equal(root.item(withTitle: "Clock")?.submenu?.item(withTitle: "A.ini")?.state, .on)
            t.equal(root.item(withTitle: "Clock")?.submenu?.item(withTitle: "B.ini")?.state, .off)
            guard let mixedCase = app.activate(config: "sUiTe\\cLoCk", file: "A.ini"),
                  let caseRoot = rootMenu(in: app.skinMenu(for: mixedCase, includeCustomItems: true), named: "Suite") else {
                return t.check(false, "case-insensitive config lookup retains its root")
            }
            t.equal(allChoices(caseRoot).count, choices.count)
        }

        t.suite("App: menu navigation: root tree works without a root-level INI") {
            guard let (app, _) = try fixture(t),
                  let skin = app.activate(config: "Branches\\Only\\Leaf", file: "Leaf.ini"),
                  let root = rootMenu(in: app.skinMenu(for: skin, includeCustomItems: true), named: "Branches") else {
                return t.check(false, "folder-only ancestors produce a root menu")
            }
            t.equal(root.items.map(\.title), ["Only"])
            t.equal(root.item(withTitle: "Only")?.submenu?.items.map(\.title), ["Leaf"])
            let leaves = allChoices(root)
            t.equal(leaves.map(\.title), ["Leaf.ini"])
            t.equal(leaves.first?.representedObject as? [String], [skin.config, skin.file])
            perform(leaves.first, t)
            t.equal(app.controller(for: skin.config)?.file, "Leaf.ini")
            t.equal(app.state.skin(skin.config)?.active, true, "choosing the current INI never unloads it")
        }

        t.suite("App: menu navigation: root activation ignores skin and Manage selections") {
            guard let (app, clicked) = try fixture(t),
                  let first = app.activate(config: "App\\Focus", file: "Focus.ini"),
                  let second = app.activate(config: "App\\Controls", file: "Controls.ini") else { return }
            app.skinSelection.toggle(first)
            app.skinSelection.toggle(second)
            let menu = app.skinMenu(for: clicked, includeCustomItems: true)
            let action = rootMenu(in: menu, named: "Suite")?.item(withTitle: "Nested")?.submenu?
                .item(withTitle: "Deep")?.submenu?.item(withTitle: "Deep.ini")
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: "Deskset\\Clock", file: "Clock.ini")
            app.skinSelection.clear()
            app.skinSelection.toggle(clicked)
            app.skinSelection.toggle(second)
            perform(action, t)
            t.equal(app.controller(for: "Suite\\Nested\\Deep")?.file, "Deep.ini")
            t.check(app.controller(for: clicked.config) === clicked)
            t.check(app.controller(for: first.config) === first && app.controller(for: second.config) === second,
                    "root navigation only activates the captured INI")
            perform(rootMenu(in: menu, named: "Suite")?.item(withTitle: "Root.ini"), t)
            t.equal(app.controller(for: "Suite")?.file, "Root.ini")
            t.check(app.controller(for: clicked.config) === clicked)
        }

        t.suite("App: menu navigation: discovered and stale root INIs never select a fallback") {
            guard let (app, first) = try fixture(t) else { return }
            let staleMenu = app.skinMenu(for: first, includeCustomItems: true)
            let staleA = rootMenu(in: staleMenu, named: "Suite")?.item(withTitle: "Clock")?
                .submenu?.item(withTitle: "A.ini")
            guard let second = app.activate(config: first.config, file: "B.ini") else {
                return t.check(false, "second variant loads")
            }
            let oldA = first.fileURL
            try FileManager.default.removeItem(at: oldA)
            perform(staleA, t)
            t.check(app.controller(for: second.config) === second && !second.isStopped,
                    "a missing captured INI does not replace the current one with a fallback")
            let newFile = second.fileURL.deletingLastPathComponent().appendingPathComponent("New.ini")
            try ini("New").write(to: newFile, atomically: true, encoding: .utf8)
            let refreshed = rootMenu(in: app.skinMenu(for: second, includeCustomItems: true), named: "Suite")
            t.equal(refreshed?.item(withTitle: "Clock")?.submenu?.items.map(\.title), ["B.ini", "New.ini"])
            let staleNew = refreshed?.item(withTitle: "Clock")?.submenu?.item(withTitle: "New.ini")
            try FileManager.default.removeItem(at: newFile.deletingLastPathComponent())
            perform(staleNew, t)
            t.check(app.controller(for: second.config) === second && !second.isStopped,
                    "a removed config cannot activate another config under the root")
            t.check(app.controller(for: "SuiteExtra\\Other") == nil)
        }

        t.suite("App: menu navigation: global Help follows About and opens the manual") {
            guard let (app, skin) = try fixture(t) else { return }
            var opened: [URL] = []
            app.openMenuURL = { opened.append($0) }
            let menu = NSMenu()
            app.buildMainMenu(menu)
            let titles = menu.items.map(\.title)
            guard let about = titles.firstIndex(of: "About Deskset"), let help = titles.firstIndex(of: "Help") else {
                return t.check(false, "About and Help are present")
            }
            t.equal(help, about + 1)
            t.equal(titles.filter { $0 == "Help" }.count, 1)
            perform(menu.item(withTitle: "Help"), t)
            t.equal(opened.map(\.absoluteString), ["https://docs.rainmeter.net/"])
            let context = app.skinMenu(for: skin, includeCustomItems: true)
            t.check(context.item(withTitle: "Help") == nil)
            t.check(context.item(withTitle: "Deskset")?.submenu?.item(withTitle: "Help") == nil,
                    "the existing skin flyout has no additional Help entry")
        }
    }

    private static func fixture(_ t: AppTestRunner) throws -> (AppController, SkinWindowController)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        let entries: [(String, [String])] = [
            ("Suite", ["Root.ini"]), ("Suite\\Clock", ["A.ini", "B.ini"]),
            ("Suite\\Nested\\Deep", ["Deep.ini"]), ("Suite\\Other", ["Other.ini"]),
            ("SuiteExtra\\Other", ["Extra.ini"]), ("Branches\\Only\\Leaf", ["Leaf.ini"]),
        ]
        for (config, files) in entries {
            let folder = SkinLibrary.directory(for: config, root: app.skinsDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                try ini(file, name: config == "Suite\\Clock" ? "Friendly clock" : config)
                    .write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
        }
        guard let skin = app.activate(config: "Suite\\Clock", file: "A.ini") else {
            t.check(false, "the original menu fixture loads")
            return nil
        }
        skin.pauseUpdates()
        return (app, skin)
    }

    private static func ini(_ text: String, name: String = "") -> String {
        "[Rainmeter]\nUpdate=-1\n[Metadata]\nName=\(name)\n[Meter]\nMeter=String\nText=\(text)\n"
    }

    private static func rootMenu(in menu: NSMenu, named name: String) -> NSMenu? {
        menu.items.first { $0.title == name && $0.submenu != nil }?.submenu
    }

    private static func allChoices(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            if let submenu = item.submenu { return allChoices(submenu) }
            return item.action == nil ? [] : [item]
        }
    }

    private static func perform(_ item: NSMenuItem?, _ t: AppTestRunner) {
        guard let item, let action = item.action else { return t.check(false, "the captured action exists") }
        t.check(NSApp.sendAction(action, to: item.target, from: item), "the menu action is connected")
    }
}
