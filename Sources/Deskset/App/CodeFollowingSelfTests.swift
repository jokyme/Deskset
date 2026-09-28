import AppKit
import DesksetCore

/// "App: code editor follows …": the code pane makes a step's edits character by character (`CodeEditorView.follow`,
/// `SourceTextEdits`) instead of reading its files again — the text equals the session's text in memory after steps,
/// undos and redos, the caret goes with the text around it, the scroll position stays, and the colors are the ones a
/// full read gives — and reads them again only when it must (typing not committed, another encoding, another text).
enum CodeFollowingSelfTests {
    static func run(_ t: AppTestRunner) {
        viewTests(t)
        studioTests(t)
        typedTests(t)
    }

    /// Waits until `condition` holds (at most `seconds`), running the main run loop.
    @discardableResult
    static func wait(_ seconds: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    /// Types `text` over the first `old` in the code pane, as keyboard input does.
    static func typeOver(_ code: CodeEditorView, _ old: String, with text: String) -> Bool {
        let range = (code.text as NSString).range(of: old)
        guard range.location != NSNotFound else { return false }
        code.textView.setSelectedRange(range)
        code.textView.insertText(text, replacementRange: range)
        return true
    }

    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    /// The colors of the shown text, run by run (the highlighter's temporary attributes), each color by identity.
    static func colorRuns(_ e: CodeEditorView) -> [String] {
        guard let layout = e.textView.layoutManager else { return [] }
        let length = (e.text as NSString).length
        var runs: [String] = []
        var i = 0
        while i < length {
            var range = NSRange()
            let color = layout.temporaryAttribute(.foregroundColor, atCharacterIndex: i, longestEffectiveRange: &range,
                                                  in: NSRange(location: i, length: length - i)) as? NSColor
            runs.append("\(range.location)+\(range.length) \(color.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-")")
            i = max(NSMaxRange(range), i + 1)
        }
        return runs
    }

    /// The text of the line in the middle of the visible part of the shown file.
    static func middleLine(_ e: CodeEditorView) -> String {
        guard let layout = e.textView.layoutManager, let container = e.textView.textContainer else { return "" }
        let visible = e.scrollView.contentView.bounds
        let point = NSPoint(x: 20, y: visible.midY - e.textView.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: point, in: container)
        let index = layout.characterIndexForGlyph(at: glyph)
        let document = CodeDocument(text: e.text)
        return (e.text as NSString).substring(with: document.range(ofLine: document.line(containingOffset: index)))
    }

    /// A view that read `text` afresh: what a full read shows.
    static func fresh(_ text: String, encoding: TextFileEncoding = .utf8(bom: false)) -> CodeEditorView {
        let view = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.layoutSubtreeIfNeeded()
        let data = TextDecoding.encodeForWriting(text, preferring: encoding)
        view.readData = { _ in data }
        _ = try? view.open(files: [URL(fileURLWithPath: "/tmp/fresh.ini")], current: URL(fileURLWithPath: "/tmp/fresh.ini"))
        return view
    }

    /// A step that changed `file` from `before` to `after`.
    static func step(_ before: String, _ after: String, file: URL, encoding: TextFileEncoding = .utf8(bom: false),
                     encodingAfter: TextFileEncoding? = nil) -> SourceTextEdits {
        guard let change = SourceChange(file: SourceFileID(file), before: before, after: after, encodingBefore: encoding,
                                        encodingAfter: encodingAfter ?? encoding) else { return .none }
        return SourceTextEdits([change], in: SourceBuffers())
    }

    // MARK: The view

    static func viewTests(_ t: AppTestRunner) {
        t.suite("App: code editor follows a step's edits in place") {
            let f = try CodeEditorSelfTests.makeFixture(t)
            let e = f.editor
            let text = e.text
            let reads = e.filesReadAgain
            // A selection after the edit goes with its text.
            let after = (text as NSString).range(of: "LeftMouseUpAction").location
            e.textView.setSelectedRange(NSRange(location: after, length: 4))
            let renamed = text.replacingOccurrences(of: "Text=CPU %1%", with: "Text=Processor %1%")
            let delta = ("Processor" as NSString).length - ("CPU" as NSString).length
            t.check(e.follow(step(text, renamed, file: f.main)), "followed")
            t.equal(e.text, renamed, "the new text")
            t.equal(e.textView.selectedRange(), NSRange(location: after + delta, length: 4), "the selection went with its text")
            t.check(!e.isDirty, "no typing: clean")
            t.equal(e.document(for: f.main)?.text, renamed, "the clean state is the new text")
            t.equal(e.stepsFollowed, 1)
            t.equal(e.filesReadAgain, reads, "nothing read again")
            t.equal(colorRuns(e), colorRuns(fresh(renamed)), "the colors a full read gives")
            t.check(e.textView.undoManager?.canUndo != true, "no typing to undo")

            // A caret before the edit stays where it is.
            e.textView.setSelectedRange(NSRange(location: 3, length: 0))
            t.check(e.follow(step(renamed, text, file: f.main)), "the step undone")
            t.equal(e.text, text)
            t.equal(e.textView.selectedRange(), NSRange(location: 3, length: 0), "the caret before the edit stays")

            // Not the text the edits start from: nothing changes, the host reads the files.
            t.check(!e.follow(step(renamed, text + "x", file: f.main)), "refused: it does not hold the text they start from")
            t.equal(e.text, text, "unchanged")

            // A line added (CRLF, as the file): lines, ending and colors as a full read.
            let lines = text.replacingOccurrences(of: "Update=1000\r\n", with: "Update=1000\r\nAccurateText=1\r\n")
            t.check(e.follow(step(text, lines, file: f.main)), "a line added")
            t.equal(e.text, lines)
            t.equal(e.document(for: f.main)?.lineEnding, .crlf)
            t.equal(e.lineStarts, CodeDocument(text: lines).lineStarts, "the line index")
            t.equal(e.lineRange(ofSection: "MeterText"), CodeDocument(text: lines).lineRange(ofSection: "MeterText"),
                    "the sections")
            t.equal(colorRuns(e), colorRuns(fresh(lines)))

            // A file that is not shown follows too, and shows its new text.
            let include = CodeEditorSelfTests.includeText
            let bigger = include.replacingOccurrences(of: "Size=10", with: "Size=14")
            t.check(e.follow(step(include, bigger, file: f.include)), "the include followed")
            t.equal(e.currentFile, f.main, "the shown file stays")
            e.show(file: f.include)
            t.equal(e.text, bigger, "the include's new text")
            t.equal(colorRuns(e), colorRuns(fresh(bigger)))
            e.show(file: f.main)

            // Several edits of one file, in order.
            let first = lines.replacingOccurrences(of: "Measure=CPU", with: "Measure=Memory")
            let second = first.replacingOccurrences(of: "; Test skin", with: "; A test skin")
            guard let a = SourceChange(file: SourceFileID(f.main), before: lines, after: first, encodingBefore: .utf8(bom: false),
                                       encodingAfter: .utf8(bom: false)),
                  let b = SourceChange(file: SourceFileID(f.main), before: first, after: second,
                                       encodingBefore: .utf8(bom: false), encodingAfter: .utf8(bom: false)) else {
                return t.check(false, "changes")
            }
            t.check(e.follow(SourceTextEdits([a, b], in: SourceBuffers())), "two edits")
            t.equal(e.text, second)
            t.check(e.follow(SourceTextEdits([b.reversed, a.reversed], in: SourceBuffers())), "both undone")
            t.equal(e.text, lines)
            // Changes that do not follow on from each other: read again.
            t.check(!e.follow(SourceTextEdits([a, a], in: SourceBuffers())), "refused: a broken chain")
            t.equal(e.text, lines)

            // Another encoding: read again.
            t.check(!e.follow(step(lines, text, file: f.main, encodingAfter: .utf16LittleEndian(bom: true))),
                    "refused: the encoding changed")
            t.equal(e.text, lines)

            // Typing not committed: read again (which keeps it).
            CodeEditorSelfTests.type(e, "X", at: 0)
            let typed = e.text
            t.check(!e.follow(step(lines, text, file: f.main)), "refused: typing not committed")
            t.equal(e.text, typed, "the typing stays")
            e.discardUncommittedChanges()

            // A step with no text edits (typed code shown by the canvas) changes nothing.
            let before = e.text
            t.check(e.follow(.none), "nothing to follow")
            t.equal(e.text, before)
        }

        t.suite("App: code editor follows a step's edits: colors on every line kind") {
            let f = try CodeEditorSelfTests.makeFixture(t)
            let e = f.editor
            var text = e.text
            // Each edit changes a line of another kind: a header, a comment, a key, a value with a variable and a bang.
            let edits: [(String, String)] = [
                ("[MeasureCPU]", "[MeasureProcessor]"),
                ("; the processor", "; the CPU, all cores"),
                ("Measure=CPU", "Measure=Calc\r\nFormula=(1 + 2)"),
                ("Color=255,0,0", "Color=#Base#,[MeasureCPU:],0"),
                ("[!Refresh]", "[!SetOption MeterText Text \"x\"][!Redraw]"),
                ("\r\n[MeterText]", "\r\n\r\n[MeterText]"),
            ]
            for (old, new) in edits {
                let next = text.replacingOccurrences(of: old, with: new)
                t.check(e.follow(step(text, next, file: f.main)), "followed: \(old)")
                t.equal(e.text, next)
                t.equal(colorRuns(e), colorRuns(fresh(next)), "colors after \(old) → \(new)")
                text = next
            }
        }
    }

    // MARK: The Studio

    static func studioTests(_ t: AppTestRunner) {
        t.suite("App: code editor follows the Studio's steps, undos and redos") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\Calendar") else { return }
            defer { editor.window?.close() }
            guard let session = editor.session, let skin = editor.skin,
                  let target = skin.meters.first(where: { $0 is StringMeter })?.name else {
                return t.check(false, "opened")
            }
            editor.setMode(.split)
            settle()
            editor.select(section: target)
            settle()
            let code = editor.codeView
            guard let shown = code.currentFile else { return t.check(false, "the code shows a file") }
            func memory(_ url: URL) -> String? { session.buffers.buffer(url)?.text }
            t.equal(code.text, memory(shown), "the code shows the text in memory")
            // The caret near the end, the view scrolled there.
            let lines = CodeDocument(text: code.text).lineCount
            code.reveal(line: lines - 3, in: shown, select: false)
            settle()
            let caret = code.textView.selectedRange()
            let origin = code.scrollView.contentView.bounds.origin
            t.check(origin.y > 0, "scrolled down: \(origin)")
            let middle = middleLine(code)
            t.check(!middle.isEmpty, "a line in the middle of the view: \(middle)")
            let length = (code.text as NSString).length
            let followed = code.stepsFollowed, reads = code.filesReadAgain

            func check(_ what: String, steps: Int, expectedLength: Int? = nil) {
                t.equal(code.text, memory(shown), "\(what): the code equals the text in memory")
                t.equal(code.stepsFollowed, followed + steps, "\(what): followed by its edits")
                t.equal(code.filesReadAgain, reads, "\(what): nothing read again")
                let delta = (code.text as NSString).length - length
                t.equal(code.textView.selectedRange(), NSRange(location: caret.location + delta, length: 0),
                        "\(what): the caret went with its line")
                // The text in view stays (TextKit keeps it in place as lines above it come and go).
                t.equal(middleLine(code), middle, "\(what): the same text in the middle of the view")
                t.check(abs(code.scrollView.contentView.bounds.minY - origin.y) < 40, "\(what): scrolled where it was")
                t.equal(colorRuns(code), colorRuns(fresh(code.text)), "\(what): the colors a full read gives")
                t.check(!code.hasUncommittedChanges, "\(what): clean")
            }
            editor.commit([.init(section: target, key: "FontSize", value: "19", own: true)], name: "Change Font Size")
            settle()
            check("the edit", steps: 1)
            editor.window?.undoManager?.undo()
            settle()
            check("the undo", steps: 2)
            t.equal((code.text as NSString).length, length, "the undo put the text back")
            editor.window?.undoManager?.redo()
            settle()
            check("the redo", steps: 3)
            for round in 1...3 {
                editor.window?.undoManager?.undo()
                settle()
                check("undo \(round)", steps: 2 + 2 * round)
                t.equal((code.text as NSString).length, length)
                editor.window?.undoManager?.redo()
                settle()
                check("redo \(round)", steps: 3 + 2 * round)
            }

            // A variable in an included file: that file follows while the main file stays shown.
            guard let variables = skin.includedFiles.first(where: { $0.lastPathComponent.lowercased() == "variables.inc" }),
                  let defined = memory(variables),
                  let line = defined.components(separatedBy: .newlines).first(where: {
                      !$0.hasPrefix(";") && !$0.hasPrefix("[") && $0.contains("=") && $0.contains(",")
                  }),
                  let equals = line.firstIndex(of: "=") else {
                return t.check(false, "Calendar has a color variable in Variables.inc")
            }
            let name = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let file = code.files.first { SourceFileID($0) == SourceFileID(variables) } ?? variables
            editor.commit([.init(section: "Variables", key: name, value: "12,34,56", own: false)], name: "Change Color")
            settle()
            t.check(memory(variables)?.contains("\(name)=12,34,56") == true, "the variable changed in its file")
            t.equal(code.currentFile, shown, "the shown file stays")
            t.equal(code.filesReadAgain, reads, "nothing read again")
            code.show(file: file)
            t.equal(code.text, memory(variables), "the include shows its text in memory")
            t.equal(colorRuns(code), colorRuns(fresh(code.text)))
            code.show(file: shown)
            editor.window?.undoManager?.undo()
            settle()
            code.show(file: file)
            t.equal(code.text, memory(variables), "and after the undo")
            t.equal(code.text, defined, "the variable as it was")
            code.show(file: shown)
            editor.window?.undoManager?.undo()
            settle()
            t.equal(code.text, memory(shown), "every step undone")
            t.check(session.buffers.dirtyFiles.isEmpty, "written")
        }

        t.suite("App: code editor follows a layer added and removed (the Studio's instance loads again)") {
            let ini = "[Rainmeter]\nUpdate=1000\n\n[MeterTitle]\nMeter=String\nText=Hi\nFontSize=12\n"
            guard let (_, editor, url) = try StudioReviewSelfTests.openSkin(t, "CodeFollow", ini) else { return }
            defer { editor.window?.close() }
            guard let session = editor.session else { return t.check(false, "a session") }
            editor.setMode(.split)
            settle()
            let code = editor.codeView
            let followed = code.stepsFollowed, reads = code.filesReadAgain
            let before = editor.skin
            try session.apply("Add Layer", [.editSource(file: url, text: ini + "\n[MeterNew]\nMeter=String\nText=New\n",
                                                        encoding: nil)])
            settle()
            t.check(editor.skin !== before, "the Studio's instance loaded again")
            t.equal(code.text, session.buffers.buffer(url)?.text, "the code shows the new layer")
            t.equal(code.stepsFollowed, followed + 1, "by the step's edits")
            t.equal(code.filesReadAgain, reads, "nothing read again")
            t.equal(colorRuns(code), colorRuns(fresh(code.text)))
            editor.window?.undoManager?.undo()
            settle()
            t.equal(code.text, ini, "undone")
            t.equal(code.stepsFollowed, followed + 2)
            t.equal(code.filesReadAgain, reads)
            // A change on disk is not a step: the files are read again.
            try (ini + "; saved elsewhere\n").write(to: url, atomically: true, encoding: .utf8)
            session.takeChangesFromDisk()
            session.reloadStudioSkin()
            settle()
            t.equal(code.text, ini + "; saved elsewhere\n", "the change on disk shows")
            t.check(code.filesReadAgain > reads, "read again")
        }
    }

