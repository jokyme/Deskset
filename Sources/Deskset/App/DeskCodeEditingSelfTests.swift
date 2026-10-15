import AppKit
import DeskLanguage
import DesksetCore

/// Real checked actions and native menu/undo delivery. Documents and disk conflicts use only test scratch.
enum DeskCodeEditingSelfTests {
    static func run(_ t: AppTestRunner) {
        menuTests(t)
        batchTests(t)
        rejectionTests(t)
        staleTests(t)
        waveMenuTests(t)
        keyboardMenuTests(t)
        inspectorEditTests(t)
        inspectorPropertyTests(t)
        inspectorSelectionTests(t)
        inspectorStaleTests(t)
        inspectorSourceTests(t)
        inspectorWindowDeliveryTests(t)
    }

    private struct Fixture {
        let app: AppController
        let file: URL
        let controller: CodeFileWindowController
        var editor: CodeEditorView { controller.codeView }
    }

    private static func fixture(_ t: AppTestRunner, text: String,
                                queue: DispatchQueue = DispatchQueue(label: "desk.editing.test.check")) throws -> Fixture {
        let root = t.temporaryDirectory("desk-editing")
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: root.appendingPathComponent("Skins"),
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false)
        let file = root.appendingPathComponent("Widget.desk")
        try Data(text.utf8).write(to: file)
        let controller = try CodeFileWindowController(file: file, app: app, deskCheckQueue: queue)
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

    private static func settled(_ f: Fixture) -> Bool {
        AppSelfTest.spin(timeout: 10) {
            guard let snapshot = f.controller.deskChecking?.snapshot else { return false }
            return snapshot.isChecked && snapshot.version == f.editor.textRevision
                && snapshot.text.utf8.elementsEqual(f.editor.text.utf8)
        }
    }

    private static let typoText = "\u{FEFF}info { name: \"修复😀\" }\r\nwidget { Text(\"中文😀\").colr(.red) }\r\n"
    private static let fixedText = "\u{FEFF}info { name: \"修复😀\" }\r\nwidget { Text(\"中文😀\").color(.red) }\r\n"

    /// Forwards the real card's tracking lifecycle, then ends the native loop without waiting on a clock.
    private final class MenuEntryReceipt: NSObject, NSMenuDelegate {
        let previous: NSMenuDelegate?
        private(set) var opens = 0
        private(set) var closes = 0

        init(previous: NSMenuDelegate?) { self.previous = previous; super.init() }

        func menuWillOpen(_ menu: NSMenu) {
            opens += 1
            previous?.menuWillOpen?(menu)
            RunLoop.current.perform(inModes: [.eventTracking]) { menu.cancelTracking() }
        }

        func menuDidClose(_ menu: NSMenu) {
            closes += 1
            previous?.menuDidClose?(menu)
        }
    }

    private static func menuTests(_ t: AppTestRunner) {
        t.suite("Desk: code editing: real action menu preserves the buffer, one undo and the normal save path") {
            let f = try fixture(t, text: typoText)
            guard let checking = f.controller.deskChecking, let decorations = f.controller.deskDecorations,
                  let diagnostic = checking.snapshot.diagnostics.first(where: { $0.id == .unknownModifier }),
                  let marker = decorations.markers[diagnostic.line + 1] else {
                return t.check(false, "the current real checker has no diagnostic marker")
            }
            f.controller.window?.orderFront(nil)
            t.check(f.controller.window?.makeFirstResponder(f.editor.textView) == true)
            let location = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
            guard let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: marker.window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil),
                  let exit = NSEvent.enterExitEvent(with: .mouseExited, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: marker.window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else {
                return t.check(false, "actual diagnostic marker tracking events")
            }
            marker.mouseEntered(with: enter)
            t.check(decorations.firePendingHoverForTesting())
            marker.mouseExited(with: exit)
            decorations.detailsHovered(true)
            t.check(!decorations.firePendingHoverCloseForTesting(), "moving onto the hover details panel retains its actionable menu")
            guard let content = decorations.detailsPanel?.contentView,
                  let card = decorations.cards.first(where: { $0.diagnostic.id == .unknownModifier && $0.isDescendant(of: content) }),
                  let actionIndex = card.actions.firstIndex(where: { $0.kind == .quickFix && $0.isPreferred }),
                  let popup = card.actionMenu, let menu = popup.menu,
                  let undo = f.editor.textView.undoManager else {
                return t.check(false, "the actual expanded details panel did not offer the preferred service action")
            }
            t.check(decorations.detailsPanel?.isVisible == true && card.enclosingScrollView != nil,
                    "the menu comes from the visible native details panel, not an unattached retained card")
            t.check(popup.refusesFirstResponder && f.controller.window?.firstResponder === f.editor.textView,
                    "hover keeps editing focus while leaving its quick fix clickable")
            let original = checking.snapshot
            let action = card.actions[actionIndex]
            t.equal(card.actions, original.codeActions(for: card.diagnostic).filter { $0.edit.changedFiles == [original.file] })
            t.equal(Array(menu.items.dropFirst()).map(\.title), card.actions.map(\.title), "the menu uses every real localized title")
            t.check(!undo.canUndo, "loading and checking did not make an edit")
            f.editor.textView.setSelectedRange(NSRange(location: typoText.utf16.count, length: 0))
            let revision = f.editor.textRevision
            let item = menu.items[actionIndex + 1]
            guard let selector = item.action else { return t.check(false, "the native menu item has no action") }
            t.check(NSApplication.shared.sendAction(selector, to: item.target, from: item), "AppKit dispatched the real menu selection")
            t.equal(f.editor.text, fixedText, "the expected whole document is independent of WorkspaceEdit.apply")
            t.check(decorations.detailsLine == nil, "the edit dismisses the old hover details")
            t.equal(f.editor.textView.selectedRange(), NSRange(location: fixedText.utf16.count, length: 0))
            t.check(f.editor.textRevision > revision && f.editor.isDirty)
            t.check(settled(f))
            t.check(!checking.snapshot.diagnostics.contains { $0.id == .unknownModifier })
            t.equal(try Data(contentsOf: f.file), Data(typoText.utf8), "the action edits a buffer without immediate saving")
            CodeEditorSelfTests.spin(0.02)
            t.equal(undo.undoActionName, action.title)
            undo.undo()
            t.equal(f.editor.text, typoText)
            t.check(!undo.canUndo && !f.editor.isDirty, "one undo restores all edits and leaves no earlier action")
            t.check(settled(f))
            undo.redo()
            t.equal(f.editor.text, fixedText)
            t.check(settled(f))
            f.editor.onCommit = { _, _ in false }
            t.check(!f.editor.commitNow(explicit: true) && f.editor.hasUncommittedChanges, "a refused save keeps the edited buffer")
            t.equal(try Data(contentsOf: f.file), Data(typoText.utf8))
            f.editor.onCommit = nil
            t.check(f.editor.commitNow(explicit: true))
            t.equal(try Data(contentsOf: f.file), Data(fixedText.utf8), "the existing UTF8/BOM/CRLF writer saves the action")
            t.equal(f.app.sortedControllers.count, 0, "fixing did not activate a skin")
            withExtendedLifetime((card, popup, menu)) {}
        }
    }

