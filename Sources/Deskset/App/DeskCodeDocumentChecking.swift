import AppKit
import DeskLanguage
import DesksetCore

/// The checker of one explicitly opened Desk document. The main thread owns the service; only its pending checks
/// run elsewhere. Only compiled literal images may read the widget folder; no sibling Desk text or Skin is loaded.
final class DeskCodeDocumentChecking {
    let file: URL
    let fileID: DeskFileID
    private weak var editor: CodeEditorView?
    private let service: DeskLanguageService
    private let checkQueue: DispatchQueue
    private var closed = false
    private var resourceRequest: UInt64 = 0
    private var prepared: DeskProgramResources.Prepared?
    private var resourceGeneration: Int?
    private var imageInput = DeskProgramResources.Input.ready([:])
    private(set) var snapshot: DeskSnapshot
    var onSnapshot: ((DeskSnapshot) -> Void)?

    init(file: URL, editor: CodeEditorView, checkingOn queue: DispatchQueue) {
        precondition(Thread.isMainThread)
        self.file = file.standardizedFileURL
        fileID = DeskFileID(path: file.lastPathComponent)
        self.editor = editor
        checkQueue = queue
        var options = DeskServiceOptions()
        options.fonts = DeskFontCatalog()
        options.symbols = DeskSymbolCatalog()
        options.messageLanguage = Self.language
        service = DeskLanguageService(openFile: fileID, files: [fileID: editor.text], options: options,
                                      version: editor.textRevision)
        snapshot = service.snapshot
        prepareImages(for: snapshot)
        editor.onTextRevision = { [weak self] url, revision, text in
            self?.update(file: url, revision: revision, text: text)
        }
    }

    private static var language: DiagnosticLanguage {
        StudioText.language == .chinese ? .simplifiedChinese : .english
    }

    /// Desk keeps its BOM as trivia in the text. Encoding that text as UTF-8 without an extra BOM preserves the bytes.
    static func document(from data: Data, file: URL) throws -> CodeDocument {
        guard data.count <= DeskCatalog.current.limits.maximumFileBytes else {
            throw ReadFailure(Diagnostic(id: .fileTooLarge, severity: .error,
                                         file: DeskFileID(path: file.lastPathComponent), range: 0..<0), language: language)
        }
        switch Desk.load(data, fileName: file.lastPathComponent) {
        case .text(let text, _): return CodeDocument(text: text, encoding: .utf8(bom: false))
        case .rejected(let diagnostic): throw ReadFailure(diagnostic, language: language)
        }
    }

    struct ReadFailure: LocalizedError {
        let diagnostic: Diagnostic
        let language: DiagnosticLanguage

        init(_ diagnostic: Diagnostic, language: DiagnosticLanguage) {
            self.diagnostic = diagnostic
            self.language = language
        }

        var errorDescription: String? {
            "\(diagnostic.id.rawValue): \(diagnostic.message(in: language)) [byte \(diagnostic.range.lowerBound)]"
        }
    }

    private func update(file url: URL, revision: Int, text: String) {
        precondition(Thread.isMainThread)
        guard !closed, url.standardizedFileURL == file, let editor,
              editor.currentFile == file, editor.textRevision == revision,
              editor.text.utf8.elementsEqual(text.utf8) else { return }
        let changed = DeskTextChange(range: 0..<service.text.utf16.count, text: text)
        let next = service.update(changes: [changed], version: revision, checkingOn: checkQueue, deliverOn: .main) {
            [weak self] checked in
            _ = self?.publish(checked)
        }
        publish(next)
    }

    /// Coming back to an unchanged file also checks platform information, such as newly available font families.
    func recheck() {
        precondition(Thread.isMainThread)
        guard let editor, let current = editor.currentFile else { return }
        update(file: current, revision: editor.textRevision, text: editor.text)
    }

    /// Publication is also checked against the editor, which may have changed before the service sees an edit.
    /// Kept internal so focused tests can deliver an actual old snapshot without changing the checker contract.
    @discardableResult
    func publish(_ candidate: DeskSnapshot) -> Bool {
        precondition(Thread.isMainThread)
        guard isCurrent(candidate) else { return false }
        snapshot = candidate
        prepareImages(for: candidate)
        onSnapshot?(candidate)
        return true
    }

    /// Publication and user actions must agree on the exact current document, even after a same-text recheck.
    func isCurrent(_ candidate: DeskSnapshot) -> Bool {
        precondition(Thread.isMainThread)
        guard !closed, let editor, editor.currentFile == file, candidate.file == fileID,
              candidate.version == editor.textRevision, candidate.text.utf8.elementsEqual(editor.text.utf8),
              candidate.generation == service.snapshot.generation else { return false }
        return true
    }

    /// Drawing receives only this current checked generation's inputs. A replaced source clears the canvas
    /// before the background preparation starts; the previous private copy is never presented as current.
    func imageResources(for candidate: DeskSnapshot) -> DeskProgramResources.Input {
        precondition(Thread.isMainThread)
        guard isCurrent(candidate), candidate.isChecked else { return .pending }
        if let prepared, resourceGeneration == candidate.generation, prepared.failure == nil, !prepared.unchanged() {
            prepareImages(for: candidate)
        }
        return imageInput
    }

