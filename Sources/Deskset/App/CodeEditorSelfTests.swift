import AppKit
import DesksetCore

/// `Deskset --self-test "code editor"`: the built-in code editor (CodeEditorView). Headless: editors are never put in a
/// visible window (the focus and ⌘S checks use an off-screen window that is never ordered in); files live in
/// temporary folders. Text is typed through the text view the way keyboard input arrives (`insertText`,
/// `insertNewline`), so undo registration, dirty tracking and the commit triggers run as they do for the user.
enum CodeEditorSelfTests {
    static func run(_ t: AppTestRunner) {
        openTests(t)
        layoutTests(t)
        commitTests(t)
        lineEndingTests(t)
        caretTests(t)
        silentAPITests(t)
        reloadTests(t)
        undoTests(t)
        triggerTests(t)
        encodingTests(t)
        retentionTests(t)
        fontTests(t)
    }

    // MARK: Fixtures

    /// 16 lines, CRLF. Sections: Rainmeter (2), Variables (5), MeasureCPU (9), MeterText (12).
    static let mainText = """
        ; Test skin
        [Rainmeter]
        Update=1000

        [Variables]
        Color=255,0,0

        ; the processor
        [MeasureCPU]
        Measure=CPU

        [MeterText]
        Meter=String
        MeasureName=MeasureCPU
        Text=CPU %1%
        LeftMouseUpAction=[!Refresh]
        """.replacingOccurrences(of: "\n", with: "\r\n")

    /// LF; line 2 is before any header.
    static let includeText = "; vars\nColor2=1\n[Variables]\nSize=10\n"

    /// What the host callbacks received.
    final class Recorder {
        var commits: [(url: URL, text: String)] = []
        var carets: [(url: URL, section: String?)] = []
        var fileChanges: [URL] = []
        var fontSizes: [CGFloat] = []
        /// What `onCommit` returns.
        var accept = true
    }

    struct Fixture {
        let editor: CodeEditorView
        let main: URL
        let include: URL
        let recorder: Recorder
    }

    /// A skin folder with Skin.ini (`mainBytes`, default `mainText` as UTF-8) and Vars.inc, opened in an editor whose
    /// `onCommit` writes like the host would (the file's encoding and line endings kept).
    static func makeFixture(_ t: AppTestRunner, mainBytes: Data? = nil, writes: Bool = true) throws -> Fixture {
        let dir = t.temporaryDirectory("code-editor")
        let main = dir.appendingPathComponent("Skin.ini")
        let include = dir.appendingPathComponent("Vars.inc")
        try (mainBytes ?? Data(mainText.utf8)).write(to: main)
        try Data(includeText.utf8).write(to: include)
        let editor = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        editor.layoutSubtreeIfNeeded()
        let recorder = Recorder()
        editor.onCommit = { [weak editor] url, text in
            recorder.commits.append((url, text))
            guard recorder.accept else { return false }
            if writes, let data = editor?.document(for: url)?.data(for: text) {
                try? data.write(to: CodeDocument.writeTarget(for: url))
            }
            return true
        }
        editor.onCaretSection = { recorder.carets.append(($0, $1)) }
        editor.onFileChange = { recorder.fileChanges.append($0) }
        editor.onFontSizeChange = { recorder.fontSizes.append($0) }
        try editor.open(files: [main, include], current: main)
        return Fixture(editor: editor, main: main.standardizedFileURL, include: include.standardizedFileURL,
                       recorder: recorder)
    }

    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Types `text` at `location` (or the caret) through the text view, as keyboard input does.
    static func type(_ editor: CodeEditorView, _ text: String, at location: Int? = nil) {
        if let location { editor.textView.setSelectedRange(NSRange(location: location, length: 0)) }
        editor.textView.insertText(text, replacementRange: editor.textView.selectedRange())
    }

    /// The UTF-16 range of a 1-based line of the editor's current text.
    static func line(_ editor: CodeEditorView, _ number: Int) -> NSRange {
        CodeDocument(text: editor.text).range(ofLine: number)
    }

