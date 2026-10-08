import AppKit
import DeskLanguage
import DesksetCore

/// Construct on a file worker. The loader reads only the capture's bytes, including every sibling and package
/// text; the explicitly opened member is the sole buffer the checker may overlay.
struct DeskCodePackageInput: Sendable {
    let capture: DeskPackageCapture
    let package: DeskPackage
    let member: DeskFileID
    let memberBytes: Data
    var file: URL { capture.root.appendingPathComponent(member.path).standardizedFileURL }

    init(capture: DeskPackageCapture, member: DeskFileID) throws {
        guard DeskPackagePath.kind(of: member.path) == .widget,
              let components = DeskPackagePath.safeComponents(member.path), components.count == 1,
              DeskPackagePath.sameBytes(components[0], member.path),
              let entry = capture.files.first(where: { DeskPackagePath.sameBytes($0.path, member.path) }) else {
            throw DeskPackageMemberIO.Failure.invalidMember
        }
        self.capture = capture
        self.member = member
        memberBytes = entry.bytes
        package = try PackageLoader.load(capture.source, limits: capture.limits)
    }
}

struct DeskCodePackageSnapshot: Sendable {
    let input: DeskCodePackageInput
    let snapshot: DeskSnapshot
}

/// Main owns the service and publication. Standalone documents retain their explicit-image-only path; an
/// explicitly selected package uses immutable sibling input and file-worker freshness, never Main bulk reads.
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
    var onPackageFailure: ((Error) -> Void)?

    private let packageRootIdentity: DeskPackageCapture.Identity?
    private let packageQueue: DispatchQueue
    private var packageInput: DeskCodePackageInput?
    private var packageRequest: UInt64 = 0
    private var captureRevision: UInt64 = 0
    private var packageReading = false
    private var packageReady = false
    private var packageNeedsValidation = true
    private var reloadingPackage = false
    private var packageWork: Cancellation?
    private var imageWork: Cancellation?
    private var packageCompletion: ((Result<DeskCodePackageSnapshot, Error>) -> Void)?

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    private struct ImageFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(file: URL, editor: CodeEditorView, checkingOn queue: DispatchQueue, package: DeskCodePackageInput? = nil) {
        precondition(Thread.isMainThread)
        self.file = file.standardizedFileURL
        fileID = package?.member ?? DeskFileID(path: file.lastPathComponent)
        self.editor = editor
        checkQueue = queue
        packageQueue = DispatchQueue(label: "deskset.document.package", target: queue)
        packageInput = package
        packageRootIdentity = package?.capture.rootIdentity
        var options = DeskServiceOptions()
        options.fonts = DeskFontCatalog()
        options.symbols = DeskSymbolCatalog()
        options.messageLanguage = Self.language
        if let package {
            service = DeskLanguageService(package: package.package.settingText(editor.text, of: fileID),
                                          openFile: fileID, options: options, version: editor.textRevision)
        } else {
            service = DeskLanguageService(openFile: fileID, files: [fileID: editor.text], options: options,
                                          version: editor.textRevision)
        }
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
        guard !closed, !reloadingPackage, url.standardizedFileURL == file, let editor,
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
        guard owns(candidate) else { return false }
        snapshot = candidate
        prepareImages(for: candidate)
        onSnapshot?(candidate)
        return true
    }

    /// Publication and user actions must agree on the exact current document, even after a same-text recheck.
    func isCurrent(_ candidate: DeskSnapshot) -> Bool {
        precondition(Thread.isMainThread)
        return owns(candidate) && (packageInput == nil || packageReady)
    }

    private func owns(_ candidate: DeskSnapshot) -> Bool {
        guard !closed, let editor, editor.currentFile == file, candidate.file == fileID,
              candidate.version == editor.textRevision, candidate.text.utf8.elementsEqual(editor.text.utf8),
              candidate === service.snapshot, candidate.generation == service.snapshot.generation else { return false }
        return true
    }

    /// Drawing receives only this current checked generation's inputs. A replaced source clears the canvas
    /// before the background preparation starts; the previous private copy is never presented as current.
    func imageResources(for candidate: DeskSnapshot) -> DeskProgramResources.Input {
        precondition(Thread.isMainThread)
        guard isCurrent(candidate), candidate.isChecked else { return .pending }
        if packageInput == nil, let prepared, resourceGeneration == candidate.generation,
           prepared.failure == nil, !prepared.unchanged() {
            prepareImages(for: candidate)
        }
        return imageInput
    }

    private func prepareImages(for candidate: DeskSnapshot) {
        if packageInput != nil {
            preparePackageImages(for: candidate)
            return
        }
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

    /// Refresh the whole explicitly selected package on its file worker. New typing may reuse the returned
    /// capture, but resources and completion always belong to the latest buffer snapshot. An install caller also
    /// checks its saved revision/bytes in this completion before admitting the package.
    func refreshPackage(reloadMember: Bool = false,
                        completion: ((Result<DeskCodePackageSnapshot, Error>) -> Void)? = nil) {
        precondition(Thread.isMainThread)
        guard !closed, let input = packageInput else {
            completion?(.failure(DeskPackageCapture.Failure.cancelled))
            return
        }
        let next = packageRequest.addingReportingOverflow(1)
        guard !next.overflow else {
            completion?(.failure(DeskPackageCapture.Failure.resourceLimit))
            return
        }
        packageWork?.cancel()
        let previousCompletion = packageCompletion
        packageCompletion = completion
        packageRequest = next.partialValue
        let request = packageRequest, work = Cancellation()
        packageWork = work
        packageReading = true
        packageNeedsValidation = true
        invalidatePackageImages()
        previousCompletion?(.failure(DeskPackageCapture.Failure.cancelled))
        guard !closed, packageWork === work else { return }
        onSnapshot?(snapshot)
        guard !closed, packageWork === work else { return }
        let identity = packageRootIdentity
        packageQueue.async { [weak self] in
            let result: Result<DeskCodePackageInput, Error>
            do {
                if work.isCancelled { throw DeskPackageCapture.Failure.cancelled }
                let refreshed: DeskCodePackageInput
                do {
                    try input.capture.validateUnchanged(isCancelled: { work.isCancelled })
                    refreshed = input
                } catch {
                    if work.isCancelled { throw DeskPackageCapture.Failure.cancelled }
                    let capture = try DeskPackageCapture.read(root: input.capture.root, limits: input.capture.limits,
                                                              isCancelled: { work.isCancelled })
                    guard capture.rootIdentity.device == identity?.device,
                          capture.rootIdentity.inode == identity?.inode else {
                        throw DeskPackageCapture.Failure.changed("")
                    }
                    refreshed = try DeskCodePackageInput(capture: capture, member: input.member)
                }
                if work.isCancelled { throw DeskPackageCapture.Failure.cancelled }
                result = .success(refreshed)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.packageRequest == request, self.packageWork === work,
                      !work.isCancelled else { return }
                switch result {
                case .failure(let error): self.rejectPackage(error)
                case .success(let refreshed): self.acceptPackage(refreshed, reloadMember: reloadMember, work: work)
                }
            }
        }
    }

    private func acceptPackage(_ input: DeskCodePackageInput, reloadMember: Bool, work: Cancellation) {
        guard let editor, editor.currentFile == file,
              DeskPackagePath.sameBytes(input.file.path, file.path) else {
            rejectPackage(DeskPackageMemberIO.Failure.invalidMember)
            return
        }
        do {
            // Keep the existing read/decode failure contract even when a dirty buffer could otherwise overlay
            // newly invalid disk bytes. No buffer/base/undo or sibling state changes before this succeeds.
            _ = try Self.document(from: input.memberBytes, file: file)
        } catch { rejectPackage(error); return }
        let revision = captureRevision.addingReportingOverflow(1)
        guard !revision.overflow else { rejectPackage(DeskPackageCapture.Failure.resourceLimit); return }
        if reloadMember {
            let reader = editor.readData, commit = editor.onCommit
            reloadingPackage = true
            defer { editor.readData = reader; editor.onCommit = commit; reloadingPackage = false }
            editor.readData = { url in
                guard DeskPackagePath.sameBytes(url.standardizedFileURL.path, input.file.path) else {
                    throw DeskPackageMemberIO.Failure.invalidMember
                }
                return input.memberBytes
            }
            // Host callbacks during reload must not commit against the temporary capture reader.
            editor.onCommit = { _, _ in false }
            editor.reloadFromDisk(keepCaret: true)
        }
        guard !closed, packageWork === work, !work.isCancelled else { return }
        packageInput = input
        captureRevision = revision.partialValue
        packageReading = false
        _ = service.setPackage(input.package)
        // A clean reload may have changed the text; a dirty reload deliberately kept the original base/undo.
        // Only this final service state is published, with the same package tree used by all receipts.
        let change = DeskTextChange(range: 0..<service.text.utf16.count, text: editor.text)
        let next = service.update(changes: [change], version: editor.textRevision, checkingOn: checkQueue,
                                  deliverOn: .main) { [weak self] checked in _ = self?.publish(checked) }
        publish(next)
    }

    private func invalidatePackageImages() {
        imageWork?.cancel()
        imageWork = nil
        packageReady = false
        imageInput = .pending
        resourceGeneration = nil
        prepared?.removeCopies()
        prepared = nil
    }

    private func preparePackageImages(for candidate: DeskSnapshot) {
        invalidatePackageImages()
        guard let input = packageInput, candidate.isChecked, !packageReading else { return }
        let next = resourceRequest.addingReportingOverflow(1)
        guard !next.overflow else { rejectPackage(DeskPackageCapture.Failure.resourceLimit); return }
        resourceRequest = next.partialValue
        let request = resourceRequest, capture = captureRevision, refresh = packageRequest, work = Cancellation()
        imageWork = work
        let validateCapture = packageNeedsValidation
        let expectedFile = file.path
        let language: StudioLanguage = candidate.options.messageLanguage == .simplifiedChinese ? .chinese : .english
        packageQueue.async { [weak self] in
            var prepared: DeskProgramResources.Prepared?
            let result: Result<DeskProgramResources.Prepared, Error>
            do {
                if work.isCancelled { throw DeskPackageCapture.Failure.cancelled }
                guard DeskPackagePath.sameBytes(input.file.path, expectedFile) else {
                    throw DeskPackageMemberIO.Failure.invalidMember
                }
                let sources = Desk.compile(candidate.checked, catalog: candidate.options.catalog,
                                           package: candidate.package).imageSources
                if work.isCancelled { throw DeskPackageCapture.Failure.cancelled }
                let images = DeskProgramResources.prepare(capture: input.capture, literals: sources, language: language)
                prepared = images
                if let failure = images.failure { throw ImageFailure(message: failure) }
                if validateCapture { try input.capture.validateUnchanged(isCancelled: { work.isCancelled }) }
                guard !work.isCancelled else { throw DeskPackageCapture.Failure.cancelled }
                guard images.copiesUnchanged() else { throw DeskPackageCapture.Failure.changed("") }
                result = .success(images)
            } catch {
                prepared?.removeCopies()
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.imageWork === work, !work.isCancelled,
                      self.resourceRequest == request, self.captureRevision == capture,
                      self.packageRequest == refresh, self.owns(candidate) else {
                    if case .success(let images) = result { images.removeCopies() }
                    return
                }
                self.imageWork = nil
                switch result {
                case .failure(let error): self.rejectPackage(error)
                case .success(let images):
                    self.prepared = images
                    self.resourceGeneration = candidate.generation
                    self.imageInput = .ready(images.images)
                    self.packageReady = true
                    self.packageNeedsValidation = false
                    self.snapshot = candidate
                    let completion = self.packageCompletion
                    self.packageCompletion = nil
                    self.onSnapshot?(candidate)
                    if self.packageRequest == refresh, self.isCurrent(candidate) {
                        completion?(.success(DeskCodePackageSnapshot(input: input, snapshot: candidate)))
                    } else {
                        completion?(.failure(DeskPackageCapture.Failure.cancelled))
                    }
                }
            }
        }
    }

    private func rejectPackage(_ error: Error) {
        invalidatePackageImages()
        packageWork?.cancel()
        packageWork = nil
        packageReading = false
        packageNeedsValidation = true
        imageInput = .failed(error.localizedDescription)
        let completion = packageCompletion
        packageCompletion = nil
        onPackageFailure?(error)
        if !closed { onSnapshot?(snapshot) }
        completion?(.failure(error))
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
        guard !closed else { return }
        closed = true
        packageWork?.cancel()
        imageWork?.cancel()
        let completion = packageCompletion
        packageCompletion = nil
        prepared?.removeCopies()
        prepared = nil
        imageInput = .pending
        editor?.onTextRevision = nil
        onSnapshot = nil
        onPackageFailure = nil
        completion?(.failure(DeskPackageCapture.Failure.cancelled))
    }
}
