import Foundation

// Loading a widget folder (§8.3, §8.4): walk it without following links, skip hidden files, `.DS_Store` and
// `__MACOSX`, stop past 2,000 files, note when the files add up to more than 100 MiB, read each `.desk` of at most
// 1 MiB through `Desk.load` (UTF-8, a byte order mark kept), read picture sizes from their headers and font
// families through the injected service. Nothing is decoded beyond a header, and nothing is followed.

/// The families of a font file, read by the App (Core Text). Without it, font files are listed without families
/// and the checks that need them are skipped.
public protocol FontFileInspecting: Sendable {
    /// The families the font file holds; nil when it is not a font this Mac can read.
    func families(inFontData data: Data, fileName: String) -> [String]?
}

/// An entry of an archive's list, before anything is unpacked.
public struct DeskArchiveEntry: Sendable, Hashable {
    public var path: String
    /// Unpacked bytes.
    public var size: Int
    public var isDirectory: Bool
    /// Where a link entry points; nil for files and folders.
    public var linkDestination: String?

    public init(path: String, size: Int, isDirectory: Bool = false, linkDestination: String? = nil) {
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.linkDestination = linkDestination
    }
}

public enum PackageLoader {
    /// Largest font file whose families are read.
    static let maximumFontBytes = 32 * 1_048_576
    /// How much of a picture is read to find its size.
    static let imageHeaderBytes = 1_048_576

    /// A folder on disk. Throws only when the folder itself cannot be listed.
    public static func load(folder: URL, fonts: FontFileInspecting? = nil,
                            limits: CatalogLimits = DeskCatalog.current.limits) throws -> DeskPackage {
        try load(LocalPackageSource(root: folder), fonts: fonts, limits: limits)
    }

