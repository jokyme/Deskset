import AppKit
import DesksetCore

/// Exercises the actual controls and menus with temporary app state and original test skins.
enum SkinZoomUISelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: skin zoom UI: menu defaults, presets, custom values and force") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Compact.ini"),
                  let initial = zoomMenu(app, skin) else { return t.check(false, "zoom menu") }
            let outer = app.skinMenu(for: skin, includeCustomItems: true)
            t.equal(outer.items.filter { ["Zoom", "Position", "Transparency"].contains($0.title) }.map(\.title),
                    ["Zoom", "Position", "Transparency"], "Zoom is beside the existing top-level settings")
            t.equal(outer.item(withTitle: "Settings"), nil, "Zoom has no extra Settings wrapper")
            let presets = ["80%", "90%", "100%", "110%", "120%", "130%", "140%", "150%"]
            t.equal(initial.items.map { $0.isSeparatorItem ? "separator" : $0.title },
                    ["Default", "separator"] + presets)
            t.equal(checked(initial), ["Default"], "no override is distinct from explicit 100%")

            app.setDefaultZoom(percent: 125, force: nil)
            t.check(AppSelfTest.spin { skin.effectiveZoomFactor == 1.25 })
            guard let inherited = zoomMenu(app, skin) else { return }
            t.equal(checked(inherited), ["Default"])
            t.equal(inherited.items.map(\.title).filter { $0 == "125%" }, [],
                    "a custom global default is not inserted as a per-skin override")
            perform(inherited.item(withTitle: "100%"))
            t.check(AppSelfTest.spin { skin.zoomOverridePercent == 100 && skin.effectiveZoomFactor == 1 })
            t.equal(checked(zoomMenu(app, skin)), ["100%"])
            perform(zoomMenu(app, skin)?.item(withTitle: "Default"))
            t.check(AppSelfTest.spin { skin.zoomOverridePercent == nil && skin.effectiveZoomFactor == 1.25 })

            app.setSkinZoom(config: skin.config, percent: 125)
            t.check(AppSelfTest.spin { skin.zoomOverridePercent == 125 })
            guard let custom = zoomMenu(app, skin), let entry = custom.item(withTitle: "125%") else {
                return t.check(false, "custom zoom")
            }
            t.equal(custom.items.filter { !$0.isSeparatorItem }.map(\.title),
                    ["Default", "80%", "90%", "100%", "110%", "120%", "125%", "130%", "140%", "150%"])
            t.equal(checked(custom), ["125%"])
            t.check(entry.isEnabled && entry.action == nil, "the current custom value is an enabled no-op")
            app.setDefaultZoom(percent: 130, force: true)
            t.check(AppSelfTest.spin { skin.effectiveZoomFactor == 1.3 })
            let forced = app.skinMenu(for: skin, includeCustomItems: true)
            forced.update()
            let zoom = forced.item(withTitle: "Zoom")
            t.equal(zoom?.isEnabled, false, "Force disables the entire Zoom submenu")
            t.equal(skin.zoomOverridePercent, 125, "forcing a default retains the personal override")
            app.setDefaultZoom(percent: nil, force: false)
            t.check(AppSelfTest.spin { skin.effectiveZoomFactor == 1.25 })
        }

        t.suite("App: skin zoom UI: Manage input and stepping") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: skin.config, file: skin.file)
            let field = manage.testZoomField
            let stepper = manage.testZoomStepper
            t.check(field.isEnabled && stepper.isEnabled)
            t.equal(field.integerValue, 100)
            field.stringValue = "125"
            perform(field)
            t.check(AppSelfTest.spin {
                skin.zoomOverridePercent == 125 && field.integerValue == 125 && stepper.integerValue == 125
            }, "the coalesced settings notification updates both controls")
            stepper.integerValue = 126
            perform(stepper)
            t.check(AppSelfTest.spin { skin.zoomOverridePercent == 126 && field.integerValue == 126 })
            stepper.useIncrement(for: .control)
            t.equal(stepper.increment, 10)
            stepper.useIncrement(for: [])
            t.equal(stepper.increment, 1)
            t.equal(stepper.minValue, 10)
            t.equal(stepper.maxValue, 500)
            t.check(!stepper.valueWraps)
            t.equal((field.formatter as? NumberFormatter)?.number(from: "999")?.intValue, 999,
                    "the field editor accepts an integer before the commit action clamps it")
            field.stringValue = "999"
            perform(field)
            t.check(AppSelfTest.spin { skin.zoomOverridePercent == 500 && field.integerValue == 500 })
            field.stringValue = "0"
            perform(field)
            t.check(AppSelfTest.spin { skin.zoomOverridePercent == 10 && field.integerValue == 10 })
            field.stringValue = "invalid"
            perform(field)
            t.equal(field.integerValue, 10, "invalid input restores the current zoom")
            app.setDefaultZoom(percent: 140, force: true)
            t.check(AppSelfTest.spin { field.integerValue == 140 })
            t.check(!field.isEnabled && !stepper.isEnabled)
            app.setDefaultZoom(percent: nil, force: false)
            t.check(AppSelfTest.spin { field.integerValue == 10 })
            t.check(field.isEnabled && stepper.isEnabled)
            manage.select(config: "App\\Controls", file: "Controls.ini")
            t.check(!field.isEnabled && !stepper.isEnabled, "unloaded configs cannot edit zoom in Manage")
        }

        t.suite("App: skin zoom UI: Manage controls remain reachable at minimum size") {
            guard let app = try AppSelfTest.makeApp(t),
                  let skin = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: skin.config, file: skin.file)
            guard let window = manage.window, let content = window.contentView,
                  let document = manage.testDetailDocument, let scroll = document.enclosingScrollView,
                  let lastSetting = button(titled: "Save position", in: document),
                  let footer = button(titled: "Install Skin…", in: content)?.superview else {
                return t.check(false, "Manage detail scroll and footer")
            }
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                content.layoutSubtreeIfNeeded()
                let footerRect = footer.convert(footer.bounds, to: content)
                for control in [manage.testZoomField, manage.testZoomStepper, lastSetting] as [NSView] {
                    control.scrollToVisible(control.bounds)
                    content.layoutSubtreeIfNeeded()
                    let visibleRect = control.convert(control.bounds, to: scroll.contentView)
                    let contentRect = control.convert(control.bounds, to: content)
                    t.check(visibleRect.width > 0 && visibleRect.height > 0
                            && scroll.contentView.bounds.contains(visibleRect),
                            "\(appearance.rawValue): the scrolled control is fully visible")
                    t.check(content.bounds.contains(contentRect) && !contentRect.intersects(footerRect),
                            "\(appearance.rawValue): the footer does not cover the scrolled control")
                }
            }
        }

        t.suite("App: skin zoom UI: General settings update inherited and forced zoom") {
            guard let app = try AppSelfTest.makeApp(t),
                  let inherited = app.activate(config: "App\\Focus", file: "Compact.ini"),
                  let overridden = app.activate(config: "App\\Controls", file: "Controls.ini") else { return }
            app.setSkinZoom(config: overridden.config, percent: 80)
            t.check(AppSelfTest.spin { overridden.zoomOverridePercent == 80 })
            CodeEditorRoutingSelfTests.withFakes(CodeEditorRoutingSelfTests.FakeLocator(),
                                                 CodeEditorRoutingSelfTests.RecordingOpener()) {
                let settings = SettingsWindowController(app: app)
                let manage = ManageWindowController(app: app)
                defer { settings.close(); manage.close() }
                settings.select(.general)
                manage.select(config: inherited.config, file: inherited.file)
                settings.defaultZoomField.stringValue = "120"
                perform(settings.defaultZoomField)
                t.check(AppSelfTest.spin { inherited.effectiveZoomFactor == 1.2 && manage.testZoomField.integerValue == 120 })
                t.equal(app.state.defaultZoomPercent, 120)
                t.equal(settings.defaultZoomStepper.integerValue, 120)
                t.equal(overridden.effectiveZoomFactor, 0.8)
                t.equal(inherited.zoomOverridePercent, nil, "changing the global default does not create overrides")
                settings.forceZoomBox.performClick(nil)
                t.check(AppSelfTest.spin { overridden.effectiveZoomFactor == 1.2 })
                t.check(app.state.forceDefaultZoom && !manage.testZoomField.isEnabled)
                t.equal(overridden.zoomOverridePercent, 80)
                settings.defaultZoomStepper.integerValue = 130
                perform(settings.defaultZoomStepper)
                t.check(AppSelfTest.spin { inherited.effectiveZoomFactor == 1.3 && overridden.effectiveZoomFactor == 1.3 })
                settings.forceZoomBox.performClick(nil)
                t.check(AppSelfTest.spin { overridden.effectiveZoomFactor == 0.8 })
                t.equal(inherited.effectiveZoomFactor, 1.3)
                app.setDefaultZoom(percent: 110, force: nil)
                t.equal(settings.defaultZoomField.integerValue, 110, "the open Settings page follows other entry points")
                settings.defaultZoomField.stringValue = "not a number"
                perform(settings.defaultZoomField)
                t.equal(settings.defaultZoomField.integerValue, 110)
                t.equal(app.state.defaultZoomPercent, 110)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    settings.window?.appearance = NSAppearance(named: appearance)
                    t.check(settings.snapshot() != nil, "\(appearance.rawValue): General renders with zoom controls")
                }
            }
        }

        t.suite("App: skin zoom UI: selected skins share zoom commands and menu states") {
            guard let app = try AppSelfTest.makeApp(t),
                  let first = app.activate(config: "App\\Focus", file: "Compact.ini"),
                  let second = app.activate(config: "App\\Controls", file: "Controls.ini") else { return }
            app.setDefaultZoom(percent: 125, force: nil)
            app.setSkinZoom(config: second.config, percent: 125)
            t.check(AppSelfTest.spin { first.effectiveZoomFactor == 1.25 && second.zoomOverridePercent == 125 })
            app.skinSelection.toggle(first)
            app.skinSelection.toggle(second)
            t.equal(checked(zoomMenu(app, first)), ["125%"],
                    "mixed default and explicit values check their common effective percentage")
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.select(config: first.config, file: first.file)
            t.check(!manage.testDraggableBox.isEnabled && !manage.testClickThroughBox.isEnabled
                    && !manage.testKeepOnScreenBox.isEnabled)
            perform(zoomMenu(app, first)?.item(withTitle: "Default"))
            t.check(AppSelfTest.spin { first.zoomOverridePercent == nil && second.zoomOverridePercent == nil })
            t.equal(checked(zoomMenu(app, first)), ["Default"])
            t.equal(zoomMenu(app, first)?.item(withTitle: "125%"), nil)
            perform(zoomMenu(app, first)?.item(withTitle: "140%"))
            t.check(AppSelfTest.spin { first.zoomOverridePercent == 140 && second.zoomOverridePercent == 140 })
            t.equal(checked(zoomMenu(app, second)), ["140%"])
            second.requestZoom(percent: 110)
            t.check(AppSelfTest.spin { second.zoomOverridePercent == 110 })
            t.equal(checked(zoomMenu(app, first)), [], "different effective percentages leave every item unchecked")
            let select = app.skinMenu(for: first, includeCustomItems: true).item(withTitle: "Select skin")
            t.equal(select?.state, .on)
            perform(select)
            t.check(app.skinSelection.selectedConfigs.isEmpty, "clicking a checked Select skin clears selection")
            t.check(manage.testDraggableBox.isEnabled && manage.testClickThroughBox.isEnabled
                    && manage.testKeepOnScreenBox.isEnabled)
            perform(app.skinMenu(for: first, includeCustomItems: true).item(withTitle: "Select skin"))
            t.check(app.skinSelection.contains(first.config))
        }

        t.suite("App: skin zoom UI: selected menu refresh and unload target the captured group") {
            guard let app = try AppSelfTest.makeApp(t),
                  let first = app.activate(config: "App\\Focus", file: "Compact.ini"),
                  let second = app.activate(config: "App\\Controls", file: "Controls.ini"),
                  let other = app.activate(config: "App\\Counter", file: "Counter.ini") else { return }
            app.skinSelection.toggle(first)
            app.skinSelection.toggle(second)
            t.equal(Set(app.skinSelection.selectedConfigs), Set([first.config, second.config]))
            perform(app.skinMenu(for: first, includeCustomItems: true).item(withTitle: "Refresh Skin"))
            guard let newFirst = app.controller(for: first.config),
                  let newSecond = app.controller(for: second.config) else {
                return t.check(false, "both selected configs remain loaded after Refresh")
            }
            t.check(newFirst !== first && newSecond !== second, "Refresh replaces every selected instance")
            t.check(first.isStopped && second.isStopped)
            t.check(app.skinSelection.selectedConfigs.isEmpty, "retired instances leave the selection")
            t.check(app.controller(for: other.config) === other && !other.isStopped,
                    "Refresh preserves the unselected instance")

            app.skinSelection.toggle(newFirst)
            app.skinSelection.toggle(newSecond)
            perform(app.skinMenu(for: newSecond, includeCustomItems: true).item(withTitle: "Unload Skin"))
            t.check(app.controller(for: first.config) == nil && app.controller(for: second.config) == nil,
                    "Unload closes every selected config even as the selection changes")
            t.check(newFirst.isStopped && newSecond.isStopped)
            t.check(app.skinSelection.selectedConfigs.isEmpty)
            t.equal(app.state.skin(first.config)?.active, false)
            t.equal(app.state.skin(second.config)?.active, false)
            t.check(app.controller(for: other.config) === other && !other.isStopped,
                    "Unload preserves the unselected instance")
            t.equal(app.state.skin(other.config)?.active, true)
        }

        t.suite("App: skin zoom UI: selected menu settings show and update common values") {
            guard let app = try AppSelfTest.makeApp(t),
                  let first = app.activate(config: "App\\Focus", file: "Compact.ini"),
                  let second = app.activate(config: "App\\Controls", file: "Controls.ini") else { return }
            app.changeSettings(of: first) {
                $0.draggable = false
                $0.alphaValue = 128
                $0.alwaysOnTop = -2
                $0.onHover = 0
            }
            app.changeSettings(of: second) {
                $0.draggable = true
                $0.alphaValue = 255
                $0.alwaysOnTop = 1
                $0.onHover = 1
            }
            app.skinSelection.toggle(first)
            app.skinSelection.toggle(second)
            func menu() -> NSMenu { app.skinMenu(for: first, includeCustomItems: true) }
            t.equal(menu().item(withTitle: "Draggable")?.state, .off, "mixed flags are unchecked")
            for title in ["Transparency", "Position", "On Hover"] {
                t.equal(checked(menu().item(withTitle: title)?.submenu), [], "mixed \(title) values are unchecked")
            }
            perform(menu().item(withTitle: "Draggable"))
            t.check(first.state.draggable && second.state.draggable, "mixed flags become true together")
            t.equal(menu().item(withTitle: "Draggable")?.state, .on)
            perform(menu().item(withTitle: "Draggable"))
            t.check(!first.state.draggable && !second.state.draggable, "all true becomes false together")
            perform(menu().item(withTitle: "Transparency")?.submenu?.item(withTitle: "20%"))
            let alpha = ManageModel.alpha(forTransparencyPercent: 20)
            t.equal(first.state.alphaValue, alpha)
            t.equal(second.state.alphaValue, alpha)
            t.equal(checked(menu().item(withTitle: "Transparency")?.submenu), ["20%"])
            let position = menu().item(withTitle: "Position")?.submenu?.items.first {
                ($0.representedObject as? [String])?.last == "0"
            }
            perform(position)
            t.equal(first.state.alwaysOnTop, 0)
            t.equal(second.state.alwaysOnTop, 0)
            let hover = menu().item(withTitle: "On Hover")?.submenu?.items.first {
                ($0.representedObject as? [String])?.last == "2"
            }
            perform(hover)
            t.equal(first.state.onHover, 2)
            t.equal(second.state.onHover, 2)
            app.skinSelection.clear()
            t.check(!first.state.draggable && !second.state.draggable,
                    "deselecting preserves values edited through the group menu")
        }
    }

    private static func zoomMenu(_ app: AppController, _ skin: SkinWindowController) -> NSMenu? {
        app.skinMenu(for: skin, includeCustomItems: true).item(withTitle: "Zoom")?.submenu
    }

    private static func checked(_ menu: NSMenu?) -> [String] {
        menu?.items.filter { $0.state == .on }.map(\.title) ?? []
    }

    private static func button(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews {
            if let found = button(titled: title, in: child) { return found }
        }
        return nil
    }

    private static func perform(_ control: NSControl) {
        guard let action = control.action else { return }
        _ = control.sendAction(action, to: control.target)
    }

    private static func perform(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return }
        _ = item.target?.perform(action, with: item)
    }
}
