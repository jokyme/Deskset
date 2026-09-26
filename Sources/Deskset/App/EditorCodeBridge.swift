import AppKit
import DesksetCore

/// The skin editor's code pane (docs/editor-design.md §5) and where `CodeEditorRouter` meets the editor when the
/// built-in editor is chosen.
///
/// - Commit model: the code pane's buffer is committed through `perform("Edit Code")` — the bytes written in the
///   file's own encoding, one `EditorFileChange` undo step on the window's undo stack, then a refresh. Every visual
///   edit commits a dirty buffer first (`flushCode`), and after every refresh the clean buffers re-read the disk,
///   keeping caret and scroll.
/// - Selection sync is origin-tagged: selecting a layer, data source, style or the skin scrolls the code to its
///   section (switching files when an @Include file defines it) and tints the block, without taking the focus; the
///   caret coming to rest in a section selects what it defines. The code pane reports only the user's caret moves, and
///   a selection made from the code only tints, so neither side can start a loop.
extension InspectorWindowController {
    // MARK: Building

    /// The code pane; its editor is made when the code first shows (`installCodeView`).
    func buildCodePane() {
        codePane.setAccessibilityElement(true)
        codePane.setAccessibilityRole(.group)
        codePane.setAccessibilityLabel("Code")
    }

    /// Puts the code editor, just made, in the code pane (see `codeView`).
    func installCodeView(_ codeView: CodeEditorView) {
        codeView.translatesAutoresizingMaskIntoConstraints = false
        codePane.addSubview(codeView)
        NSLayoutConstraint.activate([
            codeView.topAnchor.constraint(equalTo: codePane.safeAreaLayoutGuide.topAnchor),
            codeView.leadingAnchor.constraint(equalTo: codePane.leadingAnchor),
            codeView.trailingAnchor.constraint(equalTo: codePane.trailingAnchor),
            codeView.bottomAnchor.constraint(equalTo: codePane.bottomAnchor),
        ])
        codeView.setFontSize(CGFloat(app.state.editor.codeFontSize))
        codeView.onCommit = { [weak self] url, text in self?.commitCode(url, text) ?? false }
        codeView.onCaretSection = { [weak self] url, section in self?.codeCaretRested(in: section, file: url) }
        codeView.onFileChange = { [weak self] _ in self?.tintSelectionInCode() }
        NotificationCenter.default.addObserver(self, selector: #selector(codeScrolled(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: codeView.scrollView.contentView)
        codeView.onFontSizeChange = { [weak self] size in
            let range = EditorPreferences.fontSizes
            self?.app.state.updateEditor { $0.codeFontSize = min(max(Double(size), range.lowerBound), range.upperBound) }
        }
    }

    // MARK: Keeping the code up to date

    /// Brings the code pane up to date with the skin: its files (main .ini first, then the @Include files) are opened,
    /// clean buffers re-read from disk keeping caret and scroll, and the selection is revealed (`reveal`) or only
    /// tinted. A hidden code pane is marked stale instead and catches up when it appears.
    func syncCodePane(reveal: Bool, otherSkin: Bool = false) {
        guard let skin, isCodeVisible else {
            codeStale = true
            return
        }
        let files = skin.sourceFiles
        let keys = Set(files.map(CodeEditorRouter.comparablePath))
        // Stay in the file that is shown while the skin still reads it.
        let current = otherSkin ? nil : codeView.currentFile.flatMap { url in
            keys.contains(CodeEditorRouter.comparablePath(url)) ? url : nil
        }
        do {
            let kept = try codeView.open(files: files, current: current ?? skin.fileURL)
            if !kept.isEmpty {
                toast.show("Edits to \(kept.map(\.lastPathComponent).joined(separator: ", ")) are not saved yet", error: true)
            }
        } catch {
            Log.write("Code editor: cannot open \(skin.fileURL.lastPathComponent): \(error.localizedDescription)",
                      level: .error)
            return
        }
        codeView.reloadFromDisk(keepCaret: true)
        // The scroll view skipped placing its line-number ruler while the pane was hidden.
        codeView.scrollView.tile()
        keepCodeClearOfRuler()
        codeStale = false
        if reveal { revealSelectionInCode() } else { tintSelectionInCode() }
    }

    /// The code's clip view leaves room for the line numbers through its left content inset, but a scroll to x = 0
    /// (the code editor restores scroll positions that way when it shows another file or re-reads one) puts the text
    /// under the ruler. Any horizontal position the insets do not allow is put back.
    @objc func codeScrolled(_ notification: Notification) {
        keepCodeClearOfRuler()
    }

    func keepCodeClearOfRuler() {
        let clip = codeView.scrollView.contentView
        let allowed = clip.constrainBoundsRect(clip.bounds).origin
        guard abs(allowed.x - clip.bounds.origin.x) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: allowed.x, y: clip.bounds.origin.y))
        codeView.scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Commit model

