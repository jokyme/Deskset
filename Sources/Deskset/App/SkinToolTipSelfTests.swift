import AppKit
import DesksetCore

/// Skin tooltips drawn by Deskset (`SkinToolTipPresenter`, `SkinToolTipLayout`): ToolTipTitle, ToolTipIcon, ToolTipType
/// and ToolTipWidth.
enum SkinToolTipSelfTests {
    static let area = NSRect(x: 0, y: 0, width: 1440, height: 900)

    static func run(_ t: AppTestRunner) {
        t.suite("App: tooltips: layout of plain, titled, wrapped and balloon tooltips") {
            let pointer = NSPoint(x: 400, y: 500)
            let plain = SkinToolTipLayout(info: ToolTipInfo(text: "Hello"), hasIcon: false, pointer: pointer, area: area)
            t.equal(plain.frame.minX, 400, "starts at the pointer")
            t.equal(plain.frame.maxY, 500 - SkinToolTipLayout.cursorClearance, "below the cursor")
            t.check(plain.titleFrame == nil && plain.iconFrame == nil && plain.stemTip == nil)
            t.check(plain.textFrame.map { plain.body.contains($0) } ?? false)

            let long = String(repeating: "word ", count: 80)
            let wide = SkinToolTipLayout(info: ToolTipInfo(text: long), hasIcon: false, pointer: pointer, area: area)
            let narrow = SkinToolTipLayout(info: ToolTipInfo(text: long, maxWidth: 200), hasIcon: false, pointer: pointer,
                                           area: area)
            t.check(narrow.frame.width <= 200, "ToolTipWidth limits the width: \(narrow.frame.width)")
            t.check(narrow.frame.height > wide.frame.height, "and the text wraps onto more lines")
            t.check(wide.frame.width <= 1000, "the default width is 1000")

            let title = String(repeating: "Title ", count: 20)
            let titled = SkinToolTipLayout(info: ToolTipInfo(text: "x", title: title, icon: "Info", maxWidth: 100),
                                           hasIcon: true, pointer: pointer, area: area)
            let titleWidth = SkinToolTipLayout.measure(title, font: SkinToolTipLayout.titleFont, width: nil).width
            t.check((titled.titleFrame?.width ?? 0) >= titleWidth, "the title stays on one line")
            t.check(titled.iconFrame != nil, "the icon goes before the title")
            t.check((titled.titleFrame?.minX ?? 0) > (titled.iconFrame?.maxX ?? .infinity))
            t.check((titled.textFrame?.minY ?? 0) >= (titled.titleFrame?.maxY ?? .infinity), "the text below the title")
            let untitled = SkinToolTipLayout(info: ToolTipInfo(text: "x", icon: "Info"), hasIcon: true, pointer: pointer,
                                             area: area)
            t.check(untitled.iconFrame == nil, "no icon without a title")

            let balloon = SkinToolTipLayout(info: ToolTipInfo(text: "Balloon", balloon: true), hasIcon: false,
                                            pointer: pointer, area: area)
            t.equal(balloon.frame.maxY, 500, "the stem starts at the pointer")
            t.check(balloon.stemUp)
            t.equal(balloon.stemTip.map { $0.x + balloon.frame.minX }, 400, "and points at it")
            t.equal(balloon.body.minY, SkinToolTipLayout.stemHeight, "the body is below the stem")
            t.check(balloon.cornerRadius > plain.cornerRadius)

            let low = SkinToolTipLayout(info: ToolTipInfo(text: "Balloon", balloon: true), hasIcon: false,
                                        pointer: NSPoint(x: 400, y: 5), area: area)
            t.check(!low.stemUp && low.frame.minY >= 5, "above the pointer near the bottom of the screen")
            let edge = SkinToolTipLayout(info: ToolTipInfo(text: long), hasIcon: false,
                                         pointer: NSPoint(x: 1430, y: 500), area: area)
            t.check(edge.frame.maxX <= area.maxX, "kept on the screen")
        }

        t.suite("App: tooltips: preset and file icons") {
            for preset in ["Info", "warning", "ERROR", "Question", "Shield"] {
                t.check(SkinToolTipLayout.iconImage(ToolTipInfo(text: "x", title: "T", icon: preset), skinView: nil) != nil,
                        preset)
            }
            t.check(SkinToolTipLayout.iconImage(ToolTipInfo(text: "x", title: "T", icon: "Sparkle"), skinView: nil) == nil)
            t.check(SkinToolTipLayout.iconImage(ToolTipInfo(text: "x", icon: "Info"), skinView: nil) == nil,
                    "ToolTipTitle must be specified to use ToolTipIcon")
            let dir = t.temporaryDirectory("tooltip-icons")
            defer { try? FileManager.default.removeItem(at: dir) }
            let png = dir.appendingPathComponent("Tip.png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            try rep.representation(using: .png, properties: [:])!.write(to: png)
            let file = SkinToolTipLayout.iconImage(ToolTipInfo(text: "x", title: "T", icon: png.path), skinView: nil)
            t.equal(file?.size, NSSize(width: SkinToolTipLayout.iconSize, height: SkinToolTipLayout.iconSize))
            t.check(SkinToolTipLayout.iconImage(ToolTipInfo(text: "x", title: "T", icon: dir.appendingPathComponent("No.ico").path),
                                                skinView: nil) == nil, "a missing file")
        }

        t.suite("App: tooltips: appear after a rest, stay over the same meter, go on leaving") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let config = "ToolTips\\Main"
            let folder = SkinLibrary.directory(for: config, root: app.skinsDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
            [Rainmeter]
            Update=-1
            [A]
            Meter=Image
            W=40
            H=40
            SolidColor=0,0,0,255
            ToolTipText=First
            ToolTipTitle=One
            ToolTipIcon=Info
            ToolTipType=1
            [B]
            Meter=Image
            X=50
            W=40
            H=40
            SolidColor=0,0,0,255
            ToolTipText=Second
            ToolTipWidth=120
            """.write(to: folder.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
            app.state.update(config) { $0.file = "Skin.ini"; $0.x = 100; $0.y = 100 }
            guard let c = app.activate(config: config, file: "Skin.ini") else { return t.check(false, "loads") }
            t.atSuiteEnd { app.stopAllForTermination() }
            t.check(AppSelfTest.spin { c.isStarted })
            let tips = app.skinToolTips
            let point = NSPoint(x: 120, y: 700)
            guard let a = c.view.toolTipInfo(x: 10, y: 10), let b = c.view.toolTipInfo(x: 60, y: 10) else {
                return t.check(false, "both meters have tooltips")
            }
            t.equal(a, ToolTipInfo(text: "First", title: "One", icon: "Info", balloon: true))
            t.equal(b.maxWidth, 120)

            tips.pointerMoved(in: c.view, info: a, at: point)
            t.check(tips.pending != nil && tips.shown == nil, "waits before appearing")
            tips.pointerMoved(in: c.view, info: a, at: NSPoint(x: 125, y: 700))
            t.equal(tips.pending?.point, NSPoint(x: 125, y: 700), "follows the pointer until it appears")
            tips.showPending()
            t.equal(tips.shown?.info, a)
            t.check(tips.shown?.layout.stemTip != nil, "ToolTipType=1 is a balloon")
            t.check(tips.shown?.layout.iconFrame != nil, "with the Info icon")
            let frame = tips.shown?.layout.frame
            tips.pointerMoved(in: c.view, info: a, at: NSPoint(x: 160, y: 690))
            t.equal(tips.shown?.layout.frame, frame, "stays put over the same meter")
            t.check(tips.pending == nil)

            tips.pointerMoved(in: c.view, info: b, at: point)
            t.check(tips.shown == nil && tips.pending?.info == b, "moving to another meter starts its tooltip")
            tips.showPending()
            t.equal(tips.shown?.info, b)
            tips.pointerMoved(in: c.view, info: nil, at: point)
            t.check(tips.shown == nil && tips.pending == nil, "no tooltip where there is none")

            tips.pointerMoved(in: c.view, info: ToolTipInfo(text: ""), at: point)
            t.check(tips.pending == nil, "an empty tooltip never appears")
            tips.pointerMoved(in: c.view, info: a, at: point)
            tips.showPending()
            app.changeSettings(of: c) { $0.clickThrough = true }
            t.check(tips.shown == nil, "the tooltip goes when the skin's tooltip areas change")
            app.changeSettings(of: c) { $0.clickThrough = false }
            c.view.updateToolTips()
            tips.pointerMoved(in: c.view, info: a, at: point)
            tips.showPending()
            t.check(tips.shown != nil)
            c.stop()
            t.check(tips.shown == nil, "a stopping skin takes its tooltip along")
        }
    }
}
