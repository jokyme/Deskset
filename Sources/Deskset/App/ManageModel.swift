import Foundation
import DesksetCore

/// Data behind the Manage window and the skin menus (kept separate from the views so it can be tested).
enum ManageModel {
    /// Position choices, top layer first (the manual lists "Stay Topmost, Topmost, Normal, Bottom or On Desktop").
    static let positions: [(title: String, value: Int)] = [
        ("Stay Topmost", 2), ("Topmost", 1), ("Normal", 0), ("Bottom", -1), ("On Desktop", -2),
    ]

    /// Transparency percentage shown in the UI (0% = opaque) → AlphaValue 0…255.
    static func alpha(forTransparencyPercent percent: Int) -> Int {
        let p = Double(min(max(percent, 0), 100))
        return Int(((100 - p) / 100 * 255).rounded())
    }

    static func transparencyPercent(forAlpha alpha: Int) -> Int {
        let a = Double(min(max(alpha, 0), 255))
        return Int(((1 - a / 255) * 100).rounded())
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

    /// Files larger than this are not parsed just to show metadata.
    static let maxMetadataFileSize = 8 * 1024 * 1024

    /// `[Metadata]` of a skin file that is not loaded (the section is read from the file itself; @Include files are
    /// not followed, metadata lives in the skin's own file).
    static func readMetadata(_ url: URL) -> [String: String] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= maxMetadataFileSize,
              let text = try? TextDecoding.readFile(at: url) else { return [:] }
        var result: [String: String] = [:]
        for e in IniDocument.parse(text).section(named: "Metadata")?.entries ?? [] where result[e.key] == nil {
            result[e.key] = e.value
        }
        return result
    }

    /// Compatibility notes for a skin that is not loaded: the skin is parsed (not run) with a headless host.
    static func dryRunIssues(config: String, fileURL: URL, skinsDirectory: URL) -> [String] {
        let host = RenderHost()
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: skinsDirectory, system: SystemMonitor.shared,
                        host: host)
        do {
            try skin.load()
        } catch {
            return ["The skin cannot be loaded: \(error)"]
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
