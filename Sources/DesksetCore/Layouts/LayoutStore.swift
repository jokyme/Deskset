import Foundation

/// A Rainmeter layout is Rainmeter.ini and, optionally, Wallpaper.bmp. It does not contain skin files.
/// Public contract: https://docs.rainmeter.net/manual/user-interface/manage/#LayoutsTab
public struct LayoutDocument: Equatable {
    public var ini: IniDocument
    public var wallpaper: Data?

    public init(ini: IniDocument, wallpaper: Data? = nil) {
        self.ini = ini
        self.wallpaper = wallpaper
    }
}

public enum LayoutStoreError: Error, LocalizedError, CustomStringConvertible {
    case invalidName(String)
    case notFound(String)
    case unsafeItem(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidName(let name): return "Invalid layout name: \(name)"
        case .notFound(let name): return "Layout not found: \(name)"
        case .unsafeItem(let path): return "Layout item is not a regular file or directory: \(path)"
        }
    }
}

/// File operations for the standard Layouts/<name>/Rainmeter.ini format. All lookups are case-insensitive.
/// A replacement is staged beside the destination; a failed rename restores the previous directory.
public struct LayoutStore {
    public let directory: URL
    private let trash: (URL) throws -> Void

    public init(directory: URL, trash: @escaping (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) {
        self.directory = directory
        self.trash = trash
    }

    public func list() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try children(directory).filter { url in
            Self.isValidName(url.lastPathComponent) && itemType(url) == .typeDirectory
        }.map(\.lastPathComponent)
    }

    /// An existing destination needs replacement confirmation even when its INI is missing or unreadable.
    public func contains(named name: String) -> Bool { (try? layoutDirectory(named: name)) != nil }

    public func iniURL(named name: String) throws -> URL {
        let folder = try layoutDirectory(named: name)
        guard let file = try child("Rainmeter.ini", in: folder) else { throw LayoutStoreError.notFound(name) }
        try require(file, type: .typeRegular)
        return file
    }

    public func read(named name: String, includeWallpaper: Bool = true) throws -> LayoutDocument {
        let file = try iniURL(named: name)
        let text = try TextDecoding.readFile(at: file)
        var wallpaper: Data?
        if includeWallpaper, let image = try child("Wallpaper.bmp", in: file.deletingLastPathComponent()) {
            try require(image, type: .typeRegular)
            wallpaper = try Data(contentsOf: image)
        }
        // Empty and imperfect INI files use the same tolerant reader as Rainmeter skin settings.
        return LayoutDocument(ini: IniDocument.parse(text), wallpaper: wallpaper)
    }

    public func save(_ document: LayoutDocument, named name: String) throws {
        try validate(name)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try child(name, in: directory)
        if let existing { try require(existing, type: .typeDirectory) }
        let destination = existing ?? directory.appendingPathComponent(name, isDirectory: true)
        let transactionDirectory = directory.deletingLastPathComponent()
        let staging = transactionDirectory.appendingPathComponent(".deskset-layout-new-\(UUID().uuidString)", isDirectory: true)
        let previous = transactionDirectory.appendingPathComponent(".deskset-layout-old-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        if let existing { try copyContents(of: existing, to: staging) }
        let text = try Self.serialize(document.ini)
        let encoded = text.isEmpty ? Data() : TextDecoding.encodeForWriting(text, preferring: .utf16LittleEndian(bom: true))
        let ini = try child("Rainmeter.ini", in: staging) ?? staging.appendingPathComponent("Rainmeter.ini")
        if itemType(ini) != nil { try require(ini, type: .typeRegular) }
        try encoded.write(to: ini, options: .atomic)
        if let wallpaper = document.wallpaper {
            let image = try child("Wallpaper.bmp", in: staging) ?? staging.appendingPathComponent("Wallpaper.bmp")
            if itemType(image) != nil { try require(image, type: .typeRegular) }
            try wallpaper.write(to: image, options: .atomic)
        }
        if let existing { try fm.moveItem(at: existing, to: previous) }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            if existing != nil { try? fm.moveItem(at: previous, to: destination) }
            throw error
        }
        if existing != nil { try? fm.removeItem(at: previous) }
    }

    public func delete(named name: String) throws {
        try trash(layoutDirectory(named: name))
    }

    /// Windows single-directory names; rejecting path syntax also prevents escaping the layout root on macOS.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.utf16.count <= 255,
              name.last != " ", name.last != ".",
              !name.unicodeScalars.contains(where: { $0.value < 32 || "<>:\"/\\|?*".unicodeScalars.contains($0) })
        else { return false }
        let stem = name.split(separator: ".", omittingEmptySubsequences: false)[0].uppercased()
        let devices = ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7",
                       "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]
        return !devices.contains(stem)
    }

    private func validate(_ name: String) throws {
        guard Self.isValidName(name) else { throw LayoutStoreError.invalidName(name) }
    }

    private func layoutDirectory(named name: String) throws -> URL {
        try validate(name)
        guard FileManager.default.fileExists(atPath: directory.path), let folder = try child(name, in: directory)
        else { throw LayoutStoreError.notFound(name) }
        try require(folder, type: .typeDirectory)
        return folder
    }

    private func itemType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
    }

    private func require(_ url: URL, type: FileAttributeType) throws {
        guard itemType(url) == type else { throw LayoutStoreError.unsafeItem(url.path) }
    }

    /// Keep unrelated saved files and an omitted wallpaper without following links into another directory.
    private func copyContents(of source: URL, to destination: URL) throws {
        let fm = FileManager.default
        for item in try children(source) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            switch itemType(item) {
            case .typeDirectory:
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
                try copyContents(of: item, to: target)
            case .typeRegular:
                try fm.copyItem(at: item, to: target)
                try require(target, type: .typeRegular)
            default:
                throw LayoutStoreError.unsafeItem(item.path)
            }
        }
    }

    private func children(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { a, b in
                let result = a.lastPathComponent.caseInsensitiveCompare(b.lastPathComponent)
                return result == .orderedSame ? a.lastPathComponent < b.lastPathComponent : result == .orderedAscending
            }
    }

    private func child(_ name: String, in folder: URL) throws -> URL? {
        let matches = try children(folder).filter { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
        return matches.first { $0.lastPathComponent == name } ?? matches.first
    }

    private static func serialize(_ document: IniDocument) throws -> String {
        var sections: [String] = []
        for section in document.sections {
            // Reuse the INI writer's validation, quoting and line-break handling instead of defining another dialect.
            var text = ""
            for entry in section.entries {
                // Parsed values may contain literal outer quotes; protect them from the next read's unquoting.
                let value = Substring(entry.value)
                let writtenValue = IniSyntax.unquote(value) == value ? entry.value : "\"" + entry.value + "\""
                text = try IniWriter.updating(text, value: writtenValue, key: entry.key, section: section.name)
            }
            if text.isEmpty {
                _ = try IniWriter.updating("", value: "", key: "_", section: section.name)
                text = "[\(section.name)]\r\n"
            }
            sections.append(text)
        }
        return sections.joined(separator: "\r\n")
    }
}
