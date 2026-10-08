import Foundation
import Darwin
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Installed packages are read and qualified on a file worker. Main receives only immutable inputs and an
/// exclusive private image collection; constructing the window does not reread the captured package.
enum DeskWidgetActivation {
    enum Failure: Error, Equatable {
        case cancelled, invalidEntry, invalidPackage, compileFailed
        case resources(String)
    }

    struct SourceKey: Equatable, Sendable {
        let sourceID: UUID
        let packageID: UUID?
        let entry: String

        init(_ source: DeskWidgetSourceState) {
            sourceID = source.id; packageID = source.packageID; entry = source.entry
        }

        func matches(_ source: DeskWidgetSourceState) -> Bool {
            sourceID == source.id && packageID == source.packageID && DeskPackagePath.sameBytes(entry, source.entry)
        }

        var directoryID: UUID { packageID ?? sourceID }
    }

    final class Ticket {
        private let cancelled = Guarded(false)
        var isCancelled: Bool { cancelled.current }
        func cancel() { cancelled.access { $0 = true } }
    }

    struct Prepared: Sendable {
        let source: SourceKey
        let directory: URL
        let directoryIdentity: DeskPackageCapture.Identity
        let program: WidgetProgram
        let resources: DeskProgramResources.Prepared
    }

    typealias Preparation = (SourceKey, URL, DeskServiceOptions, Ticket) throws -> Prepared

    static func prepare(source: SourceKey, widgetsRoot: URL, options: DeskServiceOptions,
                        isCancelled: () -> Bool = { false }, hooks: DeskPackageCapture.Hooks = .init()) throws -> Prepared {
        precondition(!Thread.isMainThread, "Package activation preparation belongs on a file worker")
        func checkCancellation() throws { if isCancelled() { throw Failure.cancelled } }
        try checkCancellation()
        guard source.packageID != nil, !source.entry.contains("\0"),
              let parts = DeskPackagePath.safeComponents(source.entry), parts.count == 2,
              DeskPackagePath.sameBytes(parts.joined(separator: "/"), source.entry),
              parts[0] == source.directoryID.uuidString.lowercased(),
              DeskPackagePath.isDeskFile(parts[1]), !DeskPackagePath.isPackageFile(parts[1]),
              !DeskPackagePath.isIgnoredName(parts[1]) else { throw Failure.invalidEntry }
        let directory = widgetsRoot.appendingPathComponent(parts[0], isDirectory: true)
        let capture = try DeskPackageCapture.read(root: directory, limits: options.catalog.limits,
                                                  isCancelled: isCancelled, hooks: hooks)
        try checkCancellation()
        let package = try PackageLoader.load(capture.source, limits: options.catalog.limits)
        let selected = DeskFileID(path: parts[1])
        guard package.widgetFiles.contains(selected), package.texts[selected] != nil else { throw Failure.invalidPackage }
        let service = DeskLanguageService(package: package, openFile: selected, options: options)
        let checked = service.snapshot.packageCheck()
        guard !checked.allDiagnostics.contains(where: { $0.severity == .error }),
              checked.widgetFiles == package.widgetFiles,
              package.packageFile == nil || checked.checkedPackage != nil else { throw Failure.invalidPackage }

        var selectedProgram: WidgetProgram?
        var imageSources: [String] = []
        for file in checked.widgetFiles {
            try checkCancellation()
            guard let member = checked.files[file] else { throw Failure.invalidPackage }
            let result = Desk.compile(member, catalog: options.catalog, package: checked.checkedPackage)
            guard result.issues.isEmpty, let program = result.program else { throw Failure.compileFailed }
            if file == selected { selectedProgram = program; imageSources = result.imageSources }
        }
        try checkCancellation()
        guard let program = selectedProgram else { throw Failure.invalidPackage }
        let language: StudioLanguage = options.messageLanguage == .simplifiedChinese ? .chinese : .english
        let resources = DeskProgramResources.prepare(capture: capture, literals: imageSources, language: language)
        var transferred = false
        defer { if !transferred { resources.removeCopies() } }
        try checkCancellation()
        if let failure = resources.failure { throw Failure.resources(failure) }
        // Loader metadata, checks and image bytes all came from this capture. Do not append prepared.files to the
        // complete inventory or reparse only package.desk and pair its new NodeIDs with older widget receipts.
        try capture.validateUnchanged(isCancelled: isCancelled, hooks: hooks)
        guard resources.images.values.allSatisfy({ Images.imageStamp(atPath: $0.path) == $0.stamp }) else {
            throw Failure.invalidPackage
        }
        try checkCancellation()
        transferred = true
        return Prepared(source: source, directory: capture.root, directoryIdentity: capture.rootIdentity,
                        program: program, resources: resources)
    }

    /// A cheap named-directory identity check at handoff, not another whole-tree freshness scan. Later source
    /// edits cannot change the accepted immutable program or its private pictures; a reload captures them anew.
    static func matchesInstalledRoot(_ prepared: Prepared, widgetsRoot: URL) -> Bool {
        let root = open(widgetsRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { return false }
        defer { Darwin.close(root) }
        let directory = openat(root, prepared.source.directoryID.uuidString.lowercased(),
                               O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { return false }
        defer { Darwin.close(directory) }
        var info = stat()
        return fstat(directory, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
            Int32(info.st_dev) == prepared.directoryIdentity.device && UInt64(info.st_ino) == prepared.directoryIdentity.inode
    }
}
