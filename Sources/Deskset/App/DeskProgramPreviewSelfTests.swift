import AppKit
import CoreText
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Real private document windows, native font measurement and view drawing. No widget is activated. Bitmap
/// canaries qualify native addressing; these checks are not a desktop-compositor or reactive-runtime acceptance.
enum DeskProgramPreviewSelfTests {
    private enum Failure: Error { case fixture, bitmap, pixel }
    private struct Fixture {
        let app: AppController
        let file: URL
        let controller: CodeFileWindowController
        var editor: CodeEditorView { controller.codeView }
        var preview: DeskProgramPreviewController { controller.deskPreview! }
    }

    private static func fixture(_ t: AppTestRunner, _ text: String,
                                queue: DispatchQueue = DispatchQueue(label: "desk.preview.test.check"),
                                ext: String = "desk") throws -> Fixture {
        let root = t.temporaryDirectory("desk-program-preview")
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: root.appendingPathComponent("Skins"),
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false)
        let file = root.appendingPathComponent("Preview." + ext)
        try Data(text.utf8).write(to: file)
        let controller = try CodeFileWindowController(file: file, app: app, deskCheckQueue: queue)
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.codeView.idleCommitDelay = 600
        controller.codeView.typedTextDelay = 600
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        t.atSuiteEnd {
            controller.codeView.onCommit = { _, _ in false }
            controller.codeView.onDiskConflict = { _ in .decideLater }
            controller.codeView.discardUncommittedChanges()
            controller.window?.close()
            _ = app.stopAllForTermination()
            app.endEngineThread()
        }
        return Fixture(app: app, file: file, controller: controller)
    }

    private static func replace(_ text: String, in f: Fixture) {
        let range = NSRange(location: 0, length: f.editor.text.utf16.count)
        f.editor.textView.setSelectedRange(range)
        f.editor.textView.insertText(text, replacementRange: range)
    }

    private static func settled(_ f: Fixture) -> Bool {
        AppSelfTest.spin(timeout: 10) {
            guard let checking = f.controller.deskChecking else { return false }
            return checking.snapshot.isChecked && checking.isCurrent(checking.snapshot)
        }
    }

    static func run(_ t: AppTestRunner) {
        t.suite("Desk: program preview: actual document paints shared text with independent native reference") {
            let source = "\u{FEFF}info { name: \"预览😀\" }\r\nwidget { Text(\"预览 中文😀\").font(20).color(.accent).padding(8) }\r\n"
            let f = try fixture(t, source)
            let p = f.preview
            t.equal(p.state, .ready)
            t.check(f.controller.window?.contentViewController is NSSplitViewController)
            guard let scene = p.scene else { throw Failure.fixture }
            t.check(f.app.sortedControllers.isEmpty, "preview activates no skin controller")
            t.equal(f.editor.text, source)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                f.controller.window?.appearance = NSAppearance(named: name)
                p.refreshEnvironment()
                let appearance = MacAppearance.values(for: p.canvas.effectiveAppearance)
                var style = TextStyle()
                style.fontFace = "System"
                style.fontSize = 15 // The independent native recipe is 20 points, in existing Draw font units.
                style.fontWeight = 400
                style.color = appearance.accentColor
                style.horizontalAlign = .center
                style.verticalAlign = .center
                style.accurateText = true
                style.antiAlias = true
                style.trailingSpaces = true
                t.close(CTFontGetSize(AppFontResolver().resolve(FontRequest(style: style)).font), 20)
                let context = DrawContext(fonts: AppFontResolver())
                let size = context.text.layout("预览 中文😀", style: style, wrapWidth: nil, cycle: 1).size
                let frame = SkinRect(width: size.width + 16, height: size.height + 16)
                let content = SkinRect(x: 8, y: 8, width: size.width, height: size.height)
                let item = DrawItem.text(TextDraw(text: "预览 中文😀", style: style, frame: frame,
                                                 contentFrame: content, anchor: SkinPoint()))
                t.equal(p.scene?.drawingItems, [item], "actual compiler/runtime uses the independent point-font recipe")
                let reference = ReferenceView(items: [item], size: NSSize(width: frame.width, height: frame.height))
                reference.appearance = NSAppearance(named: name)
                let blank = ReferenceView(items: [], size: reference.frame.size)
                for scale in [1, 2] {
                    let actual = try paint(p.canvas, scale: scale)
                    let expected = try paint(reference, scale: scale)
                    try canaries(t, actual)
                    try canaries(t, expected)
                    t.check(try ink(actual) > 0, "actual native view paints text at \(scale)x")
                    t.equal(try ink(paint(blank, scale: scale)), 0, "an omitted native draw cannot qualify as visible text")
                    t.equal(try bytes(actual), try bytes(expected), "complete native view / explicit TextDraw bytes at \(scale)x")
                }
            }
            t.equal(p.scene?.size, scene.size)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8), "preview reads no other file and never saves")
        }

        t.suite("Desk: program preview: current edits errors and unsupported syntax remove stale native pixels") {
            let f = try fixture(t, #"widget { Text("before😀").font(20).padding(8) }"#)
            let p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            let old = checking.snapshot
            replace(#"widget { Text("after中文").font(20).padding(8) }"#, in: f)
            t.check(settled(f))
            t.equal(p.state, .ready)
            t.check(!checking.publish(old), "actual old snapshot is rejected by the original owner")
            p.show(old, readError: nil)
            t.check(p.scene == nil && p.canvas.isHidden, "even a direct old-preview call cannot retain the old picture")
            p.show(checking.snapshot, readError: nil)
            t.equal(p.state, .ready)
            let previousGeneration = checking.snapshot
            checking.recheck()
            t.check(settled(f))
            t.check(!checking.isCurrent(previousGeneration), "same-text service generation is part of the guard")
            for text in [#"widget { Text("bad").unknownModifier() }"#,
                         #"widget { Grid(columns: 2) { Text("unsupported") } }"#] {
                replace(text, in: f)
                t.check(settled(f))
                guard case .unavailable(let reason) = p.state else { return t.check(false, "invalid/unsupported must report its actual reason") }
                t.check(!reason.isEmpty && p.scene == nil && p.canvas.isHidden)
            }
            replace(#"widget { Text("fresh").font(20).padding(8) }"#, in: f)
            t.check(settled(f))
            t.equal(p.state, .ready)
            // Invalidate the actual check without sending another preview result: draw's independent guard must
            // withhold the retained scene. The qualified native bitmap itself must contain no old text.
            checking.close()
            let noOldPixels = try paint(p.canvas)
            try canaries(t, noOldPixels)
            t.equal(try ink(noOldPixels), 0)
            t.check(p.scene == nil && p.canvas.isHidden)
        }

        t.suite("Desk: program preview: real pending checks read failures and closing clear owned resources") {
            let queue = DispatchQueue(label: "desk.preview.test.pending")
            var suspended = false
            defer { if suspended { queue.resume() } }
            let source = #"widget { Text("large source").font(20).padding(8) }"# + "\n//" + String(repeating: "x", count: 9_000)
            let f = try fixture(t, source, queue: queue)
            let p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            t.equal(p.state, .ready)
            let old = checking.snapshot
            queue.suspend()
            suspended = true
            f.editor.textView.insertText(" ", replacementRange: NSRange(location: 0, length: 0))
            t.check(!checking.snapshot.isChecked)
            t.check(p.scene == nil && p.canvas.isHidden && p.state == .checking)
            t.check(!checking.publish(old))
            queue.resume()
            suspended = false
            t.check(settled(f))
            t.equal(p.state, .ready)
            try Data([0xFF, 0xFE, 0x00, 0x00]).write(to: f.file)
            // Make this reload exercise the real strict reader without prompting over unsaved changes.
            f.editor.discardUncommittedChanges()
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            t.check(f.controller.readError != nil)
            t.check(p.scene == nil && p.canvas.isHidden)
            f.controller.window?.close()
            t.equal(p.state, .closed)
            p.show(old, readError: nil)
            t.check(p.scene == nil && p.state == .closed)
            t.check(f.app.sortedControllers.isEmpty)
        }

        t.suite("Desk: program preview: empty hidden oversized and scroll zoom layouts keep explicit boundaries") {
            let f = try fixture(t, #"widget { Text("scroll 中文😀").font(20).width(900).padding(8) }"#)
            let p = f.preview
            f.controller.window?.setContentSize(NSSize(width: 760, height: 360))
            f.controller.window?.contentView?.layoutSubtreeIfNeeded()
            t.equal(p.state, .ready)
            t.check(p.scrollView.contentView.frame.width > 0 && p.scrollView.contentView.frame.width < 900)
            t.check(p.scrollView.hasHorizontalScroller && p.scrollView.hasVerticalScroller)
            p.setZoom(2)
            t.close(p.scrollView.magnification, 2)
            p.scrollView.contentView.scroll(to: NSPoint(x: 200, y: 0))
            p.scrollView.reflectScrolledClipView(p.scrollView.contentView)
            t.check(p.scrollView.contentView.bounds.origin.x > 0, "the native scroll view exposes the wide layout")
            p.fit()
            t.check(p.scrollView.magnification >= RenderOptions.scaleRange.lowerBound && p.scrollView.magnification < 1)
            p.actualSize()
            t.close(p.scrollView.magnification, 1)
            for source in [#"widget { Text("") }"#, #"widget { Text("hidden").hidden() }"#] {
                replace(source, in: f)
                t.check(settled(f))
                t.equal(p.state, .empty)
                t.check(p.scene != nil && p.canvas.isHidden, "a valid empty/hidden program retains its layout, not an error")
            }
            for source in [#"widget { Text("large").width(1000000) }"#, #"widget { Text("large").font(1000000) }"#] {
                replace(source, in: f)
                t.check(settled(f))
                t.check(f.controller.deskChecking?.snapshot.diagnostics.contains(where: { $0.severity == .error }) == false)
                t.equal(p.state, .unavailable(StudioText[.deskPreviewTooLarge]))
                t.check(p.scene == nil && p.canvas.isHidden)
            }
            let ordinary = try fixture(t, "plain code", ext: "txt")
            t.check(ordinary.controller.deskPreview == nil && ordinary.controller.deskChecking == nil)
            t.check(ordinary.controller.window?.contentView === ordinary.editor, "non-Desk keeps its original code-only window")
        }

        t.suite("Desk: program preview: appearance bindings preserve startup values in actual native pixels") {
            let oldLanguage = StudioText.languageOverride
            defer { StudioText.languageOverride = oldLanguage }
            StudioText.languageOverride = .english
            let source = #"widget { variable initial = system.dark; computed caption = initial == system.dark ? "起始中文😀" : "外观已变😀"; Text(caption).font(20).color(.accent).padding(8) }"#
            let f = try fixture(t, source), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            p.canvas.appearance = NSAppearance(named: .aqua)
            p.show(checking.snapshot, readError: nil) // Start this runtime under an explicit native appearance.
            for (name, text) in [(NSAppearance.Name.aqua, "起始中文😀"), (.darkAqua, "外观已变😀"), (.aqua, "起始中文😀")] {
                p.canvas.appearance = NSAppearance(named: name)
                p.refreshEnvironment()
                t.equal(p.state, .ready)
                let appearance = MacAppearance.values(for: p.canvas.effectiveAppearance)
                var style = TextStyle()
                style.fontFace = "System"
                style.fontSize = 15 // An independent 20-point native recipe, not a style copied from the program.
                style.fontWeight = 400
                style.color = appearance.accentColor
                style.horizontalAlign = .center
                style.verticalAlign = .center
                style.accurateText = true
                style.antiAlias = true
                style.trailingSpaces = true
                let context = DrawContext(fonts: AppFontResolver())
                let size = context.text.layout(text, style: style, wrapWidth: nil, cycle: 1).size
                let frame = SkinRect(width: size.width + 16, height: size.height + 16)
                let item = DrawItem.text(TextDraw(text: text, style: style, frame: frame,
                                                 contentFrame: SkinRect(x: 8, y: 8, width: size.width, height: size.height),
                                                 anchor: SkinPoint()))
                t.equal(p.scene?.drawingItems, [item], "appearance updates computed text without reinitializing its variable")
                let reference = ReferenceView(items: [item], size: NSSize(width: frame.width, height: frame.height))
                reference.appearance = NSAppearance(named: name)
                for scale in [1, 2] {
                    let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                    try canaries(t, actual)
                    try canaries(t, expected)
                    t.check(try ink(actual) > 0)
                    t.equal(try bytes(actual), try bytes(expected), "literal native reference at \(scale)x")
                }
            }
            t.check(p.view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Preview · this document is not running on the desktop"))
            replace(#"widget { variable initial = not system.dark; computed caption = initial == system.dark ? "起始中文😀" : "外观已变😀"; Text(caption).font(20).color(.accent).padding(8) }"#, in: f)
            t.check(settled(f))
            t.equal(p.scene?.drawingItems.compactMap { if case .text(let value) = $0 { return value.text }; return nil }, ["外观已变😀"])
            StudioText.languageOverride = .chinese
            p.show(checking.snapshot, readError: nil)
            t.check(p.view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("预览 · 此文档未在桌面运行"))
            replace(#"widget { variable state = false; Text("unsupported").onWake { state = true } }"#, in: f)
            t.check(settled(f))
            guard case .unavailable(let reason) = p.state else { return t.check(false, "onWake still needs its scheduler") }
            t.check(!reason.isEmpty && p.scene == nil && p.canvas.isHidden)
            // clear() deliberately leaves a 1-point canvas. Use an 8-point capture ROI only in this negative
            // fixture; the production frame, cleared scene, helper and pixel expectations stay intact.
            p.canvas.setBoundsSize(NSSize(width: 8, height: 8))
            let cleared = try paint(p.canvas)
            try canaries(t, cleared)
            t.equal(try ink(cleared), 0, "an unsupported action cannot leave the previous binding pixels")
            t.check(f.app.sortedControllers.isEmpty)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: program preview: root startup assignments use shared state in actual native pixels") {
            let source = #"widget { variable flag = false; computed caption = flag ? "加载中文😀" : "等待😀"; variable captured = "unset"; Text(captured).font(20).color(.accent).padding(8).onLoad { flag = not flag; captured = caption } }"#
            let f = try fixture(t, source), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            p.canvas.appearance = NSAppearance(named: .aqua)
            p.show(checking.snapshot, readError: nil)
            let steps: [(NSAppearance.Name, String)] = [(.aqua, "加载中文😀"), (.darkAqua, "加载中文😀"),
                                                       (.aqua, "加载中文😀"), (.aqua, "等待😀")]
            for (index, step) in steps.enumerated() {
                let (name, text) = step
                if index == 3 {
                    replace(source.replacingOccurrences(of: "variable flag = false", with: "variable flag = true"), in: f)
                    t.check(settled(f)) // A new checked snapshot creates a new startup transaction.
                }
                p.canvas.appearance = NSAppearance(named: name)
                p.refreshEnvironment()
                t.equal(p.state, .ready)
                let appearance = MacAppearance.values(for: p.canvas.effectiveAppearance)
                var style = TextStyle()
                style.fontFace = "System"
                style.fontSize = 15 // Independent 20-point recipe; never copy the compiler's style.
                style.fontWeight = 400
                style.color = appearance.accentColor
                style.horizontalAlign = .center
                style.verticalAlign = .center
                style.accurateText = true
                style.antiAlias = true
                style.trailingSpaces = true
                let context = DrawContext(fonts: AppFontResolver())
                let size = context.text.layout(text, style: style, wrapWidth: nil, cycle: 1).size
                let frame = SkinRect(width: size.width + 16, height: size.height + 16)
                let item = DrawItem.text(TextDraw(text: text, style: style, frame: frame,
                                                 contentFrame: SkinRect(x: 8, y: 8, width: size.width, height: size.height),
                                                 anchor: SkinPoint()))
                t.equal(p.scene?.drawingItems, [item], "onLoad runs on a new program, not on appearance reprojection")
                let reference = ReferenceView(items: [item], size: NSSize(width: frame.width, height: frame.height))
                reference.appearance = NSAppearance(named: name)
                for scale in [1, 2] {
                    let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                    try canaries(t, actual)
                    try canaries(t, expected)
                    t.check(try ink(actual) > 0)
                    t.equal(try bytes(actual), try bytes(expected), "startup literal reference at \(scale)x")
                }
            }
            t.check(f.app.sortedControllers.isEmpty, "startup assignments activate no skin")
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }
    }

    private final class ReferenceView: NSView {
        let items: [DrawItem]
        let context = DrawContext(fonts: AppFontResolver())
        override var isFlipped: Bool { true }
        init(items: [DrawItem], size: NSSize) {
            self.items = items
            super.init(frame: NSRect(origin: .zero, size: size))
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func draw(_ dirtyRect: NSRect) {
            guard let destination = NSGraphicsContext.current?.cgContext else { return }
            DesksetDraw.DrawExecutor.draw(items, in: destination, context: context, cycle: 1,
                                         target: DrawTarget.capture(destination, glass: .none))
        }
    }

    /// Actual native cacheDisplay (both views), equal logical size at 1x/2x. Literal device-row canaries are drawn
    /// after caching; image bytes and ink exclude only those corners, never an unqualified/empty region.
    private static func paint(_ view: NSView, scale: Int = 1) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 4, bounds.height > 4, bounds.width <= 2048, bounds.height <= 2048 else { throw Failure.bitmap }
        let width = Int(ceil(bounds.width * Double(scale))), height = Int(ceil(bounds.height * Double(scale)))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let data = rep.bitmapData, let context = NSGraphicsContext(bitmapImageRep: rep) else { throw Failure.bitmap }
        rep.size = bounds.size
        data.initialize(repeating: 0, count: rep.bytesPerRow * height)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: bounds, to: rep) }
        context.cgContext.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.cgContext.fill(context.cgContext.convertToUserSpace(CGRect(x: 0, y: 0, width: 2, height: 2)))
        context.cgContext.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.cgContext.fill(context.cgContext.convertToUserSpace(CGRect(x: width - 2, y: height - 2, width: 2, height: 2)))
        return rep
    }

    private static func canaries(_ t: AppTestRunner, _ rep: NSBitmapImageRep) throws {
        guard let red = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB),
              let blue = rep.colorAt(x: rep.pixelsWide - 1, y: rep.pixelsHigh - 1)?.usingColorSpace(.deviceRGB) else { throw Failure.pixel }
        t.check(red.redComponent > 0.99 && red.greenComponent < 0.01 && red.blueComponent < 0.01 && red.alphaComponent > 0.99)
        t.check(blue.blueComponent > 0.99 && blue.greenComponent < 0.01 && blue.redComponent < 0.01 && blue.alphaComponent > 0.99)
    }

    private static func ink(_ rep: NSBitmapImageRep) throws -> Int {
        var count = 0
        for y in 2..<(rep.pixelsHigh - 2) {
            for x in 2..<(rep.pixelsWide - 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw Failure.pixel }
                if color.alphaComponent > 0 { count += 1 }
            }
        }
        return count
    }

    private static func bytes(_ rep: NSBitmapImageRep) throws -> Data {
        guard let start = rep.bitmapData, rep.pixelsWide > 0, rep.pixelsHigh > 0 else { throw Failure.bitmap }
        var result = Data(capacity: rep.pixelsWide * rep.pixelsHigh * 4)
        for y in 0..<rep.pixelsHigh {
            result.append(start.advanced(by: y * rep.bytesPerRow), count: rep.pixelsWide * 4)
        }
        return result
    }
}