    /// A single `.desk` file (a widget shared on its own): nothing else of its folder is read.
    public static func load(deskFile: URL, limits: CatalogLimits = DeskCatalog.current.limits) throws -> DeskPackage {
        let name = deskFile.lastPathComponent
        let source = LocalPackageSource(root: deskFile.deletingLastPathComponent())
        let attributes = try FileManager.default.attributesOfItem(atPath: deskFile.path)
        if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: deskFile.path)) ?? ""
            return singleFile(name: name, size: destination.utf8.count, link: destination, data: nil, limits: limits)
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let data = size > limits.maximumFileBytes ? nil : try source.read(name, limit: limits.maximumFileBytes + 1)
        return singleFile(name: name, size: size, link: nil, data: data, limits: limits)
    }

    /// A single `.desk` file's bytes.
    public static func load(deskData data: Data, fileName: String,
                            limits: CatalogLimits = DeskCatalog.current.limits) -> DeskPackage {
        singleFile(name: fileName, size: data.count, link: nil, data: data.count > limits.maximumFileBytes ? nil : data,
                   limits: limits)
    }

    private static func singleFile(name: String, size: Int, link: String?, data: Data?, limits: CatalogLimits) -> DeskPackage {
        let id = DeskFileID(path: name)
        var package = DeskPackage(isSingleFile: true)
        let kind: DeskPackageFileKind = name == DeskPackage.packageFileName ? .package : .widget
        package.files = [DeskPackageFile(path: name, kind: kind, size: size, linkDestination: link)]
        if let link {
            package.diagnostics.append(linkDiagnostic(path: name, destination: link, catalog: .current))
            return package
        }
        guard let data else {
            package.diagnostics.append(Diagnostic(id: .fileTooLarge, severity: .error, file: id, range: 0..<0))
            return package
        }
        readText(data, file: id, kind: kind, into: &package)
        return package
    }

    /// Any folder source.
    public static func load(_ source: PackageFileSource, fonts: FontFileInspecting? = nil,
                            limits: CatalogLimits = DeskCatalog.current.limits) throws -> DeskPackage {
        var package = DeskPackage()
        var entries: [PackageEntry] = []
        var count = 0
        var total = 0
        var tooLarge = false
        try source.walk { entry in
            // A path that leaves the folder (an archive listed in memory may hold one): reported, never read.
            guard DeskPackagePath.safeComponents(entry.path) != nil else {
                package.diagnostics.append(Diagnostic(id: .fileOutsideWidget, severity: .error, file: DeskFileID(path: entry.path),
                                                      range: 0..<0))
                return .skip
            }
            let name = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
            if DeskPackagePath.isIgnoredName(name) {
                package.files.append(DeskPackageFile(path: entry.path, kind: .ignored,
                                                     size: entry.type == .directory ? 0 : entry.size))
                return .skip
            }
            if entry.type == .directory { return .next }
            count += 1
            if count > limits.maximumPackageFiles {
                package.isTruncated = true
                package.diagnostics.append(Diagnostic(id: .tooManyFiles, severity: .error, file: DeskPackage.folderFile,
                                                      range: 0..<0,
                                                      arguments: ["limit": .number(limits.maximumPackageFiles)]))
                return .stop
            }
            total += entry.size
            if total > limits.maximumPackageBytes, !tooLarge {
                tooLarge = true
                package.diagnostics.append(Diagnostic(id: .folderTooLarge, severity: .error, file: DeskPackage.folderFile,
                                                      range: 0..<0,
                                                      arguments: ["limit": .number(limits.maximumPackageBytes / 1_048_576)]))
            }
            entries.append(entry)
            return .next
        }
        // Names a Mac sees as one: the first in byte order is read, the others are shadowed (DK8602).
        var firstByKey: [String: String] = [:]
        var shadowed = Set<[UInt8]>()
        for entry in entries.sorted(by: { DeskPackagePath.precedes($0.path, $1.path) }) {
            let key = DeskPackagePath.foldedKey(entry.path)
            // `[String: …]` treats canonically equal keys as one; the key is folded to NFC first anyway.
            guard let first = firstByKey[key] else {
                firstByKey[key] = entry.path
                continue
            }
            shadowed.insert(Array(entry.path.utf8))
            let differsInCase = entry.path.precomposedStringWithCanonicalMapping.utf8
                .elementsEqual(first.precomposedStringWithCanonicalMapping.utf8) == false
            let hint = hintText(.fileNameClash, differsInCase ? "case" : "normalization", catalog: .current)
            package.diagnostics.append(Diagnostic(id: .fileNameClash, severity: .error, file: DeskFileID(path: entry.path),
                                                  range: 0..<0,
                                                  arguments: ["path": .code(entry.path), "other": .code(first), "difference": hint],
                                                  notes: [Note(file: DeskFileID(path: first), range: 0..<0, messageKey: "otherFile")]))
        }
        for entry in entries {
            var file = DeskPackageFile(path: entry.path, kind: DeskPackagePath.kind(of: entry.path), size: entry.size)
            file.isShadowed = shadowed.contains(Array(entry.path.utf8))
            switch entry.type {
            case .link(let destination):
                file.linkDestination = destination
                package.diagnostics.append(linkDiagnostic(path: entry.path, destination: destination, catalog: .current))
                package.files.append(file)
                continue
            case .special:
                file.kind = .other
                package.files.append(file)
                continue
            case .file, .directory:
                break
            }
            if !file.isShadowed {
                switch file.kind {
                case .widget, .package:
                    let id = DeskFileID(path: entry.path)
                    if entry.size > limits.maximumFileBytes {
                        package.diagnostics.append(Diagnostic(id: .fileTooLarge, severity: .error, file: id, range: 0..<0))
                    } else if let data = try? source.read(entry.path, limit: limits.maximumFileBytes + 1) {
                        if data.count > limits.maximumFileBytes {
                            package.diagnostics.append(Diagnostic(id: .fileTooLarge, severity: .error, file: id, range: 0..<0))
                        } else {
                            readText(data, file: id, kind: file.kind, into: &package)
                        }
                    }
                case .image:
                    if let data = try? source.read(entry.path, limit: imageHeaderBytes) {
                        file.pixelSize = ImageHeader.pixelSize(data)
                    }
                case .font:
                    if let fonts, !tooLarge, entry.size <= maximumFontBytes,
                       let data = try? source.read(entry.path, limit: maximumFontBytes) {
                        file.fontFamilies = fonts.families(inFontData: data, fileName: file.name)
                    }
                case .other, .ignored:
                    break
                }
            }
            package.files.append(file)
        }
        package.files.sort { DeskPackagePath.precedes($0.path, $1.path) }
        package.widgets.sort { DeskPackagePath.precedes($0.file.path, $1.file.path) }
        package.diagnostics = sorted(package.diagnostics)
        return package
    }

    /// Decodes a `.desk` file's bytes (DK1008 for invalid UTF-8) and reads its manifest or widget entry.
    private static func readText(_ data: Data, file: DeskFileID, kind: DeskPackageFileKind, into package: inout DeskPackage) {
        switch Desk.load(data, fileName: file.path) {
        case .rejected(let diagnostic):
            package.diagnostics.append(diagnostic)
        case .text(let text, _):
            package.texts[file] = text
            let tree = Desk.parse(text, file: file)
            if kind == .package {
                package.manifest = DeskPackageReader.manifest(tree)
            } else {
                package.widgets.append(DeskPackageReader.widgetEntry(tree))
            }
        }
    }

    static func linkDiagnostic(path: String, destination: String, catalog: DeskCatalog) -> Diagnostic {
        let inside = DeskPackagePath.linkStaysInside(path: path, destination: destination)
        return Diagnostic(id: .fileLink, severity: .error, file: DeskFileID(path: path), range: 0..<0,
                          arguments: ["path": .code(path), "hint": hintText(.fileLink, inside ? "inside" : "outside", catalog: catalog)])
    }

    static func hintText(_ id: DiagnosticID, _ key: String, catalog: DeskCatalog) -> DiagnosticArgument {
        .text(catalog.diagnostic(id)?.hints.first { $0.key == key }?.text ?? LocalizedText("", ""))
    }

    /// By file, then position, then id.
    static func sorted(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        diagnostics.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if !DeskPackagePath.sameBytes(x.file.path, y.file.path) { return DeskPackagePath.precedes(x.file.path, y.file.path) }
            if x.range.lowerBound != y.range.lowerBound { return x.range.lowerBound < y.range.lowerBound }
            if x.id != y.id { return x.id.rawValue < y.id.rawValue }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Archives

    /// Checks an archive's entry list before anything is unpacked (§8.3): paths that leave the folder (zip-slip,
    /// DK4030), names a Mac would unpack onto one another (DK8602), links (DK8606), more than 2,000 files (DK8607)
    /// or more than 100 MiB unpacked (DK8608). Hidden entries, `.DS_Store` and `__MACOSX` are left out, as
    /// unpacking skips them.
    public static func checkArchive(_ entries: [DeskArchiveEntry], limits: CatalogLimits = DeskCatalog.current.limits,
                                    catalog: DeskCatalog = .current) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var count = 0
        var total = 0
        var firstByKey: [String: String] = [:]
        for entry in entries {
            // Folders are often listed with a final `/`.
            let path = entry.isDirectory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            guard let parts = DeskPackagePath.safeComponents(path) else {
                out.append(Diagnostic(id: .fileOutsideWidget, severity: .error, file: DeskFileID(path: entry.path), range: 0..<0))
                continue
            }
            if parts.contains(where: DeskPackagePath.isIgnoredName) { continue }
            if let destination = entry.linkDestination {
                out.append(linkDiagnostic(path: entry.path, destination: destination, catalog: catalog))
                continue
            }
            if entry.isDirectory { continue }
            let key = DeskPackagePath.foldedKey(path)
            if let first = firstByKey[key] {
                let differsInCase = !path.precomposedStringWithCanonicalMapping.utf8
                    .elementsEqual(first.precomposedStringWithCanonicalMapping.utf8)
                out.append(Diagnostic(id: .fileNameClash, severity: .error, file: DeskFileID(path: path), range: 0..<0,
                                      arguments: ["path": .code(path), "other": .code(first),
                                                  "difference": hintText(.fileNameClash, differsInCase ? "case" : "normalization",
                                                                         catalog: catalog)],
                                      notes: [Note(file: DeskFileID(path: first), range: 0..<0, messageKey: "otherFile")]))
            } else {
                firstByKey[key] = path
            }
            count += 1
            total += max(0, entry.size)
        }
        if count > limits.maximumPackageFiles {
            out.append(Diagnostic(id: .tooManyFiles, severity: .error, file: DeskPackage.folderFile, range: 0..<0,
                                  arguments: ["limit": .number(limits.maximumPackageFiles)]))
        }
        if total > limits.maximumPackageBytes {
            out.append(Diagnostic(id: .folderTooLarge, severity: .error, file: DeskPackage.folderFile, range: 0..<0,
                                  arguments: ["limit": .number(limits.maximumPackageBytes / 1_048_576)]))
        }
        return out
    }
}

