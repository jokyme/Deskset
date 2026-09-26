import AppKit
import DesksetCore

/// `Deskset --self-test [filter]`: checks of the app layer (DesksetSelfTest links only DesksetCore). Suites are named
/// "App: …"; skin windows are created headless (never shown), files go to temporary folders, the user's state and
/// log are not touched. Uses the fixtures in TestSkins/App and DefaultSkins when run from the repository.
enum AppSelfTest {
    static func run(filter: String?) -> Int32 {
        let t = AppTestRunner(filter: filter)
        print("Deskset app self-test")
        geometryTests(t)
        visibilityTests(t)
        windowPositionTests(t)
        stateTests(t)
        libraryTests(t)
        manageModelTests(t)
        renderOptionTests(t)
        systemMonitorTests(t)
        iconTests(t)
        controllerTests(t)
        inspectorTests(t)
        editorEditingTests(t)
        editorLayerTests(t)
        editorUXTests(t)
        editorSchemaTests(t)
        componentLibraryTests(t)
        manageWindowTests(t)
        installTests(t)
        reviewTests(t)
        mousePluginTests(t)
        sliderPluginTests(t)
        sliderElsewhereTests(t)
        integrationTests(t)
        CodeEditorRoutingSelfTests.run(t)
        wiringTests(t)
        AudioSelfTests.run(t)
        MediaUITests.run(t)
        SkinThreadingSelfTests.run(t)
        RenderContextSelfTests.run(t)
        CodeEditorSelfTests.run(t)
        StudioReviewSelfTests.run(t)
        // The friendlier studio (docs/editor-friendly.md §14): one suite family per work package.
        FriendlySidebarSelfTests.run(t)
        FriendlyWidgetPageSelfTests.run(t)
        FriendlyInspectorSelfTests.run(t)
        FriendlyCanvasSelfTests.run(t)
        FriendlyWalkthroughSelfTests.run(t)
        ReviewFixesSelfTests.run(t)
        EditorOpeningSelfTests.run(t)
        return t.finish()
    }

    // MARK: Geometry

