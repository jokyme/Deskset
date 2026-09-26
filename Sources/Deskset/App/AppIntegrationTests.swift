import AppKit
import DesksetCore

/// Checks of the app ↔ engine integration (run with `Deskset --self-test`, suites "App: …"): focus / wake / cursor /
/// tooltip / context-menu APIs of the engine, mouse semantics, forwarded and group bangs, deferred config changes,
/// Default… window settings, containers and bevels, background image options, EXIF orientation, WebParser file
/// access, system readings. Fixtures: TestSkins/App/Buttons, Container, Background, Defaults, Counter, Observer.
extension AppSelfTest {
    static func integrationTests(_ t: AppTestRunner) {
        renderingIntegrationTests(t)
        mouseIntegrationTests(t)
        bangIntegrationTests(t)
        defaultsIntegrationTests(t)
        systemIntegrationTests(t)
        integrationReviewTests(t)
    }

    /// RGBA (0…1) of a pixel (top-left origin).
    static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0, 0) }
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    // MARK: Rendering

    static func renderingIntegrationTests(_ t: AppTestRunner) {
        t.suite("App: containers and bevel colors") {
            guard let testSkins = Paths.repositoryFolder("TestSkins") else { return }
            let url = testSkins.appendingPathComponent("App/Container/Container.ini")
            guard let skin = loadSkin(url, config: "App\\Container", skins: testSkins),
                  let rep = drawSkin(skin, width: 300, height: 100) else {
                t.check(false, "Container.ini renders")
                return
            }
            func isColor(_ x: Int, _ y: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.1) -> Bool {
                let p = pixel(rep, x, y)
                return abs(p.r - r) <= tolerance && abs(p.g - g) <= tolerance && abs(p.b - b) <= tolerance
            }
            t.check(isColor(50, 50, 0, 1, 0), "content inside the disc container")
            t.check(isColor(14, 14, 0, 0, 0), "no content outside the disc (inside the container's frame)")
            t.check(isColor(150, 50, 0, 0.5, 0, tolerance: 0.08), "half-transparent container: half-opaque content")
            // Raised skin bevel: BevelColor (red) left and top, BevelColor2 (blue) right and bottom.
            t.check(isColor(5, 0, 1, 0, 0) && isColor(0, 50, 1, 0, 0), "raised: BevelColor on the top and left")
            t.check(isColor(50, 99, 0, 0, 1) && isColor(299, 50, 0, 0, 1), "raised: BevelColor2 on the bottom and right")
            // Sunken meter bevel: BevelColor (yellow) right and bottom, BevelColor2 (cyan) left and top.
            t.check(isColor(250, 10, 0, 1, 1) && isColor(210, 50, 0, 1, 1), "sunken: BevelColor2 on the top and left")
            t.check(isColor(250, 89, 1, 1, 0) && isColor(289, 50, 1, 1, 0), "sunken: BevelColor on the bottom and right")
            // The container itself is not drawn: its white fill never shows.
            t.check(!isColor(90, 50, 1, 1, 1), "the container is not drawn")
            skin.execute("[!HideMeter Disc][!Redraw]", from: nil)
            if let hidden = drawSkin(skin, width: 300, height: 100) {
                let p = pixel(hidden, 50, 50)
                t.check(p.g < 0.1, "content of a hidden container is not drawn")
            }
        }

        t.suite("App: background image options") {
            guard let testSkins = Paths.repositoryFolder("TestSkins") else { return }
            let dir = testSkins.appendingPathComponent("App/Background")
            guard let margins = loadSkin(dir.appendingPathComponent("Margins.ini"), config: "App\\Background",
                                         skins: testSkins),
                  let stretch = loadSkin(dir.appendingPathComponent("Stretch.ini"), config: "App\\Background",
                                         skins: testSkins),
                  let m = drawSkin(margins, width: 120, height: 60), let s = drawSkin(stretch, width: 120, height: 60)
            else {
                t.check(false, "Background skins render")
                return
            }
            func isBlue(_ p: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> Bool { p.b > 0.9 && p.r < 0.1 }
            func isOrange(_ p: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> Bool { p.r > 0.9 && p.b < 0.1 }
            // BackgroundMargins=10,10,10,10: the 10-pixel border stays 10 pixels wide.
            t.check(isOrange(pixel(m, 5, 5)) && isOrange(pixel(m, 114, 55)), "unscaled corners")
            t.check(isBlue(pixel(m, 12, 30)) && isBlue(pixel(m, 107, 30)) && isBlue(pixel(m, 60, 12)), "stretched center")
            // No margins: the whole image stretches (border 40 wide horizontally), ImageAlpha=128 halves it.
            let edge = pixel(s, 30, 30)
            t.check(edge.r > 0.9 && edge.b < 0.1, "stretched border")
            t.close(Double(edge.a), 128.0 / 255, accuracy: 0.03, "ImageAlpha applies to Background")
            t.check(pixel(s, 60, 30).b > 0.9, "stretched center")
        }

        t.suite("App: EXIF orientation only when asked") {
            guard let testSkins = Paths.repositoryFolder("TestSkins") else { return }
            let path = testSkins.appendingPathComponent("App/@Resources/Images/Exif6.tif").path
            t.equal(Images.size(atPath: path).map { [$0.width, $0.height] }, [40, 20], "stored pixels")
            t.equal(Images.exifOrientation(atPath: path), 6)
            t.equal(PreparedImage(path: path, options: ImageOptions())?.size, CGSize(width: 40, height: 20),
                    "UseExifOrientation=0 (default): raw pixels")
            var oriented = ImageOptions()
            oriented.useExifOrientation = true
            t.equal(PreparedImage(path: path, options: oriented)?.size, CGSize(width: 20, height: 40),
                    "UseExifOrientation=1: rotated")
            // Through the Image meter: its size follows the option.
            let root = t.temporaryDirectory("exif")
            let config = root.appendingPathComponent("Exif/Skin")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            let ini = config.appendingPathComponent("Skin.ini")
            try "[Rainmeter]\nUpdate=-1\n[Raw]\nMeter=Image\nImageName=\(path)\n[Turned]\nMeter=Image\nY=50\nImageName=\(path)\nUseExifOrientation=1\n"
                .write(to: ini, atomically: true, encoding: .utf8)
            if let skin = loadSkin(ini, config: "Exif\\Skin", skins: root) {
                t.equal(skin.meter(named: "Raw").map { [$0.frame.width, $0.frame.height] }, [40, 20])
                t.equal(skin.meter(named: "Turned").map { [$0.frame.width, $0.frame.height] }, [20, 40])
            } else {
                t.check(false, "EXIF skin loads")
            }
        }

        t.suite("App: measured text is the drawn text (Layout)") {
            guard let testSkins = Paths.repositoryFolder("TestSkins"),
                  let skin = loadSkin(testSkins.appendingPathComponent("Engine/Layout/Layout.ini"), config: "Engine\\Layout",
                                      skins: testSkins) else { return }
            skin.update()
            for case let m as StringMeter in skin.meters where !m.hidden {
                let drawn = SkinRenderContext.of(skin).text.layout(m.text, style: m.style, wrapWidth: nil,
                                                                   cycle: skin.updateCount)
                let needed = drawn.textWidth + 2 * drawn.pad
                t.check(Double(needed) <= m.contentFrame.width + 0.001,
                        "[\(m.name)] \(needed) fits in \(m.contentFrame.width)")
                t.check(m.frame.maxX <= skin.width && m.frame.maxY <= skin.height,
                        "[\(m.name)] inside the DynamicWindowSize skin")
                t.equal(SkinRenderer.textSize(m.text, style: m.style, wrapWidth: nil, for: skin).width,
                        Double(ceil(needed - 0.001)), "[\(m.name)] measured = drawn")
            }
            t.equal((skin.meter(named: "Info") as? StringMeter)?.text,
                    "Box3 at 190,15  Hidden at 180,10 (0x0)")

            // The same skin in a skin window (DynamicWindowSize=1): the window is the skin's size and no text
            // reaches the last pixel columns (the Info line used to look clipped at the right edge).
            guard let app = try makeApp(t) else { return }
            try FileManager.default.copyItem(at: testSkins.appendingPathComponent("Engine"),
                                             to: app.skinsDirectory.appendingPathComponent("Engine"))
            app.rescanLibrary()
            guard let c = app.activate(config: "Engine\\Layout", file: nil) else {
                t.check(false, "Engine\\Layout loads")
                return
            }
            c.skin.update()
            let size = c.view.bounds.size
            t.equal([Double(size.width), Double(size.height)], [c.skin.width, c.skin.height], "view = skin size")
            t.equal(c.window.frame.size, size)
            if let rep = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) {
                c.view.cacheDisplay(in: c.view.bounds, to: rep)
                let scale = Double(rep.pixelsWide) / Double(size.width)
                var textPixels = 0
                if let info = c.skin.meter(named: "Info") {
                    let top = Int(info.frame.y * scale), bottom = Int(info.frame.maxY * scale)
                    for y in top..<min(bottom, rep.pixelsHigh) {
                        for x in max(rep.pixelsWide - Int(2 * scale), 0)..<rep.pixelsWide {
                            let p = pixel(rep, x, y)
                            if p.r > 0.6 && p.g > 0.6 && p.b > 0.6 { textPixels += 1 }
                        }
                    }
                }
                t.equal(textPixels, 0, "no text in the last two points of the Info line")
            }
        }
    }

    // MARK: Mouse

    static func mouseIntegrationTests(_ t: AppTestRunner) {
        t.suite("App: buttons, right presses, cursors and tooltips") {
            guard let app = try makeApp(t), let c = app.activate(config: "App\\Buttons", file: nil) else { return }
            func v(_ name: String) -> String { c.skin.variable(name) ?? "" }
            let skin: Skin = c.skin
            // Button meter: its disc is the button, the transparent corners are not.
            t.check(SkinView.isOnButton(skin, x: 10, y: 10))
            t.check(!SkinView.isOnButton(skin, x: 1, y: 1), "transparent corner")
            t.equal(SkinView.leftMouseDown(c, x: 10, y: 90, clickCount: 1, override: false), true,
                    "the bottom 20 points drag (DragMargins=0,-20,0,0)")
            t.equal(SkinView.leftMouseDown(c, x: 150, y: 50, clickCount: 1, override: false), false,
                    "outside the drag area")
            t.equal(SkinView.leftMouseDown(c, x: 150, y: 50, clickCount: 1, override: true), true, "⌘ drags anywhere")

            // A press on the button does not drag; its release runs ButtonCommand. Leaving and re-entering the
            // skin while the button is held is not reported before the release (it would end the press).
            let view = c.view
            if let down = mouseEvent(.leftMouseDown, c, x: 10, y: 10) { view.mouseDown(with: down) }
            t.equal(view.dragAllowed, false, "no drag from a Button")
            t.equal(view.heldButtons, 1)
            if let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: c.window.windowNumber, context: nil, eventNumber: 0,
                                                 trackingNumber: 0, userData: nil) {
                view.mouseExited(with: exit)
            }
            if let up = mouseEvent(.leftMouseUp, c, x: 10, y: 10) { view.mouseUp(with: up) }
            t.equal(v("Command"), "1", "ButtonCommand runs on release despite the exit while pressed")
            t.equal(view.heldButtons, 0)

            // A press that became a drag is not a click.
            c.skin.setVariable("Command", "0")
            c.skin.mouseEvent(.leftDown, x: 10, y: 10)
            SkinView.endMousePress(c, x: 10, y: 10)
            c.skin.mouseEvent(.leftUp, x: 10, y: 10)
            t.equal(v("Command"), "0", "no ButtonCommand after a drag")

            // Double clicks run the DoubleClick and the Down action; Down actions block dragging and the menu.
            t.equal(SkinView.leftMouseDown(c, x: 40, y: 10, clickCount: 2, override: false), false)
            t.equal([v("DoubleLeft"), v("LeftDown")], ["1", "1"])
            t.equal(SkinView.buttonDown(c, down: .rightDown, double: .rightDoubleClick, x: 40, y: 10, clickCount: 1),
                    true, "RightMouseDownAction replaces the skin menu")
            t.equal([v("RightDown"), v("DoubleRight")], ["1", "0"])
            c.skin.setVariable("RightDown", "0")
            SkinView.buttonDown(c, down: .rightDown, double: .rightDoubleClick, x: 40, y: 10, clickCount: 2)
            t.equal([v("RightDown"), v("DoubleRight")], ["1", "1"], "a right double click runs both")
            t.equal(SkinView.buttonDown(c, down: .rightDown, double: .rightDoubleClick, x: 150, y: 50, clickCount: 1),
                    false, "no right action: the skin menu opens")
            t.check(SkinView.isDoubleClick(2) && SkinView.isDoubleClick(4) && !SkinView.isDoubleClick(3))

            // Cursors: the pointer over a Button and over mouse actions, MouseActionCursorName otherwise.
            t.equal(SkinView.cursorName(skin, x: 10, y: 10), "HAND")
            t.equal(SkinView.cursorName(skin, x: 1, y: 1), nil)
            t.equal(SkinView.cursorName(skin, x: 40, y: 10), "Text")
            t.equal(SkinView.cursorName(skin, x: 65, y: 10), nil, "tooltips alone do not change the cursor")
            t.check(SkinView.cursor(named: "HAND") === NSCursor.pointingHand)
            t.check(SkinView.cursor(named: "text") === NSCursor.iBeam)
            t.check(SkinView.cursor(named: nil) === NSCursor.arrow)
            t.check(SkinView.cursor(named: "Custom.cur") === NSCursor.arrow)

            // Tooltips: one area per meter with a tooltip, so moving between meters shows the other text.
            t.equal(view.toolTipRects, [CGRect(x: 60, y: 0, width: 20, height: 20), CGRect(x: 80, y: 0, width: 20, height: 20)])
            t.equal(view.toolTipText(x: 65, y: 5), "A\nFirst tip")
            t.equal(view.toolTipText(x: 85, y: 5), "Second tip")
            t.equal(view.toolTipText(x: 105, y: 5), nil, "ToolTipHidden=1 on the meter")
            // Deskset is almost never the active app (a menu bar app with non-activating panels): its panels show
            // tooltips anyway.
            t.check(c.window.allowsToolTipsWhenApplicationIsInactive, "tooltips while another app is in front")
            let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
            t.equal(registered["NSInitialToolTipDelay"] as? Int, 500, "tooltips after half a second, as on Windows")
            c.skin.execute("[!HideMeter MeterTipB][!Redraw]", from: nil)
            t.equal(view.toolTipRects.count, 1, "areas follow the meters")
            let panel = c.window
            app.changeSettings(of: c) { $0.clickThrough = true }
            t.equal(view.toolTipRects.count, 0, "ClickThrough: no tooltips")
            app.changeSettings(of: c) { $0.clickThrough = false }
            t.equal(view.toolTipRects.count, 1)
            t.check(c.window !== panel, "leaving ClickThrough replaces the panel")
            t.check(c.window.allowsToolTipsWhenApplicationIsInactive, "the new panel shows tooltips in the background")
        }
    }

    // MARK: Bangs

    static func bangIntegrationTests(_ t: AppTestRunner) {
        t.suite("App: bangs for all skins and skin groups") {
            guard let app = try makeApp(t), let observer = app.activate(config: "App\\Observer", file: nil),
                  let once = app.activate(config: "App\\Once", file: nil),
                  let focus = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            func loads() -> Double { observer.skin.measure(named: "MeasureLoads")?.value ?? -1 }
            let before = loads()
            observer.skin.execute("[!UpdateMeasure MeasureLoads *]", from: nil)
            t.close(loads(), before + 1, "`*` performs the bang once on the sending skin")
            observer.skin.execute(#"[!SetVariable Marker "sent to all" *]"#, from: nil)
            t.equal([observer, once, focus].map { $0.skin.variable("Marker") ?? "" }, Array(repeating: "sent to all", count: 3))

            // Skin group bangs (Focus is in DesksetAppTest and Widgets).
            once.skin.execute("[!AutoSelectScreenGroup 1 Widgets]", from: nil)
            t.equal(focus.state.autoSelectScreen, true)
            t.equal(once.state.autoSelectScreen, false)
            focus.skin.execute("[!AutoSelectScreen 0]", from: nil)
            t.equal(focus.state.autoSelectScreen, false)
            once.skin.execute(#"[!DisableMouseActionSkinGroup "LeftMouseUpAction" Widgets]"#, from: nil)
            t.equal(focus.skin.rainmeterSection?.mouseActionState(.leftUp), .disabled)
            t.equal(once.skin.rainmeterSection?.mouseActionState(.leftUp), .enabled)
            once.skin.execute(#"[!UpdateGroup "DesksetAppTest"][!RedrawGroup Widgets]"#, from: nil)
            t.equal(app.controllers(inGroup: "widgets").map(\.config), ["App\\Focus"])
        }

        t.suite("App: refresh is deferred and keeps the Counter") {
            guard let app = try makeApp(t), let c = app.activate(config: "App\\Counter", file: nil) else { return }
            for _ in 0..<3 { c.skin.update() }
            // Counter = updates completed before this one (0 in the first update).
            t.close(c.skin.measure(named: "MeasureCounter")?.value ?? -1, 3)
            c.skin.execute("[!Refresh]", from: nil)
            t.check(app.controller(for: "App\\Counter") === c, "the skin is not replaced inside its own action")
            spin { app.controller(for: "App\\Counter") !== c }
            guard let refreshed = app.controller(for: "App\\Counter") else {
                t.check(false, "refreshed")
                return
            }
            t.close(refreshed.skin.measure(named: "MeasureCounter")?.value ?? -1, 4, "the Counter continues after a refresh")
            app.deactivate(config: "App\\Counter")
            let reloaded = app.activate(config: "App\\Counter", file: nil)
            t.close(reloaded?.skin.measure(named: "MeasureCounter")?.value ?? -1, 0, "…and restarts when loaded again")
        }
    }

    // MARK: Default settings

    static func defaultsIntegrationTests(_ t: AppTestRunner) {
        t.suite("App: Default… window settings on the first load") {
            var s = SkinState(file: "x")
            s = SkinController.seededState(s, defaults: ["AlwaysOnTop": "9", "AlphaValue": "(100+28)", "Draggable": "x",
                                                         "FadeDuration": "-5", "ClickThrough": "1"])
            t.equal([s.alwaysOnTop, s.alphaValue, s.fadeDuration], [2, 128, 0])
            t.equal(s.draggable, true, "unreadable values keep the default")
            t.equal(s.clickThrough, true)

            guard let app = try makeApp(t), let c = app.activate(config: "App\\Defaults", file: nil) else { return }
            let st = c.state
            t.equal([st.alwaysOnTop, st.alphaValue, st.onHover, st.fadeDuration], [1, 200, 2, 400])
            t.equal([st.draggable, st.snapEdges, st.keepOnScreen, st.clickThrough, st.savePosition],
                    [false, false, false, true, false])
            t.equal([st.startHidden, st.autoSelectScreen], [true, true])
            t.check(c.isHiddenByBang, "StartHidden: loaded hidden")
            t.equal((c.skin.meter(named: "MeterText") as? StringMeter)?.text, "Zpos 1", "#CURRENTCONFIGZPOS#")
            t.check(!(c.skin.variable("CONFIGEDITOR") ?? "").isEmpty, "#CONFIGEDITOR#")
            let screens = WindowGeometry.currentScreens()
            if let primary = screens.first {
                // DefaultWindowX=50% with DefaultAnchorX=50%: centered; DefaultWindowY=20B with DefaultAnchorY=100%:
                // the bottom edge 20 points above the screen's bottom.
                t.close(c.window.frame.midX, primary.frame.midX, accuracy: 1)
                t.close(c.window.frame.minY, primary.frame.minY + 20, accuracy: 1)
            }
            c.skin.execute("[!Show]", from: nil)
            t.check(!c.isHiddenByBang)
            // Later loads keep the saved settings.
            app.changeSettings(of: c) { $0.alphaValue = 90 }
            app.deactivate(config: "App\\Defaults")
            let again = app.activate(config: "App\\Defaults", file: nil)
            t.equal(again?.state.alphaValue, 90, "defaults apply only the first time")
        }
    }

    // MARK: System

    static func systemIntegrationTests(_ t: AppTestRunner) {
        t.suite("App: WebParser file access") {
            let root = t.temporaryDirectory("webparser")
            let skins = root.appendingPathComponent("Skins")
            let settings = root.appendingPathComponent("Settings")
            let outside = root.appendingPathComponent("Private")
            for dir in [skins.appendingPathComponent("A"), settings, outside] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(at: skins.appendingPathComponent("A/Link"), withDestinationURL: outside)
            let roots = [skins, settings]
            t.check(WebParserAccess.isAllowed(skins.appendingPathComponent("A/data.txt").path, roots: roots))
            t.check(WebParserAccess.isAllowed(settings.appendingPathComponent("x.json").path, roots: roots))
            t.check(!WebParserAccess.isAllowed(outside.appendingPathComponent("secret.txt").path, roots: roots))
            t.check(!WebParserAccess.isAllowed(skins.appendingPathComponent("A/../../Private/x").path, roots: roots),
                    "no escape with ..")
            t.check(!WebParserAccess.isAllowed(skins.appendingPathComponent("A/Link/secret.txt").path, roots: roots),
                    "no escape through a symbolic link")
            try "x".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
            t.check(!WebParserAccess.isAllowed(skins.path + "/A/Link/secret.txt", roots: roots), "existing file behind a link")
            try FileManager.default.createDirectory(at: outside.appendingPathComponent("Sub"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: skins.appendingPathComponent("A/Deep"),
                                                       withDestinationURL: outside.appendingPathComponent("Sub"))
            t.check(!WebParserAccess.isAllowed(skins.path + "/A/Deep/../secret.txt", roots: roots), "`..` after a link")
            t.check(!WebParserAccess.isAllowed(skins.path + "/A/Missing/../../Skins/A/x", roots: roots),
                    "`..` after a missing folder cannot be opened")
            t.check(WebParserAccess.isAllowed(skins.path + "/A/./sub/new.txt", roots: roots))
            t.check(!WebParserAccess.isAllowed(skins.path, roots: roots), "the folder itself is not a file in it")
            t.check(!WebParserAccess.isAllowed("relative/path", roots: roots))
            t.check(!WebParserAccess.isAllowed("/etc/hosts", roots: roots))
        }

        t.suite("App: SysInfo, volumes and CPU frequency") {
            let m = SystemMonitor.shared
            let values = SystemReport.sysInfoValues()
            t.equal(values.count, SystemReport.sysInfoTypes.count)
            for (type, text) in values { t.check(text != "(unsupported)", "SysInfo \(type) through the engine") }
            let byType = Dictionary(uniqueKeysWithValues: values.map { ($0.type, $0.text) })
            t.equal(byType["OS_BITS"], "64")
            t.equal(byType["USER_NAME"], NSUserName())
            t.check(!(byType["COMPUTER_NAME"] ?? "").isEmpty && !(byType["HOST_NAME"] ?? "").isEmpty)
            // Timestamps are seconds since 1601 (after 2001-01-01 = 12_622_780_800).
            for type in ["LAST_WAKE_TIME", "USER_LOGONTIME"] {
                let n = m.sysInfo(type: type, data: "")?.number ?? 0
                t.check(n == 0 || n > 12_622_780_800, "\(type) is a Windows timestamp: \(n)")
            }
            t.check((m.sysInfo(type: "IDLE_TIME", data: "")?.number ?? -1) >= 0)
            t.equal(m.sysInfo(type: "ADAPTER_STATE", data: "no-such-if9")?.string, "Unknown")
            t.equal(SystemMonitor.mediaActive("lo0"), nil, "loopback has no medium")
            t.equal(SystemMonitor.mediaActive("no-such-if9"), nil)
            if let best = m.bestNetworkInterface(), SystemMonitor.mediaActive(best) != nil {
                t.equal(SystemMonitor.mediaActive(best), true, "the best interface has a link")
                t.equal(m.sysInfo(type: "ADAPTER_STATE", data: best)?.number, 1)
            }
            let mac = m.sysInfo(type: "MAC_ADDRESS", data: "")?.string ?? ""
            t.check(mac.isEmpty || mac.split(separator: ":").count == 6, "MAC address \(mac)")

            let root = m.volumeInfo(path: "/")
            t.equal(root?.kind, .fixed)
            t.check(!(root?.label ?? "").isEmpty, "startup volume name")
            t.check(m.volumeInfo(path: "/no/such/volume") == nil, "missing: Removed")
            t.equal(SystemMonitor.volumeKind(fileSystem: "smbfs", local: false, removable: false), .network)
            t.equal(SystemMonitor.volumeKind(fileSystem: "cd9660", local: true, removable: true), .cdRom)
            t.equal(SystemMonitor.volumeKind(fileSystem: "tmpfs", local: true, removable: false), .ram)
            t.equal(SystemMonitor.volumeKind(fileSystem: "msdos", local: true, removable: true), .removable)
            t.equal(SystemMonitor.volumeKind(fileSystem: "apfs", local: true, removable: false), .fixed)
            if let hz = m.cpuFrequency() { t.check(hz > 1e8, "CPU frequency \(hz)") }
            // Intel Macs have a PCI graphics processor with a name; Apple silicon's is part of the chip.
            if let gpu = m.graphicsAdapterName() { t.check(!gpu.isEmpty, "graphics processor \(gpu)") }
        }
    }

    // MARK: Review fixes

    static func integrationReviewTests(_ t: AppTestRunner) {
        t.suite("App: a label over a Button, right double clicks") {
            guard let app = try makeApp(t), let c = app.activate(config: "App\\Buttons", file: nil) else { return }
            let skin: Skin = c.skin
            // The label (no actions) is on top of the button; clicks there still press the button, so the pointer
            // shows there too.
            t.check(SkinView.isOnButton(skin, x: 10, y: 10), "the press goes to the button under the label")
            t.equal(SkinView.cursorName(skin, x: 10, y: 10), "HAND", "pointer over the label on the button")
            t.equal(SkinView.cursorName(skin, x: 1, y: 1), nil, "transparent corner")
            // RightMouseDoubleClickAction alone "disables the context menu" (the menu would swallow the second click).
            t.equal(SkinView.showsSkinMenu(skin, x: 130, y: 10), false)
            t.equal(SkinView.showsSkinMenu(skin, x: 150, y: 50), true, "no right actions: the menu opens")
            t.equal(SkinView.buttonDown(c, down: .rightDown, double: .rightDoubleClick, x: 130, y: 10, clickCount: 2),
                    true)
            t.equal(c.skin.variable("DoubleRight"), "1")
        }

        t.suite("App: bangs for a config an earlier bang is loading") {
            guard let app = try makeApp(t), let observer = app.activate(config: "App\\Observer", file: nil) else { return }
            observer.skin.execute(#"[!ActivateConfig "App\Once"][!SetVariable Marker "after load" "App\Once"]"#
                                  + #"[!Hide "App\Once"][!Move 40 50 "App\Once"]"#, from: nil)
            t.check(app.controller(for: "App\\Once") == nil, "loaded on a later run loop turn")
            t.check(app.isLoadPending("App\\Once"))
            spin { app.controller(for: "App\\Once")?.skin.variable("Marker") == "after load" }
            guard let once = app.controller(for: "App\\Once") else {
                t.check(false, "App\\Once loaded")
                return
            }
            t.equal(once.skin.variable("Marker"), "after load", "forwarded bang reaches the skin loaded before it")
            spin { once.isHiddenByBang }
            t.check(once.isHiddenByBang, "!Hide for the loading config")
            t.close(once.topLeftPosition.x, 40, accuracy: 0.5, "!Move for the loading config")
            t.check(!app.isLoadPending("App\\Once"))

            // Another variant of a running config: the bang reaches the new variant, not the one it replaces.
            guard let focus = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            observer.skin.execute(#"[!ActivateConfig "App\Focus" "Compact.ini"][!SetVariable Marker "new variant" "App\Focus"]"#,
                                  from: nil)
            spin { app.controller(for: "App\\Focus")?.skin.variable("Marker") == "new variant" }
            t.equal(app.controller(for: "App\\Focus")?.file, "Compact.ini")
            t.equal(app.controller(for: "App\\Focus")?.skin.variable("Marker"), "new variant")
            t.check(focus.isStopped)
            // "If no file is specified, the next .ini file variant in the config folder is activated."
            t.equal(app.nextVariant(of: "App\\Focus"), "Focus.ini")
            observer.skin.execute(#"[!ActivateConfig "App\Focus"]"#, from: nil)
            spin { app.controller(for: "App\\Focus")?.file == "Focus.ini" }
            t.equal(app.controller(for: "App\\Focus")?.file, "Focus.ini", "next variant")
            t.equal(app.nextVariant(of: "App\\Focus"), "Compact.ini", "after the last one: the first")
            t.equal(app.nextVariant(of: "App\\Counter"), nil, "not running")

            // Activate, then deactivate in the same action: the skin ends up unloaded.
            observer.skin.execute(#"[!ActivateConfig "App\Counter"][!DeactivateConfig "App\Counter"]"#, from: nil)
            spin { !app.isLoadPending("App\\Counter") }
            RenderCommand.wait(milliseconds: 50)
            t.check(app.controller(for: "App\\Counter") == nil, "!DeactivateConfig after !ActivateConfig")

            // A config that cannot be loaded does not keep bangs waiting; bangs for configs nobody loads are not held.
            observer.skin.execute(#"[!ActivateConfig "App\NoSuchConfig"][!SetVariable Marker x "App\NoSuchConfig"]"#,
                                  from: nil)
            t.check(app.isLoadPending("App\\NoSuchConfig"))
            spin { !app.isLoadPending("App\\NoSuchConfig") }
            t.check(!app.isLoadPending("App\\NoSuchConfig"))
            t.check(!app.isLoadPending("App\\Controls"))
        }

        t.suite("App: !ActivateConfig of the file a config already runs changes nothing") {
            guard let app = try makeApp(t), let observer = app.activate(config: "App\\Observer", file: nil),
                  let focus = app.activate(config: "App\\Focus", file: "Focus.ini"),
                  let once = app.activate(config: "App\\Once", file: nil) else { return }
            /// Runs `action` in `sender` and waits until the loads it scheduled have run.
            func activate(_ action: String, from sender: SkinController) {
                sender.skin.execute(action, from: nil)
                spin { !app.isLoadPending("App\\Focus") && !app.isLoadPending("App\\Once") }
                RenderCommand.wait(milliseconds: 50)
            }
            // Asked by another skin (the file name in any case) or by the skin itself; bangs after it reach the
            // running skin.
            activate(#"[!ActivateConfig "App\Focus" "focus.INI"]"#, from: observer)
            activate(#"[!ActivateConfig "App\Focus" "Focus.ini"][!SetVariable Marker "still here" "App\Focus"]"#,
                     from: focus)
            t.check(app.controller(for: "App\\Focus") === focus && !focus.isStopped, "not reloaded")
            t.equal(focus.skin.variable("Marker"), "still here")
            // A missing file falls back to the last used one, which is running.
            activate(#"[!ActivateConfig "App\Focus" "Nope.ini"]"#, from: observer)
            t.check(app.controller(for: "App\\Focus") === focus && !focus.isStopped, "missing file")
            // Without a file: "the next .ini file variant", which for a config with one file is the running one.
            activate(#"[!ActivateConfig "App\Once"]"#, from: observer)
            t.check(app.controller(for: "App\\Once") === once && !once.isStopped, "single variant")
            // Another variant still replaces the running one, and !Refresh still reloads.
            activate(#"[!ActivateConfig "App\Focus" "Compact.ini"]"#, from: observer)
            t.equal(app.controller(for: "App\\Focus")?.file, "Compact.ini")
            t.check(focus.isStopped)
            once.skin.execute("[!Refresh]", from: nil)
            spin { app.controller(for: "App\\Once") !== once }
            t.check(app.controller(for: "App\\Once") !== once && once.isStopped, "!Refresh reloads")
        }

        t.suite("App: a skin that activates its own config on load loads once") {
            guard let app = try makeApp(t), let observer = app.activate(config: "App\\Observer", file: nil) else { return }
            // An update notice that asks for itself on every load (Monstercat Visualizer's does, while a newer version
            // exists): reloading it would repeat forever.
            let folder = app.skinsDirectory.appendingPathComponent("Loop/Notice", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
            [Rainmeter]
            Update=100
            OnRefreshAction=[!UpdateMeasure MeasureLoads "App\\Observer"][!ActivateConfig "Loop\\Notice" "Notice.ini"]

            [MeterNotice]
            Meter=String
            Text=A newer version is available
            """.write(to: folder.appendingPathComponent("Notice.ini"), atomically: true, encoding: .utf8)
            app.rescanLibrary()
            func loads() -> Double { observer.skin.measure(named: "MeasureLoads")?.value ?? -1 }
            let before = loads()
            guard let notice = app.activate(config: "Loop\\Notice", file: nil) else {
                t.check(false, "Loop\\Notice loads")
                return
            }
            t.close(loads(), before + 1)
            spin { !app.isLoadPending("Loop\\Notice") }
            RenderCommand.wait(milliseconds: 300)
            t.check(app.controller(for: "Loop\\Notice") === notice && !notice.isStopped, "not reloaded")
            t.close(loads(), before + 1, "loaded once")
            app.deactivate(config: "Loop\\Notice")
        }

        t.suite("App: no tooltips for the content of a hidden container") {
            guard let app = try makeApp(t), let c = app.activate(config: "App\\Container", file: nil) else { return }
            t.equal(c.view.toolTipRects.count, 1)
            t.equal(c.view.toolTipText(x: 50, y: 50), "Inside the disc")
            c.skin.execute("[!HideMeter Disc][!Redraw]", from: nil)
            t.equal(c.view.toolTipRects.count, 0, "hidden container: its content has no tooltip area")
            t.equal(c.view.toolTipText(x: 50, y: 50), nil)
            c.skin.execute("[!ShowMeter Disc][!Redraw]", from: nil)
            t.equal(c.view.toolTipRects.count, 1)
        }

        t.suite("App: WebParser file access without reading unrelated paths") {
            t.equal(WebParserAccess.lexicalComponents("/a/./b//c/../d"), ["/", "a", "b", "d"])
            t.equal(WebParserAccess.lexicalComponents("/../x"), ["/", "x"])
            let root = t.temporaryDirectory("webparser-lexical")
            let skins = root.appendingPathComponent("Skins")
            let outside = root.appendingPathComponent("Elsewhere")
            try FileManager.default.createDirectory(at: skins.appendingPathComponent("A"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try "x".write(to: skins.appendingPathComponent("A/data.txt"), atomically: true, encoding: .utf8)
            // A link outside the roots that points into them: the path is not written inside a root, so it is
            // refused without resolving it (paths like /Volumes/Server/… are never touched on the main thread).
            try FileManager.default.createSymbolicLink(at: outside.appendingPathComponent("ToSkins"), withDestinationURL: skins)
            t.check(!WebParserAccess.isAllowed(outside.path + "/ToSkins/A/data.txt", roots: [skins]))
            t.check(WebParserAccess.isAllowed(skins.path + "/A/data.txt", roots: [skins]))
            // The engine hands over standardized paths (/private/var/… → /var/…): both spellings of a root count.
            t.check(WebParserAccess.isAllowed((skins.path as NSString).standardizingPath + "/A/data.txt", roots: [skins]))
            if let real = realpath(skins.path, nil) {
                let resolved = String(cString: real)
                free(real)
                t.check(WebParserAccess.isAllowed(resolved + "/A/data.txt", roots: [skins]))
            }
        }

        t.suite("App: running programs and #CONFIGEDITOR#") {
            guard let testSkins = Paths.repositoryFolder("TestSkins"),
                  let skin = loadSkin(testSkins.appendingPathComponent("App/Buttons/Buttons.ini"), config: "App\\Buttons",
                                      skins: testSkins) else { return }
            // `["#CONFIGEDITOR#" "#CURRENTPATH#Buttons.ini"]` reaches the host as the editor and its file argument.
            let editor = "/System/Applications/TextEdit.app"
            let parsed = ActionParser.parse(#"["\#(editor)" "\#(skin.directory.path)/Buttons.ini"]"#)
            t.equal(parsed, [.execute(target: editor, arguments: [skin.directory.path + "/Buttons.ini"])])
            let file = skin.directory.appendingPathComponent("Buttons.ini")
            if FileManager.default.fileExists(atPath: editor) {
                t.equal(SkinController.executePlan(skin, target: editor, arguments: [file.path]),
                        .openFiles([URL(fileURLWithPath: file.path)], app: URL(fileURLWithPath: editor)),
                        "the file opens in the editor")
                t.equal(SkinController.executePlan(skin, target: editor, arguments: ["Buttons.ini"]),
                        .openFiles([URL(fileURLWithPath: file.path)], app: URL(fileURLWithPath: editor)),
                        "relative to the skin folder")
                t.equal(SkinController.executePlan(skin, target: editor, arguments: []),
                        .open(URL(fileURLWithPath: editor)), "no file: the app opens")
                t.equal(SkinController.executePlan(skin, target: editor, arguments: ["-n", "https://example.com/a"]),
                        .openFiles([URL(string: "https://example.com/a")!], app: URL(fileURLWithPath: editor)),
                        "URLs are handed to the app, other words are dropped")
            }
            t.equal(SkinController.executePlan(skin, target: "Buttons.ini", arguments: []),
                    .open(URL(fileURLWithPath: file.path)))
            t.equal(SkinController.executePlan(skin, target: "https://example.com", arguments: []),
                    .open(URL(string: "https://example.com")!))
            t.equal(SkinController.executePlan(skin, target: "notepad.exe", arguments: ["x"]), .unsupported("notepad.exe"))
            t.equal(SkinController.executePlan(skin, target: "  ", arguments: []), .nothing)
        }
    }
}
