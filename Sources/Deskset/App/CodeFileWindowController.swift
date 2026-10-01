import AppKit
import DeskLanguage
import DesksetCore
import UniformTypeIdentifiers

/// A text file Deskset's built-in code editor opens outside the skin editor: one no running skin reads — a skin's
/// `["#CONFIGEDITOR#" "#@#Scripts/Clock.lua"]` or `"#@#Settings.cfg"`, Open With ▸ Deskset on a loose .ini. With
/// "Deskset (built-in)" chosen in Settings ▸ Editor such files never go to the Launch Services default (on many Macs an
/// IDE the user never chose for skins): they get this window, the same code editor as the skin editor's code pane —
/// highlighting, find, encoding and line endings kept byte for byte, commits after a pause, on ⌘S, when the window
/// stops being key and when it closes — without a canvas. A change made on disk meanwhile is picked up when the window
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
            let decorations = DeskCodeDecorations()
            decorations.attach(to: codeView)
            deskDecorations = decorations
            checking.onSnapshot = { [weak self] snapshot in self?.showDeskCheck(snapshot) }
            codeView.onReadError = { [weak self] _, error in
                self?.readError = error.localizedDescription
                self?.deskDecorations?.clear()
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
        deskChecking?.close()
        deskDecorations?.detach()
        app.codeFileWindowDidClose(self)
    }

    /// Only the current finished check supplies read-only cards and ranges. Pending checks and failed reads clear
    /// the previous display; the existing subtitle and document save/conflict behavior remain the same.
    private func showDeskCheck(_ snapshot: DeskSnapshot) {
        if readError == nil, snapshot.isChecked {
            deskDecorations?.show(snapshot.diagnostics, file: snapshot.file, text: snapshot.text,
                                  language: snapshot.options.messageLanguage)
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
