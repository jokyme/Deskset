import Foundation
import DesksetCore

enum NewSkinModelSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: New Skin model: missing settings resolves its existing system ancestor") {
            let root = t.temporaryDirectory("new-skin-missing-settings")
            let skins = root.appendingPathComponent("Skins", isDirectory: true)
            let settings = root.appendingPathComponent("Missing/Settings", isDirectory: true)
            try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: false)
            t.check(!FileManager.default.fileExists(atPath: settings.path))
            let model = try NewSkinModel(skinsDirectory: skins, settingsDirectory: settings)
            let id = try model.createRoot(named: "Suite")
            let skin = try model.addSkin(named: "Clock", in: id, template: .standard)
            t.equal(model.item(id: skin)?.url.lastPathComponent, "Clock.ini")
            t.check(FileManager.default.fileExists(atPath: try model.templateURL(.standard).path))
            t.equal(try model.saveTemplate(named: "Named", from: .standard), .named("Named"))
            let originalDefault = try TextDecoding.readFile(at: settings.appendingPathComponent("NewSkin.template"))
            t.equal(originalDefault, try model.templateText(.standard), "the caller's original settings URL reads the same file")
            t.equal(try TextDecoding.readFile(at: settings.appendingPathComponent("Templates/Named.template")), originalDefault)
        }

        t.suite("App: New Skin model: one root and session ownership") {
            let f = try Fixture(t, "new-skin-root")
            let model = try f.model()
            t.check(try model.reload().isEmpty)
            t.check(!model.canAddResources)
            let rootID = try model.createRoot(named: "My suite")
            let root = try f.unwrap(model.item(id: rootID))
            t.equal(root.url.lastPathComponent, "My suite")
            t.check(root.isSessionCreated)
            t.check(model.canRenameOrDelete(item: rootID))
            t.check(model.canAddResources)
            fails(t, "a second root must not replace the anchor") { _ = try model.createRoot(named: "Other") }
            t.check(!FileManager.default.fileExists(atPath: f.skins.appendingPathComponent("Other").path))
            let reopened = try f.model(initial: root.url)
            let existing = try f.unwrap(reopened.reload().first)
            t.check(!existing.isSessionCreated)
            t.check(!reopened.canRenameOrDelete(item: existing.id), "ownership belongs to one dialog session")
            fails(t, "existing roots cannot be renamed") { try reopened.rename(item: existing.id, to: "Other") }
            fails(t, "existing roots cannot be deleted") { try reopened.delete(item: existing.id) }
        }

        t.suite("App: New Skin model: independent tree and root resources") {
            let f = try Fixture(t, "new-skin-tree")
            let suite = f.skins.appendingPathComponent("Suite")
            try FileManager.default.createDirectory(at: suite.appendingPathComponent("Empty/Nested"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: suite.appendingPathComponent("@Resources"), withIntermediateDirectories: true)
            try "[Rainmeter]\n".write(to: suite.appendingPathComponent("Existing.INI"), atomically: true, encoding: .utf8)
            try "private".write(to: suite.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
            let model = try f.model(initial: suite)
            let root = try f.unwrap(model.reload().first)
            t.equal(root.children.map { $0.url.lastPathComponent }, ["@Resources", "Empty", "Existing.INI"])
            t.check(root.children.allSatisfy { !$0.isSessionCreated })
            t.check(!model.canAddResources, "an existing resources folder disables creation")
            let nested = try f.model(initial: suite.appendingPathComponent("Empty"))
            _ = try nested.reload()
            t.check(!nested.canAddResources, "a nested anchor cannot create a nested resources folder")
            fails(t, "resources are root-only") { _ = try nested.addResources() }
            let fresh = try f.model()
            _ = try fresh.createRoot(named: "Fresh")
            let resources = try fresh.addResources()
            t.equal(fresh.item(id: resources)?.url.lastPathComponent, "@Resources")
            t.check(!fresh.canAddResources)
            fails(t, "resources cannot be created twice") { _ = try fresh.addResources() }
        }

        t.suite("App: New Skin model: UTF16 skin and lazy default template") {
            let f = try Fixture(t, "new-skin-encoding")
            let model = try f.model()
            let root = try model.createRoot(named: "Original")
            t.check(!FileManager.default.fileExists(atPath: f.settings.path), "opening the model does not write templates")
            let skin = try model.addSkin(named: "Clock", in: root, template: .standard)
            let url = try f.unwrap(model.item(id: skin)?.url)
            let data = try Data(contentsOf: url)
            t.equal(Array(data.prefix(2)), [0xFF, 0xFE])
            let decoded = TextDecoding.decodeDetectingEncoding(data)
            t.equal(decoded.encoding, .utf16LittleEndian(bom: true))
            let ini = IniDocument.parse(decoded.text)
            t.equal(ini.section(named: "Rainmeter")?.entries.first(where: { $0.key == "Update" })?.value, "1000")
            for key in ["Name", "Author", "Information", "License", "Version"] {
                t.equal(ini.section(named: "Metadata")?.entries.first(where: { $0.key == key })?.value, "")
            }
            t.check(ini.section(named: "Variables") != nil)
            t.equal(url.lastPathComponent, "Clock.ini")
            let template = try model.templateURL(.standard)
            t.equal(try Data(contentsOf: template), data)
            let uppercase = try model.addSkin(named: "Another.INI", in: root, template: .standard)
            t.equal(model.item(id: uppercase)?.url.lastPathComponent, "Another.INI")
        }

        t.suite("App: New Skin model: template cloning preserves literal Unicode text") {
            let f = try Fixture(t, "new-skin-template")
            try FileManager.default.createDirectory(at: f.settings, withIntermediateDirectories: true)
            let original = "; 中文 and café\n[Rainmeter]\nUpdate=500\n[Variables]\nLiteral=#CURRENTCONFIG# $Name$ %1\n"
            let source = f.settings.appendingPathComponent("NewSkin.template")
            try original.write(to: source, atomically: true, encoding: .utf8)
            let originalData = try Data(contentsOf: source)
            let model = try f.model()
            t.equal(try model.templateText(.standard), original)
            t.equal(try model.templates(), [])
            let chosen = try model.saveTemplate(named: "My template", from: .standard)
            t.equal(chosen, .named("My template"))
            t.equal(try model.templates(), ["My template"])
            t.equal(try model.templateText(chosen), original)
            t.equal(Array(try Data(contentsOf: model.templateURL(chosen)).prefix(2)), [0xFF, 0xFE])
            t.equal(try Data(contentsOf: source), originalData, "the existing default is not rewritten")
            let root = try model.createRoot(named: "Different name")
            let item = try model.addSkin(named: "中文", in: root, template: chosen)
            t.equal(try TextDecoding.readFile(at: f.unwrap(model.item(id: item)?.url)), original, "templates are not interpolated")
            fails(t, "saving a duplicate template must not overwrite") { _ = try model.saveTemplate(named: "MY TEMPLATE", from: .standard) }
            t.equal(try model.templateText(chosen), original)
            fails(t, "default cannot be deleted") { try model.deleteTemplate(.standard) }
            try model.deleteTemplate(chosen)
            t.equal(try model.templates(), [])
            t.equal(try Data(contentsOf: source), originalData)
        }

        t.suite("App: New Skin model: names and all sibling collisions") {
            let f = try Fixture(t, "new-skin-names")
            let model = try f.model()
            for name in ["", ".", "..", "../Outside", "a/b", "a\\b", "CON", "NUL.ini", "Bad?", "End.", "End ", "line\nfeed"] {
                fails(t, name) { _ = try model.createRoot(named: name) }
            }
            let root = try model.createRoot(named: "Suite")
            let directory = try f.unwrap(model.item(id: root)?.url)
            try "untouched".write(to: directory.appendingPathComponent("Block"), atomically: true, encoding: .utf8)
            fails(t, "an invisible non-INI file still blocks folders") { _ = try model.addFolder(named: "BLOCK", in: root) }
            try "original".write(to: directory.appendingPathComponent("Existing.ini"), atomically: true, encoding: .utf8)
            fails(t, "file collisions ignore case") { _ = try model.addSkin(named: "EXISTING", in: root, template: .standard) }
            t.equal(try String(contentsOf: directory.appendingPathComponent("Existing.ini"), encoding: .utf8), "original")
            for name in ["../Outside", "a/b", "NUL", ".ini", String(repeating: "a", count: 253)] {
                fails(t, name) { _ = try model.addSkin(named: name, in: root, template: .standard) }
            }
            fails(t, "template traversal") { _ = try model.saveTemplate(named: "../Outside", from: .standard) }
            t.check(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Outside.ini").path))
            t.check(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".deskset-") })
        }

        t.suite("App: New Skin model: rename retains descendant IDs and paths") {
            let f = try Fixture(t, "new-skin-rename")
            let model = try f.model()
            let root = try model.createRoot(named: "Before")
            let folder = try model.addFolder(named: "Nested", in: root)
            let skin = try model.addSkin(named: "Clock.ini", in: folder, template: .standard)
            let rootNode = try f.unwrap(model.item(id: root))
            let skinNode = try f.unwrap(model.item(id: skin))
            try model.rename(item: root, to: "After")
            t.check(rootNode === model.item(id: root))
            t.check(skinNode === model.item(id: skin))
            t.check(skinNode.url.path.hasSuffix("/After/Nested/Clock.ini"))
            t.check(model.canRenameOrDelete(item: folder))
            t.check(model.canRenameOrDelete(item: skin))
            try model.rename(item: folder, to: "NESTED")
            t.check(skinNode.url.path.hasSuffix("/After/NESTED/Clock.ini"), "case-only parent rename migrates children")
            try model.rename(item: skin, to: "clock")
            t.equal(skinNode.url.lastPathComponent, "clock.ini")
            t.check(FileManager.default.fileExists(atPath: skinNode.url.path))
            t.check(try FileManager.default.contentsOfDirectory(atPath: rootNode.url.path).allSatisfy { !$0.hasPrefix(".deskset-") })
            try model.delete(item: folder)
            t.check(model.item(id: folder) == nil)
            t.check(model.item(id: skin) == nil)
            t.check(model.canRenameOrDelete(item: root))
        }

        t.suite("App: New Skin model: an atomic file save retains session rights") {
            let f = try Fixture(t, "new-skin-atomic-save")
            let model = try f.model()
            let root = try model.createRoot(named: "Suite")
            let id = try model.addSkin(named: "Clock", in: root, template: .standard)
            let node = try f.unwrap(model.item(id: id))
            let previous = try FileManager.default.attributesOfItem(atPath: node.url.path)[.systemFileNumber] as? NSNumber
            let edited = "; saved externally\n[Rainmeter]\nUpdate=2000\n"
            try Data(edited.utf8).write(to: node.url, options: .atomic)
            let current = try FileManager.default.attributesOfItem(atPath: node.url.path)[.systemFileNumber] as? NSNumber
            t.check(previous != current, "the fixture really replaced the inode")
            _ = try model.reload()
            t.check(model.item(id: id) === node)
            t.check(node.isSessionCreated)
            t.check(model.canRenameOrDelete(item: id))
            try model.rename(item: id, to: "Edited.INI")
            t.equal(try TextDecoding.readFile(at: node.url), edited)
            try model.delete(item: id)
            t.check(model.item(id: id) == nil)
        }

        t.suite("App: New Skin model: directory replacements do not inherit session rights") {
            let f = try Fixture(t, "new-skin-directory-replaced")
            let model = try f.model()
            let root = try model.createRoot(named: "Suite")
            let folder = try model.addFolder(named: "Folder", in: root)
            let child = try model.addSkin(named: "Child", in: folder, template: .standard)
            let url = try f.unwrap(model.item(id: folder)?.url)
            try FileManager.default.moveItem(at: url, to: f.root.appendingPathComponent("Original folder"))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try "replacement".write(to: url.appendingPathComponent("Child.ini"), atomically: true, encoding: .utf8)
            t.check(!model.canRenameOrDelete(item: folder))
            t.check(!model.canRenameOrDelete(item: child))
            fails(t, "cannot rename an externally replaced folder") { try model.rename(item: folder, to: "Moved") }
            fails(t, "cannot add through a stale folder selection") { _ = try model.addFolder(named: "New", in: folder) }
            fails(t, "cannot delete a descendant of an externally replaced folder") { try model.delete(item: child) }
            t.equal(try String(contentsOf: url.appendingPathComponent("Child.ini"), encoding: .utf8), "replacement")
        }

        t.suite("App: New Skin model: an existing parent replacement cannot inherit file ownership") {
            let f = try Fixture(t, "new-skin-existing-parent-replaced")
            let suite = f.skins.appendingPathComponent("Suite")
            let parent = suite.appendingPathComponent("Existing")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let model = try f.model(initial: suite)
            let root = try f.unwrap(model.reload().first)
            let folder = try f.unwrap(root.children.first)
            t.check(!folder.isSessionCreated)
            let child = try model.addSkin(named: "Child", in: folder.id, template: .standard)
            t.check(model.canRenameOrDelete(item: child))
            try FileManager.default.moveItem(at: parent, to: f.root.appendingPathComponent("Previous parent"))
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let replacement = parent.appendingPathComponent("Child.ini")
            try "replacement".write(to: replacement, atomically: true, encoding: .utf8)
            t.check(!model.canRenameOrDelete(item: child))
            fails(t, "rename cannot use the replaced existing parent") { try model.rename(item: child, to: "Moved") }
            fails(t, "delete cannot use the replaced existing parent") { try model.delete(item: child) }
            _ = try model.reload()
            t.check(!model.canRenameOrDelete(item: child), "a rescan must not grant the new parent the previous identity")
            t.check(model.item(id: child)?.isSessionCreated == false)
            fails(t, "rescanned replacement still cannot be deleted") { try model.delete(item: child) }
            t.equal(try String(contentsOf: replacement, encoding: .utf8), "replacement")
        }

        t.suite("App: New Skin model: a new folder can reuse a removed existing folder name") {
            let f = try Fixture(t, "new-skin-reused-folder")
            let suite = f.skins.appendingPathComponent("Suite")
            let previous = suite.appendingPathComponent("Empty")
            try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
            let model = try f.model(initial: suite)
            let root = try f.unwrap(model.reload().first)
            let oldFolder = try f.unwrap(root.children.first)
            let oldChild = try model.addSkin(named: "Old", in: oldFolder.id, template: .standard)
            try FileManager.default.removeItem(at: previous)
            let replacement = try model.addFolder(named: "Empty", in: root.id)
            t.check(replacement != oldFolder.id)
            t.check(model.item(id: oldChild) == nil)
            t.check(model.canRenameOrDelete(item: replacement))
            let skin = try model.addSkin(named: "New", in: replacement, template: .standard)
            t.equal(model.item(id: skin)?.url.lastPathComponent, "New.ini")
            let folder = try model.addFolder(named: "Nested", in: replacement)
            t.equal(model.item(id: folder)?.url.lastPathComponent, "Nested")
            try "external".write(to: previous.appendingPathComponent("Old.ini"), atomically: true, encoding: .utf8)
            _ = try model.reload()
            let external = try f.unwrap(model.item(id: replacement)?.children.first { $0.url.lastPathComponent == "Old.ini" })
            t.check(!external.isSessionCreated, "the replaced folder must not transfer old descendant ownership")
        }

        t.suite("App: New Skin model: symlink boundaries and unsafe templates") {
            let f = try Fixture(t, "new-skin-symlinks")
            let outside = f.root.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: f.skins.appendingPathComponent("Linked"), withDestinationURL: outside)
            fails(t, "cannot anchor a symlink") { _ = try f.model(initial: f.skins.appendingPathComponent("Linked")) }
            fails(t, "cannot anchor outside Skins") { _ = try f.model(initial: outside) }
            fails(t, "Skins itself is not a configuration anchor") { _ = try f.model(initial: f.skins) }
            let model = try f.model()
            let root = try model.createRoot(named: "Suite")
            let rootURL = try f.unwrap(model.item(id: root)?.url)
            try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("Link"), withDestinationURL: outside)
            _ = try model.reload()
            t.equal(model.item(id: root)?.children.count, 0, "tree scanning does not follow links")
            fails(t, "a link participates in collision checks") { _ = try model.addFolder(named: "link", in: root) }
            try FileManager.default.createDirectory(at: f.settings, withIntermediateDirectories: true)
            let external = outside.appendingPathComponent("External.template")
            try "external".write(to: external, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: f.settings.appendingPathComponent("NewSkin.template"), withDestinationURL: external)
            fails(t, "default template links are not read") { _ = try model.templateText(.standard) }
            t.equal(try String(contentsOf: external, encoding: .utf8), "external")
            t.equal(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["External.template"])
        }

        t.suite("App: New Skin model: template directories and read failures") {
            let f = try Fixture(t, "new-skin-template-safety")
            let model = try f.model()
            let root = try model.createRoot(named: "Suite")
            _ = try model.templateURL(.standard)
            let saved = try model.saveTemplate(named: "Saved", from: .standard)
            let savedURL = try model.templateURL(saved)
            try FileManager.default.removeItem(at: savedURL)
            fails(t, "missing source is not replaced by empty content") { _ = try model.addSkin(named: "Missing", in: root, template: saved) }
            t.check(!FileManager.default.fileExists(atPath: f.skins.appendingPathComponent("Suite/Missing.ini").path))
            try FileManager.default.removeItem(at: savedURL.deletingLastPathComponent())
            let outside = f.root.appendingPathComponent("Outside templates")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: savedURL.deletingLastPathComponent(), withDestinationURL: outside)
            fails(t, "templates folder links are rejected") { _ = try model.saveTemplate(named: "Escaped", from: .standard) }
            fails(t, "template scanning does not follow folder links") { _ = try model.templates() }
            t.equal(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        }

        t.suite("App: New Skin model: failed Trash preserves session ownership") {
            let f = try Fixture(t, "new-skin-trash-failure")
            let model = try NewSkinModel(skinsDirectory: f.skins, settingsDirectory: f.settings,
                                        trash: { _ in throw CocoaError(.fileWriteNoPermission) })
            let root = try model.createRoot(named: "Suite")
            let skin = try model.addSkin(named: "Clock", in: root, template: .standard)
            let url = try f.unwrap(model.item(id: skin)?.url)
            fails(t, "Trash failure must propagate") { try model.delete(item: skin) }
            t.check(model.canRenameOrDelete(item: skin))
            t.check(FileManager.default.fileExists(atPath: url.path))
            try model.rename(item: skin, to: "Still here")
            t.equal(model.item(id: skin)?.url.lastPathComponent, "Still here.ini")
        }
    }

    private static func fails(_ t: AppTestRunner, _ message: String, _ body: () throws -> Void) {
        do { try body(); t.check(false, message) }
        catch { t.check(true) }
    }

    private struct Fixture {
        let root: URL
        let skins: URL
        let settings: URL
        let trash: URL

        init(_ t: AppTestRunner, _ name: String) throws {
            root = t.temporaryDirectory(name).resolvingSymlinksInPath()
            skins = root.appendingPathComponent("Skins", isDirectory: true)
            settings = root.appendingPathComponent("Settings", isDirectory: true)
            trash = root.appendingPathComponent("Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        }

        func model(initial: URL? = nil) throws -> NewSkinModel {
            try NewSkinModel(skinsDirectory: skins, settingsDirectory: settings, initialDirectory: initial, trash: { url in
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            })
        }

        func unwrap<T>(_ value: T?) throws -> T {
            guard let value else { throw CocoaError(.fileNoSuchFile) }
            return value
        }
    }
}
