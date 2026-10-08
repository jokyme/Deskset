import AppKit
import DeskLanguage
import DesksetCore
import UniformTypeIdentifiers

/// A text file Deskset's built-in code editor opens outside the skin editor: one no running skin reads — a skin's
/// `["#CONFIGEDITOR#" "#@#Scripts/Clock.lua"]` or `"#@#Settings.cfg"`, Open With ▸ Deskset on a loose .ini. With
/// "Deskset (built-in)" chosen in Settings ▸ Editor such files never go to the Launch Services default (on many Macs an
/// IDE the user never chose for skins): they get this window, the same code editor as the skin editor's code pane —
/// highlighting, find, encoding and line endings kept byte for byte, commits after a pause, on ⌘S, when the window
/// stops being key and when it closes. Desk documents also show their checked program as a local preview.
/// A change made on disk meanwhile is picked up when the window
/// becomes key (a clean buffer) or asked about before it is written over (see `CodeEditorView.onDiskConflict`).
final class CodeFileWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
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
    private(set) var deskInspector: StudioInspectorViewController?
    private(set) var deskElementInspector: DeskElementInspector?
    private var deskInspectorItem: NSSplitViewItem?
    private var deskInspectorObservation: NSKeyValueObservation?
    private(set) var activeStagedLease: DeskWidgetInstallation.Staged?
    private var previewObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// A native list is bound to both the check and its original caret. Previewing entries never edits a buffer.
    private struct DeskCompletionSession {
        let snapshot: DeskSnapshot
        let selection: NSRange
        let range: NSRange
        let items: [DeskCompletionItem]
        let titles: [String]
    }
    private var deskCompletion: DeskCompletionSession?

    init(file: URL, app: AppController, deskCheckQueue: DispatchQueue? = nil,
         previewClock: SkinClock = .live, previewExecutor: SkinExecutor = MainSkinExecutor.shared,
         previewLocale: @escaping () -> Locale = DeskProgramPreviewController.currentDateLocale,
         previewPreferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
         previewColors: @escaping (NSAppearance) throws -> MacAppearance.ProgramValues = MacAppearance.programValues(for:),
         previewSystem: SystemDataSource = SystemMonitor.shared) throws {
        self.file = file.standardizedFileURL
        self.app = app
        codeView = CodeEditorView(frame: NSRect(x: 0, y: 0, width: 760, height: 580))
        codeView.setFontSize(CGFloat(app.state.editor.codeFontSize))
        if self.file.pathExtension.lowercased() == "desk" {
            codeView.decodeDocument = DeskCodeDocumentChecking.document(from:file:)
            codeView.requiresUnchangedSourceForAutomaticCommit = true
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
            let preview = DeskProgramPreviewController(resources: { [weak checking] snapshot in
                checking?.imageResources(for: snapshot) ?? .pending
            }, clock: previewClock, executor: previewExecutor, dateLocale: previewLocale,
               preferredLanguages: previewPreferredLanguages, colors: previewColors,
               system: previewSystem, presentsOptions: app.presentsWindows) { [weak self] snapshot in
                guard let self, self.readError == nil else { return false }
                return self.deskChecking?.isCurrent(snapshot) == true
            }
            deskPreview = preview
            preview.onMoreStyles = { [weak self] in self?.reveal(line: nil) }
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
            let inspector = StudioInspectorViewController()
            let inspectorItem: NSSplitViewItem
            if #available(macOS 14.0, *) {
                inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
            } else {
                inspectorItem = NSSplitViewItem(viewController: inspector)
            }
            inspectorItem.minimumThickness = StudioWindowController.inspectorMinWidth
            inspectorItem.maximumThickness = StudioWindowController.inspectorMaxWidth
            inspectorItem.canCollapse = true
            inspectorItem.isCollapsed = true
            deskInspector = inspector
            deskInspectorItem = inspectorItem
            split.addSplitViewItem(inspectorItem)
            window.contentViewController = split
            _ = inspector.view
            inspector.scrollView.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0)
            inspector.pageView.showsSearch = false
            inspector.onEscape = { [weak self] in self?.setDeskInspectorShown(false) }
            deskInspectorObservation = inspectorItem.observe(\.isCollapsed) { [weak self] _, _ in
                self?.deskInspectorVisibilityChanged()
            }
            preview.onSelectElement = { [weak self] snapshot, element in
                self?.selectDeskElement(element, from: snapshot, reveal: true)
            }
            codeView.onUserSelection = { [weak self] file, _, revision in
                guard let self, file == self.file, revision == self.codeView.textRevision else { return }
                self.updateDeskInspectorSelection()
            }
            window.contentMinSize = NSSize(width: 700, height: 240)
            window.setContentSize(NSSize(width: 1040, height: 580))
            let toolbar = NSToolbar(identifier: "DesksetCodeFileToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconAndLabel
            window.toolbar = toolbar
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
                self?.showDeskInspectorEmpty(message: error.localizedDescription)
                if let self, let snapshot = self.deskChecking?.snapshot {
                    self.deskPreview?.show(snapshot, readError: error.localizedDescription)
                }
                self?.window?.subtitle = error.localizedDescription
                Log.write("Code editor: \(error.localizedDescription)", level: .error)
            }
            showDeskCheck(checking.snapshot)
            let workspace = NSWorkspace.shared.notificationCenter
            let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak preview] _ in
                preview?.notifySystemWake()
            }
            previewObservers.append((workspace, wake))
            let center = NotificationCenter.default
            let colors = center.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak preview] _ in
                preview?.refreshEnvironment()
            }
            previewObservers.append((center, colors))
            for name in [NSLocale.currentLocaleDidChangeNotification, NSNotification.Name.NSSystemTimeZoneDidChange,
                         NSNotification.Name.NSSystemClockDidChange] {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak preview] _ in
                    preview?.refreshDateInput()
                }
                previewObservers.append((center, token))
            }
            let power = center.addObserver(forName: .desksetPowerSourceDidChange, object: nil, queue: .main) { [weak preview] _ in
                preview?.notifyPowerChange()
            }
            previewObservers.append((center, power))
            let details = center.addObserver(forName: .desksetBatteryDetailsDidChange, object: nil, queue: .main) { [weak preview] _ in
                preview?.notifyBatteryDetailsReady()
            }
            previewObservers.append((center, details))
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

    deinit {
        activeStagedLease?.discard()
        for (center, token) in previewObservers { center.removeObserver(token) }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        deskPreview?.setVisible(window?.occlusionState.contains(.visible) == true)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        codeView.undoManager(for: codeView.textView)
    }

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
        activeStagedLease?.discard()
        activeStagedLease = nil
        for (center, token) in previewObservers { center.removeObserver(token) }
        previewObservers.removeAll()
        deskCompletion = nil
        deskInspectorObservation = nil
        deskElementInspector = nil
        deskInspector?.pageView.onEvent = nil
        deskInspector?.onEscape = nil
        codeView.onUserSelection = nil
        codeView.onCompletionRange = nil
        codeView.onCompletions = nil
        codeView.onInsertCompletion = nil
        deskPreview?.close()
        deskChecking?.close()
        deskDecorations?.detach()
        app.codeFileWindowDidClose(self)
    }

    /// Only the current finished check supplies cards, ranges and actions. Pending checks and failed reads clear
    /// the previous display; the existing subtitle and document save/conflict behavior remain the same.
    private func showDeskCheck(_ snapshot: DeskSnapshot) {
        deskCompletion = nil
        deskPreview?.show(snapshot, readError: readError)
        updateDeskInspectorSelection()
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

    // MARK: Checked element inspector

    var isDeskInspectorShown: Bool { deskInspectorItem?.isCollapsed == false }

    func setDeskInspectorShown(_ shown: Bool) {
        guard let item = deskInspectorItem, deskChecking != nil else { return }
        if item.isCollapsed == shown { item.isCollapsed = !shown }
        else { deskInspectorVisibilityChanged() }
    }

    @objc private func toggleDeskInspector(_ sender: Any?) { setDeskInspectorShown(!isDeskInspectorShown) }

    private func deskInspectorVisibilityChanged() {
        let shown = isDeskInspectorShown
        deskPreview?.setInspecting(shown)
        let minimum = shown ? 360 + 280 + StudioWindowController.inspectorMinWidth + 2 : 700
        window?.contentMinSize = NSSize(width: minimum, height: 240)
        if let window, window.contentLayoutRect.width < minimum {
            window.setContentSize(NSSize(width: minimum, height: window.contentLayoutRect.height))
        }
        if shown { updateDeskInspectorSelection() }
        else { showDeskInspectorEmpty() }
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.toolbarInspector }) {
            item.toolTip = StudioText[shown ? .hideInspector : .showInspector]
        }
    }

    private func updateDeskInspectorSelection() {
        guard isDeskInspectorShown, readError == nil, let checking = deskChecking,
              checking.snapshot.isChecked, checking.isCurrent(checking.snapshot) else {
            showDeskInspectorEmpty(message: readError ?? StudioText[.deskPreviewChecking])
            return
        }
        let snapshot = checking.snapshot, selection = codeView.textView.selectedRange()
        let (end, overflow) = selection.location.addingReportingOverflow(selection.length)
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              !overflow, end <= snapshot.index.utf16Count,
              snapshot.index.clampedUTF16(selection.location) == selection.location,
              snapshot.index.clampedUTF16(end) == end else { showDeskInspectorEmpty(); return }
        let first = snapshot.elementAt(snapshot.index.position(utf16: selection.location))?.element
        if selection.length > 0 {
            let last = snapshot.elementAt(snapshot.index.position(utf16: max(selection.location, end - 1)))?.element
            guard first == last else {
                _ = deskPreview?.selectElement(nil, from: snapshot)
                showDeskInspectorEmpty()
                return
            }
        }
        selectDeskElement(first, from: snapshot, reveal: false)
    }

    private func selectDeskElement(_ element: ElementRef?, from snapshot: DeskSnapshot, reveal: Bool) {
        guard isDeskInspectorShown, readError == nil, deskChecking?.isCurrent(snapshot) == true,
              snapshot.isChecked else { showDeskInspectorEmpty(); return }
        if reveal {
            let range = element.flatMap { snapshot.range(of: $0)?.callRange }
            // API selection cancels old caret notifications without taking keyboard focus or making an edit.
            let selection = range.map { NSRange(location: $0.start.offset, length: 0) }
                ?? codeView.textView.selectedRange()
            guard codeView.reveal(range: selection, in: file) else { showDeskInspectorEmpty(); return }
        }
        _ = deskPreview?.selectElement(element, from: snapshot)
        guard let element, let inspector = DeskElementInspector(snapshot: snapshot, element: element) else {
            showDeskInspectorEmpty()
            return
        }
        deskElementInspector = inspector
        showDeskInspectorPage(inspector)
    }

    private func showDeskInspectorEmpty(message: String? = nil) {
        deskElementInspector = nil
        deskInspector?.pageView.onEvent = nil
        deskInspector?.show(StudioPage(id: "desk-inspector-empty", title: StudioText[.inspector],
                                      subtitle: message ?? StudioText[.deskInspectorSelectElement]))
    }

    private func showDeskInspectorPage(_ inspector: DeskElementInspector, notice: String? = nil) {
        var page = inspector.page
        if let notice {
            page.sections.append(.init(id: "desk-inspector-feedback", title: "", items: [
                .init(id: "desk-inspector-feedback", kind: .note(.init(text: notice, link: nil,
                                                                       symbol: "exclamationmark.triangle"))),
            ]))
        }
        deskInspector?.show(page)
        deskInspector?.pageView.onEvent = { [weak self] event in
            _ = self?.applyDeskInspectorEvent(event, from: inspector)
        }
    }

    /// The displayed page is a proposal bound to one selected element and one checked source snapshot.
    @discardableResult
    func applyDeskInspectorEvent(_ event: StudioPageEvent, from inspector: DeskElementInspector) -> Bool {
        guard isDeskInspectorShown, readError == nil, let checking = deskChecking,
              checking.isCurrent(inspector.snapshot), deskElementInspector?.element == inspector.element,
              deskElementInspector?.snapshot.generation == inspector.snapshot.generation,
              let operation = inspector.operation(for: event) else { return false }
        switch operation {
        case .showInCode(let range):
            guard codeView.reveal(range: NSRange(location: range.start.offset, length: range.length), in: file) else { return false }
            window?.makeFirstResponder(codeView.textView)
            return true
        case .rejected(let message):
            showDeskInspectorPage(inspector, notice: message)
            return false
        case .edit(let edit, let actionName):
            let source = codeView.checkSourceUnchanged(for: file)
            guard checking.isCurrent(inspector.snapshot), deskElementInspector?.element == inspector.element else {
                updateDeskInspectorSelection()
                return false
            }
            switch source {
            case .changed:
                showDeskInspectorPage(inspector, notice: StudioText[.deskInspectorDiskChanged])
                return false
            case .unavailable:
                showDeskInspectorPage(inspector, notice: StudioText[.deskInspectorSourceUnavailable])
                return false
            case .unchanged: break
            }
            guard checking.apply(edit, from: inspector.snapshot, actionName: actionName) else {
                if checking.isCurrent(inspector.snapshot), deskElementInspector?.element == inspector.element {
                    showDeskInspectorPage(inspector, notice: StudioText[.deskInspectorEditRejected])
                } else { updateDeskInspectorSelection() }
                return false
            }
            return true
        }
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

    // MARK: Place on Desktop

    enum PlaceOnDesktopError: Error, Equatable {
        case notDeskFile, documentNotChecked, saveFailed, cancelled
    }

    static let toolbarPlaceOnDesktop = NSToolbarItem.Identifier("codeFile.placeOnDesktop")
    static let toolbarInspector = NSToolbarItem.Identifier("codeFile.inspector")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.toolbarPlaceOnDesktop, Self.toolbarInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.toolbarPlaceOnDesktop, Self.toolbarInspector]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.toolbarInspector {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = StudioText[.inspector]
            item.paletteLabel = item.label
            item.toolTip = StudioText[isDeskInspectorShown ? .hideInspector : .showInspector]
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(toggleDeskInspector(_:))
            return item
        }
        guard id == Self.toolbarPlaceOnDesktop else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = StudioText[.placeOnDesktop]
        item.paletteLabel = item.label
        item.toolTip = StudioText[.placeOnDesktop]
        item.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(placeOnDesktop(_:))
        return item
    }

    @objc func placeOnDesktop(_ sender: Any? = nil) {
        placeOnDesktop(sourceID: UUID(), instanceID: UUID(), completion: { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.showPlaceOnDesktopError(error)
            }
        })
    }

    func placeOnDesktop(sourceID: UUID = UUID(), instanceID: UUID = UUID(),
                        prepareQueue: DispatchQueue = DispatchQueue.global(qos: .userInitiated),
                        completion: ((Result<DeskWidgetWindowController, Error>) -> Void)? = nil) {
        precondition(Thread.isMainThread)
        guard file.pathExtension.lowercased() == "desk", let checking = deskChecking else {
            completion?(.failure(PlaceOnDesktopError.notDeskFile))
            return
        }
        if codeView.hasUncommittedChanges && !codeView.commitNow(explicit: true) {
            completion?(.failure(PlaceOnDesktopError.saveFailed))
            return
        }

        let snapshot = checking.snapshot
        guard snapshot.isChecked, checking.isCurrent(snapshot) else {
            completion?(.failure(PlaceOnDesktopError.documentNotChecked))
            return
        }

        let widgetsRoot = app.widgetsDirectory
        do {
            let admitted = try DeskWidgetInstallation.admit(snapshot, file: file, current: checking.isCurrent)
            prepareQueue.async { [weak self] in
                var staged: DeskWidgetInstallation.Staged?
                var prepError: Error?
                do {
                    staged = try DeskWidgetInstallation.prepare(admitted, sourceID: sourceID, instanceID: instanceID, root: widgetsRoot)
                } catch {
                    prepError = error
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self, let checking = self.deskChecking, checking.isCurrent(snapshot), self.window != nil else {
                        // Contract: If editor window closes before install commit, discard staging
                        staged?.discard()
                        completion?(.failure(PlaceOnDesktopError.cancelled))
                        return
                    }

                    if let prepError {
                        completion?(.failure(prepError))
                        return
                    }

                    guard let readyStaged = staged else {
                        completion?(.failure(PlaceOnDesktopError.cancelled))
                        return
                    }

                    self.activeStagedLease = readyStaged
                    defer { self.activeStagedLease = nil }

                    do {
                        // Contract: Commit inactive state, then activate standalone window from installed entry
                        let installed = try readyStaged.commit(to: self.app.state, current: checking.isCurrent)
                        let controller = try self.app.activateDeskWidget(source: installed.source, instance: installed.instance)
                        completion?(.success(controller))
                    } catch {
                        completion?(.failure(error))
                    }
                }
            }
        } catch {
            completion?(.failure(error))
        }
    }

    private func showPlaceOnDesktopError(_ error: Error) {
        if case PlaceOnDesktopError.cancelled = error { return }
        let message: String
        if let placeErr = error as? PlaceOnDesktopError {
            switch placeErr {
            case .notDeskFile: message = StudioText[.deskWidgetInvalidFile]
            case .documentNotChecked: message = StudioText[.deskPreviewChecking]
            case .saveFailed: message = StudioText[.codeNotSavedTitle]
            case .cancelled: return
            }
        } else if let installErr = error as? DeskWidgetInstallation.Failure {
            switch installErr {
            case .resourceLimit: message = StudioText[.deskWidgetPreparationFailed]
            default: message = StudioText.format(.deskWidgetInstallationFailed, String(describing: installErr))
            }
        } else if let actErr = error as? AppController.DeskWidgetActivationFailure {
            switch actErr {
            case .resourceLimit: message = StudioText[.deskWidgetPreparationFailed]
            default: message = StudioText.format(.deskWidgetInstallationFailed, String(describing: actErr))
            }
        } else {
            message = StudioText.format(.deskWidgetInstallationFailed, error.localizedDescription)
        }
        if app.presentsWindows, let window {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = StudioText[.placeOnDesktop]
            alert.informativeText = message
            alert.beginSheetModal(for: window)
        } else {
            Log.write("\(StudioText[.placeOnDesktop]): \(message)", level: .warning)
        }
    }
}
