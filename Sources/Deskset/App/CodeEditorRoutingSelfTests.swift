import AppKit
import DesksetCore

/// Settings ▸ Editor, the code-editor catalog and `CodeEditorRouter` (docs/editor-design.md §6). Apps are never
/// launched: Launch Services answers come from `FakeLocator`, opening goes to `RecordingOpener`, and the fake editors
/// are folders in a temporary directory. User defaults are an in-memory store (`MemoryKeyValueStore`), never a real
/// domain.
enum CodeEditorRoutingSelfTests {
    static func run(_ t: AppTestRunner) {
        commandTests(t)
        preferenceTests(t)
        detectionTests(t)
        routingTests(t)
        configEditorTests(t)
        settingsWindowTests(t)
        miscTests(t)
    }

    // MARK: Fakes

    final class FakeLocator: ApplicationLocating {
        var apps: [String: URL] = [:]
        var claimers: [URL] = []
        var defaultApp: URL?
        var ids: [String: String] = [:]

        func applicationURL(bundleID: String) -> URL? {
            apps.first { $0.key.caseInsensitiveCompare(bundleID) == .orderedSame }?.value
        }
        func applicationURLs(toOpenExtension ext: String) -> [URL] { claimers }
        func defaultApplicationURL(toOpen file: URL) -> URL? { defaultApp }
        func bundleIdentifier(ofApplicationAt url: URL) -> String? {
            ids[url.standardizedFileURL.path] ?? apps.first { $0.value.standardizedFileURL.path == url.standardizedFileURL.path }?.key
        }
        /// Drawn here: the icon service is asked nothing about the fake bundles (on CI's Intel runner it never answered,
        /// and drawing a pop-up menu's icon waits for it on the main thread).
        func icon(ofApplicationAt url: URL) -> NSImage {
            NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
                return true
            }
        }
    }

    final class RecordingOpener: CodeEditorOpening {
        var opened: [(urls: [URL], app: URL)] = []
        var runs: [(executable: URL, arguments: [String])] = []
        /// URLs with these schemes fail to open (an editor too old for its line URL).
        var failingSchemes: Set<String> = []

        func open(_ urls: [URL], withApplicationAt app: URL, completion: @escaping (Error?) -> Void) {
            opened.append((urls, app))
            let fails = urls.contains { failingSchemes.contains($0.scheme ?? "") }
            completion(fails ? CocoaError(.featureUnsupported) : nil)
        }

        func run(_ executable: URL, arguments: [String]) throws {
            runs.append((executable, arguments))
        }
    }

    /// A folder that looks like an app bundle (with a VS Code-style product.json when `product` is given).
    @discardableResult
    static func fakeApp(_ dir: URL, _ name: String, product: [String: String]? = nil) -> URL {
        let app = dir.appendingPathComponent("\(name).app", isDirectory: true)
        try? FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources/app"),
                                                 withIntermediateDirectories: true)
        if let product, let data = try? JSONSerialization.data(withJSONObject: product) {
            try? data.write(to: VSCodeProduct.productURL(appURL: app))
        }
        return app
    }

    /// Runs `body` with the router's locator and opener replaced, restoring them afterwards.
    static func withFakes(_ locator: FakeLocator, _ opener: RecordingOpener, _ body: () throws -> Void) rethrows {
        let (oldLocator, oldOpener, oldApp) = (CodeEditorRouter.locator, CodeEditorRouter.opener, CodeEditorRouter.primaryApp)
        CodeEditorRouter.locator = locator
        CodeEditorRouter.opener = opener
        defer {
            CodeEditorRouter.locator = oldLocator
            CodeEditorRouter.opener = oldOpener
            CodeEditorRouter.primaryApp = oldApp
        }
        try body()
    }

    // MARK: Commands

    static func commandTests(_ t: AppTestRunner) {
        t.suite("App: code editor open-at-line commands") {
            let dir = t.temporaryDirectory("editors")
            let file = URL(fileURLWithPath: "/Users/me/My Skins/System.ini")
            let spacePath = "/Users/me/My%20Skins/System.ini"
            func command(_ family: EditorFamily, _ app: URL, line: Int? = 29) -> CodeEditorCommand {
                CodeEditorLaunch.command(family: family, appURL: app, file: file, line: line)
            }
            func link(_ text: String, _ app: URL) -> CodeEditorCommand { .open([URL(string: text)!], app: app) }

            // A VS Code fork nobody listed, recognised by its product.json.
            let forky = fakeApp(dir, "Forky", product: ["urlProtocol": "forky", "applicationName": "forky"])
            let forkyFamily = CodeEditorCatalog.family(bundleID: "com.example.forky", appURL: forky)
            t.equal(forkyFamily, .vsCode(urlProtocol: "forky", applicationName: "forky"))
            t.equal(command(forkyFamily, forky), link("forky://file\(spacePath):29", forky))
            t.equal(command(forkyFamily, forky, line: nil), .open([file], app: forky), "no line: just the file")
            t.equal(command(forkyFamily, forky, line: 0), .open([file], app: forky))
            let hash = CodeEditorLaunch.command(family: forkyFamily, appURL: forky,
                                                file: URL(fileURLWithPath: "/tmp/a#b?.ini"), line: 3)
            t.equal(hash, link("forky://file/tmp/a%23b%3F.ini:3", forky), "# and ? are encoded in the path")
            // Antigravity IDE is a VS Code fork with its own scheme.
            let agy = fakeApp(dir, "Antigravity IDE", product: ["urlProtocol": "antigravity-ide",
                                                                "applicationName": "antigravity-ide"])
            t.equal(command(CodeEditorCatalog.family(bundleID: "com.google.antigravity-ide", appURL: agy), agy),
                    link("antigravity-ide://file\(spacePath):29", agy))
            // Listed without product.json: the catalog's scheme.
            let code = fakeApp(dir, "Visual Studio Code")
            t.equal(CodeEditorCatalog.family(bundleID: "com.microsoft.VSCode", appURL: code),
                    .vsCode(urlProtocol: "vscode", applicationName: nil))
            t.equal(command(CodeEditorCatalog.family(bundleID: "com.microsoft.VSCode", appURL: code), code),
                    link("vscode://file\(spacePath):29", code))
            // A fork whose product.json has no usable scheme: its bundled CLI.
            let cliOnly = fakeApp(dir, "CliOnly", product: ["urlProtocol": "bad scheme!", "applicationName": "clionly"])
            let cliFamily = CodeEditorCatalog.family(bundleID: nil, appURL: cliOnly)
            t.equal(cliFamily, .vsCode(urlProtocol: nil, applicationName: "clionly"))
            t.equal(command(cliFamily, cliOnly),
                    .run(executable: cliOnly.appendingPathComponent("Contents/Resources/app/bin/clionly"),
                         arguments: ["--goto", "/Users/me/My Skins/System.ini:29"]))
            let sneaky = fakeApp(dir, "Sneaky", product: ["applicationName": "../../evil"])
            t.equal(CodeEditorCatalog.family(bundleID: nil, appURL: sneaky), .plain, "a CLI name cannot leave bin/")

            let zed = fakeApp(dir, "Zed")
            t.equal(CodeEditorCatalog.family(bundleID: "dev.zed.Zed-Preview", appURL: zed), .zed)
            t.equal(CodeEditorCatalog.family(bundleID: "dev.zed.Zed-Future", appURL: zed), .zed, "prefix")
            t.equal(command(.zed, zed), link("zed://file\(spacePath):29", zed))

            let bbedit = fakeApp(dir, "BBEdit")
            t.equal(CodeEditorCatalog.family(bundleID: "com.barebones.bbedit", appURL: bbedit), .bbEdit)
            t.equal(command(.bbEdit, bbedit),
                    link("x-bbedit://open?url=file:///Users/me/My%2520Skins/System.ini&line=29", bbedit))
            let textMate = fakeApp(dir, "TextMate")
            t.equal(command(.textMate, textMate),
                    link("txmt://open?url=file:///Users/me/My%2520Skins/System.ini&line=29", textMate))
            let nova = fakeApp(dir, "Nova")
            t.equal(command(.nova, nova), link("nova://open?path=\(spacePath)&line=29", nova))
            let amp = CodeEditorLaunch.command(family: .nova, appURL: nova, file: URL(fileURLWithPath: "/tmp/a&b=c.ini"),
                                               line: 2)
            t.equal(amp, link("nova://open?path=/tmp/a%26b%3Dc.ini&line=2", nova), "& and = cannot end the value")

            let webStorm = fakeApp(dir, "WebStorm")
            t.equal(CodeEditorCatalog.family(bundleID: "com.jetbrains.WebStorm", appURL: webStorm), .jetBrains)
            t.equal(CodeEditorCatalog.family(bundleID: "com.jetbrains.datagrip", appURL: webStorm), .jetBrains, "prefix")
            t.equal(CodeEditorCatalog.family(bundleID: "com.jetbrains.toolbox", appURL: webStorm), .plain, "not an IDE")
            t.equal(CodeEditorCatalog.family(bundleID: "com.google.android.studio", appURL: webStorm), .jetBrains)
            t.equal(command(.jetBrains, webStorm), link("idea://open?file=\(spacePath)&line=29", webStorm))

            let macVim = fakeApp(dir, "MacVim")
            t.equal(command(.macVim, macVim),
                    link("mvim://open?url=file:///Users/me/My%2520Skins/System.ini&line=29", macVim),
                    "special characters double-encoded")

            let sublime = fakeApp(dir, "Sublime Text")
            t.equal(CodeEditorCatalog.family(bundleID: "com.sublimetext.4", appURL: sublime), .sublime)
            t.equal(command(.sublime, sublime),
                    .run(executable: sublime.appendingPathComponent("Contents/SharedSupport/bin/subl"),
                         arguments: ["/Users/me/My Skins/System.ini:29"]))
            let cot = fakeApp(dir, "CotEditor")
            t.equal(command(.cotEditor, cot),
                    .run(executable: cot.appendingPathComponent("Contents/SharedSupport/bin/cot"),
                         arguments: ["--line", "29", "/Users/me/My Skins/System.ini"]))
            let xcode = fakeApp(dir, "Xcode")
            t.equal(CodeEditorCatalog.family(bundleID: "com.apple.dt.Xcode", appURL: xcode), .xcode)
            t.equal(command(.xcode, xcode),
                    .run(executable: xcode.appendingPathComponent("Contents/Developer/usr/bin/xed"),
                         arguments: ["--line", "29", "/Users/me/My Skins/System.ini"]), "the chosen Xcode's own xed")

            let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            t.equal(CodeEditorCatalog.family(bundleID: "com.apple.TextEdit", appURL: textEdit), .textEdit)
            t.equal(command(.textEdit, textEdit), .open([file], app: textEdit), "TextEdit has no line support")
            t.check(!EditorFamily.textEdit.jumpsToLine && !EditorFamily.plain.jumpsToLine)
            t.check(EditorFamily.zed.jumpsToLine && forkyFamily.jumpsToLine && forkyFamily.confirmsURLOpens)
            t.check(!EditorFamily.vsCode(urlProtocol: nil, applicationName: nil).jumpsToLine)
            t.equal(CodeEditorCatalog.family(bundleID: "com.example.unknown", appURL: dir), .plain)
            t.equal(CodeEditorCatalog.family(bundleID: nil, appURL: dir), .plain)
            // The agent hub app is not an editor; the IDE is listed under its own identifier.
            t.check(CodeEditorCatalog.isExcluded("com.google.antigravity"))
            t.check(CodeEditorCatalog.entries.contains { $0.bundleIDs.contains("com.google.antigravity-ide") })
            t.check(!CodeEditorCatalog.entries.contains { $0.bundleIDs.contains("com.google.antigravity") })
        }
    }

    // MARK: Preferences

    static func preferenceTests(_ t: AppTestRunner) {
        t.suite("App: editor preferences in state.json") {
            let dir = t.temporaryDirectory("editorprefs")
            let d = EditorPreferences()
            t.equal(d.codeEditor, .builtIn, "the built-in editor is the default")
            t.equal([d.liveReload, d.showIniNames], [true, false])
            t.equal(d.openSkinsIn, .design)
            t.equal(d.codeFontSize, 12)

            // Existing users (a state file from before Settings) get the built-in editor too.
            let old = dir.appendingPathComponent("old.json")
            try #"{"skins": {"A\\B": {"file": "B.ini"}}, "defaultSkinsInstalled": 2}"#.write(to: old, atomically: true, encoding: .utf8)
            let oldState = AppState(fileURL: old)
            t.equal(oldState.editor, EditorPreferences())
            t.equal(oldState.skin("A\\B")?.file, "B.ini")
            t.check(!oldState.data.hasEditorPreferences)

            // Round trip.
            let url = dir.appendingPathComponent("state.json")
            let state = AppState(fileURL: url)
            var posted = 0
            let token = NotificationCenter.default.addObserver(forName: .desksetEditorPreferencesChanged, object: state,
                                                               queue: nil) { _ in posted += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            state.updateEditor {
                $0.codeEditor = .app(bundleID: "com.example.forky", lastKnownPath: "/Applications/Forky.app")
                $0.openSkinsIn = .split
                $0.showIniNames = true
                $0.codeFontSize = 15
                $0.liveReload = false
                $0.otherApp = .init(bundleID: "com.example.other", path: "/Applications/Other.app")
            }
            state.updateEditor { $0.showIniNames = true }
            t.equal(posted, 1, "one notification per actual change")
            state.setSettingsPane("editor")
            state.saveNow()
            let reloaded = AppState(fileURL: url)
            t.equal(reloaded.editor, state.editor)
            t.equal(reloaded.data.settingsPane, "editor")
            t.check(reloaded.data.hasEditorPreferences)
            state.updateEditor { $0.codeFontSize = 500 }
            t.equal(state.editor.codeFontSize, 32, "clamped")
            state.updateEditor { $0.codeEditor = .systemDefault }
            state.saveNow()
            t.equal(AppState(fileURL: url).editor.codeEditor, .systemDefault)

            // Tolerant decoding: unknown kinds, wrong types and out-of-range values keep defaults.
            func decode(_ editorJSON: String) -> AppState {
                let f = dir.appendingPathComponent("t-\(UUID().uuidString).json")
                try? #"{"skins": {"X": {"file": "X.ini"}}, "editor": \#(editorJSON)}"#.write(to: f, atomically: true, encoding: .utf8)
                return AppState(fileURL: f)
            }
            let odd = decode(#"{"codeEditor": {"kind": "emacs"}, "codeFontSize": "big", "openSkinsIn": "SPLIT", "liveReload": false, "future": 1}"#)
            t.equal(odd.editor.codeEditor, .builtIn)
            t.equal(odd.editor.codeFontSize, 12)
            t.equal(odd.editor.openSkinsIn, .split, "case-insensitive")
            t.equal(odd.editor.liveReload, false)
            t.equal(odd.skin("X")?.file, "X.ini", "the rest of the file still loads")
            t.equal(decode(#"{"codeEditor": "vscode"}"#).editor.codeEditor, .builtIn)
            t.equal(decode(#"{"codeEditor": {"kind": "app", "bundleID": "", "path": ""}}"#).editor.codeEditor, .builtIn)
            t.equal(decode(#"{"codeEditor": {"kind": "App", "bundleID": "com.x"}}"#).editor.codeEditor,
                    .app(bundleID: "com.x", lastKnownPath: ""))
            t.equal(decode(#"{"codeEditor": {"kind": "systemDefault"}, "codeFontSize": 3}"#).editor,
                    { var e = EditorPreferences(); e.codeEditor = .systemDefault; e.codeFontSize = 9; return e }())
            let broken = decode("5")
            t.equal(broken.editor, EditorPreferences())
            t.check(!broken.data.hasEditorPreferences)
            t.equal(broken.skin("X")?.file, "X.ini")
        }

        t.suite("App: studio state in state.json (tips seen, editor locks, unlocked backgrounds)") {
            let dir = t.temporaryDirectory("studioprefs")
            let d = EditorPreferences()
            t.equal(d.seenTips, [])
            t.equal(d.editorLocks, [:])
            t.equal(d.unlockedBackgrounds, [])
            t.equal(d.showsContentOutside, true)

            let url = dir.appendingPathComponent("state.json")
            let state = AppState(fileURL: url)
            state.updateEditor {
                $0.seenTips = ["T1", "T3"]
                $0.editorLocks = ["audio\\visualizer": ["meterbackground", "metertitle"]]
                $0.unlockedBackgrounds = ["deskset\\system"]
                $0.showsContentOutside = false
            }
            state.saveNow()
            t.equal(AppState(fileURL: url).editor, state.editor, "round trip")

            // Tolerant: a wrong type keeps that preference's default and loses nothing else.
            let f = dir.appendingPathComponent("odd.json")
            try #"{"editor": {"showIniNames": true, "seenTips": "T1", "editorLocks": {"a": 5}, "unlockedBackgrounds": ["b"], "showsContentOutside": "no"}}"#
                .write(to: f, atomically: true, encoding: .utf8)
            let odd = AppState(fileURL: f).editor
            t.equal(odd.seenTips, [])
            t.equal(odd.editorLocks, [:])
            t.equal(odd.unlockedBackgrounds, ["b"])
            t.equal(odd.showsContentOutside, true)
            t.equal(odd.showIniNames, true)
        }

        t.suite("App: live reload moves from UserDefaults once") {
            // An in-memory store: a UserDefaults suite would leave a file in ~/Library/Preferences.
            let defaults = MemoryKeyValueStore()
            let dir = t.temporaryDirectory("migration")
            let url = dir.appendingPathComponent("state.json")
            try #"{"skins": {}}"#.write(to: url, atomically: true, encoding: .utf8)

            defaults.set(false, forKey: EditorPreferences.legacyLiveReloadKey)
            let state = AppState(fileURL: url)
            t.equal(state.editor.liveReload, true)
            state.migrateLegacyEditorPreferences(from: defaults)
            t.equal(state.editor.liveReload, false, "carried over")
            state.saveNow()
            let raw = try String(contentsOf: url, encoding: .utf8)
            t.check(raw.contains("\"liveReload\" : false"), "stored in state.json")

            // Once: afterwards the old key is ignored.
            defaults.set(true, forKey: EditorPreferences.legacyLiveReloadKey)
            let next = AppState(fileURL: url)
            next.migrateLegacyEditorPreferences(from: defaults)
            t.equal(next.editor.liveReload, false)
            state.updateEditor { $0.liveReload = true }
            state.migrateLegacyEditorPreferences(from: defaults)
            t.equal(state.editor.liveReload, true)

            // Nothing stored in UserDefaults: the default stays.
            let fresh = AppState(fileURL: dir.appendingPathComponent("fresh.json"))
            defaults.removeObject(forKey: EditorPreferences.legacyLiveReloadKey)
            fresh.migrateLegacyEditorPreferences(from: defaults)
            t.equal(fresh.editor.liveReload, true)
        }
    }

    // MARK: Detection

    static func detectionTests(_ t: AppTestRunner) {
        t.suite("App: installed code editors") {
            let dir = t.temporaryDirectory("detect")
            let locator = FakeLocator()
            let code = fakeApp(dir, "Visual Studio Code", product: ["urlProtocol": "vscode", "applicationName": "code"])
            let zed = fakeApp(dir, "Zed")
            let hub = fakeApp(dir, "Antigravity")
            let ide = fakeApp(dir, "Antigravity IDE", product: ["urlProtocol": "antigravity-ide"])
            let claimer = fakeApp(dir, "Ini Pad")
            let own = fakeApp(dir, "Deskset Copy")
            let other = fakeApp(dir, "Other Editor")
            locator.apps = ["com.microsoft.VSCode": code, "dev.zed.Zed": zed, "com.google.antigravity-ide": ide]
            locator.claimers = [ide, code, hub, claimer, own]
            locator.ids = [hub.path: "com.google.antigravity", claimer.path: "com.example.inipad",
                           own.path: "com.example.deskset", other.path: "com.example.other"]
            var prefs = EditorPreferences()
            prefs.otherApp = .init(bundleID: "com.example.other", path: other.path)
            let found = CodeEditorDetector.detect(preferences: prefs, locator: locator, ownBundleID: "com.example.deskset")
            t.equal(found.map(\.name), ["Antigravity IDE", "Ini Pad", "Other Editor", "Visual Studio Code", "Zed"],
                    "catalog ∪ claimers ∪ Other…, sorted, without the hub app or Deskset, each once")
            t.equal(found.first?.family, .vsCode(urlProtocol: "antigravity-ide", applicationName: "antigravity-ide"),
                    "a product.json without the CLI name keeps the catalog's")
            t.equal(found.first { $0.name == "Ini Pad" }?.family, .plain)

            // Stored apps: the picked copy while it exists, else by bundle identifier, else gone.
            t.equal(CodeEditorDetector.resolve(bundleID: "dev.zed.Zed", lastKnownPath: zed.path, locator: locator), zed)
            t.equal(CodeEditorDetector.resolve(bundleID: "dev.zed.Zed", lastKnownPath: "/nowhere/Zed.app", locator: locator), zed)
            t.equal(CodeEditorDetector.resolve(bundleID: "", lastKnownPath: other.path, locator: locator), other)
            t.equal(CodeEditorDetector.resolve(bundleID: "com.example.gone", lastKnownPath: "/nowhere/Gone.app",
                                               locator: locator), nil)
            // A path now holding another app is not the stored one.
            t.equal(CodeEditorDetector.resolve(bundleID: "com.example.inipad", lastKnownPath: other.path, locator: locator), nil)
            locator.defaultApp = ide
            t.equal(CodeEditorDetector.systemDefaultApp(locator: locator)?.name, "Antigravity IDE")

            // What this Mac has (printed, not asserted).
            let real = CodeEditorDetector.detect(preferences: EditorPreferences(), locator: WorkspaceApplicationLocator())
            let summary = real.map { "\($0.name) [\($0.bundleID ?? "?")\($0.family.jumpsToLine ? ", line" : "")]" }
            print("    editors on this Mac: " + (summary.isEmpty ? "none" : summary.joined(separator: ", ")))
            print("    .ini default: " + (CodeEditorDetector.systemDefaultApp(locator: WorkspaceApplicationLocator())?.name ?? "none"))
        }
    }

    // MARK: Routing

    static func routingTests(_ t: AppTestRunner) {
        t.suite("App: code editor routing decisions") {
            let dir = t.temporaryDirectory("route")
            let locator = FakeLocator()
            let forky = fakeApp(dir, "Forky", product: ["urlProtocol": "forky"])
            let own = fakeApp(dir, "Deskset")
            locator.apps = ["com.example.forky": forky]
            let file = URL(fileURLWithPath: "/tmp/Skin/Skin.ini")
            func route(_ choice: EditorPreferences.CodeEditor, line: Int? = 4) -> CodeEditorRouter.Route {
                var p = EditorPreferences()
                p.codeEditor = choice
                return CodeEditorRouter.route(file: file, line: line, preferences: p, locator: locator, ownBundle: own,
                                              ownBundleID: "com.example.deskset")
            }
            t.equal(route(.builtIn), .builtIn)
            let forkyEditor = CodeEditorApp(url: forky, bundleID: "com.example.forky")
            t.equal(route(.app(bundleID: "com.example.forky", lastKnownPath: forky.path)),
                    .external(forkyEditor, .open([URL(string: "forky://file/tmp/Skin/Skin.ini:4")!], app: forky)))
            t.equal(route(.app(bundleID: "com.example.gone", lastKnownPath: "/nowhere/Gone.app")),
                    .builtInInstead(missingApp: "Gone"))
            t.equal(route(.app(bundleID: "com.example.deskset", lastKnownPath: own.path)), .builtIn, "Deskset itself")
            locator.defaultApp = forky
            t.equal(route(.systemDefault), .external(forkyEditor, .open([URL(string: "forky://file/tmp/Skin/Skin.ini:4")!], app: forky)),
                    "the default app, at the line when it is a known editor")
            locator.defaultApp = own
            t.equal(route(.systemDefault), .builtIn, "Deskset as the default app never loops")
            locator.defaultApp = nil
            if case .external(let e, let c) = route(.systemDefault) {
                t.equal(e.family, .textEdit)
                t.equal(c, .open([file], app: e.url))
            } else {
                t.check(false, "no default app: TextEdit")
            }
            // Files Deskset is asked to open: everything but packages, folders and non-file URLs goes to the editor.
            t.check(CodeEditorRouter.isEditableFile(URL(fileURLWithPath: "/a/B.INC")))
            t.check(CodeEditorRouter.isEditableFile(URL(fileURLWithPath: "/a/s.lua")))
            t.check(CodeEditorRouter.isEditableFile(URL(fileURLWithPath: "/a/Settings.cfg")), "any file a skin edits")
            t.check(CodeEditorRouter.isEditableFile(URL(fileURLWithPath: "/a/data.json")))
            t.check(CodeEditorRouter.isEditableFile(URL(fileURLWithPath: "/a/README")), "no extension")
            t.check(!CodeEditorRouter.isEditableFile(URL(fileURLWithPath: "/a/s.rmskin")))
            t.check(!CodeEditorRouter.isEditableFile(URL(fileURLWithPath: "/a/S.RMSKIN")))
            t.check(!CodeEditorRouter.isEditableFile(dir), "a folder goes to the installer, which explains skin folders")
            t.check(!CodeEditorRouter.isEditableFile(URL(string: "https://example.com/a.ini")!))
        }

        t.suite("App: code editor router opens the right place") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let locator = FakeLocator()
            let opener = RecordingOpener()
            let dir = t.temporaryDirectory("router")
            try withFakes(locator, opener) {
                guard let system = app.activate(config: "Deskset\\System", file: nil) else { return t.check(false, "System") }
                let ini = system.skin.fileURL
                let text = try TextDecoding.readFile(at: ini)
                let lines = text.components(separatedBy: "\n")
                guard let header = lines.firstIndex(where: { $0.hasPrefix("[MeterCPUValue]") }) else {
                    return t.check(false, "fixture header")
                }

                // Built-in: the editor opens on the skin and selects the section at the line.
                app.state.updateEditor { $0.codeEditor = .builtIn }
                CodeEditorRouter.open(file: ini, line: header + 3, app: app)
                t.equal(app.inspector?.config, "Deskset\\System")
                t.equal(app.inspector?.selectedSection, "MeterCPUValue")
                t.equal(opener.opened.count + opener.runs.count, 0, "no app launched")

                // An included file of the edited skin: the style defined there.
                let styles = system.skin.directory.deletingLastPathComponent().appendingPathComponent("@Resources/Styles.inc")
                let styleLines = try TextDecoding.readFile(at: styles).components(separatedBy: "\n")
                if let label = styleLines.firstIndex(where: { $0.hasPrefix("[StyleLabel]") }) {
                    CodeEditorRouter.open(file: styles, line: label + 2, app: app)
                    t.equal(app.inspector?.config, "Deskset\\System", "the include stays in the open editor")
                    t.equal(app.inspector?.selectedSection, "StyleLabel")
                }

                // A skin file of an unloaded config is loaded first.
                t.check(app.controller(for: "Deskset\\Clock") == nil)
                let clock = app.skinsDirectory.appendingPathComponent("Deskset/Clock/Clock.ini")
                CodeEditorRouter.open(file: clock, app: app)
                t.check(app.isLoadPending("Deskset\\Clock"), "loaded on the next run loop turn")
                AppSelfTest.spin { app.inspector?.config == "Deskset\\Clock" }
                t.check(app.controller(for: "Deskset\\Clock") != nil, "loaded")
                t.equal(app.inspector?.config, "Deskset\\Clock")

                // External app: the line URL goes to that app; the editor window is not touched.
                let forky = fakeApp(dir, "Forky", product: ["urlProtocol": "forky"])
                locator.apps["com.example.forky"] = forky
                app.state.updateEditor { $0.codeEditor = .app(bundleID: "com.example.forky", lastKnownPath: forky.path) }
                CodeEditorRouter.open(file: ini, line: 7, app: app)
                let expected = "forky://file" + (ini.standardizedFileURL.path
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") + ":7"
                t.equal(opener.opened.last?.urls, [URL(string: expected)!])
                t.equal(opener.opened.last?.app, forky)
                t.equal(app.inspector?.config, "Deskset\\Clock")
                // The skin menu offers the chosen app next to the Studio.
                let clockMenu = app.controller(for: "Deskset\\Clock").map { app.skinMenu(for: $0, includeCustomItems: false) }
                t.equal(clockMenu?.items.map(\.title).filter { $0.hasPrefix("Edit") }, ["Edit Skin…", "Edit in Forky"])

                // A URL the app refuses: the file itself is opened in it.
                opener.failingSchemes = ["forky"]
                CodeEditorRouter.open(file: ini, line: 8, app: app)
                t.equal(opener.opened.last?.urls, [ini.standardizedFileURL], "fallback to the plain file")
                t.equal(opener.opened.last?.app, forky)
                opener.failingSchemes = []

                // A bundled CLI (Sublime Text) runs; a missing one falls back to opening the file.
                let sublime = fakeApp(dir, "Sublime Text")
                let subl = sublime.appendingPathComponent("Contents/SharedSupport/bin/subl")
                try FileManager.default.createDirectory(at: subl.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "#!/bin/sh\nexit 0\n".write(to: subl, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: subl.path)
                locator.apps["com.sublimetext.4"] = sublime
                app.state.updateEditor { $0.codeEditor = .app(bundleID: "com.sublimetext.4", lastKnownPath: sublime.path) }
                CodeEditorRouter.open(file: ini, line: 12, app: app)
                t.equal(opener.runs.last?.executable, subl)
                t.equal(opener.runs.last?.arguments, ["\(ini.standardizedFileURL.path):12"])
                try FileManager.default.removeItem(at: subl)
                let before = opener.runs.count
                CodeEditorRouter.open(file: ini, line: 12, app: app)
                t.equal(opener.runs.count, before, "a missing CLI is not run")
                t.equal(opener.opened.last?.urls, [ini.standardizedFileURL])
                t.equal(opener.opened.last?.app, sublime)

                // The chosen app was uninstalled: the built-in editor, with a notice.
                app.state.updateEditor { $0.codeEditor = .app(bundleID: "com.example.gone", lastKnownPath: "/nowhere/Gone.app") }
                let opened = opener.opened.count
                CodeEditorRouter.open(file: ini, line: header + 2, app: app)
                t.equal(opener.opened.count, opened, "nothing launched")
                t.equal(app.inspector?.config, "Deskset\\System")
                t.equal(app.inspector?.selectedSection, "MeterCPUValue")
                t.check(app.inspector?.toastText.contains("Gone is no longer installed") == true,
                        app.inspector?.toastText ?? "")

                // Files opened with Deskset: code files are routed; packages, ZIP archives (Deskset is an Open With
                // choice for them) and folders go on to the skin installer.
                app.state.updateEditor { $0.codeEditor = .builtIn }
                let zip = dir.appendingPathComponent("CoolSkin.zip")
                try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: zip)
                let openedBeforeZip = opener.opened.count
                let rest = CodeEditorRouter.routeOpenedFiles([dir.appendingPathComponent("x.rmskin"), zip, clock, dir],
                                                             app: app)
                t.equal(rest, [dir.appendingPathComponent("x.rmskin"), zip, dir], "the ZIP goes to the installer")
                t.equal(opener.opened.count, openedBeforeZip, "not to Archive Utility or an editor")
                t.equal(app.inspector?.config, "Deskset\\Clock")
                t.check(!CodeEditorRouter.isEditableFile(URL(fileURLWithPath: "/a/skin.ZIP")))
                t.check(!CodeEditorRouter.isEditableFile(URL(fileURLWithPath: "/a/skin.rmskin")))
                t.check(CodeEditorRouter.isEditableFile(URL(fileURLWithPath: "/a/Settings.cfg")))
                // With an external editor chosen too: a ZIP is never handed to it.
                app.state.updateEditor { $0.codeEditor = .app(bundleID: "com.example.forky", lastKnownPath: forky.path) }
                t.equal(CodeEditorRouter.routeOpenedFiles([zip], app: app), [zip])
                t.equal(opener.opened.count, openedBeforeZip)
                app.state.updateEditor { $0.codeEditor = .builtIn }

                // Any other text file a skin hands to #CONFIGEDITOR# (here Deskset) — `["#CONFIGEDITOR#" "#@#Settings.cfg"]`,
                // .json, no extension — opens in a code window of the built-in editor: never in the system default app
                // (for example an IDE nobody chose for this), and never in the installer.
                let resources = system.skin.directory.deletingLastPathComponent().appendingPathComponent("@Resources")
                let cfg = resources.appendingPathComponent("Settings.cfg")
                let json = dir.appendingPathComponent("data.json")
                let bare = dir.appendingPathComponent("NOTES")
                for f in [cfg, json, bare] { try "x=1".write(to: f, atomically: true, encoding: .utf8) }
                locator.defaultApp = forky
                let openedBefore = opener.opened.count
                let others = CodeEditorRouter.routeOpenedFiles([cfg, json, bare], app: app)
                t.equal(others, [], "nothing for the installer")
                t.equal(opener.opened.count, openedBefore, "no other app launched, even with a default app for them")
                t.equal(app.codeFileWindows.map { CodeEditorRouter.comparablePath($0.file) },
                        [cfg, json, bare].map(CodeEditorRouter.comparablePath), "a code window each")
                t.equal(app.codeFileWindows.first?.codeView.text, "x=1")
                t.equal(app.inspector?.config, "Deskset\\Clock", "the editor window is not touched")
                // The same file again: its window, not a second one; at the line asked for.
                try "a=1\nb=2\nc=3\n".write(to: json, atomically: true, encoding: .utf8)
                CodeEditorRouter.open(file: json, line: 3, app: app)
                t.equal(app.codeFileWindows.count, 3, "one window per file")
                if let window = app.codeFileWindows.first(where: { $0.file.lastPathComponent == "data.json" }) {
                    window.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
                    window.reveal(line: 3)
                    t.equal(window.codeView.caretLine, 3, "at the line")
                    t.equal(window.codeView.text, "a=1\nb=2\nc=3\n", "coming back picks up the file as it is on disk")
                    // Typing and closing saves the file, in its own encoding and line endings.
                    window.codeView.textView.setSelectedRange(NSRange(location: 3, length: 0))
                    window.codeView.textView.insertText("0", replacementRange: window.codeView.textView.selectedRange())
                    t.check(window.windowShouldClose(window.window!), "closes")
                    t.equal(try String(contentsOf: json, encoding: .utf8), "a=10\nb=2\nc=3\n", "saved on close")
                    window.window?.close()
                    t.equal(app.codeFileWindows.count, 2, "forgotten when closed")
                }
                for w in app.codeFileWindows { w.window?.close() }
                locator.defaultApp = nil

                // Not text (an image): the app macOS uses for it, TextEdit when that would be Deskset itself.
                let picture = dir.appendingPathComponent("picture.png")
                try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]).write(to: picture)
                t.check(!CodeFileWindowController.isTextFile(picture))
                t.check(CodeFileWindowController.isTextFile(bare) && CodeFileWindowController.isTextFile(cfg))
                locator.defaultApp = forky
                CodeEditorRouter.open(file: picture, line: nil, app: app)
                t.equal(opener.opened.last?.urls, [picture.standardizedFileURL])
                t.equal(opener.opened.last?.app, forky)
                t.equal(app.codeFileWindows.count, 0)
                locator.defaultApp = Bundle.main.bundleURL
                locator.apps["com.apple.TextEdit"] = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
                CodeEditorRouter.open(file: picture, line: nil, app: app)
                t.equal(opener.opened.last?.app, URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
                locator.defaultApp = nil
            }
        }
    }

    // MARK: #CONFIGEDITOR#

    static func configEditorTests(_ t: AppTestRunner) {
        t.suite("App: #CONFIGEDITOR# follows Settings") {
            let dir = t.temporaryDirectory("configeditor")
            let locator = FakeLocator()
            let forky = fakeApp(dir, "Forky")
            let own = fakeApp(dir, "Deskset")
            locator.apps = ["com.example.forky": forky]
            func path(_ choice: EditorPreferences.CodeEditor) -> String? {
                var p = EditorPreferences()
                p.codeEditor = choice
                return CodeEditorRouter.configEditorPath(for: p, locator: locator, ownBundle: own,
                                                         ownBundleID: "com.example.deskset")
            }
            t.equal(path(.builtIn), own.path, "built-in: Deskset, which routes the files it is given")
            t.equal(path(.app(bundleID: "com.example.forky", lastKnownPath: "")), forky.path)
            t.equal(path(.app(bundleID: "com.example.gone", lastKnownPath: "/nowhere/Gone.app")), own.path,
                    "a missing app: the built-in editor stands in")
            t.equal(path(.systemDefault), nil, "system default: the .ini default app lookup")

            guard let app = try AppSelfTest.makeApp(t) else { return }
            withFakes(locator, RecordingOpener()) {
                CodeEditorRouter.primaryApp = app
                app.state.updateEditor { $0.codeEditor = .builtIn }
                t.equal(Workspace.configEditorPath, Bundle.main.bundleURL.path)
                app.state.updateEditor { $0.codeEditor = .app(bundleID: "com.example.forky", lastKnownPath: forky.path) }
                t.equal(Workspace.configEditorPath, forky.path, "a changed preference is seen at once")
                if let c = app.activate(config: "Deskset\\System", file: nil) {
                    c.skin.update()
                    t.equal(c.skin.variable("CONFIGEDITOR"), forky.path, "skins read the chosen editor")
                }
                app.state.updateEditor { $0.codeEditor = .systemDefault }
                t.check(!Workspace.configEditorPath.isEmpty)
                CodeEditorRouter.primaryApp = nil
                t.equal(CodeEditorRouter.configEditorPathOverride, nil, "headless: no preference applies")
            }
        }
    }

    // MARK: Settings window

    static func settingsWindowTests(_ t: AppTestRunner) {
        t.suite("App: Settings window") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let dir = t.temporaryDirectory("settings")
            let locator = FakeLocator()
            let forky = fakeApp(dir, "Forky", product: ["urlProtocol": "forky"])
            let zed = fakeApp(dir, "Zed")
            let textEdit = fakeApp(dir, "TextEdit")
            locator.apps = ["com.example.forky": forky, "dev.zed.Zed": zed, "com.apple.TextEdit": textEdit]
            locator.claimers = [forky]
            locator.defaultApp = forky
            withFakes(locator, RecordingOpener()) {
                let settings = SettingsWindowController(app: app)
                t.equal(settings.pane, .general, "first time: General")
                t.equal(settings.window?.title, "General")
                t.check(settings.window?.styleMask.contains(.miniaturizable) == false, "minimize dimmed")
                t.check(settings.window?.styleMask.contains(.resizable) == false, "zoom dimmed")
                t.equal(settings.window?.toolbarStyle, .preference)
                settings.select(.editor)
                t.equal(settings.window?.title, "Editor", "the title names the pane")
                t.equal(settings.window?.toolbar?.selectedItemIdentifier, SettingsWindowController.Pane.editor.identifier)
                t.equal(app.state.data.settingsPane, "editor")
                t.equal(SettingsWindowController(app: app).pane, .editor, "reopens on the last pane")

                t.equal(settings.testEditorTitles, [SettingsWindowController.builtInTitle, "-", "Forky", "TextEdit", "Zed",
                                                    "-", "System default (Forky)", "Other…"])
                t.equal(settings.editorPopUp.titleOfSelectedItem, SettingsWindowController.builtInTitle)
                t.check(settings.editorPopUp.itemArray[2].image != nil, "editors have icons")
                t.check(settings.modeControl.isEnabled)
                t.check(settings.helperLabel.stringValue.contains("skin editor"), settings.helperLabel.stringValue)

                settings.testChoose("Forky")
                t.equal(app.state.editor.codeEditor, .app(bundleID: "com.example.forky", lastKnownPath: forky.path))
                t.check(settings.helperLabel.stringValue.contains("Opens Forky at the selected line"),
                        settings.helperLabel.stringValue)
                t.check(!settings.modeControl.isEnabled, "Open skins in: built-in only")
                settings.testChoose("TextEdit")
                t.check(settings.helperLabel.stringValue.contains("can’t jump to a line"), settings.helperLabel.stringValue)
                settings.testChoose("System default (Forky)")
                t.equal(app.state.editor.codeEditor, .systemDefault)
                settings.testChoose(SettingsWindowController.builtInTitle)
                t.equal(app.state.editor.codeEditor, .builtIn)

                // Other…: any app, remembered in the list after switching away.
                let other = fakeApp(dir, "Other Editor")
                locator.ids[other.path] = "com.example.other"
                settings.useOtherApp(other)
                t.equal(app.state.editor.codeEditor, .app(bundleID: "com.example.other", lastKnownPath: other.path))
                t.equal(settings.editorPopUp.titleOfSelectedItem, "Other Editor")
                settings.testChoose(SettingsWindowController.builtInTitle)
                t.check(settings.testEditorTitles.contains("Other Editor"), "remembered")
                settings.useOtherApp(Bundle.main.bundleURL)
                t.equal(app.state.editor.codeEditor, .builtIn, "picking Deskset means the built-in editor")

                // An uninstalled choice is listed as missing.
                app.state.updateEditor { $0.codeEditor = .app(bundleID: "com.example.gone", lastKnownPath: "/nowhere/Gone.app") }
                t.check(settings.testEditorTitles.contains("Gone (missing)"), "\(settings.testEditorTitles)")
                t.equal(settings.editorPopUp.titleOfSelectedItem, "Gone (missing)")
                t.check(settings.helperLabel.stringValue.contains("no longer installed"), settings.helperLabel.stringValue)
                app.state.updateEditor { $0.codeEditor = .builtIn }

                // Other controls write the preferences, and follow changes made elsewhere.
                settings.iniNamesBox.state = .on
                _ = settings.iniNamesBox.target?.perform(settings.iniNamesBox.action, with: settings.iniNamesBox)
                t.equal(app.state.editor.showIniNames, true)
                settings.fontStepper.doubleValue = 16
                _ = settings.fontStepper.target?.perform(settings.fontStepper.action, with: settings.fontStepper)
                t.equal(app.state.editor.codeFontSize, 16)
                t.equal(settings.fontField.integerValue, 16)
                settings.modeControl.selectedSegment = 1
                _ = settings.modeControl.target?.perform(settings.modeControl.action, with: settings.modeControl)
                t.equal(app.state.editor.openSkinsIn, .split)
                app.state.updateEditor { $0.liveReload = false }
                t.equal(settings.liveReloadBox.state, .off, "follows changes made elsewhere")

                // The editor's live reload is the same preference.
                if let c = app.activate(config: "Deskset\\System", file: nil) {
                    app.showInspector(for: c)
                    t.equal(app.inspector?.liveReload, false)
                    app.inspector?.liveReload = true
                    t.equal(app.state.editor.liveReload, true)
                    t.equal(settings.liveReloadBox.state, .on)
                }
                t.check(settings.snapshot() != nil, "renders off-screen")
                settings.select(.general)
                t.check(settings.snapshot() != nil)
            }
        }
    }

    // MARK: Other

    static func miscTests(_ t: AppTestRunner) {
        t.suite("App: section at a line") {
            let text = "; comment\r\n[Rainmeter]\r\nUpdate=1000\r\n\r\n[ MeterA ]\rX=[!Log x]\n[]\n  [MeterB]junk\nY=1"
            let at = { InspectorWindowController.sectionName(atLine: $0, in: text) }
            t.equal(at(1), nil, "above the first header")
            t.equal(at(2), "Rainmeter")
            t.equal(at(4), "Rainmeter")
            t.equal(at(5), "MeterA", "trimmed")
            t.equal(at(6), "MeterA", "values starting with [ are not headers")
            t.equal(at(7), "MeterA", "an empty header names nothing")
            t.equal(at(8), "MeterB", "text after ] is ignored")
            t.equal(at(99), "MeterB")
            t.equal(InspectorWindowController.sectionName(atLine: 1, in: "\u{FEFF}[Variables]\nA=1"), "Variables")
        }

        t.suite("App: activation policy follows editor windows") {
            t.equal(AppActivation.policy(current: .accessory, anyOpen: true), .regular)
            t.equal(AppActivation.policy(current: .regular, anyOpen: false), .accessory)
            t.equal(AppActivation.policy(current: .regular, anyOpen: true), nil)
            t.equal(AppActivation.policy(current: .accessory, anyOpen: false), nil)
            t.equal(AppActivation.policy(current: .prohibited, anyOpen: true), nil, "headless runs stay headless")
        }

        t.suite("App: Settings and Manage Skins menu items") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let main = MainMenu.make(app: app)
            let items = main.items.first?.submenu?.items ?? []
            let settings = items.first { $0.title == "Settings…" }
            let manage = items.first { $0.title == "Manage Skins…" }
            t.equal(settings?.keyEquivalent, ",")
            t.equal(settings?.keyEquivalentModifierMask, [.command])
            t.equal(settings?.action, #selector(AppController.settingsAction))
            t.equal(manage?.keyEquivalent, ",")
            t.equal(manage?.keyEquivalentModifierMask, [.command, .shift])
            let status = NSMenu()
            app.buildMainMenu(status)
            t.check(status.items.contains { $0.title == "Settings…" && $0.keyEquivalent == "," })
            t.equal(status.items.first { $0.title == "Manage Skins…" }?.keyEquivalentModifierMask, [.command, .shift])
        }
    }
}
