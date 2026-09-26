import AppKit
import DesksetCore

/// The skin studio's built-in code editor (docs/editor-design.md §5): a jump bar (file pop-up with a dirty dot,
/// section pop-up, encoding) above a TextKit 1 text view with line numbers, INI highlighting and a find bar.
///
/// The files on disk stay the source of truth. Typing edits an in-memory buffer (one per open file, each with its own
/// undo manager, so ⌘Z here undoes typing only); the buffer is *committed* — handed to `onCommit`, which writes it
/// as one undoable editor step and refreshes the skin — after `idleCommitDelay` without typing, on ⌘S, when the text
/// view loses focus or its window stops being key, and before another file is shown. After a visual edit or an
/// external change the host calls `reloadFromDisk`, which updates clean buffers in place, keeping caret and scroll.
///
/// A commit never writes over a change made on disk since the buffer was read: each buffer remembers the bytes its
/// text is based on, and a commit that finds other bytes in the file asks whether to keep the typed edits (written
/// over the file) or take the file's version (`onDiskConflict`; an alert in a visible window).
///
/// A dirty buffer is never dropped: a file the host no longer lists stays open while its commit is refused. The
/// host's `windowShouldClose` must call `commitNow(explicit: true)` and, when it returns false
/// (`hasUncommittedChanges`), either keep the window open or let the user discard the edits
/// (`discardUncommittedChanges`) — once the view is gone, so are its buffers.
///
/// Selection sync is origin-tagged: `onCaretSection` reports only caret moves the user made (debounced by
/// `caretRestDelay`); everything the API does — open, reveal, tint, reload, file switches — is silent, so a host that
/// reacts to a report by revealing the same section cannot loop.
///
/// Encoding, BOM and line endings are preserved byte for byte (`CodeDocument`): the text view keeps CRLF / CR / LF as
/// they are, Return and pasted text use the file's dominant line ending, and a character an ANSI file cannot hold
/// offers a conversion to UTF-16 LE with BOM before the commit.
final class CodeEditorView: NSView {
    // MARK: Callbacks

    /// Commits a buffer: write `text` to the file — in its encoding, e.g. `document(for: url)!.data(for: text)`,
    /// which keeps BOM and line endings — and refresh. Return false to keep the buffer dirty (it is offered again at
    /// the next trigger). When nil, the view writes the file itself. Calling `commitNow()` from inside is harmless.
    ///
    /// `url` identifies the buffer (standardized, as passed to `open`); a symlink in it is *not* resolved. Write to
    /// `CodeDocument.writeTarget(for: url)` (or through `IniWriter` / `EditorFileChange`, which resolve too), so a
    /// skin file linked in from elsewhere gets the edit instead of losing its link.
    var onCommit: ((URL, String) -> Bool)?
    /// The caret came to rest in a section after a user move (click, arrow keys, typing, the section pop-up): the
    /// file and the section name (nil before the first header). Never called for API changes.
    var onCaretSection: ((URL, String?) -> Void)?
    /// The user picked another file in the jump bar (after the previous one was committed).
    var onFileChange: ((URL) -> Void)?
    /// The user changed the font size with ⌘+ / ⌘− / ⌘0 (for the host to remember).
    var onFontSizeChange: ((CGFloat) -> Void)?
    /// Asked before an ANSI file that cannot hold the new text is converted to UTF-16 LE with BOM; return true to
    /// convert and commit. When nil, an alert asks in a visible window, and headless use converts (like `IniWriter`)
    /// unless the user declined before.
    var onEncodingConversion: ((URL, CodeDocument) -> Bool)?
    /// Asked when a dirty buffer is committed but its file changed on disk since the buffer was read (another app,
    /// the skin's own `!WriteKeyValue`): keep the typed edits (they are written over the file), take the file's
    /// version (the edits are dropped), or decide later (the buffer stays dirty). When nil, an alert asks in a
    /// visible window; with nobody to ask an explicit commit (⌘S, closing) keeps the edits and an automatic one waits.
    var onDiskConflict: ((URL) -> DiskConflictChoice)?

    enum DiskConflictChoice { case keepEdits, takeDisk, decideLater }

    static let defaultIdleCommitDelay: TimeInterval = 0.8
    /// How long typing must pause before the buffer is committed (self-tests set it; the idle commit can also be
    /// fired at once with `fireIdleCommit`).
    var idleCommitDelay: TimeInterval = CodeEditorView.defaultIdleCommitDelay
    static let defaultCaretRestDelay: TimeInterval = 0.15
    /// How long the caret must rest before its section is reported (self-tests set it; `fireCaretRest` reports at
    /// once).
    var caretRestDelay: TimeInterval = CodeEditorView.defaultCaretRestDelay
    static let defaultFontSize: CGFloat = 12
    static let fontSizeRange: ClosedRange<CGFloat> = 8...36

    let textView: CodeTextView
    let scrollView: NSScrollView
    let ruler: CodeEditorRuler
    let filePopUp: NSPopUpButton
    let sectionPopUp: NSPopUpButton
    private let statusLabel: NSTextField
    private let jumpBar = JumpBarView()

    // MARK: State

    /// One open file.
    private final class FileBuffer {
        let url: URL
        /// The text as last read or committed (the clean state), with the file's encoding and line ending.
        var document: CodeDocument
        /// The file's bytes the buffer's edits start from (read, reloaded while clean, or committed). A commit that
        /// finds other bytes in the file would write over a change made elsewhere, so it asks first.
        var base: Data?
        /// The user put off deciding about a change on disk; automatic commits stop asking until an explicit one.
        var conflictPostponed = false
        /// The buffer while another file is shown (the text view holds it while this file is shown).
        var text: String
        var isDirty = false
        let undoManager = UndoManager()
        var selection = NSRange(location: 0, length: 0)
        var scrollOrigin = NSPoint.zero
        /// The user declined converting the encoding; automatic commits stop asking until an explicit one (⌘S,
        /// closing, the host dropping the file).
        var conversionDeclined = false
        /// The host no longer lists the file; it stays open only because its edits could not be committed.
        var isRetained = false