    // MARK: Typed code

    static let typedIni = "[Rainmeter]\nUpdate=1000\n\n[MeterTitle]\nMeter=String\nText=Hi\nFontSize=12\n"

    static func typedTests(_ t: AppTestRunner) {
        t.suite("App: code editor shows typed code on the canvas after a pause, and writes it at the commit") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "CodeTyped", typedIni) else { return }
            defer { editor.window?.close() }
            guard let session = editor.session, let desktop = app.controller(for: "Studio\\CodeTyped") else {
                return t.check(false, "a session")
            }
            editor.setMode(.split)
            settle()
            editor.select(section: "MeterTitle")
            settle()
            let code = editor.codeView
            editor.window?.makeFirstResponder(code.textView)
            let instance = editor.skin
            func title() -> Meter? { editor.skin?.meter(named: "MeterTitle") }
            let height = title()?.frame.height ?? 0
            let undoName = session.undoStack.undoActionName

            let typedAt = Date()
            t.check(typeOver(code, "FontSize=12", with: "FontSize=30"), "typed")
            guard let due = code.typedTextDate, let commitDue = code.idleCommitDate else {
                return t.check(false, "the pause and the commit are waited for")
            }
            t.check(due.timeIntervalSince(typedAt) >= 0.1 && due.timeIntervalSince(typedAt) <= 0.3,
                    "shown after about 150 ms: \(due.timeIntervalSince(typedAt))")
            t.check(commitDue > due, "committed later")
            t.equal(title()?.rawOption("FontSize"), "12", "not before the pause")
            t.check(wait { code.typedTextDate == nil }, "the pause ended")
            t.equal(title()?.rawOption("FontSize"), "30", "the Studio's instance shows the typed code")
            t.check((title()?.frame.height ?? 0) > height, "at its new size: \(title()?.frame.height ?? 0) > \(height)")
            t.check(editor.skin === instance, "as a patch: the same instance")
            t.equal(StudioReviewSelfTests.read(url), typedIni, "nothing written")
            t.equal(session.buffers.buffer(url)?.text, typedIni, "the text in memory is as it was")
            t.equal(session.undoStack.undoActionName, undoName, "no step")
            t.equal(desktop.skin.meter(named: "MeterTitle")?.rawOption("FontSize"), "12", "the desktop copy as it was")
            t.check(code.isDirty, "the code is still to commit")
            t.check(editor.window?.firstResponder === code.textView, "the code keeps the keyboard focus")

