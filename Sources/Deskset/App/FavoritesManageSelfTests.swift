import AppKit
import DesksetCore

/// Exercises Favorite through the same Manage checkbox used by a person.
enum FavoritesManageSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Favorites Manage: checkbox changes the selected skin") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: skin.config, file: skin.file)
            let favorite = manage.testFavoriteBox
            t.equal(favorite.title, "Favorite")
            t.check(favorite.isEnabled)
            t.equal(favorite.state, .off)
            favorite.performClick(nil)
            t.check(app.isFavorite(config: skin.config, file: skin.file))
            t.equal(favorite.state, .on)
            t.check(app.controller(for: skin.config) === skin, "changing Favorite does not reload the skin")
            favorite.performClick(nil)
            t.check(!app.isFavorite(config: skin.config, file: skin.file))
            t.equal(favorite.state, .off)
            t.check(app.controller(for: skin.config) === skin)

            app.setFavorite(true, config: skin.config, file: skin.file)
            t.check(AppSelfTest.spin { favorite.state == .on }, "Manage follows changes from other entry points")
            app.setFavorite(false, config: skin.config, file: skin.file)
            t.check(AppSelfTest.spin { favorite.state == .off })

            app.deactivate(config: skin.config)
            t.check(AppSelfTest.spin { !favorite.isEnabled }, "unloading elsewhere disables Favorite")
            favorite.performClick(nil)
            t.check(!app.isFavorite(config: skin.config, file: skin.file))
            guard app.activate(config: skin.config, file: skin.file) != nil else {
                return t.check(false, "skin reloads for selection checks")
            }
            t.check(AppSelfTest.spin { favorite.isEnabled }, "loading elsewhere enables the selected skin")
            manage.select(config: skin.config, file: "Compact.ini")
            t.check(!favorite.isEnabled, "another variant is not the selected running skin")
            manage.select(config: "App\\Controls", file: "Controls.ini")
            t.check(!favorite.isEnabled, "an unloaded skin cannot change Favorite")
            t.equal(favorite.state, .off)
            manage.select(config: "App", file: nil)
            t.check(!favorite.isEnabled, "a parent folder is not a skin")
            t.equal(favorite.state, .off)
            favorite.performClick(nil)
            t.check(!app.isFavorite(config: skin.config, file: skin.file),
                    "a disabled folder checkbox cannot change the last selected skin")
        }

        t.suite("App: Favorites Manage: checkbox remains reachable at minimum size") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: skin.config, file: skin.file)
            guard let window = manage.window, let content = window.contentView,
                  let document = manage.testDetailDocument, let scroll = document.enclosingScrollView,
                  let footer = button(titled: "Install Skin…", in: content)?.superview else {
                return t.check(false, "Manage details and footer")
            }
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                let favorite = manage.testFavoriteBox
                content.layoutSubtreeIfNeeded()
                favorite.scrollToVisible(favorite.bounds)
                content.layoutSubtreeIfNeeded()
                let visibleRect = favorite.convert(favorite.bounds, to: scroll.contentView)
                let contentRect = favorite.convert(favorite.bounds, to: content)
                let footerRect = footer.convert(footer.bounds, to: content)
                t.check(visibleRect.width > 0 && visibleRect.height > 0
                        && scroll.contentView.bounds.contains(visibleRect),
                        "\(appearance.rawValue): the complete Favorite checkbox is reachable")
                t.check(content.bounds.contains(contentRect) && !contentRect.intersects(footerRect),
                        "\(appearance.rawValue): Favorite does not overlap the footer")
                t.check(manage.snapshot() != nil, "\(appearance.rawValue): Manage renders with Favorite")
            }
        }

        t.suite("App: Favorites Manage: entering the skin list discovers new variants") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: skin.config, file: skin.file)
            let directory = SkinLibrary.directory(for: skin.config, root: app.skinsDirectory)
            func add(_ name: String) throws {
                try "[Rainmeter]\nUpdate=-1\n[Meter]\nMeter=String\nText=New variant\n"
                    .write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                t.equal(manage.testRowLabel(config: skin.config, file: name), nil,
                        "the cached outline has not discovered \(name) yet")
            }
            func check(_ name: String) {
                t.check(manage.testRowLabel(config: skin.config, file: name) != nil,
                        "the outline discovers \(name)")
                t.equal(manage.selection?.config, skin.config)
                t.equal(manage.selection?.file, skin.file, "discovery preserves the selected variant")
                t.check(app.controller(for: skin.config) === skin, "discovery does not refresh a running skin")
            }

            try add("A Focus.ini")
            manage.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: manage.window))
            check("A Focus.ini")

            manage.selectTab(.layouts)
            try add("B Focus.ini")
            manage.selectTab(.skins)
            check("B Focus.ini")

            try add("C Focus.ini")
            manage.selectTab(.skins)
            check("C Focus.ini")

            try add("D Focus.ini")
            t.check(manage.testContextMenuTitles(config: skin.config, file: skin.file).contains("Unload"),
                    "discovering files preserves the requested context menu target")
            check("D Focus.ini")
        }
    }

    private static func button(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(titled: title, in: $0) }.first
    }
}
