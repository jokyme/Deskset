import AppKit

final class DebugWatchEditorController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    typealias Preview = (DebugWatchExpression, @escaping (String) -> Void) -> Void

    private let expressionID: UUID
    private let preview: Preview
    private let execute: (String) -> Void
    private let save: (DebugWatchExpression) -> Void
    private let onClose: () -> Void

    private let stringButton = NSButton(radioButtonWithTitle: "String", target: nil, action: nil)
    private let formulaButton = NSButton(radioButtonWithTitle: "Formula", target: nil, action: nil)
    private let expressionView = NSTextView()
    private let resultView = NSTextView()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let executeButton = NSButton(title: "Execute", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var kind: DebugWatchExpression.Kind
    private var revision: UInt64 = 0
    private var activePreviewID: UUID?
    private var previewTimer: Timer?
    private var hasPreviewResult = false
    private(set) var isClosed = false

    var expression: DebugWatchExpression {
        DebugWatchExpression(id: expressionID, kind: kind, text: expressionView.string)
    }

    init(initial: DebugWatchExpression? = nil,
         preview: @escaping Preview,
         execute: @escaping (String) -> Void,
         save: @escaping (DebugWatchExpression) -> Void,
         onClose: @escaping () -> Void = {}) {
        expressionID = initial?.id ?? UUID()
        kind = initial?.kind ?? .string
        self.preview = preview
        self.execute = execute
        self.save = save
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = initial == nil ? "Add watch" : "Edit watch"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        expressionView.string = initial?.text ?? ""
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { previewTimer?.invalidate() }

    func show(relativeTo parent: NSWindow? = nil) {
        guard !isClosed, let window else { return }
        startPreviewing()
        if let parent, window.sheetParent == nil, !window.isVisible {
            parent.beginSheet(window) { [weak self] _ in self?.finish(saving: nil) }
        } else {
            showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(expressionView)
    }

    override func showWindow(_ sender: Any?) {
        guard !isClosed else { return }
        startPreviewing()
        super.showWindow(sender)
    }

    func startPreviewing() {
        guard !isClosed, previewTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollPreviewNow() }
        previewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        pollPreviewNow()
    }

    override func close() { finish(saving: nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        finish(saving: nil, dismissWindow: false)
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === expressionView, !isClosed else { return }
        expressionDidChange()
    }

    /// Polling skips an outstanding request; the next tick evaluates only the latest edit.
    func pollPreviewNow() {
        guard !isClosed, activePreviewID == nil, hasExpression else { return }
        let requestID = UUID()
        let requestedRevision = revision
        activePreviewID = requestID
        preview(expression) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosed, self.activePreviewID == requestID else { return }
                self.activePreviewID = nil
                guard self.revision == requestedRevision else { return }
                if self.resultView.string != result {
                    let selection = self.resultView.selectedRange()
                    self.resultView.string = result
                    let length = (result as NSString).length
                    if selection.location != NSNotFound {
                        let location = min(selection.location, length)
                        self.resultView.setSelectedRange(NSRange(location: location,
                                                                length: min(selection.length, length - location)))
                    }
                }
                self.hasPreviewResult = true
                self.updateControls()
            }
        }
    }

    private var hasExpression: Bool {
        !expressionView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func expressionDidChange() {
        revision &+= 1
        hasPreviewResult = false
        resultView.string = ""
        updateControls()
    }

    private func updateControls() {
        stringButton.state = kind == .string ? .on : .off
        formulaButton.state = kind == .formula ? .on : .off
        saveButton.isEnabled = !isClosed && hasExpression
        executeButton.isEnabled = !isClosed && kind == .string && hasExpression
        copyButton.isEnabled = !isClosed && hasPreviewResult
    }

    @objc private func selectKind(_ sender: NSButton) {
        guard !isClosed else { return }
        let selectedKind: DebugWatchExpression.Kind = sender === formulaButton ? .formula : .string
        guard selectedKind != kind else { updateControls(); return }
        kind = selectedKind
        expressionDidChange()
    }

    @objc private func copyResult(_ sender: Any?) {
        guard !isClosed, hasPreviewResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultView.string, forType: .string)
    }

    @objc private func executeExpression(_ sender: Any?) {
        guard !isClosed, kind == .string, hasExpression else { return }
        execute(expressionView.string)
        // Refresh the preview after dispatching the action without reporting its completion.
        expressionDidChange()
    }

    @objc private func saveExpression(_ sender: Any?) {
        guard !isClosed, hasExpression else { return }
        finish(saving: expression)
    }

    @objc private func cancelEditing(_ sender: Any?) { close() }

    private func finish(saving expression: DebugWatchExpression?, dismissWindow: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        revision &+= 1
        activePreviewID = nil
        previewTimer?.invalidate()
        previewTimer = nil
        updateControls()
        if dismissWindow, let window {
            window.sheetParent?.endSheet(window, returnCode: expression == nil ? .cancel : .OK)
            super.close()
        }
        if let expression { save(expression) }
        onClose()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let typeLabel = NSTextField(labelWithString: "Expression type:")
        let expressionLabel = NSTextField(labelWithString: "Expression:")
        let typeRow = NSStackView(views: [typeLabel, stringButton, formulaButton])
        typeRow.orientation = .horizontal
        typeRow.alignment = .centerY
        typeRow.spacing = 18

        for button in [stringButton, formulaButton] {
            button.target = self
            button.action = #selector(selectKind(_:))
        }
        copyButton.target = self
        copyButton.action = #selector(copyResult(_:))
        executeButton.target = self
        executeButton.action = #selector(executeExpression(_:))
        saveButton.target = self
        saveButton.action = #selector(saveExpression(_:))
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelEditing(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        let expressionScroll = makeTextScrollView(expressionView, editable: true)
        let resultScroll = makeTextScrollView(resultView, editable: false)
        expressionView.delegate = self
        expressionView.setAccessibilityLabel("Watch expression")
        resultView.setAccessibilityLabel("Watch result")

        let spacer = NSView()
        let buttonRow = NSStackView(views: [copyButton, executeButton, spacer, saveButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let views: [NSView] = [typeRow, expressionLabel, expressionScroll, resultScroll, buttonRow]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for button in [copyButton, executeButton, saveButton, cancelButton] {
            button.widthAnchor.constraint(equalToConstant: 92).isActive = true
        }
        NSLayoutConstraint.activate([
            typeRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            typeRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            expressionLabel.topAnchor.constraint(equalTo: typeRow.bottomAnchor, constant: 12),
            expressionLabel.leadingAnchor.constraint(equalTo: typeRow.leadingAnchor),
            expressionScroll.topAnchor.constraint(equalTo: expressionLabel.bottomAnchor, constant: 6),
            expressionScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            expressionScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            resultScroll.topAnchor.constraint(equalTo: expressionScroll.bottomAnchor, constant: 10),
            resultScroll.leadingAnchor.constraint(equalTo: expressionScroll.leadingAnchor),
            resultScroll.trailingAnchor.constraint(equalTo: expressionScroll.trailingAnchor),
            resultScroll.heightAnchor.constraint(equalTo: expressionScroll.heightAnchor),
            buttonRow.topAnchor.constraint(equalTo: resultScroll.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: expressionScroll.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: expressionScroll.trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window?.initialFirstResponder = expressionView
    }

    private func makeTextScrollView(_ textView: NSTextView, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        textView.isRichText = false
        textView.isEditable = editable
        textView.isSelectable = true
        textView.allowsUndo = editable
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = editable ? .textBackgroundColor : .controlBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 588, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        return scroll
    }

    var testExpressionView: NSTextView { expressionView }
    var testResultView: NSTextView { resultView }
    var testStringButton: NSButton { stringButton }
    var testFormulaButton: NSButton { formulaButton }
    var testCopyButton: NSButton { copyButton }
    var testExecuteButton: NSButton { executeButton }
    var testSaveButton: NSButton { saveButton }
    var testCancelButton: NSButton { cancelButton }
}