            // The commit writes it as one step, and finds nothing more to show.
            t.check(code.fireIdleCommit(), "committed after the longer pause")
            settle()
            t.check(StudioReviewSelfTests.read(url).contains("FontSize=30\n"), "written")
            t.equal(session.undoStack.undoActionName, "Edit Code", "one step")
            t.check(editor.skin === instance, "the same instance")
            t.equal(title()?.rawOption("FontSize"), "30")
            t.check(session.studioSources.typed.isEmpty, "no typed code left")
            t.check(!code.isDirty)
            t.equal(code.text, session.buffers.buffer(url)?.text)
            t.check(wait { desktop.skin.meter(named: "MeterTitle")?.rawOption("FontSize") == "30" },
                    "the desktop copy follows the step")

            editor.window?.undoManager?.undo()
            settle()
            t.equal(StudioReviewSelfTests.read(url), typedIni, "undone")
            t.equal(code.text, typedIni, "the code too")
            t.equal(title()?.rawOption("FontSize"), "12")
            editor.window?.undoManager?.redo()
            settle()
            t.check(StudioReviewSelfTests.read(url).contains("FontSize=30\n"), "redone")
            t.equal(code.text, session.buffers.buffer(url)?.text)
            editor.window?.undoManager?.undo()
            settle()