    /// The code pane's commit: writes `text` in the file's encoding (BOM and line endings kept), as one undo step,
    /// and refreshes the skin. False keeps the buffer dirty (the write failed, or no skin is loaded).
    func commitCode(_ url: URL, _ text: String) -> Bool {
        guard let document = codeView.document(for: url), let data = document.data(for: text) else { return false }
        let target = CodeDocument.writeTarget(for: url)
        committingCode = true
        defer { committingCode = false }
        return perform("Edit Code", files: [target], flushingCode: false, message: nil) {
            try data.write(to: target, options: .atomic)
        }
    }

    /// Commits a dirty code buffer before a visual edit writes, so no typing is lost and the edit applies to what the
    /// user sees in the code. False when it could not be committed (the visual edit is then not written either).
    @discardableResult
    func flushCode() -> Bool {
        guard !committingCode, let codeView = loadedCodeView, codeView.hasUncommittedChanges else { return true }
        if codeView.commitNow() { return true }
        toast.show("Your code changes couldn’t be saved — save or undo them first", error: true)
        NSSound.beep()
        return false
    }

    /// A visual edit with typed code not committed yet: the code is committed now and `edit` runs on the next turn of
    /// the run loop — against the skin as the code left it, and as an undo step of its own (the undo manager groups
    /// what one event registers). True when `edit` was deferred, or dropped because the code could not be saved
    /// (`flushCode` says so); false when there was nothing to commit and the caller goes on.
    func deferUntilCodeIsCommitted(_ edit: @escaping () -> Void) -> Bool {
        guard !committingCode, codeHasUncommittedChanges else { return false }
        if flushCode() { DispatchQueue.main.async(execute: edit) }
        return true
    }

    /// Like `deferUntilCodeIsCommitted`, for edits that must also see what the inspector has not written yet: a value
    /// typed in a field whose editing has not ended (a click on a button does not end it) and a live preview. They
    /// are committed first, and `edit` runs on the next turn against the result, as its own undo step. For edits that
    /// renumber what fields refer to (moving or removing a shape, a gradient color, a Combine step), and for adding
    /// or removing layers. False when nothing was pending (the caller goes on).
    func deferUntilEditsAreCommitted(_ edit: @escaping () -> Void) -> Bool {
        guard !committingCode else { return false }
        let typed = inspectorFieldHasTypedText
        let previewing = inspectorState.preview != nil
        guard codeHasUncommittedChanges || typed || previewing else { return false }
        guard flushCode() else { return true }
        if previewing { commitPendingPreview() }
        if typed { commitInspectorEditing() }
        DispatchQueue.main.async(execute: edit)
        return true
    }

    /// Whether the code pane holds typed code not written yet.
    var codeHasUncommittedChanges: Bool { loadedCodeView?.hasUncommittedChanges ?? false }

    /// The inspector text field being edited (its field editor has the focus), if any.
    var editedInspectorField: NSTextField? {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField, field.isDescendant(of: inspectorStack) else { return nil }
        return field
    }

    /// Whether the field being edited holds text that is not written yet.
    var inspectorFieldHasTypedText: Bool {
        guard let field = editedInspectorField, let editor = field.currentEditor() else { return false }
        if let value = field as? ValueField { return editor.string != value.original }
        if let combo = field as? ValueComboBox { return editor.string != combo.original }
        if let edit = fieldEdits[ObjectIdentifier(field)] {
            let old = edit.own ? rawGeometryValue(edit.key) : rows.first { $0.key == edit.key }?.raw
            return editor.string != (old ?? "")
        }
        return false
    }

    /// Writes what is typed in the inspector field being edited, now (as Return would) — before the window closes, an
    /// edit that renumbers, or the skin goes away. The field keeps the focus (a rebuild gives it back).
    func commitInspectorEditing() {
        guard let field = editedInspectorField else { return }
        field.validateEditing()
        if let value = field as? ValueField {
            value.finishEditing(deferred: false)
        } else if let combo = field as? ValueComboBox {
            combo.commitNow()
        } else if fieldEdits[ObjectIdentifier(field)] != nil {
            fieldCommitted(field)
        }
    }

    // MARK: Selection sync

    /// The section the code shows for the selection: the selected layer, data source or style, `[Variables]` for the
    /// theme, `[Rainmeter]` for the skin itself.
    var codeSectionForSelection: String? {
        guard let skin else { return nil }
        let name = selectedKind == .variables ? "Variables" : (selectedSection ?? "Rainmeter")
        return skin.sources.location(section: name) != nil ? name : nil
    }

