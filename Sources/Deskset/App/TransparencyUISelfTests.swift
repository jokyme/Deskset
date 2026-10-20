import AppKit
import DesksetCore

enum TransparencyUISelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: transparency UI: shared choices preserve the almost transparent endpoint") {
            let titles = ["0%", "10%", "20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%", "~100%"]
            let alphas = [255, 230, 204, 179, 153, 128, 102, 77, 51, 26, 1]
            t.equal(ManageModel.transparencyChoices.map(\.title), titles)
            t.equal(ManageModel.transparencyChoices.map(\.alpha), alphas)
            for (index, alpha) in alphas.enumerated() {
                t.equal(ManageModel.transparencyChoiceIndex(forAlpha: alpha), index, "AlphaValue \(alpha)")
            }
            for (alpha, index): (Int, Int?) in [(0, nil), (1, 10), (2, nil), (25, 9), (26, 9), (200, nil), (254, 0)] {
                t.equal(ManageModel.transparencyChoiceIndex(forAlpha: alpha), index, "custom AlphaValue \(alpha)")
            }
            t.equal(ManageModel.alpha(forTransparencyPercent: 100), 0, "generic 100% remains fully transparent")
        }

        t.suite("App: transparency UI: Manage choices apply exact alpha and end a fade override") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            guard let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else {
                return t.check(false, "skin fixture loads")
            }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: skin.config, file: skin.file)
            let popup = manage.testTransparencyPopup
            t.check(popup.isEnabled)
            t.equal(popup.itemTitles, ManageModel.transparencyChoices.map(\.title))
            t.equal(popup.itemArray.map(\.tag), ManageModel.transparencyChoices.map(\.alpha))
            for (index, choice) in ManageModel.transparencyChoices.enumerated() {
                skin.fadeWindow(from: 70, to: 80)
                t.check(skin.fadedAlpha != nil)
                popup.selectItem(at: index)
                t.check(popup.sendAction(popup.action, to: popup.target), "Manage dispatches \(choice.title)")
                t.equal(skin.state.alphaValue, choice.alpha, choice.title)
                t.check(skin.fadedAlpha == nil, "\(choice.title) ends a FadeWindow override")
                t.equal(popup.indexOfSelectedItem, index)
            }
            manage.select(config: "App\\Controls", file: "Controls.ini")
            t.check(!popup.isEnabled, "an unloaded config cannot change transparency")
        }

        t.suite("App: transparency UI: custom alpha clears stale choices and unrelated changes preserve it") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            guard let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else {
                return t.check(false, "skin fixture loads")
            }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: skin.config, file: skin.file)
            let popup = manage.testTransparencyPopup
            for alpha in [0, 1, 2, 25, 26, 200, 254] {
                popup.selectItem(at: 5)
                app.changeSettings(of: skin) { $0.alphaValue = alpha }
                manage.select(config: skin.config, file: skin.file)
                t.equal(popup.indexOfSelectedItem, ManageModel.transparencyChoiceIndex(forAlpha: alpha) ?? -1,
                        "custom AlphaValue \(alpha) does not retain a stale selection")
                t.equal(skin.state.alphaValue, alpha, "displaying a value does not normalize it")
                let description = "Transparency: \(ManageModel.transparencyPercent(forAlpha: alpha))%"
                t.equal(popup.toolTip, description)
                t.equal(popup.accessibilityHelp(), description)
                skin.fadeWindow(from: 70, to: 80)
                let draggable = skin.state.draggable
                manage.testDraggableBox.performClick(nil)
                t.equal(skin.state.draggable, !draggable)
                t.equal(skin.state.alphaValue, alpha, "unrelated controls preserve AlphaValue \(alpha)")
                t.equal(skin.fadedAlpha?.value, 80, "unrelated controls retain the fade override")
            }
            app.changeSettings(of: skin) { $0.alphaValue = 200 }
            manage.select(config: skin.config, file: skin.file)
            skin.fadeWindow(from: 70, to: 80)
            t.equal(popup.indexOfSelectedItem, -1)
            t.check(popup.sendAction(popup.action, to: popup.target))
            t.equal(skin.state.alphaValue, 200, "an unselected popup cannot write a preset")
            t.equal(skin.fadedAlpha?.value, 80, "an unselected popup cannot clear a fade override")
        }

        t.suite("App: transparency UI: skin menus share choices and preserve custom selections") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            guard let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else {
                return t.check(false, "skin fixture loads")
            }
            guard let firstMenu = menu(app, skin) else { return t.check(false, "transparency menu exists") }
            t.equal(firstMenu.items.map(\.title), ManageModel.transparencyChoices.map(\.title))
            t.equal(firstMenu.items.compactMap { ($0.representedObject as? [String])?.last }.compactMap(Int.init),
                    ManageModel.transparencyChoices.map(\.alpha))
            for choice in ManageModel.transparencyChoices {
                perform(menu(app, skin)?.item(withTitle: choice.title), t)
                t.equal(skin.state.alphaValue, choice.alpha, choice.title)
                t.equal(checked(menu(app, skin)), [choice.title])
            }
            for alpha in [0, 1, 2, 25, 26, 200, 254] {
                app.changeSettings(of: skin) { $0.alphaValue = alpha }
                let expected = ManageModel.transparencyChoiceIndex(forAlpha: alpha)
                    .map { [ManageModel.transparencyChoices[$0].title] } ?? []
                t.equal(checked(menu(app, skin)), expected, "custom AlphaValue \(alpha)")
                t.equal(skin.state.alphaValue, alpha, "building the menu preserves the stored value")
            }
        }

        t.suite("App: transparency UI: mixed raw alpha stays unchecked and group endpoint ends both fades") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            guard let first = app.activate(config: "App\\Focus", file: "Compact.ini"),
                  let second = app.activate(config: "App\\Controls", file: "Controls.ini"),
                  let other = app.activate(config: "App\\Counter", file: "Counter.ini") else {
                return t.check(false, "three skin fixtures load")
            }
            app.changeSettings(of: other) { $0.alphaValue = 200 }
            app.skinSelection.toggle(first)
            app.skinSelection.toggle(second)
            for pair in [(0, 1), (1, 2), (25, 26)] {
                app.changeSettings(of: first) { $0.alphaValue = pair.0 }
                app.changeSettings(of: second) { $0.alphaValue = pair.1 }
                t.equal(checked(menu(app, first)), [], "mixed AlphaValue \(pair.0)/\(pair.1)")
            }
            for skin in [first, second] {
                app.changeSettings(of: skin) { $0.alphaValue = 1 }
                skin.fadeWindow(from: 70, to: 80)
            }
            t.equal(checked(menu(app, first)), ["~100%"])
            perform(menu(app, first)?.item(withTitle: "~100%"), t)
            for skin in [first, second] {
                t.equal(skin.state.alphaValue, 1)
                t.check(skin.fadedAlpha == nil, "reselecting the endpoint ends \(skin.config)'s fade override")
            }
            t.equal(other.state.alphaValue, 200, "group transparency preserves unselected skins")
        }

        t.suite("App: transparency UI: Manage popup is reachable at minimum size in both appearances") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            guard let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else {
                return t.check(false, "skin fixture loads")
            }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: skin.config, file: skin.file)
            guard let window = manage.window, let content = window.contentView,
                  let document = manage.testDetailDocument, let scroll = document.enclosingScrollView else {
                return t.check(false, "Manage has a window and scrollable details")
            }
            let popup = manage.testTransparencyPopup
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                content.layoutSubtreeIfNeeded()
                popup.scrollToVisible(popup.bounds)
                content.layoutSubtreeIfNeeded()
                let frame = popup.convert(popup.bounds, to: scroll.contentView)
                t.check(frame.width > 0 && frame.height > 0 && scroll.contentView.bounds.contains(frame),
                        "\(appearance.rawValue): transparency is fully reachable")
                let titleWidth = ("~100%" as NSString).size(withAttributes: [
                    .font: popup.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                ]).width
                t.check(popup.bounds.width >= titleWidth + 24, "the longest choice and popup arrow fit")
            }
        }
    }

    private static func menu(_ app: AppController, _ skin: SkinWindowController) -> NSMenu? {
        app.skinMenu(for: skin, includeCustomItems: true).item(withTitle: "Settings")?.submenu?
            .item(withTitle: "Transparency")?.submenu
    }

    private static func checked(_ menu: NSMenu?) -> [String] {
        menu?.items.filter { $0.state == .on }.map(\.title) ?? []
    }

    private static func perform(_ item: NSMenuItem?, _ t: AppTestRunner) {
        guard let item, let action = item.action else { return t.check(false, "menu action exists") }
        t.check(NSApp.sendAction(action, to: item.target, from: item), "menu action dispatches")
    }
}
