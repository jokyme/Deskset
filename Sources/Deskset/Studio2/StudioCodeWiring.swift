import AppKit
import DesksetCore

/// What the window keeps about its code pane.
final class StudioCodeState {
    enum Mode: Equatable {
        /// Next to the canvas.
        case alongside
        /// The code alone (⌃⌘3), for long writing.
        case only
    }

    var mode = Mode.alongside
    /// The diagnostics shown: of the text typed when it is newer than the widget, else of the widget.
    var diagnostics: [IniDiagnostic] = []
    /// The diagnostics of the widget's instance they were worked out for (the hold asks for them too), as of its text
    /// then: a patch gives the same instance new text (`Skin.sourceGeneration`).
    var checked: [IniDiagnostic] = []
    var checkedGeneration = -1
    /// The red problems of the version the desktop runs (nil: not known yet): only a new one holds the desktop.
    var desktopProblems: Set<String>?
    /// Files other widgets share, written while the desktop was held: those widgets load again once it is not.
    var othersWaiting: [URL] = []
    weak var checkedSkin: Skin?
    var checkTimer: Timer?
    var committing = false
    /// The name of the next step the code makes ("Fix FontColr"; else "Typing").
    var nextStepName: String?
    /// Why the last commit was not written.
    var saveError: String?
    /// Where each part was the last time it could draw (the canvas's ghosts of parts that can't).
    var lastGoodFrames: [String: SkinRect] = [:]
    /// The file menu is open (headless: the snapshot draws it).
    var fileMenuShown = false
    var observers: [NSObjectProtocol] = []
    var logWindow: StudioLogWindowController?

    /// The code column's share of the window when shown alongside the preview.
    static let codeShare: CGFloat = 0.62

    /// The editor "Open in …" names (Settings ▸ Editor, else the Mac's app for the file). Snapshots set a fixed one.
    static var editorName: (URL, AppController) -> String? = { url, app in
        if let editor = CodeEditorRouter.externalEditor(for: app.state.editor, file: url) { return editor.name }
        return CodeEditorRouter.locator.defaultApplicationURL(toOpen: url).map { CodeEditorApp.displayName(of: $0) }
    }

    deinit {
        checkTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Typed code over the session's text: what the check reads before the code is committed.
private final class TypedSources: SourceProvider {
    let base: SourceProvider
    let file: SourceFileID
    let text: String

    init(base: SourceProvider, file: URL, text: String) {
        self.base = base
        self.file = SourceFileID(file)
        self.text = text
    }

    func sourceText(for url: URL) -> String? {
        SourceFileID(url) == file ? text : base.sourceText(for: url)
    }
}

extension StudioWindowController {
    var codeView: CodeEditorView { codeController.codeView }

    // MARK: Wiring

    func wireCode() {
        _ = codeController.view
        let cv = codeView
        cv.onCommit = { [weak self] url, text in self?.commitCode(url, text) ?? false }
        cv.readData = { [weak self] url in
            if let session = self?.session { return try session.data(of: url) }
            return try Data(contentsOf: url)
        }
        cv.onCaretSection = { [weak self] url, section in self?.codeCaretRested(section, file: url) }
        cv.onFileChange = { [weak self] _ in
            self?.codeView.tintSection(lines: nil)
            self?.showDiagnostics()
        }
        cv.onFontSizeChange = { [weak self] size in
            let range = EditorPreferences.fontSizes
            self?.app.state.updateEditor { $0.codeFontSize = min(max(Double(size), range.lowerBound), range.upperBound) }
        }
        cv.setFontSize(CGFloat(app.state.editor.codeFontSize))
        codeController.decorations.onFix = { [weak self] d in self?.fix(d) }
        let header = codeController.header
        header.fileButton.action = { [weak self] in self?.showFileMenu() }
        header.problemsChip.action = { [weak self] in self?.revealNext(.problem) }
        header.warningsChip.action = { [weak self] in self?.revealNext(.warning) }
        header.logChip.action = { [weak self] in self?.showLog(allWidgets: false) }
        header.moreButton.action = { [weak self] in self?.showMoreMenu() }
        codeState.observers.append(NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: cv.textView, queue: .main) { [weak self] _ in
                self?.codeTyped()
            })
        codeState.observers.append(NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: cv.textView, queue: .main) { [weak self] _ in
                self?.updateCodeHeader()
                self?.updateCodeStatus()
            })
    }