    static let screen = WindowGeometry.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                              visibleFrame: CGRect(x: 0, y: 60, width: 1440, height: 815))
    /// A second display to the right, top-aligned, 1920×1080.
    static let screen2 = WindowGeometry.Screen(frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080),
                                               visibleFrame: CGRect(x: 1440, y: -180, width: 1920, height: 1080))

    static func geometryTests(_ t: AppTestRunner) {
        t.suite("App: window levels") {
            let levels = (-2...2).map { WindowGeometry.level(forAlwaysOnTop: $0).rawValue }
            t.check(levels == levels.sorted() && Set(levels).count == 5, "levels increase: \(levels)")
            t.check(levels[0] > Int(CGWindowLevelForKey(.desktopIconWindow)), "On Desktop is above the desktop icons")
            t.check(levels[1] < NSWindow.Level.normal.rawValue, "Bottom is below normal windows")
            t.equal(levels[2], NSWindow.Level.normal.rawValue)
            t.equal(levels[3], NSWindow.Level.floating.rawValue)
            t.check(levels[4] > NSWindow.Level.floating.rawValue && levels[4] < NSWindow.Level.mainMenu.rawValue,
                    "Stay Topmost is above floating windows, below the menu bar")
            t.equal(WindowGeometry.level(forAlwaysOnTop: -9), WindowGeometry.level(forAlwaysOnTop: -2))
            t.equal(WindowGeometry.level(forAlwaysOnTop: 7), WindowGeometry.level(forAlwaysOnTop: 2))
            for v in -2...2 {
                let b = WindowGeometry.collectionBehavior(forAlwaysOnTop: v)
                t.check(b.contains(.canJoinAllSpaces) && b.contains(.ignoresCycle), "all spaces, no cycling (\(v))")
                t.equal(b.contains(.stationary), v != -1, "stationary \(v)")
                t.equal(b.contains(.transient), v == -1, "transient \(v)")
                t.equal(b.contains(.fullScreenAuxiliary), v >= 1, "full screen \(v)")
            }
        }

        t.suite("App: coordinates") {
            let f = WindowGeometry.frame(topLeftX: 100, y: 50, size: CGSize(width: 200, height: 80), primaryHeight: 900)
            t.equal(f, CGRect(x: 100, y: 770, width: 200, height: 80))
            let p = WindowGeometry.topLeft(of: f, primaryHeight: 900)
            t.close(p.x, 100)
            t.close(p.y, 50)
            let cascade = WindowGeometry.cascadeFrame(index: 1000, size: CGSize(width: 10, height: 10),
                                                      visible: screen.visibleFrame)
            t.check(screen.visibleFrame.contains(cascade), "cascade stays on screen for many skins")
            t.equal(WindowGeometry.primaryHeight([]), 900)
        }

        t.suite("App: keep on screen") {
            let area = WindowGeometry.keepArea(screen)
            t.equal(area, CGRect(x: 0, y: 0, width: 1440, height: 875))
            // Off the right edge and under the menu bar.
            let moved = WindowGeometry.keptOnScreen(CGRect(x: 1400, y: 860, width: 100, height: 50), screens: [screen])
            t.equal(moved, CGRect(x: 1340, y: 825, width: 100, height: 50))
            // Larger than the screen: the top-left corner stays visible.
            let big = WindowGeometry.keptOnScreen(CGRect(x: -50, y: -500, width: 2000, height: 1200), screens: [screen])
            t.equal(big.minX, 0)
            t.equal(big.maxY, 875)
            // Bridging two screens: moved fully onto the one it overlaps most.
            let bridging = WindowGeometry.keptOnScreen(CGRect(x: 1400, y: 300, width: 200, height: 100),
                                                       screens: [screen, screen2])
            t.equal(bridging.minX, 1440)
            let mostlyLeft = WindowGeometry.keptOnScreen(CGRect(x: 1300, y: 300, width: 200, height: 100),
                                                         screens: [screen, screen2])
            t.equal(mostlyLeft.maxX, 1440)
            // Entirely off every screen: nearest screen.
            let lost = WindowGeometry.keptOnScreen(CGRect(x: 5000, y: 300, width: 100, height: 100),
                                                   screens: [screen, screen2])
            t.equal(lost.maxX, 3360)
            t.check(WindowGeometry.isOffScreen(CGRect(x: -500, y: 0, width: 100, height: 100), screens: [screen]))
            let partly = CGRect(x: -50, y: 0, width: 100, height: 100)
            t.equal(WindowGeometry.rescuedIfOffScreen(partly, screens: [screen]), partly)
            t.equal(WindowGeometry.rescuedIfOffScreen(CGRect(x: -500, y: 0, width: 100, height: 100), screens: [screen]).minX, 0)
            t.equal(WindowGeometry.keptOnScreen(partly, screens: []), partly)
        }

        t.suite("App: snapping") {
            let s = WindowGeometry.snapped(CGRect(x: 6, y: 400, width: 100, height: 50), screens: [screen], others: [])
            t.equal(s.minX, 0)
            let exact = WindowGeometry.snapped(CGRect(x: 10, y: 400, width: 100, height: 50), screens: [screen], others: [])
            t.equal(exact.minX, 10, "10 points away does not snap")
            let right = WindowGeometry.snapped(CGRect(x: 1335, y: 400, width: 100, height: 50), screens: [screen], others: [])
            t.equal(right.maxX, 1440)
            // Another skin next to it: left edge onto its right edge.
            let other = CGRect(x: 300, y: 400, width: 200, height: 100)
            let beside = WindowGeometry.snapped(CGRect(x: 505, y: 420, width: 100, height: 50), screens: [screen],
                                                others: [other])
            t.equal(beside.minX, 500)
            // Far below the other skin: its edges do not attract.
            let far = WindowGeometry.snapped(CGRect(x: 505, y: 100, width: 100, height: 50), screens: [screen],
                                             others: [other])
            t.equal(far.minX, 505)
            // Top edge onto the visible frame's top (below the menu bar).
            let top = WindowGeometry.snapped(CGRect(x: 600, y: 820, width: 100, height: 50), screens: [screen], others: [])
            t.equal(top.maxY, 875)
        }

        t.suite("App: stacking by load order") {
            let groups = WindowGeometry.stackingGroups([
                (item: "a", alwaysOnTop: 0, loadOrder: 5, name: "A"),
                (item: "b", alwaysOnTop: 0, loadOrder: -1, name: "B"),
                (item: "c", alwaysOnTop: -2, loadOrder: 0, name: "C"),
                (item: "d", alwaysOnTop: 0, loadOrder: 5, name: "a2"),
                (item: "e", alwaysOnTop: 9, loadOrder: 0, name: "E"),
            ])
            t.equal(groups, [["c"], ["b", "a", "d"], ["e"]])
        }
    }

    static func visibilityTests(_ t: AppTestRunner) {
        t.suite("App: transparency and hover") {
            t.close(Double(SkinVisibility.targetAlpha(alphaValue: 255, onHover: 0, hovering: false, hidden: false)), 1)
            t.close(Double(SkinVisibility.targetAlpha(alphaValue: 128, onHover: 0, hovering: true, hidden: false)), 128.0 / 255)
            t.close(Double(SkinVisibility.targetAlpha(alphaValue: 128, onHover: 1, hovering: true, hidden: false)), 0)
            t.close(Double(SkinVisibility.targetAlpha(alphaValue: 128, onHover: 2, hovering: true, hidden: false)), 1)
            t.close(Double(SkinVisibility.targetAlpha(alphaValue: 128, onHover: 3, hovering: true, hidden: false)), 0)
            t.close(Double(SkinVisibility.targetAlpha(alphaValue: 128, onHover: 3, hovering: false, hidden: false)), 128.0 / 255)
            t.close(Double(SkinVisibility.targetAlpha(alphaValue: 255, onHover: 2, hovering: true, hidden: true)), 0)
            t.close(Double(SkinVisibility.targetAlpha(alphaValue: 999, onHover: 7, hovering: true, hidden: false)), 1)
            t.check(SkinVisibility.passesClicksWhileHovering(onHover: 1))
            t.check(!SkinVisibility.passesClicksWhileHovering(onHover: 3))
            t.close(SkinVisibility.fadeSeconds(250), 0.25)
            t.close(SkinVisibility.fadeSeconds(-5), 0)
            t.close(SkinVisibility.fadeSeconds(Int.max), Double(SkinState.maxFadeDuration) / 1000)
        }

        t.suite("App: setting flags") {
            t.equal(SkinVisibility.flag("1", current: false), true)
            t.equal(SkinVisibility.flag("0", current: true), false)
            t.equal(SkinVisibility.flag("-1", current: true), false)
            t.equal(SkinVisibility.flag("-1", current: false), true)
            t.equal(SkinVisibility.flag(" -1 ", current: false), true)
            t.equal(SkinVisibility.flag("", current: false), true)
            t.equal(SkinVisibility.flag("abc", current: false), true)
            t.equal(SkinVisibility.flag("1.0", current: false), true)
            t.equal(SkinVisibility.flag("-1.0", current: true), false)
            t.equal(SkinVisibility.flag("nan", current: true), true)
            t.equal(SkinVisibility.flag("1e300", current: false), true)
        }

        t.suite("App: update timer") {
            t.equal(SkinController.updateInterval(-1), nil)
            t.equal(SkinController.updateInterval(-50), nil)
            t.equal(SkinController.updateInterval(0), 0.016)
            t.equal(SkinController.updateInterval(5), 0.016)
            t.equal(SkinController.updateInterval(1000), 1.0)
            t.close(SkinController.timerTolerance(1.0), 0.1)
            t.close(SkinController.timerTolerance(0.016), 0.0016)
            t.close(SkinController.timerTolerance(3600), 0.5)
        }
    }

    static func windowPositionTests(_ t: AppTestRunner) {
        t.suite("App: SetWindowPosition values") {
            t.equal(WindowPosition.parse("50%", endLetter: "R"), .init(value: 50, percent: true))
            t.equal(WindowPosition.parse("100R", endLetter: "R"), .init(value: 100, fromEnd: true))
            t.equal(WindowPosition.parse("20%R", endLetter: "R"), .init(value: 20, percent: true, fromEnd: true))
            t.equal(WindowPosition.parse("50B", endLetter: "B"), .init(value: 50, fromEnd: true))
            t.equal(WindowPosition.parse("(100 / 2)%", endLetter: "R"), .init(value: 50, percent: true))
            t.equal(WindowPosition.parse("200@2", endLetter: "R"), .init(value: 200, screen: 2))
            t.equal(WindowPosition.parse("10@0", endLetter: "R"), .init(value: 10, screen: 0))
            t.equal(WindowPosition.parse("10@40", endLetter: "R"), nil)
            t.equal(WindowPosition.parse("abc", endLetter: "R"), nil)
            t.equal(WindowPosition.parse("50B", endLetter: "R")?.fromEnd, false, "B is not an X suffix")
            let screens = [screen, screen2]
            let size = CGSize(width: 200, height: 100)
            let center = WindowPosition.resolve(x: "50%", y: "50%", anchorX: "50%", anchorY: "50%", skinSize: size,
                                                screens: screens)
            t.close(center?.x ?? -1, 620)
            t.close(center?.y ?? -1, 400)
            let corner = WindowPosition.resolve(x: "0R", y: "0B", anchorX: "0R", anchorY: "0B", skinSize: size,
                                                screens: screens)
            t.close(corner?.x ?? -1, 1240)
            t.close(corner?.y ?? -1, 800)
            let second = WindowPosition.resolve(x: "10@2", y: "10@2", anchorX: "0", anchorY: "0", skinSize: size,
                                                screens: screens)
            t.close(second?.x ?? -1, 1450)
            t.close(second?.y ?? -1, 10, "screen 2 is top-aligned with the primary screen")
            let virtual = WindowPosition.resolve(x: "100%@0", y: "0", anchorX: "100%", anchorY: "0", skinSize: size,
                                                 screens: screens)
            t.close(virtual?.x ?? -1, 3160)
            t.check(WindowPosition.resolve(x: "x", y: "0", anchorX: "0", anchorY: "0", skinSize: size, screens: screens) == nil)
        }
    }

    // MARK: State and library

    static func stateTests(_ t: AppTestRunner) {
        t.suite("App: state file") {
            let dir = t.temporaryDirectory("state")
            let url = dir.appendingPathComponent("state.json")
            // An older file without the newer keys, with out-of-range and wrongly typed values.
            let old = #"""
            {"defaultSkinsInstalled": 1, "skins": {
              "Deskset\\Clock": {"file": "Clock.ini", "active": true, "x": 10, "y": 20, "alwaysOnTop": 9,
                                "alphaValue": 999, "draggable": false},
              "Other\\Skin": {"file": "A.ini", "x": "left", "onHover": 2, "fadeDuration": 99999999, "extra": 1}
            }, "futureKey": [1, 2]}
            """#
            try old.write(to: url, atomically: true, encoding: .utf8)
            let state = AppState(fileURL: url)
            let clock = state.skin("Deskset\\Clock")
            t.equal(clock?.file, "Clock.ini")
            t.equal(clock?.x, 10)
            t.equal(clock?.alwaysOnTop, 2)
            t.equal(clock?.alphaValue, 255)
            t.equal(clock?.draggable, false)
            t.equal(clock?.fadeDuration, 250, "missing key → default")
            t.equal(clock?.onHover, 0)
            t.equal(clock?.keepOnScreen, true)
            let other = state.skin("other\\SKIN")
            t.equal(other?.x, nil, "wrong type → default")
            t.equal(other?.active, true)
            t.equal(other?.onHover, 2)
            t.equal(other?.fadeDuration, SkinState.maxFadeDuration)
            t.equal(state.data.defaultSkinsInstalled, 1)

            state.update("DESKSET\\clock") { $0.alphaValue = -4; $0.loadOrder = 3 }
            t.equal(state.data.skins.count, 2, "updates reuse the existing key")
            t.equal(state.skin("Deskset\\Clock")?.alphaValue, 0)
            state.saveNow()
            let reloaded = AppState(fileURL: url)
            t.equal(reloaded.skin("Deskset\\Clock")?.loadOrder, 3)
            t.equal(reloaded.activeConfigs.map(\.config), ["Other\\Skin", "Deskset\\Clock"])

            // Unreadable file: defaults, and the file is kept aside.
            let broken = dir.appendingPathComponent("broken.json")
            try "{not json".write(to: broken, atomically: true, encoding: .utf8)
            let fresh = AppState(fileURL: broken)
            t.check(fresh.data.skins.isEmpty)
            t.check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("broken.unreadable.json").path))
            // Missing file.
            t.check(AppState(fileURL: dir.appendingPathComponent("none.json")).data.skins.isEmpty)
        }
    }

    static func libraryTests(_ t: AppTestRunner) {
        t.suite("App: skin library scan") {
            let root = t.temporaryDirectory("library")
            let fm = FileManager.default
            func file(_ path: String) throws {
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "[Rainmeter]\n".write(to: url, atomically: true, encoding: .utf8)
            }
            try file("Suite/Clock/B.ini")
            try file("Suite/Clock/a.INI")
            try file("Suite/Clock/notes.txt")
            try file("Suite/@Resources/Hidden.ini")
            try file("Suite/Deep/Er/Skin.ini")
            try file(".hidden/X/Skin.ini")
            try file("Solo/Solo.ini")
            try fm.createDirectory(at: root.appendingPathComponent("Folder.ini"), withIntermediateDirectories: true)
            // A symlink loop must not hang the scan.
            try fm.createSymbolicLink(at: root.appendingPathComponent("Suite/Deep/Loop"),
                                      withDestinationURL: root.appendingPathComponent("Suite"))
            let library = SkinLibrary.scan(root)
            let names = library.map(\.name)
            t.check(names.contains("Suite\\Clock"), "\(names)")
            t.check(names.contains("Suite\\Deep\\Er"))
            t.check(names.contains("Solo"))
            t.check(!names.contains { $0.contains("@Resources") || $0.contains(".hidden") })
            t.equal(library.first { $0.name == "Suite\\Clock" }?.files, ["a.INI", "B.ini"])
            t.equal(library.first { $0.name == "Suite\\Clock" }?.rootName, "Suite")
            t.check(library.count < 20, "loop visited once: \(library.count)")
            t.equal(SkinLibrary.normalizedConfigName(" illustro/Clock\\ "), "illustro\\Clock")
            t.equal(SkinLibrary.directory(for: "A\\B", root: root).lastPathComponent, "B")
            t.equal(SkinLibrary.scan(root.appendingPathComponent("missing")).count, 0)
        }
    }

    static func manageModelTests(_ t: AppTestRunner) {
        t.suite("App: manage model") {
            t.equal(ManageModel.alpha(forTransparencyPercent: 0), 255)
            t.equal(ManageModel.alpha(forTransparencyPercent: 50), 128)
            t.equal(ManageModel.alpha(forTransparencyPercent: 90), 26)
            t.equal(ManageModel.alpha(forTransparencyPercent: 500), 0)
            for p in stride(from: 0, through: 90, by: 10) {
                t.equal(ManageModel.transparencyPercent(forAlpha: ManageModel.alpha(forTransparencyPercent: p)), p)
            }
            t.equal(ManageModel.positions.map(\.value), [2, 1, 0, -1, -2])
            let metadata = ["name": " Clock ", "Author": "", "Information": "Line one|Line two | three"]
            t.equal(ManageModel.metadataValue(metadata, "Name"), "Clock")
            t.equal(ManageModel.metadataValue(metadata, "Author"), nil)
            t.equal(ManageModel.metadataValue(metadata, "License"), nil)
            t.equal(ManageModel.informationText(metadata["Information"] ?? ""), "Line one\nLine two\nthree")

            let dir = t.temporaryDirectory("metadata")
            let ini = dir.appendingPathComponent("Skin.ini")
            try "[Rainmeter]\nUpdate=1000\n[Metadata]\nName=\"Quoted\"\nAuthor=Someone\n[Metadata]\nName=Second\n"
                .write(to: ini, atomically: true, encoding: .utf8)
            let read = ManageModel.readMetadata(ini)
            t.equal(ManageModel.metadataValue(read, "Name"), "Quoted")
            t.equal(ManageModel.metadataValue(read, "Author"), "Someone")
            t.equal(ManageModel.readMetadata(dir.appendingPathComponent("missing.ini")), [:])

            let library = [
                SkinConfig(name: "Root", directory: dir, files: ["Top.ini"]),
                SkinConfig(name: "Root\\B", directory: dir, files: ["z.ini", "a.ini"]),
                SkinConfig(name: "Root\\A\\Deep", directory: dir, files: ["x.ini"]),
                SkinConfig(name: "Another", directory: dir, files: ["y.ini"]),
            ]
            let tree = ManageModel.tree(library)
            t.equal(tree.map(\.name), ["Another", "Root"])
            let rootNode = tree[1]
            t.equal(rootNode.children.map(\.name), ["A", "B", "Top.ini"], "folders first, then files")
            t.equal(rootNode.children[1].children.map(\.name), ["a.ini", "z.ini"])
            t.equal(rootNode.children[0].children.first?.path, "Root\\A\\Deep")
            t.equal(rootNode.children[0].config?.name, nil, "Root\\A is a folder, not a config")
            t.equal(rootNode.config?.name, "Root")
        }
    }

    static func renderOptionTests(_ t: AppTestRunner) {
        t.suite("App: command-line flags") {
            typealias V = CommandLineTools.Validation
            func check(_ args: [String], _ expected: V, _ note: String = "") {
                t.equal(CommandLineTools.validate(["/Applications/Deskset.app/Contents/MacOS/Deskset"] + args), expected,
                        "\(args) \(note)")
            }
            check([], .app)
            // Finder / LaunchServices and AppKit defaults (single dash) still start the app.
            check(["-psn_0_1234567"], .app)
            check(["-NSDocumentRevisionsDebugMode", "YES"], .app)
            check(["-AppleLanguages", "(en)"], .app)
            check(["--render", "a.ini", "--out", "x.png", "--updates", "3", "--interval", "0", "--scale", "1",
                   "--background", "0,0,0", "--skins-dir", "/tmp/Skins"], .mode)
            check(["--self-test"], .mode)
            check(["--self-test", "App: Audio"], .mode)
            check(["--snapshot-ui", "manage", "--out", "m.png", "--dark", "--select", "App\\Focus", "--size",
                   "900x600", "--skins-dir", "/tmp/S"], .mode)
            check(["--snapshot-ui", "inspector", "--zoom", "2"], .mode)
            check(["--snapshot-ui", "inspector", "--select", "none", "--mode", "split", "--tab", "library", "--code-below",
                   "--inspector-width", "340", "--config", "Deskset\\System"], .mode)
            check(["--snapshot-ui", "library", "--category", "text", "--search", "clock"], .mode)
            check(["--snapshot-ui", "settings", "--pane", "general"], .mode)
            check(["--system-report"], .mode)
            check(["--make-icon", "Deskset.iconset"], .mode)
            check(["--help"], .help)
            check(["-h"], .help)
            check(["--render", "a.ini", "--help"], .help)
            // Typos never fall through to the menu bar app (it would run against the user's real skins and state).
            check(["--selftest"], .invalid("unknown option --selftest"))
            check(["--self-test", "--verbose"], .invalid("unknown option --verbose"))
            check(["--render", "a.ini", "--scael", "2"], .invalid("unknown option --scael"))
            check(["--foo", "--bar"], .invalid("unknown options --foo, --bar"))
            check(["--"], .invalid("unknown option --"))
            check(["--dark"], .invalid("--dark needs one of --render, --snapshot-ui"), "an option without a mode")
            let long = "--" + String(repeating: "x", count: 500)
            if case .invalid(let message) = CommandLineTools.validate(["P", long]) {
                t.check(message.count < 100, "a long flag is shown shortened")
            } else {
                t.check(false, "a long unknown flag is invalid")
            }
            for flag in CommandLineTools.modeFlags + ["--help"] {
                t.check(CommandLineTools.usage.contains(flag), "usage mentions \(flag)")
            }
            for flag in CommandLineTools.optionFlags {
                t.check(CommandLineTools.usage.contains(flag), "usage mentions \(flag)")
            }
        }

        t.suite("App: render options") {
            t.check(RenderOptions.parse(["Deskset"]) == nil)
            t.check(RenderOptions.parse(["Deskset", "--render"]) == nil)
            let d = RenderOptions.parse(["Deskset", "--render", "a.ini"])
            t.equal(d?.updates, 2)
            t.equal(d?.interval, 1000)
            t.equal(d?.scale, 2)
            t.equal(d?.warnings, [])
            let zero = RenderOptions.parse(["P", "--render", "a.ini", "--updates", "0", "--interval", "0"])
            t.equal(zero?.updates, 1)
            t.equal(zero?.interval, 0)
            t.equal(zero?.warnings.count, 1)
            let bad = RenderOptions.parse(["P", "--render", "a.ini", "--updates", "many", "--interval", "-5",
                                           "--scale", "100", "--background", "nope"])
            t.equal(bad?.updates, 2)
            t.equal(bad?.interval, 0)
            t.equal(bad?.scale, 8)
            t.equal(bad?.background, nil)
            t.equal(bad?.warnings.count, 2)
            let huge = RenderOptions.parse(["P", "--render", "a.ini", "--updates", "1e30", "--interval", "inf",
                                            "--scale", "nan"])
            t.equal(huge?.updates, RenderOptions.maxUpdates)
            t.equal(huge?.interval, 1000)
            t.equal(huge?.scale, 2)
            let missing = RenderOptions.parse(["P", "--render", "a.ini", "--updates", "--out", "x.png"])
            t.equal(missing?.updates, 2)
            t.equal(missing?.output, "x.png")
            let color = RenderOptions.parse(["P", "--render", "a.ini", "--background", "40,40,50"])
            t.equal(color?.background, RGBA(r: 40, g: 40, b: 50, a: 255))

            let (root, config) = RenderCommand.locate(URL(fileURLWithPath: "/x/Skins/Suite/Clock/Clock.ini"), skinsDir: nil)
            t.equal(root.path, "/x/Skins")
            t.equal(config, "Suite\\Clock")
            let (root2, config2) = RenderCommand.locate(URL(fileURLWithPath: "/x/TestSkins/App/Focus/Focus.ini"), skinsDir: nil)
            t.equal(root2.path, "/x/TestSkins")
            t.equal(config2, "App\\Focus")
            let (_, config3) = RenderCommand.locate(URL(fileURLWithPath: "/a/b/C.ini"), skinsDir: "/elsewhere")
            t.equal(config3, "b")
        }
    }

    // MARK: System readings

    static func systemMonitorTests(_ t: AppTestRunner) {
        t.suite("App: CPU usage math") {
            let before: [[UInt32]] = [[100, 0, 50, 0], [0, 0, 0, 0]]
            let now: [[UInt32]] = [[200, 0, 150, 0], [0, 50, 50, 0]]
            let u = SystemMonitor.cpuUsage(now: now, before: before)
            t.close(u.perCore[0], 50)
            t.close(u.perCore[1], 50)
            t.close(u.total, 50)
            let wrap = SystemMonitor.cpuUsage(now: [[10, 0, 20, 0]], before: [[UInt32.max - 9, 0, 0, 0]])
            t.close(wrap.total, 50, "counter wrap-around")
            let idle = SystemMonitor.cpuUsage(now: [[5, 5, 5, 5]], before: [[5, 5, 5, 5]])
            t.close(idle.total, 0)
            let changed = SystemMonitor.cpuUsage(now: [[1, 1, 1, 1]], before: [])
            t.equal(changed.perCore, [0])
        }

        t.suite("App: memory and battery math") {
            var stats = vm_statistics64()
            stats.internal_page_count = 100
            stats.purgeable_count = 10
            stats.wire_count = 50
            stats.compressor_page_count = 40
            t.close(SystemMonitor.usedMemory(stats, pageSize: 16384, total: 1e12), 180 * 16384)
            t.close(SystemMonitor.usedMemory(stats, pageSize: 16384, total: 1000), 1000, "clamped to total")
            stats.purgeable_count = 1000
            t.close(SystemMonitor.usedMemory(stats, pageSize: 1, total: 1e12), 90)

            let charging = SystemMonitor.batteryStatus([kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 100,
                                                        kIOPSIsChargingKey: true,
                                                        kIOPSPowerSourceStateKey: kIOPSACPowerValue,
                                                        kIOPSTimeToEmptyKey: 30])
            t.equal(charging, BatteryStatus(percent: 50, isCharging: true, isPluggedIn: true, minutesRemaining: nil))
            let draining = SystemMonitor.batteryStatus([kIOPSCurrentCapacityKey: 3000, kIOPSMaxCapacityKey: 4000,
                                                        kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
                                                        kIOPSTimeToEmptyKey: 125])
            t.equal(draining, BatteryStatus(percent: 75, isCharging: false, isPluggedIn: false, minutesRemaining: 125))
            let calculating = SystemMonitor.batteryStatus([kIOPSCurrentCapacityKey: 10, kIOPSTimeToEmptyKey: -1])
            t.equal(calculating.minutesRemaining, nil)
            t.close(calculating.percent, 10)
            t.close(SystemMonitor.batteryStatus([kIOPSCurrentCapacityKey: 500, kIOPSMaxCapacityKey: 0]).percent, 0)
        }

        t.suite("App: SysInfo timestamps and names") {
            let offset = Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: 0)))
            t.close(SystemMonitor.windowsTimestamp(0), 11_644_473_600 + offset)
            t.check(SystemMonitor.productName().hasPrefix("macOS"))
        }

        t.suite("App: live system readings") {
            let m = SystemMonitor.shared
            _ = m.cpuUsage(processor: 0)
            RenderCommand.wait(milliseconds: 300)
            let cpu = m.cpuUsage(processor: 0)
            t.check(cpu >= 0 && cpu <= 100, "cpu \(cpu)")
            t.check(m.processorCount >= 1)
            t.equal(m.cpuUsage(processor: m.processorCount + 5), 0)
            let mem = m.memoryStatus()
            t.check(mem.physicalTotal > 0 && mem.physicalUsed > 0 && mem.physicalUsed <= mem.physicalTotal)
            t.check(mem.swapUsed <= mem.swapTotal)
            if let disk = m.diskSpace(path: "/") {
                t.check(disk.total > 0 && disk.free >= 0 && disk.free <= disk.total)
            } else {
                t.check(false, "statfs /")
            }
            t.check(m.diskSpace(path: "/no/such/volume") == nil)
            let up = m.uptime()
            let boot = SystemMonitor.sysctlTime("kern.boottime") ?? 0
            t.close(up, Date().timeIntervalSince1970 - boot, accuracy: 5)
            let a = m.networkCounters(interface: nil)
            RenderCommand.wait(milliseconds: 600)
            let b = m.networkCounters(interface: nil)
            t.check(b.received >= a.received && b.sent >= a.sent, "counters only grow")
            t.equal(m.networkCounters(interface: "no-such-if9"), NetworkCounters())
            for name in m.networkInterfaces() {
                t.check(!SystemMonitor.isVirtualInterface(name), "\(name) listed as active")
                t.equal(m.resolveAdapter(name.uppercased()), name)
            }
            t.equal(m.resolveAdapter("99"), nil)
            t.check(SystemMonitor.isVirtualInterface("utun3") && SystemMonitor.isVirtualInterface("awdl0"))
            t.check(!SystemMonitor.isVirtualInterface("en0"))
            t.check(m.isProcessRunning("launchd"), "launchd runs")
            t.check(!m.isProcessRunning("surely-not-a-running-process-name"))
            for type in SystemReport.sysInfoTypes {
                // The engine computes monitor, time zone, OS_BITS and PAGESIZE values without asking the app.
                let engine = SystemMonitor.engineSysInfoTypes.contains(type)
                t.equal(m.sysInfo(type: type, data: "") == nil, engine, "SysInfo \(type) answered by the app: \(!engine)")
            }
            t.check(m.sysInfo(type: "NO_SUCH_TYPE", data: "") == nil)
            t.equal(m.sysInfo(type: "USER_NAME", data: "")?.string, NSUserName())
            t.equal(m.sysInfo(type: "ADAPTER_STATUS", data: "no-such-if9")?.string, "Not Present")
        }
    }

    static func iconTests(_ t: AppTestRunner) {
        t.suite("App: icon") {
            guard let data = AppIcon.pngData(pixels: 256), let rep = NSBitmapImageRep(data: data) else {
                t.check(false, "icon renders")
                return
            }
            t.equal(rep.pixelsWide, 256)
            t.equal(rep.pixelsHigh, 256)
            t.check((rep.colorAt(x: 128, y: 128)?.alphaComponent ?? 0) > 0.99, "opaque center")
            t.check((rep.colorAt(x: 1, y: 1)?.alphaComponent ?? 1) < 0.01, "transparent corner")
            t.equal(AppIcon.iconsetEntries.count, 10)
            t.equal(Set(AppIcon.iconsetEntries.map(\.pixels)), [16, 32, 64, 128, 256, 512, 1024])
            let dir = t.temporaryDirectory("icon").appendingPathComponent("Deskset.iconset")
            try AppIcon.writeIconset(to: dir)
            t.equal(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 10)
            let status = AppIcon.statusBarImage()
            t.check(status.isTemplate)
            t.equal(status.size, NSSize(width: 18, height: 18))
        }
    }

    // MARK: Controllers (headless windows)

    private static var retainedApps: [AppController] = []

    /// Closes the editors of the apps made so far and stops their skins' update timers (at the end of each suite: see
    /// `AppTestRunner.suite`). No suite uses an earlier suite's app; its skins would otherwise keep updating in every
    /// later suite's run-loop turns, which slows a CI runner and makes editor timers fire mid-test.
    static func closeEditors() {
        for app in retainedApps {
            app.inspector?.window?.close()
            for c in app.sortedControllers { c.pauseUpdates() }
        }
    }

    /// Stops the skins of the apps made so far, whose suites are over: they would go on updating on the main thread
    /// through the suites that follow (the editor-opening suites time its steps).
    static func stopEarlierSkins() {
        for app in retainedApps { app.stopAllForTermination() }
    }

    /// A headless app over a temporary Skins folder holding TestSkins/App and DefaultSkins/Deskset.
    static func makeApp(_ t: AppTestRunner) throws -> AppController? {
        guard let testSkins = Paths.repositoryFolder("TestSkins") else {
            print("    (skipped: TestSkins not found; run from the repository)")
            return nil
        }
        let root = t.temporaryDirectory("app")
        let skins = root.appendingPathComponent("Skins")
        try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: testSkins.appendingPathComponent("App"),
                                         to: skins.appendingPathComponent("App"))
        if let defaults = Paths.repositoryFolder("DefaultSkins") {
            try? FileManager.default.copyItem(at: defaults.appendingPathComponent("Deskset"),
                                              to: skins.appendingPathComponent("Deskset"))
        }
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: skins, layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), presentsWindows: false)
        retainedApps.append(app)
        return app
    }

    /// Runs the main run loop until `condition` holds (deferred bangs, background installs).
    @discardableResult
    static func spin(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            RenderCommand.wait(milliseconds: 20)
        }
        return true
    }

    static func controllerTests(_ t: AppTestRunner) {
        t.suite("App: skin controller window bangs") {
            guard let app = try makeApp(t) else { return }
            guard let c = app.activate(config: "App\\Focus", file: nil) else {
                t.check(false, "App\\Focus loads")
                return
            }
            t.equal(c.file, "Compact.ini", "first .ini when none was used before")
            guard let focus = app.activate(config: "app/focus/", file: "focus.INI") else {
                t.check(false, "variant loads")
                return
            }
            t.check(c.isStopped, "the previous variant stopped")
            t.equal(focus.file, "Focus.ini")
            t.equal(app.state.skin("App\\Focus")?.file, "Focus.ini")
            t.check(!focus.window.isVisible, "headless windows are never shown")
            t.check(focus.wantsFocus)
            t.equal(focus.window.level, WindowGeometry.level(forAlwaysOnTop: -2))

            func run(_ action: String, _ target: SkinController = focus) { target.skin.execute(action, from: nil) }
            run("[!SetTransparency 128]")
            t.equal(focus.state.alphaValue, 128)
            t.close(Double(focus.window.alphaValue), 128.0 / 255, accuracy: 0.01)
            run("[!SetTransparency 9999]")
            t.equal(focus.state.alphaValue, 255)
            run("[!ZPos 1]")
            t.equal(focus.window.level, .floating)
            run("[!ZPos -1]")
            t.check(focus.window.collectionBehavior.contains(.transient))
            run("[!ZPos 42]")
            t.equal(focus.state.alwaysOnTop, 2)
            run("[!ClickThrough 1]")
            t.check(focus.window.ignoresMouseEvents)
            let panel = focus.window
            run("[!ClickThrough -1]")
            t.check(!focus.window.ignoresMouseEvents)
            t.check(focus.window !== panel, "a fresh panel restores per-pixel hit testing")
            t.check(focus.window.contentView === focus.view)
            t.equal(focus.window.level, WindowGeometry.level(forAlwaysOnTop: 2), "settings survive the new panel")
            run("[!Draggable 0]")
            t.equal(focus.state.draggable, false)
            run("[!Draggable -1]")
            t.equal(focus.state.draggable, true)
            run("[!KeepOnScreen 0][!SnapEdges 0]")
            t.equal(focus.state.keepOnScreen, false)
            t.equal(focus.state.snapEdges, false)
            run("[!KeepOnScreen 1][!SnapEdges 1]")
            run("[!FadeDuration 500]")
            t.equal(focus.state.fadeDuration, 500)
            run("[!FadeDuration -3]")
            t.equal(focus.state.fadeDuration, 0)

            // Visibility
            run("[!HideFade]")
            t.check(focus.isHiddenByBang)
            t.close(Double(focus.window.alphaValue), 0)
            run("[!ShowFade]")
            t.check(!focus.isHiddenByBang)
            t.close(Double(focus.window.alphaValue), 1)
            run("[!Toggle]")
            t.check(focus.isHiddenByBang)
            run("[!ToggleFade]")
            t.check(!focus.isHiddenByBang)

            // Position
            let screens = WindowGeometry.currentScreens()
            if !screens.isEmpty {
                run("[!Move 100 200]")
                let expected = WindowGeometry.keptOnScreen(
                    WindowGeometry.frame(topLeftX: 100, y: 200, size: focus.window.frame.size,
                                         primaryHeight: WindowGeometry.primaryHeight(screens)), screens: screens)
                let p = WindowGeometry.topLeft(of: expected, primaryHeight: WindowGeometry.primaryHeight(screens))
                t.close(focus.topLeftPosition.x, p.x)
                t.close(focus.topLeftPosition.y, p.y)
                t.close(app.state.skin("App\\Focus")?.x ?? -1, p.x, "SavePosition stores the move")
                run("[!SetWindowPosition 50% 50% 50% 50%]")
                let primary = screens[0].frame
                t.close(focus.window.frame.midX, primary.midX, accuracy: 1)
                t.close(focus.window.frame.midY, primary.midY, accuracy: 1)
                let before = app.state.skin("App\\Focus")
                app.screensChanged()
                t.equal(app.state.skin("App\\Focus")?.x, before?.x, "display changes do not rewrite the saved position")
                run("[!Move nonsense 5]")
                t.close(focus.window.frame.midX, primary.midX, accuracy: 1)
            }

            // Focus, unfocus, wake
            focus.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            t.equal(focus.skin.variable("Focus"), "focused")
            t.equal((focus.skin.meter(named: "MeterFocus") as? StringMeter)?.text, "Focus: focused")
            focus.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
            t.equal(focus.skin.variable("Focus"), "not focused")
            focus.systemDidWake()
            focus.systemDidWake()
            t.equal(focus.skin.variable("Wakes"), "2")

            // Pausing
            let count = focus.skin.updateCount
            focus.pauseUpdates()
            focus.resumeUpdates(updateNow: true)
            t.equal(focus.skin.updateCount, count + 1)

            // Unsupported host bangs are reported as such.
            t.equal(focus.handleHostBang(Bang(name: "loadlayout", args: ["x"])), false)
            t.equal(focus.handleHostBang(Bang(name: "autoselectscreen", args: ["1"])), true)
        }

        t.suite("App: config and group bangs") {
            guard let app = try makeApp(t), let focus = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            focus.skin.execute(#"[!ActivateConfig "App\Controls"]"#, from: nil)
            t.check(app.controller(for: "App\\Controls") == nil, "!ActivateConfig loads after the action has run")
            spin { app.controller(for: "App\\Controls") != nil }
            guard let controls = app.controller(for: "App\\Controls") else {
                t.check(false, "!ActivateConfig loads on the next run loop turn")
                return
            }
            t.equal(app.controllers(inGroup: "desksetapptest").count, 2)
            t.equal(app.controllers(inGroup: "Widgets").map(\.config), ["App\\Focus"])
            t.equal(app.controllers(inGroup: " ").count, 0)
            t.equal(app.controllers(forConfigArgument: "*", current: nil).count, 2)
            t.equal(app.controllers(forConfigArgument: "", current: focus).first?.config, "App\\Focus")
            t.equal(app.controllers(forConfigArgument: "App/Controls/", current: focus).first?.config, "App\\Controls")
            t.equal(app.controllers(forConfigArgument: "Nope", current: focus).count, 0)

            controls.skin.execute("[!HideGroup DesksetAppTest]", from: nil)
            t.check(focus.isHiddenByBang && controls.isHiddenByBang)
            controls.skin.execute("[!ShowFadeGroup Widgets]", from: nil)
            t.check(!focus.isHiddenByBang && controls.isHiddenByBang)
            controls.skin.execute("[!ShowGroup DesksetAppTest][!SetTransparencyGroup 100 DesksetAppTest]", from: nil)
            t.equal(focus.state.alphaValue, 100)
            t.equal(controls.state.alphaValue, 100)
            controls.skin.execute("[!ZPosGroup 1 Widgets][!FadeDurationGroup 700 Widgets]", from: nil)
            t.equal(focus.state.alwaysOnTop, 1)
            t.equal(controls.state.alwaysOnTop, -2)
            t.equal(focus.state.fadeDuration, 700)
            controls.skin.execute(#"[!SetVariableGroup Focus "set by group" DesksetAppTest]"#, from: nil)
            t.equal(focus.skin.variable("Focus"), "set by group")
            // Bangs aimed at another config.
            controls.skin.execute(#"[!HideFade "App\Focus"][!SetTransparency 50 "App\Focus"]"#, from: nil)
            t.check(focus.isHiddenByBang)
            t.equal(focus.state.alphaValue, 50)
            t.equal(controls.state.alphaValue, 100)
            controls.skin.execute(#"[!SetVariable Focus "forwarded" "App\Focus"]"#, from: nil)
            t.equal(focus.skin.variable("Focus"), "forwarded")

            // A skin unloading itself is deferred until its action has run.
            focus.skin.execute("[!DeactivateConfig]", from: nil)
            t.check(app.controller(for: "App\\Focus") != nil, "still running inside its own action")
            spin { app.controller(for: "App\\Focus") == nil }
            t.check(app.controller(for: "App\\Focus") == nil)
            t.equal(app.state.skin("App\\Focus")?.active, false)
            t.check(focus.isStopped)
            t.equal(controls.skin.variable("FocusClosed"), "1", "OnCloseAction can still send bangs")
            // Toggle another config.
            controls.skin.execute(#"[!ToggleConfig "App\Focus" "Compact.ini"]"#, from: nil)
            spin { app.controller(for: "App\\Focus") != nil }
            t.equal(app.controller(for: "App\\Focus")?.file, "Compact.ini")
            controls.skin.execute(#"[!ToggleConfig "App\Focus"]"#, from: nil)
            spin { app.controller(for: "App\\Focus") == nil }
            t.check(app.controller(for: "App\\Focus") == nil)
            // OnCloseAction unloading itself during a refresh must not unload the reloaded skin.
            let reloaded = app.activate(config: "App\\Focus", file: "Focus.ini")
            if let reloaded { app.refresh(reloaded) }
            RenderCommand.wait(milliseconds: 100)
            t.check(app.controller(for: "App\\Focus") != nil && app.controller(for: "App\\Focus") !== reloaded)
            app.deactivate(config: "App\\Focus")
            // Refresh replaces the controller, keeping the position.
            controls.skin.execute("[!Refresh]", from: nil)
            spin { app.controller(for: "App\\Controls") !== controls }
            let refreshed = app.controller(for: "App\\Controls")
            t.check(refreshed != nil && refreshed !== controls && controls.isStopped)
            t.close(refreshed?.topLeftPosition.x ?? -1, controls.topLeftPosition.x)
            // Missing configs and files.
            t.check(app.activate(config: "App\\Missing", file: nil) == nil)
            t.equal(app.activate(config: "App\\Focus", file: "Nope.ini")?.file, "Focus.ini", "falls back to the last file")
            refreshed?.skin.execute("[!DeactivateConfigGroup DesksetAppTest]", from: nil)
            spin { app.controllers.isEmpty }
            t.equal(app.controllers.count, 0)
        }

        t.suite("App: skin menus") {
            guard let app = try makeApp(t), let focus = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            // Three titles: a title of dashes is a separator only "if more than 3 options are given", otherwise it
            // needs an action like any item, and an invalid item ends the list.
            let custom = app.customSkinMenu(for: focus)
            t.equal(custom?.items.map(\.title), ["Hide, then show again"])
            let menu = app.skinMenu(for: focus, includeCustomItems: true)
            let titles = menu.items.map(\.title)
            t.equal(titles.first, "Focus & Fade")
            for expected in ["Variants", "Position", "Transparency", "On Hover", "Draggable", "Click Through",
                             "Keep on Screen", "Snap to Edges", "Save Position", "Manage Skin…", "Edit Skin…",
                             "Refresh Skin", "Open Skin Folder", "Unload Skin"] {
                t.check(titles.contains(expected), "skin menu has \(expected)")
            }
            // With the built-in code editor, Edit Skin… (the Studio) is the only edit item.
            t.equal(titles.filter { $0.hasPrefix("Edit") || $0.hasPrefix("Open Skin Editor") }, ["Edit Skin…"])
            let variants = menu.items.first { $0.title == "Variants" }?.submenu?.items
            t.equal(variants?.map(\.title), ["Compact.ini", "Focus.ini"])
            t.equal(variants?.last?.state, .on)
            let position = menu.items.first { $0.title == "Position" }?.submenu?.items
            t.equal(position?.first { $0.state == .on }?.title, "On Desktop")
            if let controls = app.activate(config: "App\\Controls", file: nil) {
                let menu = app.skinMenu(for: controls, includeCustomItems: true)
                let holder = menu.items.first { $0.title == "Custom Skin Actions" }
                t.check(holder != nil, "more than 3 custom items become a submenu")
                let items = holder?.submenu?.items ?? []
                t.equal(items.map(\.title), ["Show App\\Focus", "Hide App\\Focus", "", "A context title that is far lo..."])
                t.equal(items[2].isSeparatorItem, true)
                t.equal(app.customSkinMenu(for: controls)?.items.count, 4)
            }
            let main = NSMenu()
            app.buildMainMenu(main)
            t.check(main.items.contains { $0.title == "Manage Skins…" })
            t.check(main.items.contains { $0.title == "Launch at Login" })
            t.check(main.items.contains { $0.title == "App\\Focus" })
            if let unsupported = app.activate(config: "App\\Unsupported", file: nil) {
                let notes = app.skinMenu(for: unsupported, includeCustomItems: false).items
                    .first { $0.title.hasPrefix("Compatibility Notes") }
                t.check((notes?.submenu?.items.count ?? 0) >= 3, "compatibility notes listed")
            }
        }
    }

    // MARK: Manage window

    static func manageWindowTests(_ t: AppTestRunner) {
        t.suite("App: manage window") {
            guard let app = try makeApp(t) else { return }
            app.activate(config: "App\\Focus", file: "Focus.ini")
            let manage = ManageWindowController(app: app)
            t.check(manage.testOutlineRows >= 2, "roots listed")
            manage.select(config: "App\\Focus", file: nil)
            t.equal(manage.selection?.config, "App\\Focus")
            t.equal(manage.selection?.file, "Focus.ini")
            t.equal(manage.testTitle, "Focus & Fade")
            t.equal(manage.testLoadButtonTitle, "Unload")
            t.check(manage.testSettingsEnabled)
            manage.select(config: "App\\Focus", file: "Compact.ini")
            t.equal(manage.testTitle, "Focus (compact)")
            t.equal(manage.testLoadButtonTitle, "Load")
            t.check(manage.testSettingsEnabled, "settings belong to the config, whichever variant runs")
            manage.select(config: "App\\Unsupported", file: "Unsupported.ini")
            t.equal(manage.testTitle, "Windows Only")
            t.check(manage.testIssueCount >= 4, "three issues and a note: \(manage.testIssueCount)")
            manage.select(config: "App", file: nil)
            t.equal(manage.testLoadButtonTitle, "Load")
            // Reacts to skins being loaded elsewhere.
            manage.select(config: "App\\Controls", file: "Controls.ini")
            app.activate(config: "App\\Controls", file: nil)
            t.equal(manage.testLoadButtonTitle, "Unload")
            if let rep = manage.snapshot() {
                t.check(rep.pixelsWide > 100 && rep.pixelsHigh > 100)
            } else {
                t.check(false, "snapshot")
            }
            manage.close()
        }
        t.suite("App: manage window keeps its size while skins load and unload") {
            guard let app = try makeApp(t) else { return }
            let manage = ManageWindowController(app: app)
            guard let window = manage.window else { return t.check(false, "window") }
            window.setFrame(NSRect(x: 100, y: 100, width: 900, height: 660), display: false)
            window.layoutIfNeeded()
            let width = window.frame.width
            var widths: [CGFloat] = []
            for (config, file) in [("App\\Focus", "Focus.ini"), ("App\\Controls", "Controls.ini"),
                                   ("App\\Unsupported", "Unsupported.ini")] {
                for _ in 0..<2 {
                    manage.testToggleLoad(config: config, file: file)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    window.layoutIfNeeded()
                    widths.append(window.frame.width)
                }
            }
            t.check(widths.allSatisfy { $0 == width }, "the window keeps its width: \(width) → \(widths)")
            t.check(window.frame.width >= window.minSize.width, "never narrower than its minimum")
            // Whatever shrinks it below its minimum (AppKit only enforces minSize for the user's drags), it grows back.
            window.setFrame(NSRect(x: 100, y: 100, width: 380, height: 660), display: false)
            t.equal(window.frame.width, window.minSize.width, "restored to its minimum width")
            t.check(manage.testGridHugging < NSLayoutConstraint.Priority.windowSizeStayPut,
                    "the detail grids never pull the window narrower")
            manage.close()
        }
        t.suite("App: manage window: the details' page has a place as well as a width") {
            guard let app = try makeApp(t) else { return }
            let manage = ManageWindowController(app: app)
            guard let window = manage.window, let page = manage.testDetailDocument,
                  let clip = page.superview as? NSClipView else { return t.check(false, "window") }
            // At the window's smallest, the details of a widget with issues are taller than the pane.
            window.setFrame(NSRect(origin: NSPoint(x: 100, y: 100), size: window.minSize), display: false)
            for (config, file) in [("App\\Focus", "Focus.ini"), ("App\\Unsupported", "Unsupported.ini")] {
                manage.select(config: config, file: file)
                window.layoutIfNeeded()
                t.check(!page.hasAmbiguousLayout, "\(config): one place for the page (not one from window to window)")
                t.equal(page.frame.origin, .zero, "\(config): at the top of the pane")
            }
            // Scrolled, the page stays where it is: the pane's bounds move over it.
            t.check(page.frame.height > clip.bounds.height, "the page is taller than the pane")
            clip.scroll(to: NSPoint(x: 0, y: 60))
            window.layoutIfNeeded()
            t.equal(clip.bounds.origin.y, 60, "scrolled")
            t.equal(page.frame.origin, .zero, "the page stays")
            manage.close()
        }
    }

    // MARK: Install flow

    /// Builds a .rmskin (ZIP + 16-byte footer) from `files` (relative path → contents).
    static func makePackage(_ t: AppTestRunner, name: String, files: [String: Data]) throws -> URL {
        try makePackage(in: t.temporaryDirectory("package"), name: name, files: files)
    }

    static func makePackage(in dir: URL, name: String, files: [String: Data]) throws -> URL {
        let content = dir.appendingPathComponent("content")
        for (path, data) in files {
            let url = content.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let zip = dir.appendingPathComponent("package.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", content.path, zip.path]
        try process.run()
        process.waitUntilExit()
        var data = try Data(contentsOf: zip)
        var length = UInt64(data.count).littleEndian
        data.append(Data(bytes: &length, count: 8))
        data.append(contentsOf: RmskinPackage.footerMagic)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func installTests(_ t: AppTestRunner) {
        t.suite("App: install flow") {
            guard let app = try makeApp(t) else { return }
            let manifest = "[rmskin]\nName=Test Package\nAuthor=Deskset tests\nVersion=2.0\nLoadType=Skin\n"
                + "Load=PkgRoot\\Widget\\Widget.ini\n"
            let skin = "[Rainmeter]\nUpdate=1000\n[Metadata]\nName=Widget\n[M]\nMeter=String\nText=Hi\n"
            let url = try makePackage(t, name: "Test.rmskin", files: [
                "RMSKIN.ini": Data(manifest.utf8),
                "Skins/PkgRoot/Widget/Widget.ini": Data(skin.utf8),
                "Plugins/64bit/FakePlugin.dll": Data([0x4D, 0x5A, 0, 0]),
            ])
            let inspection = try RmskinPackage.inspect(url)
            let summary = InstallSummary(inspection, packageName: "Test.rmskin", skinsDirectory: app.skinsDirectory)
            inspection.cleanup()
            t.equal(summary.title, "Install “Test Package”?")
            t.equal(summary.subtitle, "By Deskset tests · Version 2.0")
            t.equal(summary.skins, [InstallSummary.Line(text: "PkgRoot", detail: nil, configs: ["Widget"])])
            t.equal(summary.loadAfterInstall, "PkgRoot\\Widget\\Widget.ini")
            t.check(summary.pluginWarning?.contains("FakePlugin.dll") == true)
            t.check(!summary.warnings.contains { $0.contains("Windows plugins") }, "plugin warning not repeated")
            let view = SkinInstallFlow.accessoryView(summary, headerImage: NSImage(size: NSSize(width: 400, height: 60)))
            t.check(view.frame.width == 400 && view.frame.height > 60)

            // The whole flow (headless: confirmation accepted automatically).
            app.installer.open([url])
            spin { app.controller(for: "PkgRoot\\Widget") != nil && app.installer.isIdle }
            t.check(app.controller(for: "PkgRoot\\Widget") != nil, "the package's skin is loaded")
            t.check(FileManager.default.fileExists(atPath: app.skinsDirectory.appendingPathComponent("PkgRoot/Widget/Widget.ini").path))

            // Installing over a running skin: replaced, backed up, reloaded.
            let running = app.controller(for: "PkgRoot\\Widget")
            let againInspection = try RmskinPackage.inspect(url)
            let again = InstallSummary(againInspection, packageName: "Test.rmskin", skinsDirectory: app.skinsDirectory)
            againInspection.cleanup()
            t.check(again.skins.first?.detail?.contains("replaces") == true)
            app.installer.open([url])
            spin { app.installer.isIdle && app.controller(for: "PkgRoot\\Widget") !== running }
            t.check(app.controller(for: "PkgRoot\\Widget") != nil && app.controller(for: "PkgRoot\\Widget") !== running)
            t.check(running?.isStopped == true)
            t.check(FileManager.default.fileExists(atPath: app.backupsDirectory.appendingPathComponent("PkgRoot").path))

            // Broken and foreign files: errors, and the queue keeps going.
            let broken = t.temporaryDirectory("broken").appendingPathComponent("Broken.rmskin")
            try Data("not a zip".utf8).write(to: broken)
            let text = t.temporaryDirectory("text").appendingPathComponent("notes.txt")
            try Data("x".utf8).write(to: text)
            app.deactivate(config: "PkgRoot\\Widget")
            app.installer.open([broken, text, url])
            spin { app.installer.isIdle && app.controller(for: "PkgRoot\\Widget") != nil }
            t.check(app.controller(for: "PkgRoot\\Widget") != nil, "the valid package after a broken one installs")
            t.check(app.installer.isIdle)
        }
    }
}

/// The ten slowest suites with their share of the run (where CI's time goes).
func printSlowest(_ durations: [(name: String, seconds: TimeInterval)]) {
    let total = durations.reduce(0) { $0 + $1.seconds }
    guard durations.count > 1, total >= 1 else { return }
    print("")
    print(String(format: "Slowest suites (%d suites, %.0f s in all):", durations.count, total))
    for d in durations.sorted(by: { $0.seconds > $1.seconds }).prefix(10) {
        print(String(format: "  %7.1f s  %4.1f %%  %@", d.seconds, d.seconds / total * 100, d.name))
    }
}

/// Ends a run that is stuck in one suite, so CI says where instead of running into the job's time limit with nothing
/// in the log: after `limit` seconds in one suite it names the suite, prints every thread's stack (`/usr/bin/sample`)
/// and exits with status 3. `DESKSET_SUITE_TIMEOUT` (seconds; 600 by default) sets the limit; 0 turns the watchdog
/// off.
final class SuiteWatchdog {
    let limit: TimeInterval
    private let queue = DispatchQueue(label: "app.deskset.selftest.watchdog")
    private var timer: DispatchSourceTimer?
    private static let lock = NSLock()
    private static var firedSuite: String?

    /// The suite that ran over its limit, when the watchdog fired but the suite finished while its stacks were being
    /// printed (slow rather than stuck): the run still fails.
    static var overran: String? {
        lock.lock()
        defer { lock.unlock() }
        return firedSuite
    }

    init(defaultLimit: TimeInterval) {
        limit = ProcessInfo.processInfo.environment["DESKSET_SUITE_TIMEOUT"].flatMap(Double.init) ?? defaultLimit
    }

    func start(_ suite: String) {
        stop()
        guard limit > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + limit)
        let limit = self.limit
        timer.setEventHandler { SuiteWatchdog.fire(suite, after: limit) }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Runs on the watchdog's queue while the main thread is stuck: writes straight to the file descriptors (stdout is
    /// line-buffered, so the suites' lines are already out) and leaves with `_exit`, which does not wait for locks
    /// the stuck thread may hold.
    private static func fire(_ suite: String, after limit: TimeInterval) {
        lock.lock()
        firedSuite = suite
        lock.unlock()
        let seconds = String(format: "%g", limit)
        let note = "\n  HANG    \(suite): still running after \(seconds) s; the stacks of every thread follow\n"
        FileHandle.standardOutput.write(Data(note.utf8))
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(getpid()), "3", "-mayDie", "-file", "/dev/stdout"]
        sample.standardOutput = FileHandle.standardOutput
        sample.standardError = FileHandle.standardError
        if (try? sample.run()) != nil { sample.waitUntilExit() }
        FileHandle.standardOutput.write(Data("\n  HANG    \(suite): stopped the run\n".utf8))
        _exit(3)
    }
}

/// Minimal test harness mirroring DesksetSelfTest's TestRunner.
final class AppTestRunner {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var currentSuite = ""
    /// What the current suite puts back when it ends (`atSuiteEnd`).
    private var suiteCleanups: [() -> Void] = []
    private let filter: String?
    /// Folders made by `temporaryDirectory`, removed when the run finishes (fake app bundles left behind would stay
    /// registered with Launch Services and pile up).
    private var temporaryDirectories: [URL] = []
    /// How long each suite took (for the slowest ones listed by `finish()`).
    private var durations: [(name: String, seconds: TimeInterval)] = []
    private let watchdog = SuiteWatchdog(defaultLimit: 600)

    init(filter: String?) {
        self.filter = filter?.lowercased()
        IconServiceGuard.install()
        IconServiceGuard.onUse = { [weak self] stack in self?.iconServiceUsed(stack) }
        // Line by line, so a run that is stopped (CI's time limit, the watchdog) still shows how far it got.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    func suite(_ name: String, _ body: () throws -> Void) {
        if let filter, !name.lowercased().contains(filter) { return }
        currentSuite = name
        iconServiceReported = false
        let before = failures.count
        let start = ProcessInfo.processInfo.systemUptime
        watchdog.start(name)
        defer { watchdog.stop() }
        // Each suite's objects go when it ends: its editors are closed and what they autoreleased is drained. (The run
        // never returns to the run loop, so nothing else drains; on macOS 26 every button keeps a SwiftUI graph, and
        // thousands of editors' inspector pages filled its table and aborted the run.)
        autoreleasepool {
            do {
                try body()
            } catch {
                record("unexpected error thrown: \(error)", line: #line)
            }
            AppSelfTest.closeEditors()
            while let cleanup = suiteCleanups.popLast() { cleanup() }
        }
        let seconds = ProcessInfo.processInfo.systemUptime - start
        durations.append((name, seconds))
        let time = seconds >= 1 ? String(format: "  (%.1f s)", seconds) : ""
        print((failures.count == before ? "  ok      \(name)" : "  FAILED  \(name)") + time)
    }

    /// A suite asked the system's icon service (`IconServiceGuard`): one failure per suite, with where it was asked.
    private var iconServiceReported = false
    private func iconServiceUsed(_ stack: [String]) {
        guard !currentSuite.isEmpty, !iconServiceReported else { return }
        iconServiceReported = true
        let frames = stack.map { "        " + $0 }.joined(separator: "\n")
        record("asked the system's icon service, which never answers on CI's Intel runner (IconServiceGuard):\n"
               + frames, line: #line)
    }

    /// Runs `cleanup` when the current suite ends, after its editors are closed (the last one registered first): puts
    /// back what the suite replaced for its run, such as a fake audio device.
    func atSuiteEnd(_ cleanup: @escaping () -> Void) {
        suiteCleanups.append(cleanup)
    }

    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        if condition { passed += 1 } else { record("check failed \(message())", line: line) }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        if actual == expected {
            passed += 1
        } else {
            record("expected \(String(reflecting: expected)), got \(String(reflecting: actual)) \(message())", line: line)
        }
    }

    func close(_ actual: Double, _ expected: Double, accuracy: Double = 1e-6, _ message: @autoclosure () -> String = "",
               line: UInt = #line) {
        if abs(actual - expected) <= accuracy {
            passed += 1
        } else {
            record("expected \(expected) ± \(accuracy), got \(actual) \(message())", line: line)
        }
    }

    func close(_ actual: CGFloat, _ expected: CGFloat, accuracy: Double = 1e-6, _ message: @autoclosure () -> String = "",
               line: UInt = #line) {
        close(Double(actual), Double(expected), accuracy: accuracy, message(), line: line)
    }

    func temporaryDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesksetAppTest-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    func finish() -> Int32 {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        printSlowest(durations)
        if let suite = SuiteWatchdog.overran { failures.append("[\(suite)] ran over the watchdog's limit (see HANG)") }
        print("")
        if failures.isEmpty {
            print("All \(passed) checks passed.")
            return 0
        }
        print("\(failures.count) FAILED, \(passed) passed:")
        for f in failures { print("  - \(f)") }
        return 1
    }

    private func record(_ message: String, line: UInt) {
        let entry = "[\(currentSuite)] AppSelfTest.swift:\(line): \(message)"
        failures.append(entry)
        print("    ✗ \(entry)")
    }
}
