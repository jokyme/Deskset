import AppKit
import DesksetCore

/// Application interface theme (`UITheme=0|1|2`): utility windows, menus and tooltips follow the chosen theme while
/// `NSApp.appearance` and skin windows keep following macOS appearance; Settings General keeps the reorganized sections.
enum UIThemeSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: UITheme: Settings controls, layout preservation and isolated utility appearance") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            t.atSuiteEnd { app.stopAllForTermination(); app.endEngineThread() }

            let skinFolder = app.skinsDirectory.appendingPathComponent("ThemeFixture")
            try FileManager.default.createDirectory(at: skinFolder, withIntermediateDirectories: true)
            try """
            [Rainmeter]
            Update=-1
            [Label]
            Meter=String
            Text=Theme
            """.write(to: skinFolder.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
            app.rescanLibrary()
            guard let skin = app.activate(config: "ThemeFixture", file: "Skin.ini") else {
                return t.check(false, "theme fixture loads")
            }
            t.check(AppSelfTest.spin { skin.isStarted })

            let appAppearanceBefore = NSApp.appearance
            let skinAppearanceBefore = skin.window.appearance

            CodeEditorRoutingSelfTests.withFakes(.init(), .init()) {
                let settings = SettingsWindowController(app: app)
                let debug = DebugWindowController.show(app: app, tab: .log)
                let manage = ManageWindowController(app: app)
                let about = AboutWindowController(app: app)
                let packager = SkinPackagerWindowController(app: app)
                _ = app.skinToolTips.ensurePanelForTesting()
                defer {
                    settings.close()
                    debug.close()
                    manage.close()
                    about.close()
                    packager.close()
                }
                settings.select(.general)
                checkGeneralLayout(t, settings: settings)

                t.equal(app.state.uiTheme, .auto)
                t.equal(settings.uiThemePopUp.indexOfSelectedItem, 0)
                t.equal(settings.uiThemePopUp.itemTitles, [L("Auto"), L("Light"), L("Dark")])

                settings.uiThemePopUp.selectItem(at: 2)
                if let target = settings.uiThemePopUp.target, let action = settings.uiThemePopUp.action {
                    t.check(NSApp.sendAction(action, to: target, from: settings.uiThemePopUp))
                }
                t.equal(app.state.uiTheme, .dark)
                t.equal(app.state.data.rainmeterOptions["UITheme"], "2")
                t.equal(settings.window?.appearance?.name, .darkAqua)
                t.equal(debug.window?.appearance?.name, .darkAqua)
                t.equal(manage.window?.appearance?.name, .darkAqua)
                t.equal(about.window?.appearance?.name, .darkAqua)
                t.equal(packager.window?.appearance?.name, .darkAqua)
                t.equal(app.updateFlow.window?.appearance?.name, .darkAqua)
                t.equal(app.skinToolTips.panelForTheme?.appearance?.name, .darkAqua)

                let mainMenu = NSMenu()
                app.buildMainMenu(mainMenu)
                t.equal(mainMenu.appearance?.name, .darkAqua)
                let skinMenu = app.skinMenu(for: skin, includeCustomItems: false, discoverLibrary: false)
                t.equal(skinMenu.appearance?.name, .darkAqua)

                t.check(NSApp.appearance === appAppearanceBefore,
                        "UITheme must not overwrite NSApp.appearance")
                t.check(skin.window.appearance === skinAppearanceBefore,
                        "UITheme must not alter skin windows' system appearance")

                app.state.setUITheme(.light)
                t.equal(settings.uiThemePopUp.indexOfSelectedItem, 1)
                t.equal(settings.window?.appearance?.name, .aqua)
                t.equal(debug.window?.appearance?.name, .aqua)
                t.equal(app.skinToolTips.panelForTheme?.appearance?.name, .aqua)

                // Ordinary layout replacement preserves UITheme; empty INI leaves settings untouched.
                let previous = LayoutState(skins: [:], order: [], rainmeterOptions: app.state.data.rainmeterOptions)
                let incoming = LayoutState(skins: [:], order: [], rainmeterOptions: ["UITheme": "2"])
                let merged = incoming.preservingSettings(from: previous)
                app.state.replaceLayout(merged)
                t.equal(app.state.uiTheme, .light, "ordinary layouts preserve the user's UITheme choice")

                app.state.setUITheme(.auto)
                t.equal(settings.uiThemePopUp.indexOfSelectedItem, 0)
                t.equal(settings.window?.appearance, nil)
                t.equal(debug.window?.appearance, nil)
                t.equal(app.skinToolTips.panelForTheme?.appearance, nil)
            }
        }
    }

    private static func checkGeneralLayout(_ t: AppTestRunner, settings: SettingsWindowController) {
        guard let window = settings.window, let content = window.contentView else {
            return t.check(false, "General pane content exists")
        }
        var labels: [String] = []
        func collect(_ view: NSView) {
            if let field = view as? NSTextField, !field.isEditable, !field.isHidden {
                labels.append(field.stringValue)
            }
            for child in view.subviews { collect(child) }
        }
        collect(content)
        t.check(labels.contains(L("User interface")) && labels.contains(L("General")) && labels.contains(L("Skins")),
                "General displays User interface, General and Skins headings: \(labels)")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            t.close(content.bounds.width, SettingsWindowController.contentWidth)
            t.check(content.bounds.height >= ceil(content.fittingSize.height),
                    "\(appearance.rawValue): reorganized General pane fits its height")
            let controls: [NSView] = [settings.uiThemePopUp, settings.defaultZoomField, settings.defaultZoomStepper,
                                     settings.forceZoomBox, settings.disableDraggingBox,
                                     settings.automaticUpdatesBox, settings.checkUpdatesButton]
            for control in controls {
                let rect = control.convert(control.bounds, to: content)
                t.check(rect.width > 0 && rect.height > 0 && content.bounds.contains(rect),
                        "\(appearance.rawValue): General control stays inside bounds")
            }
            t.check(settings.snapshot() != nil, "\(appearance.rawValue): General snapshot succeeds")
        }
    }
}