    /// The window shows a session: the code commits through it, and the desktop copy keeps its version while the widget
    /// has a problem that stops a part from drawing.
    func codeAttached(_ session: EditingSession) {
        codeState.lastGoodFrames = [:]
        codeState.checked = []
        codeState.checkedSkin = nil
        codeState.saveError = nil
        codeState.desktopProblems = nil
        codeState.othersWaiting = []
        session.holdsDesktop = { [weak self] skin in self?.holdsDesktop(skin) ?? false }
        session.willApply = { [weak self] in self?.flushCode() }
    }

    /// The red problems the desktop's version has: those of the widget's instance as the window takes it (the version
    /// the desktop runs; asked once the instance is there).
    func noteDesktopProblems() {
        guard codeState.desktopProblems == nil, let skin else { return }
        codeState.desktopProblems = Self.redKeys(diagnostics(of: skin))
    }

    func codeDetached(_ session: EditingSession) {
        codeState.checkTimer?.invalidate()
        codeState.checkTimer = nil
        if codeController.isViewLoaded, codeView.hasUncommittedChanges { codeView.commitNow(explicit: true) }
        session.holdsDesktop = nil
        session.willApply = nil
        session.endHold()
        codeState.othersWaiting = []
        codeState.desktopProblems = nil
    }

    // MARK: Panes

    var isCodeShown: Bool { !codeItem.isCollapsed }

    /// Shows the code next to the canvas (`alongside`) or alone (`only`).
    func setCodeMode(_ mode: StudioCodeState.Mode) {
        guard let window else { return }
        codeState.mode = mode
        canvasItem.isCollapsed = mode == .only
        codeItem.isCollapsed = false
        window.contentView?.layoutSubtreeIfNeeded()
        placeCode()
        syncCode()
        canvasController.besideCode = true
        window.contentView?.layoutSubtreeIfNeeded()
        codeController.layOut()
        canvasController.view.needsLayout = true
        updateToolbar()
        updateCodeHeader()
    }

