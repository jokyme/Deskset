import AppKit
import DesksetCore

/// Uses the Manage controls to select loaded skins and open the shared display settings.
enum ManagePositionUISelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Manage Position UI: Active skins selects without loading or showing") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            let popup = manage.testActiveSkinsPopup
            t.equal(popup.title, "Active skins")
            t.check(!popup.isEnabled, "no loaded skins leaves the pull-down disabled")
            t.equal(popup.menu?.numberOfItems, 1)
            guard let focus = app.activate(config: "App\\Focus", file: "Compact.ini"),
                  let controls = app.activate(config: "App\\Controls", file: "Controls.ini") else {
                return t.check(false, "both skin fixtures load")
            }
            t.check(AppSelfTest.spin { popup.menu?.numberOfItems == 3 && popup.isEnabled })
            t.equal(popup.menu?.items.dropFirst().compactMap { $0.representedObject as? [String] },
                    [[controls.config, controls.file], [focus.config, focus.file]])
            t.check(popup.menu?.items.dropFirst().allSatisfy {
                ($0.representedObject as? [String])?.last != "Focus.ini"
            } == true, "unloaded variants are absent")

            focus.runtime.send(.execute("[!Hide]", section: nil))
            t.check(AppSelfTest.spin { focus.isHiddenByBang })
            let frame = focus.window.frame
            manage.select(config: controls.config, file: controls.file)
            manage.selectTab(.layouts)
            perform(choice(popup, config: focus.config, file: focus.file))
            t.equal(manage.selection?.config, focus.config)
            t.equal(manage.selection?.file, focus.file)
            t.check(manage.testRowLabel(config: focus.config, file: focus.file) != nil,
                    "the selected file's ancestors are expanded")
            t.check(app.controller(for: focus.config) === focus, "selection retains the running controller")
            t.check(focus.isHiddenByBang, "locating a hidden skin does not show it")
            t.equal(focus.window.frame, frame, "locating a skin does not move it")
            t.equal(app.controllers.count, 2, "selecting from the list does not load another skin")

            app.deactivate(config: controls.config)
            t.check(AppSelfTest.spin { popup.menu?.numberOfItems == 2 })
            app.deactivate(config: focus.config)
            t.check(AppSelfTest.spin { !popup.isEnabled && popup.menu?.numberOfItems == 1 })
        }

        t.suite("App: Manage Position UI: stale Active skins choices cannot select another variant") {
            guard let app = try AppSelfTest.makeApp(t),
                  let focus = app.activate(config: "App\\Focus", file: "Compact.ini"),
                  let controls = app.activate(config: "App\\Controls", file: "Controls.ini") else { return }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: controls.config, file: controls.file)
            guard let oldVariant = choice(manage.testActiveSkinsPopup, config: focus.config, file: focus.file) else {
                return t.check(false, "the running variant has an Active skins item")
            }
            guard let replacement = app.activate(config: focus.config, file: "Focus.ini") else {
                return t.check(false, "replacement variant loads")
            }
            perform(oldVariant)
            t.equal(manage.selection?.config, controls.config)
            t.equal(manage.selection?.file, controls.file)
            t.check(app.controller(for: focus.config) === replacement)

            manage.reload()
            guard let removedFile = choice(manage.testActiveSkinsPopup, config: replacement.config,
                                           file: replacement.file) else {
                return t.check(false, "the replacement has an Active skins item before deletion")
            }
            let file = SkinLibrary.directory(for: replacement.config, root: app.skinsDirectory)
                .appendingPathComponent(replacement.file)
            try FileManager.default.removeItem(at: file)
            perform(removedFile)
            t.equal(manage.selection?.config, controls.config,
                    "a missing running file does not fall back to another outline row")
            t.equal(manage.selection?.file, controls.file)
            t.check(app.controller(for: replacement.config) === replacement,
                    "a stale selection does not unload the running skin")
            app.deactivate(config: replacement.config)
            perform(removedFile)
            t.equal(manage.selection?.config, controls.config)
            t.check(app.controller(for: replacement.config) == nil, "a stale choice cannot reload a skin")
        }

        t.suite("App: Manage Position UI: Display monitor uses current shared choices") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            let popup = manage.testDisplayMonitorPopup
            manage.select(config: skin.config, file: skin.file)
            t.check(popup.isEnabled)
            t.equal(popup.title, "Display monitor")
            guard let menu = popup.menu else { return t.check(false, "Display monitor menu") }
            manage.menuNeedsUpdate(menu)
            let expected = app.displayMonitorMenu(for: skin, appliesToSelection: false)
            t.equal(menu.items.dropFirst().map(\.title), expected.items.map(\.title))
            t.equal(menu.items.dropFirst().map(\.state), expected.items.map(\.state))
            t.equal(menu.items.dropFirst().map(\.isEnabled), expected.items.map(\.isEnabled))
            for (actual, source) in zip(menu.items.dropFirst(), expected.items) where !source.isSeparatorItem {
                t.equal(actual.action, source.action, "Manage uses the shared menu's actual action")
                t.check(actual.target === source.target)
            }
            app.changeSettings(of: skin) {
                $0.windowX = "120@0"
                $0.windowY = "140@0"
            }
            manage.menuNeedsUpdate(menu)
            t.check(skin.state.windowX?.contains("@0") == true && skin.state.windowY?.contains("@0") == true)
            perform(menu.item(withTitle: "Use default: Primary monitor"))
            t.check(AppSelfTest.spin {
                skin.state.windowX?.contains("@") != true && skin.state.windowY?.contains("@") != true
            }, "the actual Manage menu action removes the monitor directive")
            manage.select(config: skin.config, file: "Focus.ini")
            t.check(!popup.isEnabled, "an unloaded variant cannot change the running variant's monitor")
            t.equal(popup.menu?.numberOfItems, 1)
            manage.select(config: "App\\Controls", file: "Controls.ini")
            t.check(!popup.isEnabled, "an unloaded skin has no display settings")
            manage.select(config: "App", file: nil)
            t.check(!popup.isEnabled, "a parent folder has no display settings")
            manage.select(config: skin.config, file: skin.file)
            t.check(popup.isEnabled)
            app.deactivate(config: skin.config)
            t.check(AppSelfTest.spin { !popup.isEnabled })
        }

        t.suite("App: Manage Position UI: controls remain reachable at minimum size") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
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
                content.layoutSubtreeIfNeeded()
                let active = manage.testActiveSkinsPopup
                let monitor = manage.testDisplayMonitorPopup
                let activeRect = active.convert(active.bounds, to: content)
                let footerRect = footer.convert(footer.bounds, to: content)
                t.check(activeRect.width > 0 && activeRect.height > 0 && content.bounds.contains(activeRect),
                        "\(appearance.rawValue): Active skins is fully visible")
                t.check(!activeRect.intersects(footerRect), "Active skins does not overlap the footer")
                monitor.scrollToVisible(monitor.bounds)
                content.layoutSubtreeIfNeeded()
                let visible = monitor.convert(monitor.bounds, to: scroll.contentView)
                let monitorRect = monitor.convert(monitor.bounds, to: content)
                t.check(visible.width > 0 && visible.height > 0 && scroll.contentView.bounds.contains(visible),
                        "\(appearance.rawValue): Display monitor is fully reachable")
                let titleWidth = (monitor.title as NSString).size(withAttributes: [
                    .font: monitor.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                ]).width
                t.check(monitor.bounds.width >= titleWidth + 24,
                        "\(appearance.rawValue): the Display monitor title and arrow fit")
                t.check(content.bounds.contains(monitorRect) && !monitorRect.intersects(footerRect),
                        "Display monitor does not overlap the footer")
                t.check(manage.snapshot() != nil, "\(appearance.rawValue): Manage renders both controls")
            }
        }
    }

    private static func choice(_ popup: NSPopUpButton, config: String, file: String) -> NSMenuItem? {
        popup.menu?.items.first { ($0.representedObject as? [String]) == [config, file] }
    }

    private static func perform(_ item: NSMenuItem?) {
        guard let item, item.isEnabled, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func button(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(titled: title, in: $0) }.first
    }
}
