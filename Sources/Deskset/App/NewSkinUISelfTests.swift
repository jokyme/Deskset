import AppKit
import DesksetCore

enum NewSkinUISelfTests {
    static func run(_ t: AppTestRunner) {
        creation(t)
        anchoredActions(t)
        templates(t)
        lifecycle(t)
        layout(t)
    }

    private static func creation(_ t: AppTestRunner) {
        t.suite("App: New Skin UI: root naming, folders, resources and UTF-16 skins use the selected folder") {
            guard let f = try fixture(t) else { return }
            let w = f.window
            defer { w.close() }
            _ = f.app.library
            var errors = 0
            w.errorForTesting = { _ in errors += 1 }
            t.equal(w.testTabs.tabViewItems.map(\.label), ["New skin", "Template"])
            t.check(w.testItems.isEmpty)
            t.check(w.testFolderButton.isEnabled, "an empty window can retry root naming")
            t.check(!w.testSkinButton.isEnabled && !w.testResourcesButton.isEnabled)
            answer(w, .root, nil, t)
            w.testFolderButton.performClick(nil)
            t.check(w.testItems.isEmpty, "cancelling the root name creates nothing")
            answer(w, .root, "New Suite", t)
            w.testFolderButton.performClick(nil)
            guard let root = w.testItems.first else { return t.check(false, "root was created") }
            t.equal(root.url.lastPathComponent, "New Suite")
            t.equal(w.testSelectedID, root.id)
            t.equal(w.testPath, root.url.path)
            t.check(w.testResourcesButton.isEnabled)
            w.testResourcesButton.performClick(nil)
            t.check(!w.testResourcesButton.isEnabled, "resources are created only once at the anchor")
            t.check(w.testItems.contains { $0.url.path == root.url.appendingPathComponent("@Resources").path })
            w.testSelect(root.id)
            answer(w, .folder, "Clock", t)
            w.testFolderButton.performClick(nil)
            guard let folder = w.testItems.first(where: { $0.url.lastPathComponent == "Clock" }) else {
                return t.check(false, "subfolder was created")
            }
            t.equal(w.testSelectedID, folder.id)
            answer(w, .skin, "Clock", t)
            w.testSkinButton.performClick(nil)
            guard let skin = w.testItems.first(where: { $0.kind == .skin }) else {
                return t.check(false, "skin was created")
            }
            t.equal(skin.url.path, folder.url.appendingPathComponent("Clock.ini").path)
            t.check(try Data(contentsOf: skin.url).starts(with: [0xff, 0xfe]), "new skins have a UTF-16LE BOM")
            t.equal(w.testSelectedID, skin.id)
            t.equal(w.testPath, folder.url.path, "a selected skin targets its parent")
            answer(w, .skin, "Second.ini", t)
            w.testSkinButton.performClick(nil)
            t.check(w.testItems.contains { $0.url.path == folder.url.appendingPathComponent("Second.ini").path })
            t.check(!f.app.library.contains { $0.name == "New Suite\\Clock" }, "creation does not refresh the library early")
            answer(w, .skin, "Second.ini", t)
            w.testSkinButton.performClick(nil)
            t.equal(errors, 1, "collisions are reported without replacing the existing skin")
            w.close()
            t.check(f.app.library.contains { $0.name == "New Suite\\Clock" }, "Close rescans the library")
        }
    }

    private static func anchoredActions(_ t: AppTestRunner) {
        t.suite("App: New Skin UI: session rights and editor preflight guard rename and delete") {
            guard let f = try fixture(t, anchor: "App/Focus") else { return }
            let w = f.window
            defer { w.close() }
            guard let root = w.testItems.first,
                  let original = w.testItems.first(where: { $0.kind == .skin }) else {
                return t.check(false, "anchored root and existing skin are present")
            }
            t.equal(w.testPath, root.url.path)
            t.check(!w.testResourcesButton.isEnabled, "a nested anchor cannot add a root resources folder")
            t.equal(w.testContextTitles(root.id), [])
            t.equal(w.testContextTitles(original.id), ["Edit skin"], "pre-existing files cannot be renamed or deleted")
            w.testSelect(root.id)
            answer(w, .skin, "Created", t)
            w.testSkinButton.performClick(nil)
            guard let made = w.testItems.first(where: { $0.url.lastPathComponent == "Created.ini" }) else {
                return t.check(false, "session skin was created")
            }
            t.equal(w.testContextTitles(made.id), ["Edit skin", "Rename", "Delete"])
            var preflights: [(URL, Bool)] = []
            w.preflightForTesting = { url, directory in preflights.append((url, directory)); return false }
            answer(w, .rename, "Renamed.ini", t)
            w.testRename(made.id)
            t.equal(preflights.first?.0.path, made.url.path)
            t.equal(preflights.first?.1, false)
            t.check(FileManager.default.fileExists(atPath: made.url.path), "declined preflight preserves the file")
            t.check(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("Renamed.ini").path))
            w.testDelete(made.id)
            t.equal(f.trash.paths, [], "declined preflight never reaches Trash")
            w.preflightForTesting = { _, _ in true }
            answer(w, .rename, "Renamed.ini", t)
            w.testRename(made.id)
            t.equal(w.testSelectedID, made.id, "rename keeps selection by stable item identity")
            t.equal(made.url.lastPathComponent, "Renamed.ini")
            let renamedURL = made.url
            w.testDelete(made.id)
            t.equal(f.trash.paths, [renamedURL])
            t.check(!FileManager.default.fileExists(atPath: renamedURL.path))
            t.check(FileManager.default.fileExists(atPath: original.url.path))
            w.testDelete(original.id)
            t.equal(f.trash.paths, [renamedURL], "direct calls cannot bypass session rights")
        }

