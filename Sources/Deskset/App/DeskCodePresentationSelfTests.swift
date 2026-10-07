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
        interactionTests(t)
        dirtyClickTests(t)
        waveHoverTests(t)
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

    /// Opens the actual native content owner; the cards must belong to its scrollable document, never the text.
    @discardableResult
    private static func details(_ t: AppTestRunner, _ decorations: DeskCodeDecorations,
                                line: Int) -> [DeskDiagnosticCard] {
        t.check(decorations.showDetails(forLine: line), "the current gutter marker opens its diagnostic details")
        guard let content = decorations.detailsPanel?.contentView else {
            t.check(false, "the native details panel has no content view")
            return []
        }
        content.layoutSubtreeIfNeeded()
        let cards = decorations.cards.filter { $0.diagnostic.line + 1 == line }
        t.check(!cards.isEmpty && cards.allSatisfy { $0.isDescendant(of: content) && !$0.isHidden },
                "every same-line message is attached to the actual details document")
        return cards
    }

    private static func lineRects(_ editor: CodeEditorView) -> [NSRect?] {
        editor.lineStarts.map {
            editor.textView.lineRect(forCharacterRange: NSRange(location: $0, length: $0 < editor.text.utf16.count ? 1 : 0))
        }
    }

    private static func pointerEvent(_ type: NSEvent.EventType, view: NSView, point: NSPoint? = nil) -> NSEvent? {
        let windowPoint = view.convert(point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        if type == .mouseEntered || type == .mouseExited {
            return NSEvent.enterExitEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                                           windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                           eventNumber: 0, trackingNumber: 0, userData: nil)
        }
        return NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                                 windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                 eventNumber: 0, clickCount: 1, pressure: 1)
    }

    private static func keyEvent(_ code: UInt16, view: NSView) -> NSEvent? {
        let characters = code == 36 ? "\r" : code == 49 ? " " : "\u{1B}"
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: view.window?.windowNumber ?? 0, context: nil,
                               characters: characters, charactersIgnoringModifiers: characters,
                               isARepeat: false, keyCode: code)
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

    private static func inkPoint(_ rep: NSBitmapImageRep, in rect: NSRect) throws -> NSPoint? {
        let x0 = max(2, Int(floor(rect.minX))), x1 = min(rep.pixelsWide - 2, Int(ceil(rect.maxX)))
        let y0 = max(2, Int(floor(rect.minY))), y1 = min(rep.pixelsHigh - 2, Int(ceil(rect.maxY)))
        guard x1 > x0, y1 > y0 else { return nil }
        for y in y0..<y1 { for x in x0..<x1 {
            if try pixel(rep, x, y).alphaComponent > 0.1 { return NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5) }
        } }
        return nil
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
        nativeFragments(f, range: NSRange(location: 1, length: 23), overlay: overlay).map(\.probe)
    }

    /// Native line fragments and underline probes are independent of the decoration owner's hit regions.
    private static func nativeFragments(_ f: Fixture, range: NSRange, overlay: NSView) -> [(fragment: NSRect, probe: NSRect)] {
        guard let lm = f.editor.textView.layoutManager else { return [] }
        let tv = f.editor.textView
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var regions: [(fragment: NSRect, probe: NSRect)] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, fragmentGlyphs, _ in
            let part = NSIntersectionRange(glyphs, fragmentGlyphs)
            guard part.length > 0 else { return }
            let bounds = lm.boundingRect(forGlyphRange: part, in: container)
            let baseline = fragment.minY + lm.location(forGlyphAt: part.location).y
            let region = NSRect(x: bounds.minX + tv.textContainerOrigin.x,
                                y: baseline + tv.textContainerOrigin.y + 1, width: max(6, bounds.width), height: 6)
            regions.append((overlay.convert(fragment.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y), from: tv),
                            overlay.convert(region, from: tv)))
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
            t.check(decorations.cards.allSatisfy { !$0.isDescendant(of: f.editor.textView) },
                    "diagnostic content never occupies the editable text view")
            let originalDiagnostics = checking.snapshot.diagnostics
            decorations.clear()
            f.editor.layoutSubtreeIfNeeded()
            let originalFrame = f.editor.textView.frame, originalMinimum = f.editor.textView.minSize
            let originalLines = lineRects(f.editor)
            t.check(decorations.show(originalDiagnostics, file: checking.fileID, text: originalText, language: .english))
            t.equal(f.editor.textView.frame, originalFrame, "diagnostics reserve no extra document height")
            t.equal(f.editor.textView.minSize, originalMinimum, "diagnostics keep the native text minimum size")
            t.check(lineRects(f.editor) == originalLines, "all native text lines keep their undecorated positions")
            let sameLine = details(t, decorations, line: typo.line + 1)
            t.check(sameLine.count >= 2, "both actual errors on one line have cards")
            t.equal(sameLine.map(\.diagnostic), originalDiagnostics.filter { $0.line == typo.line },
                    "the single marker preserves all diagnostic order in its details panel")
            t.equal(decorations.markers.count, Set(originalDiagnostics.map { $0.line + 1 }).count)
            guard let marker = decorations.markers[typo.line + 1] else { return t.check(false, "the original error marker") }
            t.equal(marker.severity, .error, "the shared physical-line marker uses the highest severity")
            let markerInRuler = f.editor.ruler.convert(marker.bounds, from: marker)
            t.check(markerInRuler.minX >= 0 && markerInRuler.maxX <= f.editor.ruler.leadingAccessoryWidth,
                    "the icon occupies a separate column to the left of the line number")
            for (first, second) in zip(sameLine, sameLine.dropFirst()) {
                t.check(first.frame.maxY <= second.frame.minY && !first.isHidden && !second.isHidden,
                        "same-line messages have nonoverlapping native details panel frames")
            }
            t.equal(typo.line, 2, "the independent typo is on the third physical CRLF line")
            guard f.editor.lineStarts.count > 3 else { return t.check(false, "the original fixture has its next native line") }
            let duplicateCards = details(t, decorations, line: duplicate.line + 1)
            guard let card = duplicateCards.first(where: { $0.diagnostic.id == .duplicateElementName }) else {
                return t.check(false, "the actual note card is missing")
            }
            let painted = try paint(card, children: true)
            try canaries(t, painted)
            let neutralPoint = NSPoint(x: card.cardRect.maxX - 6, y: card.cardRect.midY)
            let neutralPixel = try pixel(painted, Int(neutralPoint.x), Int(neutralPoint.y))
            var neutralColor: NSColor?
            card.effectiveAppearance.performAsCurrentDrawingAppearance { neutralColor = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) }
            if let neutral = neutralColor {
                t.close(neutralPixel.redComponent, neutral.redComponent, accuracy: 0.01, "the diagnostic body has a neutral background")
                t.close(neutralPixel.greenComponent, neutral.greenComponent, accuracy: 0.01)
                t.close(neutralPixel.blueComponent, neutral.blueComponent, accuracy: 0.01)
            } else { t.check(false, "the native neutral background resolves in the bitmap color space") }
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
            t.equal(decorations.markers.count, 1, "one physical line has one severity marker")
            t.equal(decorations.markers[1]?.severity, .error)
            t.equal(details(t, decorations, line: 1).map(\.diagnostic), diagnostics, "all severities remain in original order")
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
                f.controller.window?.orderFront(nil)
                if text.isEmpty {
                    t.check(decorations.items.contains { $0.id == .missingWidget }, "real empty UTF8 first displays DK2017")
                    t.check(decorations.markers[1]?.isHidden == false, "the actual empty-check gutter marker is visible")
                }
                let position = DeskPosition(offset: offset, line: line, column: column)
                let diagnostic = DeskServiceDiagnostic(id: .missingWidget, severity: .error, file: checking.fileID,
                                                       range: DeskRange(start: position, end: position), message: "Original zero/EOF anchor")
                t.check(decorations.show([diagnostic], file: checking.fileID, text: text, language: .english))
                guard let marker = decorations.markers[line + 1], let card = details(t, decorations, line: line + 1).first else {
                    return t.check(false, "zero-length diagnostic marker and details card are absent")
                }
                t.check(!marker.isHidden && f.editor.ruler.bounds.contains(f.editor.ruler.convert(marker.bounds, from: marker)),
                        "the native empty/EOF marker fits its gutter")
                t.check(card.frame.height > 0 && card.enclosingScrollView != nil, "the complete EOF message is scrollable")
                let painted = try paint(decorations.overlay)
                try canaries(t, painted)
                let textArea = NSRect(x: 12, y: 2, width: decorations.overlay.bounds.width - 16,
                                      height: decorations.overlay.bounds.height - 4)
                t.check(try ink(painted, in: textArea) > 0, "a zero-length diagnostic paints a real native anchor beyond the gutter")
                decorations.overlay.updateTrackingAreas()
                guard let point = try inkPoint(painted, in: textArea),
                      let move = pointerEvent(.mouseMoved, view: decorations.overlay, point: point) else {
                    return t.check(false, "the painted native zero/EOF wave has a pointer probe")
                }
                decorations.overlay.mouseMoved(with: move)
                t.check(decorations.firePendingHoverForTesting(), "the actual painted zero/EOF wave opens details")
                t.equal(decorations.detailsLine, line + 1)
                t.check(decorations.detailsPanel?.isVisible == true && decorations.detailsAnchor != nil,
                        "zero and EOF diagnostics display the same visible arrowless details owner")
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
            guard let decorations = f.controller.deskDecorations, let checking = f.controller.deskChecking,
                  let window = f.controller.window else {
                return t.check(false, "a real document window and native layout owner")
            }
            let oldWidth = f.editor.textView.bounds.width
            t.check(!details(t, decorations, line: 3).isEmpty)
            window.setContentSize(NSSize(width: 360, height: 420))
            f.editor.layoutSubtreeIfNeeded()
            t.check(AppSelfTest.spin(timeout: 5) {
                f.editor.textView.bounds.width < oldWidth && decorations.detailsLine == nil
            }, "real frame notifications reflow the same diagnostic consumer")
            let diagnostics = decorations.items
            decorations.clear()
            let frame = f.editor.textView.frame, minimum = f.editor.textView.minSize
            let nativeLines = lineRects(f.editor)
            t.check(decorations.show(diagnostics, file: checking.fileID,
                                     text: originalText, language: .simplifiedChinese))
            t.equal(f.editor.textView.frame, frame, "the narrow document has no card-induced height")
            t.equal(f.editor.textView.minSize, minimum)
            t.check(lineRects(f.editor) == nativeLines, "resizing keeps the native text line layout")
            let visibleCards = details(t, decorations, line: 3)
            for card in visibleCards {
                card.layoutSubtreeIfNeeded()
                t.check(card.noteLabels.allSatisfy { card.cardRect.contains($0.frame) }, "all full note labels remain inside the native card")
            }
            guard let card = visibleCards.first else { return t.check(false, "narrow card") }
            try canaries(t, paint(card, children: true))
            t.check(card.titleLabel.stringValue.contains("错误") || card.titleLabel.stringValue.contains("提醒"))
            t.equal(try Data(contentsOf: f.file), Data(originalText.utf8))
            // A separate legacy pane remains the original owner with its original delegate and INI fix API.
            let legacyView = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            let legacy = StudioCodeDecorations()
            legacy.attach(to: legacyView)
            t.check(legacyView.textView.layoutManager?.delegate === legacy)
            t.check(f.editor.textView.layoutManager?.delegate == nil, "Desk leaves the standalone TextKit delegate in place")
            t.check(legacy.onFix == nil && legacy.items.isEmpty)

            // A distant three-digit line keeps its own gutter lane at both font sizes, with complete scrollable details.
            let longText = String(repeating: "// preceding line\n", count: 99) + "widget { Text(\"中文😀\") }\n"
            let distant = try fixture(t, text: longText)
            guard let longDecorations = distant.controller.deskDecorations,
                  let longChecking = distant.controller.deskChecking else { return t.check(false, "the distant native gutter") }
            let offset = distant.editor.lineStarts[99]
            let position = DeskPosition(offset: offset, line: 99, column: 0)
            let message = String(repeating: "完整说明😀 with wrapped details. ", count: 180)
            let note = "Last note — 中文😀 remains readable after scrolling."
            let diagnostic = DeskServiceDiagnostic(id: .unusedStyle, severity: .warning, file: longChecking.fileID,
                range: DeskRange(start: position, end: position), message: message,
                notes: [DeskServiceNote(location: nil, message: note)])
            t.check(longDecorations.show([diagnostic], file: longChecking.fileID, text: longText, language: .english))
            distant.editor.textView.scrollRangeToVisible(NSRange(location: offset, length: 1))
            longDecorations.layoutChanged()
            guard let marker = longDecorations.markers[100] else { return t.check(false, "line 100 has a gutter marker") }
            let beforeZoom = distant.editor.ruler.ruleThickness
            for size: CGFloat in [13, 22] {
                distant.editor.setFontSize(size)
                distant.editor.layoutSubtreeIfNeeded()
                distant.editor.textView.scrollRangeToVisible(NSRange(location: offset, length: 1))
                longDecorations.layoutChanged()
                let numberWidth = ("100" as NSString).size(withAttributes: [.font: distant.editor.ruler.font]).width
                let markerInRuler = distant.editor.ruler.convert(marker.bounds, from: marker)
                t.check(!marker.isHidden && markerInRuler.maxX <= distant.editor.ruler.bounds.width - 8 - numberWidth,
                        "the three-digit number never overlaps the diagnostic icon after zoom")
            }
            t.check(distant.editor.ruler.ruleThickness > beforeZoom, "the real ruler grows with the editor font")
            guard let longCard = details(t, longDecorations, line: 100).first,
                  let scroll = longCard.enclosingScrollView, let document = scroll.documentView else {
                return t.check(false, "long diagnostics have a native scrollable details document")
            }
            t.equal(longCard.messageLabel.stringValue, message)
            t.equal(longCard.noteLabels.last?.stringValue, note)
            t.check(document.bounds.height > scroll.contentView.bounds.height && scroll.hasVerticalScroller,
                    "long instructions scroll instead of being truncated")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            if let lastNote = longCard.noteLabels.last {
                t.check(scroll.contentView.bounds.intersects(scroll.contentView.convert(lastNote.frame, from: longCard)),
                        "scrolling the actual native document reveals its final note")
            }
            t.equal(try Data(contentsOf: distant.file), Data(longText.utf8))
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
            t.check(!decorations.cards.isEmpty && !decorations.markers.isEmpty, "the finished original check has gutter details")
            t.check(!details(t, decorations, line: 3).isEmpty)
            let old = checking.snapshot
            queue.suspend()
            suspended = true
            type("color", replacing: NSRange(location: 58, length: 4), in: f.editor)
            t.check(!checking.snapshot.isChecked, "the suspended real service publishes pending syntax")
            t.check(decorations.cards.isEmpty && decorations.items.isEmpty && decorations.markers.isEmpty
                        && decorations.detailsLine == nil, "pending clears markers and any open stale details")
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
            t.check(decorations.cards.isEmpty && decorations.markers.isEmpty && decorations.detailsLine == nil
                        && f.editor.textView.layoutManager?.delegate == nil,
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

    private static func interactionTests(_ t: AppTestRunner) {
        t.suite("Desk: code presentation: gutter hover, click and keyboard preserve editing focus and dismiss safely") {
            let text = "info { name: \"Gutter\" }\nwidget { Text(\"中文😀\").colr(.red) }\n"
                + String(repeating: "// scrollable document\n", count: 100)
            let f = try fixture(t, text: text)
            guard let decorations = f.controller.deskDecorations, let window = f.controller.window,
                  let marker = decorations.markers[2] else { return t.check(false, "the actual checked gutter marker") }
            window.makeKeyAndOrderFront(nil)
            t.equal(marker.line, 2)
            t.equal(marker.accessibilityRole(), .button)
            t.check(!(marker.accessibilityLabel() ?? "").isEmpty && marker.acceptsFirstResponder,
                    "the marker exposes a named keyboard-accessible button")
            f.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            guard let down = pointerEvent(.leftMouseDown, view: marker), let up = pointerEvent(.leftMouseUp, view: marker) else {
                return t.check(false, "native marker pointer events")
            }
            marker.mouseDown(with: down)
            marker.mouseUp(with: up)
            t.equal(decorations.detailsLine, 2, "click opens details for the actual physical line")
            t.equal(f.editor.textView.selectedRange(), NSRange(location: 0, length: 0), "an icon click does not select its line")
            decorations.closeDetails()
            let markerInRuler = f.editor.ruler.convert(marker.bounds, from: marker)
            let point = f.editor.ruler.convert(NSPoint(x: f.editor.ruler.bounds.maxX - 10, y: markerInRuler.midY), to: nil)
            guard let numberDown = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                return t.check(false, "native line-number event")
            }
            f.editor.ruler.mouseDown(with: numberDown)
            t.equal(f.editor.textView.selectedRange(), CodeEditorSelfTests.line(f.editor, 2),
                    "the separate line-number lane keeps its original whole-line selection")
            t.check(marker.accessibilityPerformPress())
            t.equal(decorations.detailsLine, 2, "AX press opens the same details")
            decorations.closeDetails()
            t.check(window.makeFirstResponder(marker), "the diagnostic button participates in native keyboard focus")
            for code: UInt16 in [36, 49] {
                guard let open = keyEvent(code, view: marker), let escape = keyEvent(53, view: marker) else {
                    return t.check(false, "native diagnostic keyboard events")
                }
                marker.keyDown(with: open)
                t.equal(decorations.detailsLine, 2, "Return and Space open the focused diagnostic button")
                marker.keyDown(with: escape)
                t.check(decorations.detailsLine == nil, "Escape closes the details")
            }

            window.makeKeyAndOrderFront(nil)
            t.check(window.makeFirstResponder(f.editor.textView))
            type("// unsaved buffer😀\n", replacing: NSRange(location: f.editor.text.utf16.count, length: 0), in: f.editor)
            t.check(settled(f) && f.editor.isDirty)
            f.editor.textView.scrollRangeToVisible(NSRange(location: f.editor.lineStarts[1], length: 1))
            decorations.layoutChanged()
            guard let currentMarker = decorations.markers[2], let enter = pointerEvent(.mouseEntered, view: currentMarker),
                  let exit = pointerEvent(.mouseExited, view: currentMarker) else {
                return t.check(false, "the dirty buffer has real marker tracking events")
            }
            var commits = 0
            f.editor.onCommit = { _, _ in commits += 1; return false }
            let selection = f.editor.textView.selectedRange(), buffer = f.editor.text, revision = f.editor.textRevision
            currentMarker.mouseEntered(with: enter)
            t.check(decorations.firePendingHoverForTesting(), "the real delayed hover is triggered without a wall-clock wait")
            t.check(decorations.detailsPanel?.isVisible == true && decorations.detailsLine == 2)
            t.check(window.firstResponder === f.editor.textView, "hover keeps the editor's keyboard focus")
            t.equal(f.editor.textView.selectedRange(), selection)
            t.equal(f.editor.text, buffer)
            t.equal(f.editor.textRevision, revision)
            t.equal(commits, 0, "hover never invokes the focus-left save path")
            t.equal(try Data(contentsOf: f.file), Data(text.utf8))
            currentMarker.mouseExited(with: exit)
            decorations.detailsHovered(true)
            t.check(!decorations.firePendingHoverCloseForTesting(), "entering the details panel cancels the marker-exit close")
            t.check(decorations.detailsPanel?.isVisible == true, "the content remains available while moving onto its controls")
            decorations.detailsHovered(false)
            t.check(decorations.firePendingHoverCloseForTesting())
            t.check(decorations.detailsLine == nil, "leaving both marker and content closes details")
            t.check(decorations.showDetails(forLine: 2, hover: true))
            let clip = f.editor.scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 20))
            f.editor.scrollView.reflectScrolledClipView(clip)
            t.check(decorations.detailsLine == nil, "real editor scrolling dismisses the anchored details")
            f.editor.textView.scrollRangeToVisible(NSRange(location: f.editor.lineStarts[1], length: 1))
            decorations.layoutChanged()
            t.check(decorations.showDetails(forLine: 2, hover: true))
            type(" ", replacing: NSRange(location: f.editor.text.utf16.count, length: 0), in: f.editor)
            t.check(decorations.detailsLine == nil, "an actual edit removes the prior diagnostic details")
            t.check(f.editor.isDirty && window.firstResponder === f.editor.textView)
            t.equal(commits, 0)
            t.equal(try Data(contentsOf: f.file), Data(text.utf8), "diagnostic navigation never writes the dirty buffer")
        }
    }

    private static func dirtyClickTests(_ t: AppTestRunner) {
        t.suite("Desk: code presentation: clicking a diagnostic marker preserves a dirty buffer without saving") {
            let text = "info { name: \"Click\" }\nwidget { Text(\"中文😀\").colr(.red) }\n"
            let f = try fixture(t, text: text)
            guard let decorations = f.controller.deskDecorations, let window = f.controller.window else {
                return t.check(false, "the actual dirty document window")
            }
            window.makeKeyAndOrderFront(nil)
            t.check(window.makeFirstResponder(f.editor.textView))
            type("// unsaved click😀\n", replacing: NSRange(location: text.utf16.count, length: 0), in: f.editor)
            t.check(settled(f) && f.editor.isDirty, "the real edited buffer has a current checked diagnostic")
            guard let marker = decorations.markers[2], let down = pointerEvent(.leftMouseDown, view: marker),
                  let up = pointerEvent(.leftMouseUp, view: marker) else {
                return t.check(false, "the dirty document's actual marker and native click events")
            }
            f.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            t.check(window.firstResponder === f.editor.textView)
            var commits = 0
            f.editor.onCommit = { _, _ in commits += 1; return false }
            let buffer = f.editor.text, revision = f.editor.textRevision, selection = f.editor.textView.selectedRange()
            marker.mouseDown(with: down)
            t.equal(commits, 0, "marker mouseDown must not invoke the focus-left save path")
            marker.mouseUp(with: up)
            t.equal(commits, 0, "opening the diagnostic details panel must not invoke the focus-left save path")
            t.check(decorations.detailsPanel?.isVisible == true && decorations.detailsLine == 2,
                    "the actual down/up click opens the dirty document's diagnostic details panel")
            t.equal(f.editor.textView.selectedRange(), selection, "the marker click leaves the caret selection alone")
            t.equal(f.editor.text, buffer)
            t.equal(f.editor.textRevision, revision)
            t.check(f.editor.isDirty, "reading diagnostic details retains the uncommitted buffer")
            t.equal(try Data(contentsOf: f.file), Data(text.utf8), "the dirty buffer is not written by diagnostic navigation")
        }
    }

    private static func waveHoverTests(_ t: AppTestRunner) {
        t.suite("Desk: code presentation: native diagnostic fragments anchor read-only hover details below code") {
            let f = try fixture(t, text: rangeText)
            guard let decorations = f.controller.deskDecorations, let checking = f.controller.deskChecking,
                  let window = f.controller.window else { return t.check(false, "the actual ranged diagnostic window") }
            window.makeKeyAndOrderFront(nil)
            t.check(window.makeFirstResponder(f.editor.textView))
            type(" // unsaved😀\r\n", replacing: NSRange(location: rangeText.utf16.count, length: 0), in: f.editor)
            t.check(settled(f) && f.editor.isDirty)
            let buffer = f.editor.text, revision = f.editor.textRevision, selection = f.editor.textView.selectedRange()
            var commits = 0
            f.editor.onCommit = { _, _ in commits += 1; return false }
            let whole = DeskRange(start: DeskPosition(offset: 1, line: 0, column: 1),
                                  end: DeskPosition(offset: 24, line: 2, column: 1))
            let diagnostic = DeskServiceDiagnostic(id: .unknownModifier, severity: .error, file: checking.fileID,
                                                   range: whole, message: "Original CRLF/emoji diagnostic hover control")
            t.check(decorations.show([diagnostic], file: checking.fileID, text: buffer, language: .english))
            let fragments = nativeFragments(f, range: NSRange(location: 1, length: 23), overlay: decorations.overlay)
            t.equal(fragments.count, 3, "the independent range covers three native CRLF fragments")
            t.equal(decorations.diagnosticRegions.count, 3)
            decorations.overlay.updateTrackingAreas()
            t.check(decorations.overlay.trackingAreas.contains {
                $0.options.contains(.mouseMoved) && $0.options.contains(.inVisibleRect)
            }, "the native overlay observes movement while keeping text hit testing transparent")
            for (number, fragment) in fragments.enumerated() {
                let point = NSPoint(x: fragment.probe.midX, y: fragment.probe.midY)
                let expected = NSRect(x: fragment.probe.minX, y: fragment.fragment.minY,
                                      width: fragment.probe.width, height: fragment.fragment.height)
                t.check(decorations.diagnosticRegions.contains {
                    $0.diagnosticIndex == 0 && $0.fragmentRect == fragment.fragment && $0.hitRect.contains(point)
                }, "native glyph geometry qualifies fragment \(number + 1)")
                let hitPoint = decorations.overlay.convert(point, to: decorations.overlay.superview)
                t.check(decorations.overlay.hitTest(hitPoint) == nil, "a diagnostic glyph never intercepts text clicks")
                guard let move = pointerEvent(.mouseMoved, view: decorations.overlay, point: point) else {
                    return t.check(false, "native diagnostic fragment movement")
                }
                decorations.overlay.mouseMoved(with: move)
                t.check(decorations.firePendingHoverForTesting())
                t.equal(decorations.detailsAnchor, expected, "the hovered fragment keeps its own glyph X and line Y")
                t.equal(decorations.detailsLine, 1, "a later CRLF fragment retains the originating diagnostic content")
                guard let panel = decorations.detailsPanel, let content = panel.contentView else {
                    return t.check(false, "the real diagnostic details panel")
                }
                t.check(panel.isVisible && !panel.canBecomeKey && !panel.canBecomeMain,
                        "the visible arrowless panel cannot take document keyboard ownership")
                t.check(!panel.styleMask.contains(.titled) && panel.styleMask.contains(.nonactivatingPanel))
                t.check(window.childWindows?.contains(where: { $0 === panel }) == true)
                t.check(decorations.cards.first?.isDescendant(of: content) == true)
                let screenAnchor = window.convertToScreen(decorations.overlay.convert(expected, to: nil))
                t.check(panel.frame.maxY <= screenAnchor.minY, "the native details frame starts below the hovered code")
                if let screen = window.screen { t.check(screen.visibleFrame.contains(panel.frame), "native details fit the visible screen") }
                t.check(window.firstResponder === f.editor.textView)
                decorations.closeDetails()
            }
            guard let lm = f.editor.textView.layoutManager, let container = f.editor.textView.textContainer else {
                return t.check(false, "the native glyph negative controls")
            }
            let firstGlyph = lm.glyphIndexForCharacter(at: 0)
            let ordinary = lm.boundingRect(forGlyphRange: NSRange(location: firstGlyph, length: 1),
                                           in: container)
            let origin = f.editor.textView.textContainerOrigin
            let ordinaryPoint = decorations.overlay.convert(NSPoint(x: ordinary.midX + origin.x, y: ordinary.midY + origin.y),
                                                             from: f.editor.textView)
            guard let first = fragments.first else { return t.check(false, "the first native fragment") }
            let whitespace = NSPoint(x: first.probe.maxX + 30, y: first.probe.midY)
            for point in [ordinaryPoint, whitespace] {
                guard let move = pointerEvent(.mouseMoved, view: decorations.overlay, point: point) else {
                    return t.check(false, "native ordinary-code and whitespace movement")
                }
                decorations.overlay.mouseMoved(with: move)
                t.check(!decorations.firePendingHoverForTesting() && decorations.detailsPanel == nil,
                        "ordinary code and blank space do not open a diagnostic")
            }
            t.equal(commits, 0)
            t.equal(f.editor.text, buffer)
            t.equal(f.editor.textRevision, revision)
            t.equal(f.editor.textView.selectedRange(), selection)
            t.check(f.editor.isDirty)
            t.equal(try Data(contentsOf: f.file), Data(rangeText.utf8))

            let wrappedText = String(repeating: "中文😀 wrapped diagnostic ", count: 18) + "\r\n"
            let wrapped = try fixture(t, text: wrappedText)
            guard let wrappedDecorations = wrapped.controller.deskDecorations,
                  let wrappedChecking = wrapped.controller.deskChecking else { return t.check(false, "native wrapped text") }
            wrapped.controller.window?.orderFront(nil)
            let end = wrappedText.utf16.count - 2
            let range = DeskRange(start: DeskPosition(offset: 0, line: 0, column: 0),
                                 end: DeskPosition(offset: end, line: 0, column: end))
            t.check(wrappedDecorations.show([DeskServiceDiagnostic(id: .unknownModifier, severity: .error,
                file: wrappedChecking.fileID, range: range, message: "Original soft-wrap hover control")],
                file: wrappedChecking.fileID, text: wrappedText, language: .english))
            let wrappedFragments = nativeFragments(wrapped, range: NSRange(location: 0, length: end), overlay: wrappedDecorations.overlay)
            t.check(wrappedFragments.count > 2, "the independent long physical line really soft-wraps in TextKit")
            for fragment in wrappedFragments {
                let point = NSPoint(x: fragment.probe.midX, y: fragment.probe.midY)
                guard let move = pointerEvent(.mouseMoved, view: wrappedDecorations.overlay, point: point) else {
                    return t.check(false, "native wrapped-fragment movement")
                }
                wrappedDecorations.overlay.mouseMoved(with: move)
                t.check(wrappedDecorations.firePendingHoverForTesting())
                t.equal(wrappedDecorations.detailsAnchor,
                        NSRect(x: fragment.probe.minX, y: fragment.fragment.minY, width: fragment.probe.width, height: fragment.fragment.height),
                        "soft-wrap hover stays under the current visual fragment")
                wrappedDecorations.closeDetails()
            }
            t.equal(try Data(contentsOf: wrapped.file), Data(wrappedText.utf8))

            let area = NSRect(x: 100, y: 50, width: 800, height: 600), size = NSSize(width: 220, height: 100)
            let middle = NSRect(x: 220, y: 450, width: 40, height: 18)
            let below = DeskCodeDecorations.placementFrame(anchor: middle, size: size, within: area)
            t.check(area.contains(below) && below.maxY <= middle.minY, "the actual placement helper prefers below code")
            let rightBottom = NSRect(x: area.maxX - 5, y: area.minY + 8, width: 4, height: 18)
            let flipped = DeskCodeDecorations.placementFrame(anchor: rightBottom, size: size, within: area)
            t.check(area.contains(flipped) && flipped.minY >= rightBottom.maxY && flipped.minX < rightBottom.minX,
                    "the actual helper flips above and clamps at the right screen edge")
            let left = NSRect(x: area.minX - 20, y: 450, width: 4, height: 18)
            let clamped = DeskCodeDecorations.placementFrame(anchor: left, size: size, within: area)
            t.check(area.contains(clamped) && clamped.minX > left.minX, "the actual helper clamps at the left screen edge")
        }
    }
}
