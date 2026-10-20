import DesksetCore
import Foundation

enum SafeStartRecoveryError: Error, LocalizedError {
    case desktopAlreadyLoaded

    var errorDescription: String? {
        "Safe Start recovery must finish before any skins load."
    }
}

extension AppController {
    /// Backs up the saved desktop, then commits an empty desktop without loading or closing any skins.
    func prepareSafeStartRecovery(saveBackup: ((LayoutDocument) throws -> Void)? = nil,
                                  writeState: ((Data, URL) throws -> Void)? = nil) throws {
        guard controllers.isEmpty, !isTerminating else { throw SafeStartRecoveryError.desktopAlreadyLoaded }
        let backup = layouts.captureBackup()
        if let saveBackup { try saveBackup(backup) }
        else { try layoutStore.save(backup, named: "@Backup") }
        try state.prepareSafeStart(write: writeState)
        sessionPositions.removeAll()
        notifyChanged()
    }
}
