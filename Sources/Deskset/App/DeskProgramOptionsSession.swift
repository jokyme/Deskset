import AppKit
import DesksetCore

final class DeskProgramOptionsChange {
    let input: ProgramOptionsInput
    let revision: UInt64
    private var completion: ((Result<ProgramOptionsSnapshot, Error>) -> Void)?

    init(input: ProgramOptionsInput, revision: UInt64,
         completion: @escaping (Result<ProgramOptionsSnapshot, Error>) -> Void) {
        self.input = input; self.revision = revision; self.completion = completion
    }

    func finish(_ result: Result<ProgramOptionsSnapshot, Error>) {
        let callback = completion
        completion = nil
        callback?(result)
    }
}

/// Main owns the panel's drafts; the runtime owner accepts complete snapshots serially. New edits coalesce by
/// stable option name while resources are pending, so an older reply cannot overwrite a newer control value.
final class DeskProgramOptionsSession {
    typealias Update = (ProgramOptionsInput, UInt64, @escaping (Result<ProgramOptionsSnapshot, Error>) -> Void) -> Void
    let panel: DeskProgramOptionsPanelController
    let lease = UUID()
    private(set) var snapshot: ProgramOptionsSnapshot
    private let defaults: ProgramOptionsInput
    private let update: Update
    private let save: (ProgramOptionsInput) throws -> Void
    private let preview: Bool
    private var pending: [String: Edit] = [:]
    private var inFlight = false
    private var closeRequested = false
    private(set) var isClosed = false
    var onClosed: (() -> Void)?

    private struct Edit {
        let id: UUID
        let value: ProgramOptionValue
    }

    init(snapshot: ProgramOptionsSnapshot, defaults: ProgramOptionsInput, isPreview: Bool,
         presentsWindows: Bool, update: @escaping Update,
         save: @escaping (ProgramOptionsInput) throws -> Void, moreStyles: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        self.snapshot = snapshot; self.defaults = defaults; self.preview = isPreview
        self.update = update; self.save = save
        panel = DeskProgramOptionsPanelController(presentsWindows: presentsWindows)
        panel.onChange = { [weak self] change in
            guard let self, !self.isClosed, change.lease == self.lease,
                  self.snapshot.values.values[change.name] != nil else { return }
            self.pending[change.name] = Edit(id: change.id, value: change.value)
            self.submit()
        }
        panel.onRestoreDefaults = { [weak self] lease, _ in
            guard let self, !self.isClosed, self.lease == lease else { return }
            for (name, value) in self.defaults.values { self.pending[name] = Edit(id: UUID(), value: value) }
            self.submit()
        }
        panel.onMoreStyles = { [weak self] lease in
            guard let self, !self.isClosed, self.lease == lease else { return }
            moreStyles()
        }
        panel.onRequestClose = { [weak self] lease in
            guard let self, self.lease == lease else { return }
            self.requestClose()
        }
        panel.apply(snapshot, lease: lease, isPreview: isPreview)
    }

    func receive(_ snapshot: ProgramOptionsSnapshot) {
        precondition(Thread.isMainThread)
        guard !isClosed, snapshot.revision >= self.snapshot.revision else { return }
        self.snapshot = snapshot
        panel.apply(snapshot, lease: lease, isPreview: preview)
    }

    func requestClose() {
        guard !isClosed else { return }
        closeRequested = true
        finishCloseIfReady()
    }

    /// Source/session replacement cancels the UI lease. The owning window decides how its accepted values are
    /// retained; no delayed callback from this panel may save against a replacement document.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        pending.removeAll()
        panel.close()
        onClosed?()
    }

    private func submit() {
        guard !isClosed, !inFlight, !pending.isEmpty else { finishCloseIfReady(); return }
        let edits = pending, revision = snapshot.revision
        pending.removeAll()
        var values = snapshot.values.values
        for (name, edit) in edits { values[name] = edit.value }
        inFlight = true
        update(ProgramOptionsInput(values: values), revision) { [weak self] result in
            precondition(Thread.isMainThread)
            guard let self, !self.isClosed else { return }
            self.inFlight = false
            switch result {
            case .success(let snapshot):
                self.receive(snapshot)
                for edit in edits.values { self.panel.complete(edit.id, snapshot: self.snapshot) }
            case .failure(let error):
                // An independently accepted action may advance options while this request travels to its owner.
                // Rebase only explicitly edited names; never replay an older complete snapshot over those values.
                if (error as? DeskProgramHost.Failure) == .staleOptions, self.snapshot.revision > revision {
                    for (name, edit) in edits where self.pending[name] == nil { self.pending[name] = edit }
                } else {
                    self.panel.setFeedback(StudioText[.deskOptionsChangeFailed])
                    for edit in edits.values {
                        self.panel.complete(edit.id, snapshot: self.snapshot, message: StudioText[.deskOptionsChangeFailed])
                    }
                    self.closeRequested = false
                }
            }
            // A Main-owned preview may reply synchronously from its projection. Let that transaction leave
            // its measurement boundary before starting another coalesced edit or closing the panel.
            DispatchQueue.main.async { [weak self] in self?.submit() }
        }
    }

    private func finishCloseIfReady() {
        guard closeRequested, !isClosed, !inFlight, pending.isEmpty else { return }
        // The user can keep typing while a resource request is pending. Flush the current editor once more
        // before saving; that flush may enqueue a newer value and start another owner transaction.
        guard panel.commitEditing() else { closeRequested = false; return }
        guard closeRequested, !isClosed, !inFlight, pending.isEmpty else { return }
        do {
            try save(snapshot.values)
            close()
        } catch {
            closeRequested = false
            panel.setFeedback(StudioText[.deskOptionsSaveFailed])
        }
    }
}
