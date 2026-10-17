import AppKit
import DesksetCore

/// "App: code editor follows …": the code pane makes a step's edits character by character (`CodeEditorView.follow`,
/// `SourceTextEdits`) instead of reading its files again — the text equals the session's text in memory after steps,
/// undos and redos, the caret goes with the text around it, the scroll position stays, and the colors are the ones a
/// full read gives — and reads them again only when it must (typing not committed, another encoding, another text).
enum CodeFollowingSelfTests {
    static func run(_ t: AppTestRunner) {
        viewTests(t)
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
}