    static func keyEvent(_ characters: String, _ flags: NSEvent.ModifierFlags, window: NSWindow? = nil) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)
    }

    static func color(_ editor: CodeEditorView, at index: Int) -> NSColor? {
        editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                          effectiveRange: nil) as? NSColor
    }

    /// Runs `body`, ending the run with a failure when it has not returned after `seconds`: a layout loop never
    /// returns, and a hung run tells nobody which suite it was in.
    static func failing(ifStuckIn what: String, after seconds: Int = 20, _ body: () throws -> Void) rethrows {
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + .seconds(seconds))
        watchdog.setEventHandler {
            print("    ✗ code editor: \(what) did not return within \(seconds) s")
            fflush(stdout)
            _exit(1)
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        try body()
    }

    // MARK: Opening

    static func openTests(_ t: AppTestRunner) {
        t.suite("App: code editor opens a skin and its includes") {
            let f = try makeFixture(t)
            let e = f.editor
            t.equal(e.files, [f.main, f.include])
            t.equal(e.currentFile, f.main)
            t.equal(e.text, mainText)
            t.check(!e.isDirty && !e.hasUncommittedChanges)
            t.equal(e.document(for: f.main)?.lineEnding, .crlf)
            t.equal(e.document(for: f.include)?.lineEnding, .lf)

            let tv = e.textView
            t.check(tv.textLayoutManager == nil && tv.layoutManager != nil, "TextKit 1")
            t.check(!tv.isAutomaticQuoteSubstitutionEnabled && !tv.isAutomaticDashSubstitutionEnabled
                    && !tv.isAutomaticTextReplacementEnabled && !tv.isAutomaticSpellingCorrectionEnabled
                    && !tv.isContinuousSpellCheckingEnabled && !tv.isGrammarCheckingEnabled
                    && !tv.isAutomaticDataDetectionEnabled && !tv.isAutomaticLinkDetectionEnabled
                    && !tv.smartInsertDeleteEnabled && !tv.isRichText, "code-safe text settings")
            t.check(tv.usesFindBar && tv.isIncrementalSearchingEnabled, "find bar")
            t.check(tv.textContainer?.widthTracksTextView == true && !tv.isHorizontallyResizable, "soft wrap")
            t.check(tv.font?.isFixedPitch == true, "monospaced")
            t.equal(tv.font?.pointSize, CodeEditorView.defaultFontSize)
            t.check(e.scrollView.verticalRulerView === e.ruler && e.scrollView.rulersVisible, "line numbers")
            t.check(e.ruler.clipsToBounds, "the ruler clips (macOS 14 default change)")
            t.check(e.ruler.ruleThickness > 20)

            // Highlighting is applied on load as temporary attributes.
            t.check(color(e, at: 0) === CodeEditorTheme.comment, "comment")
            let header = (mainText as NSString).range(of: "[Rainmeter]")
            t.check(color(e, at: header.location) === CodeEditorTheme.sectionHeader, "header")
            let type = (mainText as NSString).range(of: "CPU\r\n")
            t.check(color(e, at: type.location) === CodeEditorTheme.typeName, "Measure= type")
            let bang = (mainText as NSString).range(of: "[!Refresh]")
            t.check(color(e, at: bang.location) === CodeEditorTheme.bang, "bang")
            t.check(e.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                    == NSColor.textColor, "the text itself is not colored")

            // Jump bar: files with the main file selected, sections of the buffer.
            t.equal(e.filePopUp.itemTitles, ["Skin.ini", "Vars.inc"])
            t.equal(e.filePopUp.indexOfSelectedItem, 0)
            if let menu = e.sectionPopUp.menu {
                menu.delegate?.menuNeedsUpdate?(menu)
                t.equal(Array(menu.items.dropFirst().map(\.title)), ["Rainmeter", "Variables", "MeasureCPU", "MeterText"])
                t.equal(menu.items.last?.representedObject as? Int, 12, "items jump to their header line")
            }
            t.equal(e.sectionPopUp.item(at: 0)?.title, "Rainmeter", "the caret's section")

            // A missing include is left out; a missing current file throws.
            let other = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            let missing = f.main.deletingLastPathComponent().appendingPathComponent("Missing.inc")
            try other.open(files: [f.main, missing], current: f.main)
            t.equal(other.files, [f.main])
            t.check((try? other.open(files: [], current: missing)) == nil, "a missing current file throws")
            t.equal(other.currentFile, f.main, "a failed open changes nothing")
        }
    }

    // MARK: Layout

    static func layoutTests(_ t: AppTestRunner) {
        t.suite("App: code editor lays out text taller than the pane with legacy scrollers") {
            // With a mouse connected (or Show scroll bars set to Always) scrollers take room from the text. A scroller
            // that came and went with the text's height narrowed the text; re-wrapping made the non-contiguous layout
            // estimate it shorter than the pane, which hid the scroller again, and so on: `ensureLayout` never
            // returned while the editor was not on screen (the code window opens its file before it has a window).
            // The scroller style is set here as AppKit sets it on such a Mac, whatever this one has.
            let dir = t.temporaryDirectory("code-editor-scroller")
            let short = dir.appendingPathComponent("Short.inc")
            let tall = dir.appendingPathComponent("Tall.ini")
            try Data("[Variables]\r\nSize=10\r\n".utf8).write(to: short)
            // 40 lines: taller than the pane, and short enough to be estimated shorter than it after a re-wrap.
            let tallText = (1...20).map { "[Section\($0)]\r\nValue=\($0)" }.joined(separator: "\r\n")
            try Data(tallText.utf8).write(to: tall)
            let e = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            e.scrollView.scrollerStyle = .legacy
            e.layoutSubtreeIfNeeded()
            let clip = e.scrollView.contentView
            try e.open(files: [short, tall], current: short)
            t.check(e.scrollView.verticalScroller?.isHidden == false, "the scroller keeps its room while everything fits")
            // One that comes and goes would loop below.
            guard e.scrollView.verticalScroller?.isHidden == false else { return }
            let width = e.textView.frame.width

            try failing(ifStuckIn: "showing a file taller than the pane") {
                e.show(file: tall)
                t.equal(e.textView.frame.width, width, "the text keeps its width")
                e.reveal(line: 40, in: tall, select: false)
                let last = e.textView.lineRect(forCharacterRange: line(e, 40)) ?? .zero
                t.check(clip.bounds.minY > 0 && clip.bounds.contains(NSPoint(x: 1, y: last.midY)),
                        "\(last) in \(clip.bounds)")
                t.check(e.textView.frame.height >= last.maxY, "the text view holds the text")
                t.equal(e.textView.frame.width, width)

                // The scroll position survives a file switch, clear of the line numbers.
                let scrolled = clip.bounds.origin
                e.show(file: short)
                t.close(clip.bounds.minY, 0)
                e.show(file: tall)
                t.close(clip.bounds.minY, scrolled.y, "restored")
                t.close(clip.bounds.minX, clip.constrainBoundsRect(clip.bounds).minX, "not under the line numbers")

                // A reload keeps it too, in another font size (the line numbers grow with it).
                e.setFontSize(13)
                let before = clip.bounds.origin
                let widthAt13 = e.textView.frame.width
                try Data((tallText + "\r\n; more").utf8).write(to: tall)
                e.reloadFromDisk(keepCaret: true)
                t.check(e.text.hasSuffix("; more"))
                t.close(clip.bounds.minY, before.y, "kept on reload")
                t.equal(e.textView.frame.width, widthAt13)
            }

            // An editor that has no size yet (still being laid out) opens and scrolls without looping as well.
            let unsized = CodeEditorView(frame: .zero)
            unsized.scrollView.scrollerStyle = .legacy
            try failing(ifStuckIn: "opening in an editor without a size") {
                try unsized.open(files: [tall], current: tall)
                unsized.reveal(line: 40, in: tall, select: false)
                unsized.setFrameSize(NSSize(width: 600, height: 300))
                unsized.layoutSubtreeIfNeeded()
                unsized.reveal(line: 40, in: tall, select: false)
                let visible = unsized.scrollView.contentView.bounds
                let last = unsized.textView.lineRect(forCharacterRange: line(unsized, 40)) ?? .zero
                t.check(visible.contains(NSPoint(x: 1, y: last.midY)), "\(last) in \(visible)")
                t.check(unsized.textView.frame.maxX <= visible.maxX + 0.5, "the text is not under the scroller")
            }
        }
    }

    // MARK: Commits

    static func commitTests(_ t: AppTestRunner) {
        t.suite("App: code editor commits typed text") {
            let f = try makeFixture(t)
            let e = f.editor
            type(e, "0", at: NSMaxRange(line(e, 3)))
            t.check(e.isDirty && e.isDirty(f.main) && !e.isDirty(f.include))
            t.check(f.recorder.commits.isEmpty, "typing alone does not commit")
            t.check(e.filePopUp.item(at: 0)?.image === CodeEditorTheme.dirtyDot, "dirty dot")
            t.check(e.commitNow())
            t.equal(f.recorder.commits.count, 1)
            t.equal(f.recorder.commits.first?.url, f.main)
            t.equal(f.recorder.commits.first?.text, mainText.replacingOccurrences(of: "Update=1000", with: "Update=10000"))
            t.check(!e.isDirty)
            t.check(e.filePopUp.item(at: 0)?.image === CodeEditorTheme.cleanDot, "clean again")
            t.equal(try Data(contentsOf: f.main), Data(e.text.utf8), "CRLF kept byte for byte")
            t.equal(e.document(for: f.main)?.text, e.text, "the committed text is the new clean state")
            t.check(e.commitNow())
            t.equal(f.recorder.commits.count, 1, "nothing to commit")

            // Typing and deleting back to the committed text is clean without a commit.
            type(e, "x", at: 0)
            t.check(e.isDirty)
            e.textView.deleteBackward(nil)
            t.check(!e.isDirty, "back to the clean text")
        }

        t.suite("App: code editor tolerates host calls during a commit") {
            let f = try makeFixture(t)
            let e = f.editor
            var nested: [Bool] = []
            let write = e.onCommit
            e.onCommit = { [weak e] url, text in
                // A host commits dirty code before its own edits, and reloads after its refresh.
                nested.append(e?.commitNow() ?? false)
                let ok = write?(url, text) ?? false
                e?.reloadFromDisk(keepCaret: true)
                return ok
            }
            type(e, "7", at: NSMaxRange(line(e, 3)))
            t.check(e.commitNow())
            t.equal(nested, [true], "the nested request is the running commit")
            t.check(!e.isDirty)
            t.equal(e.text, mainText.replacingOccurrences(of: "Update=1000", with: "Update=10007"))
            t.check(e.textView.undoManager?.canUndo == true, "the reload found the committed text: undo kept")
        }

        t.suite("App: code editor commits after an idle pause") {
            let f = try makeFixture(t)
            let e = f.editor
            t.equal(e.idleCommitDelay, 0.8, "about a second of rest by default")
            // A long pause for the checks that nothing is committed yet (a slow machine must not reach it); the
            // commit itself is fired below instead of waited for.
            e.idleCommitDelay = 600
            type(e, "A", at: NSMaxRange(line(e, 15)))
            guard let first = e.idleCommitDate else { return t.check(false, "a commit is scheduled after typing") }
            t.close(first.timeIntervalSinceNow, 600, accuracy: 30, "for the pause after the keystroke")
            spin(0.02)
            t.equal(f.recorder.commits.count, 0, "still typing")
            type(e, "B")
            t.check((e.idleCommitDate ?? .distantPast) > first, "the pause restarts with every keystroke")
            t.equal(f.recorder.commits.count, 0)
            t.check(e.fireIdleCommit(), "the pause ends")
            t.equal(f.recorder.commits.count, 1)
            t.check(f.recorder.commits.last?.text.contains("Text=CPU %1%AB") == true)
            t.check(!e.isDirty)
            t.equal(e.idleCommitDate, nil, "nothing more to commit")
            // Once for real, with a short pause: the timer commits by itself.
            e.idleCommitDelay = 0.05
            type(e, "C")
            t.check(AppSelfTest.spin(timeout: 10) { f.recorder.commits.count == 2 }, "committed by the timer")
            t.check(!e.isDirty)
        }

        t.suite("App: code editor keeps a refused commit dirty") {
            let f = try makeFixture(t)
            let e = f.editor
            f.recorder.accept = false
            type(e, "1", at: NSMaxRange(line(e, 3)))
            t.check(!e.commitNow())
            t.check(e.isDirty, "still dirty")
            t.equal(try String(contentsOf: f.main, encoding: .utf8), mainText, "nothing written")
            f.recorder.accept = true
            t.check(e.commitNow())
            t.check(!e.isDirty)
        }

        t.suite("App: code editor writes the file itself without a host") {
            var bytes: [UInt8] = [0xFF, 0xFE]
            for unit in mainText.utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            let f = try makeFixture(t, mainBytes: Data(bytes))
            let e = f.editor
            e.onCommit = nil
            t.equal(e.document(for: f.main)?.encoding, .utf16LittleEndian(bom: true))
            t.equal(e.text, mainText)
            type(e, "é", at: NSMaxRange(line(e, 15)))
            t.check(e.commitNow())
            let expected = mainText.replacingOccurrences(of: "CPU %1%", with: "CPU %1%é")
            var expectedBytes: [UInt8] = [0xFF, 0xFE]
            for unit in expected.utf16 { expectedBytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            t.equal(try Data(contentsOf: f.main), Data(expectedBytes), "UTF-16 LE with BOM and CRLF kept")

            // A symlinked skin file: the target gets the edit, the link stays.
            let dir = f.main.deletingLastPathComponent()
            let linkedDir = t.temporaryDirectory("code-editor-link")
            let link = linkedDir.appendingPathComponent("Linked.ini")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.main)
            try e.open(files: [link], current: link)
            type(e, "!", at: 0)
            t.check(e.commitNow())
            let kind = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
            t.equal(kind, .typeSymbolicLink, "the link is still a link")
            t.equal(try CodeDocument.load(dir.appendingPathComponent("Skin.ini")).text, "!" + expected,
                    "the target was written")
        }
    }

    // MARK: Line endings

    static func lineEndingTests(_ t: AppTestRunner) {
        t.suite("App: code editor Return uses the file's line ending") {
            let f = try makeFixture(t)
            let e = f.editor
            e.textView.setSelectedRange(NSRange(location: NSMaxRange(line(e, 3)), length: 0))
            e.textView.insertNewline(nil)
            type(e, "AccurateText=1")
            let expected = mainText.replacingOccurrences(of: "Update=1000\r\n", with: "Update=1000\r\nAccurateText=1\r\n")
            t.equal(e.text, expected, "CRLF in a CRLF file")

            // Pasted text takes the file's line ending too.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("DesksetCodeEditorTest-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString("A=1\nB=2\rC=3", forType: .string)
            e.textView.setSelectedRange(NSRange(location: NSMaxRange(line(e, 4)), length: 0))
            t.check(e.textView.readSelection(from: pasteboard, type: .string))
            t.check(e.text.contains("AccurateText=1A=1\r\nB=2\r\nC=3\r\n"), "pasted: \(e.text.debugDescription)")
            t.check(e.commitNow())
            let written = try Data(contentsOf: f.main)
            t.check(!zip(written, written.dropFirst()).contains { $0.1 == 0x0A && $0.0 != 0x0D }, "no lone LF on disk")

            // An LF file gets LF.
            e.show(file: f.include)
            t.equal(e.currentFile, f.include)
            e.textView.setSelectedRange(NSRange(location: NSMaxRange(line(e, 4)), length: 0))
            e.textView.insertNewline(nil)
            t.equal(e.text, includeText.replacingOccurrences(of: "Size=10\n", with: "Size=10\n\n"))
            t.equal(CodeTextView.convertingLineEndings("a\r\nb\rc\nd", to: "\n"), "a\nb\nc\nd")
            t.equal(CodeTextView.convertingLineEndings("a\nb", to: "\r\n"), "a\r\nb")
        }
    }

    // MARK: Caret

    static func caretTests(_ t: AppTestRunner) {
        t.suite("App: code editor reports where the caret rests") {
            let f = try makeFixture(t)
            let e = f.editor
            let r = f.recorder
            t.equal(e.caretRestDelay, 0.15, "a short rest by default")
            // Rests are fired below instead of waited for (a long delay, so none happens on its own).
            e.caretRestDelay = 600
            t.check(!e.fireCaretRest(), "opening is not a caret move")
            t.equal(r.carets.count, 0)

            e.textView.setSelectedRange(NSRange(location: line(e, 13).location + 3, length: 0))
            t.equal(r.carets.count, 0, "waits for the caret to rest")
            t.check(e.fireCaretRest())
            t.equal(r.carets.map(\.section), ["MeterText"])
            t.equal(r.carets.last?.url, f.main)
            t.equal(e.sectionPopUp.item(at: 0)?.title, "MeterText", "the jump bar follows")

            e.textView.setSelectedRange(NSRange(location: line(e, 10).location, length: 0))
            e.textView.setSelectedRange(NSRange(location: line(e, 11).location, length: 0))
            e.fireCaretRest()
            t.equal(r.carets.map(\.section), ["MeterText", "MeasureCPU"], "one report per rest")

            type(e, "Processor=0")
            e.fireCaretRest()
            t.equal(r.carets.count, 2, "typing in the same section is not reported again")

            e.textView.moveDown(nil)
            e.fireCaretRest()
            t.equal(r.carets.last?.section, "MeterText", "arrow keys: line 12 is the header of MeterText")

            e.textView.setSelectedRange(NSRange(location: line(e, 8).location, length: 0))
            e.fireCaretRest()
            t.equal(r.carets.last?.section, "MeasureCPU", "the comment right above a header belongs to it")
            t.equal(e.caretLine, 8)
            t.equal(e.caretSection, "MeasureCPU")

            // The section pop-up and the line numbers move the caret as the user.
            if let menu = e.sectionPopUp.menu { menu.delegate?.menuNeedsUpdate?(menu) }
            e.sectionPopUp.selectItem(at: 2)
            e.sectionPopUp.sendAction(e.sectionPopUp.action, to: e.sectionPopUp.target)
            t.equal(e.caretLine, 5, "jumped to [Variables]")
            e.fireCaretRest()
            t.equal(r.carets.last?.section, "Variables")
            e.selectLine(containingOffset: line(e, 3).location + 2)
            t.equal(e.textView.selectedRange(), line(e, 3), "a click on a line number selects the line")
            e.fireCaretRest()
            t.equal(r.carets.last?.section, "Rainmeter")

            e.show(file: f.include)
            e.textView.setSelectedRange(NSRange(location: line(e, 2).location, length: 0))
            e.fireCaretRest()
            t.equal(r.carets.last?.url, f.include)
            t.check(r.carets.last.map { $0.section == nil } == true, "before the first header")

            // Once for real, with a short rest: the timer reports by itself.
            e.caretRestDelay = 0.05
            e.textView.setSelectedRange(NSRange(location: 0, length: 0))
            let count = r.carets.count
            t.check(AppSelfTest.spin(timeout: 10) { r.carets.count == count + 1 }, "reported by the timer")
        }
    }

    static func silentAPITests(_ t: AppTestRunner) {
        t.suite("App: code editor API changes are not reported") {
            let f = try makeFixture(t)
            let e = f.editor
            let r = f.recorder
            e.caretRestDelay = 600
            e.reveal(line: 12, in: f.main, select: true)
            t.equal(e.textView.selectedRange(), line(e, 12), "select")
            let selection = e.textView.selectedRange()
            e.tintSection(lines: 12..<17)
            t.equal(e.textView.selectedRange(), selection, "tinting keeps the selection")
            t.check(e.textView.tintRange != nil)
            t.check(e.revealSection("MeasureCPU", in: f.main))
            t.equal(e.textView.tintRange, CodeDocument(text: e.text).range(ofLines: 9..<11))
            // The revealed section is where the caret goes (silently): the jump bar names it, arrows go on from it.
            t.equal(e.textView.selectedRange(), NSRange(location: line(e, 9).location, length: 0), "caret on the header")
            t.equal(e.sectionPopUp.item(at: 0)?.title, "MeasureCPU", "the jump bar names the revealed section")
            e.reveal(line: 14, in: f.main, select: false)
            t.equal(e.textView.selectedRange(), NSRange(location: line(e, 14).location, length: 0), "a revealed line too")
            t.equal(e.sectionPopUp.item(at: 0)?.title, "MeterText")
            t.check(!e.fireCaretRest(), "none of this is reported")
            t.check(!e.revealSection("Nope", in: f.main))
            t.equal(e.textView.tintRange, nil)
            e.setFontSize(14)
            e.reloadFromDisk(keepCaret: true)
            try e.open(files: [f.main, f.include], current: f.main)
            e.reveal(line: 2, in: f.include, select: false)
            t.equal(e.currentFile, f.include, "reveal switches files")
            t.check(!e.fireCaretRest(), "no caret rest pending")
            t.equal(r.carets.count, 0, "nothing reported")
            t.equal(r.fileChanges.count, 0, "API file switches are not reported")

            // After an API change, the next user move is reported even in the same section.
            e.show(file: f.main)
            e.textView.setSelectedRange(NSRange(location: line(e, 13).location, length: 0))
            e.fireCaretRest()
            e.revealSection("MeterText", in: f.main)
            e.textView.setSelectedRange(NSRange(location: line(e, 14).location, length: 0))
            e.fireCaretRest()
            t.equal(r.carets.map(\.section), ["MeterText", "MeterText"])

            // A user switch in the jump bar is reported (and commits the file it leaves).
            type(e, "x", at: 0)
            e.filePopUp.selectItem(at: 1)
            e.filePopUp.sendAction(e.filePopUp.action, to: e.filePopUp.target)
            t.equal(r.fileChanges, [f.include])
            t.equal(e.currentFile, f.include)
            t.equal(e.text, includeText)
            t.equal(r.commits.last?.url, f.main, "the file it left was committed")
            t.check(!e.isDirty(f.main))
        }

        t.suite("App: code editor reveal scrolls only when needed") {
            let dir = t.temporaryDirectory("code-editor-long")
            let url = dir.appendingPathComponent("Long.ini")
            let long = (1...300).map { "[S\($0)]\nX=\($0)" }.joined(separator: "\n")
            try Data(long.utf8).write(to: url)
            let e = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            e.layoutSubtreeIfNeeded()
            try e.open(files: [url], current: url)
            t.close(e.scrollView.contentView.bounds.minY, 0)
            e.reveal(line: 400, in: url, select: false)
            let target = e.textView.lineRect(forCharacterRange: line(e, 400)) ?? .zero
            let visible = e.scrollView.contentView.bounds
            t.check(visible.minY > 0 && visible.contains(NSPoint(x: 1, y: target.midY)), "\(target) in \(visible)")
            t.check(abs(target.midY - visible.midY) < target.height * 2, "centred")
            e.reveal(line: 401, in: url, select: false)
            t.equal(e.scrollView.contentView.bounds.minY, visible.minY, "already visible: not moved")
            t.equal(e.ruler.ruleThickness, e.ruler.requiredThickness)
        }
    }

    // MARK: Reload

    static func reloadTests(_ t: AppTestRunner) {
        t.suite("App: code editor reload keeps the caret") {
            let f = try makeFixture(t)
            let e = f.editor
            let caret = line(e, 13).location + 3
            e.textView.setSelectedRange(NSRange(location: caret, length: 0))
            type(e, "Z")
            t.check(e.commitNow())
            t.check(e.textView.undoManager?.canUndo == true)
            e.reloadFromDisk(keepCaret: true)
            t.check(e.textView.undoManager?.canUndo == true, "an unchanged file keeps the undo history")

            // Another app adds a line above the caret.
            let prefix = "; edited elsewhere\r\n"
            let changed = prefix + e.text
            try Data(changed.utf8).write(to: f.main)
            e.reloadFromDisk(keepCaret: true)
            t.equal(e.text, changed)
            t.equal(e.textView.selectedRange().location, caret + 1 + (prefix as NSString).length, "same place in the text")
            t.check(!e.isDirty)
            t.check(e.textView.undoManager?.canUndo == false, "undo history of the old text is gone")
            t.check(color(e, at: 0) === CodeEditorTheme.comment, "the new line is highlighted")
            t.check(color(e, at: (prefix as NSString).length) === CodeEditorTheme.comment, "and the old first line too")

            try Data(mainText.utf8).write(to: f.main)
            e.reloadFromDisk(keepCaret: false)
            t.equal(e.text, mainText)
            t.equal(e.textView.selectedRange(), NSRange(location: 0, length: 0))

            // A dirty buffer keeps its edits.
            type(e, "Q", at: 0)
            try Data((mainText + "\r\n").utf8).write(to: f.main)
            e.reloadFromDisk(keepCaret: true)
            t.equal(e.text, "Q" + mainText)
            t.check(e.isDirty)
            t.equal(e.document(for: f.main)?.text, mainText + "\r\n", "its clean state is the disk's")

            // Clean buffers of other files follow the disk.
            try Data("[Other]\n".utf8).write(to: f.include)
            e.reloadFromDisk(keepCaret: true)
            e.show(file: f.include)
            t.equal(e.text, "[Other]\n")
            t.equal(f.recorder.carets.count, 0, "reloads are silent")
        }
    }

    // MARK: Undo

    static func undoTests(_ t: AppTestRunner) {
        t.suite("App: code editor undo undoes typing only") {
            let f = try makeFixture(t)
            let e = f.editor
            guard let undo = e.textView.undoManager else {
                t.check(false, "the text view has an undo manager")
                return
            }
            t.check(!undo.canUndo, "opening is not undoable")
            e.tintSection(lines: 2..<4)
            e.reveal(line: 9, in: f.main, select: true)
            e.setFontSize(13)
            e.reloadFromDisk(keepCaret: true)
            t.check(!undo.canUndo, "tint, reveal, font and reload are not undoable")

            type(e, "abc", at: NSMaxRange(line(e, 3)))
            spin(0.02)
            t.check(undo.canUndo)
            undo.undo()
            t.equal(e.text, mainText, "typing undone")
            t.check(!e.isDirty)
            t.check(!undo.canUndo, "nothing before the typing")
            undo.redo()
            t.check(e.text.contains("Update=1000abc"))

            // Each file has its own history.
            e.show(file: f.include)
            let includeUndo = e.textView.undoManager
            t.check(includeUndo !== undo, "separate undo manager per file")
            t.check(includeUndo?.canUndo == false)
            type(e, "Q", at: 0)
            spin(0.02)
            includeUndo?.undo()
            t.equal(e.text, includeText)
            e.show(file: f.main)
            t.check(e.textView.undoManager === undo)
            t.check(e.text.contains("Update=1000abc"), "the main buffer is as it was")
            undo.undo()
            t.equal(e.text, mainText, "its history survives the file switch")
        }
    }

    // MARK: Triggers

    static func triggerTests(_ t: AppTestRunner) {
        t.suite("App: code editor commits on ⌘S and on focus loss") {
            let f = try makeFixture(t)
            let e = f.editor
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let field = NSTextField(string: "")
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            container.addSubview(e)
            container.addSubview(field)
            window.contentView = container
            defer {
                e.removeFromSuperview()
                window.close()
            }
            t.check(!window.isVisible, "never shown")
            t.check(window.makeFirstResponder(e.textView))

            type(e, "1", at: NSMaxRange(line(e, 3)))
            if let event = keyEvent("s", .command, window: window) {
                t.check(container.performKeyEquivalent(with: event), "⌘S handled while the code is focused")
            }
            t.equal(f.recorder.commits.count, 1, "⌘S commits")
            t.check(!e.isDirty)

            type(e, "2")
            t.check(window.makeFirstResponder(field))
            t.equal(f.recorder.commits.count, 2, "focus loss commits")
            t.check(!e.isDirty)

            if let event = keyEvent("s", .command, window: window) {
                t.check(!e.textView.performKeyEquivalent(with: event), "not handled when the code is not focused")
            }
            t.check(window.makeFirstResponder(e.textView))
            if let bigger = keyEvent("=", .command, window: window) {
                t.check(container.performKeyEquivalent(with: bigger))
            }
            t.equal(e.fontSize, CodeEditorView.defaultFontSize + 1)
            t.equal(f.recorder.fontSizes, [CodeEditorView.defaultFontSize + 1], "⌘+ is reported for the settings")

            // Removing the editor from its window commits a dirty buffer.
            type(e, "3")
            e.removeFromSuperview()
            t.equal(f.recorder.commits.count, 3)
        }
    }

    // MARK: Encoding

    static func encodingTests(_ t: AppTestRunner) {
        t.suite("App: code editor offers Unicode when ANSI cannot hold the text") {
            let ansi = Data("[A]\r\nText=Caf".utf8) + Data([0xE9]) + Data("\r\n".utf8)
            let f = try makeFixture(t, mainBytes: ansi)
            let e = f.editor
            e.onCommit = nil
            t.equal(e.document(for: f.main)?.encoding, .windows1252)
            var asked = 0
            var answer = false
            e.onEncodingConversion = { _, _ in
                asked += 1
                return answer
            }
            type(e, "é", at: NSMaxRange(line(e, 2)))
            t.check(e.commitNow(), "1252 holds é: no question")
            t.equal(asked, 0)
            t.equal(try Data(contentsOf: f.main), Data("[A]\r\nText=Caf".utf8) + Data([0xE9, 0xE9]) + Data("\r\n".utf8))

            type(e, "日")
            t.check(!e.commitNow(), "declined")
            t.equal(asked, 1)
            t.check(e.isDirty)
            t.check(!e.commitNow(), "a declined conversion is not asked again by automatic commits")
            t.equal(asked, 1)
            answer = true
            if let event = keyEvent("s", .command) { t.check(e.handleKeyEquivalent(event)) }
            t.equal(asked, 2, "⌘S asks again")
            t.check(!e.isDirty)
            t.equal(e.document(for: f.main)?.encoding, .utf16LittleEndian(bom: true))
            let disk = try CodeDocument.load(f.main)
            t.equal(disk.encoding, .utf16LittleEndian(bom: true))
            t.equal(disk.text, "[A]\r\nText=Caféé日\r\n")
        }
    }

    // MARK: Keeping unsaved edits

    /// Vars.inc as Windows-1252 with CRLF; `f.editor` re-reads it (the buffer is clean).
    static let ansiInclude = Data("[Variables]\r\nName=Caf".utf8) + Data([0xE9]) + Data("\r\n".utf8)

    /// An off-screen window (never ordered in) holding `editor`, for the leave-the-window path.
    static func offscreenWindow(with editor: CodeEditorView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        container.addSubview(editor)
        window.contentView = container
        return window
    }

    static func retentionTests(_ t: AppTestRunner) {
        t.suite("App: code editor keeps a dropped file whose commit is refused") {
            let f = try makeFixture(t)
            let e = f.editor
            let r = f.recorder
            r.accept = false // e.g. a locked file
            e.show(file: f.include)
            type(e, "Q", at: 0)
            e.show(file: f.main)
            t.check(e.isDirty(f.include), "refused when leaving it")

            // The host re-opens without the include (its @Include line was removed): the typing stays.
            t.equal(try e.open(files: [f.main], current: f.main), [f.include], "reported")
            t.equal(e.files, [f.main, f.include], "still open, after the listed files")
            t.check(e.isDirty(f.include) && e.hasUncommittedChanges)
            t.equal(r.commits.last?.url, f.include, "dropping it tried to commit it")
            t.equal(try String(contentsOf: f.include, encoding: .utf8), includeText, "nothing written")

            // Also when it is the shown file.
            e.show(file: f.include)
            t.equal(e.text, "Q" + includeText, "the typing survived")
            type(e, "R")
            t.equal(try e.open(files: [f.main], current: f.main), [f.include])
            t.equal(e.currentFile, f.main)
            t.equal(e.text, mainText)
            e.show(file: f.include)
            t.equal(e.text, "QR" + includeText, "the shown text was kept")

            // Once its commit goes through, the next open closes it.
            r.accept = true
            t.equal(try e.open(files: [f.main], current: f.main), [])
            t.equal(e.files, [f.main])
            t.equal(e.currentFile, f.main)
            t.equal(try String(contentsOf: f.include, encoding: .utf8), "QR" + includeText, "saved on the way out")
            t.check(!e.hasUncommittedChanges)
        }

        t.suite("App: code editor keeps dirty files a host drops during a commit") {
            let f = try makeFixture(t)
            let e = f.editor
            let r = f.recorder
            r.accept = false
            e.show(file: f.include)
            type(e, "Q", at: 0)
            e.show(file: f.main)
            type(e, "0", at: NSMaxRange(line(e, 3)))
            r.accept = true
            let write = e.onCommit
            e.onCommit = { [weak e] url, text in
                let ok = write?(url, text) ?? false
                // The host's refresh after writing the main file finds no @Include any more and re-opens.
                _ = try? e?.open(files: [f.main], current: f.main)
                return ok
            }
            t.check(e.commitNow())
            t.equal(r.commits.map(\.url), [f.include, f.main, f.include], "the include was committed, not dropped")
            t.equal(try String(contentsOf: f.include, encoding: .utf8), "Q" + includeText)
            t.check(!e.hasUncommittedChanges)
            try e.open(files: [f.main], current: f.main)
            t.equal(e.files, [f.main], "closed once clean")
        }

        t.suite("App: code editor asks again before dropping a declined conversion") {
            let f = try makeFixture(t)
            let e = f.editor
            e.onCommit = nil
            try ansiInclude.write(to: f.include)
            e.reloadFromDisk()
            t.equal(e.document(for: f.include)?.encoding, .windows1252)
            var asked = 0
            var answer = false
            e.onEncodingConversion = { _, _ in
                asked += 1
                return answer
            }
            e.show(file: f.include)
            type(e, "日", at: 0)
            e.show(file: f.main)
            t.equal(asked, 1, "leaving the file asks")
            t.check(e.isDirty(f.include), "declined: still dirty")
            t.check(!e.commitNow())
            t.equal(asked, 1, "automatic commits do not ask again")

            // The include list changes: dropping the file is explicit, so it asks again; declined, it stays open.
            t.equal(try e.open(files: [f.main], current: f.main), [f.include])
            t.equal(asked, 2)
            t.equal(try Data(contentsOf: f.include), ansiInclude, "nothing written")
            t.equal(try e.open(files: [f.main], current: f.main), [f.include], "still kept")
            t.equal(asked, 2, "later re-opens (after every refresh) do not ask again")

            // The view leaves its window: asked again, and this time converted and saved.
            let window = offscreenWindow(with: e)
            defer { window.close() }
            t.check(!window.isVisible, "never shown")
            answer = true
            e.removeFromSuperview()
            t.equal(asked, 3, "leaving the window asks again")
            t.check(!e.hasUncommittedChanges)
            let disk = try CodeDocument.load(f.include)
            t.equal(disk.encoding, .utf16LittleEndian(bom: true))
            t.equal(disk.text, "日[Variables]\r\nName=Café\r\n")
        }

        t.suite("App: code editor keeps a declined answer nobody can revise, and discards on request") {
            let f = try makeFixture(t)
            let e = f.editor
            e.onCommit = nil
            try ansiInclude.write(to: f.include)
            e.reloadFromDisk()
            e.onEncodingConversion = { _, _ in false }
            e.show(file: f.include)
            type(e, "日", at: 0)
            e.show(file: f.main)
            t.check(e.isDirty(f.include), "declined")

            // No callback and no visible window: the user's answer stands, even for an explicit commit.
            e.onEncodingConversion = nil
            t.check(!e.commitNow(explicit: true))
            t.equal(try Data(contentsOf: f.include), ansiInclude, "not converted behind the user's back")
            t.check(e.isDirty(f.include))

            // The host's close check: the user discards (the shown buffer's typing too).
            type(e, "x", at: 0)
            t.check(e.isDirty)
            e.discardUncommittedChanges()
            t.check(!e.hasUncommittedChanges)
            t.equal(e.text, mainText)
            t.check(e.textView.undoManager?.canUndo == false, "its typing is not undoable any more")
            t.check(!e.fireIdleCommit(), "no commit is left pending")
            let window = offscreenWindow(with: e)
            defer { window.close() }
            e.removeFromSuperview()
            t.equal(try String(contentsOf: f.main, encoding: .utf8), mainText, "nothing committed later")
            t.equal(try Data(contentsOf: f.include), ansiInclude)
            e.show(file: f.include)
            t.equal(e.text, "[Variables]\r\nName=Café\r\n", "back to the file's text")
            t.equal(e.document(for: f.include)?.encoding, .windows1252)
        }
    }

    // MARK: Font

    static func fontTests(_ t: AppTestRunner) {
        t.suite("App: code editor font size") {
            let f = try makeFixture(t)
            let e = f.editor
            let thickness = e.ruler.ruleThickness
            e.setFontSize(18)
            t.equal(e.fontSize, 18)
            t.equal(e.textView.font?.pointSize, 18)
            t.equal((e.textView.textStorage?.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)?.pointSize, 18)
            t.check(e.ruler.ruleThickness > thickness, "the ruler grows with the font")
            t.equal(e.text, mainText)
            t.check(color(e, at: 0) === CodeEditorTheme.comment, "highlighting kept")
            t.check(e.textView.undoManager?.canUndo == false)
            e.setFontSize(100)
            t.equal(e.fontSize, CodeEditorView.fontSizeRange.upperBound)
            e.setFontSize(1)
            t.equal(e.fontSize, CodeEditorView.fontSizeRange.lowerBound)
            t.equal(f.recorder.fontSizes, [], "API changes are not reported")

            let png = UISnapshot.codeEditorPreview(size: NSSize(width: 480, height: 320))
            t.check(png.map { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) } == true, "--snapshot-ui codeeditor renders")
        }
    }
}