        init(url: URL, document: CodeDocument, base: Data?) {
            self.url = url
            self.document = document
            self.base = base
            self.text = document.text
        }
    }

    private var buffers: [FileBuffer] = []
    private var current: FileBuffer?
    private(set) var fontSize: CGFloat = CodeEditorView.defaultFontSize
    /// > 0 while an API call changes the text or the selection: its selection changes are not caret reports.
    private var apiDepth = 0
    /// The buffer being handed to `onCommit` (or written), during the call.
    private var committingBuffer: FileBuffer?
    private var commitTimer: Timer?
    private var caretTimer: Timer?
    /// Whether the pending caret rest was caused by typing (a rest in the same section is then not reported again).
    private var caretMoveFromTyping = false
    private var isEditingText = false
    private var lastReport: (url: URL, section: String?)?
    /// Edited characters waiting to be highlighted again.
    private var pendingHighlight: NSRange?
    /// The shown buffer as a CodeDocument (line index, sections), rebuilt lazily after edits.
    private var analysisCache: CodeDocument?
    private var windowObservers: [NSObjectProtocol] = []

    // MARK: Setup

    override init(frame: NSRect) {
        // TextKit 1 from the start: touching `layoutManager` on a TextKit 2 view would switch it irreversibly.
        textView = CodeTextView(usingTextLayoutManager: false)
        scrollView = NSScrollView()
        ruler = CodeEditorRuler(scrollView: scrollView, orientation: .verticalRuler)
        filePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        sectionPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
        statusLabel = EditorStyle.label("", size: 11, color: .tertiaryLabelColor)
        super.init(frame: frame)
        setUpTextView()
        setUpJumpBar()
        layOut()
        applyFont()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        commitTimer?.invalidate()
        caretTimer?.invalidate()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        NotificationCenter.default.removeObserver(self)
    }

