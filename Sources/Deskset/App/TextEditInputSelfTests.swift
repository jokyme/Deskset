import AppKit
import DesksetCore

/// Native event translation, clipboard boundaries and owner-thread delivery for editable skin meters.
enum TextEditInputSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: TextEdit input: native navigation and undo keys") {
            t.equal(SkinView.keyInput(for: key(123)), .move(.left, selecting: false))
            t.equal(SkinView.keyInput(for: key(124, flags: .shift)), .move(.right, selecting: true))
            t.equal(SkinView.keyInput(for: key(123, flags: .option)), .move(.wordLeft, selecting: false))
            t.equal(SkinView.keyInput(for: key(124, flags: [.command, .shift])), .move(.lineEnd, selecting: true))
            t.equal(SkinView.keyInput(for: key(126, flags: .command)), .move(.documentStart, selecting: false))
            t.equal(SkinView.keyInput(for: key(125, flags: [.command, .shift])), .move(.documentEnd, selecting: true))
            t.equal(SkinView.keyInput(for: key(115)), .move(.lineStart, selecting: false))
            t.equal(SkinView.keyInput(for: key(119, flags: .shift)), .move(.lineEnd, selecting: true))
            t.equal(SkinView.keyInput(for: key(116)), .move(.pageUp, selecting: false))
            t.equal(SkinView.keyInput(for: key(121, flags: .shift)), .move(.pageDown, selecting: true))
            t.equal(SkinView.keyInput(for: key(51, flags: .option)), .deleteWordBackward)
            t.equal(SkinView.keyInput(for: key(117, flags: .option)), .deleteWordForward)
            t.equal(SkinView.keyInput(for: key(6, flags: .command, chars: "z")), .undo)
            t.equal(SkinView.keyInput(for: key(6, flags: [.command, .shift], chars: "Z")), nil,
                    "no undocumented redo shortcut")
            t.equal(SkinView.keyInput(for: key(0, flags: [.command, .capsLock], chars: "A")), .selectAll)
        }

        for threading in [SkinThreading.main, .engine, .pool] {
            t.suite("App: TextEdit input: native clipboard and undo actions, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var clipboard = "", writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { writes.append($0); clipboard = $0 })
                focus(t, c)
                c.view.keyDown(with: key(0, flags: .command, chars: "a"))
                c.view.keyDown(with: key(8, flags: .command, chars: "c"))
                drain(t, c)
                t.equal(clipboard, "alpha beta")
                t.equal(value(c, \.inputText), "alpha beta")
                t.equal(writes, ["alpha beta"])
                t.check(NSApp.sendAction(#selector(NSText.cut(_:)), to: c.view, from: nil))
                drain(t, c)
                t.equal(value(c, \.inputText), "")
                t.equal(clipboard, "alpha beta")
                t.check(NSApp.sendAction(Selector(("undo:")), to: c.view, from: nil))
                drain(t, c)
                t.equal(value(c, \.inputText), "alpha beta")
                t.check(NSApp.sendAction(#selector(NSText.selectAll(_:)), to: c.view, from: nil))
                clipboard = "replacement"
                t.check(NSApp.sendAction(#selector(NSText.paste(_:)), to: c.view, from: nil))
                drain(t, c)
                t.equal(value(c, \.inputText), "replacement")
                t.check(c.view.performKeyEquivalent(with: key(6, flags: .command, chars: "z")))
                drain(t, c)
                t.equal(value(c, \.inputText), "alpha beta")
                t.check(c.view.performKeyEquivalent(with: key(0, flags: .command, chars: "a")))
                t.check(c.view.performKeyEquivalent(with: key(8, flags: .command, chars: "c")))
                drain(t, c)
                t.equal(writes.last, "alpha beta")
            }

            t.suite("App: TextEdit input: cut followed immediately by paste restores its text, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var clipboard = "old clipboard", writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                focus(t, c)
                c.view.selectAll(nil)
                drain(t, c)
                let gate = threading == .main ? nil : SkinLifecycleSelfTests.Gate()
                gate?.hold(c.runtime.executor)
                c.view.keyDown(with: key(7, flags: .command, chars: "x"))
                c.view.keyDown(with: key(9, flags: .command, chars: "v"))
                gate?.open()
                drain(t, c)
                t.equal(value(c, \.inputText), "alpha beta", "paste uses the pending cut instead of stale clipboard data")
                t.equal(value(c, \.caretPosition), 10)
                t.equal(writes, ["alpha beta"])
                t.equal(clipboard, "alpha beta")
            }

            t.suite("App: TextEdit input: immediate paste uses the new copy before following edits, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var clipboard = "old clipboard", writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                focus(t, c)
                c.runtime.send(.bang(Bang(name: "textedit:select", args: ["Input", "0", "5"]), from: "", hops: 0))
                drain(t, c)
                t.equal(value(c, \.selectionRange), 0..<5)
                let gate = threading == .main ? nil : SkinLifecycleSelfTests.Gate()
                gate?.hold(c.runtime.executor)
                c.view.keyDown(with: key(8, flags: .command, chars: "c"))
                c.view.keyDown(with: key(125, flags: .command))
                c.view.keyDown(with: key(9, flags: .command, chars: "v"))
                c.view.keyDown(with: key(18, chars: "!"))
                gate?.open()
                drain(t, c)
                t.equal(value(c, \.inputText), "alpha betaalpha!", "copy, navigation, paste and typing stay in owner order")
                t.equal(value(c, \.caretPosition), 16)
                t.equal(writes, ["alpha"])
                t.equal(clipboard, "alpha")
            }

            t.suite("App: TextEdit input: immediate paste stays before a subsequent field switch, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading, secondInput: true) else { return }
                var clipboard = "old clipboard", writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                focus(t, c)
                c.view.selectAll(nil)
                drain(t, c)
                let gate = threading == .main ? nil : SkinLifecycleSelfTests.Gate()
                gate?.hold(c.runtime.executor)
                c.view.cut(nil)
                c.view.paste(nil)
                c.view.mouseDown(with: mouse(.leftMouseDown, c, x: 180, y: 75))
                c.view.mouseUp(with: mouse(.leftMouseUp, c, x: 180, y: 75))
                c.view.keyDown(with: key(18, chars: "!"))
                gate?.open()
                drain(t, c)
                t.equal(value(c, \.inputText), "alpha beta", "paste finishes in the field focused when it was queued")
                t.equal(value(c, \.isFocused), false)
                t.equal(value(c, \.inputText, meter: "Other"), "other!")
                t.equal(value(c, \.isFocused, meter: "Other"), true)
                t.equal(writes, ["alpha beta"])
            }

            t.suite("App: TextEdit input: an earlier copy reply cannot clear a later pending copy, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var clipboard = "old clipboard", writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                focus(t, c)
                c.runtime.send(.bang(Bang(name: "textedit:select", args: ["Input", "0", "5"]), from: "", hops: 0))
                drain(t, c)
                c.view.copy(nil)
                let gate = threading == .main ? nil : SkinLifecycleSelfTests.Gate()
                let copied = DispatchSemaphore(value: 0)
                if let gate {
                    c.runtime.executor.async { copied.signal() }
                    gate.hold(c.runtime.executor)
                }
                c.runtime.send(.bang(Bang(name: "textedit:select", args: ["Input", "6", "4"]), from: "", hops: 0))
                c.view.copy(nil)
                if gate != nil {
                    t.check(copied.wait(timeout: .now() + 2) == .success, "the first owner result reached the main queue")
                    t.check(AppSelfTest.spin { clipboard == "alpha" }, "the first reply arrives while the second copy is still queued")
                }
                c.view.keyDown(with: key(125, flags: .command))
                c.view.paste(nil)
                gate?.open()
                drain(t, c)
                t.equal(value(c, \.inputText), "alpha betabeta", "paste stays linked to the second copy")
                t.equal(clipboard, "beta")
                t.equal(writes, ["alpha", "beta"])
            }

            t.suite("App: TextEdit input: a no-selection copy keeps the external paste value, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var clipboard = "old clipboard", writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                focus(t, c)
                c.view.selectAll(nil)
                c.view.copy(nil)
                drain(t, c)
                t.equal(writes, ["alpha beta"])
                clipboard = "external"
                c.view.keyDown(with: key(125, flags: .command))
                drain(t, c)
                t.equal(value(c, \.selectionRange), 10..<10)
                let gate = threading == .main ? nil : SkinLifecycleSelfTests.Gate()
                gate?.hold(c.runtime.executor)
                c.view.copy(nil)
                c.view.paste(nil)
                gate?.open()
                drain(t, c)
                t.equal(value(c, \.inputText), "alpha betaexternal", "a nil copy result must not reuse the earlier successful copy")
                t.equal(clipboard, "external")
                t.equal(writes, ["alpha beta"], "an empty selection does not change the clipboard")
            }

            t.suite("App: TextEdit input: a password copy permits pasting external text, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading, extra: "Password=1\n") else { return }
                var clipboard = "external", writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                focus(t, c)
                c.view.selectAll(nil)
                drain(t, c)
                let gate = threading == .main ? nil : SkinLifecycleSelfTests.Gate()
                gate?.hold(c.runtime.executor)
                c.view.copy(nil)
                c.view.paste(nil)
                gate?.open()
                drain(t, c)
                t.equal(value(c, \.inputText), "external", "a blocked password copy falls back to the paste gesture's clipboard")
                t.equal(clipboard, "external")
                t.check(writes.isEmpty, "password contents never leave the meter")
            }

            t.suite("App: TextEdit input: a pending copy supplies paste when the clipboard was empty, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var clipboard: String?, writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                focus(t, c)
                c.view.selectAll(nil)
                drain(t, c)
                let gate = threading == .main ? nil : SkinLifecycleSelfTests.Gate()
                gate?.hold(c.runtime.executor)
                c.view.copy(nil)
                c.view.paste(nil)
                c.view.keyDown(with: key(18, chars: "!"))
                gate?.open()
                t.check(AppSelfTest.spin { value(c, \.inputText) == "alpha beta!" }, "nil clipboard does not drop a paste after pending copy")
                t.equal(clipboard, "alpha beta")
                t.equal(writes, ["alpha beta"])
            }

            t.suite("App: TextEdit input: a pending successful copy survives a following empty copy, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var clipboard = "old clipboard", writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                focus(t, c)
                c.view.selectAll(nil)
                drain(t, c)
                let gate = threading == .main ? nil : SkinLifecycleSelfTests.Gate()
                gate?.hold(c.runtime.executor)
                c.view.copy(nil)
                c.view.keyDown(with: key(125, flags: .command))
                c.view.copy(nil)
                c.view.paste(nil)
                c.view.keyDown(with: key(18, chars: "!"))
                gate?.open()
                t.check(AppSelfTest.spin { value(c, \.inputText) == "alpha betaalpha beta!" },
                        "the empty copy preserves the earlier pending successful copy")
                t.equal(clipboard, "alpha beta")
                t.equal(writes, ["alpha beta"], "only the successful copy writes")
            }

            t.suite("App: TextEdit input: pending clipboard copy crosses skin owners before target typing, \(threading)") {
                guard let (_, source) = try fixture(t, threading: .engine),
                      let (_, target) = try fixture(t, threading: threading) else { return }
                var clipboard: String?, writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                focus(t, source)
                source.view.selectAll(nil)
                drain(t, source)
                focus(t, target)
                target.view.selectAll(nil)
                drain(t, target)
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(source.runtime.executor)
                source.view.copy(nil)
                target.view.paste(nil)
                target.view.keyDown(with: key(18, chars: "!"))
                drain(t, target)
                t.equal(value(target, \.inputText), "alpha beta", "target typing waits behind unresolved cross-skin paste")
                gate.open()
                t.check(AppSelfTest.spin { value(target, \.inputText) == "alpha beta!" }, "paste resolves before the target's later typing")
                t.equal(value(source, \.inputText), "alpha beta")
                t.equal(clipboard, "alpha beta")
                t.equal(writes, ["alpha beta"])
            }

            for retire in [false, true] {
                t.suite("App: TextEdit input: \(retire ? "retiring" : "closing") cancels pending paste without blocking other skins, \(threading)") {
                    guard let (_, source) = try fixture(t, threading: .engine),
                          let (_, target) = try fixture(t, threading: threading),
                          let (_, continuing) = try fixture(t, threading: threading) else { return }
                    var clipboard = "old clipboard", writes: [String] = []
                    clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                    for c in [source, target, continuing] {
                        focus(t, c)
                        c.view.selectAll(nil)
                        drain(t, c)
                    }
                    let gate = SkinLifecycleSelfTests.Gate()
                    gate.hold(source.runtime.executor)
                    source.view.copy(nil)
                    target.view.paste(nil)
                    target.view.keyDown(with: key(18, chars: "!"))
                    // A copy after the pending paste must still answer when that editing owner is canceled.
                    target.view.copy(nil)
                    drain(t, target)
                    if retire { target.runtime.retireForLayout() }
                    else {
                        target.stop()
                        t.check(AppSelfTest.spin { target.hasClosed }, "close bypasses a pending paste barrier")
                    }
                    gate.open()
                    continuing.view.paste(nil)
                    continuing.view.keyDown(with: key(18, chars: "!"))
                    t.check(AppSelfTest.spin { value(continuing, \.inputText) == "alpha beta!" },
                            "a later skin's paste is not blocked by the canceled owner")
                    t.equal(value(target, \.inputText), "alpha beta", "the canceled target neither pastes nor types")
                    t.equal(clipboard, "alpha beta")
                    t.equal(writes, ["alpha beta"], "discarded copies never write")
                }
            }

            t.suite("App: TextEdit input: closing a pending paste completes patch and zoom requests, \(threading)") {
                guard let (_, source) = try fixture(t, threading: .engine),
                      let (_, target) = try fixture(t, threading: threading) else { return }
                var clipboard = "old clipboard", writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                for c in [source, target] {
                    focus(t, c)
                    c.view.selectAll(nil)
                    drain(t, c)
                }
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(source.runtime.executor)
                source.view.copy(nil)
                target.view.paste(nil)
                drain(t, target)
                var patchResults: [SkinPatchResult] = [], zoomCompletions = 0
                target.runtime.send(.patch(SourceBuffers()) { result, _ in
                    DispatchQueue.main.async { patchResults.append(result) }
                })
                target.runtime.send(.setZoom(percent: 150, completion: {
                    t.check(Thread.isMainThread)
                    zoomCompletions += 1
                }))
                target.stop()
                t.check(AppSelfTest.spin { target.hasClosed && patchResults.count == 1 && zoomCompletions == 1 },
                        "close completes both callbacks while the clipboard copy is still blocked")
                t.equal(patchResults, [.needsReload(.closed)])
                t.equal(zoomCompletions, 1)
                t.equal(value(target, \.inputText), "alpha beta")
                gate.open()
                source.view.paste(nil)
                source.view.keyDown(with: key(18, chars: "!"))
                t.check(AppSelfTest.spin { value(source, \.inputText) == "alpha beta!" }, "other owners still paste after the closed request callbacks")
                t.equal(writes, ["alpha beta"])
            }

            t.suite("App: TextEdit input: zoomed pointer selection never drags the skin, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                let frame = c.window.frame
                for zoom in [10, 100, 250, 500] {
                    c.runtime.send(.setZoom(percent: zoom, completion: nil))
                    drain(t, c)
                    let factor = c.runtime.snapshot.zoomFactor
                    let logical = c.view.logicalPoint(NSPoint(x: 25 * factor, y: 15 * factor))
                    t.close(logical.0, 25)
                    t.close(logical.1, 15)
                    c.view.mouseDown(with: mouse(.leftMouseDown, c, x: 14, y: 15))
                    t.check(!c.view.dragAllowed && !c.isDragPressActive, "field capture blocks window dragging")
                    c.view.mouseDragged(with: mouse(.leftMouseDragged, c, x: 600, y: 15))
                    c.view.mouseUp(with: mouse(.leftMouseUp, c, x: 600, y: 15))
                    drain(t, c)
                    t.check(value(c, \.selectionRange)?.isEmpty == false, "drag outside still extends selection")
                    t.equal(value(c, \.caretPosition), 10)
                    t.equal(value(c, \.isSelecting), false, "release outside ends capture")
                    t.equal(c.view.heldButtons, 0)
                    t.check(c.view.pointerPresses.isEmpty)
                    let anchor = value(c, \.selectionAnchor)
                    c.view.mouseDown(with: mouse(.leftMouseDown, c, x: 45, y: 15, flags: .shift))
                    c.view.mouseUp(with: mouse(.leftMouseUp, c, x: 45, y: 15, flags: .shift))
                    drain(t, c)
                    t.equal(value(c, \.selectionAnchor), anchor, "Shift click preserves the original anchor")
                    t.check(!c.view.dragAllowed)
                }
                t.equal(c.window.frame.origin.x, frame.origin.x, "selection does not move the skin horizontally")
                t.equal(c.window.frame.maxY, frame.maxY, "zoom preserves the top edge")
                t.check(SkinView.leftMouseDown(c, x: 14, y: 15, clickCount: 1, override: true),
                        "Command dragging still overrides the field")
            }

            t.suite("App: TextEdit input: custom mouse actions and wheel scrolling, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading, extra: "LeftMouseDownAction=[!SetVariable Down yes]\nLeftMouseUpAction=[!SetVariable Up yes]\n") else { return }
                c.view.mouseDown(with: mouse(.leftMouseDown, c, x: 18, y: 15))
                c.view.mouseUp(with: mouse(.leftMouseUp, c, x: 18, y: 15))
                drain(t, c)
                t.equal(c.runtime.exclusive { $0.variable("Down") }, "yes")
                t.equal(c.runtime.exclusive { $0.variable("Up") }, "yes")
                t.equal(value(c, \.isFocused), true)
                c.runtime.send(.bang(Bang(name: "textedit:settext", args: ["Input", "a\nb\nc\nd\ne\nf\ng\nh"]), from: "", hops: 0))
                c.runtime.send(.scroll(.scrollDown, x: 20, y: 15))
                c.runtime.send(.scroll(.scrollDown, x: 20, y: 15))
                drain(t, c)
                t.check((value(c, \.scrollLineOffset) ?? 0) > 0, "wheel changes the viewport")
                c.runtime.send(.scroll(.scrollUp, x: 20, y: 15))
                drain(t, c)
                t.equal(value(c, \.scrollLineOffset), 1)
            }

            t.suite("App: TextEdit input: bang focus and loss redraw an Update=-1 skin, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var focuses = 0
                c.willFocusTextEdit = { focuses += 1 }
                defer { c.willFocusTextEdit = nil }
                focus(t, c)
                t.equal(focuses, 1, "a bang requests native keyboard focus")
                t.check(c.runtime.snapshot.hasFocusedTextEdit)
                c.runtime.send(.key(.insert("!")))
                drain(t, c)
                t.equal(focuses, 1, "typing does not repeatedly take native focus")
                let updates = c.runtime.snapshot.updateCount
                let wasVisible = value(c, \.caretVisible)
                t.check(AppSelfTest.spin(timeout: 2) { value(c, \.caretVisible) != wasVisible }, "caret blinks with no update timer")
                t.equal(c.runtime.snapshot.updateCount, updates)
                c.runtime.send(.focus(false))
                drain(t, c)
                t.equal(value(c, \.isFocused), false)
                t.check(!c.runtime.snapshot.hasFocusedTextEdit)
                let generation = c.runtime.exclusive { $0.meter(named: "Input")?.drawGeneration }
                let until = Date().addingTimeInterval(0.6)
                t.check(AppSelfTest.spin { Date() >= until })
                t.equal(c.runtime.exclusive { $0.meter(named: "Input")?.drawGeneration }, generation,
                        "unfocused field has no caret work")
                t.equal(c.runtime.snapshot.updateCount, updates)
                focus(t, c)
                t.equal(focuses, 2)
                c.runtime.send(.pause)
                drain(t, c)
                let pausedCaret = value(c, \.caretVisible)
                let pausedUntil = Date().addingTimeInterval(0.6)
                t.check(AppSelfTest.spin { Date() >= pausedUntil })
                t.equal(value(c, \.caretVisible), pausedCaret, "sleep pauses the caret timer")
                c.runtime.send(.resume(updateNow: true))
                drain(t, c)
                t.check(AppSelfTest.spin(timeout: 2) { value(c, \.caretVisible) != pausedCaret })
                t.equal(c.runtime.snapshot.updateCount, updates, "resuming never updates an Update=-1 skin")
            }
        }

        t.suite("App: TextEdit input: password and readonly clipboard operations") {
            for extra in ["Password=1\n", "ReadOnly=1\n"] {
                guard let (_, c) = try fixture(t, extra: extra) else { return }
                var clipboard = "changed", written: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; written.append($0) })
                focus(t, c)
                c.view.selectAll(nil)
                c.view.copy(nil)
                c.view.cut(nil)
                c.view.paste(nil)
                drain(t, c)
                if extra.hasPrefix("Password") { t.check(written.isEmpty, "password never leaves the field") }
                else { t.equal(written, ["alpha beta"], "readonly permits copying") }
                if extra.hasPrefix("ReadOnly") { t.equal(value(c, \.inputText), "alpha beta") }
            }
        }

        for threading in [SkinThreading.engine, .pool] {
            t.suite("App: TextEdit input: a queued click precedes clipboard commands, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var clipboard = "queued", writes: [String] = []
                clipboardSeams(t, read: { clipboard }, write: { clipboard = $0; writes.append($0) })
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(c.runtime.executor)
                t.check(!c.runtime.snapshot.hasFocusedTextEdit)
                c.view.mouseDown(with: mouse(.leftMouseDown, c, x: 180, y: 15))
                c.view.mouseUp(with: mouse(.leftMouseUp, c, x: 180, y: 15))
                c.view.keyDown(with: key(0, flags: .command, chars: "a"))
                c.view.keyDown(with: key(8, flags: .command, chars: "c"))
                c.view.keyDown(with: key(9, flags: .command, chars: "v"))
                gate.open()
                drain(t, c)
                t.equal(value(c, \.inputText), "alpha beta", "paste follows the queued focus, selection and copy")
                t.equal(writes, ["alpha beta"], "copy reads selection when its message executes")
            }

            t.suite("App: TextEdit input: retired and closed queued clipboard cannot write, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var writes: [String] = []
                clipboardSeams(t, read: { "new" }, write: { writes.append($0) })
                focus(t, c)
                c.view.selectAll(nil)
                drain(t, c)
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(c.runtime.executor)
                c.view.copy(nil)
                c.runtime.retireForLayout()
                gate.open()
                drain(t, c)
                t.check(writes.isEmpty)
                c.stop()
                drain(t, c)
                var replied = false
                c.runtime.send(.textEditClipboard(cut: false) { value in
                    DispatchQueue.main.async {
                        t.equal(value, nil)
                        replied = true
                    }
                })
                t.check(AppSelfTest.spin { replied }, "closed owner answers without reading a retired field")
                t.check(writes.isEmpty)
            }

            t.suite("App: TextEdit input: late clipboard replies recheck lifetime, \(threading)") {
                guard let (_, c) = try fixture(t, threading: threading) else { return }
                var writes: [String] = []
                clipboardSeams(t, read: { "new" }, write: { writes.append($0) })
                focus(t, c)
                c.view.selectAll(nil)
                drain(t, c)
                c.view.copy(nil)
                let copied = DispatchSemaphore(value: 0)
                c.runtime.executor.async { copied.signal() }
                t.check(copied.wait(timeout: .now() + 2) == .success, "owner copied while main-thread reply still waits")
                c.runtime.retireForLayout()
                drain(t, c)
                t.check(writes.isEmpty, "a retired view cannot publish a stale copy result")
            }
        }
    }

    private static func fixture(_ t: AppTestRunner, threading: SkinThreading = .main,
                                extra: String = "", secondInput: Bool = false) throws -> (AppController, SkinWindowController)? {
        guard let app = try AppSelfTest.makeApp(t, threading: threading) else { return nil }
        t.atSuiteEnd { app.stopAllForTermination(); app.endEngineThread() }
        let folder = app.skinsDirectory.appendingPathComponent("TextEditInput", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var definition = """
        [Rainmeter]
        Update=-1
        [Variables]
        Down=no
        Up=no
        [Input]
        Meter=TextEdit
        X=10
        Y=10
        W=180
        H=42
        FontFace=Arial
        FontSize=12
        InitialText=alpha beta
        Multiline=1
        \(extra)
        """
        if secondInput {
            definition += """

            [Other]
            Meter=TextEdit
            X=10
            Y=70
            W=180
            H=42
            FontFace=Arial
            FontSize=12
            InitialText=other
            Multiline=1

            """
        }
        try definition.write(to: folder.appendingPathComponent("Input.ini"), atomically: true, encoding: .utf8)
        app.rescanLibrary()
        guard let c = app.activate(config: "TextEditInput", file: "Input.ini"),
              AppSelfTest.spin(until: { c.isStarted }) else { t.check(false, "input fixture starts"); return nil }
        return (app, c)
    }

    private static func focus(_ t: AppTestRunner, _ c: SkinWindowController) {
        t.check(c.window.makeFirstResponder(c.view))
        c.runtime.send(.bang(Bang(name: "textedit:focus", args: ["Input"]), from: "", hops: 0))
        drain(t, c)
        t.equal(value(c, \.isFocused), true)
    }

    private static func value<T>(_ c: SkinWindowController, _ path: KeyPath<TextEditMeter, T>, meter: String = "Input") -> T? {
        c.runtime.exclusive { ($0.meter(named: meter) as? TextEditMeter).map { $0[keyPath: path] } } ?? nil
    }

    private static func drain(_ t: AppTestRunner, _ c: SkinWindowController) {
        var done = false
        c.runtime.whenCaughtUp { done = true }
        t.check(AppSelfTest.spin { done })
    }

    private static func clipboardSeams(_ t: AppTestRunner, read: @escaping () -> String?, write: @escaping (String) -> Void) {
        let oldRead = SkinView.readTextEditClipboard, oldWrite = SkinView.writeTextEditClipboard
        SkinView.readTextEditClipboard = { t.check(Thread.isMainThread); return read() }
        SkinView.writeTextEditClipboard = { t.check(Thread.isMainThread); write($0) }
        t.atSuiteEnd {
            SkinView.readTextEditClipboard = oldRead
            SkinView.writeTextEditClipboard = oldWrite
        }
    }

    private static func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                         keyCode: code)!
    }

    private static func mouse(_ type: NSEvent.EventType, _ c: SkinWindowController, x: Double, y: Double,
                              flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let factor = c.runtime.snapshot.zoomFactor
        let location = c.view.convert(NSPoint(x: x * factor, y: y * factor), to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0,
                                  windowNumber: c.window.windowNumber, context: nil, eventNumber: 1,
                                  clickCount: 1, pressure: 1)!
    }
}
