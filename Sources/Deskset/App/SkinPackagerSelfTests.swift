import AppKit
import DesksetCore

/// Skin Packager window (`SkinPackagerWindowController`): opening it from Manage, its two steps, Load previous, and the
/// package it writes.
enum SkinPackagerSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Skin Packager: Manage opens it with the selected skin's root config") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let history = isolatedHistory()
            defer { history.restore() }
            let manage = ManageWindowController(app: app)
            defer { SkinPackagerWindowController.window(for: app)?.close(); manage.close() }
            manage.select(config: "Deskset\\Clock", file: "Clock.ini")
            t.equal(manage.testPackageButton.toolTip, "Create .rmskin Package…")
            manage.testPackageButton.performClick(nil)
            guard let packager = SkinPackagerWindowController.window(for: app) else {
                return t.check(false, "the Manage button opens the Skin Packager")
            }
            t.equal(packager.spec.rootConfig?.standardizedFileURL,
                    app.skinsDirectory.appendingPathComponent("Deskset").standardizedFileURL, "the root config, not the skin")
            t.equal(packager.spec.name, "Deskset", "Name from the folder")
            t.check(!packager.spec.author.isEmpty, "Author and Version from the first skin's [Metadata]")
            t.check({ if case .skin = packager.spec.load { return true }; return false }(), "loads a skin by default")
            t.equal(packager.spec.minimumRainmeter, "5.0")
            t.check(SkinPackagerWindowController.show(app: app) === packager, "a second request reuses the window")
        }

        t.suite("App: Skin Packager: two steps, a package, and Load previous") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let history = isolatedHistory()
            defer { history.restore() }
            let dir = t.temporaryDirectory("packager-app")
            defer { try? FileManager.default.removeItem(at: dir) }
            let fm = FileManager.default
            let layout = app.layoutsDirectory.appendingPathComponent("Desk")
            try fm.createDirectory(at: layout, withIntermediateDirectories: true)
            try "[Rainmeter]\n[Deskset\\Clock]\nActive=1\n".write(to: layout.appendingPathComponent("Rainmeter.ini"),
                                                                 atomically: true, encoding: .utf8)
            for (folder, machine) in [("32bit", UInt16(0x14C)), ("64bit", UInt16(0x8664))] {
                try fm.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
                var bytes = [UInt8](repeating: 0, count: 0x48)
                bytes[0] = 0x4D; bytes[1] = 0x5A; bytes[0x3C] = 0x40; bytes[0x40] = 0x50; bytes[0x41] = 0x45
                bytes[0x44] = UInt8(machine & 0xFF); bytes[0x45] = UInt8(machine >> 8)
                try Data(bytes).write(to: dir.appendingPathComponent("\(folder)/Glow.dll"))
            }
            let output = dir.appendingPathComponent("Out")
            try fm.createDirectory(at: output, withIntermediateDirectories: true)

            let packager = SkinPackagerWindowController(app: app)
            defer { packager.close() }
            var messages: [(String, String)] = []
            packager.messageForTesting = { messages.append(($0, $1)) }
            let answers: [SkinPackagerWindowController.Choice: URL] = [
                .skin: app.skinsDirectory.appendingPathComponent("Deskset"),
                .plugin: dir.appendingPathComponent("64bit/Glow.dll"), .output: output,
            ]
            packager.chooseForTesting = { answers[$0] }

            packager.next()
            t.equal(packager.step, 1, "step 1 needs a name, an author and a skin")
            t.check(messages.last?.1.contains(packager.describe(.skinMissing)) ?? false, "\(messages)")
            packager.setSkin(answers[.skin]!)
            packager.addLayout(layout)
            packager.addPlugin(answers[.plugin]!)
            t.equal(packager.spec.plugins.count, 1)
            t.check(packager.spec.plugins.first?.x86 != nil, "the 32-bit version is found next to the 64-bit one")
            packager.edit { $0.author = "Tester"; $0.version = "2.1"; $0.outputDirectory = output }
            packager.next()
            t.equal(packager.step, 2)
            packager.back()
            t.equal(packager.step, 1, "Back returns to step 1 keeping everything")
            t.equal(packager.spec.layouts.count, 1)
            packager.next()

            packager.edit { $0.minimumRainmeter = "five" }
            packager.create()
            t.check(messages.last?.1.contains(packager.describe(.minimumVersionInvalid("five"))) ?? false,
                    "step 2's checks run on Create")
            packager.edit { $0.minimumRainmeter = "5.0"; $0.load = .layout("Desk") }
            packager.create()
            let package = output.appendingPathComponent("Deskset_2.1.rmskin")
            t.equal(packager.lastMessage?.title, "Package created")
            t.check(fm.fileExists(atPath: package.path), "the package is written")
            let inspection = try RmskinPackage.inspect(package)
            defer { inspection.cleanup() }
            t.equal(inspection.manifest.author, "Tester")
            t.equal(inspection.manifest.loadType, "Layout")
            t.equal(inspection.layouts, ["Desk"])
            t.equal(inspection.pluginNames, ["Glow.dll"])

            var asked = 0
            packager.confirmReplaceForTesting = { _ in asked += 1; return false }
            let before = try Data(contentsOf: package)
            try Data("keep".utf8).write(to: package)
            packager.create()
            t.equal(asked, 1, "an existing package is replaced only after asking")
            t.equal(try Data(contentsOf: package), Data("keep".utf8))
            packager.confirmReplaceForTesting = { _ in true }
            packager.create()
            t.equal((try Data(contentsOf: package)).count, before.count)

            t.equal(packager.history.entries.map(\.name), ["Deskset"], "Load previous remembers the package once")
            let fresh = SkinPackagerWindowController(app: app)
            defer { fresh.close() }
            t.equal(fresh.spec.name, "")
            fresh.loadPrevious(at: 0)
            t.equal(fresh.spec, packager.spec, "Load previous restores every setting")
        }

        t.suite("App: Skin Packager: Load previous keeps one entry per name, newest first") {
            let history = isolatedHistory()
            defer { history.restore() }
            let store = SkinPackagerHistory(storage: history.storage)
            for (name, version) in [("A", "1"), ("B", "1"), ("a", "2")] {
                var spec = RmskinPackageSpec()
                spec.name = name
                spec.version = version
                store.remember(spec)
            }
            t.equal(store.entries.map { "\($0.name) \($0.version)" }, ["a 2", "B 1"])
            store.forget(at: 1)
            t.equal(store.entries.map(\.name), ["a"])
            store.forget(at: 7)
            t.equal(store.entries.count, 1)
            for n in 0..<30 {
                var spec = RmskinPackageSpec()
                spec.name = "P\(n)"
                store.remember(spec)
            }
            t.equal(store.entries.count, SkinPackagerHistory.limit)
            t.equal(store.entries.first?.name, "P29")
        }

        t.suite("App: Skin Packager: every problem has a message") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let packager = SkinPackagerWindowController(app: app)
            defer { packager.close() }
            let problems: [RmskinPackagerProblem] = [
                .nameMissing, .authorMissing, .skinMissing, .skinWithoutSkins("S"), .layoutWithoutSettings("L"),
                .pluginIncomplete("P.dll"), .loadSkinNotFound("S\\a.ini"), .loadLayoutNotIncluded("L"), .headerNotBitmap,
                .headerWrongSize(width: 1, height: 2), .variableFileNotFound("S\\v.inc"), .mergeWithVariableFiles,
                .minimumVersionInvalid("x"), .outputMissing,
            ]
            let texts = problems.map(packager.describe)
            t.check(texts.allSatisfy { !$0.isEmpty })
            t.equal(Set(texts).count, texts.count, "distinct messages")
            t.check(texts[9].contains("1") && texts[9].contains("2"), texts[9])
            t.equal(problems.filter(SkinPackagerWindowController.isStepOne).count, 6)
        }
    }

    /// Load previous in memory, so the tests never read or change the user's preferences.
    private static func isolatedHistory() -> (storage: SkinPackagerHistory.Storage, restore: () -> Void) {
        let previous = SkinPackagerWindowController.historyStorage
        let storage = SkinPackagerHistory.Storage()
        SkinPackagerWindowController.historyStorage = storage
        return (storage, { SkinPackagerWindowController.historyStorage = previous })
    }
}