    private func setUpTextView() {
        let tv = textView
        tv.editor = self
        tv.delegate = self
        tv.textStorage?.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.usesInspectorBar = false
        tv.allowsDocumentBackgroundColorChange = false
        // Code-safe text: smart quotes would turn " into curly quotes and break options and bangs.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.enabledTextCheckingTypes = 0
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textColor = .textColor
        tv.insertionPointColor = .textColor
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.setAccessibilityLabel("Code")
        // Soft wrap: bang lines and long actions stay readable without horizontal scrolling.
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.layoutManager?.allowsNonContiguousLayout = true

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // The scroller stays when everything fits. Legacy scrollers (a mouse connected, or Show scroll bars: Always)
        // take room from the text: one that came and went with the text's height narrowed the text, re-wrapping made
        // the non-contiguous layout estimate it shorter than the pane, which hid the scroller again, and so on — off
        // screen, `ensureLayout` never returned. Overlay scrollers take no room either way.
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = tv
        ruler.editor = self
        ruler.clientView = tv
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewScrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    private func setUpJumpBar() {
        for popUp in [filePopUp, sectionPopUp] {
            popUp.isBordered = false
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: 11.5)
            popUp.target = self
            popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            (popUp.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        }
        filePopUp.action = #selector(filePicked(_:))
        filePopUp.setAccessibilityLabel("File")
        sectionPopUp.action = #selector(sectionPicked(_:))
        sectionPopUp.setAccessibilityLabel("Section")
        sectionPopUp.menu?.delegate = self
        sectionPopUp.addItem(withTitle: "No Section")
        let chevron = NSImageView(image: EditorStyle.image("chevron.right", size: 9, weight: .semibold) ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.lineBreakMode = .byClipping
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = EditorStyle.hstack([filePopUp, chevron, sectionPopUp, EditorStyle.spacer(), statusLabel], spacing: 4)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        jumpBar.addSubview(row)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        jumpBar.addSubview(separator)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: jumpBar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: jumpBar.trailingAnchor),
            row.topAnchor.constraint(equalTo: jumpBar.topAnchor),
            row.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: jumpBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: jumpBar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: jumpBar.bottomAnchor),
        ])
    }

    private func layOut() {
        jumpBar.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(jumpBar)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            jumpBar.topAnchor.constraint(equalTo: topAnchor),
            jumpBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            jumpBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            jumpBar.heightAnchor.constraint(equalToConstant: 28),
            scrollView.topAnchor.constraint(equalTo: jumpBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Public API

    var files: [URL] { buffers.map(\.url) }
    var currentFile: URL? { current?.url }
    /// The shown buffer's text (line endings as in the file).
    var text: String { textView.string }
    /// Whether the shown buffer differs from its file.
    var isDirty: Bool { current?.isDirty ?? false }
    func isDirty(_ url: URL) -> Bool { buffer(for: url)?.isDirty ?? false }
    /// Whether any open buffer differs from its file.
    var hasUncommittedChanges: Bool { buffers.contains { $0.isDirty } }

    /// The file's clean state: text as last read or committed, encoding, BOM and dominant line ending.
    func document(for url: URL) -> CodeDocument? { buffer(for: url)?.document }

    /// The 1-based line of the caret and the section it is in (the shown buffer, unsaved edits included).
    var caretLine: Int { analysis.line(containingOffset: textView.selectedRange().location) }
    var caretSection: String? { analysis.section(containingLine: caretLine) }
    /// UTF-16 offsets of the line starts of the shown buffer (the ruler's numbers).
    var lineStarts: [Int] { analysis.lineStarts }
    /// The lines of `[name]` in the shown buffer (see `CodeDocument.lineRange(ofSection:)`).
    func lineRange(ofSection name: String) -> Range<Int>? { analysis.lineRange(ofSection: name) }
    /// The tinted characters, if any (they follow edits).
    private(set) var tintedRange: NSRange? {
        didSet {
            textView.tintRange = tintedRange
            ruler.needsDisplay = true
        }
    }

    /// Opens `files` (the main .ini and its @Include files) and shows `current`. Throws when `current` cannot be read;
    /// other unreadable files are left out. Files that are already open keep their buffer, undo history, caret and
    /// scroll position (call `reloadFromDisk` to pick up disk changes).
    ///
    /// Files no longer listed are committed (explicitly: a declined encoding conversion is asked again) and closed —
    /// except one whose commit is refused (`onCommit` returned false, the conversion was declined again, the write
    /// failed, or another commit is running): it stays open after the listed files, still dirty, until a later
    /// `open` (which retries it as an automatic commit) finds it committed. Returns those files, for the host to
    /// point out.
    @discardableResult
    func open(files: [URL], current currentURL: URL) throws -> [URL] {
        let target = currentURL.standardizedFileURL
        var urls: [URL] = []
        for url in files.map(\.standardizedFileURL) where !urls.contains(url) { urls.append(url) }
        if !urls.contains(target) { urls.insert(target, at: 0) }
        let targetFile: (document: CodeDocument, bytes: Data?)
        if let existing = buffer(for: target) {
            targetFile = (existing.document, existing.base)
        } else {
            let loaded = try Self.load(target)
            targetFile = (loaded.document, loaded.bytes)
        }

        var kept: [FileBuffer] = []
        for url in urls {
            if let existing = buffer(for: url) {
                kept.append(existing)
            } else if url == target {
                kept.append(FileBuffer(url: url, document: targetFile.document, base: targetFile.bytes))
            } else if let file = try? Self.load(url) {
                kept.append(FileBuffer(url: url, document: file.document, base: file.bytes))
            }
        }
        var retained: [FileBuffer] = []
        for old in buffers where !kept.contains(where: { $0 === old }) {
            // Only the first drop is explicit: hosts re-open after every refresh, and asking each time would nag.
            commit(old, explicit: !old.isRetained)
            // Dropping a buffer that is still dirty would silently lose the user's typing.
            if old.isDirty {
                old.isRetained = true
                retained.append(old)
            }
            if old === current {
                stashCurrent()
                current = nil
            }
        }
        for buffer in kept { buffer.isRetained = false }
        buffers = kept + retained
        guard let shown = buffer(for: target) else { return retained.map(\.url) }
        if shown === current {
            apiChange { updateJumpBar() }
        } else {
            show(shown)
        }
        return retained.map(\.url)
    }

    /// Shows another open file (commits the shown buffer first). Not reported through `onFileChange`.
    func show(file url: URL) {
        guard let buffer = buffer(for: url) else { return }
        show(buffer)
    }

    /// Commits every dirty buffer (the shown one first). Returns false when a commit was refused; that buffer stays
    /// dirty. `explicit` — the user asked, as with ⌘S or closing the window — asks about an encoding conversion again
    /// even after the user declined it; automatic commits (the default) do not.
    @discardableResult
    func commitNow(explicit: Bool = false) -> Bool {
        commitAll(explicit: explicit)
    }

    /// Throws away the edits of every dirty buffer — the host's "Discard" when its window closes with
    /// `hasUncommittedChanges` — so nothing is committed later (e.g. when the view leaves the window). The buffers go
    /// back to their files' text (re-read; the last read or committed text when unreadable) and lose their undo
    /// history. Silent, like every API change.
    func discardUncommittedChanges() {
        commitTimer?.invalidate()
        commitTimer = nil
        apiChange {
            for buffer in buffers where buffer.isDirty {
                // Re-read: the disk may have changed, and a refused commit may have switched the encoding already.
                if let disk = try? Self.load(buffer.url) {
                    buffer.document = disk.document
                    buffer.base = disk.bytes
                }
                buffer.isDirty = false
                buffer.conversionDeclined = false
                buffer.conflictPostponed = false
                if buffer === current {
                    _ = replaceShownText(with: buffer.document.text, keepCaret: true)
                    textView.lineEnding = buffer.document.lineEnding.string
                } else {
                    buffer.text = buffer.document.text
                    let length = (buffer.text as NSString).length
                    buffer.selection = NSRange(location: min(buffer.selection.location, length), length: 0)
                }
                buffer.undoManager.removeAllActions()
            }
            updateJumpBar()
        }
    }

    /// Scrolls `line` (1-based) of `file` into view — centred when it is off-screen, not moved when it is already
    /// visible — switching files if needed, and puts the caret at the start of the line (`select` selects the whole
    /// line), so the jump bar names the revealed section and the arrow keys go on from there. Never takes focus or
    /// reports the caret.
    func reveal(line: Int, in file: URL, select: Bool) {
        guard let buffer = buffer(for: file) ?? (try? addBuffer(file)) else { return }
        apiChange {
            if buffer !== current { show(buffer) }
            let range = analysis.range(ofLine: line)
            textView.setSelectedRange(select ? range : NSRange(location: range.location, length: 0))
            scrollToVisible(range)
        }
    }

    /// Reveals the header of `[name]` in `file` and tints its block. Returns false when the section is not there.
    @discardableResult
    func revealSection(_ name: String, in file: URL, tint: Bool = true) -> Bool {
        guard let buffer = buffer(for: file) ?? (try? addBuffer(file)) else { return false }
        if buffer !== current { apiChange { show(buffer) } }
        guard let lines = analysis.lineRange(ofSection: name) else {
            if tint { tintSection(lines: nil) }
            return false
        }
        reveal(line: lines.lowerBound, in: file, select: false)
        if tint { tintSection(lines: lines) }
        return true
    }

    /// A soft band behind 1-based `lines` of the shown file (nil removes it). Changes neither the selection, the
    /// scroll position nor the focus.
    func tintSection(lines: Range<Int>?) {
        apiChange {
            guard let lines, !lines.isEmpty else {
                tintedRange = nil
                return
            }
            let range = analysis.range(ofLines: lines)
            tintedRange = range.length > 0 ? range : nil
        }
    }

    /// Re-reads every open file. Clean buffers take the disk text — the shown one by replacing only what changed,
    /// keeping caret and scroll when `keepCaret` (otherwise the caret goes to the top); a buffer whose text changed
    /// loses its undo history. Dirty buffers keep their edits and the bytes they are based on: when the file changed
    /// meanwhile, their next commit asks what to keep (see `onDiskConflict`). Only their clean state is refreshed.
    func reloadFromDisk(keepCaret: Bool = true) {
        apiChange {
            for buffer in buffers {
                guard let file = try? Self.load(buffer.url) else { continue }
                let disk = file.document
                if buffer.isDirty {
                    buffer.document = disk
                    let text = buffer === current ? textView.string : buffer.text
                    buffer.isDirty = !(text as NSString).isEqual(to: disk.text)
                    if !buffer.isDirty {
                        buffer.base = file.bytes
                        buffer.conflictPostponed = false
                    }
                    continue
                }
                buffer.document = disk
                buffer.base = file.bytes
                if buffer === current {
                    if replaceShownText(with: disk.text, keepCaret: keepCaret) { buffer.undoManager.removeAllActions() }
                    textView.lineEnding = disk.lineEnding.string
                } else if !(buffer.text as NSString).isEqual(to: disk.text) {
                    buffer.text = disk.text
                    buffer.undoManager.removeAllActions()
                    let length = (disk.text as NSString).length
                    buffer.selection = NSRange(location: min(buffer.selection.location, length), length: 0)
                }
            }
            updateJumpBar()
        }
    }

    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size.rounded(), Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        guard clamped != fontSize else { return }
        fontSize = clamped
        apiChange { applyFont() }
    }

    @objc func makeTextLarger(_ sender: Any?) { userSetFontSize(fontSize + 1) }
    @objc func makeTextSmaller(_ sender: Any?) { userSetFontSize(fontSize - 1) }
    @objc func makeTextStandardSize(_ sender: Any?) { userSetFontSize(Self.defaultFontSize) }

    private func userSetFontSize(_ size: CGFloat) {
        let before = fontSize
        setFontSize(size)
        if fontSize != before { onFontSizeChange?(fontSize) }
    }

    // MARK: - Buffers

    private func buffer(for url: URL) -> FileBuffer? {
        let url = url.standardizedFileURL
        return buffers.first { $0.url == url }
    }

    /// A file's text (decoded like `CodeDocument.load`) and its bytes.
    private static func load(_ url: URL) throws -> (document: CodeDocument, bytes: Data) {
        let bytes = try Data(contentsOf: url)
        return (CodeDocument(data: bytes), bytes)
    }

    /// Opens a file that was not in the list (e.g. revealed from an include the host did not pass).
    private func addBuffer(_ url: URL) throws -> FileBuffer {
        let file = try Self.load(url)
        let buffer = FileBuffer(url: url.standardizedFileURL, document: file.document, base: file.bytes)
        buffers.append(buffer)
        apiChange { updateJumpBar() }
        return buffer
    }

    /// Shows `buffer` in the text view: commits and stashes the shown buffer, loads the new text without undo,
    /// highlights it and restores its caret and scroll position.
    private func show(_ buffer: FileBuffer) {
        apiChange {
            if let old = current, old !== buffer {
                commit(old)
                stashCurrent()
            }
            current = buffer
            tintedRange = nil
            lastReport = nil
            textView.lineEnding = buffer.document.lineEnding.string
            textView.textStorage?.setAttributedString(NSAttributedString(string: buffer.text, attributes: baseAttributes))
            textView.typingAttributes = baseAttributes
            pendingHighlight = nil
            highlight(NSRange(location: 0, length: (textView.string as NSString).length))
            let length = (textView.string as NSString).length
            let location = min(buffer.selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(buffer.selection.length, length - location)))
            restoreScroll(buffer.scrollOrigin)
            updateJumpBar()
        }
    }

    /// Saves the shown buffer's text, caret and scroll position into it before the text view shows something else.
    private func stashCurrent() {
        guard let current else { return }
        current.text = textView.string
        current.selection = textView.selectedRange()
        current.scrollOrigin = scrollView.contentView.bounds.origin
        textView.breakUndoCoalescing()
    }

    /// Replaces the shown text by `newText`, changing only the range between their common prefix and suffix (so
    /// layout, scroll and highlighting elsewhere are untouched). Returns false when nothing changed.
    private func replaceShownText(with newText: String, keepCaret: Bool) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let old = storage.mutableString
        if old.isEqual(to: newText) { return false }
        let new = newText as NSString
        let oldLength = old.length, newLength = new.length
        var prefix = 0
        while prefix < min(oldLength, newLength), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }
        var suffix = 0
        while suffix < min(oldLength, newLength) - prefix,
              old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(old.character(at: oldLength - suffix)) { suffix -= 1 }
        let changed = NSRange(location: prefix, length: oldLength - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        storage.beginEditing()
        storage.replaceCharacters(in: changed, with: NSAttributedString(string: replacement, attributes: baseAttributes))
        storage.endEditing()
        guard keepCaret else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            restoreScroll(.zero)
            return true
        }
        let delta = newLength - oldLength
        func map(_ p: Int) -> Int {
            if p < prefix { return p }
            if p >= oldLength - suffix { return p + delta }
            return min(p, prefix + replacement.utf16.count)
        }
        let start = map(selection.location)
        let end = max(start, map(NSMaxRange(selection)))
        textView.setSelectedRange(NSRange(location: start, length: end - start))
        restoreScroll(origin)
        return true
    }

    // MARK: - Commit

    @discardableResult
    private func commitAll(explicit: Bool) -> Bool {
        var ok = true
        if let current { ok = commit(current, explicit: explicit) && ok }
        for buffer in buffers where buffer !== current && buffer.isDirty { ok = commit(buffer, explicit: explicit) && ok }
        return ok
    }

    /// Hands a dirty buffer to `onCommit` (or writes it). `explicit` (⌘S, closing, the host dropping the file) asks
    /// about an encoding conversion again even if the user declined it before.
    @discardableResult
    private func commit(_ buffer: FileBuffer, explicit: Bool = false) -> Bool {
        if buffer === current {
            commitTimer?.invalidate()
            commitTimer = nil
        }
        guard buffer.isDirty else { return true }
        // No nested commits: the host (committing dirty code before its own edit), its refresh, or the window
        // resigning key behind the conversion alert may ask for one while this one runs. For the same buffer that is
        // fine — it is being committed.
        if let committing = committingBuffer { return committing === buffer }
        committingBuffer = buffer
        defer { committingBuffer = nil }
        let text = buffer === current ? textView.string : buffer.text
        if (text as NSString).isEqual(to: buffer.document.text) {
            buffer.isDirty = false
            updateJumpBar()
            return true
        }
        // The file changed on disk since the edits began: writing the buffer would silently undo that change.
        if let base = buffer.base, let disk = try? Data(contentsOf: buffer.url), disk != base {
            switch resolveDiskConflict(of: buffer, explicit: explicit) {
            case .keepEdits:
                break
            case .takeDisk:
                adoptDisk(disk, into: buffer)
                return true
            case .decideLater:
                return false
            }
        }
        if !buffer.document.canEncode(text) {
            guard confirmConversion(of: buffer, explicit: explicit) else { return false }
            buffer.document.convertToUnicode()
        }
        let ok: Bool
        if let onCommit {
            ok = onCommit(buffer.url, text)
        } else {
            do {
                try buffer.document.write(text, to: buffer.url)
                ok = true
            } catch {
                Log.write("Code editor: cannot write \(buffer.url.lastPathComponent): \(error.localizedDescription)",
                          level: .error)
                ok = false
            }
        }
        if ok {
            buffer.document.text = text
            buffer.base = (try? Data(contentsOf: buffer.url)) ?? buffer.document.data(for: text)
            buffer.conflictPostponed = false
            let now = buffer === current ? textView.string : buffer.text
            buffer.isDirty = !(now as NSString).isEqual(to: text)
        }
        updateJumpBar()
        return ok
    }

    /// What to do with a dirty buffer whose file changed on disk since its edits began.
    private func resolveDiskConflict(of buffer: FileBuffer, explicit: Bool) -> DiskConflictChoice {
        if buffer.conflictPostponed && !explicit { return .decideLater }
        let choice: DiskConflictChoice
        if let onDiskConflict {
            choice = onDiskConflict(buffer.url)
        } else if let window, window.isVisible {
            let alert = NSAlert()
            alert.messageText = "“\(buffer.url.lastPathComponent)” changed on disk while you were editing it"
            alert.informativeText = "Keep your edits to write them over the file, or use the file as it is now "
                + "(your edits since then are dropped)."
            alert.addButton(withTitle: "Keep My Edits")
            alert.addButton(withTitle: "Use the File on Disk")
            alert.addButton(withTitle: "Decide Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn: choice = .keepEdits
            case .alertSecondButtonReturn: choice = .takeDisk
            default: choice = .decideLater
            }
        } else {
            // Nobody to ask: saving on purpose keeps the edits; an automatic commit waits for someone who can decide.
            choice = explicit ? .keepEdits : .decideLater
        }
        buffer.conflictPostponed = choice == .decideLater
        return choice
    }

    /// The buffer takes the file's current bytes (its edits are dropped, with their undo history).
    private func adoptDisk(_ bytes: Data, into buffer: FileBuffer) {
        let disk = CodeDocument(data: bytes)
        apiChange {
            buffer.document = disk
            buffer.base = bytes
            buffer.isDirty = false
            buffer.conflictPostponed = false
            if buffer === current {
                _ = replaceShownText(with: disk.text, keepCaret: true)
                textView.lineEnding = disk.lineEnding.string
            } else {
                buffer.text = disk.text
                let length = (disk.text as NSString).length
                buffer.selection = NSRange(location: min(buffer.selection.location, length), length: 0)
            }
            buffer.undoManager.removeAllActions()
            updateJumpBar()
        }
    }

    /// Whether an ANSI buffer may be converted to Unicode for its commit. With nobody to ask (no callback, no visible
    /// window) it converts, like `IniWriter` — unless the user already declined: that answer stands until they can
    /// be asked again (the host's close check runs while its window is still visible).
    private func confirmConversion(of buffer: FileBuffer, explicit: Bool) -> Bool {
        if buffer.conversionDeclined && !explicit { return false }
        let accepted: Bool
        if let onEncodingConversion {
            accepted = onEncodingConversion(buffer.url, buffer.document)
        } else if buffer.conversionDeclined, !(window?.isVisible ?? false) {
            accepted = false
        } else if let window, window.isVisible {
            let alert = NSAlert()
            alert.messageText = "Convert “\(buffer.url.lastPathComponent)” to Unicode?"
            alert.informativeText = "The file is saved as \(buffer.document.encodingName), which can’t hold some of the "
                + "characters you typed. Converting saves it as UTF-16 LE, which Rainmeter skins can use as well."
            alert.addButton(withTitle: "Convert to Unicode")
            alert.addButton(withTitle: "Keep Editing")
            accepted = alert.runModal() == .alertFirstButtonReturn
        } else {
            accepted = true
        }
        buffer.conversionDeclined = !accepted
        return accepted
    }

    /// Runs the pending idle commit now (self-tests: no waiting on the clock). False when none was pending.
    @discardableResult
    func fireIdleCommit() -> Bool {
        guard let timer = commitTimer, timer.isValid else { return false }
        timer.fire()
        return true
    }

    private func scheduleCommit() {
        commitTimer?.invalidate()
        let timer = Timer(timeInterval: idleCommitDelay, repeats: false) { [weak self] _ in
            guard let self, let current = self.current else { return }
            self.commitTimer = nil
            // Not in the middle of an input-method composition: its marked text is not typed yet.
            if self.textView.hasMarkedText() {
                self.scheduleCommit()
                return
            }
            self.commit(current)
        }
        RunLoop.main.add(timer, forMode: .default)
        commitTimer = timer
    }

    /// ⌘S, ⌘+ / ⌘− / ⌘0 and the find shortcuts while the text view is focused. Returns true when handled.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch (key, flags) {
        case ("s", [.command]):
            commitAll(explicit: true)
        case ("=", [.command]), ("+", [.command]), ("=", [.command, .shift]), ("+", [.command, .shift]):
            makeTextLarger(nil)
        case ("-", [.command]):
            makeTextSmaller(nil)
        case ("0", [.command]):
            makeTextStandardSize(nil)
        case ("f", [.command]):
            finderAction(.showFindInterface)
        case ("f", [.command, .option]):
            finderAction(.showReplaceInterface)
        case ("g", [.command]):
            finderAction(.nextMatch)
        case ("g", [.command, .shift]):
            finderAction(.previousMatch)
        case ("e", [.command]):
            finderAction(.setSearchString)
        default:
            return false
        }
        return true
    }

    private func finderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    // MARK: - Caret reports

    private func scheduleCaretRest(fromTyping: Bool) {
        caretTimer?.invalidate()
        caretMoveFromTyping = fromTyping
        let timer = Timer(timeInterval: caretRestDelay, repeats: false) { [weak self] _ in
            self?.caretTimer = nil
            self?.caretRested()
        }
        RunLoop.main.add(timer, forMode: .default)
        caretTimer = timer
    }

    /// Reports a pending caret rest now (self-tests: no waiting on the clock). False when none was pending.
    @discardableResult
    func fireCaretRest() -> Bool {
        guard let timer = caretTimer, timer.isValid else { return false }
        timer.fire()
        return true
    }

    /// When the pending idle commit is due (nil: none pending), for self-tests.
    var idleCommitDate: Date? { commitTimer.flatMap { $0.isValid ? $0.fireDate : nil } }

    private func caretRested() {
        guard let buffer = current else { return }
        let section = caretSection
        updateSectionTitle(section)
        if caretMoveFromTyping, let last = lastReport, last.url == buffer.url, last.section == section { return }
        lastReport = (buffer.url, section)
        onCaretSection?(buffer.url, section)
    }

    /// Runs an API change: no caret reports (a pending one is dropped), highlighting and jump bar settled at the end.
    private func apiChange(_ body: () -> Void) {
        apiDepth += 1
        caretTimer?.invalidate()
        caretTimer = nil
        body()
        flushHighlight()
        apiDepth -= 1
        if apiDepth == 0 {
            // The next user move is reported even in the same section: the host may have selected something else.
            lastReport = nil
            updateSectionTitle(caretSection)
            ruler.updateThickness(lineCount: analysis.lineCount)
            ruler.needsDisplay = true
            textView.updateCurrentLineHighlight()
        }
    }

    // MARK: - Highlighting

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let font = CodeEditorTheme.font(size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.tabStops = []
        paragraph.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: font]).width
        return [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }

    private func applyFont() {
        let attributes = baseAttributes
        textView.font = attributes[.font] as? NSFont
        textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = attributes
        if let storage = textView.textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        ruler.font = CodeEditorTheme.lineNumberFont(size: fontSize)
        ruler.updateThickness(lineCount: analysis.lineCount, force: true)
        ruler.needsDisplay = true
    }

    /// Re-colors the lines touched by `range` (temporary attributes: no undo, no layout, no text change).
    private func highlight(_ range: NSRange) {
        guard let storage = textView.textStorage, let layoutManager = textView.layoutManager else { return }
        let text = storage.mutableString as NSString
        let lines = IniHighlighter.lineRange(in: text, containing: range)
        guard lines.length > 0 else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: lines)
        for token in IniHighlighter.tokens(in: text, range: lines) {
            guard let color = CodeEditorTheme.color(for: token.kind) else { continue }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
        }
    }

    private func flushHighlight() {
        guard let range = pendingHighlight else { return }
        pendingHighlight = nil
        highlight(range)
    }

    /// `range` after an edit that replaced `edited.length - delta` characters at `edited.location` by `edited.length`
    /// characters: shifted when the edit is before it, grown or shrunk (and joined with the edit) when they overlap.
    private static func adjust(_ range: NSRange, forEdit edited: NSRange, delta: Int, length: Int) -> NSRange {
        let oldEnd = edited.location + edited.length - delta
        var result = range
        if oldEnd <= range.location {
            result.location += delta
        } else if edited.location < NSMaxRange(range) {
            let start = min(range.location, edited.location)
            let end = max(NSMaxRange(range) + delta, NSMaxRange(edited))
            result = NSRange(location: start, length: max(0, end - start))
        }
        let start = min(max(result.location, 0), length)
        return NSRange(location: start, length: min(max(result.length, 0), length - start))
    }

    // MARK: - Scrolling

    private func scrollToVisible(_ range: NSRange) {
        guard let layoutManager = textView.layoutManager else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(NSMaxRange(range) + 1,
                                                                                      (textView.string as NSString).length)))
        guard let rect = textView.lineRect(forCharacterRange: range) else { return }
        let clip = scrollView.contentView
        let visible = clip.bounds
        if rect.minY >= visible.minY, rect.maxY <= visible.maxY { return }
        let maxY = max(0, textView.frame.height - visible.height)
        let y = min(max(rect.midY - visible.height / 2, 0), maxY)
        clip.scroll(to: NSPoint(x: visible.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls back to `origin` (a clip view bounds origin saved earlier), as far as the text now reaches.
    private func restoreScroll(_ origin: NSPoint) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let clip = scrollView.contentView
        let size = clip.bounds.size
        if origin.y > 0 {
            // The text from the top down to the bottom of the restored view: with non-contiguous layout, laying out
            // only that view left the text above it estimated too short to scroll there.
            let bottom = origin.y + size.height - textView.textContainerOrigin.y
            layoutManager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: bottom),
                                       in: container)
        }
        // The clip view knows how far it may scroll; its left inset keeps the text clear of the line numbers.
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func clipViewScrolled(_ notification: Notification) {
        ruler.needsDisplay = true
    }

    // MARK: - Jump bar

    private var analysis: CodeDocument {
        if let cached = analysisCache { return cached }
        let document = CodeDocument(text: textView.string)
        analysisCache = document
        return document
    }

    private func updateJumpBar() {
        let names = buffers.map { $0.url.lastPathComponent }
        filePopUp.removeAllItems()
        for buffer in buffers {
            var title = buffer.url.lastPathComponent
            if names.filter({ $0 == title }).count > 1 {
                title += " (\(buffer.url.deletingLastPathComponent().lastPathComponent))"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = buffer.url
            item.toolTip = buffer.url.path
            item.image = buffer.isDirty ? CodeEditorTheme.dirtyDot : CodeEditorTheme.cleanDot
            item.setAccessibilityLabel(buffer.isDirty ? "\(title), edited" : title)
            filePopUp.menu?.addItem(item)
        }
        if let current, let index = buffers.firstIndex(where: { $0 === current }) { filePopUp.selectItem(at: index) }
        if let current {
            statusLabel.stringValue = "\(current.document.encodingName) · \(current.document.lineEnding.name)"
        } else {
            statusLabel.stringValue = ""
        }
    }

    private func updateSectionTitle(_ section: String?) {
        guard let title = sectionPopUp.item(at: 0) else { return }
        let header = section.flatMap { name in analysis.sectionHeaders().first { $0.name == name } }
        title.title = section ?? "No Section"
        title.image = header.map { CodeEditorView.symbolImage(for: $0) }
            ?? EditorStyle.image("text.alignleft", size: 11)
    }

    private static func symbolImage(for header: CodeDocument.Header) -> NSImage? {
        let kind: InspectedSectionKind
        switch header.name.lowercased() {
        case "rainmeter": kind = .rainmeter
        case "variables": kind = .variables
        case "metadata": kind = .metadata
        default: kind = header.measure != nil ? .measure : (header.meter != nil ? .meter : .other)
        }
        return EditorStyle.image(EditorStyle.symbol(for: kind, type: header.meter?.lowercased() ?? ""), size: 11)
    }

    @objc private func filePicked(_ sender: NSPopUpButton) {
        guard let url = sender.selectedItem?.representedObject as? URL, let buffer = buffer(for: url) else { return }
        guard buffer !== current else { return }
        show(buffer)
        window?.makeFirstResponder(textView)
        onFileChange?(buffer.url)
    }

    @objc private func sectionPicked(_ sender: NSPopUpButton) {
        guard let line = sender.selectedItem?.representedObject as? Int else { return }
        // A user navigation: the caret moves (and is reported) like a click on the header.
        let range = analysis.range(ofLine: line)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        scrollToVisible(range)
        window?.makeFirstResponder(textView)
    }

    /// The text view lost the keyboard focus.
    func focusLeft() {
        if let current { commit(current) }
    }

    /// Selects the line that contains `offset`, as a user action (the ruler's clicks).
    func selectLine(containingOffset offset: Int) {
        let line = analysis.line(containingOffset: offset)
        textView.setSelectedRange(analysis.range(ofLine: line))
    }

    // MARK: - Window

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        // Leaving the window (the host replacing or tearing down the pane) is the last chance to save, so it asks
        // again about a declined conversion. A refused commit leaves the buffer dirty: the host checks
        // `hasUncommittedChanges` before it lets the view go.
        if newWindow == nil, window != nil { commitNow(explicit: true) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Switching to another window or app commits, like focus leaving the text view.
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.commitNow()
            })
    }
}

