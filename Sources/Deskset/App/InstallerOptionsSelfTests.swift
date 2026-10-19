import AppKit
import DesksetCore

/// Installer choices are checked through installed files and the skins that actually run afterwards.
enum InstallerOptionsSelfTests {
    static func run(_ t: AppTestRunner) {
        backupTests(t)
        loadTests(t)
        confirmationTests(t)
        controlsTests(t)
    }

    private static func backupTests(_ t: AppTestRunner) {
        t.suite("App: Installer options: modern merge and skin backups keep layout backups independent") {
            for merge in [false, true] {
                for backup in [false, true] {
                    let root = t.temporaryDirectory("installer-options-backup")
                    let skins = root.appendingPathComponent("Skins")
                    let layouts = root.appendingPathComponent("Layouts")
                    let backups = root.appendingPathComponent("Backups")
                    try write("[Rainmeter]\nUpdate=-1\n", to: skins.appendingPathComponent("Options/Card/Card.ini"))
                    try write("user extra", to: skins.appendingPathComponent("Options/user.txt"))
                    try write("[Variables]\nSize=99\n", to: skins.appendingPathComponent("Options/@Resources/Variables.inc"))
                    let oldLayout = "[Options\\Card]\nActive=1\nWindowX=11\n"
                    try write(oldLayout, to: layouts.appendingPathComponent("Desk/Rainmeter.ini"))
                    try write("keep this backup", to: backups.appendingPathComponent("Unrelated/old.txt"))
                    let package = try AppSelfTest.makePackage(t, name: "Options.rmskin", files: [
                        "RMSKIN.ini": data("[rmskin]\nName=Options\nMergeSkins=\(merge ? 1 : 0)\n"
                            + "VariableFiles=Options\\@Resources\\Variables.inc\n"),
                        "Skins/Options/Card/Card.ini": data(simpleSkin("Installed")),
                        "Skins/Options/@Resources/Variables.inc": data("[Variables]\nSize=12\nAdded=1\n"),
                        "Layouts/Desk/Rainmeter.ini": data("[Options\\Card]\nActive=1\nWindowX=22\n"),
                    ])
                    let result = try RmskinInstaller.install(packageURL: package, skinsDirectory: skins,
                        layoutsDirectory: layouts, backupDirectory: backups, backupSkins: backup)
                    let keepsSkinBackup = backup && !merge
                    let context = "merge=\(merge), backup=\(backup)"
                    let variables = try readIni(skins.appendingPathComponent("Options/@Resources/Variables.inc"))
                    t.equal(variables.section(named: "Variables")?["Size"], keepsSkinBackup ? "99" : "12", context)
                    t.equal(variables.section(named: "Variables")?["Added"], "1", context)
                    t.equal(result.preservedVariableCount, keepsSkinBackup ? 1 : 0, context)
                    t.equal(exists(skins.appendingPathComponent("Options/user.txt")), merge,
                            "\(context): merge keeps files that the package does not replace")
                    t.equal(exists(backups.appendingPathComponent("Options")), keepsSkinBackup, context)
                    if keepsSkinBackup {
                        t.equal(try text(backups.appendingPathComponent("Options/user.txt")), "user extra")
                    }
                    t.equal(try text(backups.appendingPathComponent("@Layouts/Desk/Rainmeter.ini")), oldLayout,
                            "\(context): Backup skins does not disable existing layout backups")
                    t.equal(try readIni(layouts.appendingPathComponent("Desk/Rainmeter.ini"))
                        .section(named: "Options\\Card")?["WindowX"], "22", context)
                    t.equal(try text(backups.appendingPathComponent("Unrelated/old.txt")), "keep this backup")
                    var expected = Set([backups.appendingPathComponent("@Layouts/Desk").path])
                    if keepsSkinBackup { expected.insert(backups.appendingPathComponent("Options").path) }
                    t.equal(Set(result.backupLocations.map(\.path)), expected, context)
                    t.equal(Set(try FileManager.default.contentsOfDirectory(atPath: skins.path)), ["Options"],
                            "\(context): no replacement staging folders remain")
                }
            }
        }
    }

