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
    }


    /// Independent native geometry API, not the shared Program lowering or ShapeGeometryBuilder.
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