    private static func batchTests(_ t: AppTestRunner) {
        t.suite("Desk: code editing: real Fix all and repeated insertions are complete single undo steps") {
            // The same full-width punctuation fixture is covered by the existing language service action tests.
            let text = "info { name: \"T\" }\nwidget {\n    Text(\"A\")。font(.caption)\n    Text(\"B\")。font(.caption)\n    Text(\"C\")。bold()\n}\n"
            let fixed = "info { name: \"T\" }\nwidget {\n    Text(\"A\").font(.caption)\n    Text(\"B\").font(.caption)\n    Text(\"C\").bold()\n}\n"
            let f = try fixture(t, text: text)
            guard let checking = f.controller.deskChecking,
                  let diagnostic = checking.snapshot.diagnostics.first(where: { $0.id == .fullWidthPunctuation }),
                  let all = checking.snapshot.codeActions(for: diagnostic).first(where: { $0.kind == .fixAll }),
                  let undo = f.editor.textView.undoManager else {
                return t.check(false, "the real punctuation control has no complete Fix all action")
            }
            t.equal(all.diagnostics.count, 3)
            t.check(f.controller.applyDeskAction(all, from: checking.snapshot))
            t.equal(f.editor.text, fixed)
            t.check(settled(f))
            t.check(!checking.snapshot.diagnostics.contains { $0.id == .fullWidthPunctuation })
            CodeEditorSelfTests.spin(0.02)
            undo.undo()
            t.equal(f.editor.text, text)
            t.check(!undo.canUndo)

            let raw = try fixture(t, text: "A😀\r\n")
            guard let rawChecking = raw.controller.deskChecking, let rawUndo = raw.editor.textView.undoManager else {
                return t.check(false, "the raw UTF16 control has no checker/undo manager")
            }
            raw.editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
            let edits = [edit(1, 3, "字"), edit(0, 0, "L"), edit(0, 0, "R"), edit(5, 5, "!")]
            t.check(rawChecking.apply(edits, from: rawChecking.snapshot, actionName: "Original multi-edit control"))
            t.equal(raw.editor.text, "LRA字\r\n!", "same-point insertions keep their original stable order")
            t.equal(raw.editor.textView.selectedRange(), NSRange(location: 7, length: 0))
            t.equal(try Data(contentsOf: raw.file), Data("A😀\r\n".utf8))
            CodeEditorSelfTests.spin(0.02)
            rawUndo.undo()
            t.equal(raw.editor.text, "A😀\r\n")
            t.check(!rawUndo.canUndo)
        }
    }

    private static func edit(_ start: Int, _ end: Int, _ text: String) -> DeskTextEditU16 {
        var range = DeskRange(start: DeskPosition(offset: start, line: 0, column: start),
                              end: DeskPosition(offset: end, line: 0, column: end))
        // Preserve even a reversed raw range; the service's constructor otherwise normalizes its end.
        range.end = DeskPosition(offset: end, line: 0, column: end)
        return DeskTextEditU16(range: range, newText: text)
    }