    /// The left code column's width (wider than the right preview column).
    func placeCode() {
        guard !codeItem.isCollapsed else { return }
        let split = splitController.splitView
        split.layoutSubtreeIfNeeded()
        let divider = split.dividerThickness
        let total = split.bounds.width
        let width: CGFloat
        if canvasItem.isCollapsed {
            width = total
        } else {
            let wanted = (total * StudioCodeState.codeShare).rounded()
            width = min(max(420, wanted), max(420, total - 360 - divider))
        }
        split.setPosition(width, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
    }

    func codeWindowResized() {
        guard isCodeShown, codeState.mode == .alongside else { return }
        placeCode()
    }

    // MARK: Keeping the code up to date

    /// Brings the code up to date with the widget: its files (the main one, then the included ones), clean buffers
    /// re-read keeping caret and scroll, the diagnostics.
    func syncCode() {
        guard isCodeShown, let skin else { return }
        let files = skin.sourceFiles
        let keys = Set(files.map { SourceFileID($0) })
        let current = codeView.currentFile.flatMap { keys.contains(SourceFileID($0)) ? $0 : nil }
        do {
            try codeView.open(files: files, current: current ?? skin.fileURL)
        } catch {
            Log.write("Studio: cannot open \(skin.fileURL.lastPathComponent) in the code pane: \(error.localizedDescription)",
                      level: .error)
            return
        }
        codeView.reloadFromDisk(keepCaret: true)
        codeView.scrollView.tile()
        keepCodeClearOfLineNumbers()
        refreshDiagnostics()
    }

    /// The code's clip view leaves room for the line numbers through its left inset, but a scroll to x = 0 (the editor
    /// restores scroll positions that way) puts the text under them: any position the inset does not allow goes back.
    func keepCodeClearOfLineNumbers() {
        let clip = codeView.scrollView.contentView
        let allowed = clip.constrainBoundsRect(clip.bounds).origin
        guard abs(allowed.x - clip.bounds.origin.x) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: allowed.x, y: clip.bounds.origin.y))
        codeView.scrollView.reflectScrolledClipView(clip)
    }

    /// The session changed the widget: the code follows (not while its own commit is being made: that one is known).
    func codeSessionChanged() {
        if isCodeShown, !codeState.committing { syncCode() } else { refreshDiagnostics() }
    }

    /// The caret came to rest in a section: its block is tinted.
    func codeCaretRested(_ section: String?, file: URL) {
        let lines = section.flatMap { codeView.lineRange(ofSection: $0) }
        codeView.tintSection(lines: lines)
        codeController.decorations.overlay.needsDisplay = true
        updateCodeHeader()
    }

    // MARK: Committing

    /// The code's commit: the file's text becomes `text` (in its encoding, BOM and line endings kept), one step on the
    /// widget's undo stack ("Typing"), the widget loaded again. False keeps the buffer dirty (it could not be written).
    func commitCode(_ url: URL, _ text: String) -> Bool {
        guard let session, let document = codeView.document(for: url), document.data(for: text) != nil else { return false }
        let name = codeState.nextStepName ?? StudioText[.stepTyping]
        codeState.nextStepName = nil
        codeState.committing = true
        defer { codeState.committing = false }
        do {
            _ = try session.apply(name, [.editSource(file: CodeDocument.writeTarget(for: url), text: text,
                                                     encoding: document.encoding)])
            codeState.saveError = nil
        } catch {
            codeState.saveError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            updateCodeStatus()
            return false
        }
        DispatchQueue.main.async { [weak self] in
            self?.refreshDiagnostics()
            self?.updateCodeStatus()
        }
        return true
    }

    /// A file opened for editing (Finder's Open With, `!EditSkin`, `#CONFIGEDITOR#`, "Open in built-in editor"): the
    /// code beside the canvas at `line` of `file` (the file itself without one), with the keyboard; `notice` (the
    /// skin that was asked for is no longer installed) shows over the canvas and is spoken.
    func reveal(file: URL, line: Int?, notice: String?) {
        setCodeMode(.alongside)
        if let line {
            codeView.reveal(line: line, in: file, select: false)
        } else {
            codeView.show(file: file)
        }
        window?.makeFirstResponder(codeView.textView)
        showDiagnostics()
        if let notice {
            preview.showNotice(notice)
            announce(notice)
        }
    }

    /// Commits typed code before another action runs.
    func flushCode() {
        guard !codeState.committing, codeController.isViewLoaded, codeView.hasUncommittedChanges else { return }
        codeView.commitNow()
    }

    // MARK: Diagnostics

    /// The diagnostics of the widget's instance (worked out once per instance and text: a step taken as a patch gives
    /// the same instance new text).
    func diagnostics(of skin: Skin) -> [IniDiagnostic] {
        if codeState.checkedSkin === skin, codeState.checkedGeneration == skin.sourceGeneration { return codeState.checked }
        let found = IniDiagnostics.check(skin)
        codeState.checked = found
        codeState.checkedSkin = skin
        codeState.checkedGeneration = skin.sourceGeneration
        return found
    }

    /// The editing session's hold: the desktop copy keeps its version while the widget cannot draw a part — for a red
    /// problem the desktop's version does not have already (a skin with a missing image still reaches the desktop
    /// with each step). Not held: the desktop takes this version, whose problems become the desktop's.
    func holdsDesktop(_ skin: Skin) -> Bool {
        let red = Self.redKeys(diagnostics(of: skin))
        let known = codeState.desktopProblems ?? red
        if red.subtracting(known).isEmpty {
            codeState.desktopProblems = red
            return false
        }
        return true
    }

    /// Red problems as the hold compares them: what and where, not the line (typing moves lines).
    static func redKeys(_ diagnostics: [IniDiagnostic]) -> Set<String> {
        Set(diagnostics.filter { $0.severity == .problem }.map { d in
            "\(SourceFileID(d.file).url.path.lowercased())|\(d.kind)|\(d.meters.map { $0.lowercased() }.sorted())"
        })
    }

    /// Typing: the check runs once it pauses for 0.3 seconds (never moving the caret).
    func codeTyped() {
        updateCodeStatus()
        codeState.checkTimer?.invalidate()
        let timer = Timer(timeInterval: IniDiagnostics.checkDelay, repeats: false) { [weak self] _ in
            self?.codeState.checkTimer = nil
            self?.refreshDiagnostics(typed: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        codeState.checkTimer = timer
    }

    /// Runs the check waiting for the pause now (self-tests).
    @discardableResult
    func fireCodeCheck() -> Bool {
        guard let timer = codeState.checkTimer, timer.isValid else { return false }
        timer.fire()
        return true
    }

    /// Works the diagnostics out again — of the typed text when `typed` and the code holds edits not committed, else of
    /// the widget — and shows them everywhere.
    func refreshDiagnostics(typed: Bool = false) {
        guard let skin, let session else {
            codeState.diagnostics = []
            showDiagnostics()
            return
        }
        if typed, codeController.isViewLoaded, let url = codeView.currentFile, codeView.isDirty {
            codeState.diagnostics = IniDiagnostics.check(skin, sources: TypedSources(base: session.buffers, file: url,
                                                                                    text: codeView.text))
        } else {
            codeState.diagnostics = diagnostics(of: skin)
        }
        let red = Set(codeState.diagnostics.filter { $0.severity == .problem }.flatMap(\.meters).map { $0.lowercased() })
        for m in skin.meters where !red.contains(m.name.lowercased()) && m.frame.width > 0 && m.frame.height > 0 {
            codeState.lastGoodFrames[m.name.lowercased()] = m.frame
        }
        showDiagnostics()
    }

    /// The diagnostics in the code (the file shown), the header's counts, the canvas's marks and capsule, the status.
    func showDiagnostics() {
        let all = codeState.diagnostics
        let skin = self.skin
        let title: (Meter) -> String = { m in m.name }
        if codeController.isViewLoaded, let file = codeView.currentFile {
            let id = SourceFileID(file)
            codeController.decorations.show(all.filter { SourceFileID($0.file) == id }.map {
                ($0, StudioCodeWords.message($0, skin: skin, partTitle: title))
            })
        }
        let problems = all.filter { $0.severity == .problem }
        var ghosts: [(name: String, frame: SkinRect)] = []
        var seen: Set<String> = []
        for d in problems {
            for name in d.meters where seen.insert(name.lowercased()).inserted {
                let current = skin?.meter(named: name).map(\.frame)
                if let frame = codeState.lastGoodFrames[name.lowercased()]
                    ?? current.flatMap({ $0.width > 0 && $0.height > 0 ? $0 : nil }) {
                    ghosts.append((name, frame))
                }
            }
        }
        var framed: [String] = []
        for d in all where d.severity == .warning {
            for name in d.meters where !seen.contains(name.lowercased()) && !framed.contains(name) { framed.append(name) }
        }
        canvasController.problemMarks.show(ghosts: ghosts, framed: framed)
        canvasController.showProblem(StudioCodeWords.capsule(problems: problems, skin: skin,
                                                             holding: session?.isHoldingDesktop ?? false,
                                                             partTitle: title))
        updateCodeHeader()
        updateCodeStatus()
    }

    /// Red first, then amber: the next one after the caret, in its file.
    func revealNext(_ severity: IniDiagnostic.Severity) {
        let list = codeState.diagnostics.filter { $0.severity == severity }
        guard !list.isEmpty else { return }
        let here = codeView.currentFile.map { SourceFileID($0) }
        let caret = codeView.caretLine
        let next = list.first { SourceFileID($0.file) == here && $0.line > caret } ?? list[0]
        codeView.reveal(line: next.line, in: next.file, select: false)
        showDiagnostics()
        window?.makeFirstResponder(codeView.textView)
    }

    /// "Fix": the change is made in the code (one step, named after it) and committed at once.
    func fix(_ d: IniDiagnostic) {
        guard let fix = d.fix, let session else { return }
        let what: String
        switch d.kind {
        case .unknownKey(let key, _, _): what = key
        case .unknownBang(let name, _): what = name
        default: what = fix.text
        }
        codeState.nextStepName = StudioText.format(.stepFix, what)
        if let file = codeView.currentFile, SourceFileID(file) == SourceFileID(d.file),
           let line = codeController.decorations.range(ofLine: d.line), fix.column + fix.length <= line.length {
            let range = NSRange(location: line.location + fix.column, length: fix.length)
            let tv = codeView.textView
            if tv.shouldChangeText(in: range, replacementString: fix.text) {
                tv.textStorage?.replaceCharacters(in: range, with: fix.text)
                tv.didChangeText()
            }
            codeView.commitNow(explicit: true)
        } else if let text = try? session.buffers.text(of: d.file) {
            let document = CodeDocument(text: text)
            guard d.line >= 1, d.line <= document.lineCount else { return }
            let line = document.range(ofLine: d.line)
            guard fix.column + fix.length <= line.length else { return }
            let fixed = (text as NSString).replacingCharacters(in: NSRange(location: line.location + fix.column,
                                                                           length: fix.length), with: fix.text)
            let name = codeState.nextStepName ?? StudioText[.stepTyping]
            codeState.nextStepName = nil
            _ = try? session.apply(name, [.editSource(file: CodeDocument.writeTarget(for: d.file), text: fixed,
                                                     encoding: nil)])
        }
        codeState.nextStepName = nil
        announce(StudioText.format(.stepFix, what))
    }

    // MARK: Header and status

    func updateCodeHeader() {
        guard codeController.isViewLoaded else { return }
        let all = codeState.diagnostics
        let section = isCodeShown && codeView.currentFile != nil ? codeView.caretSection : nil
        codeController.header.show(file: codeView.currentFile?.lastPathComponent ?? "", section: section,
                                   problems: all.filter { $0.severity == .problem }.count,
                                   warnings: all.filter { $0.severity == .warning }.count,
                                   log: logCount)
    }

    func updateCodeStatus() {
        guard codeController.isViewLoaded else { return }
        let state: StudioCodeStatusLine.State
        if let error = codeState.saveError {
            state = .notSaved(error)
        } else if codeView.hasUncommittedChanges, !codeState.committing {
            state = .editing
        } else if session?.isHoldingDesktop == true {
            state = .held
        } else {
            state = .saved
        }
        codeController.statusLine.show(state, line: codeView.currentFile == nil ? 1 : codeView.caretLine)
    }

    // MARK: Menus of the header

    /// The files of the file menu: the main file, then every included file, relative to the widget's folder, with their
    /// counts of problems and warnings.
    func codeFiles() -> [(url: URL, title: String, problems: Int, warnings: Int, current: Bool)] {
        guard let skin else { return [] }
        let root = skin.rootConfigDirectory.standardizedFileURL.path
        let current = codeView.currentFile.map { SourceFileID($0) }
        // The main file, then the included ones by name.
        let files = [skin.fileURL] + skin.includedFiles.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return files.map { url in
            let path = url.standardizedFileURL.path
            let title = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
            let id = SourceFileID(url)
            let mine = codeState.diagnostics.filter { SourceFileID($0.file) == id }
            return (url, title, mine.filter { $0.severity == .problem }.count,
                    mine.filter { $0.severity == .warning }.count, id == current)
        }
    }

    /// The name "Open in …" uses for the file shown.
    var codeEditorName: String? {
        guard let file = codeView.currentFile ?? skin?.fileURL else { return nil }
        return StudioCodeState.editorName(file, app)
    }

    /// The file menu: the widget's files with their counts, Show in Finder, Open in <editor>.
    func fileMenu() -> NSMenu {
        let menu = NSMenu()
        for f in codeFiles() {
            let item = ClosureMenuItem(f.title) { [weak self] in
                self?.codeView.show(file: f.url)
                self?.codeView.tintSection(lines: nil)
                self?.showDiagnostics()
            }
            item.state = f.current ? .on : .off
            item.image = StudioPageStyle.symbol("doc.text", size: 12, color: .secondaryLabelColor)
            if f.problems + f.warnings > 0 {
                let title = NSMutableAttributedString(string: f.title + "   ")
                if f.problems > 0 {
                    title.append(NSAttributedString(string: "●", attributes: [.foregroundColor: StudioCodeColors.problem]))
                    title.append(NSAttributedString(string: " \(f.problems)  "))
                }
                if f.warnings > 0 {
                    title.append(NSAttributedString(string: "●", attributes: [.foregroundColor: StudioCodeColors.warning]))
                    title.append(NSAttributedString(string: " \(f.warnings)"))
                }
                item.attributedTitle = title
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(StudioText[.showInFinder]) { [weak self] in self?.showCodeFileInFinder() })
        if let name = codeEditorName {
            menu.addItem(ClosureMenuItem(StudioText.format(.codeOpenIn, name)) { [weak self] in self?.openCodeInEditor() })
        }
        return menu
    }

    /// ⋯: Open in <editor>, Show in Finder, the log.
    func moreMenu() -> NSMenu {
        let menu = NSMenu()
        if let name = codeEditorName {
            menu.addItem(ClosureMenuItem(StudioText.format(.codeOpenIn, name)) { [weak self] in self?.openCodeInEditor() })
        }
        menu.addItem(ClosureMenuItem(StudioText[.showInFinder]) { [weak self] in self?.showCodeFileInFinder() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(StudioText[.logTitle]) { [weak self] in self?.showLog(allWidgets: false) })
        return menu
    }

    /// The file menu is open (a real menu on screen; snapshots draw it from `fileMenu`).
    var isShowingFileMenu: Bool {
        get { codeState.fileMenuShown }
        set { codeState.fileMenuShown = newValue }
    }

    func showFileMenu() {
        let button = codeController.header.fileButton
        guard app.presentsWindows, window?.isVisible == true else {
            isShowingFileMenu = true
            return
        }
        fileMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    func showMoreMenu() {
        let button = codeController.header.moreButton
        guard app.presentsWindows, window?.isVisible == true else { return }
        moreMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    func showCodeFileInFinder() {
        guard let file = codeView.currentFile ?? skin?.fileURL, app.presentsWindows else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func openCodeInEditor() {
        guard let file = codeView.currentFile ?? skin?.fileURL, app.presentsWindows else { return }
        codeView.commitNow(explicit: true)
        let line = codeView.currentFile == nil ? nil : codeView.caretLine
        if let editor = CodeEditorRouter.externalEditor(for: app.state.editor, file: file) {
            CodeEditorRouter.open(file: file, line: line, in: editor)
        } else if let url = CodeEditorRouter.locator.defaultApplicationURL(toOpen: file) {
            CodeEditorRouter.open(file: file, line: line, in: CodeEditorApp(url: url, bundleID: nil))
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let runAction: () -> Void

    init(_ title: String, key: String = "", enabled: Bool = true, run: @escaping () -> Void) {
        self.runAction = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc func fire() { runAction() }
}
