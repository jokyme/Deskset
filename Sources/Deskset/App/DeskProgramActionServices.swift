import AppKit
import DesksetCore

/// Main's two user-initiated Desk services. Tests replace every external operation with a recorder.
struct DeskProgramActionServices {
    let resolver: DeskProgramOpenResolver
    let copy: (String) -> Bool
    let open: (URL) -> Bool

    static let live = DeskProgramActionServices(resolver: .live, copy: { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }, open: { NSWorkspace.shared.open($0) })

    /// A failed operation does not stop later requests in the already-resolved, ordered action list.
    func perform(_ effect: ProgramEffect, directory: URL) -> String? {
        precondition(Thread.isMainThread)
        switch effect {
        case .copy(let text):
            return copy(text) ? nil : StudioText[.deskActionCopyFailed]
        case .open(let target):
            guard let url = resolver.resolve(target, directory: directory), open(url) else {
                return String(format: StudioText[.deskActionOpenFailed], target)
            }
            return nil
        }
    }
}

/// Opens the catalog's URL, file/folder, bundle-ID and application-name targets without a shell or Skin.
/// The application directories follow StudioWords.appName; lookup and existence checks are injectable.
struct DeskProgramOpenResolver {
    let application: (String) -> URL?
    let applicationNamed: (String) -> URL?
    let exists: (URL) -> Bool

    static let live = DeskProgramOpenResolver(application: { bundleID in
        WorkspaceApplicationLocator().applicationURL(bundleID: bundleID)
    }, applicationNamed: { name in
        let folders = ["/System/Applications", "/System/Applications/Utilities", "/Applications", "/Applications/Utilities"]
        let file = name.hasSuffix(".app") ? name : name + ".app"
        return folders.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(file) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }, exists: { FileManager.default.fileExists(atPath: $0.path) })

    func resolve(_ raw: String, directory: URL) -> URL? {
        precondition(Thread.isMainThread)
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.contains("\0") else { return nil }
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1 {
            if url.isFileURL { return exists(url) ? url : nil }
            // A malformed web address is not handed to Launch Services as a valid user target.
            if ["http", "https"].contains(scheme.lowercased()) {
                guard let host = url.host, !host.isEmpty else { return nil }
            }
            return url
        }
        let expanded = (target as NSString).expandingTildeInPath
        let file = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : directory.appendingPathComponent(expanded)
        if exists(file) { return file.standardizedFileURL }
        // A path that does not exist must not accidentally turn into an application name.
        guard !target.contains("/"), !target.hasPrefix(".") else { return nil }
        return application(target) ?? applicationNamed(target)
    }
}

/// Captured by Main from its accepted picture before the owner receives the release.
struct DeskWidgetClickToken: Equatable, Sendable {
    let session: UUID
    let epoch: UInt64
    let sourceGeneration: UInt64
    let serial: UInt64
}