    private static func rejectionTests(_ t: AppTestRunner) {
        t.suite("Desk: code editing: foreign files, invalid scalar ranges and overlaps are rejected as a whole") {
            let f = try fixture(t, text: "A😀\r\n")
            guard let checking = f.controller.deskChecking, let undo = f.editor.textView.undoManager else {
                return t.check(false, "the rejection control has no checker/undo manager")
            }
            let snapshot = checking.snapshot
            let revision = f.editor.textRevision
            let invalid = [[edit(-1, 0, "bad")], [edit(2, 3, "split")], [edit(0, 6, "outside")],
                           [edit(3, 1, "reversed")], [edit(Int.max, Int.max, "overflow")],
                           [edit(0, 3, "replace"), edit(1, 1, "overlap")]]
            for edits in invalid {
                t.check(!checking.apply(edits, from: snapshot, actionName: "Invalid control"))
                t.equal(f.editor.text, "A😀\r\n")
                t.equal(f.editor.textRevision, revision)
                t.check(!undo.canUndo, "rejecting the complete list leaves no partial undo step")
            }
            let other = DeskFileID(path: "Other.desk")
            let both = DeskWorkspaceEdit([checking.fileID: [edit(0, 1, "B")], other: [edit(0, 0, "foreign")]])
            t.check(!checking.apply(both, from: snapshot, actionName: "Foreign control"))
            t.equal(f.editor.text, "A😀\r\n", "the own-file subset of a foreign action is not applied")
            t.check(!FileManager.default.fileExists(atPath: f.file.deletingLastPathComponent().appendingPathComponent("Other.desk").path))
            f.editor.textView.isEditable = false
            t.check(!checking.apply([edit(0, 1, "B")], from: snapshot, actionName: "Read-only control"))
            f.editor.textView.isEditable = true
            t.equal(f.editor.textRevision, revision)
            t.check(!undo.canUndo && !f.editor.isDirty)
            t.equal(try Data(contentsOf: f.file), Data("A😀\r\n".utf8))
        }
    }

