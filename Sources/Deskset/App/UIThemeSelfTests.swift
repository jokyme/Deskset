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
                let menuBarPanelWindow = app.menuBarPanel.windowForTesting
                _ = app.skinToolTips.ensurePanelForTesting()
                defer {
                    app.menuBarPanel.close()
                    settings.close()
                    debug.close()
                    manage.close()
                    about.close()
                    packager.close()
                }
                settings.select(.general)
                checkGeneralLayout(t, settings: settings, manage: manage, app: app)

                t.equal(app.state.uiTheme, .auto)
                t.equal(settings.uiThemePopUp.indexOfSelectedItem, 0)
                t.equal(settings.uiThemePopUp.itemTitles, [L("Auto"), L("Light"), L("Dark")])

                settings.uiThemePopUp.selectItem(at: 2)
                if let target = settings.uiThemePopUp.target, let action = settings.uiThemePopUp.action {
                    t.check(NSApp.sendAction(action, to: target, from: settings.uiThemePopUp))
                }
                t.equal(app.state.uiTheme, .dark)
                t.equal(settings.settingsModel.uiTheme, .dark)
                t.equal(app.state.data.rainmeterOptions["UITheme"], "2")
                t.equal(settings.window?.appearance?.name, .darkAqua)
                t.equal(debug.window?.appearance?.name, .darkAqua)
                t.equal(manage.window?.appearance?.name, .darkAqua)
                t.equal(about.window?.appearance?.name, .darkAqua)
                t.equal(packager.window?.appearance?.name, .darkAqua)
                t.equal(menuBarPanelWindow?.appearance?.name, .darkAqua)
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
                t.equal(settings.settingsModel.uiTheme, .light)
                t.equal(settings.window?.appearance?.name, .aqua)
                t.equal(debug.window?.appearance?.name, .aqua)
                t.equal(menuBarPanelWindow?.appearance?.name, .aqua)
                t.equal(app.skinToolTips.panelForTheme?.appearance?.name, .aqua)

                // Ordinary layout replacement preserves UITheme; empty INI leaves settings untouched.
                let previous = LayoutState(skins: [:], order: [], rainmeterOptions: app.state.data.rainmeterOptions)
                let incoming = LayoutState(skins: [:], order: [], rainmeterOptions: ["UITheme": "2"])
                let merged = incoming.preservingSettings(from: previous)
                app.state.replaceLayout(merged)
                t.equal(app.state.uiTheme, .light, "ordinary layouts preserve the user's UITheme choice")

                app.state.setUITheme(.auto)
                t.equal(settings.uiThemePopUp.indexOfSelectedItem, 0)
                t.equal(settings.settingsModel.uiTheme, .auto)
                t.equal(settings.window?.appearance, nil)
                t.equal(debug.window?.appearance, nil)
                t.equal(menuBarPanelWindow?.appearance, nil)
                t.equal(app.skinToolTips.panelForTheme?.appearance, nil)
            }
        }
    }

    private static func checkGeneralLayout(_ t: AppTestRunner,
                                           settings: SettingsWindowController,
                                           manage: ManageWindowController,
                                           app: AppController) {
        guard let window = settings.window, let content = window.contentView else {
            return t.check(false, "General pane content exists")
        }
        t.equal(window.minSize, SettingsWindowController.minimumSize)
        t.equal(settings.settingsModel.pane, .general)
        t.equal(SettingsWindowController.Pane.allCases.map(\.rawValue),
                ["general", "editor", "layouts", "debug", "about"])
        t.check(manage.libraryModel.cards.contains { $0.config.name == "ThemeFixture" },
                "Widget Library card grid includes the installed fixture")
        let idleFolder = app.skinsDirectory.appendingPathComponent("UnloadedSuite")
        try? FileManager.default.createDirectory(at: idleFolder, withIntermediateDirectories: true)
        try? "[Rainmeter]\nUpdate=-1\n[M]\nMeter=String\nText=Idle\n"
            .write(to: idleFolder.appendingPathComponent("Idle.ini"), atomically: true, encoding: .utf8)
        app.rescanLibrary()
        manage.reload()
        manage.libraryModel.switchSection(.installed)
        manage.libraryModel.selectedFolder = "UnloadedSuite"
        t.equal(manage.libraryModel.filteredCards.map(\.config.name), ["UnloadedSuite"])
        manage.libraryModel.switchSection(.active)
        t.equal(manage.libraryModel.selectedFolder, nil,
                "switching to Loaded Skins clears a previous folder filter so loaded widgets stay visible")
        t.equal(manage.libraryModel.filteredCards.count, manage.libraryModel.activeCount)
        t.check(!manage.libraryModel.visibleRootFolders.contains { $0.name == "UnloadedSuite" },
                "Loaded Skins hides folders that have zero loaded skins")
        try? FileManager.default.removeItem(at: idleFolder)
        app.rescanLibrary()
        manage.reload()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            manage.window?.appearance = NSAppearance(named: appearance)
            app.menuBarPanel.windowForTesting?.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            t.close(content.bounds.width, SettingsWindowController.contentWidth)
            t.check(content.bounds.height >= SettingsWindowController.minimumSize.height,
                    "\(appearance.rawValue): Settings split sidebar window meets minimum height")
            t.equal(settings.settingsModel.defaultZoomPercent, app.state.defaultZoomPercent)
            t.equal(settings.settingsModel.forceDefaultZoom, app.state.forceDefaultZoom)
            t.equal(settings.settingsModel.disableDragging, app.state.disableDragging)
            t.equal(settings.settingsModel.automaticallyChecksUpdates, app.updates.automaticallyChecks)
            t.check(settings.snapshot() != nil, "\(appearance.rawValue): General snapshot succeeds")
            t.check(manage.snapshot() != nil, "\(appearance.rawValue): Widget Library snapshot succeeds")
            t.check(app.menuBarPanel.snapshot() != nil, "\(appearance.rawValue): MenuBarPanel snapshot succeeds")
        }
        window.appearance = nil
        manage.window?.appearance = nil
        app.menuBarPanel.windowForTesting?.appearance = nil
    }
}