// MARK: - Delegates

extension CodeEditorView: NSTextViewDelegate, NSTextStorageDelegate, NSMenuDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        current?.undoManager
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        if apiDepth == 0 { isEditingText = true }
        return true
    }

    func textDidChange(_ notification: Notification) {
        isEditingText = false
        flushHighlight()
        guard let buffer = current else { return }
        let wasDirty = buffer.isDirty
        buffer.isDirty = !(textView.textStorage?.mutableString.isEqual(to: buffer.document.text) ?? true)
        if buffer.isDirty != wasDirty { updateJumpBar() }
        if buffer.isDirty { scheduleCommit() } else { commitTimer?.invalidate() }
        ruler.updateThickness(lineCount: analysis.lineCount)
        ruler.needsDisplay = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.updateCurrentLineHighlight()
        ruler.needsDisplay = true
        guard apiDepth == 0 else { return }
        scheduleCaretRest(fromTyping: isEditingText)
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        analysisCache = nil
        let length = textStorage.length
        if let pending = pendingHighlight {
            pendingHighlight = NSUnionRange(Self.adjust(pending, forEdit: editedRange, delta: delta, length: length),
                                            editedRange)
        } else {
            pendingHighlight = editedRange
        }
        if let tint = tintedRange {
            tintedRange = Self.adjust(tint, forEdit: editedRange, delta: delta, length: length)
        }
        // Colors are applied after the edit (textDidChange / the API call's end); this covers any other path.
        DispatchQueue.main.async { [weak self] in self?.flushHighlight() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sectionPopUp.menu else { return }
        let title = menu.item(at: 0)
        menu.removeAllItems()
        if let title { menu.addItem(title) }
        let headers = analysis.sectionHeaders()
        if headers.isEmpty {
            let empty = NSMenuItem(title: "No Sections", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for header in headers {
            let item = NSMenuItem(title: header.name, action: nil, keyEquivalent: "")
            item.representedObject = header.line
            item.image = CodeEditorView.symbolImage(for: header)
            menu.addItem(item)
        }
    }
}

/// The jump bar's background: the editor's text background, so bar and code read as one pane.
private final class JumpBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

// MARK: - Text view

/// The code text view: Return inserts the file's line ending, pasted text is converted to it, the editor's key
/// equivalents run while it is focused, and the background shows the section tint and the current line.
final class CodeTextView: NSTextView {
    weak var editor: CodeEditorView?
    /// The line ending Return inserts (the file's dominant one).
    var lineEnding = "\r\n"
    /// Characters of the tinted section (drawn as a full-width band).
    var tintRange: NSRange? {
        didSet { if tintRange != oldValue { needsDisplay = true } }
    }
    private var currentLineRect = NSRect.zero

    override func insertNewline(_ sender: Any?) {
        insertText(lineEnding, replacementRange: selectedRange())
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }
    override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }
    override func insertParagraphSeparator(_ sender: Any?) { insertNewline(sender) }

    /// Pasted and dropped text takes the file's line ending, so a paste does not mix LF into a CRLF file.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let string = pboard.string(forType: .string) else {
            return super.readSelection(from: pboard, type: type)
        }
        let text = CodeTextView.convertingLineEndings(string, to: lineEnding)
        // Text that already uses the file's line ending takes AppKit's own path (drags within the view rely on it).
        if (text as NSString).isEqual(to: string) { return super.readSelection(from: pboard, type: type) }
        let range = rangeForUserTextChange
        guard range.location != NSNotFound, shouldChangeText(in: range, replacementString: text) else { return false }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        return true
    }

    /// Every CRLF, CR and LF in `text` replaced by `ending`.
    static func convertingLineEndings(_ text: String, to ending: String) -> String {
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
            .replacingOccurrences(of: "\r", with: "\n", options: .literal)
        return ending == "\n" ? lf : lf.replacingOccurrences(of: "\n", with: ending, options: .literal)
    }

    /// Focus leaving the code commits it. (Not `textDidEndEditing`: NSText also sends that around edits made while
    /// the view is not first responder.)
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { editor?.focusLeft() }
        return resigned
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, editor?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), editor?.handleKeyEquivalent(event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: Background

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let tintRange, let band = lineRect(forCharacterRange: tintRange), band.intersects(rect) {
            CodeEditorTheme.sectionTint.setFill()
            band.fill(using: .sourceOver)
        }
        if let line = caretLineRect(), line.intersects(rect) {
            CodeEditorTheme.currentLine.setFill()
            line.fill(using: .sourceOver)
        }
    }

    /// Invalidates the old and new current-line bands after the selection moved.
    func updateCurrentLineHighlight() {
        let rect = caretLineRect() ?? .zero
        guard rect != currentLineRect else { return }
        if !currentLineRect.isEmpty { setNeedsDisplay(currentLineRect) }
        if !rect.isEmpty { setNeedsDisplay(rect) }
        currentLineRect = rect
    }

    /// The full-width band of the caret's line (all its wrapped fragments); nil while a range is selected.
    func caretLineRect() -> NSRect? {
        let selection = selectedRange()
        guard selection.length == 0, let storage = textStorage else { return nil }
        let line = IniHighlighter.lineRange(in: storage.mutableString, containing: NSRange(location: selection.location, length: 0))
        return lineRect(forCharacterRange: line)
    }

    /// The full-width band covering the line fragments of `range` (the empty last line when `range` is empty at the
    /// end of the text), in view coordinates.
    func lineRect(forCharacterRange range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let length = storage.length
        var rect = NSRect.null
        if range.length > 0, range.location < length {
            let characters = NSRange(location: range.location, length: min(range.length, length - range.location))
            let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
                rect = rect.union(fragment)
            }
        } else if range.location >= length {
            // The extra fragment exists once layout has reached the end of the text.
            if length > 0 {
                layoutManager.ensureLayout(forCharacterRange: NSRange(location: length - 1, length: 1))
            } else {
                layoutManager.ensureLayout(for: textContainer)
            }
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty { rect = extra }
        }
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return NSRect(x: 0, y: rect.minY + textContainerOrigin.y, width: bounds.width, height: rect.height)
    }
}

