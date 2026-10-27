import AppKit
import DesksetCore

enum MetadataEditingError: LocalizedError, Equatable {
    case unsavedChanges(String)
    case operationAborted(String)

    var errorDescription: String? {
        switch self {
        case .unsavedChanges(let name):
            return L("Changes to “%@” must be saved before adding metadata.", name)
        case .operationAborted(let name):
            return L("Could not add metadata to “%@” while an editor save was still in progress.", name)
        }
    }
}

/// Inserts a missing `[Metadata]` section into a skin `.ini` file after committing any open built-in editor buffers and
/// flushing any matching editing sessions, then synchronizes only the target file's clean caches without closing
/// editors or refreshing running skins.
enum MetadataEditing {
    private final class Check {
        var wasReentered = false
    }
    private static var checking: [ObjectIdentifier: Check] = [:]

    @discardableResult
    static func addIfMissing(to file: URL, app: AppController) throws -> Bool {
        let name = file.lastPathComponent
        guard Thread.isMainThread else {
            throw MetadataEditingError.operationAborted(name)
        }
        let appID = ObjectIdentifier(app)
        if let active = checking[appID] {
            active.wasReentered = true
            throw MetadataEditingError.operationAborted(name)
        }
        let check = Check()
        checking[appID] = check
        defer { checking[appID] = nil }

        let targetID = SourceFileID(file)
        let studio = StudioWindowController.window(for: app)
        let studioFiles = studio?.codeView.files.map(SourceFileID.init)
        let studioSession = studio?.session
        let affectedStudio = studio.flatMap {
            $0.codeView.files.contains(where: { SourceFileID($0) == targetID }) ? $0 : nil
        }
        let fileWindows = app.codeFileWindows
        let fileWindowTargets = fileWindows.map { SourceFileID($0.file) }
        let affectedFileWindows = fileWindows.filter { SourceFileID($0.file) == targetID }
        let sessionSnapshot = app.studioSessions.keys.sorted().compactMap { key in
            app.studioSessions[key].map { (key: key, session: $0) }
        }

        func registrationsMatch() -> Bool {
            guard !check.wasReentered, !app.isTerminating, SourceFileID(file) == targetID else { return false }
            let currentStudio = StudioWindowController.window(for: app)
            guard currentStudio === studio,
                  currentStudio?.session === studioSession,
                  currentStudio?.codeView.files.map(SourceFileID.init) == studioFiles else { return false }
            guard app.codeFileWindows.map(ObjectIdentifier.init) == fileWindows.map(ObjectIdentifier.init),
                  app.codeFileWindows.map({ SourceFileID($0.file) }) == fileWindowTargets else { return false }
            guard app.studioSessions.count == sessionSnapshot.count,
                  sessionSnapshot.allSatisfy({ app.studioSessions[$0.key] === $0.session }) else { return false }
            return true
        }

        func matchingSessions() -> [EditingSession] {
            var seen: Set<ObjectIdentifier> = []
            var result: [EditingSession] = []
            let candidates = sessionSnapshot.map(\.session) + (studioSession.map { [$0] } ?? [])
            for session in candidates where seen.insert(ObjectIdentifier(session)).inserted {
                if session.buffers.contains(targetID.url) {
                    result.append(session)
                }
            }
            return result
        }

        guard registrationsMatch() else { throw MetadataEditingError.operationAborted(name) }
        if let affectedStudio {
            guard !affectedStudio.codeView.hasCommitInProgress else {
                throw MetadataEditingError.operationAborted(name)
            }
            guard affectedStudio.codeView.commitNow(explicit: true) else {
                throw MetadataEditingError.unsavedChanges(name)
            }
            guard registrationsMatch(),
                  !affectedStudio.codeView.hasCommitInProgress,
                  !affectedStudio.codeView.hasUncommittedChanges else {
                throw MetadataEditingError.unsavedChanges(name)
            }
        }
        for editor in affectedFileWindows {
            guard registrationsMatch(), !editor.codeView.hasCommitInProgress else {
                throw MetadataEditingError.operationAborted(name)
            }
            guard editor.codeView.commitNow(explicit: true) else {
                throw MetadataEditingError.unsavedChanges(name)
            }
            guard registrationsMatch(),
                  !editor.codeView.hasCommitInProgress,
                  !editor.codeView.hasUncommittedChanges else {
                throw MetadataEditingError.unsavedChanges(name)
            }
        }
        for session in matchingSessions() {
            guard registrationsMatch() else { throw MetadataEditingError.operationAborted(name) }
            try session.diskSync.flush()
            guard registrationsMatch(),
                  !session.diskSync.hasUnwrittenChanges,
                  !session.diskSync.hasScheduledFlush else {
                throw MetadataEditingError.unsavedChanges(name)
            }
        }
        guard registrationsMatch() else { throw MetadataEditingError.operationAborted(name) }
        if let affectedStudio {
            guard !affectedStudio.codeView.hasCommitInProgress,
                  !affectedStudio.codeView.hasUncommittedChanges else {
                throw MetadataEditingError.unsavedChanges(name)
            }
        }
        for editor in affectedFileWindows {
            guard !editor.codeView.hasCommitInProgress,
                  !editor.codeView.hasUncommittedChanges else {
                throw MetadataEditingError.unsavedChanges(name)
            }
        }
        for session in matchingSessions() {
            guard !session.diskSync.hasUnwrittenChanges,
                  !session.diskSync.hasScheduledFlush else {
                throw MetadataEditingError.unsavedChanges(name)
            }
        }

        let inserted = try IniWriter.addMetadataIfMissing(fileURL: file)
        for session in matchingSessions() {
            session.diskSync.adoptChanges([targetID.url])
            _ = session.diskSync.touchedOnDisk([targetID.url], marking: true)
        }
        if let affectedStudio {
            affectedStudio.codeView.reloadFromDisk(keepCaret: true, only: targetID)
        }
        for editor in affectedFileWindows {
            editor.codeView.reloadFromDisk(keepCaret: true, only: targetID)
        }
        return inserted
    }
}