    private static func loadTests(_ t: AppTestRunner) {
        t.suite("App: Installer options: declining the included skin still installs its files") {
            saveHooks(t)
            guard let app = try fixture(t) else { return }
            var loadAttempts = 0
            SkinInstallFlow.beforeLoadingPackageSkin = { _ in loadAttempts += 1 }
            SkinInstallFlow.optionsForTesting = { _, defaults in
                var options = defaults
                options.loadIncludedSkins = false
                return options
            }
            let package = try skinPackage(t, root: "Fresh")
            app.installer.open([package])
            guard finished(app, t) else { return }
            t.check(exists(app.skinsDirectory.appendingPathComponent("Fresh/Card/New.ini")))
            t.equal(app.controller(for: "Fresh\\Card"), nil)
            t.equal(app.controller(for: "Fresh\\Other"), nil)
            t.equal(loadAttempts, 0, "unchecked loading never begins the author-requested activation")
            t.check(app.config(named: "Fresh\\Card")?.files.contains("New.ini") == true,
                    "the installed skin is available for a later manual load")
        }

        for mode in [SkinThreading.main, .engine] {
            for loadIncluded in [false, true] {
                t.suite("App: Installer options: replacement loads one chosen variant, \(mode), load=\(loadIncluded)") {
                    saveHooks(t)
                    guard let app = try fixture(t, threading: mode) else { return }
                    try write(countedSkin("Old disk version"),
                              to: app.skinsDirectory.appendingPathComponent("Replace/Card/Old.ini"))
                    app.rescanLibrary()
                    guard let observer = app.activate(config: "App\\Observer", file: "Observer.ini"),
                          let old = app.activate(config: "Replace\\Card", file: "Old.ini") else {
                        return t.check(false, "the old variant and observer activate")
                    }
                    guard AppSelfTest.spin(timeout: 30, until: { observer.isStarted && old.isStarted }) else {
                        return t.check(false, "the old desktop starts")
                    }
                    t.close(count(observer, "MeasureLoads"), 2)
                    var authorLoads = 0
                    SkinInstallFlow.beforeLoadingPackageSkin = { _ in authorLoads += 1 }
                    if !loadIncluded {
                        SkinInstallFlow.optionsForTesting = { _, defaults in
                            var options = defaults
                            options.loadIncludedSkins = false
                            return options
                        }
                    }
                    let package = try skinPackage(t, root: "Replace", counted: true)
                    app.installer.open([package])
                    guard finished(app, t), let current = app.controller(for: "Replace\\Card") else {
                        return t.check(false, "a replaced running config is restored")
                    }
                    t.check(current !== old && old.hasClosed, "the old instance closes before replacement")
                    t.equal(current.file, loadIncluded ? "New.ini" : "Old.ini")
                    t.close(count(observer, "MeasureLoads"), 3, "only one replacement instance ran OnRefreshAction")
                    t.close(count(observer, "MeasureCloses"), 2, "only the original instance ran OnCloseAction")
                    t.equal(authorLoads, loadIncluded ? 1 : 0)
                    t.equal(app.controller(for: "Replace\\Other"), nil, "other packaged skins are not auto-loaded")
                    t.check(try text(current.fileURL).contains(loadIncluded ? "New package version" : "Old package version"),
                            "the restored variant uses the newly installed file")
                    t.check(exists(app.backupsDirectory.appendingPathComponent("Replace/Card/Old.ini")),
                            "the default backup choice still applies when loading is declined")
                }
            }
        }
    }

