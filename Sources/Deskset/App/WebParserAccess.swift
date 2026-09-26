import Foundation
import DesksetCore

/// Which local files a WebParser measure may read with `URL=file://…`. The manual allows any fully qualified path,
/// but a skin that reads private files could send their contents elsewhere in the URL of another WebParser, so the
/// app allows only files inside the Skins folder of the skin and the app's settings folder (`#SETTINGSPATH#`).
/// A refused file behaves like a missing one; each refused path is logged once.
///
/// The check runs on the thread of the skin that asks, so skins on different threads use it at once: the set of
/// refusals already logged is behind a lock.
enum WebParserAccess {
    private static let loggedRefusals = Guarded<Set<String>>([])

    /// Installs the policy (at launch).
    static func install(settingsFolder: URL) {
        WebParserMeasure.allowsFileAccess = { path, skin in
            let allowed = isAllowed(path, roots: [skin.skinsDirectory, settingsFolder])
            if !allowed, isFirstRefusal(path) {
                Log.write("WebParser: reading \(path) is not allowed (only files in the Skins and settings folders)",
                          level: .warning, source: skin.config)
            }
            return allowed
        }
    }

    /// Whether `path` has not been refused before (the first 256 refused paths are remembered, so a skin that tries
    /// ever new paths cannot fill the log).
    static func isFirstRefusal(_ path: String) -> Bool {
        loggedRefusals.access { $0.count < 256 && $0.insert(path).inserted }
    }

    /// True when `path` (absolute) is inside one of `roots`, resolved the way the file system opens it: symbolic
    /// links followed and `..` taken physically (a link inside the Skins folder pointing elsewhere, or `Link/..`,
    /// does not count as inside).
    static func isAllowed(_ path: String, roots: [URL]) -> Bool {
        guard path.hasPrefix("/") else { return false }
        func isInside(_ components: [String], _ base: [String]) -> Bool {
            base.count > 1 && components.count > base.count && Array(components.prefix(base.count)) == base
        }
        // First, without touching the file system: a path that is not even written inside a root is refused before
        // `realpath` could wait for an unreachable network volume (`file:///Volumes/Server/…`) on the main thread.
        let written = lexicalComponents(path)
        let plausible = roots.contains { root in
            var forms = [lexicalComponents(root.path), lexicalComponents((root.path as NSString).standardizingPath)]
            if let real = physicalComponents(root.path) { forms.append(real) }
            return forms.contains { isInside(written, $0) }
        }
        guard plausible, let target = physicalComponents(path) else { return false }
        return roots.contains { root in
            guard let base = physicalComponents(root.path) else { return false }
            return isInside(target, base)
        }
    }

    /// Components of `path` as written: `.` and empty names dropped, `..` removing the name before it (no links
    /// followed, nothing read from the disk).
    static func lexicalComponents(_ path: String) -> [String] {
        var result: [String] = []
        for part in (path as NSString).pathComponents {
            switch part {
            case ".", "": continue
            case "..": if result.count > 1 { result.removeLast() }
            default: result.append(part)
            }
        }
        return result
    }

    /// Components of the path the kernel would open: `realpath` of the longest leading part that exists, then the
    /// remaining names (which do not exist, so they hold no links). nil when a missing folder is followed by `..`
    /// (such a path cannot be opened).
    static func physicalComponents(_ path: String) -> [String]? {
        let parts = (path as NSString).pathComponents
        var count = parts.count
        while count >= 1 {
            let prefix = NSString.path(withComponents: Array(parts.prefix(count)))
            if let real = realpath(prefix, nil) {
                let resolved = String(cString: real)
                free(real)
                var result = (resolved as NSString).pathComponents
                for part in parts.dropFirst(count) where part != "." && !part.isEmpty {
                    if part == ".." { return nil }
                    result.append(part)
                }
                return result
            }
            count -= 1
        }
        return nil
    }
}
