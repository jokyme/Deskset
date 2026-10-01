import AppKit
import DeskLanguage
import DesksetCore

/// Actual standalone windows and native TextKit/bitmap consumers, with explicit independent range controls.
/// All document I/O is private test scratch; diagnostic note locations are metadata, not file permissions.
enum DeskCodePresentationSelfTests {
    static func run(_ t: AppTestRunner) {
        consumerTests(t)
        rangeTests(t)
        anchorTests(t)
        resizeTests(t)
        lifecycleTests(t)
    }

    private static let missingFont = "Deskset Missing Presentation F9F89B"
    private static let originalText = "\u{FEFF}info { name: \"展示😀\" }\r\nwidget { Column {\r\n  Text(\"中文😀\").colr(.red).font(\"Deskset Missing Presentation F9F89B\", 13)\r\n  Text(\"B\").name(\"Repeated Name\")\r\n  Text(\"C\").name(\"Repeated Name\")\r\n} }\r\n"
    private static let rangeText = "甲😀 first\r\n二😀 second\r\n尾"

    private struct Fixture {
        let app: AppController
        let file: URL
        let controller: CodeFileWindowController
        var editor: CodeEditorView { controller.codeView }
    }

    private static func fixture(_ t: AppTestRunner, text: String,
                                queue: DispatchQueue = DispatchQueue(label: "desk.presentation.test.check")) throws -> Fixture {
        let root = t.temporaryDirectory("desk-presentation")
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: root.appendingPathComponent("Skins"),
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false)
        let file = root.appendingPathComponent("Widget.desk")
        try Data(text.utf8).write(to: file)
        let controller = try CodeFileWindowController(file: file, app: app, deskCheckQueue: queue)
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.codeView.idleCommitDelay = 600
        controller.codeView.typedTextDelay = 600
        controller.codeView.layoutSubtreeIfNeeded()
        t.atSuiteEnd {
            controller.deskChecking?.close()
            controller.codeView.onCommit = { _, _ in false }
            controller.codeView.onDiskConflict = { _ in .decideLater }
            controller.codeView.discardUncommittedChanges()
            controller.window?.close()
            _ = app.stopAllForTermination()
            app.endEngineThread()
        }
        return Fixture(app: app, file: file, controller: controller)
    }

    private static func type(_ text: String, replacing range: NSRange, in editor: CodeEditorView) {
        editor.textView.setSelectedRange(range)
        editor.textView.insertText(text, replacementRange: range)
    }

    private static func settled(_ f: Fixture) -> Bool {
        AppSelfTest.spin(timeout: 10) {
            guard let snapshot = f.controller.deskChecking?.snapshot else { return false }
            return snapshot.isChecked && snapshot.version == f.editor.textRevision
                && snapshot.text.utf8.elementsEqual(f.editor.text.utf8)
        }
    }

    private enum PaintFailure: Error { case emptyView, bitmap, pixel }

    /// Follows UISnapshot's native bitmap/cacheDisplay path for cards. The overlay paints in bitmap device rows,
    /// addressed like the TextKit view coordinates; independent CG color canaries verify that row contract.
    /// An ancestor's background/text cannot stand in for an omitted underline. This is not a window-compositor capture.
    private static func paint(_ view: NSView, children: Bool = false) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 4, bounds.height > 4, bounds.width <= 2048, bounds.height <= 2048 else {
            throw PaintFailure.emptyView
        }
        let width = Int(ceil(bounds.width)), height = Int(ceil(bounds.height))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bytes = rep.bitmapData, let context = NSGraphicsContext(bitmapImageRep: rep) else { throw PaintFailure.bitmap }
        rep.size = bounds.size
        bytes.initialize(repeating: 0, count: rep.bytesPerRow * height)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            if children { view.cacheDisplay(in: bounds, to: rep) }
            else {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.saveGState()
                context.cgContext.concatenate(context.cgContext.userSpaceToDeviceSpaceTransform.inverted())
                context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                view.draw(bounds)
                context.cgContext.restoreGState()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        // Independent native color/address canaries outside every text/gutter test region, after the view painted.
        context.cgContext.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.cgContext.fill(context.cgContext.convertToUserSpace(CGRect(x: 0, y: 0, width: 2, height: 2)))
        context.cgContext.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.cgContext.fill(context.cgContext.convertToUserSpace(CGRect(x: width - 2, y: height - 2, width: 2, height: 2)))
        return rep
    }

    private static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw PaintFailure.pixel }
        return color
    }

    private static func canaries(_ t: AppTestRunner, _ rep: NSBitmapImageRep) throws {
        let red = try pixel(rep, 0, 0), blue = try pixel(rep, rep.pixelsWide - 1, rep.pixelsHigh - 1)
        t.check(red.redComponent > 0.99 && red.greenComponent < 0.01 && red.blueComponent < 0.01 && red.alphaComponent > 0.99,
                "the native bitmap's first corner is opaque red")
        t.check(blue.blueComponent > 0.99 && blue.redComponent < 0.01 && blue.greenComponent < 0.01 && blue.alphaComponent > 0.99,
                "the opposite address/row corner is opaque blue")
    }

    private static func ink(_ rep: NSBitmapImageRep, in rect: NSRect) throws -> Int {
        let x0 = max(2, Int(floor(rect.minX))), x1 = min(rep.pixelsWide - 2, Int(ceil(rect.maxX)))
        let y0 = max(2, Int(floor(rect.minY))), y1 = min(rep.pixelsHigh - 2, Int(ceil(rect.maxY)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var count = 0
        for y in y0..<y1 { for x in x0..<x1 { if try pixel(rep, x, y).alphaComponent > 0 { count += 1 } } }
        return count
    }

    private static func differences(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: NSRect) throws -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { throw PaintFailure.bitmap }
        let x0 = max(2, Int(floor(rect.minX))), x1 = min(a.pixelsWide - 2, Int(ceil(rect.maxX)))
        let y0 = max(2, Int(floor(rect.minY))), y1 = min(a.pixelsHigh - 2, Int(ceil(rect.maxY)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var count = 0
        for y in y0..<y1 { for x in x0..<x1 {
            let p = try pixel(a, x, y), q = try pixel(b, x, y)
            if p.redComponent != q.redComponent || p.greenComponent != q.greenComponent
                || p.blueComponent != q.blueComponent || p.alphaComponent != q.alphaComponent { count += 1 }
        } }
        return count
    }

    /// The literal fixture range is [1,24), across three native glyph fragments. These are backend line baselines,
    /// not rectangles or counters supplied by the production decoration owner.
    private static func fragmentRegions(_ f: Fixture, overlay: NSView) -> [NSRect] {
        guard let lm = f.editor.textView.layoutManager else { return [] }
        let tv = f.editor.textView
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: 1, length: 23), actualCharacterRange: nil)
        var regions: [NSRect] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, fragmentGlyphs, _ in
            let part = NSIntersectionRange(glyphs, fragmentGlyphs)
            guard part.length > 0 else { return }
            let bounds = lm.boundingRect(forGlyphRange: part, in: container)
            let baseline = fragment.minY + lm.location(forGlyphAt: part.location).y
            let region = NSRect(x: bounds.minX + tv.textContainerOrigin.x,
                                y: baseline + tv.textContainerOrigin.y + 1, width: max(6, bounds.width), height: 6)
            regions.append(overlay.convert(region, from: tv))
        }
        return regions
    }

    private static func consumerTests(_ t: AppTestRunner) {
        t.suite("Desk: code presentation: the actual checker supplies stacked messages and notes without document writes") {
            t.check(Fonts.installedFamily(named: missingFont) == nil, "the original font negative control is absent")
            let f = try fixture(t, text: originalText)
            guard let checking = f.controller.deskChecking, let decorations = f.controller.deskDecorations,
                  let typo = checking.snapshot.diagnostics.first(where: { $0.id == .unknownModifier }),
                  let font = checking.snapshot.diagnostics.first(where: { $0.id == .fontNotInstalled }),
                  let duplicate = checking.snapshot.diagnostics.first(where: { $0.id == .duplicateElementName }) else {
                return t.check(false, "the real checker did not supply the typo and duplicate-name note")
            }
            t.equal(typo.range.nsRange, NSRange(location: 58, length: 4), "independent UTF16 offset includes BOM/CJK/emoji/CRLF")
            t.equal(font.line, typo.line, "the actual platform font error shares the original typo's physical line")
            t.check(!duplicate.notes.isEmpty && duplicate.notes.allSatisfy { !$0.message.isEmpty && $0.location?.file == checking.fileID })
            t.equal(decorations.items, checking.snapshot.diagnostics, "all diagnostics reach the actual document consumer")
            t.equal(decorations.cards.count, checking.snapshot.diagnostics.count)
            t.check(decorations.cards.allSatisfy { !$0.isHidden && f.editor.textView.bounds.contains($0.frame) },
                    "every complete-check card is inside its actual scrollable text view")
            let sameLine = decorations.cards.filter { $0.diagnostic.line == typo.line }
            t.check(sameLine.count >= 2, "both actual errors on one line have cards")
            for (first, second) in zip(sameLine, sameLine.dropFirst()) {
                t.check(first.frame.maxY <= second.frame.minY && !first.isHidden && !second.isHidden,
                        "the real TextKit stack gives each same-line diagnostic visible nonoverlapping space")
            }
            t.equal(typo.line, 2, "the independent typo is on the third physical CRLF line")
            guard f.editor.lineStarts.count > 3 else { return t.check(false, "the original fixture has its next native line") }
            let nextStart = f.editor.lineStarts[3]
            guard let nextBand = f.editor.textView.lineRect(forCharacterRange: NSRange(location: nextStart, length: 1)),
                  let lastSameLine = sameLine.last else { return t.check(false, "the following native text line and full card stack exist") }
            t.check(lastSameLine.frame.maxY <= nextBand.minY, "CRLF reserves the full stack before the next native text line")
            guard let card = decorations.cards.first(where: { $0.diagnostic.id == .duplicateElementName }) else {
                return t.check(false, "the actual note card is missing")
            }
            let painted = try paint(card, children: true)
            try canaries(t, painted)
            let labels = [card.messageLabel] + card.noteLabels
            let messages = labels.map { $0.stringValue }
            let labelFrames = labels.map { $0.frame }
            labels.forEach { $0.stringValue = ""; $0.needsDisplay = true }
            card.needsDisplay = true
            let blankLabels = try paint(card, children: true)
            for frame in labelFrames {
                t.check(try differences(painted, blankLabels, in: frame) > 0,
                        "the native message/note glyphs differ from the real empty-label negative control")
            }
            for (label, message) in zip(labels, messages) { label.stringValue = message }
            t.equal(f.editor.document(for: f.file)?.data, Data(originalText.utf8), "display keeps BOM/CRLF bytes")
            t.equal(try Data(contentsOf: f.file), Data(originalText.utf8))
            t.equal(f.app.sortedControllers.count, 0, "no Desk activation or widget reload")
        }
    }

    private static func rangeTests(_ t: AppTestRunner) {
        t.suite("Desk: code presentation: complete UTF16 ranges paint every native fragment and keep tips quiet") {
            let f = try fixture(t, text: rangeText)
            guard let decorations = f.controller.deskDecorations, let checking = f.controller.deskChecking else {
                return t.check(false, "an actual document owns its Desk decoration owner")
            }
            let file = checking.fileID
            let whole = DeskRange(start: DeskPosition(offset: 1, line: 0, column: 1),
                                  end: DeskPosition(offset: 24, line: 2, column: 1))
            let first = DeskRange(start: DeskPosition(offset: 0, line: 0, column: 0),
                                  end: DeskPosition(offset: 1, line: 0, column: 1))
            let sibling = f.file.deletingLastPathComponent().appendingPathComponent("Other.desk")
            try Data([0xC3]).write(to: sibling)
            let note = DeskServiceNote(location: DeskLocation(file: DeskFileID("Other.desk"),
                range: DeskRange(start: DeskPosition(offset: 13, line: 2, column: 1), end: DeskPosition(offset: 14, line: 2, column: 2))),
                message: "Do not open this sibling.")
            let diagnostics = [DeskServiceDiagnostic(id: .unknownModifier, severity: .error, file: file, range: whole,
                                                      message: "Across three lines — 中文😀", notes: [note]),
                               DeskServiceDiagnostic(id: .unusedStyle, severity: .warning, file: file, range: first,
                                                      message: "Original warning control"),
                               DeskServiceDiagnostic(id: .tooManyProblems, severity: .info, file: file, range: first,
                                                      message: "Original tip control")]
            t.equal(rangeText.utf16.count, 24)
            t.check(decorations.show(diagnostics, file: file, text: rangeText, language: .english))
            t.equal(decorations.cards.count, 3, "the same physical line keeps error, warning and tip")
            t.equal(decorations.items.filter { $0.isProblem }.count, 2, "the tip is excluded from problems")
            t.equal(decorations.cards.last?.titleLabel.stringValue, "DK2030 · Tip")
            t.equal(decorations.cards.first?.noteLabels.first?.stringValue, "Other.desk:3:2\nDo not open this sibling.")
            let regions = fragmentRegions(f, overlay: decorations.overlay)
            t.equal(regions.count, 3, "the hand range covers exactly three native line fragments")
            let painted = try paint(decorations.overlay)
            try canaries(t, painted)
            for (line, region) in regions.enumerated() {
                t.check(try ink(painted, in: region) > 0, "the full-range underline actually paints native fragment \(line + 1)")
            }
            decorations.clear()
            let absent = try paint(decorations.overlay)
            try canaries(t, absent)
            for region in regions { t.equal(try ink(absent, in: region), 0, "the omitted-decoration negative paints no underline") }
            var invalid = diagnostics[0]
            invalid.range.end.offset = 2 // Between the two UTF16 halves of the first emoji, not a legal scalar boundary.
            t.check(!decorations.show([invalid], file: file, text: rangeText, language: .english))
            t.check(decorations.cards.isEmpty && decorations.items.isEmpty, "an invalid range is refused, not clamped")
            var reads: [URL] = []
            f.editor.readData = { url in reads.append(url); return try Data(contentsOf: url) }
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            t.check(!reads.isEmpty && reads.allSatisfy { $0 == f.file }, "note metadata never reads the sibling")
            t.equal(try Data(contentsOf: sibling), Data([0xC3]))
            t.equal(f.editor.files, [f.file])
            t.equal(try Data(contentsOf: f.file), Data(rangeText.utf8))
        }
    }

    private static func anchorTests(_ t: AppTestRunner) {
        t.suite("Desk: code presentation: zero length, EOF and empty documents keep native visible anchors") {
            for (text, offset, line, column) in [("", 0, 0, 0), ("A😀", 3, 0, 3), ("A😀\r\n", 5, 1, 0)] {
                let f = try fixture(t, text: text)
                guard let decorations = f.controller.deskDecorations, let checking = f.controller.deskChecking else {
                    return t.check(false, "the actual empty/EOF document has a checker and presentation owner")
                }
                if text.isEmpty {
                    t.check(decorations.items.contains { $0.id == .missingWidget }, "real empty UTF8 first displays DK2017")
                    t.check(decorations.cards.contains { !$0.isHidden && $0.frame.height > 0 }, "the actual empty-check card is visible")
                }
                let position = DeskPosition(offset: offset, line: line, column: column)
                let diagnostic = DeskServiceDiagnostic(id: .missingWidget, severity: .error, file: checking.fileID,
                                                       range: DeskRange(start: position, end: position), message: "Original zero/EOF anchor")
                t.check(decorations.show([diagnostic], file: checking.fileID, text: text, language: .english))
                guard let card = decorations.cards.first else { return t.check(false, "zero-length diagnostic card is absent") }
                t.check(!card.isHidden && f.editor.textView.bounds.contains(card.frame), "the native empty/EOF card fits its scrollable text view")
                let painted = try paint(decorations.overlay)
                try canaries(t, painted)
                let textArea = NSRect(x: 12, y: 2, width: decorations.overlay.bounds.width - 16,
                                      height: decorations.overlay.bounds.height - 4)
                t.check(try ink(painted, in: textArea) > 0, "a zero-length diagnostic paints a real native anchor beyond the gutter")
                decorations.clear()
                t.equal(try ink(paint(decorations.overlay), in: textArea), 0, "the corresponding omitted-anchor negative is empty")
                t.equal(f.editor.text, text)
                t.equal(try Data(contentsOf: f.file), Data(text.utf8))
                t.check(f.editor.textView.undoManager?.canUndo != true, "show/clear creates no typing undo")
            }
        }
    }

    private static func resizeTests(_ t: AppTestRunner) {
        t.suite("Desk: code presentation: actual window resizing reflows all read-only cards without changing INI decoration ownership") {
            let oldLanguage = StudioText.languageOverride
            defer { StudioText.languageOverride = oldLanguage }
            StudioText.languageOverride = .chinese
            let f = try fixture(t, text: originalText)
            guard let decorations = f.controller.deskDecorations, let window = f.controller.window else {
                return t.check(false, "a real document window and native layout owner")
            }
            let oldWidth = f.editor.textView.bounds.width
            let oldHeight = decorations.cards.reduce(CGFloat.zero) { $0 + $1.frame.height }
            window.setContentSize(NSSize(width: 360, height: 420))
            f.editor.layoutSubtreeIfNeeded()
            t.check(AppSelfTest.spin(timeout: 5) {
                f.editor.textView.bounds.width < oldWidth
                    && decorations.cards.allSatisfy { !$0.isHidden && $0.frame.width == f.editor.textView.bounds.width }
            }, "real frame notifications reflow the same diagnostic consumer")
            t.check(decorations.cards.reduce(CGFloat.zero) { $0 + $1.frame.height } >= oldHeight,
                    "narrower wrapped messages reserve at least the original stack height")
            for card in decorations.cards {
                card.layoutSubtreeIfNeeded()
                t.check(card.noteLabels.allSatisfy { card.cardRect.contains($0.frame) }, "all full note labels remain inside the native card")
            }
            guard let card = decorations.cards.first else { return t.check(false, "narrow card") }
            try canaries(t, paint(card, children: true))
            t.check(card.titleLabel.stringValue.contains("错误") || card.titleLabel.stringValue.contains("提醒"))
            t.equal(try Data(contentsOf: f.file), Data(originalText.utf8))
            // A separate legacy pane remains the original owner with its original delegate and INI fix API.
            let legacyView = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            let legacy = StudioCodeDecorations()
            legacy.attach(to: legacyView)
            t.check(legacyView.textView.layoutManager?.delegate === legacy)
            t.check(f.editor.textView.layoutManager?.delegate === decorations)
            t.check(legacy.onFix == nil && legacy.items.isEmpty)
        }
    }

    private static func lifecycleTests(_ t: AppTestRunner) {
        t.suite("Desk: code presentation: real pending checks and closing remove stale cards, ranges and observers") {
            let queue = DispatchQueue(label: "desk.presentation.test.pending")
            var suspended = false
            defer { if suspended { queue.resume() } }
            let text = originalText + "//" + String(repeating: "x", count: 9_000) + "\r\n"
            let f = try fixture(t, text: text, queue: queue)
            guard let checking = f.controller.deskChecking, let decorations = f.controller.deskDecorations else {
                return t.check(false, "actual checked document presentation")
            }
            t.check(!decorations.cards.isEmpty, "the finished original check has real cards")
            let old = checking.snapshot
            queue.suspend()
            suspended = true
            type("color", replacing: NSRange(location: 58, length: 4), in: f.editor)
            t.check(!checking.snapshot.isChecked, "the suspended real service publishes pending syntax")
            t.check(decorations.cards.isEmpty && decorations.items.isEmpty, "pending clears the old complete-check display")
            t.check(!checking.publish(old), "the old checked version cannot restore its cards")
            let empty = try paint(decorations.overlay)
            try canaries(t, empty)
            t.equal(try ink(empty, in: NSRect(x: 12, y: 2, width: empty.size.width - 16, height: empty.size.height - 4)), 0,
                    "no stale underline actually paints while the real check waits")
            queue.resume()
            suspended = false
            t.check(settled(f), "the real checker resumes and publishes its latest complete result")
            t.equal(decorations.items, checking.snapshot.diagnostics)
            t.check(!decorations.cards.isEmpty, "the remaining original errors reappear")
            queue.suspend()
            suspended = true
            type(" ", replacing: NSRange(location: 0, length: 0), in: f.editor)
            f.controller.window?.close()
            t.check(decorations.codeView == nil && decorations.overlay.superview == nil)
            t.check(decorations.cards.isEmpty && f.editor.textView.layoutManager?.delegate == nil,
                    "close removes every card and restores the original standalone layout delegate")
            queue.resume()
            suspended = false
            var drained = false
            queue.async { DispatchQueue.main.async { drained = true } }
            t.check(AppSelfTest.spin(timeout: 10) { drained }, "the original queued check and main publication drain")
            t.check(decorations.cards.isEmpty && !checking.publish(old), "closing never reattaches an old presentation")
            t.equal(try Data(contentsOf: f.file), Data(text.utf8), "display/checking never saves the dirty test buffer")
            t.equal(f.app.sortedControllers.count, 0)
        }
    }
}
