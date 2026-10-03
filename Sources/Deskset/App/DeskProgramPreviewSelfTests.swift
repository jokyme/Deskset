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
                                colors: @escaping (NSAppearance) throws -> MacAppearance.ProgramValues = MacAppearance.programValues(for:)) throws -> Fixture {
        let root = t.temporaryDirectory("desk-program-preview")
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: root.appendingPathComponent("Skins"),
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false)
        let file = root.appendingPathComponent("Preview." + ext)
        try Data(text.utf8).write(to: file)
        let controller = try CodeFileWindowController(file: file, app: app, deskCheckQueue: queue,
                                                       previewClock: clock, previewExecutor: executor, previewLocale: locale, previewColors: colors)
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

        runPalettePreviewTests(t)
        runNumericPreviewTests(t)
        runClockPreviewTests(t)
        runClickPreviewTests(t)
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
        if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
    }

    private static func click(at point: NSPoint, in f: Fixture) throws {
        try mouse(.leftMouseDown, at: point, in: f)
        try mouse(.leftMouseUp, at: point, in: f)
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
            let f = try fixture(t, text, locale: { Locale(identifier: "en_US") }), p = f.preview
            p.setVisible(true)
            try numericPixels(t, "😀1.0|No|No", ranges: [NSRange(location: 2, length: 3)], in: f)
            try click(at: NSPoint(x: 20, y: 20), in: f)
            try numericPixels(t, "😀空😀|Yes|Yes", ranges: [], in: f)
            try click(at: NSPoint(x: 20, y: 20), in: f)
            try numericPixels(t, "😀2.0|No|No", ranges: [NSRange(location: 2, length: 3)], in: f)
            guard let checking = f.controller.deskChecking else { throw Failure.fixture }
            let old = checking.snapshot
            for invalid in [#"widget { Text(1%) }"#, #"widget { Text(cpu.usage) }"#] {
                replace(invalid, in: f); t.check(settled(f))
                guard case .unavailable(let reason) = p.state else { return t.check(false, "dimensioned or service numeric data must report unsupported") }
                t.check(!reason.isEmpty && p.scene == nil && p.canvas.isHidden)
                t.check(!checking.publish(old))
                p.canvas.setBoundsSize(NSSize(width: 8, height: 8))
                let clear = try paint(p.canvas); try canaries(t, clear); t.equal(try ink(clear), 0)
            }
            replace(text, in: f); t.check(settled(f)); p.setVisible(true)
            try numericPixels(t, "😀1.0|No|No", ranges: [NSRange(location: 2, length: 3)], in: f)
            f.controller.window?.close()
            try click(at: NSPoint(x: 20, y: 20), in: f)
            t.check(p.scene == nil && p.state == .closed)
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