// MARK: - Theme

/// Colors and fonts of the code editor: muted, semantic (each has a light and a dark variant), in the editor's calm
/// style. Variables are purple like the inspector's variable pills.
enum CodeEditorTheme {
    static func font(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    static func lineNumberFont(size: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: max(size - 1.5, 8), weight: .regular) }

    /// nil: the plain text color.
    static func color(for kind: IniHighlighter.Kind) -> NSColor? {
        switch kind {
        case .value: return nil
        case .sectionHeader: return sectionHeader
        case .key: return key
        case .includeKey: return includeKey
        case .equals: return .tertiaryLabelColor
        case .typeName: return typeName
        case .variable: return variable
        case .sectionVariable: return sectionVariable
        case .bang: return bang
        case .comment: return comment
        case .number: return number
        case .quote: return quote
        case .paren: return .secondaryLabelColor
        }
    }

    static let sectionHeader = dynamic(light: 0x0B4F79, dark: 0x7CC4EC)
    static let key = dynamic(light: 0x326D74, dark: 0x8CC4C6)
    static let includeKey = dynamic(light: 0x815F03, dark: 0xD8C77E)
    static let typeName = dynamic(light: 0x9B2393, dark: 0xE58BCF)
    static let variable = dynamic(light: 0x6C36A9, dark: 0xB793F2)
    static let sectionVariable = dynamic(light: 0x2A7A3E, dark: 0x86CF94)
    static let bang = dynamic(light: 0xB8531C, dark: 0xEFA36A)
    static let comment = dynamic(light: 0x707F8C, dark: 0x7F8C98)
    static let number = dynamic(light: 0x1C4FC4, dark: 0x9DB8FF)
    static let quote = dynamic(light: 0xB0352A, dark: 0xEE8C7C)

    static let currentLine = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.035)
    }
    static let sectionTint = NSColor(name: nil) { appearance in
        NSColor.controlAccentColor.withAlphaComponent(isDark(appearance) ? 0.14 : 0.09)
    }
    static let rulerText = NSColor.tertiaryLabelColor
    static let rulerCurrentText = NSColor.secondaryLabelColor

    /// The jump bar's "edited" dot, and a transparent stand-in of the same size so titles line up.
    static let dirtyDot = dot(NSColor.secondaryLabelColor)
    static let cleanDot = dot(nil)

    private static func dot(_ color: NSColor?) -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            if let color {
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            }
            return true
        }
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        func rgb(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        let l = rgb(light), d = rgb(dark)
        return NSColor(name: nil) { isDark($0) ? d : l }
    }
}
