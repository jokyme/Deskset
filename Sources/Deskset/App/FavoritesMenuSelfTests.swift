import AppKit
import DesksetCore

/// Exercises the actual Favorite actions with original skins in a temporary library.
enum FavoritesMenuSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Favorites menus: placement, empty state and Settings action") {
            guard let (app, skin) = try fixture(t) else { return }
            let main = mainMenu(app)
            let titles = main.items.map(\.title)
            guard let index = titles.firstIndex(of: "Favorites"),
                  let favorites = main.item(withTitle: "Favorites") else {
                return t.check(false, "Favorites menu exists")
            }
            t.check(index > 0 && index + 1 < titles.count)
            if index > 0 && index + 1 < titles.count {
                t.equal(titles[index - 1], "Skins")
                t.equal(titles[index + 1], "Layouts")
            }
            t.check(!favorites.isEnabled)
            t.equal(favorites.submenu?.items.count, 0)

            let context = app.skinMenu(for: skin, includeCustomItems: true)
            guard let settings = context.item(withTitle: "Settings")?.submenu,
                  let favorite = settings.item(withTitle: "Favorite") else {
                return t.check(false, "Settings has a Favorite action")
            }
            t.equal(settings.items.last?.title, "Favorite")
            t.equal(favorite.state, .off)
            let runtime = skin.runtime
            let updates = runtime.snapshot.updateCount
            perform(favorite, t)
            t.check(app.isFavorite(config: skin.config, file: skin.file))
            t.check(app.controller(for: skin.config)?.runtime === runtime)
            t.equal(runtime.snapshot.updateCount, updates, "favoriting does not update or reload the skin")
            let marked = mainMenu(app).item(withTitle: "Favorites")
            t.check(marked?.isEnabled == true)
            t.equal(marked?.submenu?.items.map(\.title), ["Favorites\\Twin\\A.ini"])
            t.equal(marked?.submenu?.items.first?.state, .on)
            t.equal(app.skinMenu(for: skin, includeCustomItems: true).item(withTitle: "Settings")?
                .submenu?.item(withTitle: "Favorite")?.state, .on)
            let rebuilt = app.skinMenu(for: skin, includeCustomItems: true)
            t.check(rebuilt.item(withTitle: "Deskset")?.submenu?.item(withTitle: "Favorites")?.isEnabled == true)
            app.setFavorite(false, config: skin.config, file: skin.file)
            t.check(mainMenu(app).item(withTitle: "Favorites")?.isEnabled == false)
            t.check(app.controller(for: skin.config)?.runtime === runtime)
        }

        t.suite("App: Favorites menus: variants, unload, restart and loading actions") {
            guard let (app, a) = try fixture(t) else { return }
            app.setFavorite(true, config: a.config, file: a.file)
            guard let b = app.activate(config: a.config, file: "B.ini") else {
                return t.check(false, "the second variant loads")
            }
            b.pauseUpdates()
            app.setFavorite(true, config: b.config, file: b.file)
            let marked = mainMenu(app).item(withTitle: "Favorites")?.submenu
            t.equal(marked?.items.map(\.title), ["Favorites\\Twin\\A.ini", "Favorites\\Twin\\B.ini"])
            t.equal(marked?.items.map(\.state), [.off, .on])
            app.setFavorite(false, config: a.config, file: a.file)
            t.check(app.isFavorite(config: a.config, file: a.file), "an inactive variant cannot change its setting")
            t.check(app.controller(for: b.config) === b)
            app.deactivate(config: b.config)
            app.state.saveNow()
            let reopened = AppState(fileURL: app.state.fileURL)
            t.check(reopened.isFavorite(config: a.config, file: a.file))
            t.check(reopened.isFavorite(config: b.config, file: b.file))
            t.equal(reopened.skin(b.config)?.active, false)
            let unloaded = mainMenu(app).item(withTitle: "Favorites")?.submenu
            t.equal(unloaded?.items.map(\.state), [.off, .off])
            perform(unloaded?.item(withTitle: "Favorites\\Twin\\A.ini"), t)
            guard let loaded = app.controller(for: a.config) else {
                return t.check(false, "Favorites loads an unloaded skin")
            }
            t.equal(loaded.file, "A.ini")
            perform(mainMenu(app).item(withTitle: "Favorites")?.submenu?
                .item(withTitle: "Favorites\\Twin\\B.ini"), t)
            t.equal(app.controller(for: a.config)?.file, "B.ini")
            t.check(loaded.isStopped, "choosing another favorite variant replaces the old one")
            perform(mainMenu(app).item(withTitle: "Favorites")?.submenu?
                .item(withTitle: "Favorites\\Twin\\B.ini"), t)
            t.equal(app.controller(for: a.config), nil, "Favorites uses the existing skin toggle action")
            t.check(app.isFavorite(config: a.config, file: "B.ini"))
        }

        t.suite("App: Favorites menus: missing files are hidden and stale actions cannot load a fallback") {
            guard let (app, a) = try fixture(t) else { return }
            app.setFavorite(true, config: a.config, file: a.file)
            guard let b = app.activate(config: a.config, file: "B.ini") else {
                return t.check(false, "the second variant loads")
            }
            b.pauseUpdates()
            app.setFavorite(true, config: b.config, file: b.file)
            let stale = mainMenu(app).item(withTitle: "Favorites")?.submenu?
                .item(withTitle: "Favorites\\Twin\\A.ini")
            let source = try String(contentsOf: a.fileURL, encoding: .utf8)
            try FileManager.default.removeItem(at: a.fileURL)
            let filtered = mainMenu(app).item(withTitle: "Favorites")?.submenu
            t.equal(filtered?.items.map(\.title), ["Favorites\\Twin\\B.ini"])
            t.check(app.isFavorite(config: a.config, file: "A.ini"), "a missing file keeps its saved shortcut")
            perform(stale, t)
            t.check(app.controller(for: b.config) === b, "a stale favorite cannot fall back to another file")
            try source.write(to: a.fileURL, atomically: true, encoding: .utf8)
            t.equal(mainMenu(app).item(withTitle: "Favorites")?.submenu?.items.count, 2)
            try FileManager.default.removeItem(at: a.fileURL.deletingLastPathComponent())
            let missing = mainMenu(app).item(withTitle: "Favorites")
            t.check(missing?.isEnabled == false)
            t.equal(missing?.submenu?.items.count, 0)
            t.check(app.controller(for: b.config) === b && !b.isStopped,
                    "discovering deleted files does not unload their running instance")
            t.equal(app.state.favorites.count, 2)
        }
    }

    private static func fixture(_ t: AppTestRunner) throws -> (AppController, SkinWindowController)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        let folder = SkinLibrary.directory(for: "Favorites\\Twin", root: app.skinsDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["A.ini", "B.ini"] {
            try "[Rainmeter]\nUpdate=-1\n[Meter]\nMeter=String\nText=\(file)\n"
                .write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        guard let skin = app.activate(config: "Favorites\\Twin", file: "A.ini") else {
            t.check(false, "favorite fixture loads")
            return nil
        }
        skin.pauseUpdates()
        return (app, skin)
    }

    private static func mainMenu(_ app: AppController) -> NSMenu {
        let menu = NSMenu()
        app.buildMainMenu(menu)
        return menu
    }

    private static func perform(_ item: NSMenuItem?, _ t: AppTestRunner) {
        guard let item, let action = item.action else { return t.check(false, "menu action exists") }
        t.check(NSApp.sendAction(action, to: item.target, from: item), "menu action is connected")
    }
}
