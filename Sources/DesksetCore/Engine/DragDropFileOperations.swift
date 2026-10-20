import Darwin
import Foundation

/// File operations used by DragDrop. Staging stays on the destination's volume so replacement can be undone.
enum DragDropFileOperations {
    /// False means that the request leaves the files unchanged (a collision or the same file).
    @discardableResult
    static func write(from source: URL, to destination: URL, folder: URL,
                      mode: DragDropMeasure.DropAction, replaceIfExists: Bool,
                      fileManager fm: FileManager = .default) throws -> Bool {
        guard mode == .copy || mode == .move || mode == .shortcut else { return false }
        guard source.isFileURL, destination.isFileURL, folder.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard let sourceInfo = try entryInfo(source) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let destinationInfo = try entryInfo(destination)
        if sameItem(source, destination) { return false }
        let sourceIsFolder = (sourceInfo.st_mode & S_IFMT) == S_IFDIR
        // A folder cannot be copied into itself. Replacing an ancestor would also remove the source.
        if mode != .shortcut && sourceIsFolder && isInside(destination, folder: source) { return false }
        if destinationInfo != nil && isInside(source, folder: destination) { return false }
        if destinationInfo != nil && !replaceIfExists { return false }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var parentInfo = stat()
        guard stat(parent.path, &parentInfo) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let renamingSource = mode == .move && sourceInfo.st_dev == parentInfo.st_dev
        let transaction = try temporaryFolder(in: parent, fileManager: fm)
        let staged = transaction.appendingPathComponent("staged")
        let previous = transaction.appendingPathComponent("previous")
        var sourceTransaction: URL?
        var sourceBackup: URL?
        var keepTransaction = false
        var keepSourceTransaction = false
        var installed = false
        var hadPrevious = false
        var renamedSourceInfo = sourceInfo
        defer {
            if !keepTransaction { try? fm.removeItem(at: transaction) }
            if let sourceTransaction, !keepSourceTransaction { try? fm.removeItem(at: sourceTransaction) }
        }

        do {
            if mode == .move && !renamingSource {
                let temporary = try temporaryFolder(in: source.deletingLastPathComponent(), fileManager: fm)
                sourceTransaction = temporary
                sourceBackup = temporary.appendingPathComponent("source")
            }
            if mode == .shortcut {
                try fm.createSymbolicLink(at: staged, withDestinationURL: source)
            } else if renamingSource {
                // Preserve the source inode, its hard links and any already-open file handles.
                try fm.moveItem(at: source, to: staged)
                if let current = try entryInfo(staged) { renamedSourceInfo = current }
            } else {
                // Cross-volume moves keep the source until a complete destination copy exists.
                try fm.copyItem(at: source, to: staged)
            }
            if destinationInfo != nil {
                try fm.moveItem(at: destination, to: previous)
                hadPrevious = true
            }
            try fm.moveItem(at: staged, to: destination)
            installed = true
            if let sourceBackup {
                // Both paths have the same parent volume. A failed detach can roll the destination back.
                try fm.moveItem(at: source, to: sourceBackup)
            }
            return true
        } catch {
            let operationError = error
            var recoveryErrors: [Error] = []
            var retainedSource: URL?
            var retainedDestination: URL?
            if renamingSource {
                // A failed rename leaves its input in place. Locate by inode so a late failure cannot
                // cause cleanup to delete the only original, even if installation already completed.
                var original = [source, staged, destination].first { matches(renamedSourceInfo, at: $0) }
                if original == nil, (try? entryInfo(source)) == nil, (try? entryInfo(staged)) != nil {
                    original = staged
                }
                if let original, original != source {
                    do {
                        guard try entryInfo(source) == nil else { throw CocoaError(.fileWriteFileExists) }
                        try fm.moveItem(at: original, to: source)
                    } catch {
                        retainedSource = original
                        if original == staged { keepTransaction = true }
                        recoveryErrors.append(error)
                    }
                }
            } else if let sourceBackup, (try? entryInfo(sourceBackup)) != nil {
                do {
                    guard try entryInfo(source) == nil else { throw CocoaError(.fileWriteFileExists) }
                    try fm.moveItem(at: sourceBackup, to: source)
                } catch {
                    keepSourceTransaction = true
                    retainedSource = sourceBackup
                    recoveryErrors.append(error)
                }
            }
            if installed && retainedSource != destination && (try? entryInfo(destination)) != nil {
                do { try fm.removeItem(at: destination) }
                catch { recoveryErrors.append(error) }
            }
            if hadPrevious || (try? entryInfo(previous)) != nil {
                do { try fm.moveItem(at: previous, to: destination) }
                catch {
                    keepTransaction = true
                    retainedDestination = previous
                    recoveryErrors.append(error)
                }
            }
            if !recoveryErrors.isEmpty {
                // Keep any surviving original in place when the filesystem also refuses recovery.
                throw RecoveryError(operation: operationError, recovery: recoveryErrors,
                                    destinationBackup: retainedDestination,
                                    sourceBackup: retainedSource)
            }
            throw operationError
        }
    }

    static func trash(at source: URL, fileManager fm: FileManager = .default) throws {
        try fm.trashItem(at: source, resultingItemURL: nil)
    }

    private static func temporaryFolder(in parent: URL, fileManager: FileManager) throws -> URL {
        let url = parent.appendingPathComponent(".Deskset-DragDrop-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private static func entryInfo(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func sameItem(_ first: URL, _ second: URL) -> Bool {
        let a = first.standardizedFileURL.resolvingSymlinksInPath()
        let b = second.standardizedFileURL.resolvingSymlinksInPath()
        if a.path == b.path { return true }
        var firstInfo = stat(), secondInfo = stat()
        return stat(a.path, &firstInfo) == 0 && stat(b.path, &secondInfo) == 0
            && firstInfo.st_dev == secondInfo.st_dev && firstInfo.st_ino == secondInfo.st_ino
    }

    private static func matches(_ original: stat, at url: URL) -> Bool {
        guard let current = try? entryInfo(url) else { return false }
        return original.st_dev == current.st_dev && original.st_ino == current.st_ino
    }

    private static func isInside(_ item: URL, folder: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        var parent = item.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        while true {
            if sameItem(parent, base) { return true }
            if parent.path == "/" || parent.path.isEmpty { return false }
            let next = parent.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            if next.path == parent.path { return false }
            parent = next
        }
    }

    private struct RecoveryError: LocalizedError {
        let operation: Error
        let recovery: [Error]
        let destinationBackup: URL?
        let sourceBackup: URL?

        var errorDescription: String? {
            let paths = [destinationBackup, sourceBackup].compactMap { $0?.path }.joined(separator: ", ")
            let details = recovery.map(\.localizedDescription).joined(separator: "; ")
            return "\(operation.localizedDescription) Recovery failed: \(details)"
                + (paths.isEmpty ? "" : " Original items retained at: \(paths)")
        }
    }
}