        t.suite("App: New Skin UI: Edit opens a created skin without loading it") {
            guard let f = try fixture(t) else { return }
            let w = f.window
            defer { w.close() }
            answer(w, .root, "Unloaded", t)
            w.testFolderButton.performClick(nil)
            answer(w, .skin, "Created", t)
            w.testSkinButton.performClick(nil)
            guard let skin = w.testItems.first(where: { $0.kind == .skin }) else {
                return t.check(false, "created skin is present")
            }
            w.testEdit(skin.id)
            t.check(f.app.controller(for: "Unloaded") == nil)
            t.check(f.app.codeFileWindows.contains {
                CodeEditorRouter.comparablePath($0.file) == CodeEditorRouter.comparablePath(skin.url)
            }, "Edit uses the standalone editor")
        }
    }

    private static func templates(_ t: AppTestRunner) {
        t.suite("App: New Skin UI: template selection, saving, editing and guarded deletion") {
            guard let f = try fixture(t, anchor: "App/Focus") else { return }
            let w = f.window
            defer { w.close() }
            t.equal(w.testTemplatePopup.menu?.items.map(\.title), ["Template…", "Use default template"])
            t.equal(w.testTemplatePopup.menu?.items.first?.isEnabled, true, "the available menu title is not dimmed")
            t.equal(w.testTemplatePopup.menu?.items.last?.state, .on)
            t.equal(w.testTemplateNames, [], "default is not an editable saved-template row")
            t.check(!w.testSaveTemplateButton.isEnabled && !w.testEditTemplateButton.isEnabled
                    && !w.testDeleteTemplateButton.isEnabled)
            w.testTabs.selectTabViewItem(at: 1)
            w.testTemplateName.stringValue = "My Template"
            w.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: w.testTemplateName))
            t.check(w.testSaveTemplateButton.isEnabled)
            w.testSaveTemplateButton.performClick(nil)
            t.equal(w.testTemplateNames, ["My Template"])
            t.equal(w.testTemplateName.stringValue, "")
            t.check(!w.testSaveTemplateButton.isEnabled)
            t.check(w.testEditTemplateButton.isEnabled && w.testDeleteTemplateButton.isEnabled)
            t.equal(w.testTemplatePopup.menu?.items.map(\.title), ["Template…", "Use default template", "My Template"])
            t.equal(w.testTemplatePopup.menu?.items.last?.state, .on)
            let template = try f.model.templateURL(.named("My Template"))
            try "[Rainmeter]\nUpdate=1234\n[Variables]\nCustom=preserved\n"
                .write(to: template, atomically: true, encoding: .utf8)
            w.testEditTemplateButton.performClick(nil)
            t.check(f.app.codeFileWindows.contains {
                CodeEditorRouter.comparablePath($0.file) == CodeEditorRouter.comparablePath(template)
            })
            w.testTabs.selectTabViewItem(at: 0)
            answer(w, .skin, "FromTemplate", t)
            w.testSkinButton.performClick(nil)
            guard let created = w.testItems.first(where: { $0.url.lastPathComponent == "FromTemplate.ini" }) else {
                return t.check(false, "skin from template was created")
            }
            t.equal(try TextDecoding.readFile(at: created.url), try TextDecoding.readFile(at: template))
            w.testChooseTemplate("Use default template")
            t.equal(w.testTemplatePopup.menu?.items[1].state, .on)
            w.testTabs.selectTabViewItem(at: 1)
            w.testSelectTemplate("My Template")
            w.preflightForTesting = { url, directory in
                t.equal(url.path, template.path)
                t.check(!directory)
                return false
            }
            w.testDeleteTemplateButton.performClick(nil)
            t.equal(w.testTemplateNames, ["My Template"])
            w.preflightForTesting = nil
            w.testDeleteTemplateButton.performClick(nil)
            t.equal(w.testTemplateNames, [])
            t.equal(f.trash.paths, [template])
            t.check(!f.app.codeFileWindows.contains {
                CodeEditorRouter.comparablePath($0.file) == CodeEditorRouter.comparablePath(template)
            },
                    "the real preflight closes the template editor before removal")
            t.check(FileManager.default.fileExists(atPath: try f.model.templateURL(.standard).path))
        }
    }

    private static func lifecycle(_ t: AppTestRunner) {
        t.suite("App: New Skin UI: pending replies and reentrant preflight cannot mutate a closed session") {
            guard let f = try fixture(t) else { return }
            let w = f.window
            var refreshes = 0
            w.refreshForTesting = { refreshes += 1 }
            var reply: ((String?) -> Void)?
            w.namePromptForTesting = { _, answer in reply = answer }
            w.testRequestRootName()
            t.check(!w.testFolderButton.isEnabled, "an outstanding name request prevents reentry")
            w.testRequestRootName()
            w.close()
            reply?("Too Late")
            w.close()
            w.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: w.window))
            t.equal(refreshes, 1)
            t.check(!FileManager.default.fileExists(atPath: f.app.skinsDirectory.appendingPathComponent("Too Late").path))

            guard let g = try fixture(t, anchor: "App/Focus") else { return }
            defer { g.window.close() }
            answer(g.window, .skin, "Keep", t)
            g.window.testSkinButton.performClick(nil)
            guard let file = g.window.testItems.first(where: { $0.url.lastPathComponent == "Keep.ini" }) else {
                return t.check(false, "skin for reentrant deletion is present")
            }
            g.window.preflightForTesting = { _, _ in
                g.window.testDelete(file.id)
                g.window.close()
                return true
            }
            g.window.testDelete(file.id)
            t.check(g.trash.paths.isEmpty)
            t.check(FileManager.default.fileExists(atPath: file.url.path), "closing during preflight aborts deletion")
        }
    }

    private static func layout(_ t: AppTestRunner) {
        t.suite("App: New Skin UI: controls remain reachable at minimum size in both appearances") {
            guard let f = try fixture(t, anchor: "App/Focus") else { return }
            defer { f.window.close() }
            guard let window = f.window.window, let content = window.contentView else {
                return t.check(false, "window and content view are present")
            }
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: name)
                for index in 0..<2 {
                    f.window.testTabs.selectTabViewItem(at: index)
                    content.layoutSubtreeIfNeeded()
                    let controls: [NSView] = index == 0
                        ? [f.window.testFolderButton, f.window.testResourcesButton, f.window.testSkinButton,
                           f.window.testTemplatePopup]
                        : [f.window.testTemplateName, f.window.testSaveTemplateButton,
                           f.window.testEditTemplateButton, f.window.testDeleteTemplateButton]
                    for control in controls {
                        let frame = control.convert(control.bounds, to: content)
                        t.check(frame.width > 0 && frame.height > 0 && content.bounds.contains(frame),
                                "\(name.rawValue), tab \(index): control is inside the content area")
                    }
                }
            }
        }
    }

    private static func answer(_ window: NewSkinWindowController, _ kind: NewSkinWindowController.NameKind,
                                _ name: String?, _ t: AppTestRunner) {
        window.namePromptForTesting = { request, respond in t.equal(request.kind, kind); respond(name) }
    }

    private final class Trash {
        var paths: [URL] = []
        let directory: URL
        init(_ directory: URL) { self.directory = directory }
        func move(_ url: URL) throws {
            try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(UUID().uuidString))
            paths.append(url)
        }
    }

    private static func fixture(_ t: AppTestRunner, anchor: String? = nil)
        throws -> (app: AppController, model: NewSkinModel, window: NewSkinWindowController, trash: Trash)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        let trash = Trash(t.temporaryDirectory("new-skin-ui-trash"))
        let model = try NewSkinModel(skinsDirectory: app.skinsDirectory, settingsDirectory: app.settingsDirectory,
            initialDirectory: anchor.map { app.skinsDirectory.appendingPathComponent($0) }, trash: trash.move)
        let window = try NewSkinWindowController(app: app, model: model)
        return (app, model, window, trash)
    }
}
