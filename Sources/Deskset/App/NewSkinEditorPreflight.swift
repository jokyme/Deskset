import AppKit

/// Closes built-in editors before a file created in the New Skin dialog is renamed or removed. A saved or explicitly
/// discarded buffer must not keep a pending writer pointed at the old path. External editors remain their own apps.
enum NewSkinEditorPreflight {
    private final class Check {
        var wasReentered = false
    }
    private static var checking: [ObjectIdentifier: Check] = [:]

    /// Save/Discard/Cancel follows each editor's existing close behavior. Any changed registration, busy save or
    /// unresolved buffer aborts the file operation; unrelated editors are left open.
    static func closeEditors(affectedBy url: URL, isDirectory: Bool, app: AppController) -> Bool {
        guard Thread.isMainThread else { return false }
        let appID = ObjectIdentifier(app)
        if let active = checking[appID] {
            active.wasReentered = true
            return false
        }
        let check = Check()
        checking[appID] = check
        defer { checking[appID] = nil }

        let path = CodeEditorRouter.comparablePath(url)
        func matches(_ file: URL) -> Bool {
            let candidate = CodeEditorRouter.comparablePath(file)
            return candidate == path || (isDirectory && candidate.hasPrefix(path == "/" ? path : path + "/"))
        }
        let studio = StudioWindowController.window(for: app)
        let studioFiles = studio?.codeView.files.map(CodeEditorRouter.comparablePath)
        let affectedStudio = studio.flatMap { $0.codeView.files.contains(where: matches) ? $0 : nil }
        let session = affectedStudio?.session
        let fileWindows = app.codeFileWindows
        let affectedFiles = fileWindows.filter { matches($0.file) }
        var closedFiles: Set<ObjectIdentifier> = []
        var closedStudio = false

        func registrationsMatch() -> Bool {
            guard !check.wasReentered else { return false }
            let currentStudio = StudioWindowController.window(for: app)
            if closedStudio {
                guard currentStudio == nil else { return false }
            } else {
                guard currentStudio === studio,
                      currentStudio?.codeView.files.map(CodeEditorRouter.comparablePath) == studioFiles else { return false }
                if let affectedStudio, affectedStudio.session !== session { return false }
            }
            return app.codeFileWindows.map(ObjectIdentifier.init)
                == fileWindows.filter { !closedFiles.contains(ObjectIdentifier($0)) }.map(ObjectIdentifier.init)
        }
        func clean() -> Bool {
            if let affectedStudio {
                guard !affectedStudio.codeView.hasCommitInProgress,
                      !affectedStudio.codeView.hasUncommittedChanges,
                      session?.diskSync.hasUnwrittenChanges != true,
                      session?.diskSync.hasScheduledFlush != true else { return false }
            }
            return affectedFiles.allSatisfy {
                !$0.codeView.hasCommitInProgress && !$0.codeView.hasUncommittedChanges
            }
        }

        if let affectedStudio {
            guard registrationsMatch(), affectedStudio.canTerminate(), registrationsMatch() else { return false }
            do { try session?.diskSync.flush() } catch { return false }
            guard registrationsMatch(), !affectedStudio.codeView.hasCommitInProgress,
                  !affectedStudio.codeView.hasUncommittedChanges,
                  session?.diskSync.hasUnwrittenChanges != true else { return false }
        }
        for editor in affectedFiles {
            guard registrationsMatch(), editor.canTerminate(), registrationsMatch() else { return false }
        }
        guard registrationsMatch(), clean() else { return false }

        if let affectedStudio {
            affectedStudio.window?.close()
            closedStudio = true
            guard registrationsMatch(), clean() else { return false }
        }
        for editor in affectedFiles {
            guard registrationsMatch(), clean() else { return false }
            editor.window?.close()
            closedFiles.insert(ObjectIdentifier(editor))
            guard registrationsMatch(), clean() else { return false }
        }
        return registrationsMatch() && clean()
    }
}