    private func prepareImages(for candidate: DeskSnapshot) {
        precondition(Thread.isMainThread)
        prepared?.removeCopies()
        prepared = nil
        resourceGeneration = nil
        let next = resourceRequest.addingReportingOverflow(1)
        guard !next.overflow else { imageInput = .failed(StudioText[.deskImageRefreshFailed]); return }
        resourceRequest = next.partialValue
        imageInput = .ready([:])
        guard candidate.isChecked else { return }
        let sources = Desk.compile(candidate.checked, catalog: candidate.options.catalog, package: candidate.package).imageSources
        guard !sources.isEmpty else { return }
        imageInput = .pending
        let request = resourceRequest, root = file.deletingLastPathComponent()
        let limits = candidate.options.catalog.limits
        let language: StudioLanguage = candidate.options.messageLanguage == .simplifiedChinese ? .chinese : .english
        checkQueue.async { [weak self] in
            let result = DeskProgramResources.prepare(root: root, literals: sources,
                                                      maximumBytes: limits.maximumPackageBytes,
                                                      maximumFiles: limits.maximumPackageFiles, language: language)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.resourceRequest == request, self.isCurrent(candidate) else {
                    result.removeCopies(); return
                }
                // A curated resource package supplies the existing checker with existence/size facts. Its sole
                // Desk text is the already-open buffer; setPackage does not read sibling files or a manifest.
                let package = DeskPackage(files: result.files, texts: [self.fileID: candidate.text], isSingleFile: true)
                let checked = self.service.setPackage(package)
                self.prepared = result
                self.resourceGeneration = checked.generation
                self.imageInput = result.failure.map(DeskProgramResources.Input.failed) ?? .ready(result.images)
                self.snapshot = checked
                self.onSnapshot?(checked)
            }
        }
    }

    /// A standalone document accepts only a complete edit of the file it already opened.
    @discardableResult
    func apply(_ edit: DeskWorkspaceEdit, from candidate: DeskSnapshot, actionName: String) -> Bool {
        precondition(Thread.isMainThread)
        guard edit.changedFiles == [fileID] else { return false }
        return apply(edit.edits(for: fileID), from: candidate, actionName: actionName)
    }

    /// Validate the original list before any WorkspaceEdit normalization can discard overlaps. Completion will
    /// use this same entry for its primary and additional edits; all ranges address the same original text.
    @discardableResult
    func apply(_ edits: [DeskTextEditU16], from candidate: DeskSnapshot, actionName: String) -> Bool {
        precondition(Thread.isMainThread)
        guard isCurrent(candidate), candidate.isChecked, let editor, !edits.isEmpty else { return false }
        let index = candidate.index
        let selection = editor.textView.selectedRange()
        let (selectionEnd, selectionOverflow) = selection.location.addingReportingOverflow(selection.length)
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              !selectionOverflow, selectionEnd <= index.utf16Count,
              index.clampedUTF16(selection.location) == selection.location,
              index.clampedUTF16(selectionEnd) == selectionEnd else { return false }
        // Stable ordering includes repeated insertions at one position, as specified by the service.
        let ordered = edits.enumerated().sorted { a, b in
            let left = (a.element.range.start.offset, a.element.range.end.offset)
            let right = (b.element.range.start.offset, b.element.range.end.offset)
            return left != right ? left < right : a.offset < b.offset
        }.map(\.element)
        var reached = 0
        for edit in ordered {
            let start = edit.range.start.offset, end = edit.range.end.offset
            guard start >= 0, end >= start, end <= index.utf16Count, start >= reached,
                  index.clampedUTF16(start) == start, index.clampedUTF16(end) == end else { return false }
            reached = end
        }
        let replacement = NSMutableString(string: candidate.text)
        for edit in ordered.reversed() {
            replacement.replaceCharacters(in: NSRange(location: edit.range.start.offset,
                                                      length: edit.range.end.offset - edit.range.start.offset),
                                          with: edit.newText)
        }
        let nextText = replacement as String
        guard !nextText.utf8.elementsEqual(candidate.text.utf8) else { return false }
        // Map the original caret/selection once, rather than leaving it at the end of a whole-buffer insertion.
        func mapped(_ offset: Int) -> Int? {
            var delta = 0
            for edit in ordered {
                let start = edit.range.start.offset, end = edit.range.end.offset
                if offset < start { break }
                let inserted = edit.newText.utf16.count
                if offset < end {
                    let (atStart, overflow1) = start.addingReportingOverflow(delta)
                    let (after, overflow2) = atStart.addingReportingOverflow(inserted)
                    return overflow1 || overflow2 ? nil : after
                }
                let difference = inserted - (end - start)
                let (sum, overflow) = delta.addingReportingOverflow(difference)
                guard !overflow else { return nil }
                delta = sum
            }
            let (mapped, overflow) = offset.addingReportingOverflow(delta)
            return overflow ? nil : mapped
        }
        guard let start = mapped(selection.location), let end = mapped(selectionEnd), end >= start else { return false }
        return editor.replaceAsUser(with: nextText, selection: NSRange(location: start, length: end - start),
                                    actionName: actionName)
    }

    func close() {
        precondition(Thread.isMainThread)
        closed = true
        prepared?.removeCopies()
        prepared = nil
        imageInput = .pending
        editor?.onTextRevision = nil
        onSnapshot = nil
    }
}
