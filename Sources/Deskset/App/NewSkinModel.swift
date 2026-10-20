import Darwin
import Foundation
import DesksetCore

/// Files and templates managed by one New skin window. The tree is independent of loaded-skin discovery.
final class NewSkinModel {
    enum Kind: Equatable { case folder, skin }

    final class Item {
        let id = UUID()
        fileprivate(set) var url: URL
        let kind: Kind
        fileprivate(set) var children: [Item] = []
        fileprivate(set) var isSessionCreated = false

        fileprivate init(url: URL, kind: Kind) {
            self.url = url
            self.kind = kind
        }
    }

    enum TemplateID: Hashable { case standard, named(String) }

    enum Failure: LocalizedError {
        case invalidName(String), collision(String), unsafeItem(String), unavailable, notCreated, defaultTemplate

        var errorDescription: String? {
            switch self {
            case .invalidName(let name): return "Invalid name: \(name)"
            case .collision(let name): return "An item named \(name) already exists."
            case .unsafeItem(let name): return "The item is no longer a regular file or folder: \(name)"
            case .unavailable: return "The selected folder is no longer available."
            case .notCreated: return "Only items created in this New skin window can be renamed or deleted."
            case .defaultTemplate: return "The default template cannot be deleted."
            }
        }
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let type: mode_t
        var isDirectory: Bool { type == S_IFDIR }
        var isFile: Bool { type == S_IFREG }
    }

    private struct Creation {
        let kind: Kind
        let directoryIdentity: Identity?
    }

    let skinsDirectory: URL
    let settingsDirectory: URL
    private let fm = FileManager.default
    private let trash: (URL) throws -> Void
    private let skinsIdentity: Identity
    private var anchor: URL?
    private var anchorIdentity: Identity?
    private var nodes: [String: Item] = [:]
    private var created: [String: Creation] = [:]
    private var directoryIdentities: [String: Identity] = [:]

