import AppKit
import DesksetCore

enum NewSkinManageSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: New Skin Manage: root button and captured folder context") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let manage = ManageWindowController(app: app)
            defer { NewSkinWindowController.window(for: app)?.close(); manage.close() }
            manage.select(config: "App\\Focus", file: "Focus.ini")
            let menu = manage.testFolderContextMenu(config: "App\\Controls")
            guard let create = menu.items.first(where: { $0.title == "Create new skin" }),
                  let action = create.action else { return t.check(false, "folder has the documented creation entry") }
            t.check(!manage.testContextMenuTitles(config: "App\\Focus", file: "Focus.ini")
                .contains("Create new skin"), "file rows do not acquire a folder action")
            // Change selection after building the menu: the action still belongs to the right-clicked folder.
            manage.select(config: "Deskset\\Clock", file: "Clock.ini")
            t.check(NSApp.sendAction(action, to: create.target, from: create))
            guard let dialog = NewSkinWindowController.window(for: app) else {
                return t.check(false, "folder action opens New skin")
            }
            let expected = SkinLibrary.directory(for: "App\\Controls", root: app.skinsDirectory)
            t.equal(dialog.testItems.first?.url.standardizedFileURL, expected.standardizedFileURL)
            t.check(dialog.testItems.allSatisfy { !$0.isSessionCreated }, "existing files have no session mutation rights")
            t.check(NewSkinWindowController.show(app: app) === dialog, "another entry reuses the open session")
            dialog.close()

            t.equal(manage.testNewSkinButton.toolTip, "Create new skin")
            t.equal(manage.testNewSkinButton.accessibilityLabel(), "Create new skin")
            manage.testNewSkinButton.performClick(nil)
            guard let rootDialog = NewSkinWindowController.window(for: app) else {
                return t.check(false, "top button opens root creation")
            }
            t.check(rootDialog !== dialog)
            t.equal(rootDialog.testItems.count, 0, "headless initial naming is cancelled without touching disk")
        }

        t.suite("App: New Skin Manage: close refreshes the library and every active skin once") {
            guard let app = try AppSelfTest.makeApp(t),
                  let old = app.activate(config: "App\\Focus", file: "Focus.ini"),
                  let dialog = NewSkinWindowController.show(app: app,
                      initialDirectory: SkinLibrary.directory(for: "App\\Controls", root: app.skinsDirectory)) else { return }
            defer { dialog.close() }
            _ = app.library
            let directory = app.skinsDirectory.appendingPathComponent("CreatedAfterScan")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "[Rainmeter]\nUpdate=-1\n".write(to: directory.appendingPathComponent("New.ini"),
                                                  atomically: true, encoding: .utf8)
            t.check(!app.library.contains { $0.name == "CreatedAfterScan" }, "library was cached before creation")
            dialog.close()
            t.check(app.config(named: "CreatedAfterScan") != nil, "closing performs a full discovery")
            guard let refreshed = app.controller(for: old.config) else { return t.check(false, "active skin remains loaded") }
            t.check(refreshed !== old && old.isStopped, "closing also reloads the active skin")
            dialog.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: dialog.window))
            dialog.close()
            t.check(app.controller(for: old.config) === refreshed, "duplicate close callbacks cannot refresh twice")
            t.check(NewSkinWindowController.window(for: app) == nil)
        }

        t.suite("App: New Skin Manage: reopening and terminating preserve window ownership") {
            guard let app = try AppSelfTest.makeApp(t),
                  let dialog = NewSkinWindowController.show(app: app,
                      initialDirectory: SkinLibrary.directory(for: "App\\Focus", root: app.skinsDirectory)),
                  let window = dialog.window else { return }
            var refreshes = 0
            dialog.refreshForTesting = { refreshes += 1 }
            t.check(AppController.reopenTarget(editor: nil, settings: nil, newSkin: window,
                codeWindows: [], isOpen: { $0 === window }) === window, "reopen can restore New skin")
            let other = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
            t.check(AppController.reopenTarget(editor: other, settings: nil, newSkin: window,
                codeWindows: [], isOpen: { _ in true }) === other, "existing editor priority is unchanged")
            _ = app.stopAllForTermination()
            t.check(NewSkinWindowController.window(for: app) == nil, "quit closes the dialog")
            t.equal(refreshes, 0, "quitting must not reload skins after closing them")
            t.check(NewSkinWindowController.show(app: app) == nil, "late actions cannot reopen while terminating")
        }

        t.suite("App: New Skin Manage: creation button stays visible beside Active skins") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let manage = ManageWindowController(app: app)
            defer { manage.close() }
            guard let window = manage.window, let content = window.contentView else { return }
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                content.layoutSubtreeIfNeeded()
                let button = manage.testNewSkinButton.convert(manage.testNewSkinButton.bounds, to: content)
                let popup = manage.testActiveSkinsPopup.convert(manage.testActiveSkinsPopup.bounds, to: content)
                t.check(content.bounds.contains(button) && button.width >= 24 && button.height >= 24,
                        "\(appearance.rawValue): Create new skin is reachable")
                t.check(popup.maxX < button.minX && abs(popup.midY - button.midY) < 1,
                        "\(appearance.rawValue): button is beside Active skins without overlap")
            }
        }
    }
}