// MARK: - Picture headers

/// Picture sizes from the first bytes of PNG, JPEG and GIF files; nothing is decoded.
public enum ImageHeader {
    public static func pixelSize(_ data: Data) -> DeskPixelSize? {
        let b = [UInt8](data.prefix(PackageLoader.imageHeaderBytes))
        if b.count >= 24, b[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
           b[12..<16].elementsEqual(Array("IHDR".utf8)) {
            return size(big32(b, 16), big32(b, 20))
        }
        if b.count >= 10, b[0..<6].elementsEqual(Array("GIF87a".utf8)) || b[0..<6].elementsEqual(Array("GIF89a".utf8)) {
            return size(Int(b[6]) | Int(b[7]) << 8, Int(b[8]) | Int(b[9]) << 8)
        }
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 { return jpeg(b) }
        return nil
    }

    private static func size(_ width: Int, _ height: Int) -> DeskPixelSize? {
        width > 0 && height > 0 ? DeskPixelSize(width: width, height: height) : nil
    }

    private static func big32(_ b: [UInt8], _ at: Int) -> Int {
        Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
    }

    private static func big16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }

    /// The first start-of-frame segment's size (as stored, before any orientation).
    private static func jpeg(_ b: [UInt8]) -> DeskPixelSize? {
        var i = 2
        while i + 3 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            if marker == 0xD9 || marker == 0xDA { return nil }
            let length = big16(b, i + 2)
            guard length >= 2 else { return nil }
            let isFrame = (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
            if isFrame {
                guard i + 8 < b.count else { return nil }
                return size(big16(b, i + 7), big16(b, i + 5))
            }
            i += 2 + length
        }
        return nil
    }
}