    private static func confirmationTests(_ t: AppTestRunner) {
        t.suite("App: Installer options: cancelling confirmation leaves files, running skins and state untouched") {
            saveHooks(t)
            guard let app = try fixture(t) else { return }
            let file = app.skinsDirectory.appendingPathComponent("Cancelled/Card/Old.ini")
            try write(simpleSkin("User version"), to: file)
            app.rescanLibrary()
            guard let running = app.activate(config: "Cancelled\\Card", file: "Old.ini") else {
                return t.check(false, "the existing skin starts")
            }
            app.state.saveNow()
            let savedState = try Data(contentsOf: app.state.fileURL)
            let oldFile = try Data(contentsOf: file)
            var confirmations = 0
            SkinInstallFlow.confirmForTesting = { _, _ in confirmations += 1; return false }
            let package = try skinPackage(t, root: "Cancelled")
            app.installer.open([package])
            guard finished(app, t) else { return }
            app.state.saveNow()
            t.equal(confirmations, 1)
            t.check(app.controller(for: "Cancelled\\Card") === running && !running.isStopped)
            t.equal(try Data(contentsOf: file), oldFile)
            t.check(!exists(app.skinsDirectory.appendingPathComponent("Cancelled/Card/New.ini")))
            t.check(!exists(app.backupsDirectory.appendingPathComponent("Cancelled")))
            t.equal(try Data(contentsOf: app.state.fileURL), savedState)
        }

        t.suite("App: Installer options: each queued package starts with fresh choices") {
            saveHooks(t)
            guard let app = try fixture(t) else { return }
            for root in ["First", "Second"] {
                try write(simpleSkin("Old"), to: app.skinsDirectory.appendingPathComponent("\(root)/Card/Old.ini"))
                try write("[Variables]\nSize=99\n", to: app.skinsDirectory.appendingPathComponent("\(root)/@Resources/Variables.inc"))
            }
            app.rescanLibrary()
            var defaultsSeen: [SkinInstallFlow.Options] = []
            SkinInstallFlow.optionsForTesting = { _, defaults in
                defaultsSeen.append(defaults)
                guard defaultsSeen.count == 1 else { return defaults }
                var options = defaults
                options.loadIncludedSkins = false
                options.applyIncludedLayout = false
                options.backupSkins = false
                return options
            }
            let first = try skinPackage(t, root: "First", variables: true)
            let second = try skinPackage(t, root: "Second", variables: true)
            app.installer.open([first, second])
            guard finished(app, t) else { return }
            t.equal(defaultsSeen, [SkinInstallFlow.Options(), SkinInstallFlow.Options()])
            t.equal(app.controller(for: "First\\Card"), nil)
            t.equal(app.controller(for: "Second\\Card")?.file, "New.ini")
            t.check(!exists(app.backupsDirectory.appendingPathComponent("First")))
            t.check(exists(app.backupsDirectory.appendingPathComponent("Second/Card/Old.ini")))
            t.equal(try readIni(app.skinsDirectory.appendingPathComponent("First/@Resources/Variables.inc"))
                .section(named: "Variables")?["Size"], "12")
            t.equal(try readIni(app.skinsDirectory.appendingPathComponent("Second/@Resources/Variables.inc"))
                .section(named: "Variables")?["Size"], "99")
        }

        t.suite("App: Installer options: declining an included layout keeps the desktop and installs the layout") {
            saveHooks(t)
            guard let app = try fixture(t),
                  let old = app.activate(config: "App\\Observer", file: "Observer.ini") else { return }
            SkinInstallFlow.optionsForTesting = { _, defaults in
                var options = defaults
                options.applyIncludedLayout = false
                options.backupSkins = false
                return options
            }
            let package = try AppSelfTest.makePackage(t, name: "Layout.rmskin", files: [
                "RMSKIN.ini": data("[rmskin]\nName=Layout\nLoadType=Layout\nLoad=Included\n"),
                "Skins/LayoutChoice/Card/Card.ini": data(simpleSkin("Layout card")),
                "Layouts/Included/Rainmeter.ini": data("[LayoutChoice\\Card]\nActive=1\n"),
            ])
            app.installer.open([package])
            guard finished(app, t) else { return }
            t.check(app.controller(for: "App\\Observer") === old && !old.isStopped)
            t.equal(app.controller(for: "LayoutChoice\\Card"), nil)
            t.check(app.layoutStore.contains(named: "Included"))
            t.check(!app.layoutStore.contains(named: "@Backup"), "declining the layout never replaces the desktop")
            t.check(exists(app.skinsDirectory.appendingPathComponent("LayoutChoice/Card/Card.ini")))
        }
    }