    /// The URL the code pane uses for `url` (the same file under another spelling, e.g. through a symlink, must not
    /// open a second buffer).
    func codeFile(for url: URL) -> URL {
        let key = CodeEditorRouter.comparablePath(url)
        return loadedCodeView?.files.first { CodeEditorRouter.comparablePath($0) == key } ?? url
    }

    /// Scrolls the code to the selection's section (in the file that defines it) and tints the block. Never takes the
    /// focus; a selection made from the code only tints.
    func revealSelectionInCode() {
        guard isCodeVisible, !codeStale, let codeView = loadedCodeView else { return }
        guard !selectionFromCode else { return tintSelectionInCode() }
        guard let skin, let name = codeSectionForSelection, let file = skin.sources.location(section: name)?.file else {
            return codeView.tintSection(lines: nil)
        }
        codeView.revealSection(name, in: codeFile(for: file))
    }

    /// Tints the selection's section when the shown file defines it (nothing moves).
    func tintSelectionInCode() {
        guard isCodeVisible, let codeView = loadedCodeView else { return }
        guard let skin, let name = codeSectionForSelection, let file = skin.sources.location(section: name)?.file,
              let shown = codeView.currentFile,
              CodeEditorRouter.comparablePath(shown) == CodeEditorRouter.comparablePath(file),
              let lines = codeView.lineRange(ofSection: name) else { return codeView.tintSection(lines: nil) }
        codeView.tintSection(lines: lines)
    }

    /// The caret came to rest in `section` of `file` after a user move: select what it defines — the layer or data
    /// source (switching the sidebar tab), the style, or the skin itself for `[Rainmeter]`, `[Metadata]` and
    /// `[Variables]`.
    func codeCaretRested(in section: String?, file: URL) {
        guard let section, skin != nil else { return }
        selectionFromCode = true
        defer { selectionFromCode = false }
        let item = allItems.first { $0.title.caseInsensitiveCompare(section) == .orderedSame }
        switch item?.kind {
        case .meter?, .measure?, .other?:
            guard let item else { return }
            if item.title == selectedSection, !isMultiSelection {
                // Already selected: only the tab follows.
                if item.kind == .meter, sidebarTab != .layers { selectSidebarTab(.layers) }
                if item.kind == .measure, sidebarTab != .data { selectSidebarTab(.data) }
                return
            }
            select(section: item.title)
        default:
            guard ["rainmeter", "metadata", "variables"].contains(section.lowercased()) else { return }
            if selectedSection != nil || isMultiSelection { canvasSelectionChanged([]) }
            if sidebarTab == .data { selectSidebarTab(.layers) }
        }
        tintSelectionInCode()
    }

    // MARK: CodeEditorRouter

    /// Shows `file` (the skin's main file or one it includes) at `line` (1-based): selects what is defined at or above
    /// that line — the layer, data source, style, variables or skin settings whose `[Section]` header is the last one
    /// before the line — and shows the line in the code pane, switching to Split from Design. "Show in Code", a source
    /// link, the Manage window's Edit, `!EditSkin` and a skin's `["#CONFIGEDITOR#" "#@#Styles.inc"]` land here with the
    /// built-in editor.
    ///
    /// Returns the selected section (nil when there was no line, or nothing selectable there).
    @discardableResult
    func revealInCode(file: URL, line: Int?) -> String? {
        guard let skin else { return nil }
        let target = skin.sourceFiles.first {
            CodeEditorRouter.comparablePath($0) == CodeEditorRouter.comparablePath(file)
        } ?? file
        var selected: String?
        if let line, line > 0, let text = try? TextDecoding.readFile(at: target),
           let name = Self.sectionName(atLine: line, in: text),
           allItems.contains(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            select(section: name)
            selected = selectedSection
        }
        guard !usesExternalEditor else { return selected }
        if mode == .design { setMode(lastCodeMode) }
        if codeStale { syncCodePane(reveal: false) }
        let url = codeFile(for: target)
        if let line, line > 0 {
            codeView.reveal(line: line, in: url, select: false)
        } else if codeView.currentFile.map(CodeEditorRouter.comparablePath) != CodeEditorRouter.comparablePath(url) {
            codeView.reveal(line: 1, in: url, select: false)
        }
        tintSelectionInCode()
        return selected
    }

    /// The name in the last `[Section]` header at or above `line` (1-based) of one INI file's text, nil above the
    /// first header. Lines end at `\r\n`, `\r` or `\n`; a header's name ends at the first `]` and is trimmed of
    /// spaces and tabs (the reader's rules; comments and `Key=[!Bang]` values never start with `[`).
    static func sectionName(atLine line: Int, in text: String) -> String? {
        var current: String?
        var number = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            number += 1
            if number > line { break }
            let trimmed = raw.drop { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }
            guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { continue }
            let name = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if !name.isEmpty { current = name }
        }
        return current
    }
}