            // Typed back to what is written: the instance shows the text in memory again.
            t.check(typeOver(code, "FontSize=12", with: "FontSize=40"), "typed again")
            code.fireTypedText()
            t.equal(title()?.rawOption("FontSize"), "40")
            t.check(typeOver(code, "FontSize=40", with: "FontSize=12"), "typed back")
            t.check(!code.isDirty, "clean")
            t.check(code.fireTypedText(), "the pause is waited for again")
            t.equal(title()?.rawOption("FontSize"), "12", "the text in memory shows again")
            t.check(session.studioSources.typed.isEmpty)

            // Committed before the pause (⌘S): the step shows it, and the pause has nothing left to show.
            t.check(typeOver(code, "FontSize=12", with: "FontSize=22"), "typed")
            t.check(code.commitNow(explicit: true), "saved at once")
            t.equal(code.typedTextDate, nil, "nothing left for the pause")
            t.equal(title()?.rawOption("FontSize"), "22", "the step shows it")
            t.check(StudioReviewSelfTests.read(url).contains("FontSize=22\n"))
            editor.window?.undoManager?.undo()
            settle()
            t.equal(title()?.rawOption("FontSize"), "12")
            t.equal(StudioReviewSelfTests.read(url), typedIni)
        }

        t.suite("App: code editor shows a typed layer by loading the Studio's instance again, and drops it when discarded") {
            guard let (_, editor, url) = try StudioReviewSelfTests.openSkin(t, "CodeTypedLayer", typedIni) else { return }
            defer { editor.window?.close() }
            guard let session = editor.session else { return t.check(false, "a session") }
            editor.setMode(.split)
            settle()
            let code = editor.codeView
            let instance = editor.skin
            editor.window?.makeFirstResponder(code.textView)
            let end = (code.text as NSString).length
            code.textView.setSelectedRange(NSRange(location: end, length: 0))
            code.textView.insertText("\n[MeterTyped]\nMeter=String\nText=Typed\nY=30\n", replacementRange: code.textView.selectedRange())
            t.check(code.fireTypedText(), "the pause")
            t.check(editor.skin !== instance, "a layer added: the Studio's instance loaded again")
            t.check(editor.skin?.meter(named: "MeterTyped") != nil, "it shows the typed layer")
            t.check(editor.allItems.contains { $0.title == "MeterTyped" }, "the layers list it")
            t.check(editor.window?.firstResponder === code.textView, "the code keeps the keyboard focus")
            t.equal(StudioReviewSelfTests.read(url), typedIni, "nothing written")
            t.equal(session.buffers.buffer(url)?.text, typedIni)
            t.check(!session.undoStack.canUndo, "no step")
            let shown = editor.skin
            code.discardUncommittedChanges()
            settle()
            t.check(editor.skin?.meter(named: "MeterTyped") == nil, "discarded: the layer is gone")
            t.check(editor.skin !== shown, "loaded again")
            t.check(session.studioSources.typed.isEmpty)
            t.equal(code.text, typedIni)
            t.check(!session.undoStack.canUndo, "still no step")

            // Code that does not load keeps the instance as it was.
            let before = editor.skin
            t.check(typeOver(code, "[MeterTitle]", with: "[MeterTitle"), "a broken header")
            code.fireTypedText()
            t.check(editor.skin != nil, "the Studio still shows the widget")
            code.discardUncommittedChanges()
            settle()
            t.check(editor.skin?.meter(named: "MeterTitle") != nil, "and after the typing is dropped")
            _ = before
        }
    }
}
