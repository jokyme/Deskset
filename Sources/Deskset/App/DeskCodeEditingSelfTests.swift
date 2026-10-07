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
}
