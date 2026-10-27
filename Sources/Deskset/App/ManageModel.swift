import Foundation
import DesksetCore

/// Data behind the Manage window and the skin menus (kept separate from the views so it can be tested).
enum ManageModel {
    /// Position choices, top layer first (the manual lists "Stay Topmost, Topmost, Normal, Bottom or On Desktop").
    static var positions: [(title: String, value: Int)] {
        [(L("Stay Topmost"), 2), (L("Topmost"), 1), (L("Normal"), 0), (L("Bottom"), -1), (L("On Desktop"), -2)]
    }

    /// Transparency percentage shown in the UI (0% = opaque) → AlphaValue 0…255.
    static func alpha(forTransparencyPercent percent: Int) -> Int {
        let p = Double(min(max(percent, 0), 100))
        return Int(((100 - p) / 100 * 255).rounded())
    }

    static func transparencyPercent(forAlpha alpha: Int) -> Int {
        let a = Double(min(max(alpha, 0), 255))
        return Int(((1 - a / 255) * 100).rounded())
    }

    static let transparencyChoices: [(title: String, alpha: Int)] =
        stride(from: 0, through: 90, by: 10).map {
            (title: "\($0)%", alpha: alpha(forTransparencyPercent: $0))
        } + [(title: "~100%", alpha: 1)]

    static func transparencyChoiceIndex(forAlpha alpha: Int) -> Int? {
        if alpha == 1 { return transparencyChoices.count - 1 }
        let percent = transparencyPercent(forAlpha: alpha)
        return transparencyChoices.dropLast().firstIndex { transparencyPercent(forAlpha: $0.alpha) == percent }
    }

    /// A `[Metadata]` value by key (case-insensitive), trimmed; nil when missing or empty.
    static func metadataValue(_ metadata: [String: String], _ key: String) -> String? {
        let value = metadata[key] ?? metadata.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        let trimmed = value.map { $0.trimmingCharacters(in: .whitespaces) }
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// `Information`: "The pipe character (|) functions as a line break".
    static func informationText(_ raw: String) -> String {
        raw.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    /// What the details say about a loaded skin that is off the desktop because a skin action (`!Hide`, `!HideFade`,
    /// a widget's own "hide when idle") or StartHidden hid it: moving it or changing its settings does not bring it
    /// back, only a show does (the notice's Show button, `!Show`).
    enum Hidden {
        static var status: String { "● " + L("Loaded, hidden") }
        static var title: String { L("Hidden by the skin") }
        static var showTitle: String { L("Show") }

        /// The notice's text. `startHidden`: the skin's settings say StartHidden, so it may never have been shown.
        static func explanation(startHidden: Bool) -> String {
            let why = startHidden
                ? L("It is set to start hidden (StartHidden), or a skin action (!Hide) took it off the desktop.")
                : L("It is loaded and running, but a skin action (!Hide) took it off the desktop, as some widgets do while they have nothing to show.")
            let after = startHidden ? L("Moving it does not bring it back; Show does, until it is loaded again.")
                : L("Moving it does not bring it back; Show does, until the skin hides itself again.")
            return why + " " + after
        }

        /// Under the coordinates of a hidden skin; `moved`: coordinates were just typed for it.
        static func coordinatesHint(moved: Bool) -> String {
            moved ? L("Moved, but still hidden: click Show above to see it.")
                : L("The skin is hidden: it moves, but stays out of sight.")
        }

        /// The outline row's accessibility label of a loaded file.
        static func accessibilityLabel(name: String, loaded: Bool, hidden: Bool) -> String {
            loaded ? (hidden ? L("%@, loaded, hidden", name) : L("%@, loaded", name)) : name
        }
    }

    /// Files larger than this are not parsed just to show metadata.
    static let maxMetadataFileSize = 8 * 1024 * 1024

    /// Whether the skin file at `url` defines a `[Metadata]` section (any case, even when empty). Returns `nil` when
    /// the file does not exist, is not a regular file, exceeds `maxMetadataFileSize`, or cannot be read.
    static func hasMetadataSection(_ url: URL) -> Bool? {
        guard let text = readMetadataText(url) else { return nil }
        return IniWriter.definesSection(text, section: "Metadata")
    }

    /// `[Metadata]` of a skin file that is not loaded (the section is read from the file itself; @Include files are
    /// not followed, metadata lives in the skin's own file).
    static func readMetadata(_ url: URL) -> [String: String] {
        guard let text = readMetadataText(url) else { return [:] }
        var result: [String: String] = [:]
        for e in IniDocument.parse(text).section(named: "Metadata")?.entries ?? [] where result[e.key] == nil {
            result[e.key] = e.value
        }
        return result
    }

    private static func readMetadataText(_ url: URL) -> String? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = attrs[.size] as? Int,
              size <= maxMetadataFileSize,
              let text = try? TextDecoding.readFile(at: target) else { return nil }
        return text
    }

    /// Compatibility notes for a skin that is not loaded: the skin is parsed (not run) with a headless host.
    static func dryRunIssues(config: String, fileURL: URL, skinsDirectory: URL) -> [String] {
        let host = RenderHost()
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: skinsDirectory, system: SystemMonitor.shared,
                        host: host)
        do {
            try skin.load()
        } catch {
            return [L("The skin cannot be loaded: %@", "\(error)")]
        }
        return withExtendedLifetime(host) { skin.issues }
    }

    // MARK: Tree

    /// Outline item: a folder under Skins (a config when it holds .ini files) or one .ini file.
    final class Node {
        enum Kind { case folder, file }
        let kind: Kind
        let name: String
        /// Folder path with `\` separators (for files: the config).
        let path: String
        /// The config this folder is, or the file belongs to.
        var config: SkinConfig?
        let file: String?
        var children: [Node] = []

        init(kind: Kind, name: String, path: String, config: SkinConfig?, file: String?) {
            self.kind = kind
            self.name = name
            self.path = path
            self.config = config
            self.file = file
        }
    }

    /// Folders (sub-folders first, then .ini files), root configs at the top level.
    static func tree(_ library: [SkinConfig]) -> [Node] {
        var roots: [Node] = []
        var folders: [String: Node] = [:]
        func folder(_ components: [String]) -> Node {
            let path = components.joined(separator: "\\")
            if let existing = folders[path.lowercased()] { return existing }
            let node = Node(kind: .folder, name: components.last ?? path, path: path, config: nil, file: nil)
            folders[path.lowercased()] = node
            if components.count == 1 {
                roots.append(node)
            } else {
                folder(Array(components.dropLast())).children.append(node)
            }
            return node
        }
        for config in library {
            let components = config.name.split(separator: "\\").map(String.init)
            guard !components.isEmpty else { continue }
            let node = folder(components)
            node.config = config
            for file in config.files {
                node.children.append(Node(kind: .file, name: file, path: config.name, config: config, file: file))
            }
        }
        func sort(_ nodes: inout [Node]) {
            nodes.sort { a, b in
                if a.kind != b.kind { return a.kind == .folder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            for n in nodes { sort(&n.children) }
        }
        sort(&roots)
        return roots
    }
}
