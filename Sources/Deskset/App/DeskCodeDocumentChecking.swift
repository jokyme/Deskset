import AppKit
import DeskLanguage
import DesksetCore

/// The checker of one explicitly opened Desk document. The main thread owns the service; only its pending checks
/// run elsewhere. This does not load the parent folder or create a widget runtime.
final class DeskCodeDocumentChecking {
    let file: URL
    let fileID: DeskFileID
    private weak var editor: CodeEditorView?
    private let service: DeskLanguageService
    private let checkQueue: DispatchQueue
    private var closed = false
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
        options.messageLanguage = Self.language
        service = DeskLanguageService(openFile: fileID, files: [fileID: editor.text], options: options,
                                      version: editor.textRevision)
        snapshot = service.snapshot
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
        guard !closed, let editor, editor.currentFile == file, candidate.file == fileID,
              candidate.version == editor.textRevision, candidate.text.utf8.elementsEqual(editor.text.utf8),
              candidate.generation == service.snapshot.generation else { return false }
        snapshot = candidate
        onSnapshot?(candidate)
        return true
    }

    func close() {
        precondition(Thread.isMainThread)
        closed = true
        editor?.onTextRevision = nil
        onSnapshot = nil
    }
}
