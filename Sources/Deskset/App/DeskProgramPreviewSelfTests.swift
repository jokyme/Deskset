import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Darwin
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
                                ext: String = "desk", clock: SkinClock = .live,
                                executor: SkinExecutor = MainSkinExecutor.shared,
                                locale: @escaping () -> Locale = DeskProgramPreviewController.currentDateLocale,
                                colors: @escaping (NSAppearance) throws -> MacAppearance.ProgramValues = MacAppearance.programValues(for:),
                                system: SystemDataSource = SystemMonitor.shared) throws -> Fixture {
        let root = t.temporaryDirectory("desk-program-preview")
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: root.appendingPathComponent("Skins"),
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false)
        let file = root.appendingPathComponent("Preview." + ext)
        try Data(text.utf8).write(to: file)
        let controller = try CodeFileWindowController(file: file, app: app, deskCheckQueue: queue,
                                                       previewClock: clock, previewExecutor: executor, previewLocale: locale, previewColors: colors,
                                                       previewSystem: system)
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
        t.suite("Desk: background preview: glass-only boxes show the appearance-aware placeholder") {
            for (name, style) in [("glass", GlassStyle.regular), ("clearGlass", .clear)] {
                let source = "widget { Column { }.size(32, 24).padding(4).background(.\(name), tint: \"#FF000080\").rounded(6) }"
                let f = try fixture(t, source), p = f.preview
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    p.canvas.appearance = NSAppearance(named: appearance)
                    p.refreshEnvironment()
                    t.equal(p.state, .ready, "glass alone is visible content")
                    t.check(!p.canvas.isHidden)
                    let region = GlassRegion(id: "reference", rect: SkinRect(width: 32, height: 24), cornerRadius: 6,
                                             style: style, tint: RGBA(r: 255, g: 0, b: 0, a: 128))
                    let reference = ReferenceView(items: [.glass(region)], size: NSSize(width: 32, height: 24),
                                                  glass: .placeholder(dark: appearance == .darkAqua))
                    let omitted = ReferenceView(items: [.glass(region)], size: reference.frame.size)
                    for scale in [1, 2] {
                        let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                        try canaries(t, actual); try canaries(t, expected)
                        t.check(try ink(actual) > 0)
                        t.equal(try bytes(actual), try bytes(expected), "literal outer box includes padding at \(scale)x")
                        t.equal(try ink(paint(omitted, scale: scale)), 0, "omitted glass cannot pass as visible")
                    }
                }
                replace("widget { Column { }.size(32, 24).background(.\(name)).hidden() }", in: f)
                t.check(settled(f)); t.equal(p.state, .empty); t.check(p.canvas.isHidden)
                t.equal(try Data(contentsOf: f.file), Data(source.utf8), "preview edits do not save")
            }
        }

        t.suite("Desk: background preview: colored parents paint before child glass and recover after errors") {
            let source = ##"widget { Freeform { Column { }.size(24, 16).position(x: 8, y: 8).background(.glass) }.size(40, 32).background("#123456") }"##
            let f = try fixture(t, source), p = f.preview
            t.equal(p.state, .ready)
            let parent = DrawItem.fill(SkinRect(width: 40, height: 32), Paint(color: RGBA(r: 18, g: 52, b: 86)))
            let child = DrawItem.glass(GlassRegion(id: "child", rect: SkinRect(x: 8, y: 8, width: 24, height: 16), cornerRadius: 0))
            let expected = ReferenceView(items: [parent, child], size: NSSize(width: 40, height: 32), glass: .placeholder(dark: false))
            let wrongOrder = ReferenceView(items: [child, parent], size: expected.frame.size, glass: .placeholder(dark: false))
            for scale in [1, 2] {
                let actual = try paint(p.canvas, scale: scale)
                try canaries(t, actual)
                t.equal(try bytes(actual), try bytes(paint(expected, scale: scale)))
                t.check(try bytes(actual) != bytes(paint(wrongOrder, scale: scale)), "moving glass behind its parent must fail")
            }
            replace("widget { Column { }.background(.glass).rounded() }", in: f)
            t.check(settled(f)); t.check(p.scene == nil && p.canvas.isHidden)
            replace(source, in: f)
            t.check(settled(f)); t.equal(p.state, .ready)
            t.equal(try bytes(paint(p.canvas)), try bytes(paint(expected)), "valid edits replace the cleared preview")
        }

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

        t.suite("Desk: rectangle preview: a text-free document paints the independent native solid recipe") {
            let source = #"widget { Rectangle().size(24, 18).padding(2) }"#
            let f = try fixture(t, source), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                p.canvas.appearance = NSAppearance(named: name)
                p.refreshEnvironment()
                t.equal(p.state, .ready)
                t.check(!p.canvas.isHidden && p.scene?.elements.count == 1)
                let color = MacAppearance.values(for: p.canvas.effectiveAppearance).labelColor
                let rect = SkinRect(x: 2, y: 2, width: 20, height: 14)
                let item = DrawItem.fill(rect, Paint(color: color))
                t.equal(p.scene?.drawingItems, [item], "Rectangle does not require a fabricated text leaf")
                t.equal(p.scene?.size, SkinSize(width: 24, height: 18))
                let reference = ReferenceView(items: [item], size: NSSize(width: 24, height: 18))
                let wrongPosition = ReferenceView(items: [.fill(SkinRect(x: 3, y: 2, width: 20, height: 14), Paint(color: color))],
                                                  size: reference.frame.size)
                let wrongPaint = ReferenceView(items: [.fill(rect, Paint(color: RGBA(r: 255, g: 0, b: 0)))], size: reference.frame.size)
                let blank = ReferenceView(items: [], size: reference.frame.size)
                for scale in [1, 2] {
                    let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                    try canaries(t, actual); try canaries(t, expected)
                    t.check(try ink(actual) > 0)
                    let empty = try paint(blank, scale: scale), shifted = try paint(wrongPosition, scale: scale)
                    let recolored = try paint(wrongPaint, scale: scale)
                    try canaries(t, empty); try canaries(t, shifted); try canaries(t, recolored)
                    t.equal(try ink(empty), 0)
                    t.equal(try bytes(actual), try bytes(expected), "complete solid native pixels at \(scale)x")
                    t.check(try bytes(actual) != bytes(shifted), "wrong geometry cannot pass")
                    t.check(try bytes(actual) != bytes(recolored), "wrong color cannot pass")
                }
            }
            t.check(checking.isCurrent(checking.snapshot) && f.app.sortedControllers.isEmpty)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: rectangle preview: mixed native text alpha and hidden boxes keep literal drawing order") {
            let source = ##"widget { Row(spacing: 6, align: .top) { Rectangle().size(24, 18).padding(2).fill("#12345680"); Text("绘图😀").font(20).color(.accent); Rectangle().size(14, 12).fill("#FF0000").hidden() }.padding(2) }"##
            let f = try fixture(t, source), p = f.preview
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                p.canvas.appearance = NSAppearance(named: name)
                p.refreshEnvironment()
                var style = TextStyle()
                style.fontFace = "System"
                style.fontSize = 15 // Independent 20-point recipe.
                style.fontWeight = 400
                style.color = MacAppearance.values(for: p.canvas.effectiveAppearance).accentColor
                style.horizontalAlign = .center
                style.verticalAlign = .center
                style.accurateText = true
                style.antiAlias = true
                style.trailingSpaces = true
                let context = DrawContext(fonts: AppFontResolver())
                let measured = context.text.layout("绘图😀", style: style, wrapWidth: nil, cycle: 1).size
                let textFrame = SkinRect(x: 32, y: 2, width: measured.width, height: measured.height)
                let items: [DrawItem] = [.fill(SkinRect(x: 4, y: 4, width: 20, height: 14), Paint(color: RGBA(r: 18, g: 52, b: 86, a: 128))),
                                         .text(TextDraw(text: "绘图😀", style: style, frame: textFrame,
                                                        contentFrame: textFrame, anchor: SkinPoint(x: 32, y: 2)))]
                let size = SkinSize(width: measured.width + 54, height: max(18, measured.height) + 4)
                t.equal(p.state, .ready)
                t.equal(p.scene?.size, size)
                t.equal(p.scene?.drawingItems, items)
                t.equal(p.scene?.elements.last?.frame, SkinRect(x: measured.width + 38, y: 2, width: 14, height: 12))
                t.equal(p.scene?.elements.last?.visibility, .hiddenKeepsSpace)
                let reference = ReferenceView(items: items, size: NSSize(width: size.width, height: size.height))
                for scale in [1, 2] {
                    let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                    try canaries(t, actual); try canaries(t, expected)
                    t.check(try ink(actual) > 0)
                    t.equal(try bytes(actual), try bytes(expected), "alpha fill / native text / hidden gap at \(scale)x")
                }
            }
            t.check(f.app.sortedControllers.isEmpty)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: rectangle preview: empty and unsupported edits clear every previously visible shape") {
            let source = #"widget { Rectangle().size(24, 18).fill(.accent) }"#
            let f = try fixture(t, source), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            t.equal(p.state, .ready)
            let old = checking.snapshot
            let replacements: [(String, Bool)] = [(#"widget { Rectangle().size(24, 18).fill(.clear) }"#, true),
                                                   (#"widget { Rectangle().size(0, 18) }"#, true),
                                                   (#"widget { Rectangle().size(24, 18).hidden() }"#, true),
                                                   (#"widget { Rectangle().size(24, 18).rounded(3, topLeft: 0) }"#, false),
                                                   (#"widget { Rectangle().size(24, 18).stroke(.accent, dash: [2, 3]) }"#, false),
                                                   (#"widget { Rectangle().margin(1) }"#, false),
                                                   (#"widget { Rectangle().size(24, 18).unknownModifier() }"#, false)]
            for (replacement, empty) in replacements {
                replace(replacement, in: f)
                t.check(settled(f))
                t.check(!checking.publish(old))
                if empty {
                    t.equal(p.state, .empty)
                    t.check(p.scene != nil, "a supported empty shape retains its layout")
                } else {
                    guard case .unavailable(let reason) = p.state else { return t.check(false, "unsupported shape must report a reason") }
                    t.check(p.scene == nil && !reason.isEmpty)
                }
                t.check(p.canvas.isHidden)
                // A qualified capture ROI only: clear() can leave a 1-point canvas and a zero-width shape is valid.
                p.canvas.setBoundsSize(NSSize(width: 8, height: 8))
                let cleared = try paint(p.canvas)
                try canaries(t, cleared)
                t.equal(try ink(cleared), 0)
            }
            replace(source, in: f)
            t.check(settled(f)); t.equal(p.state, .ready)
            let visible = try paint(p.canvas)
            try canaries(t, visible); t.check(try ink(visible) > 0)
            f.controller.window?.close()
            t.equal(p.state, .closed)
            t.check(p.scene == nil && f.app.sortedControllers.isEmpty)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: flex preview: catalog defaults and capped shares paint independent native rectangles") {
            let sources: [(String, NSSize, [SkinRect], [RGBA?])] = [
                (#"widget { Rectangle() }"#, NSSize(width: 10, height: 10), [SkinRect(width: 10, height: 10)], [nil]),
                (##"widget { Column(spacing: 4, align: .left) { Rectangle().height(.fill, min: 10, max: 15).fill("#FF0000"); Rectangle().height(.fill, min: 20, max: 30).fill("#00AA88"); Rectangle().height(.fill, min: 5).fill("#0033FF") }.width(20).height(100) }"##,
                 NSSize(width: 20, height: 100), [SkinRect(width: 20, height: 15), SkinRect(y: 19, width: 20, height: 30),
                                                SkinRect(y: 53, width: 20, height: 47)],
                 [RGBA(r: 255, g: 0, b: 0), RGBA(r: 0, g: 170, b: 136), RGBA(r: 0, g: 51, b: 255)])]
            for (source, size, rects, colors) in sources {
                let f = try fixture(t, source), p = f.preview
                for name in [NSAppearance.Name.aqua, .darkAqua] {
                    p.canvas.appearance = NSAppearance(named: name)
                    p.refreshEnvironment()
                    let fallback = MacAppearance.values(for: p.canvas.effectiveAppearance).labelColor
                    let items: [DrawItem] = rects.indices.map { .fill(rects[$0], Paint(color: colors[$0] ?? fallback)) }
                    t.equal(p.state, .ready)
                    t.equal(p.scene?.size, SkinSize(width: size.width, height: size.height))
                    t.equal(p.scene?.drawingItems, items, "hand-written equal-share/clamp/redistribution geometry")
                    let reference = ReferenceView(items: items, size: size), blank = ReferenceView(items: [], size: size)
                    for scale in [1, 2] {
                        let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                        let empty = try paint(blank, scale: scale)
                        try canaries(t, actual); try canaries(t, expected); try canaries(t, empty)
                        t.check(try ink(actual) > 0); t.equal(try ink(empty), 0)
                        t.equal(try bytes(actual), try bytes(expected), "actual flexible native pixels at \(scale)x")
                    }
                }
                t.check(f.app.sortedControllers.isEmpty)
                t.equal(try Data(contentsOf: f.file), Data(source.utf8))
            }
        }

        t.suite("Desk: flex preview: assigned text width reflows the native fit cross axis without clipping") {
            let source = #"widget { Row(spacing: 4, align: .bottom) { Rectangle().height(6).fill(.accent); Text("wrapped 中文😀").font(20).width(.fill) }.width(100) }"#
            let f = try fixture(t, source), p = f.preview
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                p.canvas.appearance = NSAppearance(named: name)
                p.refreshEnvironment()
                let appearance = MacAppearance.values(for: p.canvas.effectiveAppearance)
                var style = TextStyle()
                style.fontFace = "System"
                style.fontSize = 15
                style.fontWeight = 400
                style.color = appearance.labelColor
                style.horizontalAlign = .center
                style.verticalAlign = .center
                style.accurateText = true
                style.antiAlias = true
                style.trailingSpaces = true
                style.wrap = true
                let context = DrawContext(fonts: AppFontResolver())
                let measured = context.text.layout("wrapped 中文😀", style: style, wrapWidth: 48, cycle: 1).size
                t.check(measured.height > 6, "the independent native recipe really wraps")
                let frame = SkinRect(x: 52, width: 48, height: measured.height)
                let items: [DrawItem] = [.fill(SkinRect(y: measured.height - 6, width: 48, height: 6), Paint(color: appearance.accentColor)),
                                         .text(TextDraw(text: "wrapped 中文😀", style: style, frame: frame, contentFrame: frame,
                                                        anchor: SkinPoint(x: 52)))]
                t.equal(p.state, .ready)
                t.equal(p.scene?.size, SkinSize(width: 100, height: measured.height))
                t.equal(p.scene?.drawingItems, items)
                let reference = ReferenceView(items: items, size: NSSize(width: 100, height: measured.height))
                for scale in [1, 2] {
                    let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                    try canaries(t, actual); try canaries(t, expected)
                    t.check(try ink(actual) > 0)
                    t.equal(try bytes(actual), try bytes(expected), "native wrapping grows the Row's fit height at \(scale)x")
                }
            }
            t.check(f.app.sortedControllers.isEmpty)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: flex preview: minimum overflow and unsupported layout edits clear the previous pixels") {
            let source = #"widget { Column(spacing: 4) { Rectangle().height(.fill, min: 20); Rectangle().height(.fill, min: 20) }.width(30).height(60) }"#
            let f = try fixture(t, source), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            t.equal(p.state, .ready)
            let old = checking.snapshot
            for replacement in [source.replacingOccurrences(of: "height(60)", with: "height(10)"),
                                source.replacingOccurrences(of: "height(60)", with: "height(60).margin(1)")] {
                replace(replacement, in: f)
                t.check(settled(f)); t.check(!checking.publish(old))
                guard case .unavailable(let reason) = p.state else { return t.check(false, "minimum overflow/unsupported layout must report an actual reason") }
                t.check(!reason.isEmpty && p.scene == nil && p.canvas.isHidden)
                p.canvas.setBoundsSize(NSSize(width: 8, height: 8)) // Only qualify the original clear() capture ROI.
                let cleared = try paint(p.canvas)
                try canaries(t, cleared); t.equal(try ink(cleared), 0)
            }
            replace(source, in: f)
            t.check(settled(f)); t.equal(p.state, .ready)
            let actual = try paint(p.canvas)
            try canaries(t, actual); t.check(try ink(actual) > 0)
            t.check(f.app.sortedControllers.isEmpty)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: shape preview: text-free curves match independent native paths at both scales and appearances") {
            for name in ["Circle", "Ellipse", "Capsule"] {
                for padded in [false, true] {
                    let source = "widget { " + name + "()" + (padded ? ".size(24, 18).padding(2)" : "") + " }"
                    let f = try fixture(t, source), p = f.preview
                    let size = padded ? NSSize(width: 24, height: 18) : NSSize(width: 10, height: 10)
                    let rect = padded ? CGRect(x: 2, y: 2, width: 20, height: 14) : CGRect(x: 0, y: 0, width: 10, height: 10)
                    let path = try curvePath(name, in: rect)
                    t.equal(p.state, .ready); t.equal(p.scene?.size, SkinSize(width: size.width, height: size.height))
                    t.check(f.app.sortedControllers.isEmpty)
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        p.canvas.appearance = NSAppearance(named: appearance)
                        p.refreshEnvironment()
                        let color = MacAppearance.values(for: p.canvas.effectiveAppearance).labelColor
                        let reference = CurveReferenceView(recipes: [(path, color)], size: size)
                        let rectangle = CurveReferenceView(recipes: [(CGPath(rect: rect, transform: nil), color)], size: size)
                        let wrongColor = CurveReferenceView(recipes: [(path, RGBA(r: 255, g: 0, b: 0))], size: size)
                        let blank = CurveReferenceView(recipes: [], size: size)
                        for scale in [1, 2] {
                            let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                            let empty = try paint(blank, scale: scale), wrongGeometry = try paint(rectangle, scale: scale)
                            let recolored = try paint(wrongColor, scale: scale)
                            for rep in [actual, expected, empty, wrongGeometry, recolored] { try canaries(t, rep) }
                            t.check(try ink(actual) > 0); t.equal(try ink(empty), 0)
                            t.equal(try bytes(actual), try bytes(expected), "independent CGPath oracle for \(name) at \(scale)x")
                            t.check(try bytes(actual) != bytes(wrongGeometry), "a rectangular substitute cannot qualify as a curve")
                            t.check(try bytes(actual) != bytes(recolored), "wrong paint cannot qualify")
                            if padded {
                                guard let corner = actual.colorAt(x: 2 * scale, y: 2 * scale)?.usingColorSpace(.deviceRGB),
                                      let center = actual.colorAt(x: 12 * scale, y: 9 * scale)?.usingColorSpace(.deviceRGB) else { throw Failure.pixel }
                                t.equal(corner.alphaComponent, 0)
                                t.equal(Int((center.alphaComponent * 255).rounded()), Int(color.a.rounded()),
                                        "a fully covered center retains the semantic color's byte alpha")
                            }
                        }
                    }
                    t.equal(try Data(contentsOf: f.file), Data(source.utf8), "preview never saves or activates this file")
                }
            }
        }

        t.suite("Desk: shape preview: alpha and replaced snapshots retain independent cold curve recipes") {
            let source = ##"widget { Capsule().size(30, 14).padding(2).fill("#12345680") }"##
            let f = try fixture(t, source), p = f.preview
            guard let checking = f.controller.deskChecking, let scene = p.scene, let item = scene.drawingItems.first,
                  case .shape(let first) = item else { throw Failure.fixture }
            let old = checking.snapshot, captured = scene.drawingItems
            let oldSize = NSSize(width: 30, height: 14)
            let path = try curvePath("Capsule", in: CGRect(x: 2, y: 2, width: 26, height: 10))
            let reference = CurveReferenceView(recipes: [(path, RGBA(r: 18, g: 52, b: 86, a: 128))], size: oldSize)
            let warmReplay = ReferenceView(items: captured, size: oldSize)
            for scale in [1, 2] {
                let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                let replay = try paint(warmReplay, scale: scale)
                try canaries(t, actual); try canaries(t, expected); try canaries(t, replay)
                t.equal(try bytes(actual), try bytes(expected)); t.equal(try bytes(replay), try bytes(expected))
                guard let center = actual.colorAt(x: 15 * scale, y: 7 * scale)?.usingColorSpace(.deviceRGB) else { throw Failure.pixel }
                t.check(center.alphaComponent > 0 && center.alphaComponent < 1)
            }
            replace(#"widget { Ellipse().size(18, 26).padding(2).fill(.accent) }"#, in: f)
            t.check(settled(f)); t.equal(p.state, .ready)
            guard let nextItem = p.scene?.drawingItems.first, case .shape(let next) = nextItem else { throw Failure.fixture }
            t.check(first.sourceID != next.sourceID && first.contentFrame != next.contentFrame)
            t.check(!checking.publish(old))
            let coldReplay = ReferenceView(items: captured, size: oldSize)
            let nextReference = CurveReferenceView(recipes: [(try curvePath("Ellipse", in: CGRect(x: 2, y: 2, width: 14, height: 22)),
                                                             MacAppearance.values(for: p.canvas.effectiveAppearance).accentColor)],
                                                  size: NSSize(width: 18, height: 26))
            for scale in [1, 2] {
                let actual = try paint(p.canvas, scale: scale), expected = try paint(nextReference, scale: scale)
                let replay = try paint(coldReplay, scale: scale), oldExpected = try paint(reference, scale: scale)
                let warm = try paint(warmReplay, scale: scale)
                for rep in [actual, expected, replay, oldExpected, warm] { try canaries(t, rep) }
                t.equal(try bytes(actual), try bytes(expected)); t.equal(try bytes(replay), try bytes(oldExpected))
                t.equal(try bytes(warm), try bytes(oldExpected), "a newer different geometry/paint cannot poison a captured recipe")
            }
            t.equal(try Data(contentsOf: f.file), Data(source.utf8)); t.check(f.app.sortedControllers.isEmpty)
        }

        t.suite("Desk: shape preview: empty invalid and unsupported curve edits clear actual previous pixels") {
            let source = #"widget { Circle().size(24, 18).fill(.accent) }"#
            let f = try fixture(t, source), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            let old = checking.snapshot
            t.equal(p.state, .ready)
            let cases: [(String, Bool)] = [(#"widget { Ellipse().size(24, 18).hidden() }"#, true),
                (#"widget { Capsule().size(0, 18) }"#, true), (#"widget { Circle().size(24, 18).fill(.clear) }"#, true),
                (#"widget { Circle().size(24, 18).stroke(.accent, dash: [2, 3]) }"#, false),
                (#"widget { Ellipse().size(24, 18).fill(.accent, if: true) }"#, false),
                (#"widget { Capsule().size(24, 18).margin(1) }"#, false),
                (#"widget { Ellipse().size(24, 18).unknownModifier() }"#, false)]
            for (replacement, empty) in cases {
                replace(replacement, in: f); t.check(settled(f)); t.check(!checking.publish(old))
                if empty { t.equal(p.state, .empty); t.check(p.scene != nil) }
                else {
                    guard case .unavailable(let reason) = p.state else { return t.check(false, "unsupported curve must report its actual reason") }
                    t.check(p.scene == nil && !reason.isEmpty)
                }
                t.check(p.canvas.isHidden)
                p.canvas.setBoundsSize(NSSize(width: 8, height: 8)) // Qualified clear ROI, as in the existing rectangle tests.
                let blank = try paint(p.canvas); try canaries(t, blank); t.equal(try ink(blank), 0)
            }
            replace(source, in: f); t.check(settled(f)); t.equal(p.state, .ready)
            let actual = try paint(p.canvas); try canaries(t, actual); t.check(try ink(actual) > 0)
            f.controller.window?.close(); t.equal(p.state, .closed); t.check(p.scene == nil)
        }

        t.suite("Desk: styled shape preview: native solid outlines and rounded boxes retain their outside pixels") {
            let cases: [(String, String, Double, Double)] = [
                ("Rectangle", ".stroke(.accent, width: 4)", 4, 0), ("Circle", ".stroke(.accent, width: 4)", 4, 0),
                ("Ellipse", ".stroke(.accent, width: 4)", 4, 0), ("Capsule", ".stroke(.accent, width: 4)", 4, 0),
                // These are the entire original unavailable-preview literals, now real positive controls.
                ("Rectangle", ".rounded(3)", 0, 3), ("Rectangle", ".stroke(.accent)", 1, 0),
                ("Circle", ".stroke(.accent)", 1, 0)]
            for (name, suffix, width, radius) in cases {
                let source = "widget { " + name + "().size(24, 18)" + suffix + " }"
                let f = try fixture(t, source), p = f.preview
                t.equal(p.state, .ready); t.equal(p.scene?.size, SkinSize(width: 24, height: 18))
                let path = try styledPath(name, in: CGRect(x: 0, y: 0, width: 24, height: 18), radius: radius)
                let nativeExtent = width > 0 ? path.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10).boundingBoxOfPath
                                            : path.boundingBoxOfPath
                // Independent native stroke geometry must fit; the shared layout is never stretched to hide clipping.
                t.check(p.canvas.bounds.contains(nativeExtent), "the viewport encloses the actual native paint")
                if name == "Rectangle", width == 4 { t.equal(p.canvas.bounds, CGRect(x: -2, y: -2, width: 28, height: 22)) }
                for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                    p.canvas.appearance = NSAppearance(named: appearanceName); p.refreshEnvironment()
                    let appearance = MacAppearance.values(for: p.canvas.effectiveAppearance)
                    let fill = width > 0 ? RGBA.clear : appearance.labelColor
                    let reference = StyledReferenceView(path: path, fill: fill, stroke: appearance.accentColor, width: width, viewport: p.canvas.bounds)
                    let wrong = StyledReferenceView(path: path, fill: .clear, stroke: .white, width: width > 0 ? width + 2 : 2, viewport: p.canvas.bounds)
                    let blank = CurveReferenceView(recipes: [], size: p.canvas.bounds.size)
                    for scale in [1, 2] {
                        let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                        let missing = try paint(blank, scale: scale), bad = try paint(wrong, scale: scale)
                        for rep in [actual, expected, missing, bad] { try canaries(t, rep) }
                        t.check(try outlineInk(actual) > 0, "qualified ink: \(name) width \(width) \(appearanceName.rawValue) \(scale)x")
                        t.equal(try outlineInk(missing), 0, "literal blank cannot qualify using the two canary corners")
                        t.equal(try bytes(actual), try bytes(expected), "independent native \(name) outline / corner bytes at \(scale)x")
                        t.check(try bytes(actual) != bytes(missing), "blank differs: \(name) width \(width) \(scale)x")
                        t.check(try bytes(actual) != bytes(bad), "wrong paint differs: \(name) width \(width) \(scale)x")
                        if width > 0 {
                            guard let center = actual.colorAt(x: actual.pixelsWide / 2, y: actual.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { throw Failure.pixel }
                            t.equal(center.alphaComponent, 0, "D115 stroke-only must not inherit an implicit fill")
                        }
                    }
                }
                t.check(f.app.sortedControllers.isEmpty); t.equal(try Data(contentsOf: f.file), Data(source.utf8))
            }
        }

        t.suite("Desk: styled shape preview: alpha strokes and changed radii keep immutable warm and cold recipes") {
            let source = ##"widget { Rectangle().size(32, 26).padding(4).rounded(3).fill("#55667780").stroke("#12345680", width: 4) }"##
            let f = try fixture(t, source), p = f.preview
            t.equal(p.state, .ready)
            guard let captured = p.scene?.drawingItems, case .shape(let old)? = captured.first else { throw Failure.fixture }
            let path = try styledPath("Rectangle", in: CGRect(x: 4, y: 4, width: 24, height: 18), radius: 3)
            let viewport = CGRect(x: 0, y: 0, width: 32, height: 26)
            t.equal(p.canvas.bounds, viewport)
            let reference = StyledReferenceView(path: path, fill: RGBA(r: 85, g: 102, b: 119, a: 128),
                                                stroke: RGBA(r: 18, g: 52, b: 86, a: 128), width: 4, viewport: viewport)
            let warm = ReferenceView(items: captured, size: viewport.size)
            for scale in [1, 2] {
                for view in [p.canvas, warm] as [NSView] {
                    let actual = try paint(view, scale: scale), expected = try paint(reference, scale: scale)
                    try canaries(t, actual); try canaries(t, expected)
                    t.equal(try bytes(actual), try bytes(expected), "translucent solid stroke blends exactly once")
                }
            }
            replace(#"widget { Rectangle().size(32, 24).padding(4).rounded(.full).stroke(.white, width: 2) }"#, in: f)
            t.check(settled(f)); t.equal(p.state, .ready)
            guard case .shape(let next)? = p.scene?.drawingItems.first else { throw Failure.fixture }
            t.check(next.sourceID != old.sourceID)
            t.equal(old.shapes[0].stroke, .color(RGBA(r: 18, g: 52, b: 86, a: 128)))
            let cold = ReferenceView(items: captured, size: viewport.size)
            let nextReference = StyledReferenceView(path: try styledPath("Rectangle", in: CGRect(x: 4, y: 4, width: 24, height: 16), radius: 8),
                                                    fill: .clear, stroke: .white, width: 2, viewport: CGRect(x: 0, y: 0, width: 32, height: 24))
            for scale in [1, 2] {
                let actual = try paint(p.canvas, scale: scale), expected = try paint(nextReference, scale: scale)
                let replay = try paint(cold, scale: scale), original = try paint(reference, scale: scale)
                for rep in [actual, expected, replay, original] { try canaries(t, rep) }
                t.equal(try bytes(actual), try bytes(expected)); t.equal(try bytes(replay), try bytes(original))
            }
            t.equal(try Data(contentsOf: f.file), Data(source.utf8)); t.check(f.app.sortedControllers.isEmpty)
        }

        t.suite("Desk: styled shape preview: empty unsupported and oversized outlines clear current pixels and bound zoom") {
            let source = #"widget { Rectangle().size(24, 18).rounded(3).stroke(.accent, width: 4) }"#
            let f = try fixture(t, source), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            t.equal(p.state, .ready)
            let old = checking.snapshot
            for replacement in [#"widget { Rectangle().size(24, 18).stroke(.accent, width: 0) }"#,
                                #"widget { Circle().size(24, 18).stroke(.clear) }"#,
                                #"widget { Ellipse().size(0, 18).stroke(.accent) }"#,
                                #"widget { Capsule().size(24, 18).stroke(.accent).hidden() }"#] {
                replace(replacement, in: f); t.check(settled(f)); t.equal(p.state, .empty)
                t.check(p.scene != nil && p.canvas.isHidden)
                p.canvas.setBoundsSize(NSSize(width: 8, height: 8))
                let cleared = try paint(p.canvas); try canaries(t, cleared); t.equal(try ink(cleared), 0)
            }
            for replacement in [#"widget { Rectangle().size(24, 18).rounded(3, topLeft: 0) }"#,
                                #"widget { Rectangle().size(24, 18).rounded() }"#,
                                #"widget { Circle().size(24, 18).stroke(.accent, dash: [2, 3]) }"#,
                                #"widget { Ellipse().size(24, 18).stroke(gradient(.black, .white)) }"#] {
                replace(replacement, in: f); t.check(settled(f))
                guard case .unavailable(let reason) = p.state else { return t.check(false, "unsupported paint has a real reason") }
                t.check(!reason.isEmpty && p.scene == nil && p.canvas.isHidden)
                p.canvas.setBoundsSize(NSSize(width: 8, height: 8))
                let cleared = try paint(p.canvas); try canaries(t, cleared); t.equal(try ink(cleared), 0)
            }
            replace(#"widget { Rectangle().size(24, 18).stroke(.accent, width: 1000000) }"#, in: f)
            t.check(settled(f)); t.equal(p.state, .unavailable(StudioText[.deskPreviewTooLarge]))
            t.check(p.scene == nil && p.canvas.isHidden, "paint extent, rather than the 24-point layout, controls the resource budget")
            replace(#"widget { Rectangle().size(24, 18).stroke(.accent, width: 1000) }"#, in: f)
            t.check(settled(f)); t.equal(p.state, .ready)
            t.equal(p.scene?.size, SkinSize(width: 24, height: 18)); t.equal(p.canvas.bounds.size, NSSize(width: 1024, height: 1018))
            p.fit(); t.check(p.scrollView.magnification < 1, "fit uses the outside stroke canvas")
            p.actualSize(); t.close(p.scrollView.magnification, 1)
            t.check(!checking.publish(old))
            replace(source, in: f); t.check(settled(f)); t.equal(p.state, .ready)
            let visible = try paint(p.canvas); try canaries(t, visible); t.check(try ink(visible) > 0)
            t.check(p.canvas.bounds.minX < 0 && p.canvas.bounds.minY < 0)
            f.controller.window?.close(); t.equal(p.state, .closed); t.check(p.scene == nil)
            t.equal(p.canvas.bounds.origin, .zero, "closing releases the old outside-stroke coordinate origin")
            p.canvas.setBoundsSize(NSSize(width: 8, height: 8))
            let cleared = try paint(p.canvas); try canaries(t, cleared); t.equal(try outlineInk(cleared), 0)
        }
        t.suite("Desk: image preview: ordinary local pictures match independent native placement at both scales") {
            let data = try imageData()
            let decoded = try decodedFixture(data)
            for mode in ["fit", "fill", "stretch", "tile"] {
                let source = "widget { Image(\"photos/甲😀.png\").size(48, 40).padding(4).imageMode(." + mode + ") }"
                let f = try imageFixture(t, source, images: ["photos/甲😀.png": data])
                t.check(imageSettled(f)); t.equal(f.preview.state, .ready)
                guard let scene = f.preview.scene, case .image(let draw)? = scene.drawingItems.first else { throw Failure.fixture }
                t.equal(scene.size, SkinSize(width: 48, height: 40)); t.check(draw.options.useExifOrientation)
                guard let path = draw.path else { throw Failure.fixture }
                t.equal(try Data(contentsOf: URL(fileURLWithPath: path)), data, "renderer reads exact private approved bytes")
                t.check(!path.hasPrefix(f.file.deletingLastPathComponent().path + "/"), "scene does not re-read a user asset")
                let reference = ImageReferenceView(image: decoded, mode: mode, size: NSSize(width: 48, height: 40))
                let wrong = ImageReferenceView(image: decoded, mode: mode == "fit" ? "stretch" : "fit", size: reference.frame.size)
                let blank = ReferenceView(items: [], size: reference.frame.size)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    f.controller.window?.appearance = NSAppearance(named: appearance)
                    f.preview.refreshEnvironment()
                    reference.appearance = NSAppearance(named: appearance)
                    for scale in [1, 2] {
                        let actual = try paint(f.preview.canvas, scale: scale), expected = try paint(reference, scale: scale)
                        let omitted = try paint(blank, scale: scale), bad = try paint(wrong, scale: scale)
                        try canaries(t, actual); try canaries(t, expected)
                        t.check(try ink(actual) > 0); t.equal(try ink(omitted), 0)
                        t.equal(try bytes(actual), try bytes(expected), "full native bytes: \(mode) \(scale)x \(appearance.rawValue)")
                        t.check(try bytes(actual) != bytes(bad), "wrong placement cannot qualify")
                    }
                }
                t.equal(try Data(contentsOf: f.file.deletingLastPathComponent().appendingPathComponent("photos/甲😀.png")), data)
                t.check(f.app.sortedControllers.isEmpty, "no compatibility skin or desktop widget")
            }
        }

        t.suite("Desk: image preview: upright JPEG natural dimensions and actual flexible layout consume decoded files") {
            let jpeg = try imageData(jpeg: true, orientation: 6)
            let raw = try decodedFixture(jpeg)
            let upright = try rotateFixtureClockwise(raw)
            let f = try imageFixture(t, #"widget { Image("Photo.JPG").padding(4) }"#, images: ["photo.jpg": jpeg])
            t.check(imageSettled(f)); t.equal(f.preview.state, .ready)
            t.equal(f.preview.scene?.size, SkinSize(width: 20, height: 28), "raw 20x12 becomes upright 12x20 points before padding")
            let reference = ImageReferenceView(image: upright, mode: "natural", size: NSSize(width: 20, height: 28))
            let wrong = ImageReferenceView(image: raw, mode: "natural", size: reference.frame.size)
            for scale in [1, 2] {
                let actual = try paint(f.preview.canvas, scale: scale), expected = try paint(reference, scale: scale)
                try canaries(t, actual); try canaries(t, expected)
                t.equal(try bytes(actual), try bytes(expected), "upright JPEG uses an independent original-data rotation")
                t.check(try bytes(actual) != bytes(paint(wrong, scale: scale)))
            }
            replace(#"widget { Row(spacing: 4) { Image("photo.jpg").width(.fill).height(.fill); Image("photo.jpg").width(.fill).height(.fill).hidden() }.size(60, 20).padding(2) }"#, in: f)
            t.check(imageSettled(f)); t.equal(f.preview.state, .ready)
            t.equal(f.preview.scene?.elements.map(\.frame), [SkinRect(width: 60, height: 20),
                    SkinRect(x: 2, y: 2, width: 26, height: 16), SkinRect(x: 32, y: 2, width: 26, height: 16)])
            t.equal(f.preview.scene?.drawingItems.count, 1)
            t.equal(f.preview.scene?.elements[2].visibility, .hiddenKeepsSpace)
            t.equal(try Data(contentsOf: f.file.deletingLastPathComponent().appendingPathComponent("photo.jpg")), jpeg)
        }

        t.suite("Desk: image preview: explicit natural points retain large tiles upright aspect and derive failures") {
            let large = try imageData(width: 9600)
            let tile = try imageFixture(t, #"widget { Image("large.png").size(48, 40).padding(4).imageMode(.tile) }"#,
                                        images: ["large.png": large])
            t.check(imageSettled(tile)); t.equal(tile.preview.state, .ready)
            guard case .image(let tiled)? = tile.preview.scene?.drawingItems.first else { throw Failure.fixture }
            t.equal(tiled.naturalSize, SkinSize(width: 9600, height: 12))
            let reduced = try thumbnailFixture(large, side: 8192)
            let naturalTile = NaturalImageReferenceView(image: reduced, tile: CGSize(width: 9600, height: 12))
            let truncated = NaturalImageReferenceView(image: reduced, tile: CGSize(width: 8192, height: reduced.height))
            for scale in [1, 2] {
                let actual = try paint(tile.preview.canvas, scale: scale), expected = try paint(naturalTile, scale: scale)
                try canaries(t, actual); try canaries(t, expected); t.check(try ink(actual) > 0)
                t.equal(try bytes(actual), try bytes(expected), "bounded decode must not truncate the natural tile period")
                t.check(try bytes(actual) != bytes(paint(truncated, scale: scale)))
            }

            let jpeg = try imageData(jpeg: true, orientation: 6, width: 101, height: 57)
            let photo = try imageFixture(t, #"widget { Image("upright.jpg").size(48, 40).padding(4) }"#,
                                         images: ["upright.jpg": jpeg])
            t.check(imageSettled(photo)); t.equal(photo.preview.state, .ready)
            let raw = try thumbnailFixture(jpeg, side: 64)
            t.check(Double(raw.width) / 101 != Double(raw.height) / 57, "the thumbnail really has unequal density axes")
            let upright = try rotateFixtureClockwise(raw)
            let width = 32.0 * 57.0 / 101.0
            let fit = NaturalImageReferenceView(image: upright, target: CGRect(x: 4 + (40 - width) / 2, y: 4, width: width, height: 32))
            for scale in [1, 2] {
                let actual = try paint(photo.preview.canvas, scale: scale), expected = try paint(fit, scale: scale)
                try canaries(t, actual); try canaries(t, expected)
                t.equal(try bytes(actual), try bytes(expected), "upright point aspect is independent of thumbnail-axis rounding")
            }

            // A large mirrored square needs a bounded orientation bitmap, not a raw fallback or a new layout cap.
            let budgetData = try largeOrientedFixture()
            guard let budgetSource = CGImageSourceCreateWithData(budgetData as CFData, nil),
                  let budgetProperties = CGImageSourceCopyPropertiesAtIndex(budgetSource, 0, nil) as? [CFString: Any]
            else { throw Failure.fixture }
            t.equal(budgetProperties[kCGImagePropertyOrientation] as? Int, 2, "original fixture really encodes an integer mirror orientation")
            let bounded = try imageFixture(t, #"widget { Image("mirror.jpg").size(48, 40).padding(4).imageMode(.tile) }"#,
                                           images: ["mirror.jpg": budgetData])
            t.check(imageSettled(bounded)); t.equal(bounded.preview.state, .ready)
            guard case .image(let draw)? = bounded.preview.scene?.drawingItems.first,
                  let probe = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let prepared = ImageRenderer.preparedNaturalImage(draw, in: probe) else { throw Failure.fixture }
            t.equal(prepared.size, CGSize(width: 4500, height: 4500)); t.check(prepared.image.width <= 4096)
            let mirrored = try mirrorFixture(try thumbnailFixture(budgetData, side: 4096))
            let mirror = NaturalImageReferenceView(image: mirrored, tile: CGSize(width: 4500, height: 4500))
            let actual = try paint(bounded.preview.canvas), expected = try paint(mirror)
            try canaries(t, actual); try canaries(t, expected); t.equal(try bytes(actual), try bytes(expected))

            // Existing cache failure injection is restricted to this unique private file. Non-nil legacy preparation
            // still falls back raw; the explicit Desk contract must fail and clear the whole previous scene instead.
            let failed = try imageFixture(t, #"widget { Image("fail.jpg").size(48, 40).padding(4) }"#,
                                          images: ["fail.jpg": try imageData(jpeg: true, orientation: 6)])
            t.check(imageSettled(failed))
            guard let checking = failed.controller.deskChecking else { throw Failure.fixture }
            // AppKit may have already painted the actual document's first ready image. Give this failure its own
            // fresh file/cache generation before constructing another actual preview consumer of the checked file.
            let fresh = t.temporaryDirectory("image-derive-failure").appendingPathComponent("fresh.jpg")
            try imageData(jpeg: true, orientation: 6).write(to: fresh)
            let path = fresh.path
            guard let entry = Images.entry(atPath: path), let stamp = Images.imageStamp(atPath: path) else { throw Failure.fixture }
            let key = Images.DerivedKey(path: path, generation: entry.generation, recipe: .oriented)
            t.check(Images.derived(key) { nil } == nil)
            let input = ProgramImageResource(path: path, naturalSize: SkinSize(width: 12, height: 20), stamp: stamp)
            let failurePreview = DeskProgramPreviewController(resources: { _ in .ready(["fail.jpg": input]) }) {
                [weak checking] in checking?.isCurrent($0) == true
            }
            t.atSuiteEnd { failurePreview.close() }
            failurePreview.show(checking.snapshot, readError: nil)
            t.equal(failurePreview.state, .ready)
            guard case .image(let failureDraw)? = failurePreview.scene?.drawingItems.first else { throw Failure.fixture }
            t.check(PreparedImage(path: path, options: failureDraw.options) != nil, "original fallback behavior is preserved")
            t.check(ImageRenderer.preparedNaturalImage(failureDraw, in: probe) == nil)
            let clear = try paint(failurePreview.canvas); try canaries(t, clear); t.equal(try ink(clear), 0)
            t.check(failurePreview.scene == nil && failurePreview.canvas.isHidden)
        }

        t.suite("Desk: image preview: asset replacement missing bootstrap stale work and close release private generations") {
            let original = try imageData(), next = try imageData(alternate: true)
            let queue = DispatchQueue(label: "desk.preview.test.images")
            let f = try imageFixture(t, #"widget { Image("A.png").size(48, 40).padding(4) }"#, images: ["A.png": original, "B.png": next], queue: queue)
            t.check(imageSettled(f)); guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            func currentPath() throws -> String {
                guard case .image(let draw)? = f.preview.scene?.drawingItems.first, let path = draw.path else { throw Failure.fixture }
                return path
            }
            let first = try currentPath(), old = checking.snapshot
            queue.suspend()
            var suspended = true
            defer { if suspended { queue.resume() } }
            replace(#"widget { Image("B.png").size(48, 40).padding(4) }"#, in: f)
            t.check(f.preview.scene == nil && f.preview.state == .checking)
            t.check(!FileManager.default.fileExists(atPath: first), "current revision releases the old private copy")
            t.check(checking.snapshot.checked.diagnostics.contains { $0.id == .fileNotFound }, "old A metadata cannot claim B exists")
            t.equal(Desk.compile(checking.snapshot.checked).imageSources, ["B.png"])
            queue.resume(); suspended = false
            t.check(imageSettled(f)); t.equal(f.preview.state, .ready)
            t.check(!checking.snapshot.checked.diagnostics.contains { $0.id == .fileNotFound })
            t.check(!checking.publish(old))
            let second = try currentPath()
            t.equal(try Data(contentsOf: URL(fileURLWithPath: second)), next)
            try original.write(to: f.file.deletingLastPathComponent().appendingPathComponent("B.png"), options: .atomic)
            let cleared = try paint(f.preview.canvas)
            try canaries(t, cleared); t.equal(try ink(cleared), 0, "drawing detects source replacement before using any old picture")
            t.check(imageSettled(f)); t.equal(f.preview.state, .ready)
            let third = try currentPath()
            t.equal(try Data(contentsOf: URL(fileURLWithPath: third)), original)
            t.check(!FileManager.default.fileExists(atPath: second))
            try FileManager.default.removeItem(at: f.file.deletingLastPathComponent().appendingPathComponent("B.png"))
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            t.check(imageSettled(f)); t.check(f.preview.scene == nil && f.preview.canvas.isHidden)
            t.check(checking.snapshot.checked.diagnostics.contains { $0.id == .fileNotFound })
            try next.write(to: f.file.deletingLastPathComponent().appendingPathComponent("B.png"))
            checking.recheck()
            t.check(imageSettled(f)); t.equal(f.preview.state, .ready, "a formerly missing file is actually loaded on recheck")
            let finalPath = try currentPath()
            queue.suspend(); suspended = true
            replace(#"widget { Image("A.png").size(48, 40).padding(4) }"#, in: f)
            f.editor.onCommit = { _, _ in false }; f.editor.discardUncommittedChanges()
            f.controller.window?.close()
            queue.resume(); suspended = false
            t.check(AppSelfTest.spin(timeout: 10) { f.preview.state == .closed })
            t.check(!FileManager.default.fileExists(atPath: finalPath))
            t.check(f.preview.scene == nil)
            let marker = DispatchSemaphore(value: 0)
            queue.async { DispatchQueue.main.async { marker.signal() } }
            t.check(AppSelfTest.spin(timeout: 10) { marker.wait(timeout: .now()) == .success })
            t.equal(f.preview.state, .closed)
        }

        t.suite("Desk: image preview: bounded referenced files reject malformed links and outside inputs without partial pixels") {
            let data = try imageData()
            let f = try imageFixture(t, #"widget { Image("valid.png").size(48, 40).padding(4) }"#, images: ["valid.png": data])
            t.check(imageSettled(f)); t.equal(f.preview.state, .ready)
            let root = f.file.deletingLastPathComponent()
            try Data("not an image".utf8).write(to: root.appendingPathComponent("broken.png"))
            try data.prefix(33).write(to: root.appendingPathComponent("spoof.png"))
            try Data("invalid sibling Desk bytes".utf8).write(to: root.appendingPathComponent("Sibling.desk"))
            let outside = t.temporaryDirectory("image-outside")
            try data.write(to: outside.appendingPathComponent("external.png"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("external.png"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
            for path in ["broken.png", "spoof.png", "link.png", "linked/external.png", "missing.png", "../external.png", outside.appendingPathComponent("external.png").path] {
                replace("widget { Image(\"" + path + "\").size(48, 40).padding(4) }", in: f)
                t.check(imageSettled(f)); t.check(f.preview.scene == nil && f.preview.canvas.isHidden, path)
                f.preview.canvas.frame = NSRect(x: 0, y: 0, width: 8, height: 8)
                let clear = try paint(f.preview.canvas); try canaries(t, clear); t.equal(try ink(clear), 0)
            }
            for (paths, bytes, count) in [(["valid.png"], data.count - 1, 2), (["valid.png"], data.count, 0),
                                           (["valid.png", "broken.png"], data.count + 100, 2)] {
                let inputs = DeskProgramResources.prepare(root: root, literals: paths, maximumBytes: bytes, maximumFiles: count)
                defer { inputs.removeCopies() }
                t.check(inputs.failure != nil && inputs.images.isEmpty && inputs.folder == nil, "no partial input on collection failure")
            }
            let alias = DeskProgramResources.prepare(root: root, literals: ["./VALID.PNG", "valid.png"], maximumBytes: data.count, maximumFiles: 1)
            defer { alias.removeCopies() }
            t.check(alias.failure == nil, "same asset aliases count once: \(String(describing: alias.failure))")
            t.equal(alias.images.count, 2); t.equal(alias.files.count, 1)
            let sparse = root.appendingPathComponent("huge.png")
            let fd = Darwin.open(sparse.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw Failure.fixture }
            defer { Darwin.close(fd) }
            t.equal(ftruncate(fd, off_t(DeskCatalog.current.limits.maximumPackageBytes + 1)), 0)
            let tooLarge = DeskProgramResources.prepare(root: root, literals: ["huge.png"], maximumBytes: DeskCatalog.current.limits.maximumPackageBytes,
                                                       maximumFiles: DeskCatalog.current.limits.maximumPackageFiles)
            t.check(tooLarge.failure != nil && tooLarge.images.isEmpty && tooLarge.folder == nil)
            replace(#"widget { Image("valid.png").rounded(3) }"#, in: f)
            t.check(imageSettled(f)); t.check(f.preview.scene == nil)
            t.check(Desk.compile(f.controller.deskChecking!.snapshot.checked).imageSources.isEmpty)
            t.equal(try Data(contentsOf: root.appendingPathComponent("valid.png")), data)
            t.equal(f.app.sortedControllers.count, 0)
        }

        runFontSizePreviewTests(t)
        runPalettePreviewTests(t)
        runUnitPreviewTests(t)
        runNumericPreviewTests(t)
        runClockPreviewTests(t)
        runClickPreviewTests(t)
        runClickActionPreviewTests(t)
        runPointerEventPreviewTests(t)
        runInspectionPreviewTests(t)
        runFreeformPreviewTests(t)
        runProgressPreviewTests(t)
        runPresetPreviewTests(t)
    }

    private static func runProgressPreviewTests(_ t: AppTestRunner) {
        t.suite("Desk: progress preview: a bar without track ink remains visible and responds to native input") {
            let source = #"widget { variable amount = 0.25; Progress(amount).size(100, 12).color(.black).track(.clear).name(level).onClick { amount = 0.75; copy("primary") }.onRightClick { amount = 0; copy("secondary") } }"#
            let f = try fixture(t, source), p = f.preview
            p.setVisible(true)
            t.equal(p.state, .ready); t.check(!p.canvas.isHidden)
            guard let snapshot = f.controller.deskChecking?.snapshot,
                  let ref = snapshot.elements().first(where: { $0.name == "level" })?.element else { throw Failure.fixture }
            func pixels(_ width: Double) throws {
                let items: [DrawItem] = width == 0 ? [] : [.fill(SkinRect(width: width, height: 12), Paint(color: RGBA(r: 0, g: 0, b: 0, a: 255)))]
                let reference = ReferenceView(items: items, size: NSSize(width: 100, height: 12))
                for scale in [1, 2] {
                    let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                    try canaries(t, actual); try canaries(t, expected)
                    t.equal(try bytes(actual), try bytes(expected), "literal progress width \(width) at \(scale)x")
                    let painted = try ink(actual)
                    t.check(width == 0 ? painted == 0 : painted > 0)
                }
            }
            try pixels(25)
            p.setInspecting(true)
            try click(at: NSPoint(x: 90, y: 6), in: f)
            t.equal(p.inspectedElement, ref); t.check(p.recordedEffects.isEmpty)
            p.setInspecting(false)
            try click(at: NSPoint(x: 90, y: 6), in: f)
            t.equal(p.recordedEffects, [.copy("primary")]); try pixels(75)
            try mouse(.rightMouseDown, at: NSPoint(x: 90, y: 6), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: 90, y: 6), in: f)
            t.equal(p.recordedEffects, [.copy("primary"), .copy("secondary")]); try pixels(0)
            t.equal(p.state, .ready, "an empty but clickable progress box remains reachable")
            try click(at: NSPoint(x: 110, y: 6), in: f)
            t.equal(p.recordedEffects.count, 2)
            t.equal(f.editor.text, source); t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: progress preview: live missing data clears the fill and resumes on the next boundary") {
            let time = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_790_586_000.25), timeZone: TimeZone(secondsFromGMT: 0)!)
            let system = PreviewCountingSystem()
            let source = #"widget { Progress(cpu.usage).size(100, 12).color(.black).track(.white) }"#
            let f = try fixture(t, source, clock: time.clock, executor: time, system: system), p = f.preview
            p.setVisible(true)
            func pixels(_ width: Double) throws {
                let reference = ReferenceView(items: [
                    .fill(SkinRect(width: 100, height: 12), Paint(color: RGBA(r: 255, g: 255, b: 255, a: 255))),
                    .fill(SkinRect(width: width, height: 12), Paint(color: RGBA(r: 0, g: 0, b: 0, a: 255)))
                ], size: NSSize(width: 100, height: 12))
                t.equal(p.state, .ready)
                for scale in [1, 2] {
                    let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                    try canaries(t, actual); try canaries(t, expected)
                    t.equal(try bytes(actual), try bytes(expected), "track and current CPU fill at \(scale)x")
                }
            }
            t.equal(system.cpuCalls, 1); t.equal(time.pendingCount, 1); try pixels(42)
            system.cpu = 75; time.advance(until: 0.75)
            t.equal(system.cpuCalls, 2); try pixels(75)
            system.cpu = .nan; time.advance(by: 1)
            t.equal(system.cpuCalls, 3); try pixels(0)
            t.equal(time.pendingCount, 1, "a missing reading does not lose its refresh boundary")
            p.setVisible(false); t.equal(time.pendingCount, 0)
            system.cpu = 50; time.advance(by: 5)
            t.equal(system.cpuCalls, 3)
            p.setVisible(true); t.equal(system.cpuCalls, 4); try pixels(50)
            p.close(); t.equal(time.pendingCount, 0)
            time.advance(by: 3); t.equal(system.cpuCalls, 4)
        }
    }

    private static func runPresetPreviewTests(_ t: AppTestRunner) {
        t.suite("Desk: preset preview: catalog sizes propose the root and Spacer pushes the progress to its padded edge") {
            for (preset, width, height) in [("small", 170.0, 170.0), ("medium", 356.0, 170.0), ("large", 356.0, 356.0)] {
                let source = "info { name: \"Preset\", size: .\(preset) }\nwidget { Column(spacing: 0, align: .left) { Rectangle().size(20).fill(.black); Spacer(min: 10); Progress(0.5).height(10).color(.black).track(.white) }.size(22, 18).padding(10) }"
                let f = try fixture(t, source), p = f.preview
                t.equal(p.state, .ready); t.equal(p.scene?.size, SkinSize(width: width, height: height))
                t.equal(p.canvas.bounds, NSRect(x: 0, y: 0, width: width, height: height))
                t.check(f.controller.deskChecking?.snapshot.checked.diagnostics.contains { $0.id.rawValue == "DK5018" } == true)
                guard let scene = p.scene else { throw Failure.fixture }
                t.equal(scene.elements.first?.frame, SkinRect(width: width, height: height), "preset overrides the root's written size")
                t.equal(scene.elements.first { $0.kind == .bar }?.frame,
                        SkinRect(x: 10, y: height - 20, width: width - 20, height: 10))
                let reference = ReferenceView(items: [
                    .fill(SkinRect(x: 10, y: 10, width: 20, height: 20), Paint(color: RGBA(r: 0, g: 0, b: 0, a: 255))),
                    .fill(SkinRect(x: 10, y: height - 20, width: width - 20, height: 10), Paint(color: RGBA(r: 255, g: 255, b: 255, a: 255))),
                    .fill(SkinRect(x: 10, y: height - 20, width: (width - 20) / 2, height: 10), Paint(color: RGBA(r: 0, g: 0, b: 0, a: 255)))
                ], size: NSSize(width: width, height: height))
                for scale in [1, 2] {
                    let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                    try canaries(t, actual); try canaries(t, expected)
                    t.check(try ink(actual) > 0); t.equal(try bytes(actual), try bytes(expected), "\(preset), \(scale)x")
                }
                t.equal(f.editor.text, source)
            }
        }

        t.suite("Desk: preset preview: uniformly scaled content keeps selection and native clicks in displayed coordinates") {
            let source = "info { name: \"Scaled\", size: .small }\nwidget { Column(spacing: 0, align: .left) { Text(\"A\").font(20).color(.black).size(340, 60).name(label).onClick { copy(\"scaled\") }; Progress(0.5).size(340, 280).color(.black).track(.white) } }"
            let f = try fixture(t, source), p = f.preview
            p.setVisible(true)
            guard let snapshot = f.controller.deskChecking?.snapshot,
                  let ref = snapshot.elements().first(where: { $0.name == "label" })?.element,
                  let scene = p.scene else { throw Failure.fixture }
            t.equal(p.state, .ready); t.check(!p.canvas.isHidden)
            t.equal(scene.size, SkinSize(width: 170, height: 170))
            t.equal(p.canvas.bounds, NSRect(x: 0, y: 0, width: 170, height: 170))
            t.equal(scene.elements.first { $0.kind == .string }?.frame, SkinRect(width: 170, height: 30))
            t.equal(scene.elements.first { $0.kind == .bar }?.frame, SkinRect(x: 0, y: 30, width: 170, height: 140))
            var style = TextStyle()
            style.fontFace = "System"; style.fontSize = 15; style.fontWeight = 400; style.color = RGBA(r: 0, g: 0, b: 0, a: 255)
            style.horizontalAlign = .center; style.verticalAlign = .center
            style.accurateText = true; style.antiAlias = true; style.trailingSpaces = true
            let textFrame = SkinRect(width: 340, height: 60)
            let items: [DrawItem] = [
                .text(TextDraw(text: "A", style: style, frame: textFrame, contentFrame: textFrame, anchor: SkinPoint())),
                .fill(SkinRect(x: 0, y: 60, width: 340, height: 280), Paint(color: RGBA(r: 255, g: 255, b: 255, a: 255))),
                .fill(SkinRect(x: 0, y: 60, width: 170, height: 280), Paint(color: RGBA(r: 0, g: 0, b: 0, a: 255)))
            ]
            let transform = ShapeTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 0, ty: 0)
            let reference = ReferenceView(items: [.transformed(transform, items)], size: NSSize(width: 170, height: 170))
            let unscaled = ReferenceView(items: items, size: reference.frame.size)
            for scale in [1, 2] {
                let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                try canaries(t, actual); try canaries(t, expected)
                t.equal(try bytes(actual), try bytes(expected), "one uniform content transform at \(scale)x")
                t.check(try bytes(actual) != bytes(paint(unscaled, scale: scale)), "unscaled or cropped content is not accepted")
            }
            p.setZoom(2); _ = p.canvas.scrollToVisible(NSRect(x: 140, y: 5, width: 20, height: 20))
            p.setInspecting(true)
            try click(at: NSPoint(x: 150, y: 15), in: f)
            t.equal(p.inspectedElement, ref); t.check(p.recordedEffects.isEmpty)
            p.setInspecting(false)
            try click(at: NSPoint(x: 150, y: 15), in: f)
            t.equal(p.recordedEffects, [.copy("scaled")])
            try click(at: NSPoint(x: 300, y: 30), in: f)
            t.equal(p.recordedEffects, [.copy("scaled")], "raw pre-scale coordinates do not hit the displayed Text")
            try mouse(.leftMouseDown, at: NSPoint(x: 150, y: 15), in: f)
            replace(source.replacingOccurrences(of: "Text(\"A\")", with: "Text(\"B\")"), in: f)
            t.check(settled(f))
            try mouse(.leftMouseUp, at: NSPoint(x: 150, y: 15), in: f)
            t.check(p.recordedEffects.isEmpty, "source replacement rejects the held scaled gesture")
        }
    }

    private static func runFreeformPreviewTests(_ t: AppTestRunner) {
        t.suite("Desk: freeform preview: negative native text retains pixels selection and click coordinates at zoom") {
            let source = #"widget { Freeform { Text("Left").font(20pt).color(.accent).size(180pt, 60pt).position(x: -100pt, y: -20pt).name(label).onClick { copy("picked") } } }"#
            let f = try fixture(t, source), p = f.preview
            p.setVisible(true)
            guard let snapshot = f.controller.deskChecking?.snapshot,
                  let ref = snapshot.elements().first(where: { $0.name == "label" })?.element else { throw Failure.fixture }
            t.equal(p.state, .ready)
            t.equal(p.scene?.size, SkinSize(width: 80, height: 40))
            let viewport = NSRect(x: -100, y: -20, width: 180, height: 60)
            t.equal(p.canvas.bounds, viewport)
            var style = TextStyle()
            style.fontFace = "System"; style.fontSize = 15; style.fontWeight = 400
            style.color = MacAppearance.values(for: p.canvas.effectiveAppearance).accentColor
            style.horizontalAlign = .center; style.verticalAlign = .center
            style.accurateText = true; style.antiAlias = true; style.trailingSpaces = true
            let frame = SkinRect(x: -100, y: -20, width: 180, height: 60)
            let item = DrawItem.text(TextDraw(text: "Left", style: style, frame: frame, contentFrame: frame,
                                             anchor: SkinPoint(x: -100, y: -20)))
            t.equal(p.scene?.drawingItems, [item])
            let reference = ReferenceView(items: [item], size: viewport.size); reference.bounds = viewport
            let wrong = ReferenceView(items: [.text(TextDraw(text: "Left", style: style, frame: SkinRect(width: 180, height: 60),
                contentFrame: SkinRect(width: 180, height: 60), anchor: SkinPoint()))], size: viewport.size)
            wrong.bounds = viewport
            let blank = ReferenceView(items: [], size: viewport.size); blank.bounds = viewport
            for scale in [1, 2] {
                let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                try canaries(t, actual); try canaries(t, expected)
                t.check(try ink(actual) > 0); t.equal(try ink(paint(blank, scale: scale)), 0)
                t.equal(try bytes(actual), try bytes(expected), "independent native negative text at \(scale)x")
                t.check(try bytes(actual) != bytes(paint(wrong, scale: scale)), "shifting negative coordinates changes the pixels")
            }
            p.setZoom(2)
            _ = p.canvas.scrollToVisible(NSRect(x: -96, y: -16, width: 8, height: 8))
            t.close(Double(p.scrollView.magnification), 2)
            p.setInspecting(true)
            var selected: [ElementRef?] = []
            p.onSelectElement = { _, value in selected.append(value) }
            try click(at: NSPoint(x: -92, y: -12), in: f)
            t.equal(selected, [ref]); t.equal(p.inspectedElement, ref)
            t.check(p.recordedEffects.isEmpty, "inspection does not dispatch the text action")
            p.setInspecting(false)
            try click(at: NSPoint(x: -92, y: -12), in: f)
            t.equal(p.recordedEffects, [.copy("picked")], "the same negative scene point reaches the runtime")
            try click(at: NSPoint(x: -104, y: -12), in: f)
            t.equal(p.recordedEffects, [.copy("picked")], "paint viewport does not expand the target box")
            t.equal(f.editor.text, source); t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: freeform preview: all-negative transparent inspection remains reachable and hidden boxes stay excluded") {
            let source = #"widget { Freeform { Rectangle().size(40, 32).fill(.clear).position(x: -60, y: -50).name(clearBox); Rectangle().size(20).position(x: -300, y: -300).hidden().name(hiddenBox) } }"#
            let f = try fixture(t, source), p = f.preview
            guard let snapshot = f.controller.deskChecking?.snapshot,
                  let ref = snapshot.elements().first(where: { $0.name == "clearBox" })?.element else { throw Failure.fixture }
            t.equal(p.scene?.size, SkinSize())
            t.equal(p.state, .empty)
            p.setVisible(true); p.setInspecting(true)
            t.equal(p.state, .ready)
            t.equal(p.canvas.bounds, NSRect(x: -60, y: -50, width: 61, height: 51))
            t.check(p.scene?.hitMap.entries.isEmpty == true)
            let capture = try paint(p.canvas); try canaries(t, capture); t.equal(try ink(capture), 0)
            try click(at: NSPoint(x: -40, y: -34), in: f)
            t.equal(p.inspectedElement, ref)
            try click(at: NSPoint(x: -290, y: -290), in: f)
            t.check(p.inspectedElement == nil, "a hidden negative box has no inspection target")
            p.setInspecting(false); t.equal(p.state, .empty)
        }
    }

    private static func runInspectionPreviewTests(_ t: AppTestRunner) {
        t.suite("Desk: inspection preview: actionless source refs select innermost native scene frames") {
            let source = #"widget { Column(spacing: 0, align: .left) { Rectangle().size(40, 24).name(box); Row(spacing: 0, align: .top) { Text("甲😀").size(60, 30).name(label) }.name(row) }.padding(4).name(layout) }"#
            let f = try fixture(t, source), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            let snapshot = checking.snapshot
            guard let box = snapshot.elements().first(where: { $0.name == "box" }),
                  let label = snapshot.elements().first(where: { $0.name == "label" }),
                  let layout = snapshot.elements().first(where: { $0.name == "layout" }),
                  let scene = p.scene,
                  let boxFrame = scene.elements.first(where: { $0.id.name == "box" }),
                  let labelFrame = scene.elements.first(where: { $0.id.name == "label" }),
                  let overlay = p.canvas.subviews.first else { throw Failure.fixture }
            let compiled = Desk.compile(snapshot.checked, catalog: snapshot.options.catalog)
            t.equal(compiled.elementRefs[boxFrame.id], box.element)
            t.equal(compiled.elementRefs[labelFrame.id], label.element)
            t.equal(snapshot.range(of: box.element)?.callRange, box.callRange)
            t.equal((source as NSString).substring(with: box.callRange.nsRange), "Rectangle()")
            t.equal((source as NSString).substring(with: label.callRange.nsRange), "Text(\"甲😀\")")
            t.equal(boxFrame.frame, SkinRect(x: 4, y: 4, width: 40, height: 24))
            t.equal(labelFrame.frame, SkinRect(x: 4, y: 28, width: 60, height: 30))
            t.check(scene.hitMap.entries.isEmpty, "source geometry exists without any runtime action target")
            t.check(!p.isInspecting && p.inspectedElement == nil && overlay.isHidden)
            t.check(!p.selectElement(box.element, from: snapshot), "code selection requires the inspector mode")
            p.setVisible(true)
            var selected: [(DeskSnapshot, ElementRef?)] = []
            p.onSelectElement = { selected.append(($0, $1)) }
            try click(at: NSPoint(x: 12, y: 12), in: f)
            t.check(selected.isEmpty && p.inspectedElement == nil, "ordinary preview ignores actionless clicks")
            p.setInspecting(true)
            let items = p.scene?.drawingItems
            t.check(p.selectElement(label.element, from: snapshot))
            t.equal(p.inspectedElement, label.element)
            t.check(!overlay.isHidden)
            t.check(overlay.hitTest(NSPoint(x: 12, y: 36)) == nil, "selection ink cannot intercept the canvas gesture")
            try click(at: NSPoint(x: 12, y: 12), in: f)
            t.equal(p.inspectedElement, box.element)
            try click(at: NSPoint(x: 12, y: 36), in: f)
            t.equal(p.inspectedElement, label.element, "the Text wins over its enclosing Row and Column")
            try click(at: NSPoint(x: 1, y: 1), in: f)
            t.equal(p.inspectedElement, layout.element, "the container's padding remains selectable")
            try click(at: NSPoint(x: -12, y: -12), in: f)
            t.check(p.inspectedElement == nil && overlay.isHidden)
            t.equal(selected.map { $0.1 }, [box.element, label.element, layout.element, nil])
            t.check(selected.allSatisfy { checking.isCurrent($0.0) && $0.0.tree.version == snapshot.tree.version })
            t.equal(p.scene?.drawingItems, items, "inspection outline does not alter the program's drawing items")
            t.check(p.scene?.hitMap.entries.isEmpty == true && p.recordedEffects.isEmpty)
            t.equal(f.editor.text, source)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: inspection preview: design clicks suppress actions and switching modes cancels held presses") {
            let source = #"widget { variable n = 0; Row(spacing: 0, align: .top) { Rectangle().size(40, 30).name(box).onClick { n = n + 1; copy("{n}"); open("https://example.com/{n}") }.onRightClick { copy("secondary") }; Text(n).size(80, 30).name(label) } }"#
            let f = try fixture(t, source), p = f.preview
            guard let snapshot = f.controller.deskChecking?.snapshot,
                  let box = snapshot.elements().first(where: { $0.name == "box" })?.element else { throw Failure.fixture }
            p.setVisible(true)
            let hitMap = p.scene?.hitMap.entries
            var selections: [ElementRef?] = [], batches: [[ProgramEffect]] = []
            p.onSelectElement = { _, ref in selections.append(ref) }
            p.onRecordedEffects = { batches.append($0) }
            try mouse(.leftMouseDown, at: NSPoint(x: 12, y: 12), in: f)
            p.setInspecting(true)
            try mouse(.leftMouseUp, at: NSPoint(x: 12, y: 12), in: f)
            t.check(selections.isEmpty && p.recordedEffects.isEmpty)
            t.equal(clockTexts(p), ["0"], "an interactive press cannot become an inspection release")
            try click(at: NSPoint(x: 12, y: 12), in: f)
            t.equal(selections, [box])
            t.equal(p.inspectedElement, box)
            try mouse(.rightMouseDown, at: NSPoint(x: 12, y: 12), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: 12, y: 12), in: f)
            t.equal(clockTexts(p), ["0"])
            t.check(p.recordedEffects.isEmpty && batches.isEmpty, "neither primary nor secondary executes in design mode")
            t.equal(p.scene?.hitMap.entries, hitMap, "inspection does not replace the runtime action hit map")
            try mouse(.leftMouseDown, at: NSPoint(x: 12, y: 12), in: f)
            p.setInspecting(false)
            try mouse(.leftMouseUp, at: NSPoint(x: 12, y: 12), in: f)
            t.equal(selections, [box])
            t.check(p.inspectedElement == nil && p.recordedEffects.isEmpty)
            t.equal(clockTexts(p), ["0"], "an inspection press cannot become an interactive release")
            try click(at: NSPoint(x: 12, y: 12), in: f)
            let first: [ProgramEffect] = [.copy("1"), .open("https://example.com/1")]
            t.equal(clockTexts(p), ["1"])
            t.equal(p.recordedEffects, first)
            t.equal(batches, [first])
            try mouse(.leftMouseDown, at: NSPoint(x: 12, y: 12), in: f)
            try mouse(.leftMouseDragged, at: NSPoint(x: 100, y: 12), in: f)
            try mouse(.leftMouseUp, at: NSPoint(x: 12, y: 12), in: f)
            let second: [ProgramEffect] = [.copy("2"), .open("https://example.com/2")]
            t.equal(clockTexts(p), ["2"], "legacy primary drag followed by a same-target release retains its action semantics")
            t.equal(p.recordedEffects, first + second)
            t.equal(batches, [first, second])
            t.equal(selections, [box])
            t.check(f.app.sortedControllers.isEmpty && f.app.deskWidgetWindows.isEmpty)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: inspection preview: same-text checks pending errors and closing reject old refs and held gestures") {
            let queue = DispatchQueue(label: "desk.preview.test.inspection.pending")
            var suspended = false
            defer { if suspended { queue.resume() } }
            let source = #"widget { Rectangle().size(40, 30).name(box) }"# + "\n//" + String(repeating: "x", count: 9_000)
            let f = try fixture(t, source, queue: queue), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            p.setVisible(true)
            p.setInspecting(true)
            let old = checking.snapshot
            guard let oldRef = old.elements().first?.element else { throw Failure.fixture }
            var selections = 0
            p.onSelectElement = { _, _ in selections += 1 }
            t.check(p.selectElement(oldRef, from: old))
            try mouse(.leftMouseDown, at: NSPoint(x: 12, y: 12), in: f)
            checking.recheck()
            t.check(settled(f))
            let current = checking.snapshot
            guard let currentRef = current.elements().first?.element else { throw Failure.fixture }
            t.equal(current.text, old.text)
            t.check(currentRef != oldRef && !checking.isCurrent(old))
            t.check(current.range(of: oldRef) == nil)
            t.check(!p.selectElement(oldRef, from: current), "a current snapshot cannot authorize an older tree reference")
            t.check(!p.selectElement(currentRef, from: old), "an old service receipt cannot authorize a current reference")
            t.check(p.inspectedElement == nil)
            try mouse(.leftMouseUp, at: NSPoint(x: 12, y: 12), in: f)
            t.equal(selections, 0, "same-text recheck cancels the held native gesture")
            t.check(p.selectElement(currentRef, from: current))
            try mouse(.leftMouseDown, at: NSPoint(x: 12, y: 12), in: f)
            queue.suspend(); suspended = true
            f.editor.textView.insertText(" ", replacementRange: NSRange(location: 0, length: 0))
            t.check(!checking.snapshot.isChecked && p.state == .checking)
            t.check(p.inspectedElement == nil && p.scene == nil && p.canvas.isHidden)
            t.check(!p.selectElement(currentRef, from: current))
            try mouse(.leftMouseUp, at: NSPoint(x: 12, y: 12), in: f)
            t.equal(selections, 0)
            queue.resume(); suspended = false
            t.check(settled(f))
            let fresh = checking.snapshot
            guard let freshRef = fresh.elements().first?.element else { throw Failure.fixture }
            t.check(p.selectElement(freshRef, from: fresh))
            try mouse(.leftMouseDown, at: NSPoint(x: 12, y: 12), in: f)
            p.show(fresh, readError: "controlled inspection read failure")
            t.equal(p.state, .unavailable("controlled inspection read failure"))
            t.check(p.inspectedElement == nil && p.scene == nil)
            t.check(!p.selectElement(freshRef, from: fresh))
            try mouse(.leftMouseUp, at: NSPoint(x: 12, y: 12), in: f)
            t.equal(selections, 0)
            p.show(fresh, readError: nil)
            t.check(p.selectElement(freshRef, from: fresh))
            replace(#"widget { Rectangle().size(40, 30).unknownModifier() }"#, in: f)
            t.check(settled(f))
            guard case .unavailable = p.state else { return t.check(false, "the real checker error removes inspection geometry") }
            t.check(p.inspectedElement == nil && p.scene == nil)
            t.check(!p.selectElement(freshRef, from: fresh))
            replace(source, in: f)
            t.check(settled(f))
            let recovered = checking.snapshot
            guard let recoveredRef = recovered.elements().first?.element else { throw Failure.fixture }
            t.check(p.selectElement(recoveredRef, from: recovered))
            try mouse(.leftMouseDown, at: NSPoint(x: 12, y: 12), in: f)
            p.close()
            try mouse(.leftMouseUp, at: NSPoint(x: 12, y: 12), in: f)
            p.setInspecting(true)
            p.show(recovered, readError: nil)
            t.equal(p.state, .closed)
            t.check(p.inspectedElement == nil && p.scene == nil && p.canvas.isHidden)
            t.check(!p.selectElement(recoveredRef, from: recovered))
            t.equal(selections, 0)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: inspection preview: hidden geometry is excluded but transparent nonzero frames remain selectable") {
            let hidden = try fixture(t, #"widget { Rectangle().size(40, 30).hidden().name(hiddenBox) }"#)
            let hp = hidden.preview
            hp.setVisible(true)
            hp.setInspecting(true)
            var hiddenSelections = 0
            hp.onSelectElement = { _, _ in hiddenSelections += 1 }
            t.equal(hp.state, .empty)
            t.check(hp.canvas.isHidden)
            t.equal(hp.scene?.elements.first?.frame, SkinRect(width: 40, height: 30))
            t.equal(hp.scene?.elements.first?.visibility, .hiddenKeepsSpace)
            try click(at: NSPoint(x: 12, y: 12), in: hidden)
            t.check(hp.inspectedElement == nil)
            t.equal(hiddenSelections, 0)

            let source = #"widget { Rectangle().size(40, 30).fill(.clear).name(clearBox) }"#
            let f = try fixture(t, source), p = f.preview
            guard let snapshot = f.controller.deskChecking?.snapshot,
                  let ref = snapshot.elements().first?.element else { throw Failure.fixture }
            t.equal(p.state, .empty)
            t.check(p.canvas.isHidden)
            p.setVisible(true)
            p.setInspecting(true)
            t.equal(p.state, .ready)
            t.check(!p.canvas.isHidden && p.scene?.hitMap.entries.isEmpty == true)
            t.equal(p.scene?.elements.first?.visibility, .visible)
            t.equal(p.scene?.elements.first?.frame, SkinRect(width: 40, height: 30))
            var selected: [ElementRef?] = []
            p.onSelectElement = { _, ref in selected.append(ref) }
            try click(at: NSPoint(x: 12, y: 12), in: f)
            t.equal(p.inspectedElement, ref)
            t.equal(selected, [ref])
            t.check(p.recordedEffects.isEmpty)
            p.setInspecting(false)
            t.equal(p.state, .empty)
            t.check(p.canvas.isHidden && p.inspectedElement == nil)
            try click(at: NSPoint(x: 12, y: 12), in: f)
            t.equal(selected, [ref], "ordinary preview does not turn an invisible actionless shape into an action target")
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("Desk: inspection preview: native drag cross-element and nonfinite gestures cannot change selection") {
            let source = #"widget { Row(spacing: 0, align: .top) { Rectangle().size(40, 30).name(box); Text("other").size(80, 30).name(label) } }"#
            let f = try fixture(t, source), p = f.preview
            guard let snapshot = f.controller.deskChecking?.snapshot,
                  let box = snapshot.elements().first(where: { $0.name == "box" })?.element else { throw Failure.fixture }
            p.setVisible(true)
            p.setInspecting(true)
            t.check(p.selectElement(box, from: snapshot))
            var selections: [ElementRef?] = []
            p.onSelectElement = { _, ref in selections.append(ref) }
            try mouse(.leftMouseDown, at: NSPoint(x: 12, y: 12), in: f)
            try mouse(.leftMouseDragged, at: NSPoint(x: 60, y: 12), in: f)
            try mouse(.leftMouseUp, at: NSPoint(x: 12, y: 12), in: f)
            t.equal(p.inspectedElement, box)
            t.check(selections.isEmpty, "a drag returning to the original frame still cancels inspection")
            try mouse(.leftMouseDown, at: NSPoint(x: 12, y: 12), in: f)
            try mouse(.leftMouseUp, at: NSPoint(x: 60, y: 12), in: f)
            t.equal(p.inspectedElement, box)
            t.check(selections.isEmpty, "a release on another source element cannot select it")
            try mouse(.leftMouseUp, at: NSPoint(x: 60, y: 12), in: f)
            t.check(selections.isEmpty, "an unmatched release has no inspection receipt")
            // Only deliver nonfinite coordinates if the native event factory and view conversion retain them.
            // A rejected or normalized NSEvent is not replaced with a fake controller-level gesture.
            for location in [NSPoint(x: CGFloat.nan, y: CGFloat.nan),
                             NSPoint(x: CGFloat.infinity, y: -CGFloat.infinity)] {
                guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                   windowNumber: f.controller.window?.windowNumber ?? 0, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1),
                      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
                                                 windowNumber: f.controller.window?.windowNumber ?? 0, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                let point = p.canvas.convert(down.locationInWindow, from: nil)
                guard !point.x.isFinite || !point.y.isFinite else { continue }
                p.canvas.mouseDown(with: down)
                p.canvas.mouseUp(with: up)
                t.equal(p.inspectedElement, box, "a nonfinite native gesture must not be treated as an empty-space selection")
                t.check(selections.isEmpty)
            }
            try click(at: NSPoint(x: 12, y: 12), in: f)
            t.equal(selections, [box], "the cancelled gestures leave the next valid native click usable")
            t.equal(p.inspectedElement, box)
            t.check(p.recordedEffects.isEmpty && p.scene?.hitMap.entries.isEmpty == true)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }
    }

    private static func runPointerEventPreviewTests(_ t: AppTestRunner) {
        t.suite("App: Desk pointer events: preview secondary and Control record only their selected ordered requests") {
            let source = #"widget { variable n = 0; Row(spacing: 0) { Text(n).font(20).size(80, 40).onClick { copy("{cpu.usage}") }.onRightClick { n = n + 1; copy("{n}"); open("https://example.com/{n}"); copy("{memory.used, unit: .gib, unitStyle: .none, decimals: 0}") }; Text("Other").size(100, 40).onRightClick { copy("other") }; Text("Empty").size(80, 40).onRightClick { }; Text("Primary").size(80, 40).onClick { copy("last primary") } } }"#
            let system = PreviewCountingSystem(), f = try fixture(t, source, system: system), p = f.preview
            p.setVisible(true)
            var batches: [[ProgramEffect]] = []
            p.onRecordedEffects = { batches.append($0) }
            t.equal(system.cpuCalls, 0); t.equal(system.memCalls, 0)
            try mouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            t.check(p.recordedEffects.isEmpty, "a secondary press records no requests before its release")
            try mouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            let first: [ProgramEffect] = [.copy("1"), .open("https://example.com/1"), .copy("16")]
            t.equal(p.recordedEffects, first); t.equal(batches, [first])
            t.equal(system.cpuCalls, 0); t.equal(system.memCalls, 1)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f, flags: [.control])
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            let second: [ProgramEffect] = [.copy("2"), .open("https://example.com/2"), .copy("16")]
            t.equal(p.recordedEffects, first + second, "releasing Control still releases the selected secondary handler")
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f, flags: [.control])
            let expected = first + second + [.copy("42")]
            t.equal(p.recordedEffects, expected, "adding Control after a primary press does not change its event")
            t.equal(system.cpuCalls, 1)
            try mouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: f, flags: [.option])
            try mouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f, flags: [.control, .option])
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: f, flags: [.option])
            try mouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: 100, y: 20), in: f)
            try mouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.rightMouseDragged, at: NSPoint(x: 100, y: 20), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f, flags: [.control])
            try mouse(.leftMouseDragged, at: NSPoint(x: 100, y: 20), in: f)
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.equal(p.recordedEffects, expected, "Option, cross-leaf, drag and unmatched releases cancel without primary leakage")
            let before = p.scene?.generation
            try mouse(.rightMouseDown, at: NSPoint(x: 200, y: 20), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: 200, y: 20), in: f)
            t.equal(p.scene?.generation, before.map { $0 + 1 }, "empty right handler consumes a real secondary click")
            try mouse(.rightMouseDown, at: NSPoint(x: 280, y: 20), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: 280, y: 20), in: f)
            p.updateForTick(); p.refreshEnvironment()
            t.equal(p.recordedEffects, expected, "a missing secondary handler or an ordinary redraw never runs a primary action")
            t.equal(batches, [first, second, [.copy("42")]])
            t.check(f.app.sortedControllers.isEmpty && f.app.deskWidgetWindows.isEmpty)
            t.equal(f.editor.text, source); t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }

        t.suite("App: Desk pointer events: preview secondary geometry CPU ticks and checked-session cancellation stay qualified") {
            let time = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_790_586_059.25), timeZone: TimeZone(secondsFromGMT: 0)!)
            let system = PreviewCountingSystem()
            let source = #"widget { variable n = 0; Row(spacing: 0, align: .top) { Rectangle().size(24, 18).stroke(.accent, width: 4).onRightClick { n = n + 1; copy("{n}") }; Text(n).size(40, 30).onRightClick { copy("other") }; Text(cpu.usage).size(280, 40) } }"#
            let f = try fixture(t, source, clock: time.clock, executor: time, system: system), p = f.preview
            p.setVisible(true)
            t.equal(p.canvas.bounds.origin, NSPoint(x: -2, y: -2))
            p.setZoom(2)
            p.scrollView.contentView.scroll(to: NSPoint(x: 8, y: 0))
            p.scrollView.reflectScrolledClipView(p.scrollView.contentView)
            try mouse(.rightMouseDown, at: NSPoint(x: -1, y: 6), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: -1, y: 6), in: f)
            t.check(p.recordedEffects.isEmpty, "the outside stroke is painted but does not become a hit box")
            try mouse(.rightMouseDown, at: NSPoint(x: 1, y: 6), in: f)
            let generation = p.scene?.generation
            system.cpu = 75
            time.advance(until: 0.75)
            t.check(p.scene?.generation != generation)
            try mouse(.rightMouseUp, at: NSPoint(x: 1, y: 6), in: f)
            t.equal(p.recordedEffects, [.copy("1")], "CPU ticks preserve the legal element press with zoom/scroll and negative origin")
            try mouse(.rightMouseDown, at: NSPoint(x: 1, y: 6), in: f)
            p.setVisible(false); p.setVisible(true)
            try mouse(.rightMouseUp, at: NSPoint(x: 1, y: 6), in: f)
            t.equal(p.recordedEffects, [.copy("1")], "restoring visibility does not restore a cancelled press")
            try mouse(.rightMouseDown, at: NSPoint(x: 1, y: 6), in: f)
            replace(source.replacingOccurrences(of: "n = 0", with: "n = 5"), in: f)
            t.check(settled(f))
            try mouse(.rightMouseUp, at: NSPoint(x: 1, y: 6), in: f)
            t.check(p.recordedEffects.isEmpty, "a checked source replacement invalidates both the press and prior records")
            try mouse(.rightMouseDown, at: NSPoint(x: 1, y: 6), in: f)
            f.controller.window?.close()
            try mouse(.rightMouseUp, at: NSPoint(x: 1, y: 6), in: f)
            t.equal(p.state, .closed); t.check(p.recordedEffects.isEmpty)
        }

        t.suite("App: Desk pointer events: hidden and failed preview secondary handlers cannot record requests") {
            let f = try fixture(t, #"widget { Text("Hidden").hidden().size(80, 40).onRightClick { copy("hidden") } }"#), p = f.preview
            p.setVisible(true)
            try mouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.check(p.recordedEffects.isEmpty); t.equal(p.scene?.hitMap.entries.count, 0)
            replace(#"widget { variable points = 20; Text("Fail").font(points).size(80, 40).onRightClick { points = 0; copy("must not escape") } }"#, in: f)
            t.check(settled(f))
            try mouse(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.rightMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.check(p.scene == nil && p.recordedEffects.isEmpty)
            p.updateForTick()
            t.equal(clockTexts(p), ["Fail"], "failed secondary projection rolls back the font assignment")
        }
    }

    private static func runClickActionPreviewTests(_ t: AppTestRunner) {
        t.suite("App: Desk click actions: editor records ordered requests without executing or replaying them") {
            let oldLanguage = StudioText.languageOverride
            StudioText.languageOverride = .english
            defer { StudioText.languageOverride = oldLanguage }
            let source = #"widget { variable n = 0; computed caption = "{n}"; Text(caption).font(20).size(160, 40).onClick { n = n + 1; copy(caption); open("https://example.com/{n}"); copy("done😀") } }"#
            let f = try fixture(t, source), p = f.preview
            p.setVisible(true)
            t.equal(p.actionRecordsButton.state, .off, "records start collapsed without taking canvas space")
            t.equal(p.actionRecordsButton.title, "Actions (0)")
            t.check(p.actionRecordsScrollView.isHiddenOrHasHiddenAncestor)
            t.check(!p.actionRecordsClearButton.isEnabled)
            var batches: [[ProgramEffect]] = []
            p.onRecordedEffects = { batches.append($0) }
            try click(at: NSPoint(x: 20, y: 20), in: f)
            let expected: [ProgramEffect] = [.copy("1"), .open("https://example.com/1"), .copy("done😀")]
            t.equal(p.recordedEffects, expected)
            t.equal(batches, [expected])
            t.equal(clockTexts(p), ["1"])
            t.equal(p.actionRecordsButton.title, "Actions (3)")
            t.equal(p.actionRecordsText.string, "", "collapsed recording does not build a hidden text log")
            p.actionRecordsButton.performClick(nil)
            t.equal(p.actionRecordsButton.state, .on)
            t.check(!p.actionRecordsScrollView.isHiddenOrHasHiddenAncestor)
            t.equal(p.actionRecordsText.string, "1. Would copy 1\n\n2. Would open https://example.com/1\n\n3. Would copy done😀")
            t.equal(p.actionRecordsText.accessibilityLabel(), "Actions (3)")
            t.equal(p.actionRecordsNotice.stringValue, StudioText[.deskActionPreviewNotice])
            t.check(!p.actionRecordsText.isEditable && p.actionRecordsText.isSelectable)
            p.updateForTick(); p.refreshEnvironment()
            t.equal(p.recordedEffects, expected, "projection and environment refresh never replay requests")
            t.equal(batches.count, 1)
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            try click(at: NSPoint(x: 300, y: 20), in: f)
            p.setVisible(false); try click(at: NSPoint(x: 20, y: 20), in: f)
            t.equal(batches.count, 1, "missing press, miss and hidden preview cannot record requests")
            p.setVisible(true)
            for _ in 0..<35 { try click(at: NSPoint(x: 20, y: 20), in: f) }
            t.equal(p.recordedEffects.count, 100, "preview uses the existing bounded Studio action-log retention")
            t.equal(p.recordedEffects.last, .copy("done😀"))
            t.equal(p.actionRecordsButton.title, "Actions (100)")
            t.equal(p.actionRecordsText.string.components(separatedBy: "\n\n").count, 100)
            t.check(p.actionRecordsText.string.hasPrefix("1. Would copy done😀\n\n2. Would copy 4\n\n"),
                    "the visible log starts at the retained oldest effect, in execution order")
            t.check(p.actionRecordsText.string.hasSuffix("100. Would copy done😀"))
            let batchesBeforeClear = batches.count
            p.actionRecordsClearButton.performClick(nil)
            t.check(p.recordedEffects.isEmpty)
            t.equal(p.actionRecordsButton.title, "Actions (0)")
            t.equal(p.actionRecordsText.string, StudioText[.deskActionRecordsEmpty])
            t.equal(clockTexts(p), ["36"], "clearing the log leaves program variables alone")
            t.equal(batches.count, batchesBeforeClear)
            t.check(!p.actionRecordsClearButton.isEnabled)
            try click(at: NSPoint(x: 20, y: 20), in: f)
            t.equal(p.recordedEffects, [.copy("37"), .open("https://example.com/37"), .copy("done😀")])
            t.equal(f.editor.text, source)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
            t.check(f.app.sortedControllers.isEmpty && f.app.deskWidgetWindows.isEmpty,
                    "editor actions create no live host or desktop service")
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            replace(#"widget { Text("Replacement").font(20).size(160, 40) }"#, in: f)
            t.check(settled(f))
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.check(p.recordedEffects.isEmpty, "a checked replacement clears the previous session's recording and press")
            t.equal(p.actionRecordsButton.title, "Actions (0)")
            t.equal(p.actionRecordsText.string, StudioText[.deskActionRecordsEmpty])
            f.editor.discardUncommittedChanges(); f.controller.window?.close()
            t.equal(p.state, .closed)
            t.check(p.onRecordedEffects == nil)
            t.equal(p.actionRecordsText.string, "")
            t.check(p.actionRecordsScrollView.isHiddenOrHasHiddenAncestor)
            t.check(!p.actionRecordsButton.isEnabled && !p.actionRecordsClearButton.isEnabled)
            t.check(p.actionRecordsButton.target == nil && p.actionRecordsClearButton.target == nil)
        }

        t.suite("App: Desk click actions: visible records wrap select scroll and preserve the minimum preview canvas") {
            let oldLanguage = StudioText.languageOverride
            StudioText.languageOverride = .english
            defer { StudioText.languageOverride = oldLanguage }
            let payload = String(repeating: "中文😀 e\u{301} \"quoted\" \\ \u{E000}\u{E001}\n", count: 120) + "最后一行😀"
            let literal = payload.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            let source = "widget { Text(cpu.usage).font(20).size(160, 40).onClick { copy(\"" + literal +
                "\"); open(\"https://example.com/中文\") } }"
            guard let zone = TimeZone(secondsFromGMT: 0) else { throw Failure.fixture }
            let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_790_586_000.25), timeZone: zone)
            let system = PreviewCountingSystem()
            let f = try fixture(t, source, clock: executor.clock, executor: executor, system: system), p = f.preview
            p.setVisible(true)
            var batches = 0
            p.onRecordedEffects = { _ in batches += 1 }
            try click(at: NSPoint(x: 20, y: 20), in: f)
            p.actionRecordsButton.performClick(nil)
            t.equal(p.recordedEffects, [.copy(payload), .open("https://example.com/中文")])
            t.equal(p.actionRecordsText.string, "1. Would copy " + payload + "\n\n2. Would open https://example.com/中文")
            t.check(p.actionRecordsScrollView.hasVerticalScroller && !p.actionRecordsScrollView.hasHorizontalScroller)
            t.check(p.actionRecordsText.isVerticallyResizable && !p.actionRecordsText.isHorizontallyResizable)
            guard let window = f.controller.window,
                  let split = window.contentViewController as? NSSplitViewController,
                  let pane = p.actionRecordsScrollView.superview,
                  let textContainer = p.actionRecordsText.textContainer,
                  let textStorage = p.actionRecordsText.textStorage else { throw Failure.fixture }
            window.setContentSize(NSSize(width: 700, height: 240))
            window.contentView?.layoutSubtreeIfNeeded()
            split.splitView.setPosition(split.splitView.bounds.width - 280 - split.splitView.dividerThickness, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            t.close(p.view.bounds.width, 280, accuracy: 1)
            t.close(p.view.bounds.height, 240, accuracy: 1)
            t.check(!p.view.hasAmbiguousLayout && !pane.hasAmbiguousLayout && !p.actionRecordsScrollView.hasAmbiguousLayout)
            t.check(pane.bounds.height > 0 && pane.bounds.height <= p.view.bounds.height * 0.25 + 1)
            let layoutHeights = "view(frame/bounds)=\(p.view.frame.height)/\(p.view.bounds.height), " +
                "toolbar=\(p.view.subviews.compactMap { $0 as? NSStackView }.first?.frame.height ?? -1), " +
                "status=\(p.view.subviews.compactMap { $0 as? NSTextField }.first?.frame.height ?? -1), " +
                "footer=\(pane.superview?.frame.height ?? -1), header=\(p.actionRecordsButton.superview?.frame.height ?? -1), " +
                "pane(frame/bounds)=\(pane.frame.height)/\(pane.bounds.height), notice=\(p.actionRecordsNotice.frame.height), " +
                "canvas(scroll/clipFrame/clipBounds)=\(p.scrollView.frame.height)/\(p.scrollView.contentView.frame.height)/\(p.scrollView.contentView.bounds.height), " +
                "records(scroll/clipFrame/clipBounds)=\(p.actionRecordsScrollView.frame.height)/\(p.actionRecordsScrollView.contentView.frame.height)/\(p.actionRecordsScrollView.contentView.bounds.height), " +
                "zoom=\(p.scrollView.magnification)"
            t.check(p.scrollView.contentView.bounds.height > pane.bounds.height,
                    "the minimum-size preview still gives the canvas more height than the record pane; " + layoutHeights)
            t.check(p.actionRecordsScrollView.contentView.bounds.height > 0)
            p.actionRecordsText.layoutManager?.ensureLayout(for: textContainer)
            p.actionRecordsText.sizeToFit()
            t.check(p.actionRecordsText.bounds.height > p.actionRecordsScrollView.contentView.bounds.height,
                    "long multiline requests occupy a real scrollable document")
            let selected = (p.actionRecordsText.string as NSString).range(of: "最后一行😀")
            t.check(selected.location != NSNotFound)
            p.actionRecordsText.setSelectedRange(selected)
            p.actionRecordsText.scrollRangeToVisible(selected)
            t.equal(p.actionRecordsText.selectedRange(), selected)
            t.equal((p.actionRecordsText.string as NSString).substring(with: selected), "最后一行😀")
            t.check(p.actionRecordsScrollView.contentView.bounds.origin.y > 0, "the last Unicode line is inspectable by scrolling")
            let visibleText = p.actionRecordsText.string
            let edits = ActionRecordEditingObserver()
            textStorage.delegate = edits
            defer { textStorage.delegate = nil }
            system.cpu = 57
            executor.advance(by: 2)
            t.equal(clockTexts(p), ["57"], "ordinary CPU frames still project while the action pane is open")
            t.equal(p.actionRecordsText.string, visibleText)
            t.equal(p.actionRecordsText.selectedRange(), selected)
            t.equal(edits.characterEdits, 0, "CPU timers do not rewrite the action document")
            t.equal(batches, 1)
            let expandedCanvasHeight = p.scrollView.contentView.bounds.height
            for _ in 0..<2 {
                p.actionRecordsButton.performClick(nil)
                p.view.layoutSubtreeIfNeeded()
                t.check(p.actionRecordsScrollView.isHiddenOrHasHiddenAncestor)
                t.check(p.scrollView.contentView.bounds.height > expandedCanvasHeight)
                p.actionRecordsButton.performClick(nil)
                p.view.layoutSubtreeIfNeeded()
                t.check(!p.actionRecordsScrollView.isHiddenOrHasHiddenAncestor)
                t.check(pane.bounds.height <= p.view.bounds.height * 0.25 + 1)
                t.equal(p.actionRecordsText.string, visibleText)
            }
            StudioText.languageOverride = .chinese
            p.refreshDateInput()
            t.equal(p.actionRecordsButton.title, "动作（2）")
            t.equal(p.actionRecordsButton.accessibilityLabel(), "动作（2）")
            t.equal(p.actionRecordsClearButton.title, "清除")
            t.equal(p.actionRecordsNotice.accessibilityLabel(), StudioText[.deskActionPreviewNotice])
            t.equal(p.actionRecordsText.string, "1. 会复制 " + payload + "\n\n2. 会打开 https://example.com/中文")
            t.equal(p.recordedEffects, [.copy(payload), .open("https://example.com/中文")])
            t.equal(batches, 1, "changing the displayed language does not replay requests")
        }

        t.suite("App: Desk click actions: failed editor projection records no external requests") {
            let source = #"widget { variable size = 20; Text("Fail safely").font(size).size(160, 40).onClick { size = 0; copy("must not escape") } }"#
            let f = try fixture(t, source), p = f.preview
            p.setVisible(true)
            var calls = 0
            p.onRecordedEffects = { _ in calls += 1 }
            try click(at: NSPoint(x: 20, y: 20), in: f)
            t.check(p.recordedEffects.isEmpty)
            t.equal(calls, 0)
            t.check(p.scene == nil)
            p.updateForTick()
            t.equal(clockTexts(p), ["Fail safely"], "the failed assignment was not committed by the preview")
        }

        t.suite("App: Desk click actions: invalid preview clock boundary cannot commit or record a click") {
            let source = #"widget { variable n = 0; Row { Text(n).font(20).size(80, 40).onClick { n = n + 1; copy("{n}") }; Text(cpu.usage).font(20).size(80, 40) } }"#
            guard let zone = TimeZone(secondsFromGMT: 0) else { throw Failure.fixture }
            let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_790_586_059.25), timeZone: zone)
            var instant = executor.clock.now()
            let clock = SkinClock(now: { instant }, uptime: executor.clock.uptime, timeZone: { zone })
            let f = try fixture(t, source, clock: clock, executor: executor, system: PreviewCountingSystem())
            let p = f.preview
            p.setVisible(true)
            t.equal(executor.pendingCount, 1)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            instant = Date(timeIntervalSince1970: .nan)
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.check(p.recordedEffects.isEmpty && p.scene == nil)
            t.equal(executor.pendingCount, 0)
            instant = executor.clock.now()
            p.updateForTick()
            t.equal(clockTexts(p).first, "0", "the delay failure keeps the previous variable value")
        }
    }

    private final class ActionRecordEditingObserver: NSObject, NSTextStorageDelegate {
        var characterEdits = 0
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            if editedMask.contains(.editedCharacters) { characterEdits += 1 }
        }
    }

    private static func runPalettePreviewTests(_ t: AppTestRunner) {
        // This explicit native catalog is independent of MacAppearance's provider and ProgramColor resolution.
        let native: [(String, NSColor)] = [("accent", .controlAccentColor), ("text", .labelColor), ("dim", .secondaryLabelColor),
            ("faint", .tertiaryLabelColor), ("separator", .separatorColor), ("red", .systemRed), ("orange", .systemOrange),
            ("yellow", .systemYellow), ("green", .systemGreen), ("mint", .systemMint), ("teal", .systemTeal), ("cyan", .systemCyan),
            ("blue", .systemBlue), ("indigo", .systemIndigo), ("purple", .systemPurple), ("pink", .systemPink), ("brown", .systemBrown),
            ("gray", .systemGray), ("white", .white), ("black", .black), ("clear", .clear)]
        t.suite("Desk: palette preview: all catalog colors match independent native text fill and outline pixels") {
            t.equal(Set(native.map { $0.0 }), Set(DeskCatalog.current.namedValues.filter { $0.type == "Color" }.map(\.name)))
            for (name, nativeColor) in native {
                let source = "widget { Row(spacing: 8, align: .top) { Text(\"色😀\").font(20).color(." + name + ").size(100, 50).padding(4).onClick { }; Rectangle().size(36, 28).fill(." + name + ").onClick { }; Ellipse().size(36, 28).stroke(." + name + ", width: 4).onClick { } } }"
                let f = try fixture(t, source), p = f.preview
                for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                    guard let appearance = NSAppearance(named: appearanceName) else { throw Failure.fixture }
                    f.controller.window?.appearance = appearance; p.refreshEnvironment()
                    var resolved: NSColor?
                    appearance.performAsCurrentDrawingAppearance { resolved = nativeColor.usingColorSpace(.sRGB) }
                    guard let resolved else { throw Failure.pixel }
                    let color = RGBA(r: Double(resolved.redComponent) * 255, g: Double(resolved.greenComponent) * 255,
                                     b: Double(resolved.blueComponent) * 255, a: Double(resolved.alphaComponent) * 255)
                    if name == "white" { t.equal(color, .white) }
                    if name == "clear" { t.equal(color, .clear) }
                    t.equal(p.state, .ready, "transparent boxes remain actually interactive")
                    t.equal(p.scene?.hitMap.entries.count, 3)
                    t.equal(p.scene?.size, SkinSize(width: 188, height: 50))
                    let layout = CGRect(x: 0, y: 0, width: 188, height: 50)
                    if color.a > 0 {
                        let path = CGPath(ellipseIn: CGRect(x: 152, y: 0, width: 36, height: 28), transform: nil)
                        let stroke = path.copy(strokingWithWidth: 4, lineCap: .butt, lineJoin: .miter, miterLimit: 10).boundingBoxOfPath
                        t.check(p.canvas.bounds.contains(layout.union(stroke)), "the viewport contains independently computed native paint and the full layout")
                    } else { t.equal(p.canvas.bounds, layout, "transparent paint retains its exact layout viewport") }
                    // ShapeStroker's conservative viewport can exceed the native curve bounds. As in the existing
                    // outline oracle, both views use that viewport while native geometry remains independent.
                    let viewport = p.canvas.bounds
                    let reference = PaletteReferenceView(color: color, viewport: viewport)
                    let wrong = PaletteReferenceView(color: RGBA(r: 197, g: 23, b: 83), viewport: viewport)
                    let blank = ReferenceView(items: [], size: viewport.size); blank.bounds = viewport
                    for scale in [1, 2] {
                        let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
                        let missing = try paint(blank, scale: scale), incorrect = try paint(wrong, scale: scale)
                        for rep in [actual, expected, missing, incorrect] { try canaries(t, rep) }
                        t.equal(try bytes(actual), try bytes(expected), "native \(name) \(appearanceName.rawValue) at \(scale)x")
                        t.equal(try outlineInk(missing), 0)
                        if name == "clear" {
                            t.equal(try outlineInk(actual), 0, "the known transparent palette is separately qualified")
                            t.equal(try bytes(actual), try bytes(missing))
                        } else {
                            t.check(try outlineInk(actual) > 0, "\(name) really paints; white is opaque, not an empty pass")
                            t.check(try bytes(actual) != bytes(missing))
                        }
                        t.check(try bytes(actual) != bytes(incorrect), "wrong literal paint cannot qualify \(name)")
                    }
                }
                t.check(f.app.sortedControllers.isEmpty); t.equal(try Data(contentsOf: f.file), Data(source.utf8))
            }
        }
        t.suite("Desk: palette preview: actual color notifications preserve variables clocks and a held native press") {
            let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_790_586_059.25), timeZone: TimeZone(identifier: "UTC")!)
            var blue = RGBA(r: 19, g: 67, b: 131), reads = 0
            let source = #"widget { variable enabled = false; computed caption = enabled ? "On😀" : "Off😀"; Text("{caption}|{time.now, format: "HH:mm:ss"}").font(20).color(.blue).size(280, 60).padding(8).onLoad { enabled = not enabled }.onClick { enabled = not enabled } }"#
            let f = try fixture(t, source, clock: executor.clock, executor: executor, locale: { Locale(identifier: "en_US_POSIX") }, colors: { appearance in
                reads += 1
                let value = try MacAppearance.programValues(for: appearance)
                var colors = value.colors.colors; colors[.blue] = blue
                return MacAppearance.ProgramValues(appearance: value.appearance, colors: ProgramColorInput(colors: colors))
            }), p = f.preview
            p.setVisible(true); t.equal(executor.pendingCount, 1)
            try paletteTextPixels(t, "On😀|09:00:59", color: blue, in: f)
            let stamp = p.scene?.environment, generation = p.scene?.generation
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            blue = RGBA(r: 131, g: 53, b: 17)
            NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            t.check(AppSelfTest.spin(timeout: 5) { p.scene?.generation != generation })
            t.equal(p.scene?.environment, stamp, "only a named palette color changed, outside the original five-color stamp")
            try paletteTextPixels(t, "On😀|09:00:59", color: blue, in: f)
            executor.advance(until: 0.75)
            try paletteTextPixels(t, "On😀|09:01:00", color: blue, in: f)
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            try paletteTextPixels(t, "Off😀|09:01:00", color: blue, in: f)
            t.equal(executor.pendingCount, 1, "a legal palette refresh retains the real clock dependency")
            let current = p.scene?.generation
            f.controller.window?.appearance = NSAppearance(named: .darkAqua); p.refreshEnvironment()
            t.check(p.scene?.generation != current)
            try paletteTextPixels(t, "Off😀|09:01:00", color: blue, in: f)
            p.close(); t.equal(executor.pendingCount, 0)
            let closedReads = reads
            NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            executor.advance(by: 2)
            t.equal(reads, closedReads); t.equal(p.state, .closed); t.check(p.scene == nil && p.canvas.isHidden)
        }
        t.suite("Desk: palette preview: failed capture pending source read failure and close clear stale colors") {
            let queue = DispatchQueue(label: "desk.palette.pending.check")
            var fail = false
            let source = #"widget { variable enabled = false; Text(enabled ? "On😀" : "Off😀").font(20).color(.blue).size(280, 60).padding(8).onLoad { enabled = not enabled }.onClick { enabled = not enabled } }"#
            let f = try fixture(t, source + "\n//" + String(repeating: "x", count: 9_000), queue: queue, colors: { appearance in
                if fail { throw MacAppearance.ProgramFailure.unresolvableColor(.blue) }
                return try MacAppearance.programValues(for: appearance)
            }), p = f.preview
            t.check(settled(f)); p.setVisible(true)
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            t.check(p.scene != nil)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            fail = true
            NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            if case .unavailable(let message) = p.state { t.check(message.contains("unresolvableColor")) }
            else { t.check(false, "a failed real provider explicitly invalidates the previous preview") }
            t.check(p.scene == nil && p.canvas.isHidden)
            fail = false
            NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            t.equal(p.scene?.drawingItems.compactMap { if case .text(let value) = $0 { return value.text }; return nil }, ["On😀"])
            let recovered = p.scene?.generation
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.equal(p.scene?.generation, recovered, "capture failure cancels the old held press, while recovery does not repeat onLoad")
            queue.suspend()
            var suspended = true
            defer { if suspended { queue.resume() } }
            let previous = checking.snapshot
            replace(source.replacingOccurrences(of: ".blue", with: ".red") + "\n//" + String(repeating: "x", count: 9_000), in: f)
            t.check(!checking.snapshot.isChecked && !checking.isCurrent(previous))
            NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            t.equal(p.state, .checking); t.check(p.scene == nil && p.canvas.isHidden)
            p.show(previous, readError: nil); t.check(p.scene == nil, "old checked generation cannot restore palette pixels")
            queue.resume(); suspended = false; t.check(settled(f)); t.equal(p.state, .ready)
            try Data([0xFF]).write(to: f.file)
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            t.check(p.scene == nil && p.canvas.isHidden)
            NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            t.check(p.scene == nil && p.canvas.isHidden, "read errors stay empty despite platform changes")
            p.close(); NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            t.equal(p.state, .closed); t.check(p.scene == nil)
        }
    }

    private static func paletteTextPixels(_ t: AppTestRunner, _ text: String, color: RGBA, in f: Fixture) throws {
        var style = TextStyle()
        style.fontFace = "System"; style.fontSize = 15; style.fontWeight = 400; style.color = color
        style.horizontalAlign = .center; style.verticalAlign = .center
        style.accurateText = true; style.antiAlias = true; style.trailingSpaces = true
        let frame = SkinRect(width: 280, height: 60)
        let draw = TextDraw(text: text, style: style, frame: frame, contentFrame: SkinRect(x: 8, y: 8, width: 264, height: 44), anchor: SkinPoint())
        t.equal(f.preview.scene?.drawingItems, [.text(draw)])
        let reference = ReferenceView(items: [.text(draw)], size: NSSize(width: 280, height: 60))
        let blank = ReferenceView(items: [], size: reference.bounds.size)
        for scale in [1, 2] {
            let actual = try paint(f.preview.canvas, scale: scale), expected = try paint(reference, scale: scale)
            try canaries(t, actual); try canaries(t, expected)
            t.check(try ink(actual) > 0); t.equal(try ink(paint(blank, scale: scale)), 0)
            t.equal(try bytes(actual), try bytes(expected))
        }
    }

    /// Literal native geometry and independently constructed point-text style, not Program geometry/resolution.
    private final class PaletteReferenceView: NSView {
        let color: RGBA
        let context = DrawContext(fonts: AppFontResolver())
        override var isFlipped: Bool { true }
        init(color: RGBA, viewport: CGRect) {
            self.color = color
            super.init(frame: NSRect(origin: .zero, size: viewport.size)); bounds = viewport
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func draw(_ dirtyRect: NSRect) {
            guard let destination = NSGraphicsContext.current?.cgContext else { return }
            destination.saveGState(); defer { destination.restoreGState() }
            var style = TextStyle()
            style.fontFace = "System"; style.fontSize = 15; style.fontWeight = 400; style.color = color
            style.horizontalAlign = .center; style.verticalAlign = .center
            style.accurateText = true; style.antiAlias = true; style.trailingSpaces = true
            let draw = TextDraw(text: "色😀", style: style, frame: SkinRect(width: 100, height: 50),
                                contentFrame: SkinRect(x: 4, y: 4, width: 92, height: 42), anchor: SkinPoint())
            DesksetDraw.DrawExecutor.draw([.text(draw)], in: destination, context: context, cycle: 1,
                                         target: DrawTarget.capture(destination, glass: .none))
            destination.setAllowsAntialiasing(true); destination.setShouldAntialias(true)
            destination.setFillColor(CGColor(srgbRed: color.r / 255, green: color.g / 255, blue: color.b / 255, alpha: color.a / 255))
            destination.fill(CGRect(x: 108, y: 0, width: 36, height: 28))
            let path = CGPath(ellipseIn: CGRect(x: 152, y: 0, width: 36, height: 28), transform: nil)
            destination.addPath(path.copy(strokingWithWidth: 4, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
            destination.fillPath(using: .winding)
        }
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in f: Fixture,
                              flags: NSEvent.ModifierFlags = []) throws {
        let canvas = f.preview.canvas
        let windowPoint = canvas.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: flags, timestamp: 0,
                                            windowNumber: f.controller.window?.windowNumber ?? 0, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1) else { throw Failure.fixture }
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .leftMouseUp: canvas.mouseUp(with: event)
        case .rightMouseDown: canvas.rightMouseDown(with: event)
        case .rightMouseDragged: canvas.rightMouseDragged(with: event)
        case .rightMouseUp: canvas.rightMouseUp(with: event)
        default: throw Failure.fixture
        }
    }

    private static func click(at point: NSPoint, in f: Fixture) throws {
        try mouse(.leftMouseDown, at: point, in: f)
        try mouse(.leftMouseUp, at: point, in: f)
    }


    private static func runFontSizePreviewTests(_ t: AppTestRunner) {
        let source = #"widget { variable size = 20; Text("甲😀").font(size).color(.accent).padding(8).onClick { size = size + 4 } }"#
        t.suite("Desk: font size preview: invalid live sizes explain the error in the Studio language and recover") {
            let oldLanguage = StudioText.languageOverride
            defer { StudioText.languageOverride = oldLanguage }
            let messages: [(StudioLanguage, String)] = [
                (.english, "Text content or style is invalid. Check the text, color and font; font size must be finite and greater than zero."),
                (.chinese, "文字内容或样式无效。请检查文字、颜色与字体；字号必须为大于 0 的有限数值。")
            ]
            for (language, message) in messages {
                StudioText.languageOverride = language
                let f = try fixture(t, source), p = f.preview
                t.equal(p.state, .ready)
                replace(source.replacingOccurrences(of: "size = 20", with: "size = 0"), in: f)
                t.check(settled(f))
                t.equal(p.state, .unavailable(message))
                t.check(p.scene == nil && p.canvas.isHidden)
                replace(source, in: f)
                t.check(settled(f))
                t.equal(p.state, .ready)
                t.check(p.scene != nil && !p.canvas.isHidden)
            }
        }
        t.suite("Desk: font size preview: native clicks grow point fonts with independent literal pixels") {
            let f = try fixture(t, source), p = f.preview
            p.setVisible(true)
            try fontSizePixels(t, [("甲😀", 20, 400)], in: f)
            let first = p.scene?.generation
            try click(at: NSPoint(x: 20, y: 20), in: f)
            t.check(p.scene?.generation != first)
            try fontSizePixels(t, [("甲😀", 24, 400)], in: f)
            f.controller.window?.appearance = NSAppearance(named: .darkAqua); p.refreshEnvironment()
            try fontSizePixels(t, [("甲😀", 24, 400)], in: f)
            try click(at: NSPoint(x: 20, y: 20), in: f)
            try fontSizePixels(t, [("甲😀", 28, 400)], in: f)
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
            t.check(f.app.sortedControllers.isEmpty)
        }
        t.suite("Desk: font size preview: appearance computations inherit while literals and presets keep their own size") {
            let source = #"widget { computed size = system.dark ? 20 : 28; Column(spacing: 3, align: .left) { Text("甲😀"); Text("B").font(13); Text("C").font(.caption) }.font(size).color(.accent).padding(8) }"#
            let f = try fixture(t, source), p = f.preview
            try fontSizePixels(t, [("甲😀", 28, 400), ("B", 13, 400), ("C", 11, 500)], spacing: 3, in: f)
            let old = p.scene?.elements.map(\.id)
            f.controller.window?.appearance = NSAppearance(named: .darkAqua); p.refreshEnvironment()
            try fontSizePixels(t, [("甲😀", 20, 400), ("B", 13, 400), ("C", 11, 500)], spacing: 3, in: f)
            t.equal(p.scene?.elements.map(\.id), old)
            f.controller.window?.appearance = NSAppearance(named: .aqua); p.refreshEnvironment()
            try fontSizePixels(t, [("甲😀", 28, 400), ("B", 13, 400), ("C", 11, 500)], spacing: 3, in: f)
        }
        t.suite("Desk: font size preview: live size ticks preserve a held press and close cancels the original timer") {
            let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
            let source = #"widget { variable started = time.now; computed size = 20 + (time.now - started) / 1s; Text("甲😀").font(size).color(.accent).padding(8).onClick { started = time.now } }"#
            let f = try fixture(t, source, clock: executor.clock, executor: executor), p = f.preview
            p.setVisible(true); t.equal(executor.pendingCount, 1)
            try fontSizePixels(t, [("甲😀", 20, 400)], in: f)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            executor.advance(until: 4)
            try fontSizePixels(t, [("甲😀", 24, 400)], in: f)
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            try fontSizePixels(t, [("甲😀", 20, 400)], in: f)
            t.equal(executor.pendingCount, 1)
            p.close(); t.equal(executor.pendingCount, 0)
            executor.advance(by: 5)
            t.equal(p.state, .closed); t.check(p.scene == nil && p.canvas.isHidden)
        }
        t.suite("Desk: font size preview: invalid pending stale and closed sources clear old glyphs and recover") {
            let invalid = try fixture(t, #"widget { variable bad = false; computed size = bad ? 0 : 20; Text("甲😀").font(size).color(.accent).padding(8).onClick { bad = true } }"#)
            invalid.preview.setVisible(true)
            try fontSizePixels(t, [("甲😀", 20, 400)], in: invalid)
            try click(at: NSPoint(x: 20, y: 20), in: invalid)
            if case .unavailable(let reason) = invalid.preview.state { t.check(!reason.isEmpty) }
            else { t.check(false, "missing/nonpositive font size fails the scene rather than silently using a default") }
            t.check(invalid.preview.scene == nil && invalid.preview.canvas.isHidden)
            // The failed assignment rolled back. Existing redraw/environment refresh can reproject that valid state.
            invalid.preview.refreshEnvironment()
            try fontSizePixels(t, [("甲😀", 20, 400)], in: invalid)

            let appearance = try fixture(t, #"widget { computed size = system.dark ? 0 : 20; Text("甲😀").font(size).color(.accent).padding(8) }"#)
            try fontSizePixels(t, [("甲😀", 20, 400)], in: appearance)
            appearance.controller.window?.appearance = NSAppearance(named: .darkAqua)
            appearance.preview.refreshEnvironment()
            if case .unavailable(let reason) = appearance.preview.state { t.check(!reason.isEmpty) }
            else { t.check(false, "a persistent invalid point size cannot fall back to a literal font") }
            t.check(appearance.preview.scene == nil && appearance.preview.canvas.isHidden)
            appearance.preview.canvas.bounds = NSRect(x: 0, y: 0, width: 8, height: 8)
            let cleared = try paint(appearance.preview.canvas); try canaries(t, cleared); t.equal(try ink(cleared), 0)
            t.check(appearance.preview.scene == nil && appearance.preview.canvas.isHidden)
            appearance.controller.window?.appearance = NSAppearance(named: .aqua)
            appearance.preview.refreshEnvironment()
            try fontSizePixels(t, [("甲😀", 20, 400)], in: appearance)

            replace(#"widget { variable size = 1000000; Text("甲😀").font(size).padding(8) }"#, in: invalid)
            t.check(settled(invalid))
            t.check(invalid.preview.scene == nil && invalid.preview.canvas.isHidden, "the unchanged native pixel budget rejects enormous live fonts")

            let queue = DispatchQueue(label: "desk.font.pending.check")
            let pendingSource = source + "\n//" + String(repeating: "x", count: 9_000)
            let f = try fixture(t, pendingSource, queue: queue), p = f.preview
            t.check(settled(f))
            p.setVisible(true)
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            let old = checking.snapshot
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            queue.suspend(); var suspended = true
            defer { if suspended { queue.resume() } }
            replace(pendingSource.replacingOccurrences(of: "size = 20", with: "size = 24"), in: f)
            t.equal(p.state, .checking); t.check(p.scene == nil && p.canvas.isHidden)
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.check(!checking.publish(old))
            queue.resume(); suspended = false
            t.check(settled(f)); try fontSizePixels(t, [("甲😀", 24, 400)], in: f)
            p.show(old, readError: nil); t.check(p.scene == nil && p.canvas.isHidden)
            p.show(checking.snapshot, readError: nil); try fontSizePixels(t, [("甲😀", 24, 400)], in: f)
            p.show(checking.snapshot, readError: "controlled read failure"); t.check(p.scene == nil && p.canvas.isHidden)
            p.show(checking.snapshot, readError: nil); try fontSizePixels(t, [("甲😀", 24, 400)], in: f)
            p.close(); p.show(checking.snapshot, readError: nil)
            t.check(p.scene == nil && p.canvas.isHidden); t.equal(p.state, .closed)
            t.check(f.app.sortedControllers.isEmpty)
        }
    }

    /// Independent literal point-size recipes and native measurement, never copied from the candidate scene.
    private static func fontSizePixels(_ t: AppTestRunner, _ parts: [(String, Double, Int)], spacing: Double? = nil,
                                       in f: Fixture) throws {
        t.equal(f.preview.state, .ready)
        let appearance = MacAppearance.values(for: f.preview.canvas.effectiveAppearance)
        let context = DrawContext(fonts: AppFontResolver())
        var sizes: [SkinSize] = [], styles: [TextStyle] = []
        for (text, points, weight) in parts {
            var style = TextStyle()
            style.fontFace = "System"; style.fontSize = points * 0.75; style.fontWeight = weight
            style.color = appearance.accentColor; style.horizontalAlign = .center; style.verticalAlign = .center
            style.accurateText = true; style.antiAlias = true; style.trailingSpaces = true
            t.close(CTFontGetSize(AppFontResolver().resolve(FontRequest(style: style)).font), points)
            let measured = context.text.layout(text, style: style, wrapWidth: nil, cycle: 1).size
            sizes.append(SkinSize(width: measured.width, height: measured.height))
            styles.append(style)
        }
        let width = (sizes.map(\.width).max() ?? 0) + 16
        let height = sizes.reduce(0) { $0 + $1.height } + (spacing ?? 0) * Double(parts.count - 1) + 16
        var items: [DrawItem] = [], wrong: [DrawItem] = [], y = 8.0
        for index in parts.indices {
            let content = SkinRect(x: 8, y: y, width: sizes[index].width, height: sizes[index].height)
            let frame = spacing == nil ? SkinRect(width: width, height: height) : content
            let anchor = spacing == nil ? SkinPoint() : SkinPoint(x: 8, y: y)
            items.append(.text(TextDraw(text: parts[index].0, style: styles[index], frame: frame, contentFrame: content, anchor: anchor)))
            var wrongStyle = styles[index]; wrongStyle.fontSize += 0.75
            wrong.append(.text(TextDraw(text: parts[index].0, style: wrongStyle, frame: frame, contentFrame: content, anchor: anchor)))
            y += sizes[index].height + (spacing ?? 0)
        }
        t.equal(f.preview.scene?.size, SkinSize(width: width, height: height))
        t.equal(f.preview.scene?.drawingItems, items, "the actual live style is measured and drawn with this literal point-font recipe")
        let reference = ReferenceView(items: items, size: NSSize(width: width, height: height))
        reference.appearance = f.controller.window?.appearance
        let incorrect = ReferenceView(items: wrong, size: reference.frame.size); incorrect.appearance = reference.appearance
        let blank = ReferenceView(items: [], size: reference.frame.size)
        for scale in [1, 2] {
            let actual = try paint(f.preview.canvas, scale: scale), expected = try paint(reference, scale: scale)
            let missing = try paint(blank, scale: scale), other = try paint(incorrect, scale: scale)
            for rep in [actual, expected, missing, other] { try canaries(t, rep) }
            t.check(try ink(actual) > 0); t.equal(try ink(missing), 0)
            t.equal(try bytes(actual), try bytes(expected), "complete native live font at \(scale)x")
            t.check(try bytes(actual) != bytes(missing) && bytes(actual) != bytes(other), "blank or one-point-wrong native paint cannot qualify")
        }
    }

    private static func runUnitPreviewTests(_ t: AppTestRunner) {
        let source = "\u{FEFF}" + #"widget { variable percent = 50%; variable bytes = 1KB; variable elapsed = 90s; Text("😀7|{percent}|{bytes}|{elapsed, style: .clock}").font(20).color(.accent).size(520, 60).padding(8).onClick { percent = percent + 5%; bytes = bytes + 1KB; elapsed = elapsed + 1s } }"# + "\r\n"
        t.suite("Desk: units preview: primary clicks paint percent bytes and duration with literal native ranges") {
            let original = try fixture(t, #"widget { Text(1%) }"#, locale: { Locale(identifier: "en_US") })
            t.equal(original.preview.state, .ready); t.equal(clockTexts(original.preview), ["1"])
            let f = try fixture(t, source, locale: { Locale(identifier: "en_US") }), p = f.preview
            p.setVisible(true)
            let ranges = [NSRange(location: 4, length: 2), NSRange(location: 7, length: 3),
                          NSRange(location: 14, length: 1), NSRange(location: 16, length: 2)]
            try numericPixels(t, "😀7|50|1.0 KB|1:30", ranges: ranges, in: f)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                f.controller.window?.appearance = NSAppearance(named: appearance); p.refreshEnvironment()
                try click(at: NSPoint(x: 20, y: 20), in: f)
                try numericPixels(t, appearance == .aqua ? "😀7|55|2.0 KB|1:31" : "😀7|60|3.0 KB|1:32", ranges: ranges, in: f)
            }
            t.equal(f.editor.text, source); t.equal(try Data(contentsOf: f.file), Data(source.utf8))
            t.check(f.app.sortedControllers.isEmpty, "local unit state activates no Skin or data service")
        }

        t.suite("Desk: units preview: locale changes preserve frozen unit text and expose numeric fields only") {
            var locale = Locale(identifier: "en_US")
            let text = #"widget { variable p = 12.5%; variable b = 12500B; variable frozen = "{b}"; Text("😀7|{p, decimals: 1}|{frozen}|{b}|{90s, style: .clock}").font(20).color(.accent).size(520, 60).padding(8).onClick { b = b + 100B; frozen = "{b}" } }"#
            let f = try fixture(t, text, locale: { locale }), p = f.preview
            p.setVisible(true)
            let ranges = [NSRange(location: 4, length: 4), NSRange(location: 9, length: 4),
                          NSRange(location: 17, length: 4), NSRange(location: 25, length: 1), NSRange(location: 27, length: 2)]
            try numericPixels(t, "😀7|12.5|12.5 KB|12.5 KB|1:30", ranges: ranges, in: f)
            locale = Locale(identifier: "de_DE"); p.refreshDateInput()
            try numericPixels(t, "😀7|12,5|12.5 KB|12,5 KB|1:30", ranges: ranges, in: f)
            try click(at: NSPoint(x: 20, y: 20), in: f)
            try numericPixels(t, "😀7|12,5|12,6 KB|12,6 KB|1:30", ranges: ranges, in: f)
            for policy in ["normal", "equalWidth"] {
                replace(text.replacingOccurrences(of: ".font(20)", with: ".digits(." + policy + ").font(20)"), in: f)
                t.check(settled(f)); t.equal(p.state, .ready)
                try numericPixels(t, "😀7|12,5|12,5 KB|12,5 KB|1:30", ranges: policy == "normal" ? [] : [NSRange(location: 0, length: 29)], in: f)
            }
        }

        t.suite("Desk: units preview: typed missing and rejected unit programs clear old native content") {
            let text = #"widget { variable b = 1KB; Text("😀{b, missing: "空😀"}|{b.isMissing}|{(b < 0B).ifMissing(true)}").font(20).color(.accent).size(520, 60).padding(8).onClick { b = b.isMissing ? 2KB : 1KB / 0 } }"#
            let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
            let system = PreviewCountingSystem()
            let f = try fixture(t, text, clock: executor.clock, executor: executor,
                                locale: { Locale(identifier: "en_US") }, system: system), p = f.preview
            p.setVisible(true)
            try numericPixels(t, "😀1.0 KB|No|No", ranges: [NSRange(location: 2, length: 3)], in: f)
            try click(at: NSPoint(x: 20, y: 20), in: f)
            try numericPixels(t, "😀空😀|Yes|Yes", ranges: [], in: f)
            try click(at: NSPoint(x: 20, y: 20), in: f)
            try numericPixels(t, "😀2.0 KB|No|No", ranges: [NSRange(location: 2, length: 3)], in: f)
            replace(#"widget { Text(memory.used).font(20).color(.accent).size(520, 60).padding(8) }"#, in: f)
            t.check(settled(f)); t.equal(p.state, .ready)
            try numericPixels(t, "16.0 GB", ranges: [NSRange(location: 0, length: 4)], in: f)
            t.equal(system.memCalls, 1); t.equal(system.cpuCalls, 0)
            t.equal(executor.pendingCount, 1)
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            let previous = checking.snapshot
            for invalid in [#"widget { Text(1KB / 1s) }"#, #"widget { Text("{1s, decimals: 1}") }"#,
                            #"widget { Text(50% * 25%) }"#] {
                replace(invalid, in: f); t.check(settled(f))
                guard case .unavailable(let reason) = p.state else { return t.check(false, "unsupported or invalid units must report a real reason; input: \(invalid); state: \(p.state)") }
                t.check(!reason.isEmpty && p.scene == nil && p.canvas.isHidden)
                t.equal(executor.pendingCount, 0)
                t.check(!checking.publish(previous))
                p.canvas.setBoundsSize(NSSize(width: 8, height: 8))
                let cleared = try paint(p.canvas); try canaries(t, cleared); t.equal(try ink(cleared), 0)
            }
            replace(text, in: f); t.check(settled(f)); p.setVisible(true)
            try numericPixels(t, "😀1.0 KB|No|No", ranges: [NSRange(location: 2, length: 3)], in: f)
            f.controller.window?.close(); try click(at: NSPoint(x: 20, y: 20), in: f)
            t.equal(p.state, .closed); t.check(p.scene == nil)
            t.equal(executor.pendingCount, 0)
        }

        t.suite("Desk: units preview: live date differences use one boundary while frozen and hidden duration stays idle") {
            let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
            let text = #"widget { variable opened = time.now; computed elapsed = time.now - opened; Text("😀7|{elapsed, style: .clock}").font(20).color(.accent).size(520, 60).padding(8) }"#
            let f = try fixture(t, text, clock: executor.clock, executor: executor, locale: { Locale(identifier: "en_US") }), p = f.preview
            p.setVisible(true)
            try numericPixels(t, "😀7|0:00", ranges: [NSRange(location: 4, length: 1), NSRange(location: 6, length: 2)], in: f)
            t.equal(executor.pendingCount, 1); executor.advance(by: 90)
            try numericPixels(t, "😀7|1:30", ranges: [NSRange(location: 4, length: 1), NSRange(location: 6, length: 2)], in: f)
            p.setVisible(false); t.equal(executor.pendingCount, 0); executor.advance(by: 30)
            p.setVisible(true)
            try numericPixels(t, "😀7|2:00", ranges: [NSRange(location: 4, length: 1), NSRange(location: 6, length: 2)], in: f)
            let frozen = #"widget { variable d = time.now - time.now; Text("😀7|{d, style: .clock}").font(20).color(.accent).size(520, 60).padding(8) }"#
            replace(frozen, in: f); t.check(settled(f)); t.equal(executor.pendingCount, 0)
            executor.advance(by: 60); p.refreshDateInput()
            try numericPixels(t, "😀7|0:00", ranges: [NSRange(location: 4, length: 1), NSRange(location: 6, length: 2)], in: f)
            replace(text.replacingOccurrences(of: ".font(20)", with: ".hidden().font(20)"), in: f)
            t.check(settled(f)); t.equal(p.state, .empty); t.equal(executor.pendingCount, 0)
            f.controller.window?.close(); executor.advance(by: 3)
            t.equal(p.state, .closed); t.equal(executor.pendingCount, 0)
        }
    }

    private static func runNumericPreviewTests(_ t: AppTestRunner) {
        let source = "\u{FEFF}" + #"widget { variable n = 0; computed twice = n * 2; Text("😀7|{n}|{twice}").font(20).color(.accent).size(520, 60).padding(8).onClick { n = n + 1 } }"# + "\r\n"
        t.suite("Desk: numeric preview: real primary clicks draw counters and precise emoji numeric ranges") {
            let f = try fixture(t, source, locale: { Locale(identifier: "en_US") }), p = f.preview
            p.setVisible(true)
            let ranges = [NSRange(location: 4, length: 1), NSRange(location: 6, length: 1)]
            try numericPixels(t, "😀7|0|0", ranges: ranges, in: f)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                f.controller.window?.appearance = NSAppearance(named: name); p.refreshEnvironment()
                try click(at: NSPoint(x: 20, y: 20), in: f)
                try numericPixels(t, name == .aqua ? "😀7|1|2" : "😀7|2|4", ranges: ranges, in: f)
            }
            let generation = p.scene?.generation
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.equal(p.scene?.generation, generation)
            t.equal(f.editor.text, source); t.equal(try Data(contentsOf: f.file), Data(source.utf8))
            t.check(f.app.sortedControllers.isEmpty && p.scene != nil)
        }

        t.suite("Desk: numeric preview: frozen String formatting locale refresh and digits policies consume native styles") {
            var locale = Locale(identifier: "en_US")
            let text = #"widget { variable n = 12345.678; variable frozen = "{n}"; computed live = "{n, decimals: 1}"; Text("😀7|{frozen}|{live}").font(20).color(.accent).size(520, 60).padding(8).onClick { n = n + 1; frozen = "{n}" } }"#
            let f = try fixture(t, text, locale: { locale }), p = f.preview
            p.setVisible(true)
            let ranges = [NSRange(location: 4, length: 9), NSRange(location: 14, length: 8)]
            try numericPixels(t, "😀7|12,345.68|12,345.7", ranges: ranges, in: f)
            locale = Locale(identifier: "de_DE"); p.refreshDateInput()
            try numericPixels(t, "😀7|12,345.68|12.345,7", ranges: ranges, in: f)
            try click(at: NSPoint(x: 20, y: 20), in: f)
            try numericPixels(t, "😀7|12.346,68|12.346,7", ranges: ranges, in: f)
            for policy in ["normal", "equalWidth"] {
                let modified = text.replacingOccurrences(of: ".font(20)", with: ".digits(." + policy + ").font(20)")
                replace(modified, in: f); t.check(settled(f)); t.equal(p.state, .ready)
                let expected = "😀7|12.345,68|12.345,7"
                try numericPixels(t, expected, ranges: policy == "normal" ? [] : [NSRange(location: 0, length: 22)], in: f)
            }
        }

        t.suite("Desk: numeric preview: typed missing recovery and unsupported units clear real previous pixels") {
            let text = #"widget { variable n = 1; Text("😀{n, decimals: 1, missing: "空😀"}|{n.isMissing}|{(n < 0).ifMissing(true)}").font(20).color(.accent).size(520, 60).padding(8).onClick { n = n.isMissing ? 2 : 1 / 0 } }"#
            let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
            let system = PreviewCountingSystem()
            let f = try fixture(t, text, clock: executor.clock, executor: executor,
                                locale: { Locale(identifier: "en_US") }, system: system), p = f.preview
            p.setVisible(true)
            try numericPixels(t, "😀1.0|No|No", ranges: [NSRange(location: 2, length: 3)], in: f)
            try click(at: NSPoint(x: 20, y: 20), in: f)
            try numericPixels(t, "😀空😀|Yes|Yes", ranges: [], in: f)
            try click(at: NSPoint(x: 20, y: 20), in: f)
            try numericPixels(t, "😀2.0|No|No", ranges: [NSRange(location: 2, length: 3)], in: f)
            replace(#"widget { Text(cpu.usage).font(20).color(.accent).size(520, 60).padding(8) }"#, in: f)
            t.check(settled(f)); t.equal(p.state, .ready)
            try numericPixels(t, "42", ranges: [NSRange(location: 0, length: 2)], in: f)
            t.equal(system.cpuCalls, 1); t.equal(system.memCalls, 0)
            t.equal(executor.pendingCount, 1)
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            let old = checking.snapshot
            // The original Percent literal is retained unchanged in runUnitPreviewTests' positive control.
            for invalid in [#"widget { Text(1°C) }"#] {
                replace(invalid, in: f); t.check(settled(f))
                guard case .unavailable(let reason) = p.state else { return t.check(false, "dimensioned or service numeric data must report unsupported; input: \(invalid); state: \(p.state)") }
                t.check(!reason.isEmpty && p.scene == nil && p.canvas.isHidden)
                t.equal(executor.pendingCount, 0)
                t.check(!checking.publish(old))
                p.canvas.setBoundsSize(NSSize(width: 8, height: 8))
                let clear = try paint(p.canvas); try canaries(t, clear); t.equal(try ink(clear), 0)
            }
            replace(text, in: f); t.check(settled(f)); p.setVisible(true)
            try numericPixels(t, "😀1.0|No|No", ranges: [NSRange(location: 2, length: 3)], in: f)
            f.controller.window?.close()
            try click(at: NSPoint(x: 20, y: 20), in: f)
            t.check(p.scene == nil && p.state == .closed)
            t.equal(executor.pendingCount, 0)
        }
    }

    private static func numericPixels(_ t: AppTestRunner, _ text: String, ranges: [NSRange], in f: Fixture) throws {
        // Independent literal recipe: no ProgramText/formatter/runtime helper supplies this expected style or text.
        var style = TextStyle()
        style.fontFace = "System"; style.fontSize = 15; style.fontWeight = 400
        style.color = MacAppearance.values(for: f.preview.canvas.effectiveAppearance).accentColor
        style.horizontalAlign = .center; style.verticalAlign = .center
        style.accurateText = true; style.antiAlias = true; style.trailingSpaces = true
        style.inlineSpans = ranges.map { InlineSpan(location: $0.location, length: $0.length, setting: .typography(feature: "tnum", value: 1)) }
        let item = DrawItem.text(TextDraw(text: text, style: style, frame: SkinRect(width: 520, height: 60),
                                         contentFrame: SkinRect(x: 8, y: 8, width: 504, height: 44), anchor: SkinPoint()))
        t.equal(clockTexts(f.preview), [text]); t.equal(f.preview.scene?.drawingItems, [item])
        t.close(CTFontGetSize(AppFontResolver().resolve(FontRequest(style: style)).font), 20)
        let reference = ReferenceView(items: [item], size: NSSize(width: 520, height: 60))
        reference.appearance = f.preview.canvas.effectiveAppearance
        let blank = ReferenceView(items: [], size: reference.frame.size)
        let wrong = ReferenceView(items: [.text(TextDraw(text: text + "0", style: style, frame: SkinRect(width: 520, height: 60),
                                  contentFrame: SkinRect(x: 8, y: 8, width: 504, height: 44), anchor: SkinPoint()))], size: reference.frame.size)
        wrong.appearance = reference.appearance
        for scale in [1, 2] {
            let actual = try paint(f.preview.canvas, scale: scale), expected = try paint(reference, scale: scale)
            try canaries(t, actual); try canaries(t, expected)
            t.check(try ink(actual) > 0); t.equal(try ink(paint(blank, scale: scale)), 0)
            t.equal(try bytes(actual), try bytes(expected), "native plain-number / independent TextDraw complete bytes at \(scale)x")
            t.check(try bytes(actual) != bytes(paint(wrong, scale: scale)), "an incorrect literal numeric text fails the strict native comparison")
        }
    }

    private static func runClickPreviewTests(_ t: AppTestRunner) {
        let start = Date(timeIntervalSince1970: 1_790_586_059.25)
        let utc = TimeZone(identifier: "UTC")!, locale = Locale(identifier: "en_US_POSIX")
        let source = #"widget { variable flag = false; computed caption = flag ? "开😀" : "关😀"; Text(caption).font(20).color(.accent).size(280, 60).padding(8).onLoad { flag = true }.onClick { flag = not flag } }"#
        t.suite("Desk: click preview: native primary events paint shared assignments with independent literal pixels") {
            let f = try fixture(t, source), p = f.preview
            p.setVisible(true)
            try clockPixels(t, "开😀", in: f)
            let original = p.scene?.generation
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.equal(p.scene?.generation, original, "release without a press cannot dispatch")
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                f.controller.window?.appearance = NSAppearance(named: name); p.refreshEnvironment()
                try click(at: NSPoint(x: 20, y: 20), in: f)
                try clockPixels(t, "关😀", in: f)
                try click(at: NSPoint(x: 20, y: 20), in: f)
                try clockPixels(t, "开😀", in: f)
            }
            let unchanged = p.scene?.generation
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f, flags: [.control])
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            try mouse(.leftMouseUp, at: NSPoint(x: 300, y: 20), in: f)
            t.equal(p.scene?.generation, unchanged)
            t.equal(f.editor.text, source); t.equal(try Data(contentsOf: f.file), Data(source.utf8))
            t.check(f.app.sortedControllers.isEmpty, "preview has no Skin or permission service")
        }

        t.suite("Desk: click preview: rounded padding transparent curves and zoom scroll use actual box coordinates") {
            let shapeSource = #"widget { variable flag = false; computed caption = flag ? "开😀" : "关😀"; Row(spacing: 0, align: .top) { Circle().size(40, 30).fill(.clear).onClick { flag = not flag }; Text(caption).font(20).color(.accent).size(280, 60).padding(8).onClick { flag = not flag } } }"#
            let f = try fixture(t, shapeSource), p = f.preview
            p.setVisible(true)
            try clickPairPixels(t, "关😀", in: f)
            p.setZoom(2)
            p.scrollView.contentView.scroll(to: NSPoint(x: 8, y: 0))
            p.scrollView.reflectScrolledClipView(p.scrollView.contentView)
            t.close(Double(p.scrollView.magnification), 2)
            t.check(p.scrollView.contentView.bounds.origin.x > 0)
            try click(at: NSPoint(x: 0.5, y: 0.5), in: f) // Outside the circle's ink, inside its box.
            try clickPairPixels(t, "开😀", in: f)
            let sameElement = p.scene?.generation
            try mouse(.leftMouseDown, at: NSPoint(x: 0.5, y: 0.5), in: f)
            try mouse(.leftMouseUp, at: NSPoint(x: 60, y: 20), in: f)
            t.equal(p.scene?.generation, sameElement, "a different valid leaf handler cannot receive the held press")
            let rounded = shapeSource.replacingOccurrences(of: "Circle().size(40, 30).fill(.clear)",
                                                           with: "Rectangle().size(40, 30).fill(.clear).rounded(.full).padding(4)")
            replace(rounded, in: f); t.check(settled(f))
            let generation = p.scene?.generation
            try click(at: NSPoint(x: 0.5, y: 0.5), in: f)
            t.equal(p.scene?.generation, generation, "rounded box removes the corner")
            try click(at: NSPoint(x: 1, y: 15), in: f)
            try clickPairPixels(t, "开😀", in: f) // Padding is hit even though it paints no pixels.
            let invisible = #"widget { Circle().size(40, 30).fill(.clear).onClick { } }"#
            replace(invisible, in: f); t.check(settled(f))
            t.equal(p.state, .ready); t.check(!p.canvas.isHidden)
            let old = p.scene?.generation
            try click(at: NSPoint(x: 0.5, y: 0.5), in: f)
            t.equal(p.scene?.generation, old.map { $0 + 1 }, "empty handlers still consume actual primary releases")
            let transparent = try paint(p.canvas); try canaries(t, transparent); t.equal(try ink(transparent), 0)
            replace(#"widget { Circle().size(40, 30).fill(.clear).hidden().onClick { } }"#, in: f)
            t.check(settled(f)); t.equal(p.state, .empty); t.check(p.canvas.isHidden)
            t.equal(p.scene?.hitMap.entries.count, 0)
            replace(#"widget { variable flag = false; Rectangle().size(32, 24).stroke(.white, width: 4).onClick { flag = not flag } }"#, in: f)
            t.check(settled(f))
            let viewport = CGRect(x: -2, y: -2, width: 36, height: 28)
            t.equal(p.canvas.bounds, viewport, "centered stroke retains the actual negative paint origin")
            let outlined = p.scene?.generation
            try click(at: NSPoint(x: -1, y: 6), in: f)
            t.equal(p.scene?.generation, outlined, "stroke outside the box is not a click target")
            try click(at: NSPoint(x: 1, y: 6), in: f)
            t.equal(p.scene?.generation, outlined.map { $0 + 1 }, "native conversion retains scene coordinates with negative bounds")
            let outline = StyledReferenceView(path: CGPath(rect: CGRect(x: 0, y: 0, width: 32, height: 24), transform: nil),
                                              fill: .clear, stroke: .white, width: 4, viewport: viewport)
            let blank = ReferenceView(items: [], size: viewport.size); blank.bounds = viewport
            for scale in [1, 2] {
                let actual = try paint(p.canvas, scale: scale), expected = try paint(outline, scale: scale)
                try canaries(t, actual); try canaries(t, expected)
                t.check(try outlineInk(actual) > 0); t.equal(try outlineInk(paint(blank, scale: scale)), 0)
                t.equal(try bytes(actual), try bytes(expected), "independent native outlined box after a negative-origin click at \(scale)x")
            }
        }

        t.suite("Desk: click preview: legitimate clock ticks preserve a held press and transactional date assignments") {
            let executor = VirtualTimeExecutor(start: start, timeZone: utc)
            let text = #"widget { variable stamp = time.now; variable live = true; computed caption = live ? "{time.now, format: "HH:mm:ss"}😀" : "{stamp, format: "HH:mm:ss"}😀"; Text(caption).font(20).color(.accent).size(280, 60).padding(8).onClick { stamp = time.now; live = false } }"#
            let f = try fixture(t, text, clock: executor.clock, executor: executor, locale: { locale }), p = f.preview
            p.setVisible(true); t.equal(executor.pendingCount, 1)
            try clockPixels(t, "09:00:59😀", in: f)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            let pressed = p.scene?.generation
            executor.advance(until: 0.75)
            t.check(p.scene?.generation != pressed); try clockPixels(t, "09:01:00😀", in: f)
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.equal(executor.pendingCount, 0); try clockPixels(t, "09:01:00😀", in: f)
            executor.advance(by: 2); p.refreshDateInput()
            try clockPixels(t, "09:01:00😀", in: f)
            p.setVisible(false); let hidden = p.scene?.generation
            try click(at: NSPoint(x: 20, y: 20), in: f)
            t.equal(p.scene?.generation, hidden)
        }

        t.suite("Desk: click preview: checked replacement resource failure hide read error and close cancel old presses") {
            let queue = DispatchQueue(label: "desk.click.pending.check")
            let pendingSource = source + "\n//" + String(repeating: "x", count: 9_000)
            let f = try fixture(t, pendingSource, queue: queue), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            p.setVisible(true)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            p.setVisible(false); p.setVisible(true)
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            try clockPixels(t, "开😀", in: f)
            let old = checking.snapshot
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            queue.suspend(); var suspended = true
            defer { if suspended { queue.resume() } }
            replace(pendingSource.replacingOccurrences(of: "flag = true", with: "flag = false"), in: f)
            t.check(p.state == .checking && p.scene == nil && p.canvas.isHidden)
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.check(!checking.publish(old))
            queue.resume(); suspended = false; t.check(settled(f))
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            try clockPixels(t, "关😀", in: f)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            let failed = #"widget { Image("Missing.png"); Text("unavailable").onClick { } }"#
            replace(failed, in: f); t.check(imageSettled(f))
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.check(p.scene == nil && p.canvas.isHidden)
            replace(source, in: f); t.check(settled(f)); try clockPixels(t, "开😀", in: f)
            try mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: f)
            try Data([0xFF, 0xFE, 0x00, 0x00]).write(to: f.file)
            f.editor.discardUncommittedChanges()
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            try mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: f)
            t.check(f.controller.readError != nil && p.scene == nil && p.canvas.isHidden)
            p.canvas.setBoundsSize(NSSize(width: 8, height: 8))
            let clear = try paint(p.canvas); try canaries(t, clear); t.equal(try ink(clear), 0)
            f.controller.window?.close()
            try click(at: NSPoint(x: 20, y: 20), in: f)
            p.show(old, readError: nil); p.setVisible(true)
            t.check(p.state == .closed && p.scene == nil && p.canvas.isHidden)
        }
    }

    private static func clickPairPixels(_ t: AppTestRunner, _ text: String, in f: Fixture) throws {
        var style = TextStyle()
        style.fontFace = "System"; style.fontSize = 15; style.fontWeight = 400
        style.color = MacAppearance.values(for: f.preview.canvas.effectiveAppearance).accentColor
        style.horizontalAlign = .center; style.verticalAlign = .center
        style.accurateText = true; style.antiAlias = true; style.trailingSpaces = true
        let item = DrawItem.text(TextDraw(text: text, style: style, frame: SkinRect(x: 40, width: 280, height: 60),
                                         contentFrame: SkinRect(x: 48, y: 8, width: 264, height: 44), anchor: SkinPoint(x: 40)))
        let reference = ReferenceView(items: [item], size: NSSize(width: 320, height: 60))
        reference.appearance = f.preview.canvas.effectiveAppearance
        let blank = ReferenceView(items: [], size: reference.frame.size)
        t.equal(clockTexts(f.preview), [text]); t.equal(f.preview.scene?.size, SkinSize(width: 320, height: 60))
        for scale in [1, 2] {
            let actual = try paint(f.preview.canvas, scale: scale), expected = try paint(reference, scale: scale)
            try canaries(t, actual); try canaries(t, expected)
            t.check(try ink(actual) > 0); t.equal(try ink(paint(blank, scale: scale)), 0)
            t.equal(try bytes(actual), try bytes(expected), "transparent hit box plus independent native text at \(scale)x")
        }
    }

    private static func runClockPreviewTests(_ t: AppTestRunner) {
        let start = Date(timeIntervalSince1970: 1_790_586_059.25)
        let utc = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US_POSIX")
        let second = #"widget { Text("{time.now, format: "HH:mm:ss"}😀").font(20).color(.accent).size(280, 60).padding(8) }"#
        t.suite("Desk: clock preview: actual document timers paint independent second and minute text") {
            let executor = VirtualTimeExecutor(start: start, timeZone: utc)
            var reads = 0
            let clock = SkinClock(now: { reads += 1; return executor.wallClock }, uptime: { executor.uptime }, timeZone: { executor.timeZone })
            let f = try fixture(t, second, clock: clock, executor: executor, locale: { locale }), p = f.preview
            t.equal(p.state, .ready); t.equal(executor.pendingCount, 0, "an unshown document samples no display clock")
            p.setVisible(true)
            t.equal(executor.pendingCount, 1); t.close(executor.nextDue ?? -1, 0.75)
            try clockPixels(t, "09:00:59😀", in: f)
            let generation = p.scene?.generation, priorReads = reads
            executor.advance(until: 0.749)
            t.equal(p.scene?.generation, generation); t.equal(reads, priorReads)
            executor.advance(until: 0.75)
            t.equal(reads, priorReads + 1, "one immutable wall date supplies the successful projection")
            t.equal(executor.pendingCount, 1)
            try clockPixels(t, "09:01:00😀", in: f)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                p.canvas.appearance = NSAppearance(named: name)
                p.refreshEnvironment()
                try clockPixels(t, "09:01:00😀", in: f)
            }
            replace(#"widget { Text("{time.now, format: "HH:mm"}😀").font(20).color(.accent).size(280, 60).padding(8) }"#, in: f)
            t.check(settled(f)); t.equal(executor.pendingCount, 1)
            t.close(executor.nextDue ?? -1, 60.75)
            executor.advance(until: 60.749)
            t.equal(clockTexts(p), ["09:01😀"])
            executor.advance(until: 60.75)
            try clockPixels(t, "09:02😀", in: f)
            t.check(f.app.sortedControllers.isEmpty)
            t.equal(try Data(contentsOf: f.file), Data(second.utf8), "a clock never writes its source")
        }

        t.suite("Desk: clock preview: checked replacements visibility and wake cancel old temporal generations") {
            let executor = VirtualTimeExecutor(start: start, timeZone: utc)
            var selectedLocale = locale
            let f = try fixture(t, second, clock: executor.clock, executor: executor, locale: { selectedLocale }), p = f.preview
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            p.setVisible(true)
            let old = checking.snapshot, generation = p.scene?.generation
            p.setVisible(false); t.equal(executor.pendingCount, 0)
            executor.advance(by: 120)
            t.equal(p.scene?.generation, generation, "occluded display does not advance its retained session")
            p.setVisible(true); t.equal(clockTexts(p), ["09:02:59😀"]); t.equal(executor.pendingCount, 1)
            executor.setWallClock(Date(timeIntervalSince1970: 1_790_586_310.5)) // Independently 09:05:10.5 UTC.
            p.notifySystemWake()
            t.equal(clockTexts(p), ["09:05:10😀"]); t.close((executor.nextDue ?? -1) - executor.now, 0.5)
            executor.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            p.refreshDateInput(); t.equal(clockTexts(p), ["18:05:10😀"])
            replace(#"widget { variable opened = time.now; Text("{opened, format: .weekday}").font(20).color(.accent).size(280, 60).padding(8) }"#, in: f)
            t.check(settled(f)); t.equal(executor.pendingCount, 0); t.equal(clockTexts(p), ["Monday"])
            selectedLocale = Locale(identifier: "zh_Hans_CN")
            executor.setWallClock(Date(timeIntervalSince1970: 1_790_672_710.5))
            p.refreshDateInput()
            t.equal(clockTexts(p), ["星期一"], "frozen date survives a wall-day change while its locale can change")
            t.check(!checking.publish(old))
            replace(second, in: f); t.check(settled(f)); t.equal(executor.pendingCount, 1)
            f.editor.discardUncommittedChanges()
            f.controller.window?.close()
            t.equal(p.state, .closed); t.equal(executor.pendingCount, 0)
            executor.advance(by: 3)
            p.show(old, readError: nil); p.setVisible(true); p.notifySystemWake()
            t.check(p.state == .closed && p.scene == nil && p.canvas.isHidden)
            t.equal(executor.pendingCount, 0)
        }

        t.suite("Desk: clock preview: frozen startup dates hidden text and active branches retain shared state") {
            let executor = VirtualTimeExecutor(start: start, timeZone: utc)
            let source = #"widget { variable opened = time.now; computed current = time.now; Text("{opened, format: "HH:mm:ss"}/{current, format: "HH:mm:ss"}😀").font(20).color(.accent).size(280, 60).padding(8).onLoad { opened = time.now } }"#
            let f = try fixture(t, source, clock: executor.clock, executor: executor, locale: { locale }), p = f.preview
            p.setVisible(true)
            try clockPixels(t, "09:00:59/09:00:59😀", in: f)
            executor.advance(until: 0.75)
            try clockPixels(t, "09:00:59/09:01:00😀", in: f)
            t.equal(executor.pendingCount, 1, "onLoad is not rerun on a clock boundary")
            replace(#"widget { Text("{time.now, format: "ss"}").size(280, 60).hidden() }"#, in: f)
            t.check(settled(f)); t.equal(p.state, .empty); t.equal(p.scene?.size, SkinSize(width: 280, height: 60))
            t.check(p.scene?.drawingItems.isEmpty == true); t.equal(executor.pendingCount, 0)
            replace(#"widget { computed live = system.dark and time.now == time.now; Text("{live}").font(20).color(.accent).size(280, 60).padding(8) }"#, in: f)
            t.check(settled(f))
            p.canvas.appearance = NSAppearance(named: .aqua); p.refreshEnvironment()
            try clockPixels(t, "No", in: f); t.equal(executor.pendingCount, 0)
            p.canvas.appearance = NSAppearance(named: .darkAqua); p.refreshEnvironment()
            try clockPixels(t, "Yes", in: f); t.equal(executor.pendingCount, 1, "short-circuit demand follows the branch actually read")
        }

        t.suite("Desk: clock preview: resource pending invalid input read errors and close cannot revive pixels") {
            let executor = VirtualTimeExecutor(start: start, timeZone: utc)
            var invalidDate = false
            let clock = SkinClock(now: { invalidDate ? Date(timeIntervalSince1970: .nan) : executor.wallClock },
                                  uptime: { executor.uptime }, timeZone: { executor.timeZone })
            let queue = DispatchQueue(label: "desk.preview.test.clock.images")
            var suspended = false
            defer { if suspended { queue.resume() } }
            let source = #"widget { Row(spacing: 4) { Image("A.png").size(48, 40); Text("{time.now, format: "HH:mm:ss"}").font(20).size(180, 40) } }"#
            let data = try imageData(), nextData = try imageData(alternate: true)
            let f = try imageFixture(t, source, images: ["A.png": data, "B.png": nextData], queue: queue,
                                     clock: clock, executor: executor, locale: { locale }), p = f.preview
            p.setVisible(true)
            t.check(imageSettled(f)); t.equal(p.state, .ready); t.equal(executor.pendingCount, 1)
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            func path() throws -> String {
                guard let image = p.scene?.drawingItems.compactMap({ if case .image(let draw) = $0 { return draw.path }; return nil }).first else { throw Failure.fixture }
                return image
            }
            let firstPath = try path(), old = checking.snapshot
            t.equal(try Data(contentsOf: URL(fileURLWithPath: firstPath)), data)
            let before = try paint(p.canvas); try canaries(t, before); t.check(try ink(before) > 0)
            executor.advance(until: 0.75)
            t.equal(clockTexts(p), ["09:01:00"]); t.equal(try path(), firstPath)
            let after = try paint(p.canvas); try canaries(t, after)
            t.check(try bytes(before) != bytes(after), "the clock redraws while retaining the actual prepared image generation")
            queue.suspend(); suspended = true
            replace(source.replacingOccurrences(of: "A.png", with: "B.png"), in: f)
            t.check(p.scene == nil && p.state == .checking); t.equal(executor.pendingCount, 0)
            t.check(!FileManager.default.fileExists(atPath: firstPath)); t.check(!checking.publish(old))
            queue.resume(); suspended = false
            t.check(imageSettled(f)); t.equal(p.state, .ready); t.equal(executor.pendingCount, 1)
            let nextPath = try path(); t.equal(try Data(contentsOf: URL(fileURLWithPath: nextPath)), nextData)
            invalidDate = true; p.refreshDateInput()
            t.check(p.scene == nil && p.canvas.isHidden); t.equal(executor.pendingCount, 0)
            p.canvas.setBoundsSize(NSSize(width: 8, height: 8))
            let clear = try paint(p.canvas); try canaries(t, clear); t.equal(try ink(clear), 0)
            invalidDate = false; p.refreshDateInput()
            t.equal(p.state, .ready); t.equal(try path(), nextPath); t.equal(executor.pendingCount, 1)
            try Data([0xFF, 0xFE, 0x00, 0x00]).write(to: f.file)
            f.editor.discardUncommittedChanges()
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            t.check(f.controller.readError != nil && p.scene == nil && p.canvas.isHidden)
            t.equal(executor.pendingCount, 0)
            f.controller.window?.close(); executor.advance(by: 2)
            t.equal(p.state, .closed); t.equal(executor.pendingCount, 0)
            t.check(!FileManager.default.fileExists(atPath: nextPath))
        }

        t.suite("Desk: program preview: system data samples cpu and memory on independent boundaries") {
            let start = Date(timeIntervalSince1970: 1_790_586_000.25)
            let utc = TimeZone(identifier: "UTC")!
            let executor = VirtualTimeExecutor(start: start, timeZone: utc)
            let clock = SkinClock(now: { executor.wallClock }, uptime: { executor.uptime }, timeZone: { executor.timeZone })
            let system = PreviewCountingSystem()

            // 1. Mixed CPU 1s and Memory 2s cadence: real text and boundary assertions
            let mixedSource = #"widget { Text("{cpu.usage}% {memory.used, unit: .gib}").font(20).padding(8) }"#
            let f = try fixture(t, mixedSource, clock: clock, executor: executor, system: system)
            let p = f.preview
            p.setVisible(true)
            t.check(settled(f))
            t.equal(p.state, .ready)
            t.equal(clockTexts(p), ["42% 16.0 GiB"])
            t.equal(system.cpuCalls, 1)
            t.equal(system.memCalls, 1)

            // Advance by 0.75s to reach 1.0s wall-clock boundary: CPU re-sampled (1s), memory NOT (needs 2s)
            executor.advance(until: 0.75)
            t.equal(system.cpuCalls, 2, "CPU sampled at 1s boundary")
            t.equal(system.memCalls, 1, "Memory not re-sampled before 2s boundary")

            // Advance by 1.0s to reach 2.0s wall-clock boundary: CPU and Memory both re-sampled
            executor.advance(until: 1.75)
            t.equal(system.cpuCalls, 3)
            t.equal(system.memCalls, 2, "Memory sampled at 2s boundary")

            // 2. Pure static text with cpu.coreCount: sampled once, 0 subsequent reads
            let staticSource = #"widget { Text("Cores: {cpu.coreCount}").font(20).padding(8) }"#
            replace(staticSource, in: f)
            t.check(settled(f))
            t.equal(p.state, .ready)
            t.equal(clockTexts(p), ["Cores: 8"])
            let cpuBefore = system.cpuCalls, memBefore = system.memCalls
            executor.advance(by: 5.0)
            t.equal(system.cpuCalls, cpuBefore, "pure static widget does not read CPU")
            t.equal(system.memCalls, memBefore, "pure static widget does not read memory")

            // 3. Power change notification while hidden: cache invalidated but not sampled until restore/wake
            let batSource = #"widget { Text(battery.charging ? "Charging" : "Discharging").font(20).padding(8) }"#
            replace(batSource, in: f)
            t.check(settled(f))
            t.equal(p.state, .ready)
            t.equal(clockTexts(p), ["Charging"])
            let batBefore = system.batteryCalls
            t.check(batBefore >= 1)

            // Hide the preview
            p.setVisible(false)
            system.batteryCharging = false

            // Notify power change while hidden (posting notification exercises the real observer in CodeFileWindowController)
            NotificationCenter.default.post(name: .desksetPowerSourceDidChange, object: nil)
            t.equal(system.batteryCalls, batBefore, "hidden preview invalidates power cache without sampling hardware")

            // Restore visibility: fresh battery status is immediately sampled
            p.setVisible(true)
            t.equal(system.batteryCalls, batBefore + 1, "restored preview samples fresh battery status")
            t.equal(clockTexts(p), ["Discharging"])

            // System wake notification also refreshes
            system.batteryCharging = true
            p.notifySystemWake()
            t.equal(system.batteryCalls, batBefore + 2, "wake samples fresh battery status")
            t.equal(clockTexts(p), ["Charging"])

            // 4. Close preview cancels timers and produces no further reads
            replace(mixedSource, in: f)
            t.check(settled(f))
            t.equal(p.state, .ready)
            t.equal(executor.pendingCount, 1, "mixed system data has a live timer before close")
            f.editor.discardUncommittedChanges()
            f.controller.window?.close()
            t.equal(p.state, .closed)
            t.equal(executor.pendingCount, 0, "closing cancels the live system-data timer")
            let cpuClosed = system.cpuCalls, memClosed = system.memCalls, batClosed = system.batteryCalls
            executor.advance(by: 10.0)
            t.equal(system.cpuCalls, cpuClosed, "closed preview does not sample CPU")
            t.equal(system.memCalls, memClosed, "closed preview does not sample memory")
            t.equal(system.batteryCalls, batClosed, "closed preview does not sample battery")
            t.equal(executor.pendingCount, 0, "closed preview does not reschedule a system-data timer")
        }
    }

    private static func clockTexts(_ preview: DeskProgramPreviewController) -> [String] {
        preview.scene?.drawingItems.compactMap { if case .text(let value) = $0 { return value.text }; return nil } ?? []
    }

    /// Independent literal TextDraw, with fixed point font, frame and padding rather than copied runtime values.
    private static func clockPixels(_ t: AppTestRunner, _ text: String, in f: Fixture) throws {
        let p = f.preview, appearance = MacAppearance.values(for: p.canvas.effectiveAppearance)
        var style = TextStyle()
        style.fontFace = "System"; style.fontSize = 15; style.fontWeight = 400
        style.color = appearance.accentColor; style.horizontalAlign = .center; style.verticalAlign = .center
        style.accurateText = true; style.antiAlias = true; style.trailingSpaces = true
        let item = DrawItem.text(TextDraw(text: text, style: style, frame: SkinRect(width: 280, height: 60),
                                         contentFrame: SkinRect(x: 8, y: 8, width: 264, height: 44), anchor: SkinPoint()))
        t.equal(p.state, .ready); t.equal(p.scene?.drawingItems, [item])
        let reference = ReferenceView(items: [item], size: NSSize(width: 280, height: 60))
        reference.appearance = p.canvas.effectiveAppearance
        let blank = ReferenceView(items: [], size: reference.frame.size)
        for scale in [1, 2] {
            let actual = try paint(p.canvas, scale: scale), expected = try paint(reference, scale: scale)
            try canaries(t, actual); try canaries(t, expected)
            t.check(try ink(actual) > 0)
            t.equal(try ink(paint(blank, scale: scale)), 0)
            t.equal(try bytes(actual), try bytes(expected), "literal native date text at \(scale)x")
        }
    }

    /// Independent native geometry API, not the shared Program lowering or ShapeGeometryBuilder.
    private static func imageSettled(_ f: Fixture) -> Bool {
        AppSelfTest.spin(timeout: 10) {
            guard let checking = f.controller.deskChecking, checking.snapshot.isChecked, checking.isCurrent(checking.snapshot) else { return false }
            if case .pending = checking.imageResources(for: checking.snapshot) { return false }
            return true
        }
    }

    private static func imageFixture(_ t: AppTestRunner, _ text: String, images: [String: Data],
                                     queue: DispatchQueue = DispatchQueue(label: "desk.preview.test.image.files"),
                                     clock: SkinClock = .live, executor: SkinExecutor = MainSkinExecutor.shared,
                                     locale: @escaping () -> Locale = DeskProgramPreviewController.currentDateLocale) throws -> Fixture {
        queue.suspend()
        defer { queue.resume() }
        let f = try fixture(t, text, queue: queue, clock: clock, executor: executor, locale: locale)
        for (path, data) in images {
            let file = f.file.deletingLastPathComponent().appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        return f
    }

    /// An original nonsquare image, with distinct literal quadrants and premultiplied partial alpha. Encoding is
    /// native ImageIO; the independent view decodes these original bytes, never a production renderer result.
    private static func imageData(jpeg: Bool = false, orientation: Int = 1, alternate: Bool = false,
                                  width: Int = 20, height: Int = 12) throws -> Data {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let rgba: [UInt8]
                if alternate { rgba = x < width / 2 ? [24, 56, 232, 255] : [240, 176, 16, 255] }
                else if y < height / 2 { rgba = x < width / 2 ? [224, 40, 60, 255] : (jpeg ? [20, 208, 80, 255] : [10, 104, 40, 128]) }
                else { rgba = x < width / 2 ? [16, 72, 224, 255] : [232, 192, 32, 255] }
                pixels.append(contentsOf: rgba)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.fixture }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { throw Failure.fixture }
        CGImageDestinationAddImage(encoder, image, [kCGImagePropertyOrientation: orientation,
                                                   kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw Failure.fixture }
        return output as Data
    }

    private static func decodedFixture(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.fixture }
        return image
    }

    private static func thumbnailFixture(_ data: Data, side: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw Failure.fixture }
        return image
    }

    private static func largeOrientedFixture() throws -> Data {
        guard let context = CGContext(data: nil, width: 4500, height: 4500, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.fixture }
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2250, height: 4500))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 2250, y: 0, width: 2250, height: 4500))
        let output = NSMutableData()
        guard let image = context.makeImage(), let encoder = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.fixture }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: 2, kCGImageDestinationLossyCompressionQuality: 1.0]
        CGImageDestinationAddImage(encoder, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw Failure.fixture }
        return output as Data
    }

    private static func mirrorFixture(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.fixture }
        context.translateBy(x: CGFloat(image.width), y: 0); context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw Failure.fixture }
        return result
    }

    private final class NaturalImageReferenceView: NSView {
        let image: CGImage, target: CGRect, tile: CGSize?
        override var isFlipped: Bool { true }
        init(image: CGImage, target: CGRect = CGRect(x: 4, y: 4, width: 40, height: 32), tile: CGSize? = nil) {
            self.image = image; self.target = target; self.tile = tile
            super.init(frame: NSRect(x: 0, y: 0, width: 48, height: 40))
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState(); defer { context.restoreGState() }
            context.clip(to: CGRect(x: 4, y: 4, width: 40, height: 32)); context.interpolationQuality = .high
            if let tile {
                context.translateBy(x: 4, y: 4); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: -tile.height, width: tile.width, height: tile.height), byTiling: true)
            } else {
                context.translateBy(x: target.minX, y: target.maxY); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: target.size))
            }
        }
    }

    private static func rotateFixtureClockwise(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.fixture }
        context.translateBy(x: 0, y: CGFloat(image.width))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw Failure.fixture }
        return result
    }

    private final class ImageReferenceView: NSView {
        let image: CGImage
        let mode: String
        override var isFlipped: Bool { true }
        init(image: CGImage, mode: String, size: NSSize) {
            self.image = image; self.mode = mode
            super.init(frame: NSRect(origin: .zero, size: size))
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            defer { context.restoreGState() }
            let box = CGRect(x: 4, y: 4, width: bounds.width - 8, height: bounds.height - 8)
            context.clip(to: box)
            context.interpolationQuality = .high
            if mode == "tile" {
                context.translateBy(x: 4, y: 4)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: -12, width: 20, height: 12), byTiling: true)
                return
            }
            // Literal expected placement of the 20x12 source inside the 40x32 content box. The natural JPEG
            // reference has already independently undone its orientation and uses its own 12x20 dimensions.
            let target: CGRect
            switch mode {
            case "fit": target = CGRect(x: 4, y: 8, width: 40, height: 24)
            case "fill": target = CGRect(x: 4 + (40 - 20 * (32.0 / 12.0)) / 2, y: 4, width: 20 * (32.0 / 12.0), height: 32)
            case "natural": target = CGRect(x: 4, y: 4, width: image.width, height: image.height)
            default: target = box
            }
            context.translateBy(x: target.minX, y: target.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: target.size))
        }
    }

    private static func curvePath(_ name: String, in rect: CGRect) throws -> CGPath {
        switch name {
        case "Circle":
            let side = min(rect.width, rect.height)
            return CGPath(ellipseIn: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side), transform: nil)
        case "Ellipse": return CGPath(ellipseIn: rect, transform: nil)
        case "Capsule":
            let radius = min(rect.width, rect.height) / 2
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        default: throw Failure.fixture
        }
    }

    private static func styledPath(_ name: String, in rect: CGRect, radius: CGFloat) throws -> CGPath {
        if name == "Rectangle" {
            return radius == 0 ? CGPath(rect: rect, transform: nil)
                : CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        return try curvePath(name, in: rect)
    }

    /// Native solid-path oracle: no Program geometry, ShapeStroker, ShapeDraw or DrawExecutor is reused.
    private final class StyledReferenceView: NSView {
        let path: CGPath, fill: RGBA, stroke: RGBA, width: CGFloat
        override var isFlipped: Bool { true }
        init(path: CGPath, fill: RGBA, stroke: RGBA, width: CGFloat, viewport: CGRect) {
            self.path = path; self.fill = fill; self.stroke = stroke; self.width = width
            super.init(frame: NSRect(origin: .zero, size: viewport.size))
            bounds = viewport
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState(); defer { context.restoreGState() }
            context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
            func paint(_ path: CGPath, _ color: RGBA) {
                guard color.a > 0 else { return }
                context.addPath(path)
                context.setFillColor(CGColor(srgbRed: color.r / 255, green: color.g / 255, blue: color.b / 255, alpha: color.a / 255))
                context.fillPath(using: .winding)
            }
            paint(path, fill)
            if width > 0 { paint(path.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10), stroke) }
        }
    }

    private final class CurveReferenceView: NSView {
        let recipes: [(CGPath, RGBA)]
        override var isFlipped: Bool { true }
        init(recipes: [(CGPath, RGBA)], size: NSSize) {
            self.recipes = recipes
            super.init(frame: NSRect(origin: .zero, size: size))
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func draw(_ dirtyRect: NSRect) {
            guard let destination = NSGraphicsContext.current?.cgContext else { return }
            destination.saveGState()
            defer { destination.restoreGState() }
            destination.setAllowsAntialiasing(true)
            destination.setShouldAntialias(true)
            for (path, color) in recipes {
                destination.addPath(path)
                destination.setFillColor(CGColor(srgbRed: color.r / 255, green: color.g / 255, blue: color.b / 255, alpha: color.a / 255))
                destination.fillPath(using: .winding)
            }
        }
    }

    private final class PreviewCountingSystem: SystemDataSource {
        var cpu: Double = 42.0
        var cpuCalls: Int = 0
        var memCalls: Int = 0
        var batteryCalls: Int = 0
        var procCalls: Int = 0
        var batteryCharging: Bool = true
        var processorCount: Int { procCalls += 1; return 8 }

        func cpuUsage(processor: Int) -> Double { cpuCalls += 1; return cpu }
        func memoryStatus() -> MemoryStatus {
            memCalls += 1
            return MemoryStatus(physicalTotal: 32 * 1024 * 1024 * 1024, physicalUsed: 16 * 1024 * 1024 * 1024)
        }
        func networkInterfaces() -> [String] { [] }
        func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters() }
        func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
        func availableDiskSpace(path: String) -> Double? { nil }
        func uptime() -> TimeInterval { 120 }
        func battery() -> BatteryStatus? {
            batteryCalls += 1
            return BatteryStatus(percent: 90, isCharging: batteryCharging, isPluggedIn: true)
        }
        func isProcessRunning(_ name: String) -> Bool { false }
        func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
        func bestNetworkInterface() -> String? { nil }
        func volumeInfo(path: String) -> VolumeInfo? { nil }
        func cpuFrequency() -> Double? { nil }
        func desktopPicturePath() -> String? { nil }
        func graphicsAdapterName() -> String? { nil }
    }

    private final class ReferenceView: NSView {
        let items: [DrawItem]
        let glass: GlassPaint
        let context = DrawContext(fonts: AppFontResolver())
        override var isFlipped: Bool { true }
        init(items: [DrawItem], size: NSSize, glass: GlassPaint = .none) {
            self.items = items
            self.glass = glass
            super.init(frame: NSRect(origin: .zero, size: size))
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func draw(_ dirtyRect: NSRect) {
            guard let destination = NSGraphicsContext.current?.cgContext else { return }
            DesksetDraw.DrawExecutor.draw(items, in: destination, context: context, cycle: 1,
                                         target: DrawTarget.capture(destination, glass: glass))
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

    /// Outlines can live wholly in the image border. Exclude only the two literal 2×2 device-row canaries,
    /// rather than the full border used by the older interior-fill fixtures.
    private static func outlineInk(_ rep: NSBitmapImageRep) throws -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if (x < 2 && y < 2) || (x >= rep.pixelsWide - 2 && y >= rep.pixelsHigh - 2) { continue }
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
