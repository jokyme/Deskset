import AppKit
import DeskLanguage
import DesksetCore
import UniformTypeIdentifiers

/// A text file Deskset's built-in code editor opens outside the skin editor: one no running skin reads — a skin's
/// `["#CONFIGEDITOR#" "#@#Scripts/Clock.lua"]` or `"#@#Settings.cfg"`, Open With ▸ Deskset on a loose .ini. With
/// "Deskset (built-in)" chosen in Settings ▸ Editor such files never go to the Launch Services default (on many Macs an
/// IDE the user never chose for skins): they get this window, the same code editor as the skin editor's code pane —
/// highlighting, find, encoding and line endings kept byte for byte, commits after a pause, on ⌘S, when the window
/// stops being key and when it closes. Desk documents also show their checked static program as a local preview.
/// A change made on disk meanwhile is picked up when the window
/// becomes key (a clean buffer) or asked about before it is written over (see `CodeEditorView.onDiskConflict`).
final class CodeFileWindowController: NSWindowController, NSWindowDelegate {
    let file: URL
    let codeView: CodeEditorView
    unowned let app: AppController
    /// Asked when the window closes with edits that could not be saved (self-tests answer it; nil: an alert).
    var closeChoice: (() -> InspectorWindowController.CloseChoice)?
    /// Editing/checking only; a Desk document has no Skin or desktop copy.
    private(set) var deskChecking: DeskCodeDocumentChecking?
    private(set) var readError: String?
    private(set) var deskDecorations: DeskCodeDecorations?
    private(set) var deskPreview: DeskProgramPreviewController?

    /// A native list is bound to both the check and its original caret. Previewing entries never edits a buffer.
    private struct DeskCompletionSession {
        let snapshot: DeskSnapshot
        let selection: NSRange
        let range: NSRange
        let items: [DeskCompletionItem]
        let titles: [String]
    }
    private var deskCompletion: DeskCompletionSession?