    private static func staleTests(_ t: AppTestRunner) {
        t.suite("Desk: code editing: same-text rechecks, pending checks, read errors and close reject retained actions") {
            let queue = DispatchQueue(label: "desk.editing.test.held")
            queue.suspend()
            var held = true
            defer { if held { queue.resume() } }
            let text = typoText + "//" + String(repeating: "x", count: 9_000) + "\r\n"
            let f = try fixture(t, text: text, queue: queue)
            guard let checking = f.controller.deskChecking, let decorations = f.controller.deskDecorations,
                  let diagnostic = checking.snapshot.diagnostics.first(where: { $0.id == .unknownModifier }),
                  let action = checking.snapshot.codeActions(for: diagnostic).first(where: { $0.kind == .quickFix }) else {
                return t.check(false, "the original checked control has no real action")
            }
            t.check(decorations.showDetails(forLine: diagnostic.line + 1))
            guard let content = decorations.detailsPanel?.contentView,
                  let card = decorations.cards.first(where: { $0.diagnostic.id == .unknownModifier && $0.isDescendant(of: content) }),
                  let popup = card.actionMenu, let menu = popup.menu,
                  let index = card.actions.firstIndex(of: action), menu.items.indices.contains(index + 1),
                  let selector = menu.items[index + 1].action else {
                return t.check(false, "the original actual panel has no retainable native menu action")
            }
            let item = menu.items[index + 1]
            let original = checking.snapshot
            checking.recheck()
            t.check(checking.snapshot.generation != original.generation, "a same-text recheck has a distinct service generation")
            t.check(!f.controller.applyDeskAction(action, from: original))
            t.check(NSApplication.shared.sendAction(selector, to: item.target, from: item), "AppKit dispatches the retained old menu")
            t.equal(f.editor.text, text)
            t.equal(f.editor.textRevision, original.version, "same-text generation invalidation rejects the retained popup callback")
            t.check(!checking.snapshot.isChecked, "the deliberately held current check is pending")
            t.check(!checking.apply(action.edit, from: checking.snapshot, actionName: action.title))
            t.equal(f.controller.deskDecorations?.cards.count, 0, "pending results leave no clickable stale card")
            t.check(decorations.markers.isEmpty && decorations.detailsLine == nil, "pending removes the marker and expanded details")
            queue.resume()
            held = false
            t.check(settled(f))
            let current = checking.snapshot
            t.check(checking.isCurrent(current) && !checking.isCurrent(original))
            t.check(NSApplication.shared.sendAction(selector, to: item.target, from: item))
            t.equal(f.editor.text, text, "a completed same-text replacement still rejects the old popup")
            t.check(decorations.showDetails(forLine: diagnostic.line + 1))
            guard let currentContent = decorations.detailsPanel?.contentView,
                  let currentCard = decorations.cards.first(where: { $0.diagnostic.id == .unknownModifier && $0.isDescendant(of: currentContent) }),
                  let currentPopup = currentCard.actionMenu, let currentMenu = currentPopup.menu,
                  let currentIndex = currentCard.actions.firstIndex(of: action), currentMenu.items.indices.contains(currentIndex + 1),
                  let currentSelector = currentMenu.items[currentIndex + 1].action else {
                return t.check(false, "the replacement actual panel has no current native menu")
            }
            let currentItem = currentMenu.items[currentIndex + 1]
            // A failed disk reload keeps the buffer, but the window's error state disables its old action.
            try Data([0xC3]).write(to: f.file)
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: f.controller.window))
            t.check(f.controller.readError != nil)
            t.check(!f.controller.applyDeskAction(action, from: current))
            t.check(NSApplication.shared.sendAction(currentSelector, to: currentItem.target, from: currentItem))
            t.equal(f.editor.text, text)
            t.equal(f.editor.textRevision, current.version, "a read error rejects even the most recently retained menu")
            t.equal(try Data(contentsOf: f.file), Data([0xC3]))
            checking.close()
            f.controller.window?.close()
            t.check(!checking.apply(action.edit, from: current, actionName: action.title))
            t.check(!checking.isCurrent(current))
            t.check(NSApplication.shared.sendAction(currentSelector, to: currentItem.target, from: currentItem))
            t.check(NSApplication.shared.sendAction(selector, to: item.target, from: item))
            t.check(decorations.detailsLine == nil && decorations.markers.isEmpty, "close removes native diagnostic controls")
            t.equal(f.editor.text, text)
            t.equal(f.editor.textRevision, current.version)
            t.check(!f.editor.isDirty)
            t.equal(f.app.sortedControllers.count, 0)
            withExtendedLifetime((card, popup, menu, currentCard, currentPopup, currentMenu)) {}
        }
    }

    private static func waveMenuTests(_ t: AppTestRunner) {
        t.suite("Desk: code editing: hovering the actual diagnostic glyphs keeps the native quick fix reachable") {
            let f = try fixture(t, text: typoText)
            guard let decorations = f.controller.deskDecorations, let checking = f.controller.deskChecking,
                  let diagnostic = checking.snapshot.diagnostics.first(where: { $0.id == .unknownModifier }),
                  let lm = f.editor.textView.layoutManager, let container = f.editor.textView.textContainer,
                  let window = f.controller.window else { return t.check(false, "the actual checked diagnostic glyphs") }
            window.makeKeyAndOrderFront(nil)
            t.check(window.makeFirstResponder(f.editor.textView))
            let glyphs = lm.glyphRange(forCharacterRange: diagnostic.range.nsRange, actualCharacterRange: nil)
            let bounds = lm.boundingRect(forGlyphRange: glyphs, in: container)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let origin = f.editor.textView.textContainerOrigin
            let point = decorations.overlay.convert(NSPoint(x: bounds.midX + origin.x,
                y: fragment.minY + lm.location(forGlyphAt: glyphs.location).y + origin.y + 3.5), from: f.editor.textView)
            let location = decorations.overlay.convert(point, to: nil)
            guard let move = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0),
                  let exit = NSEvent.enterExitEvent(with: .mouseExited, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else {
                return t.check(false, "native diagnostic glyph tracking events")
            }
            decorations.overlay.mouseMoved(with: move)
            t.check(decorations.firePendingHoverForTesting())
            decorations.overlay.mouseExited(with: exit)
            decorations.detailsHovered(true)
            t.check(!decorations.firePendingHoverCloseForTesting(), "moving from code to the details panel retains its fix controls")
            guard let content = decorations.detailsPanel?.contentView,
                  let card = decorations.cards.first(where: { $0.diagnostic.id == .unknownModifier && $0.isDescendant(of: content) }),
                  let index = card.actions.firstIndex(where: { $0.kind == .quickFix && $0.isPreferred }),
                  let popup = card.actionMenu, let menu = popup.menu, let selector = menu.items[index + 1].action else {
                return t.check(false, "the native glyph-hover details panel has no actual preferred fix")
            }
            t.check(decorations.detailsPanel?.isVisible == true && window.firstResponder === f.editor.textView)
            t.check(popup.refusesFirstResponder)
            let item = menu.items[index + 1]
            t.check(NSApplication.shared.sendAction(selector, to: item.target, from: item))
            t.equal(f.editor.text, fixedText)
            t.check(f.editor.isDirty && decorations.detailsLine == nil)
            t.equal(try Data(contentsOf: f.file), Data(typoText.utf8))
            withExtendedLifetime((card, popup, menu)) {}
        }
    }

    private static func keyboardMenuTests(_ t: AppTestRunner) {
        t.suite("Desk: code editing: focused diagnostic markers enter the actual native fix menu") {
            let f = try fixture(t, text: typoText)
            guard let decorations = f.controller.deskDecorations, let checking = f.controller.deskChecking,
                  let diagnostic = checking.snapshot.diagnostics.first(where: { $0.id == .unknownModifier }),
                  let marker = decorations.markers[diagnostic.line + 1], let window = f.controller.window else {
                return t.check(false, "the actual keyboard diagnostic marker")
            }
            window.makeKeyAndOrderFront(nil)
            t.check(window.makeFirstResponder(marker))
            guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36),
                  let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                isARepeat: false, keyCode: 125) else { return t.check(false, "native Enter and Down events") }
            marker.keyDown(with: enter)
            guard let content = decorations.detailsPanel?.contentView,
                  let card = decorations.cards.first(where: { $0.diagnostic.id == .unknownModifier && $0.isDescendant(of: content) }),
                  let index = card.actions.firstIndex(where: { $0.kind == .quickFix && $0.isPreferred }),
                  let popup = card.actionMenu, let menu = popup.menu, let selector = menu.items[index + 1].action else {
                return t.check(false, "the keyboard-opened native panel has no preferred fix")
            }
            let receipt = MenuEntryReceipt(previous: menu.delegate)
            menu.delegate = receipt
            defer { menu.delegate = receipt.previous }
            marker.keyDown(with: down)
            t.equal(receipt.opens, 1, "Down entered the actual menu tracking loop")
            t.equal(receipt.closes, 1, "the controlled event-tracking callback ended the actual native menu")
            t.check(window.firstResponder === marker && decorations.detailsPanel?.isVisible == true,
                    "the keyboard menu leaves the marker focused and the diagnostic panel available")
            t.equal(f.editor.text, typoText, "entering and dismissing the keyboard menu does not edit")
            let item = menu.items[index + 1]
            t.check(NSApplication.shared.sendAction(selector, to: item.target, from: item), "the entered native menu still dispatches its real fix")
            t.equal(f.editor.text, fixedText)
            t.check(f.editor.isDirty && decorations.detailsLine == nil)
            t.equal(try Data(contentsOf: f.file), Data(typoText.utf8))
            withExtendedLifetime((card, popup, menu, receipt)) {}
        }
    }

    private enum InspectorFixtureFailure: Error { case selection, page }
    private static let inspectorText = "\u{FEFF}info { name: \"圆角😀\" }\r\nwidget { Rectangle().size(90, 70).rounded(/* keep */ 8pt /* radius */) }\r\n"
    private static let inspectorEvent = StudioPageEvent.number(item: "desk.corners", part: 0, change: .typed("16"))

    private static func showInspector(_ t: AppTestRunner, _ f: Fixture, at offset: Int? = nil) throws -> DeskElementInspector {
        let start = offset ?? (f.editor.text as NSString).range(of: "Rectangle()").location
        t.check(f.editor.reveal(range: NSRange(location: start, length: 0), in: f.file))
        f.controller.setDeskInspectorShown(true)
        guard let model = f.controller.deskElementInspector, f.controller.deskInspector?.pageView.onEvent != nil else {
            throw InspectorFixtureFailure.selection
        }
        return model
    }

    private static func inspectorNumber(_ f: Fixture) throws -> StudioPage.Number {
        guard case .row(let row)? = f.controller.deskInspector?.pageView.page?.item("desk.corners")?.kind,
              case .number(let number) = row.control else { throw InspectorFixtureFailure.page }
        return number
    }

    private static func inspectorShape(_ f: Fixture) -> ShapeItem? {
        f.controller.deskPreview?.scene?.drawingItems.compactMap { item -> ShapeDraw? in
            if case .shape(let draw) = item { return draw }
            return nil
        }.first?.shapes.first
    }

    private static func inspectorEditTests(_ t: AppTestRunner) {
        t.suite("Desk: inspector editing: the actual property page changes radius with one undo and the normal save path") {
            let f = try fixture(t, text: inspectorText)
            guard let window = f.controller.window, let preview = f.controller.deskPreview,
                  let pane = f.controller.deskInspector, let editorUndo = f.editor.textView.undoManager,
                  let undo = window.undoManager else {
                return t.check(false, "the real Desk split window and property pane")
            }
            t.check(window.undoManager === editorUndo, "window commands and the code buffer use the same undo manager")
            t.check(!f.controller.isDeskInspectorShown && !preview.isInspecting, "the initial code and preview remain interactive")
            _ = try showInspector(t, f)
            t.check(f.controller.isDeskInspectorShown && preview.isInspecting)
            t.check(!pane.pageView.showsSearch && pane.pageView.searchField.isHidden,
                    "this small property page has no inactive search control")
            t.equal(try inspectorNumber(f).value, 8)
            window.makeKeyAndOrderFront(nil)
            t.check(settled(f), "activating the real window finishes its same-text source recheck before inspecting controls")
            window.setContentSize(window.contentMinSize)
            window.contentView?.layoutSubtreeIfNeeded()
            t.check(f.editor.frame.width >= 359 && preview.view.frame.width >= 279 && pane.view.frame.width >= 299,
                    "minimum native layout: code=\(f.editor.frame), preview=\(preview.view.frame), inspector=\(pane.view.frame)")
            t.check(f.editor.frame.height > 0 && preview.scrollView.frame.height > 0 && pane.scrollView.frame.height > 0,
                    "minimum height retains code, canvas and a scrollable inspector")
            guard let before = inspectorShape(f), let original = f.controller.deskChecking?.snapshot,
                  let row = pane.pageView.itemView("desk.corners") as? StudioRowView, let box = row.numberBox else {
                return t.check(false, "initial shared rounded geometry and the actual existing numeric control")
            }
            t.equal(Desk.compile(original.checked, catalog: original.options.catalog).program?.root.cornerRadius, .points(8))
            t.check(!undo.canUndo)
            t.check(window.makeFirstResponder(f.editor.textView))
            t.check(window.makeFirstResponder(box.field), "the property field takes real keyboard focus")
            guard let fieldEditor = box.field.currentEditor() as? NSTextView else {
                return t.check(false, "AppKit must supply a real shared field editor")
            }
            fieldEditor.setSelectedRange(NSRange(location: 0, length: fieldEditor.string.utf16.count))
            fieldEditor.insertText("16", replacementRange: fieldEditor.selectedRange())
            t.equal(fieldEditor.string, "16")
            t.equal(f.editor.text, inspectorText, "typing in the numeric field waits for its native end-editing notification")
            t.equal(f.editor.textRevision, original.version)
            t.equal(try Data(contentsOf: f.file), Data(inspectorText.utf8))
            t.check(window.makeFirstResponder(f.editor.textView), "leaving the numeric field submits through its existing delegate")
            let expected = inspectorText.replacingOccurrences(of: "8pt", with: "16pt")
            t.equal(f.editor.text, expected)
            t.check(f.editor.isDirty && f.editor.textRevision > original.version)
            t.equal(try Data(contentsOf: f.file), Data(inspectorText.utf8))
            t.check(settled(f))
            guard let current = f.controller.deskChecking?.snapshot, let after = inspectorShape(f) else {
                return t.check(false, "the changed property must reach the current real scene")
            }
            t.equal(Desk.compile(current.checked, catalog: current.options.catalog).program?.root.cornerRadius, .points(16))
            t.check(after.geometry != before.geometry && after.bounds == before.bounds,
                    "rounding changes the actual shared shape path while retaining its layout")
            CodeEditorSelfTests.spin(0.02)
            t.equal(undo.undoActionName, StudioText[.rowCorners])
            window.undoManager?.undo()
            t.equal(Data(f.editor.text.utf8), Data(inspectorText.utf8), "one undo restores exact BOM, CRLF, Unicode and comments")
            t.check(!undo.canUndo && !f.editor.isDirty)
            t.check(settled(f))
            window.undoManager?.redo()
            t.equal(f.editor.text, expected)
            t.check(settled(f))
            t.check(f.editor.commitNow(explicit: true))
            t.equal(try Data(contentsOf: f.file), Data(expected.utf8))
            t.check(!f.editor.isDirty && f.app.sortedControllers.isEmpty)
            f.controller.setDeskInspectorShown(false)
            window.setContentSize(window.contentMinSize)
            window.contentView?.layoutSubtreeIfNeeded()
            t.check(!f.controller.isDeskInspectorShown && !preview.isInspecting)
            t.check(pane.pageView.onEvent == nil && f.controller.deskElementInspector == nil)
            t.check(f.editor.frame.width >= 359 && preview.view.frame.width >= 279)
        }
    }

    private static func inspectorPropertyTests(_ t: AppTestRunner) {
        t.suite("Desk: inspector properties: real text size and position fields preserve source preview undo and save") {
            let source = "\u{FEFF}// 甲😀\r\nwidget { Freeform { Text(\"Before\").font(20pt).size(180pt, 60pt).position(x: -12pt, y: -9pt, anchor: .topLeft).name(label) } }\r\n"
            let cases: [(String, String, String, String, SkinRect, String, Double)] = [
                ("desk.width", "200", "180pt", "200pt", SkinRect(x: -12, y: -9, width: 200, height: 60), "Before", 20),
                ("desk.text.size", "24", "20pt", "24pt", SkinRect(x: -12, y: -9, width: 180, height: 60), "Before", 24),
                ("desk.position.x", "-28", "-12pt", "-28pt", SkinRect(x: -28, y: -9, width: 180, height: 60), "Before", 20),
                ("desk.text.content", "甲 {x}", "Before", "甲 {{x}}", SkinRect(x: -12, y: -9, width: 180, height: 60), "甲 {x}", 20),
            ]
            for (item, input, old, new, frame, text, size) in cases {
                let f = try fixture(t, text: source)
                guard let window = f.controller.window, let pane = f.controller.deskInspector,
                      let preview = f.controller.deskPreview, let undo = window.undoManager else {
                    throw InspectorFixtureFailure.page
                }
                window.makeKeyAndOrderFront(nil)
                t.check(settled(f))
                let model = try showInspector(t, f, at: (source as NSString).range(of: "Text(").location)
                guard let row = pane.pageView.itemView(item) as? StudioRowView, let box = row.numberBox else {
                    return t.check(false, "the real native property control exists: \(item)")
                }
                t.check(window.makeFirstResponder(f.editor.textView))
                t.check(window.makeFirstResponder(box.field), item)
                guard let fieldEditor = box.field.currentEditor() as? NSTextView else { throw InspectorFixtureFailure.page }
                fieldEditor.setSelectedRange(NSRange(location: 0, length: fieldEditor.string.utf16.count))
                fieldEditor.insertText(input, replacementRange: fieldEditor.selectedRange())
                t.equal(f.editor.text, source, "the field waits for native end editing")
                t.check(window.makeFirstResponder(f.editor.textView))
                let expected = source.replacingOccurrences(of: old, with: new)
                t.equal(f.editor.text, expected, item)
                t.check(settled(f)); t.equal(preview.state, .ready)
                guard let draw = preview.scene?.drawingItems.compactMap({ value -> TextDraw? in
                    if case .text(let text) = value { return text }; return nil
                }).first else { throw InspectorFixtureFailure.page }
                t.equal(draw.frame, frame); t.equal(draw.text, text)
                t.close(TextStyle.pixelSize(points: draw.style.fontSize), size)
                t.equal(preview.canvas.bounds, NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
                t.equal(try Data(contentsOf: f.file), Data(source.utf8), "editing still uses the normal deferred save")
                t.check(!f.controller.applyDeskInspectorEvent(.number(item: item, part: 0, change: .typed(input)), from: model),
                        "the old page cannot write after recompilation")
                CodeEditorSelfTests.spin(0.02)
                undo.undo()
                t.equal(Data(f.editor.text.utf8), Data(source.utf8), "one undo restores exact source bytes")
                t.check(!undo.canUndo && !f.editor.isDirty)
                t.check(settled(f))
                undo.redo(); t.equal(f.editor.text, expected); t.check(settled(f))
                t.check(f.editor.commitNow(explicit: true))
                t.equal(try Data(contentsOf: f.file), Data(expected.utf8))
                t.check(!f.editor.isDirty && f.app.sortedControllers.isEmpty)
                window.close()
            }
        }
    }

    private static func inspectorSelectionTests(_ t: AppTestRunner) {
        t.suite("Desk: inspector editing: a real caret move selects another anonymous Rectangle and rejects the old page") {
            let first = "Rectangle().size(90, 70).rounded(8pt)"
            let second = "Rectangle().size(90, 70).fill(.accent)"
            let source = "info { name: \"T\" }\nwidget { Row(spacing: 4) { \(first); \(second) } }\n"
            let f = try fixture(t, text: source)
            f.editor.caretRestDelay = 600
            let firstModel = try showInspector(t, f)
            guard let retained = f.controller.deskInspector?.pageView.onEvent else { throw InspectorFixtureFailure.page }
            t.equal(try inspectorNumber(f).value, 8)
            let location = (source as NSString).range(of: second).location
            f.editor.textView.setSelectedRange(NSRange(location: location + 3, length: 0))
            t.check(f.editor.fireCaretRest(), "the actual NSTextView user selection is delivered through the existing caret rest")
            guard let next = f.controller.deskElementInspector else { throw InspectorFixtureFailure.selection }
            t.check(next.element != firstModel.element && next.snapshot.generation == firstModel.snapshot.generation)
            t.equal(try inspectorNumber(f).value, 0, "another anonymous element reads its own absent radius")
            retained(inspectorEvent)
            t.check(!f.controller.applyDeskInspectorEvent(inspectorEvent, from: firstModel))
            t.equal(f.editor.text, source, "the retained first page cannot edit either Rectangle after selection changes")
            f.controller.deskInspector?.pageView.onEvent?(.number(item: "desk.corners", part: 0, change: .typed("4")))
            t.equal(f.editor.text, source.replacingOccurrences(of: second, with: second + ".rounded(4)"))
            t.check(f.editor.isDirty && settled(f))
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
            guard let checked = f.controller.deskChecking?.snapshot,
                  let program = Desk.compile(checked.checked, catalog: checked.options.catalog).program,
                  case .row(_, _, let children) = program.root.content else {
                return t.check(false, "the independently compiled real row remains supported")
            }
            t.equal(children.map(\.cornerRadius), [.points(8), .points(4)])
        }
    }

    private static func inspectorStaleTests(_ t: AppTestRunner) {
        t.suite("Desk: inspector editing: pending recheck hide read error and close reject retained page events") {
            let queue = DispatchQueue(label: "desk.inspector.test.held")
            queue.suspend()
            var held = true
            defer { if held { queue.resume() } }
            let source = inspectorText + "//" + String(repeating: "x", count: 9_000) + "\r\n"
            let f = try fixture(t, text: source, queue: queue)
            let original = try showInspector(t, f)
            guard let checking = f.controller.deskChecking, let retained = f.controller.deskInspector?.pageView.onEvent else {
                throw InspectorFixtureFailure.page
            }
            checking.recheck()
            t.check(!checking.snapshot.isChecked && checking.snapshot.generation != original.snapshot.generation)
            t.check(f.controller.deskElementInspector == nil && f.controller.deskInspector?.pageView.onEvent == nil)
            retained(inspectorEvent)
            t.check(!f.controller.applyDeskInspectorEvent(inspectorEvent, from: original))
            t.equal(f.editor.text, source)
            t.equal(f.editor.textRevision, original.snapshot.version)
            queue.resume(); held = false
            t.check(settled(f))
            retained(inspectorEvent)
            t.equal(f.editor.text, source, "the same text's newly finished check does not revive an old page")
            let current = try showInspector(t, f)
            guard let hiddenEvent = f.controller.deskInspector?.pageView.onEvent else { throw InspectorFixtureFailure.page }
            f.controller.setDeskInspectorShown(false)
            hiddenEvent(inspectorEvent)
            t.check(!f.controller.applyDeskInspectorEvent(inspectorEvent, from: current))
            t.equal(f.editor.textRevision, current.snapshot.version)
            _ = try showInspector(t, f)
            guard let errorEvent = f.controller.deskInspector?.pageView.onEvent else { throw InspectorFixtureFailure.page }
            try Data([0xC3]).write(to: f.file)
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: f.controller.window))
            t.check(f.controller.readError != nil && f.controller.deskElementInspector == nil)
            errorEvent(inspectorEvent)
            t.equal(f.editor.text, source)
            t.equal(f.editor.textRevision, current.snapshot.version)
            t.equal(try Data(contentsOf: f.file), Data([0xC3]))
            f.controller.window?.close()
            errorEvent(inspectorEvent); hiddenEvent(inspectorEvent); retained(inspectorEvent)
            t.check(!checking.isCurrent(current.snapshot))
            t.check(f.controller.deskInspector?.pageView.onEvent == nil)
            t.equal(f.editor.text, source)
            t.equal(f.editor.textRevision, current.snapshot.version)
            t.check(!f.editor.isDirty)
        }
    }

    private static func inspectorSourceTests(_ t: AppTestRunner) {
        t.suite("Desk: inspector editing: external bytes and failed source reads preserve dirty text base and undo") {
            let f = try fixture(t, text: inspectorText)
            f.editor.textView.insertText("// keep my typing\r\n", replacementRange: NSRange(location: f.editor.text.utf16.count, length: 0))
            t.check(settled(f))
            let dirty = inspectorText + "// keep my typing\r\n"
            t.equal(f.editor.text, dirty)
            t.check(f.editor.isDirty)
            _ = try showInspector(t, f)
            guard let pane = f.controller.deskInspector, let event = pane.pageView.onEvent,
                  let undo = f.editor.textView.undoManager else { throw InspectorFixtureFailure.page }
            let revision = f.editor.textRevision, selection = f.editor.textView.selectedRange()
            let undoName = undo.undoActionName, canUndo = undo.canUndo, canRedo = undo.canRedo
            let external = Data(("// changed outside\r\n" + inspectorText).utf8)
            try external.write(to: f.file)
            event(inspectorEvent)
            guard case .note(let changedNote)? = pane.pageView.page?.item("desk-inspector-feedback")?.kind else {
                return t.check(false, "the actual page must explain why changed source was rejected")
            }
            t.equal(changedNote.text, StudioText[.deskInspectorDiskChanged])
            t.equal(f.editor.text, dirty)
            t.equal(f.editor.textRevision, revision)
            t.equal(f.editor.textView.selectedRange(), selection)
            t.equal(f.editor.document(for: f.file)?.text, inspectorText)
            t.equal(try Data(contentsOf: f.file), external)
            let read = f.editor.readData
            defer { f.editor.readData = read }
            f.editor.readData = { _ in throw NSError(domain: "DeskInspectorTest", code: 1) }
            event(inspectorEvent)
            guard case .note(let unreadableNote)? = pane.pageView.page?.item("desk-inspector-feedback")?.kind else {
                return t.check(false, "the actual page must distinguish an unreadable source")
            }
            t.equal(unreadableNote.text, StudioText[.deskInspectorSourceUnavailable])
            t.equal(f.editor.text, dirty)
            t.equal(f.editor.textRevision, revision)
            t.equal(f.editor.document(for: f.file)?.text, inspectorText)
            t.equal(undo.undoActionName, undoName)
            t.equal(undo.canUndo, canUndo); t.equal(undo.canRedo, canRedo)
            t.check(f.editor.isDirty && f.controller.readError == nil, "a source guard does not reload or create a document read error")
            t.equal(try Data(contentsOf: f.file), external)
            f.editor.readData = read
            try Data(inspectorText.utf8).write(to: f.file)
            t.equal(f.editor.checkSourceUnchanged(for: f.file), .unchanged,
                    "restoring original bytes proves neither refusal replaced the old base with external bytes")
        }
    }

    private static func inspectorWindowDeliveryTests(_ t: AppTestRunner) {
        // Headless tests deliberately prohibit app activation. This qualifies complete NSWindow dispatch with
        // an explicit host visibility input; it does not qualify physical foreground or occlusion eligibility.
        t.suite("Desk: inspector editing: controlled host visibility full window delivery selects the canvas Rectangle and its code") {
            let source = inspectorText.replacingOccurrences(of: ".size(90, 70)", with: ".size(120, 90).fill(.blue)")
            let f = try fixture(t, text: source)
            guard let window = f.controller.window, let content = window.contentView,
                  let preview = f.controller.deskPreview, let checking = f.controller.deskChecking else {
                return t.check(false, "the actual code, preview and inspector window")
            }
            t.check(f.editor.reveal(range: NSRange(location: 0, length: 0), in: f.file))
            f.controller.setDeskInspectorShown(true)
            window.makeKeyAndOrderFront(nil)
            t.check(settled(f), "the actual window activation recheck must finish before native input")
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let snapshot = checking.snapshot
            let compiled = Desk.compile(snapshot.checked, catalog: snapshot.options.catalog)
            guard let hit = snapshot.elements().first(where: { $0.component == "Rectangle" }),
                  let scene = preview.scene, let rectangle = scene.elements.first(where: { compiled.elementRefs[$0.id] == hit.element }),
                  rectangle.visibility == .visible, rectangle.frame.width > 0, rectangle.frame.height > 0 else {
                return t.check(false, "current compiled source references must identify a real visible scene Rectangle")
            }
            t.check(f.controller.isDeskInspectorShown && preview.isInspecting)
            t.check(f.controller.deskElementInspector == nil && preview.inspectedElement == nil,
                    "the fixture begins on the info header with no selected element")
            let point = NSPoint(x: rectangle.frame.x + rectangle.frame.width / 2,
                                y: rectangle.frame.y + rectangle.frame.height / 2)
            let location = preview.canvas.convert(point, to: nil)
            let rootPoint = content.superview?.convert(location, from: nil) ?? location
            let target = content.hitTest(rootPoint)
            var ancestry: [String] = []
            var ancestor = target
            while let view = ancestor, ancestry.count < 8 {
                ancestry.append("\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) hidden=\(view.isHidden)")
                ancestor = view.superview
            }
            let diagnostic = "window=\(window.frame) occlusion=\(window.occlusionState.rawValue) point=\(point) location=\(location) rootPoint=\(rootPoint) content=\(content.frame) preview=\(preview.view.frame) clip=\(preview.scrollView.contentView.frame)/\(preview.scrollView.contentView.bounds) canvas=\(preview.canvas.frame)/\(preview.canvas.bounds) visibleRect=\(preview.canvas.visibleRect) hidden=\(preview.canvas.isHidden) state=\(preview.state) snapshot=\(snapshot.generation) hit=\(ancestry.joined(separator: " -> "))"
            guard target === preview.canvas else {
                return t.check(false, "the full window hit test must deliver the Rectangle center to the canvas: \(diagnostic)")
            }
            t.check(true, "the actual native window hierarchy hit the canvas")
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 2, clickCount: 1, pressure: 0) else {
                return t.check(false, "native mouse events in the actual window coordinates")
            }
            let revision = f.editor.textRevision
            // Feed the real notification contract before any controlled visibility. If this environment has
            // actually occluded the window, input must be rejected even though AppKit can route synthetic events.
            f.controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification,
                                                                    object: window))
            if !window.occlusionState.contains(.visible) {
                let selection = f.editor.textView.selectedRange()
                window.sendEvent(down)
                window.sendEvent(up)
                t.check(preview.inspectedElement == nil && f.controller.deskElementInspector == nil,
                        "real occlusion refuses the complete window click path: \(diagnostic)")
                t.equal(f.editor.textView.selectedRange(), selection)
                t.equal(f.editor.textRevision, revision)
            }
            // The existing preview fixtures use this same public host input to qualify event routing separately
            // from WindowServer visibility. No product visibility guard or process activation policy is changed.
            preview.setVisible(true)
            window.sendEvent(down)
            t.check(preview.inspectedElement == nil, "inspection selects on release")
            window.sendEvent(up)
            t.equal(preview.inspectedElement, hit.element, "the controlled-visible full window path must select the painted Rectangle: \(diagnostic)")
            t.equal(f.controller.deskElementInspector?.element, hit.element, "canvas selection opens that exact checked property page")
            t.equal(f.editor.textView.selectedRange(), NSRange(location: hit.callRange.start.offset, length: 0),
                    "canvas selection silently reveals the matching source call")
            t.equal(f.editor.text, source)
            t.equal(f.editor.textRevision, revision)
            t.check(!f.editor.isDirty && checking.isCurrent(snapshot), "native selection is not a document edit")
            t.equal(try Data(contentsOf: f.file), Data(source.utf8))
        }
    }
}
