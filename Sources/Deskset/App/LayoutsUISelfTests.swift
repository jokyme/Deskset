import AppKit
import DesksetCore

/// The Layouts page exercises the same controls as a person uses, with temporary files and an in-memory wallpaper.
enum LayoutsUISelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Layouts UI: selection, save options and replacement") {
            guard let app = try AppSelfTest.makeApp(t),
                  app.activate(config: "App\\Focus", file: "Focus.ini") != nil,
                  app.activate(config: "App\\Controls", file: "Controls.ini") != nil else { return }
            app.deactivate(config: "App\\Controls")
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            t.equal(manage.tab, .skins)
            manage.selectTab(.layouts)
            t.equal(manage.tab, .layouts)
            t.equal(manage.testLayoutNames, [])
            t.equal(manage.testLayoutsStatus, "No saved layouts.")
            for button in [manage.testSaveLayoutButton, manage.testLoadLayoutButton,
                           manage.testDeleteLayoutButton, manage.testEditLayoutButton] {
                t.check(!button.isEnabled, "empty page cannot save an unnamed layout or act on no selection")
            }

            manage.testTypeLayoutName("Desktop")
            t.check(manage.testSaveLayoutButton.isEnabled)
            manage.testSaveLayoutButton.performClick(nil)
            t.equal(manage.testLayoutNames, ["Desktop"])
            t.equal(manage.testSelectedLayout, "Desktop")
            let first = try app.layoutStore.read(named: "Desktop")
            t.check(first.ini.section(named: "App\\Focus") != nil)
            t.equal(first.ini.section(named: "App\\Controls")?["Active"], "0")
            t.equal(first.wallpaper, nil)
            t.check(manage.testLoadLayoutButton.isEnabled)
            t.check(manage.testDeleteLayoutButton.isEnabled)
            t.check(manage.testEditLayoutButton.isEnabled)

            manage.testExcludeUnloadedBox.performClick(nil)
            manage.testTypeLayoutName("Active only")
            manage.testSaveLayoutButton.performClick(nil)
            let activeOnly = try app.layoutStore.read(named: "Active only")
            t.check(activeOnly.ini.section(named: "App\\Focus") != nil)
            t.equal(activeOnly.ini.section(named: "App\\Controls"), nil)

            manage.testSelectLayout("Desktop")
            t.equal(manage.testLayoutNameField.stringValue, "Desktop", "selecting a saved row supplies its save name")
            manage.testIncludeWallpaperBox.performClick(nil)
            manage.testEmptyLayoutBox.performClick(nil)
            t.check(!manage.testExcludeUnloadedBox.isEnabled, "empty layout already excludes every config")
            t.check(!manage.testIncludeWallpaperBox.isEnabled, "empty layouts cannot include the current wallpaper")
            t.equal(manage.testExcludeUnloadedBox.state, .off)
            t.equal(manage.testIncludeWallpaperBox.state, .off)
            var replacements: [String] = []
            manage.layoutReplacementConfirmationForTesting = { name in replacements.append(name); return false }
            manage.testSaveLayoutButton.performClick(nil)
            t.equal(try app.layoutStore.read(named: "Desktop"), first, "cancel keeps the previous layout")
            manage.layoutReplacementConfirmationForTesting = { name in replacements.append(name); return true }
            manage.testSaveLayoutButton.performClick(nil)
            let replaced = try app.layoutStore.read(named: "Desktop")
            t.equal(replaced.ini.sections.map(\.name), [], "confirmed Save replaces the selected layout")
            t.equal(replacements, ["Desktop", "Desktop"])
            t.equal(manage.testLayoutNames.count, 2, "replacement does not create a duplicate")
            t.check(app.controller(for: "App\\Focus") != nil, "saving an empty layout does not unload the desktop")

            manage.testEmptyLayoutBox.performClick(nil)
            t.check(manage.testExcludeUnloadedBox.isEnabled && manage.testIncludeWallpaperBox.isEnabled)
            t.equal(manage.testExcludeUnloadedBox.state, .off, "leaving empty mode does not restore old option checks")
            t.equal(manage.testIncludeWallpaperBox.state, .off)
            (app.layoutWallpaper as? MemoryLayoutWallpaper)?.bitmap = Data([0x42, 0x4D, 1, 2])
            manage.testIncludeWallpaperBox.performClick(nil)
            manage.testTypeLayoutName("With wallpaper")
            manage.testSaveLayoutButton.performClick(nil)
            t.equal(try app.layoutStore.read(named: "With wallpaper").wallpaper, Data([0x42, 0x4D, 1, 2]))
            t.equal(replacements, ["Desktop", "Desktop"], "a new layout does not request replacement confirmation")
            manage.select(config: "App\\Focus", file: nil)
            t.equal(manage.tab, .skins, "Manage skin always returns to its Skins page")
        }

        t.suite("App: Layouts UI: load, backup, edit and delete") {
            guard let app = try AppSelfTest.makeApp(t),
                  app.activate(config: "App\\Focus", file: "Compact.ini") != nil else { return }
            let trash = isolateTrash(app, t)
            try app.saveLayout(named: "Desktop", options: LayoutSaveOptions())
            try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.selectTab(.layouts)
            manage.testSelectLayout("Empty")
            manage.testLoadLayoutButton.performClick(nil)
            t.check(app.isLoadingLayout)
            t.check(!manage.testSaveLayoutButton.isEnabled)
            t.check(!manage.testLoadLayoutButton.isEnabled)
            t.check(!manage.testDeleteLayoutButton.isEnabled)
            t.check(!manage.testEditLayoutButton.isEnabled)
            t.check(AppSelfTest.spin { !app.isLoadingLayout })
            t.equal(app.controllers.count, 0)
            t.check(manage.testLayoutNames.contains("@Backup"), "automatic backup appears without reopening the page")
            t.check(manage.testLoadLayoutButton.isEnabled)

            manage.testSelectLayout("@Backup")
            t.check(!manage.testSaveLayoutButton.isEnabled, "the automatic backup cannot be replaced through Save")
            manage.testLoadLayoutButton.performClick(nil)
            t.check(AppSelfTest.spin { !app.isLoadingLayout })
            t.check(app.controller(for: "App\\Focus") != nil, "the backup is available through the same Load action")

            app.state.updateEditor { $0.codeEditor = .builtIn }
            manage.testSelectLayout("Desktop")
            manage.testEditLayoutButton.performClick(nil)
            let expected = try app.layoutStore.iniURL(named: "Desktop")
            t.equal(app.codeFileWindows.map { $0.file.resolvingSymlinksInPath() }, [expected.resolvingSymlinksInPath()],
                    "Edit opens the saved Rainmeter.ini as a text file")
            t.equal(app.controllers.count, 1, "editing a layout does not load it as a skin")

            var deletions: [String] = []
            manage.layoutDeletionConfirmationForTesting = { name in deletions.append(name); return false }
            manage.testDeleteLayoutButton.performClick(nil)
            t.check(app.layoutStore.contains(named: "Desktop"), "cancel keeps the layout")
            t.equal(manage.testSelectedLayout, "Desktop")
            manage.layoutDeletionConfirmationForTesting = { name in deletions.append(name); return true }
            manage.testDeleteLayoutButton.performClick(nil)
            t.equal(deletions, ["Desktop", "Desktop"])
            t.check(!app.layoutStore.contains(named: "Desktop"))
            t.check(!manage.testLayoutNames.contains("Desktop"))
            t.equal(manage.testSelectedLayout, nil)
            t.check(!manage.testDeleteLayoutButton.isEnabled)
            t.check(FileManager.default.fileExists(atPath: app.skinsDirectory.appendingPathComponent("App/Focus/Compact.ini").path),
                    "deleting a layout does not delete its skins")
            t.check(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Desktop/Rainmeter.ini").path),
                    "the complete layout moves to the injected trash destination")
            app.layoutStore = LayoutStore(directory: app.layoutsDirectory, trash: { _ in
                throw CocoaError(.fileWriteNoPermission)
            })
            manage.testSelectLayout("Empty")
            manage.testDeleteLayoutButton.performClick(nil)
            t.equal(app.lastAlert?.title, "Could not delete layout")
            t.check(app.layoutStore.contains(named: "Empty"), "a failed trash operation keeps the layout")
            t.equal(manage.testSelectedLayout, "Empty")
        }

        t.suite("App: Layouts UI: invalid names and external list changes") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            _ = isolateTrash(app, t)
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.selectTab(.layouts)
            manage.testTypeLayoutName("  \n ")
            t.check(!manage.testSaveLayoutButton.isEnabled)
            manage.testTypeLayoutName("@bAcKuP")
            t.check(!manage.testSaveLayoutButton.isEnabled)
            manage.testTypeLayoutName("../Outside")
            manage.testSaveLayoutButton.performClick(nil)
            t.equal(app.lastAlert?.title, "Could not save layout")
            t.equal(manage.testLayoutNames, [])
            try app.saveLayout(named: "Imported", options: LayoutSaveOptions(empty: true))
            t.equal(manage.testLayoutNames, ["Imported"], "another entry point updates the open page")
            manage.testSelectLayout("Imported")
            try app.layoutStore.delete(named: "Imported")
            manage.selectTab(.skins)
            manage.selectTab(.layouts)
            t.equal(manage.testLayoutNames, [], "selecting Layouts rescans layouts edited outside the app")
            t.equal(manage.testSelectedLayout, nil)
            t.check(!manage.testLoadLayoutButton.isEnabled)
            let incomplete = app.layoutsDirectory.appendingPathComponent("Incomplete")
            try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: false)
            manage.selectTab(.skins)
            manage.selectTab(.layouts)
            t.equal(manage.testLayoutNames, ["Incomplete"], "a saved directory is listed even without its INI")
            manage.testSelectLayout("Incomplete")
            var replacements = 0
            manage.layoutReplacementConfirmationForTesting = { _ in replacements += 1; return false }
            manage.testSaveLayoutButton.performClick(nil)
            t.equal(replacements, 1, "an incomplete destination still needs replacement confirmation")
            t.check(!FileManager.default.fileExists(atPath: incomplete.appendingPathComponent("Rainmeter.ini").path))
            manage.layoutReplacementConfirmationForTesting = { _ in replacements += 1; return true }
            manage.testSaveLayoutButton.performClick(nil)
            t.equal(replacements, 2)
            t.check(FileManager.default.fileExists(atPath: incomplete.appendingPathComponent("Rainmeter.ini").path))
        }

        t.suite("App: Layouts UI: minimum size and appearance") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try app.saveLayout(named: "A saved desktop with a longer name", options: LayoutSaveOptions(empty: true))
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            manage.selectTab(.layouts)
            manage.testSelectLayout("A saved desktop with a longer name")
            guard let window = manage.window, let content = window.contentView else { return t.check(false, "window") }
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                content.layoutSubtreeIfNeeded()
                let controls: [NSView] = [manage.testLayoutNameField, manage.testEmptyLayoutBox,
                    manage.testExcludeUnloadedBox, manage.testIncludeWallpaperBox, manage.testSaveLayoutButton,
                    manage.testLayoutsTable, manage.testLoadLayoutButton, manage.testDeleteLayoutButton,
                    manage.testEditLayoutButton]
                for control in controls {
                    let rect = control.convert(control.bounds, to: content)
                    t.check(rect.width > 0 && rect.height > 0 && content.bounds.contains(rect),
                            "\(appearance.rawValue): \(control) fits the minimum window")
                    t.check(!control.hasAmbiguousLayout, "\(appearance.rawValue): control has a defined layout")
                }
                t.check(manage.snapshot() != nil, "\(appearance.rawValue) snapshot renders")
            }
        }
    }

    private static func isolateTrash(_ app: AppController, _ t: AppTestRunner) -> URL {
        let trash = t.temporaryDirectory("layouts-trash")
        app.layoutStore = LayoutStore(directory: app.layoutsDirectory, trash: { source in
            try FileManager.default.moveItem(at: source, to: trash.appendingPathComponent(source.lastPathComponent))
        })
        return trash
    }
}