    init(file: URL, app: AppController, deskCheckQueue: DispatchQueue? = nil) throws {
        self.file = file.standardizedFileURL
        self.app = app
        codeView = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 760, height: 580))
        codeView.setFontSize(CGFloat(app.state.editor.codeFontSize))
        if self.file.pathExtension.lowercased() == "desk" {
            codeView.decodeDocument = DeskCodeDocumentChecking.document(from:file:)
        }
        try codeView.open(files: [self.file], current: self.file)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = self.file.lastPathComponent
        window.subtitle = self.file.deletingLastPathComponent().path
        // The title's document icon comes from the system's icon service. Headless (self-tests, snapshots) nothing is
        // shown, and on CI's Intel runner that service never answers.
        if app.presentsWindows { window.representedURL = self.file }
        window.contentMinSize = NSSize(width: 360, height: 240)
        codeView.frame = window.contentLayoutRect
        codeView.autoresizingMask = [.width, .height]
        window.contentView = codeView
        super.init(window: window)
        window.delegate = self
        if self.file.pathExtension.lowercased() == "desk" {
            let queue = deskCheckQueue ?? DispatchQueue(label: "deskset.document.check", qos: .userInitiated)
            let checking = DeskCodeDocumentChecking(file: self.file, editor: codeView, checkingOn: queue)
            deskChecking = checking
            let preview = DeskProgramPreviewController { [weak self] snapshot in
                guard let self, self.readError == nil else { return false }
                return self.deskChecking?.isCurrent(snapshot) == true
            }
            deskPreview = preview
            let codeController = NSViewController()
            codeController.view = codeView
            let split = NSSplitViewController()
            split.splitView.isVertical = true
            let codeItem = NSSplitViewItem(viewController: codeController)
            let previewItem = NSSplitViewItem(viewController: preview)
            codeItem.minimumThickness = 360
            previewItem.minimumThickness = 280
            split.addSplitViewItem(codeItem)
            split.addSplitViewItem(previewItem)
            window.contentViewController = split
            window.contentMinSize = NSSize(width: 700, height: 240)
            window.setContentSize(NSSize(width: 1040, height: 580))
            codeView.onCompletionRange = { [weak self] in
                self?.prepareDeskCompletion() ?? NSRange(location: NSNotFound, length: 0)
            }
            codeView.onCompletions = { [weak self] range in self?.deskCompletionWords(for: range) ?? [] }
            codeView.onInsertCompletion = { [weak self] word, range, movement, isFinal in
                self?.insertDeskCompletion(word, range: range, movement: movement, isFinal: isFinal)
            }
            let decorations = DeskCodeDecorations()
            decorations.attach(to: codeView)
            deskDecorations = decorations
            checking.onSnapshot = { [weak self] snapshot in self?.showDeskCheck(snapshot) }
            codeView.onReadError = { [weak self] _, error in
                self?.deskCompletion = nil
                self?.readError = error.localizedDescription
                self?.deskDecorations?.clear()
                if let self, let snapshot = self.deskChecking?.snapshot {
                    self.deskPreview?.show(snapshot, readError: error.localizedDescription)
                }
                self?.window?.subtitle = error.localizedDescription
                Log.write("Code editor: \(error.localizedDescription)", level: .error)
            }
            showDeskCheck(checking.snapshot)
        }
        codeView.onFontSizeChange = { [weak app] size in
            let range = EditorPreferences.fontSizes
            app?.state.updateEditor { $0.codeFontSize = min(max(Double(size), range.lowerBound), range.upperBound) }
        }
        if app.presentsWindows {
            window.setFrameAutosaveName("DesksetCodeFileWindow")
            if !window.setFrameUsingName("DesksetCodeFileWindow") { window.center() }
        } else {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `line` (1-based), caret at its start.
    func reveal(line: Int?) {
        guard let line, line > 0 else { return }
        codeView.reveal(line: line, in: file, select: false)
    }

    /// Coming back to the window: the file as it is on disk now (a clean buffer takes it, keeping the caret).
    func windowDidBecomeKey(_ notification: Notification) {
        let revision = codeView.textRevision
        readError = nil
        codeView.reloadFromDisk(keepCaret: true)
        if let checking = deskChecking {
            if readError == nil, codeView.textRevision == revision { checking.recheck() }
            showDeskCheck(checking.snapshot)
        }
    }

    /// Closing (or quitting) saves the edits; when that fails: Save (try again), Discard Changes, or Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if codeView.commitNow(explicit: true) || !codeView.hasUncommittedChanges { return true }
        switch askAboutUncommittedCode() {
        case .save: return codeView.commitNow(explicit: true)
        case .discard:
            codeView.discardUncommittedChanges()
            return true
        case .cancel: return false
        }
    }

    func canTerminate() -> Bool {
        guard let window else { return true }
        return windowShouldClose(window)
    }

    private func askAboutUncommittedCode() -> InspectorWindowController.CloseChoice {
        if let closeChoice { return closeChoice() }
        guard app.presentsWindows, let window else { return .cancel }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Your changes to \(file.lastPathComponent) couldn’t be saved"
        alert.informativeText = "Save tries again. If you discard them, the file stays as it is on disk."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    func windowWillClose(_ notification: Notification) {
        deskCompletion = nil
        codeView.onCompletionRange = nil
        codeView.onCompletions = nil
        codeView.onInsertCompletion = nil
        deskChecking?.close()
        deskDecorations?.detach()
        deskPreview?.close()
        app.codeFileWindowDidClose(self)
    }

    /// Only the current finished check supplies cards, ranges and actions. Pending checks and failed reads clear
    /// the previous display; the existing subtitle and document save/conflict behavior remain the same.
    private func showDeskCheck(_ snapshot: DeskSnapshot) {
        deskCompletion = nil
        deskPreview?.show(snapshot, readError: readError)
        if readError == nil, snapshot.isChecked, deskChecking?.isCurrent(snapshot) == true {
            deskDecorations?.show(snapshot.diagnostics, file: snapshot.file, text: snapshot.text,
                                  language: snapshot.options.messageLanguage,
                                  actions: { diagnostic in
                                      snapshot.codeActions(for: diagnostic).filter { $0.edit.changedFiles == [snapshot.file] }
                                  }, onAction: { [weak self] action in
                                      _ = self?.applyDeskAction(action, from: snapshot)
                                  })
        } else {
            deskDecorations?.clear()
        }
        if let readError { window?.subtitle = readError }
        else if snapshot.isChecked, let diagnostic = snapshot.diagnostics.first(where: \.isProblem) {
            window?.subtitle = diagnostic.message
        } else {
            window?.subtitle = file.deletingLastPathComponent().path
        }
    }

    /// A menu from an older check cannot modify the current buffer or read a sibling file.
    @discardableResult
    func applyDeskAction(_ action: DeskCodeAction, from snapshot: DeskSnapshot) -> Bool {
        guard readError == nil, window != nil, let checking = deskChecking else { return false }
        return checking.apply(action.edit, from: snapshot, actionName: action.title)
    }

    // MARK: Native checked completions

    private func prepareDeskCompletion() -> NSRange {
        deskCompletion = nil
        let absent = NSRange(location: NSNotFound, length: 0)
        guard readError == nil, window != nil, let checking = deskChecking,
              codeView.textView.isEditable, !codeView.textView.hasMarkedText() else { return absent }
        let snapshot = checking.snapshot
        let selection = codeView.textView.selectedRange()
        guard snapshot.isChecked, checking.isCurrent(snapshot), selection.length == 0,
              selection.location != NSNotFound, selection.location >= 0,
              selection.location <= snapshot.index.utf16Count,
              snapshot.index.clampedUTF16(selection.location) == selection.location else { return absent }
        let list = snapshot.completions(at: snapshot.index.position(utf16: selection.location))
        let start = list.context.range.start.offset, end = list.context.range.end.offset
        guard !list.items.isEmpty, start >= 0, start <= selection.location, selection.location <= end,
              end <= snapshot.index.utf16Count, snapshot.index.clampedUTF16(start) == start,
              snapshot.index.clampedUTF16(end) == end else { return absent }
        // AppKit completes the prefix before the caret; the accepted service edit still replaces the whole word.
        let range = NSRange(location: start, length: selection.location - start)
        var used: Set<String> = []
        let titles = list.items.map { item -> String in
            let base = item.label + " — " + item.detail.text(in: snapshot.options.messageLanguage)
            var title = base, ordinal = 2
            while !used.insert(title).inserted {
                title = base + " (\(ordinal))"
                ordinal += 1
            }
            return title
        }
        deskCompletion = DeskCompletionSession(snapshot: snapshot, selection: selection, range: range,
                                              items: list.items, titles: titles)
        return range
    }

    private func deskCompletionWords(for range: NSRange) -> [String] {
        guard let session = deskCompletion, range == session.range, readError == nil,
              codeView.textView.selectedRange() == session.selection, codeView.textView.isEditable,
              !codeView.textView.hasMarkedText(), session.snapshot.isChecked,
              deskChecking?.isCurrent(session.snapshot) == true else { deskCompletion = nil; return [] }
        return session.titles
    }

    private func insertDeskCompletion(_ word: String, range: NSRange, movement: Int, isFinal: Bool) {
        // Native keyboard navigation previews labels. Only a final selection may create one complete user edit;
        // AppKit also sends a final insertion of the original text when the list is cancelled.
        guard isFinal else { return }
        defer { deskCompletion = nil }
        guard movement != NSCancelTextMovement, let session = deskCompletion, range == session.range,
              readError == nil, window != nil, codeView.textView.selectedRange() == session.selection,
              !codeView.textView.hasMarkedText(), let checking = deskChecking,
              let selected = session.titles.firstIndex(of: word), session.items.indices.contains(selected) else { return }
        let item = session.items[selected]
        // Use the catalog's plain fallback. Snippet markers never become document text; all extra edits address
        // the same original buffer and are validated before normalization by the checker.
        let edits = ([DeskTextEditU16(range: item.range, newText: item.plainText)] + item.additionalEdits).map { edit in
            DeskTextEditU16(range: edit.range,
                            newText: CodeTextView.convertingLineEndings(edit.newText, to: codeView.textView.lineEnding))
        }
        _ = checking.apply(edits, from: session.snapshot, actionName: StudioText.format(.completeNamed, item.label))
    }

    // MARK: Which files

    /// Extensions of the text files skins hand to their editor (and a few more), opened in the built-in editor
    /// without looking inside them.
    static let textExtensions: Set<String> = [
        "ini", "inc", "lua", "txt", "text", "cfg", "conf", "config", "json", "xml", "css", "js", "html", "htm", "md",
        "markdown", "nfo", "log", "csv", "tsv", "yaml", "yml", "toml", "bat", "cmd", "ps1", "ahk", "vbs", "sh", "py",
        "rainmeter", "list", "dat", "desk",
    ]

    /// Whether the built-in code editor can show `url`: a known text extension, a type macOS knows as plain text or
    /// source code, or — without an extension or with one nobody declared — bytes that look like text (no NUL byte in
    /// the first 64 KB, unless it starts with a Unicode byte order mark).
    static func isTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.isDeclared {
            return type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
                || type.conforms(to: .xml) || type.conforms(to: .html)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 65_536)) ?? Data()
        if sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF]) || sample.starts(with: [0xEF, 0xBB, 0xBF]) {
            return true
        }
        return !sample.contains(0)
    }
}