    private static func controlsTests(_ t: AppTestRunner) {
        t.suite("App: Installer options: load choices and Advanced backup controls fit both appearances") {
            let root = t.temporaryDirectory("installer-options-controls")
            let skinArchive = try skinPackage(t, root: "Controls")
            let layoutPackage = try AppSelfTest.makePackage(t, name: "LayoutControls.rmskin", files: [
                "RMSKIN.ini": data("[rmskin]\nName=Layout controls\nLoadType=Layout\nLoad=Included\n"),
                "Skins/Controls/Card/Card.ini": data(simpleSkin("Card")),
                "Layouts/Included/Rainmeter.ini": data("[Controls\\Card]\nActive=1\n"),
            ])
            for (package, hasLayout) in [(skinArchive, false), (layoutPackage, true)] {
                let inspection = try RmskinPackage.inspect(package)
                defer { inspection.cleanup() }
                let summary = InstallSummary(inspection, packageName: package.lastPathComponent, skinsDirectory: root)
                let controls = SkinInstallFlow.OptionControls(summary: summary, options: SkinInstallFlow.Options())
                t.equal(controls.loadLayoutCheckbox != nil, hasLayout)
                t.equal(controls.loadSkinsCheckbox != nil, !hasLayout)
                t.equal(controls.options, SkinInstallFlow.Options())
                t.check(controls.advancedButton.accessibilityLabel()?.isEmpty == false,
                        "Advanced options have an accessible name")
                var noLoadSummary = summary
                noLoadSummary.loadAfterInstall = nil
                noLoadSummary.layoutToApply = nil
                let noLoad = SkinInstallFlow.OptionControls(summary: noLoadSummary)
                t.equal(noLoad.loadSkinsCheckbox, nil)
                t.equal(noLoad.loadLayoutCheckbox, nil)
                t.equal(noLoad.backupSkinsItem.state, .on)
                let loadBox = hasLayout ? controls.loadLayoutCheckbox : controls.loadSkinsCheckbox
                guard let loadBox else { return t.check(false, "the package has its matching load checkbox") }
                loadBox.performClick(nil)
                t.equal(hasLayout ? controls.options.applyIncludedLayout : controls.options.loadIncludedSkins, false)
                let backupItem = controls.backupSkinsItem
                guard let action = backupItem.action else { return t.check(false, "Backup skins is actionable") }
                t.check(NSApp.sendAction(action, to: backupItem.target, from: backupItem))
                t.equal(controls.options.backupSkins, false)
                t.equal(backupItem.state, .off)
                let body = SkinInstallFlow.accessoryView(summary, headerImage: nil, optionControls: controls)
                let window = NSWindow(contentRect: body.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = body
                defer { window.close() }
                let accessibleLoad = NSAccessibility.unignoredDescendant(of: loadBox) as? NSAccessibilityProtocol
                t.equal(accessibleLoad?.accessibilityRole(), .checkBox)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: appearance)
                    body.layoutSubtreeIfNeeded()
                    for control in [loadBox, controls.advancedButton] {
                        let frame = control.convert(control.bounds, to: body)
                        t.check(frame.width > 0 && frame.height > 0 && body.bounds.contains(frame),
                                "\(appearance.rawValue): installer choices are fully visible")
                    }
                    guard let bitmap = body.bitmapImageRepForCachingDisplay(in: body.bounds) else {
                        return t.check(false, "the confirmation can be rendered offscreen")
                    }
                    body.cacheDisplay(in: body.bounds, to: bitmap)
                    t.check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "offscreen rendering is independent of backing scale")
                }
            }
        }
    }

    private static func saveHooks(_ t: AppTestRunner) {
        let options = SkinInstallFlow.optionsForTesting
        let confirm = SkinInstallFlow.confirmForTesting
        let layout = SkinInstallFlow.applyLayoutAfterInstallForTesting
        let loading = SkinInstallFlow.beforeLoadingPackageSkin
        SkinInstallFlow.optionsForTesting = nil
        SkinInstallFlow.confirmForTesting = nil
        SkinInstallFlow.applyLayoutAfterInstallForTesting = nil
        SkinInstallFlow.beforeLoadingPackageSkin = nil
        t.atSuiteEnd {
            SkinInstallFlow.optionsForTesting = options
            SkinInstallFlow.confirmForTesting = confirm
            SkinInstallFlow.applyLayoutAfterInstallForTesting = layout
            SkinInstallFlow.beforeLoadingPackageSkin = loading
        }
    }

    private static func fixture(_ t: AppTestRunner, threading: SkinThreading = .main) throws -> AppController? {
        guard let app = try AppSelfTest.makeApp(t, threading: threading) else { return nil }
        t.atSuiteEnd { app.stopAllForTermination(); app.endEngineThread() }
        return app
    }

    private static func finished(_ app: AppController, _ t: AppTestRunner) -> Bool {
        let done = AppSelfTest.spin(timeout: 30) { app.installer.isIdle && !app.isLoadingLayout }
        t.check(done, "the install queue and any requested layout finish")
        return done
    }

    private static func skinPackage(_ t: AppTestRunner, root: String, counted: Bool = false,
                                    variables: Bool = false) throws -> URL {
        let skin: (String) -> String = counted ? countedSkin : simpleSkin
        var files = [
            "RMSKIN.ini": data("[rmskin]\nName=\(root)\nLoadType=Skin\nLoad=\(root)\\Card\\New.ini\n"
                + (variables ? "VariableFiles=\(root)\\@Resources\\Variables.inc\n" : "")),
            "Skins/\(root)/Card/Old.ini": data(skin("Old package version")),
            "Skins/\(root)/Card/New.ini": data(skin("New package version")),
            "Skins/\(root)/Other/Other.ini": data(simpleSkin("Not requested")),
        ]
        if variables { files["Skins/\(root)/@Resources/Variables.inc"] = data("[Variables]\nSize=12\n") }
        return try AppSelfTest.makePackage(t, name: root + ".rmskin", files: files)
    }

    private static func simpleSkin(_ text: String) -> String {
        "[Rainmeter]\nUpdate=-1\n[M]\nMeter=String\nText=\(text)\n"
    }

    private static func countedSkin(_ text: String) -> String {
        "[Rainmeter]\nUpdate=-1\n"
            + "OnRefreshAction=[!UpdateMeasure MeasureLoads \"App\\Observer\"]\n"
            + "OnCloseAction=[!UpdateMeasure MeasureCloses \"App\\Observer\"]\n"
            + "[M]\nMeter=String\nText=\(text)\n"
    }

    private static func count(_ controller: SkinWindowController, _ name: String) -> Double {
        controller.runtime.exclusive(timeout: 30) { $0.measure(named: name)?.value ?? -1 } ?? -1
    }

    private static func data(_ text: String) -> Data { Data(text.utf8) }
    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private static func text(_ url: URL) throws -> String { try TextDecoding.readFile(at: url) }
    private static func readIni(_ url: URL) throws -> IniDocument { IniDocument.parse(try text(url)) }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
