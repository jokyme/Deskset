import Foundation
@testable import DesksetCore

func runTextEditMeterTests(_ t: TestRunner) {
    var retainedSkins: [Skin] = []
    defer { withExtendedLifetime(retainedSkins) {} }
    func editor(_ options: String = "") throws -> (Skin, TextEditMeter) {
        let (skin, _) = try makeSkin(t, """
        [Input]
        Meter=TextEdit
        W=80
        H=30
        FontSize=10
        \(options)
        """)
        skin.update()
        retainedSkins.append(skin)
        guard let meter = skin.meter(named: "Input") as? TextEditMeter else {
            throw NSError(domain: "TextEditMeterTests", code: 1)
        }
        return (skin, meter)
    }

    t.suite("TextEdit: insertion, backspace and forward delete use the caret") {
        let (_, m) = try editor("InitialText=ABCDE")
        m.focus()
        m.select(start: 2, length: 0)
        t.check(m.handleKeyInput(.insert("x")))
        t.equal(m.inputText, "ABxCDE")
        t.equal(m.caretPosition, 3)
        t.equal(m.selectionRange, 3..<3)
        m.handleKeyInput(.backspace)
        t.equal(m.inputText, "ABCDE")
        t.equal(m.caretPosition, 2)
        m.handleKeyInput(.deleteForward)
        t.equal(m.inputText, "ABDE")
        t.equal(m.caretPosition, 2)
        m.select(start: 0, length: 0)
        m.handleKeyInput(.backspace)
        t.equal(m.inputText, "ABDE", "backspace at the start does not remove the last character")
        m.handleKeyInput(.move(.documentEnd, selecting: false))
        m.handleKeyInput(.deleteForward)
        t.equal(m.inputText, "ABDE")
    }

    t.suite("TextEdit: reverse selections retain their anchor when crossing it") {
        let (_, m) = try editor("InitialText=ABCDE")
        m.focus()
        m.select(start: 2, length: 0)
        m.handleKeyInput(.move(.left, selecting: true))
        t.equal(m.selectionRange, 1..<2)
        t.equal(m.selectionAnchor, 2)
        t.equal(m.caretPosition, 1)
        m.handleKeyInput(.move(.right, selecting: true))
        m.handleKeyInput(.move(.right, selecting: true))
        t.equal(m.selectionRange, 2..<3)
        t.equal(m.selectionAnchor, 2)
        t.equal(m.caretPosition, 3)
        m.handleKeyInput(.move(.left, selecting: false))
        t.equal(m.selectionRange, 2..<2, "plain left collapses to the selection's leading edge")
        m.select(start: 1, length: 3)
        m.handleKeyInput(.move(.right, selecting: false))
        t.equal(m.selectionRange, 4..<4)
        m.select(start: Int.max, length: Int.max)
        t.equal(m.selectionRange, 5..<5, "bang selection arguments do not overflow")
        m.select(start: -5, length: -1)
        t.equal(m.selectionRange, 0..<5)
    }

    t.suite("TextEdit: clipboard edits preserve the surrounding text and selection history") {
        let (_, m) = try editor("InitialText=ABCDE")
        m.focus()
        m.select(start: 1, length: 3)
        t.equal(m.clipboardText, "BCD")
        t.equal(m.cutSelection(), "BCD")
        t.equal(m.inputText, "AE")
        t.equal(m.caretPosition, 1)
        t.check(m.canUndo)
        m.undo()
        t.equal(m.inputText, "ABCDE")
        t.equal(m.selectionRange, 1..<4)
        t.check(m.paste("xy"))
        t.equal(m.inputText, "AxyE")
        t.equal(m.caretPosition, 3)
        m.undo()
        t.equal(m.inputText, "ABCDE")
        t.equal(m.selectionRange, 1..<4)
    }

    t.suite("TextEdit: pasting the selected text collapses the selection without creating undo") {
        let (_, m) = try editor("InitialText=ABCDE")
        m.focus()
        m.select(start: 1, length: 3)
        t.check(m.paste("BCD"))
        t.equal(m.inputText, "ABCDE")
        t.equal(m.caretPosition, 4)
        t.equal(m.selectionRange, 4..<4, "a valid replacement collapses even when the string is unchanged")
        t.check(!m.canUndo, "a selection-only result does not create a text edit")
        m.undo()
        t.equal(m.inputText, "ABCDE")
        t.equal(m.selectionRange, 4..<4)
    }

    t.suite("TextEdit: undo restores the caret before a deletion and removes no-op edits") {
        let (_, m) = try editor("InitialText=ABCDE")
        m.focus()
        m.select(start: 2, length: 0)
        m.handleKeyInput(.backspace)
        t.equal(m.inputText, "ACDE")
        m.handleKeyInput(.undo)
        t.equal(m.inputText, "ABCDE")
        t.equal(m.selectionRange, 2..<2, "undo restores the original caret, not an internal deletion range")
        t.check(!m.canUndo)
        m.select(start: 0, length: 0)
        m.handleKeyInput(.backspace)
        t.check(!m.canUndo)
        m.handleKeyInput(.insert("x"))
        m.handleKeyInput(.insert("y"))
        t.equal(m.inputText, "xyABCDE")
        m.undo()
        t.equal(m.inputText, "xABCDE")
        m.undo()
        t.equal(m.inputText, "ABCDE")
        m.undo()
        t.equal(m.inputText, "ABCDE")
        m.handleKeyInput(.insert("q"))
        m.reset()
        t.check(!m.canUndo, "an explicit reset starts a new editing history")
    }

    t.suite("TextEdit: MaxLength truncates paste without discarding the suffix") {
        let (_, m) = try editor("InitialText=12345\nMaxLength=6")
        m.focus()
        m.select(start: 2, length: 1)
        m.paste("ABCDEF")
        t.equal(m.inputText, "12AB45")
        t.equal(m.caretPosition, 4)
        m.handleKeyInput(.insert("Z"))
        t.equal(m.inputText, "12AB45")
        m.undo()
        t.equal(m.inputText, "12345")
        m.select(start: 2, length: 0)
        m.paste("\r\nX\nY\r")
        t.equal(m.inputText, "12X345", "single-line paste follows the existing newline normalization")
    }

    t.suite("TextEdit: filtering accepts or rejects the complete replacement atomically") {
        let (_, m) = try editor("InitialText=1234\nInputFilter=Numeric")
        m.focus()
        m.select(start: 1, length: 2)
        m.paste("ab")
        t.equal(m.inputText, "1234")
        t.equal(m.selectionRange, 1..<3)
        t.check(!m.canUndo)
        m.paste("56")
        t.equal(m.inputText, "1564")
        t.equal(m.selectionRange, 3..<3)
        m.undo()
        t.equal(m.inputText, "1234")
        t.equal(m.selectionRange, 1..<3)
        let (_, decimal) = try editor("InitialText=-1.25\nInputFilter=Decimal")
        decimal.focus()
        decimal.select(start: 2, length: 0)
        decimal.paste(".")
        t.equal(decimal.inputText, "-1.25")
    }

    t.suite("TextEdit: RegExp, input case and length apply to pasted input") {
        let (_, m) = try editor("InitialText=AB\nInputCase=Upper\nInputFilter=RegExp\nInputRegExp=^[A-Z]*$\nMaxLength=4")
        m.focus()
        m.select(start: 1, length: 0)
        m.paste("cdxyz")
        t.equal(m.inputText, "ACDB")
        t.equal(m.caretPosition, 3)
        m.selectAll()
        m.paste("12")
        t.equal(m.inputText, "ACDB")
        m.paste("ßab")
        t.equal(m.inputText, "SSAB")
        t.equal(m.caretPosition, 4)
    }

    t.suite("TextEdit: StringCase applies to pasted input and copied text before InputCase") {
        let (_, m) = try editor("InitialText=aßz\nStringCase=Upper\nInputCase=Lower\nInputFilter=RegExp\nInputRegExp=^[A-Z]*$")
        t.equal(m.inputText, "ASSZ")
        t.equal(m.text, "ASSZ")
        m.focus()
        m.select(start: 1, length: 2)
        t.equal(m.clipboardText, "SS")
        m.paste("bc")
        t.equal(m.inputText, "ABCZ")
        t.equal(m.caretPosition, 3)
        m.selectAll()
        t.equal(m.clipboardText, "ABCZ")
        m.undo()
        t.equal(m.inputText, "ASSZ")
        let (_, lower) = try editor("InitialText=ABC\nStringCase=Lower\nInputCase=Upper")
        lower.focus()
        lower.selectAll()
        lower.paste("DEF")
        t.equal(lower.inputText, "def")
        lower.selectAll()
        t.equal(lower.clipboardText, "def")
        let (_, none) = try editor("StringCase=None\nInputCase=Upper")
        none.focus()
        none.paste("abc")
        t.equal(none.inputText, "abc", "InputCase is used only when StringCase is not defined")
    }

    t.suite("TextEdit: ReadOnly allows selection and copy but blocks every user mutation") {
        let (skin, m) = try editor("InitialText=ABCDE")
        m.focus()
        m.select(start: 2, length: 0)
        m.handleKeyInput(.insert("x"))
        skin.execute("[!SetOption Input ReadOnly 1]", from: nil)
        skin.update()
        m.selectAll()
        t.equal(m.clipboardText, "ABxCDE")
        t.equal(m.cutSelection(), nil)
        m.paste("changed")
        m.handleKeyInput(.insert("changed"))
        m.handleKeyInput(.backspace)
        m.handleKeyInput(.deleteForward)
        m.handleKeyInput(.deleteWordBackward)
        m.handleKeyInput(.deleteWordForward)
        m.undo()
        t.equal(m.inputText, "ABxCDE")
        t.check(!m.canUndo)
        m.handleKeyInput(.move(.left, selecting: false))
        t.equal(m.caretPosition, 0)
        m.setText("programmatic")
        t.equal(m.inputText, "programmatic", "ReadOnly does not block an explicit bang-style setText")
    }

    t.suite("TextEdit: Password does not expose copy or cut and maps graphemes to mask positions") {
        let (_, m) = try editor("InitialText=A👨‍👩‍👧‍👦éZ\nPassword=1")
        m.focus()
        m.select(start: 1, length: 2)
        t.equal(m.clipboardText, nil)
        t.equal(m.cutSelection(), nil)
        t.equal(m.inputText, "A👨‍👩‍👧‍👦éZ")
        t.equal(m.text, "●●●●")
        t.equal(m.displayedSelectionRange, 1..<3)
        t.equal(m.displayedCaretOffset, 3)
        m.paste("Q")
        t.equal(m.inputText, "AQZ")
        t.equal(m.text, "●●●")
        m.undo()
        t.equal(m.inputText, "A👨‍👩‍👧‍👦éZ")
    }

    t.suite("TextEdit: Unicode deletion and caret offsets remain on complete graphemes") {
        let (_, m) = try editor("InitialText=A👨‍👩‍👧‍👦éßZ")
        m.focus()
        m.select(start: 4, length: 0)
        t.equal(m.displayedCaretOffset, "A👨‍👩‍👧‍👦éß".utf16.count)
        m.handleKeyInput(.backspace)
        t.equal(m.inputText, "A👨‍👩‍👧‍👦éZ")
        m.handleKeyInput(.backspace)
        t.equal(m.inputText, "A👨‍👩‍👧‍👦Z")
        m.handleKeyInput(.backspace)
        t.equal(m.inputText, "AZ")
        m.undo()
        t.equal(m.inputText, "A👨‍👩‍👧‍👦Z")
        t.equal(m.caretPosition, 2)
    }

    t.suite("TextEdit: word navigation and word deletion preserve the surrounding input") {
        let (_, m) = try editor("InitialText=one two_three, four")
        m.focus()
        m.handleKeyInput(.move(.wordRight, selecting: false))
        t.equal(m.caretPosition, 4)
        m.handleKeyInput(.move(.wordRight, selecting: true))
        t.equal(m.selectionRange, 4..<13)
        m.handleKeyInput(.move(.wordLeft, selecting: false))
        t.equal(m.caretPosition, 4)
        m.handleKeyInput(.deleteWordForward)
        t.equal(m.inputText, "one , four")
        m.handleKeyInput(.move(.documentEnd, selecting: false))
        m.handleKeyInput(.deleteWordBackward)
        t.equal(m.inputText, "one , ")
        m.undo()
        t.equal(m.inputText, "one , four")
    }

    t.suite("TextEdit: line navigation excludes terminating newlines and keeps the preferred column") {
        let (_, m) = try editor("Multiline=1\nInitialText=abcdef#CRLF#ab#CRLF#abcdef")
        m.focus()
        t.equal(m.inputText, "abcdef\nab\nabcdef")
        m.select(start: 5, length: 0)
        m.handleKeyInput(.move(.down, selecting: false))
        t.equal(m.caretPosition, 9)
        m.handleKeyInput(.move(.down, selecting: false))
        t.equal(m.caretPosition, 15, "the original visual x survives a short intermediate line")
        m.handleKeyInput(.move(.lineStart, selecting: false))
        t.equal(m.caretPosition, 10)
        m.handleKeyInput(.move(.up, selecting: false))
        t.equal(m.caretPosition, 7)
        m.handleKeyInput(.move(.lineEnd, selecting: false))
        t.equal(m.caretPosition, 9, "End stops before the newline")
        m.handleKeyInput(.move(.documentStart, selecting: false))
        m.handleKeyInput(.move(.pageDown, selecting: true))
        t.equal(m.selectionAnchor, 0)
        t.check(m.caretPosition > 0)
        m.handleKeyInput(.move(.pageUp, selecting: false))
        t.equal(m.caretPosition, 0)
    }

    t.suite("TextEdit: horizontal overflow scrolls the caret into view without ellipsis") {
        let (_, m) = try editor("InitialText=abcdefghijklmnopqrstuvwxyz")
        m.focus()
        m.handleKeyInput(.move(.documentEnd, selecting: false))
        t.check(m.scrollOffset.x > 0)
        t.equal(m.text, "abcdefghijklmnopqrstuvwxyz")
        t.equal(m.lower().editing?.scroll, m.scrollOffset)
        m.resetScroll()
        t.equal(m.scrollOffset, SkinPoint())
        m.scrollByLine(100)
        t.equal(m.scrollOffset, SkinPoint(), "ScrollByLine does nothing for a single-line field")
        m.handleKeyInput(.move(.left, selecting: false))
        t.check(m.scrollOffset.x > 0)
        m.handleKeyInput(.move(.documentStart, selecting: false))
        t.close(m.scrollOffset.x, 0)
    }

    t.suite("TextEdit: a font change reveals the caret while ordinary blinking preserves manual scrolling") {
        let (skin, m) = try editor("InitialText=abcdefghijklmnopqrstuvwxyz")
        m.focus()
        m.handleKeyInput(.move(.documentEnd, selecting: false))
        let before = m.lower()
        let previousScroll = before.editing?.scroll.x ?? 0
        t.check(previousScroll > 0)
        skin.execute("[!SetOption Input FontSize 20]", from: nil)
        skin.update()
        let after = m.lower()
        t.close(after.contentFrame.width, before.contentFrame.width, "the viewport did not change")
        t.close(after.style.fontSize, 20)
        t.check((after.editing?.scroll.x ?? 0) > previousScroll,
                "the enlarged glyph positions reveal the focused caret within the fixed viewport")
        let layout = TextEditLayout.fallback(text: after.editing?.layoutText ?? after.text,
                                              style: after.editing?.layoutStyle ?? after.style,
                                              viewport: after.contentFrame, multiline: false)
        let caret = layout.caretRect(at: after.editing?.caretOffset ?? 0)
        let scroll = after.editing?.scroll ?? SkinPoint()
        t.check(caret.x >= scroll.x - 0.01)
        t.check(caret.maxX <= scroll.x + after.contentFrame.width + 0.01)
        m.resetScroll()
        t.equal(m.scrollOffset, SkinPoint())
        t.check(m.toggleCaretBlink())
        t.equal(m.lower().editing?.scroll, SkinPoint(),
                "a caret tick cannot undo an explicit ResetScroll")
        skin.update()
        t.equal(m.lower().editing?.scroll, SkinPoint(),
                "an unchanged regular update also preserves the requested viewport")
    }

    t.suite("TextEdit: multiline scroll is bounded and ResetScroll preserves the selection") {
        let (_, m) = try editor("Multiline=1\nInitialText=one#CRLF#two#CRLF#three#CRLF#four#CRLF#five")
        m.focus()
        m.handleKeyInput(.move(.documentEnd, selecting: false))
        t.check(m.scrollOffset.y > 0)
        let atEnd = m.selectionRange
        m.resetScroll()
        t.equal(m.scrollOffset, SkinPoint())
        t.equal(m.selectionRange, atEnd)
        m.scrollByLine(Int.max)
        t.check(m.scrollOffset.y.isFinite && m.scrollOffset.y > 0)
        m.scrollByLine(Int.min)
        t.close(m.scrollOffset.y, 0)
        m.select(start: 0, length: 1)
        m.scrollByLine(2)
        t.check(m.scrollOffset.y > 0)
        m.resetScroll()
        t.equal(m.selectionRange, 0..<1)
    }

    t.suite("TextEdit: ResetScroll and undo preserve a soft-wrapped caret's line affinity") {
        let (_, m) = try editor("Multiline=1\nClipString=1\nInitialText=ABCDEFGHIJKLMNOPQRST")
        m.focus()
        m.select(start: 5, length: 0)
        m.handleKeyInput(.move(.lineEnd, selecting: false))
        let before = m.lower().editing
        t.check((before?.caretOffset ?? 0) > 5)
        t.equal(before?.caretLine, 0)
        m.resetScroll()
        t.equal(m.lower().editing?.caretLine, 0, "resetting the viewport does not move a wrapped caret to the next line")
        m.handleKeyInput(.insert("x"))
        m.undo()
        t.equal(m.inputText, "ABCDEFGHIJKLMNOPQRST")
        t.equal(m.lower().editing?.caretOffset, before?.caretOffset)
        t.equal(m.lower().editing?.caretLine, 0)
    }

    t.suite("TextEdit: pointer hit testing, captured drag and Shift extension share shaped positions") {
        let (_, m) = try editor("InitialText=ABCDEFGHIJKLMNOPQRST")
        let cell = TextStyle.pixelSize(points: m.style.fontSize) * 0.5
        m.beginSelection(at: SkinPoint(x: m.contentFrame.x + cell * 2, y: m.contentFrame.y + 1))
        t.equal(m.caretPosition, 2)
        t.check(m.isSelecting)
        m.extendSelection(to: SkinPoint(x: m.contentFrame.x + cell * 5, y: m.contentFrame.y + 1))
        t.equal(m.selectionRange, 2..<5)
        m.endSelection()
        t.check(!m.isSelecting)
        m.beginSelection(at: SkinPoint(x: m.contentFrame.x + cell, y: m.contentFrame.y + 1), extending: true)
        t.equal(m.selectionAnchor, 2)
        t.equal(m.selectionRange, 1..<2)
        m.extendSelection(to: SkinPoint(x: 1000, y: m.contentFrame.y + 1))
        t.equal(m.caretPosition, 20)
        t.check(m.scrollOffset.x > 0)
        m.endSelection()
        m.extendSelection(to: SkinPoint())
        t.equal(m.caretPosition, 20, "an uncaptured movement does not change the selection")
    }

    t.suite("TextEdit: empty placeholders do not become selectable input and blink follows focus") {
        let (skin, m) = try editor("PlaceholderText=Type here\nPlaceholderFontSize=30\nOnFocusAction=[!SetVariable Focused yes]")
        m.focus()
        t.equal(skin.variable("Focused"), "yes")
        t.equal(m.clipboardText, nil)
        t.equal(m.displayedCaretOffset, 0)
        t.equal(m.lower().editing?.layoutText, "")
        t.equal(m.lower().editing?.layoutStyle?.fontSize, 10)
        t.check(m.caretVisible)
        t.check(m.toggleCaretBlink())
        t.check(!m.caretVisible)
        m.handleKeyInput(.insert("x"))
        t.check(m.caretVisible)
        m.dismiss()
        t.check(!m.toggleCaretBlink())
        t.check(!m.handleKeyInput(.insert("y")))
        t.equal(m.inputText, "x")
    }
}