    init(skinsDirectory: URL, settingsDirectory: URL, initialDirectory: URL? = nil,
         trash: ((URL) throws -> Void)? = nil) throws {
        self.skinsDirectory = try Self.canonicalDirectory(skinsDirectory)
        self.settingsDirectory = try Self.canonicalDirectory(settingsDirectory)
        self.trash = trash ?? { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        guard let identity = try Self.identity(self.skinsDirectory), identity.isDirectory else {
            throw Failure.unavailable
        }
        skinsIdentity = identity
        if let initialDirectory {
            let requested = initialDirectory.standardizedFileURL
            let suppliedRoot = skinsDirectory.standardizedFileURL
            let base = Self.contains(requested.path, in: suppliedRoot.path) ? suppliedRoot : self.skinsDirectory
            guard Self.contains(requested.path, in: base.path) else { throw Failure.unavailable }
            let suffix = requested.path.dropFirst(base.path.count)
            let url = suffix.split(separator: "/").reduce(self.skinsDirectory) {
                $0.appendingPathComponent(String($1), isDirectory: true)
            }
            try requireDirectory(url)
            guard url != self.skinsDirectory else { throw Failure.unavailable }
            anchor = url
            anchorIdentity = try Self.identity(url)
        }
    }

    @discardableResult
    func reload() throws -> [Item] {
        guard let anchor else { nodes.removeAll(); directoryIdentities.removeAll(); return [] }
        try requireAnchor()
        var next: [String: Item] = [:]
        var nextDirectories: [String: Identity] = [:]
        var count = 0
        func scan(_ url: URL, kind: Kind, depth: Int) throws -> Item {
            let node = nodes[url.path].flatMap { $0.kind == kind ? $0 : nil } ?? Item(url: url, kind: kind)
            node.url = url
            node.isSessionCreated = (try? isCreated(url, kind: kind)) == true
            next[url.path] = node
            node.children = []
            if kind == .folder { nextDirectories[url.path] = try Self.identity(url) }
            count += 1
            if kind == .folder, depth < SkinLibrary.maxDepth, count < SkinLibrary.maxFolders {
                for child in try children(url) where count < SkinLibrary.maxFolders {
                    guard let info = try Self.identity(child) else { continue }
                    if info.isDirectory {
                        node.children.append(try scan(child, kind: .folder, depth: depth + 1))
                    } else if info.isFile, child.pathExtension.caseInsensitiveCompare("ini") == .orderedSame {
                        node.children.append(try scan(child, kind: .skin, depth: depth + 1))
                    }
                }
                node.children.sort {
                    if $0.kind != $1.kind { return $0.kind == .folder }
                    return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                }
            }
            return node
        }
        let root = try scan(anchor, kind: .folder, depth: 0)
        nodes = next
        directoryIdentities.merge(nextDirectories) { previous, _ in previous }
        return [root]
    }

    func item(id: UUID) -> Item? { nodes.values.first { $0.id == id } }

    func createRoot(named name: String) throws -> UUID {
        guard anchor == nil else { throw Failure.unavailable }
        try validateName(name)
        try requireDirectory(skinsDirectory)
        try requireAvailable(name, in: skinsDirectory)
        let url = skinsDirectory.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        try rememberCreation(url, kind: .folder)
        anchor = url
        anchorIdentity = try Self.identity(url)
        try reload()
        return try nodeID(url)
    }

    func addFolder(named name: String, in parent: UUID) throws -> UUID {
        try validateName(name)
        let folder = try parentFolder(parent)
        try requireAvailable(name, in: folder)
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try requireDirectory(folder)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        try rememberCreation(url, kind: .folder)
        try reload()
        return try nodeID(url)
    }

    func addSkin(named name: String, in parent: UUID, template: TemplateID) throws -> UUID {
        let filename = try skinName(name)
        let folder = try parentFolder(parent)
        let text = try templateText(template)
        let url = folder.appendingPathComponent(filename)
        try requireDirectory(folder)
        try writeNew(text, to: url)
        try rememberCreation(url, kind: .skin)
        try reload()
        return try nodeID(url)
    }

    var canAddResources: Bool {
        guard let anchor, anchor.deletingLastPathComponent() == skinsDirectory,
              (try? requireAnchor()) != nil else { return false }
        return (try? matching("@Resources", in: anchor))?.isEmpty == true
    }

    func addResources() throws -> UUID {
        guard canAddResources, let anchor else { throw Failure.unavailable }
        return try addFolder(named: "@Resources", in: nodeID(anchor))
    }

    func canRenameOrDelete(item id: UUID) -> Bool {
        guard let item = item(id: id), (try? requireAnchor()) != nil,
              (try? requireDirectory(item.url.deletingLastPathComponent())) != nil else { return false }
        return (try? isCreated(item.url, kind: item.kind)) == true
    }

    func rename(item id: UUID, to name: String) throws {
        let node = try mutableItem(id)
        let filename = node.kind == .skin ? try skinName(name) : name
        try validateName(filename)
        let old = node.url
        let parent = old.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(filename, isDirectory: node.kind == .folder)
        if old.lastPathComponent == filename { return }
        try requireAvailable(filename, in: parent, excluding: old)
        try requireDirectory(parent)
        let before = try requireItem(old, kind: node.kind)
        let staged = temporary(in: parent)
        guard try Self.identity(old) == before else { throw Failure.unavailable }
        try fm.moveItem(at: old, to: staged)
        do {
            try requireAvailable(filename, in: parent)
            try fm.moveItem(at: staged, to: destination)
        } catch {
            do { try fm.moveItem(at: staged, to: old) }
            catch { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staged.path,
                NSLocalizedDescriptionKey: "The rename could not be completed. The original item remains at \(staged.path)."] ) }
            throw error
        }
        moveRecords(from: old, to: destination)
        if anchor == old { anchor = destination }
        try reload()
    }

    func delete(item id: UUID) throws {
        let node = try mutableItem(id)
        let url = node.url
        try requireDirectory(url.deletingLastPathComponent())
        let before = try requireItem(url, kind: node.kind)
        guard try Self.identity(url) == before else { throw Failure.unavailable }
        try trash(url)
        let paths = created.keys.filter { Self.contains($0, in: url.path) }
        for path in paths { created.removeValue(forKey: path) }
        for path in Array(directoryIdentities.keys) where Self.contains(path, in: url.path) {
            directoryIdentities.removeValue(forKey: path)
        }
        if anchor == url { anchor = nil; anchorIdentity = nil }
        try reload()
    }

    func templates() throws -> [String] {
        guard try Self.identity(settingsDirectory) != nil else { return [] }
        try requireSettingsDirectory()
        guard let directory = try templatesDirectory() else { return [] }
        return try children(directory).filter {
            $0.pathExtension.caseInsensitiveCompare("template") == .orderedSame
                && LayoutStore.isValidName($0.deletingPathExtension().lastPathComponent)
                && (try? Self.identity($0))?.isFile == true
        }.map { $0.deletingPathExtension().lastPathComponent }
    }

    func templateURL(_ id: TemplateID) throws -> URL {
        if case .named(let name) = id { try validateName(name); try validateName(name + ".template") }
        try requireSettingsDirectory(create: true)
        switch id {
        case .standard:
            if let existing = try singleMatch("NewSkin.template", in: settingsDirectory) {
                try requireFile(existing)
                return existing
            }
            let url = settingsDirectory.appendingPathComponent("NewSkin.template")
            try writeNew(Self.defaultText, to: url)
            return url
        case .named(let name):
            try validateName(name)
            guard let directory = try templatesDirectory() else { throw Failure.unavailable }
            guard let url = try singleMatch(name + ".template", in: directory) else { throw Failure.unavailable }
            try requireFile(url)
            return url
        }
    }

    func templateText(_ id: TemplateID) throws -> String {
        try TextDecoding.readFile(at: templateURL(id))
    }

    func saveTemplate(named name: String, from source: TemplateID) throws -> TemplateID {
        try validateName(name)
        try validateName(name + ".template")
        let text = try templateText(source)
        try requireSettingsDirectory(create: true)
        guard let directory = try templatesDirectory(create: true) else { throw Failure.unavailable }
        try writeNew(text, to: directory.appendingPathComponent(name + ".template"))
        return .named(name)
    }

    func deleteTemplate(_ id: TemplateID) throws {
        guard case .named = id else { throw Failure.defaultTemplate }
        let url = try templateURL(id)
        let before = try Self.identity(url)
        try requireSettingsDirectory()
        try requireFolder(url.deletingLastPathComponent())
        guard try Self.identity(url) == before else { throw Failure.unavailable }
        try trash(url)
    }

    private static let defaultText = "[Rainmeter]\r\nUpdate=1000\r\n\r\n[Metadata]\r\nName=\r\nAuthor=\r\nInformation=\r\nLicense=\r\nVersion=\r\n\r\n[Variables]\r\n"

    private func mutableItem(_ id: UUID) throws -> Item {
        try requireAnchor()
        guard let node = item(id: id), try isCreated(node.url, kind: node.kind) else { throw Failure.notCreated }
        return node
    }

    private func parentFolder(_ id: UUID) throws -> URL {
        try requireAnchor()
        guard let node = item(id: id), node.kind == .folder else { throw Failure.unavailable }
        try requireDirectory(node.url)
        guard try Self.identity(node.url) == directoryIdentities[node.url.path] else { throw Failure.unavailable }
        return node.url
    }

    private func nodeID(_ url: URL) throws -> UUID {
        guard let id = nodes[url.path]?.id else { throw Failure.unavailable }
        return id
    }

    private func rememberCreation(_ url: URL, kind: Kind) throws {
        try requireDirectory(url.deletingLastPathComponent())
        guard let identity = try Self.identity(url), kind == .folder ? identity.isDirectory : identity.isFile else {
            throw Failure.unsafeItem(url.lastPathComponent)
        }
        if kind == .folder {
            for path in Array(created.keys) where Self.contains(path, in: url.path) { created.removeValue(forKey: path) }
            for path in Array(nodes.keys) where Self.contains(path, in: url.path) { nodes.removeValue(forKey: path) }
            for path in Array(directoryIdentities.keys) where Self.contains(path, in: url.path) {
                directoryIdentities.removeValue(forKey: path)
            }
            directoryIdentities[url.path] = identity
        }
        created[url.path] = Creation(kind: kind, directoryIdentity: kind == .folder ? identity : nil)
    }

    private func isCreated(_ url: URL, kind: Kind) throws -> Bool {
        try requireDirectory(url.deletingLastPathComponent())
        guard let record = created[url.path], record.kind == kind,
              let current = try Self.identity(url), kind == .folder ? current.isDirectory : current.isFile else { return false }
        return record.directoryIdentity.map { $0 == current } ?? true
    }

    private func moveRecords(from old: URL, to new: URL) {
        let prefix = old.path
        for path in Array(created.keys) where Self.contains(path, in: prefix) {
            guard let record = created.removeValue(forKey: path) else { continue }
            created[new.path + String(path.dropFirst(prefix.count))] = record
        }
        for path in Array(nodes.keys) where Self.contains(path, in: prefix) {
            guard let node = nodes.removeValue(forKey: path) else { continue }
            let newPath = new.path + String(path.dropFirst(prefix.count))
            node.url = URL(fileURLWithPath: newPath, isDirectory: node.kind == .folder)
            nodes[newPath] = node
        }
        for path in Array(directoryIdentities.keys) where Self.contains(path, in: prefix) {
            guard let identity = directoryIdentities.removeValue(forKey: path) else { continue }
            directoryIdentities[new.path + String(path.dropFirst(prefix.count))] = identity
        }
    }

    private func requireAnchor() throws {
        guard let anchor else { throw Failure.unavailable }
        try requireDirectory(anchor)
        guard try Self.identity(anchor) == anchorIdentity else { throw Failure.unavailable }
    }

    private func requireDirectory(_ url: URL) throws {
        guard Self.contains(url.path, in: skinsDirectory.path), try Self.identity(skinsDirectory) == skinsIdentity else {
            throw Failure.unavailable
        }
        try requireFolder(skinsDirectory)
        let relative = url.path.dropFirst(skinsDirectory.path.count)
        var next = skinsDirectory
        for part in relative.split(separator: "/") {
            next.appendPathComponent(String(part), isDirectory: true)
            try requireFolder(next)
            if let expected = directoryIdentities[next.path], try Self.identity(next) != expected {
                throw Failure.unavailable
            }
            if let expected = created[next.path]?.directoryIdentity, try Self.identity(next) != expected {
                throw Failure.unavailable
            }
        }
    }

    @discardableResult
    private func requireItem(_ url: URL, kind: Kind) throws -> Identity {
        try requireDirectory(url.deletingLastPathComponent())
        guard let info = try Self.identity(url), kind == .folder ? info.isDirectory : info.isFile else {
            throw Failure.unsafeItem(url.lastPathComponent)
        }
        if let expected = created[url.path]?.directoryIdentity, expected != info { throw Failure.unavailable }
        return info
    }

    private func requireSettingsDirectory(create: Bool = false) throws {
        var next = URL(fileURLWithPath: "/", isDirectory: true)
        for component in settingsDirectory.pathComponents.dropFirst() {
            next.appendPathComponent(component, isDirectory: true)
            if try Self.identity(next) == nil, create {
                try fm.createDirectory(at: next, withIntermediateDirectories: false)
            }
            try requireFolder(next)
        }
    }

    private func templatesDirectory(create: Bool = false) throws -> URL? {
        try requireSettingsDirectory(create: create)
        if let existing = try singleMatch("Templates", in: settingsDirectory) {
            try requireFolder(existing)
            return existing
        }
        guard create else { return nil }
        let url = settingsDirectory.appendingPathComponent("Templates", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func requireFolder(_ url: URL) throws {
        guard try Self.identity(url)?.isDirectory == true else { throw Failure.unsafeItem(url.lastPathComponent) }
    }

    private func requireFile(_ url: URL) throws {
        guard try Self.identity(url)?.isFile == true else { throw Failure.unsafeItem(url.lastPathComponent) }
    }

    private func validateName(_ name: String) throws {
        guard LayoutStore.isValidName(name) else { throw Failure.invalidName(name) }
    }

    private func skinName(_ name: String) throws -> String {
        try validateName(name)
        let filename = name.lowercased().hasSuffix(".ini") ? name : name + ".ini"
        try validateName(filename)
        guard filename.count > 4 else { throw Failure.invalidName(name) }
        return filename
    }

    private func matching(_ name: String, in parent: URL) throws -> [URL] {
        try children(parent).filter { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func singleMatch(_ name: String, in parent: URL) throws -> URL? {
        let matches = try matching(name, in: parent)
        guard matches.count <= 1 else { throw Failure.collision(name) }
        return matches.first
    }

    private func requireAvailable(_ name: String, in parent: URL, excluding: URL? = nil) throws {
        guard try matching(name, in: parent).allSatisfy({ $0.path == excluding?.path }) else { throw Failure.collision(name) }
    }

    private func children(_ url: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func temporary(in parent: URL) -> URL {
        parent.appendingPathComponent(".deskset-new-skin-\(UUID().uuidString)")
    }

    private func writeNew(_ text: String, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try requireWriteParent(parent)
        try requireAvailable(destination.lastPathComponent, in: parent)
        let stagingDirectory = temporary(in: parent)
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stagingDirectory) }
        let staged = stagingDirectory.appendingPathComponent("contents")
        let data = TextDecoding.encodeForWriting(text, preferring: .utf16LittleEndian(bom: true))
        try data.write(to: staged, options: .withoutOverwriting)
        try requireWriteParent(parent)
        try requireAvailable(destination.lastPathComponent, in: parent)
        try fm.moveItem(at: staged, to: destination)
    }

    private func requireWriteParent(_ url: URL) throws {
        if Self.contains(url.path, in: skinsDirectory.path) {
            try requireDirectory(url)
        } else if Self.contains(url.path, in: settingsDirectory.path) {
            try requireSettingsDirectory()
            var next = settingsDirectory
            for component in url.path.dropFirst(settingsDirectory.path.count).split(separator: "/") {
                next.appendPathComponent(String(component), isDirectory: true)
                try requireFolder(next)
            }
        } else {
            throw Failure.unavailable
        }
    }

    private static func contains(_ path: String, in parent: String) -> Bool {
        path == parent || path.hasPrefix(parent + "/")
    }

    /// Resolve the existing ancestor first: resolving a complete URL whose last folder is missing may leave
    /// macOS aliases such as /var unresolved. Newly created descendants are still checked without following links.
    private static func canonicalDirectory(_ url: URL) throws -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while try identity(existing) == nil, existing.path != "/" {
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        guard let path = realpath(existing.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(path) }
        return missing.reversed().reduce(URL(fileURLWithPath: String(cString: path), isDirectory: true)) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
    }

    private static func identity(_ url: URL) throws -> Identity? {
        var value = stat()
        if lstat(url.path, &value) == 0 {
            return Identity(device: value.st_dev, inode: value.st_ino, type: value.st_mode & S_IFMT)
        }
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
