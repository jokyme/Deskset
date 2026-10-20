import Foundation
@testable import DesksetCore

func runDragDropFileOperationTests(_ t: TestRunner) {
    t.suite("DragDrop: file operations copy, move and shortcut into missing folders") {
        for mode in [DragDropMeasure.DropAction.copy, .move, .shortcut] {
            let root = t.temporaryDirectory("dragdrop-new")
            let source = root.appendingPathComponent("original.txt")
            let folder = root.appendingPathComponent("missing/nested")
            let destination = folder.appendingPathComponent("original.txt")
            try writeDragDropTestFile("source", at: source)
            t.check(try DragDropFileOperations.write(from: source, to: destination, folder: folder,
                                                    mode: mode, replaceIfExists: false))
            t.equal(try String(contentsOf: destination, encoding: .utf8), "source")
            t.equal(FileManager.default.fileExists(atPath: source.path), mode != .move)
            if mode == .shortcut {
                t.equal(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), source.path)
            }
            t.equal(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["original.txt"])
            t.check(!containsDragDropTransaction(in: root), "successful operations clean staging files")
        }
    }

    t.suite("DragDrop: file operations replace complete files and directory trees") {
        for mode in [DragDropMeasure.DropAction.copy, .move, .shortcut] {
            let root = t.temporaryDirectory("dragdrop-replace")
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try writeDragDropTestFile("new", at: source.appendingPathComponent("nested/new.txt"))
            try writeDragDropTestFile("old", at: destination.appendingPathComponent("old.txt"))
            t.check(try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                                    mode: mode, replaceIfExists: true))
            t.equal(try String(contentsOf: destination.appendingPathComponent("nested/new.txt"), encoding: .utf8), "new")
            t.check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.txt").path))
            t.equal(FileManager.default.fileExists(atPath: source.path), mode != .move)
            t.check(!containsDragDropTransaction(in: root))
        }
    }

    t.suite("DragDrop: same-volume move preserves inode, hard links and open file handles") {
        let root = t.temporaryDirectory("dragdrop-rename")
        let source = root.appendingPathComponent("source.txt")
        let alias = root.appendingPathComponent("hard-link.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try writeDragDropTestFile("source", at: source)
        try writeDragDropTestFile("previous", at: destination)
        try FileManager.default.linkItem(at: source, to: alias)
        let identity = try dragDropTestIdentity(source)
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.seekToEnd()
        t.check(try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                                mode: .move, replaceIfExists: true))
        t.equal(try dragDropTestIdentity(destination), identity)
        t.equal(try dragDropTestIdentity(alias), identity)
        try handle.write(contentsOf: Data("-after-move".utf8))
        t.equal(try String(contentsOf: destination, encoding: .utf8), "source-after-move")
        t.equal(try String(contentsOf: alias, encoding: .utf8), "source-after-move")
        t.check(!FileManager.default.fileExists(atPath: source.path))
        t.check(!containsDragDropTransaction(in: root))
    }

    t.suite("DragDrop: same-volume move keeps source changes made immediately before rename") {
        let root = t.temporaryDirectory("dragdrop-late-write")
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try writeDragDropTestFile("initial", at: source)
        try writeDragDropTestFile("previous", at: destination)
        let fm = FailingDragDropFileManager()
        var updated = false
        fm.beforeMove = { from, _ in
            if from == source, !updated {
                try "latest".write(to: source, atomically: true, encoding: .utf8)
                updated = true
            }
        }
        t.check(try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                                mode: .move, replaceIfExists: true, fileManager: fm))
        t.check(updated)
        t.equal(try String(contentsOf: destination, encoding: .utf8), "latest")
        t.check(!FileManager.default.fileExists(atPath: source.path))
        t.check(!containsDragDropTransaction(in: root))
    }

    t.suite("DragDrop: file operations preserve collisions, including dangling links") {
        for mode in [DragDropMeasure.DropAction.copy, .move, .shortcut] {
            let root = t.temporaryDirectory("dragdrop-collision")
            let source = root.appendingPathComponent("source.txt")
            let destination = root.appendingPathComponent("destination.txt")
            try writeDragDropTestFile("source", at: source)
            try writeDragDropTestFile("destination", at: destination)
            t.check(try !DragDropFileOperations.write(from: source, to: destination, folder: root,
                                                     mode: mode, replaceIfExists: false))
            t.equal(try String(contentsOf: source, encoding: .utf8), "source")
            t.equal(try String(contentsOf: destination, encoding: .utf8), "destination")
            try FileManager.default.removeItem(at: destination)
            let missing = root.appendingPathComponent("missing.txt")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: missing)
            t.check(try !DragDropFileOperations.write(from: source, to: destination, folder: root,
                                                     mode: mode, replaceIfExists: false))
            t.equal(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), missing.path)
            t.check(try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                                    mode: mode, replaceIfExists: true))
            t.equal(try String(contentsOf: destination, encoding: .utf8), "source")
        }
    }

    t.suite("DragDrop: file operations leave identical paths, symlinks and hard links intact") {
        for mode in [DragDropMeasure.DropAction.copy, .move, .shortcut] {
            let root = t.temporaryDirectory("dragdrop-identical")
            let source = root.appendingPathComponent("source.txt")
            try writeDragDropTestFile("preserved", at: source)
            let link = root.appendingPathComponent("alias.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            let hardLink = root.appendingPathComponent("hard-link.txt")
            try FileManager.default.linkItem(at: source, to: hardLink)
            let normalized = root.appendingPathComponent("unused/../source.txt")
            for destination in [source, normalized, link, hardLink] {
                t.check(try !DragDropFileOperations.write(from: source, to: destination, folder: root,
                                                         mode: mode, replaceIfExists: true))
                t.equal(try String(contentsOf: source, encoding: .utf8), "preserved")
                t.equal(try String(contentsOf: link, encoding: .utf8), "preserved")
                t.equal(try String(contentsOf: hardLink, encoding: .utf8), "preserved")
            }
            t.check(try !DragDropFileOperations.write(from: link, to: source, folder: root,
                                                     mode: mode, replaceIfExists: true))
            t.equal(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), source.path)
            t.equal(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)),
                    ["source.txt", "alias.txt", "hard-link.txt"])
        }
    }

    t.suite("DragDrop: file operations reject recursive and ancestor replacements before making folders") {
        for mode in [DragDropMeasure.DropAction.copy, .move] {
            let root = t.temporaryDirectory("dragdrop-recursive")
            let source = root.appendingPathComponent("source")
            try writeDragDropTestFile("source", at: source.appendingPathComponent("child/item.txt"))
            let alias = root.appendingPathComponent("folder-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
            for folder in [source.appendingPathComponent("missing"), alias.appendingPathComponent("also-missing")] {
                t.check(try !DragDropFileOperations.write(from: source, to: folder.appendingPathComponent("source"),
                                                         folder: folder, mode: mode, replaceIfExists: true))
                t.check(!FileManager.default.fileExists(atPath: folder.path))
            }
            t.check(try !DragDropFileOperations.write(from: source.appendingPathComponent("child"), to: source,
                                                     folder: root, mode: mode, replaceIfExists: true))
            t.equal(try String(contentsOf: source.appendingPathComponent("child/item.txt"), encoding: .utf8), "source")
            t.check(!containsDragDropTransaction(in: root))
        }
    }

    t.suite("DragDrop: file operations allow a shortcut within its source directory") {
        let root = t.temporaryDirectory("dragdrop-inner-shortcut")
        let source = root.appendingPathComponent("source")
        try writeDragDropTestFile("preserved", at: source.appendingPathComponent("item.txt"))
        let folder = source.appendingPathComponent("shortcuts")
        let destination = folder.appendingPathComponent("source-link")
        t.check(try DragDropFileOperations.write(from: source, to: destination, folder: folder,
                                                mode: .shortcut, replaceIfExists: false))
        t.equal(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), source.path)
        t.equal(try String(contentsOf: destination.appendingPathComponent("item.txt"), encoding: .utf8), "preserved")
        t.equal(try String(contentsOf: source.appendingPathComponent("item.txt"), encoding: .utf8), "preserved")
        t.check(!containsDragDropTransaction(in: root))
    }

    t.suite("DragDrop: file operations keep originals when a source is absent or staging fails") {
        let root = t.temporaryDirectory("dragdrop-stage-failure")
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try writeDragDropTestFile("destination", at: destination)
        t.throwsError {
            try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                              mode: .copy, replaceIfExists: true)
        }
        t.check(LiveSideEffects.performDragDropWrite(from: source, to: destination, folder: root,
                                                     mode: .copy, replaceIfExists: true) != nil,
                "the live wrapper returns failures so its caller can log them")
        t.equal(try String(contentsOf: destination, encoding: .utf8), "destination")
        try writeDragDropTestFile("source", at: source)
        t.check(LiveSideEffects.performDragDropWrite(from: source, to: destination, folder: root,
                                                     mode: .copy, replaceIfExists: false) == nil,
                "a skipped collision is unchanged, not a filesystem error")
        for mode in [DragDropMeasure.DropAction.copy, .move] {
            let fm = FailingDragDropFileManager()
            fm.failCopy = mode == .copy
            if mode == .move { fm.failMove = { from, _ in from == source } }
            t.throwsError {
                try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                                  mode: mode, replaceIfExists: true, fileManager: fm)
            }
            t.equal(try String(contentsOf: source, encoding: .utf8), "source")
            t.equal(try String(contentsOf: destination, encoding: .utf8), "destination")
            t.check(!containsDragDropTransaction(in: root), "partial copies are removed after staging errors")
        }
    }

    t.suite("DragDrop: file operations restore replaced trees after installation fails") {
        for mode in [DragDropMeasure.DropAction.copy, .move, .shortcut] {
            let root = t.temporaryDirectory("dragdrop-install-failure")
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try writeDragDropTestFile("new", at: source.appendingPathComponent("new.txt"))
            try writeDragDropTestFile("old", at: destination.appendingPathComponent("nested/old.txt"))
            let fm = FailingDragDropFileManager()
            var failed = false
            fm.failMove = { _, to in
                guard to == destination, !failed else { return false }
                failed = true
                return true
            }
            t.throwsError {
                try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                                  mode: mode, replaceIfExists: true, fileManager: fm)
            }
            t.check(failed, "installation failed after the old destination was backed up")
            t.equal(try String(contentsOf: source.appendingPathComponent("new.txt"), encoding: .utf8), "new")
            t.equal(try String(contentsOf: destination.appendingPathComponent("nested/old.txt"), encoding: .utf8), "old")
            t.check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("new.txt").path))
            t.check(!containsDragDropTransaction(in: root))
        }
    }

    t.suite("DragDrop: file operations preserve destination when a source cannot be moved") {
        for replace in [false, true] {
            let root = t.temporaryDirectory("dragdrop-move-failure")
            let source = root.appendingPathComponent("source.txt")
            let destination = root.appendingPathComponent("destination.txt")
            try writeDragDropTestFile("source", at: source)
            if replace { try writeDragDropTestFile("destination", at: destination) }
            let fm = FailingDragDropFileManager()
            fm.failMove = { from, _ in from == source }
            t.throwsError {
                try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                                  mode: .move, replaceIfExists: replace, fileManager: fm)
            }
            t.equal(try String(contentsOf: source, encoding: .utf8), "source")
            if replace {
                t.equal(try String(contentsOf: destination, encoding: .utf8), "destination")
            } else {
                t.check(!FileManager.default.fileExists(atPath: destination.path))
            }
            t.check(!containsDragDropTransaction(in: root))
        }
    }

    t.suite("DragDrop: failed move recovery preserves the original source in staging") {
        let root = t.temporaryDirectory("dragdrop-source-recovery")
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try writeDragDropTestFile("source", at: source)
        try writeDragDropTestFile("destination", at: destination)
        let identity = try dragDropTestIdentity(source)
        let fm = FailingDragDropFileManager()
        var failedInstall = false
        fm.failMove = { _, to in
            if to == destination, !failedInstall { failedInstall = true; return true }
            return to == source
        }
        var message = ""
        do {
            try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                              mode: .move, replaceIfExists: true, fileManager: fm)
            t.check(false, "installation and source recovery should fail")
        } catch { message = error.localizedDescription }
        t.check(message.contains("Original items retained at:"))
        t.equal(try String(contentsOf: destination, encoding: .utf8), "destination")
        let survivors = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let original = survivors.first { (try? dragDropTestIdentity($0)) == identity }
        t.check(original != nil, "the moved source inode must survive a denied rollback")
        if let original {
            t.equal(try String(contentsOf: original, encoding: .utf8), "source")
            t.check(message.contains(original.resolvingSymlinksInPath().path), "the error identifies the retained source")
        }
    }

    t.suite("DragDrop: late installation failure keeps both originals when source recovery is refused") {
        let root = t.temporaryDirectory("dragdrop-installed-recovery")
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try writeDragDropTestFile("source", at: source)
        try writeDragDropTestFile("destination", at: destination)
        let sourceIdentity = try dragDropTestIdentity(source)
        let destinationIdentity = try dragDropTestIdentity(destination)
        let fm = FailingDragDropFileManager()
        fm.failMove = { _, to in to == source }
        fm.afterMove = { _, to in
            if to == destination { throw CocoaError(.fileWriteUnknown) }
        }
        var message = ""
        do {
            try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                              mode: .move, replaceIfExists: true, fileManager: fm)
            t.check(false, "installation reports failure after moving the source into place")
        } catch { message = error.localizedDescription }
        t.equal(try dragDropTestIdentity(destination), sourceIdentity)
        t.equal(try String(contentsOf: destination, encoding: .utf8), "source")
        let survivors = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let previous = survivors.first { (try? dragDropTestIdentity($0)) == destinationIdentity }
        t.check(previous != nil, "the previous destination inode must also survive")
        t.check(message.contains(destination.path), "the source recovery path is reported")
        if let previous {
            t.equal(try String(contentsOf: previous, encoding: .utf8), "destination")
            t.check(message.contains(previous.resolvingSymlinksInPath().path), "the previous destination recovery path is reported")
        }
    }

    t.suite("DragDrop: file operations retain the original backup if the filesystem also refuses recovery") {
        let root = t.temporaryDirectory("dragdrop-recovery-failure")
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try writeDragDropTestFile("source", at: source)
        try writeDragDropTestFile("destination", at: destination)
        let fm = FailingDragDropFileManager()
        fm.failMove = { _, to in to == destination }
        do {
            try DragDropFileOperations.write(from: source, to: destination, folder: root,
                                              mode: .copy, replaceIfExists: true, fileManager: fm)
            t.check(false, "both installation and restoration should fail")
        } catch {
            t.check(error.localizedDescription.contains("Original items retained at:"), "recovery failure identifies preserved data")
        }
        t.equal(try String(contentsOf: source, encoding: .utf8), "source")
        let survivingFiles = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        t.check(survivingFiles.contains { (try? String(contentsOf: $0, encoding: .utf8)) == "destination" },
                "failure must never clean up the only copy of the old destination")
    }
}

private func writeDragDropTestFile(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func dragDropTestIdentity(_ url: URL) throws -> [UInt64] {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let device = attributes[.systemNumber] as? NSNumber,
          let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
    return [device.uint64Value, inode.uint64Value]
}

private func containsDragDropTransaction(in root: URL) -> Bool {
    let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    return items?.contains { ($0 as? URL)?.lastPathComponent.hasPrefix(".Deskset-DragDrop-") == true } ?? false
}

private final class FailingDragDropFileManager: FileManager, @unchecked Sendable {
    var failCopy = false
    var failMove: ((URL, URL) -> Bool)?
    var beforeMove: ((URL, URL) throws -> Void)?
    var afterMove: ((URL, URL) throws -> Void)?

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if failCopy {
            try Data("incomplete".utf8).write(to: dstURL)
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try beforeMove?(srcURL, dstURL)
        if failMove?(srcURL, dstURL) == true { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: srcURL, to: dstURL)
        try afterMove?(srcURL, dstURL)
    }
}
