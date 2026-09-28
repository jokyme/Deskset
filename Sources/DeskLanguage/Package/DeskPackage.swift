import Foundation

// A widget folder as Deskset installs and shares it (the language specification §8.3): the widget
// files at its top, an optional `package.desk` with the package's own fields, shared options, styles and
// translations, and the pictures and fonts the widgets name by relative paths. The model holds only what the folder
// contains (the files, their kinds and sizes, the `.desk` texts, what loading found), so a folder read from disk and
// the same folder held in memory give equal models; trees and checks are built from it (`CheckedDeskPackage`).

/// What a file in a widget folder is.
public enum DeskPackageFileKind: String, Sendable, Hashable, CaseIterable {
    /// A `.desk` file at the top of the folder: one widget.
    case widget
    /// `package.desk` at the top of the folder.
    case package
    /// A picture: PNG, JPEG, GIF, HEIC, WebP, TIFF or BMP.
    case image
    /// A font file: TrueType, OpenType or a collection.
    case font
    /// Anything else, a `.desk` file in a subfolder included (it is not loaded, DK8605).
    case other
    /// Hidden files, `.DS_Store` and `__MACOSX`: never read, never counted, never shared.
    case ignored
}

/// A picture's size in pixels, as its header states it.
public struct DeskPixelSize: Sendable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }
}

/// One entry of a widget folder.
public struct DeskPackageFile: Sendable, Hashable, CustomStringConvertible {
    /// Relative to the folder, `/`-separated, as the folder spells it.
    public var path: String
    public var kind: DeskPackageFileKind
    /// Bytes (for a link, the length of what it points to, as written).
    public var size: Int
    /// Where a link points, as written. Links are never followed (DK8606).
    public var linkDestination: String?
    /// A picture's size from its header (PNG, JPEG and GIF); nil when it could not be read.
    public var pixelSize: DeskPixelSize?
    /// The families a font file holds, from the injected `FontFileInspecting`; nil without it.
    public var fontFamilies: [String]?
    /// Another file whose name differs only by case or Unicode normalization came first (DK8602): this one is not
    /// read, as a Mac would find only one of them.
    public var isShadowed: Bool

    public init(path: String, kind: DeskPackageFileKind, size: Int, linkDestination: String? = nil,
                pixelSize: DeskPixelSize? = nil, fontFamilies: [String]? = nil, isShadowed: Bool = false) {
        self.path = path
        self.kind = kind
        self.size = size
        self.linkDestination = linkDestination
        self.pixelSize = pixelSize
        self.fontFamilies = fontFamilies
        self.isShadowed = isShadowed
    }

    public var isLink: Bool { linkDestination != nil }
    public var id: DeskFileID { DeskFileID(path: path) }
    /// The file name without its folders.
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// A picture or font the widgets can name (not a link, not shadowed).
    public var isAsset: Bool { (kind == .image || kind == .font) && !isLink && !isShadowed }

    public var description: String {
        var s = "\(path) \(kind.rawValue) \(size)"
        if let linkDestination { s += " -> \(linkDestination)" }
        if let pixelSize { s += " \(pixelSize)" }
        if let fontFamilies { s += " [\(fontFamilies.joined(separator: ", "))]" }
        if isShadowed { s += " shadowed" }
        return s
    }
}

/// The `package { }` block of `package.desk` (§5.3): its fields as literals, where they are written, and every field
/// as Desk text.
public struct DeskManifest: Sendable, Hashable {
    public var name: String?
    public var description: String?
    public var author: String?
    public var version: String?
    public var license: String?
    public var homepage: String?
    public var deskVersion: Int?
    public var requires: AppVersion?
    /// Every field's value as written, by field name.
    public var fields: [String: String]
    /// Where each field's value is (UTF-8, in `package.desk`).
    public var ranges: [String: Range<Int>]

    public init(name: String? = nil, description: String? = nil, author: String? = nil, version: String? = nil,
                license: String? = nil, homepage: String? = nil, deskVersion: Int? = nil, requires: AppVersion? = nil,
                fields: [String: String] = [:], ranges: [String: Range<Int>] = [:]) {
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.license = license
        self.homepage = homepage
        self.deskVersion = deskVersion
        self.requires = requires
        self.fields = fields
        self.ranges = ranges
    }
}

/// One widget of a folder, as the widget library lists it: from its `info { }` block, read from the tree alone.
public struct DeskWidgetEntry: Sendable, Hashable {
    public var file: DeskFileID
    /// `info.name` as written, or the file name without `.desk` (§5.3).
    public var name: String
    /// Whether `name` is written in `info`.
    public var hasWrittenName: Bool
    public var description: String
    /// `.small`, `.medium`, `.large` or `.fit`, without the dot; nil when not written.
    public var size: String?
    public var category: String?
    public var deskVersion: Int?
    public var requires: AppVersion?
    /// The permissions `info` asks for, without the dot, as written.
    public var permissions: [String]
    /// The hosts `info.network` lists.
    public var network: [String]
    /// Where each field's value is (UTF-8, in the widget's file).
    public var ranges: [String: Range<Int>]

    public init(file: DeskFileID, name: String, hasWrittenName: Bool, description: String = "", size: String? = nil,
                category: String? = nil, deskVersion: Int? = nil, requires: AppVersion? = nil,
                permissions: [String] = [], network: [String] = [], ranges: [String: Range<Int>] = [:]) {
        self.file = file
        self.name = name
        self.hasWrittenName = hasWrittenName
        self.description = description
        self.size = size
        self.category = category
        self.deskVersion = deskVersion
        self.requires = requires
        self.permissions = permissions
        self.network = network
        self.ranges = ranges
    }
}

/// A widget folder (or a single `.desk` file): its files, the texts of its `.desk` files, what loading found, the
/// manifest and the widgets.
public struct DeskPackage: Sendable, Hashable {
    public static let packageFileName = "package.desk"
    /// Where problems of the folder as a whole are reported (too many files, too large, an empty folder).
    public static let folderFile = DeskFileID(path: "")

    /// Every entry, ignored ones included, sorted by the bytes of their paths.
    public var files: [DeskPackageFile]
    /// The texts of the `.desk` files that were read: the widgets and `package.desk`.
    public var texts: [DeskFileID: String]
    /// What loading found: links (DK8606), too many files (DK8607), too large (DK8608), clashing names (DK8602),
    /// files over 1 MiB (DK8503), invalid UTF-8 (DK1008), paths leaving the folder (DK4030).
    public var diagnostics: [Diagnostic]
    /// `package { }`, when the folder has a `package.desk` with that block.
    public var manifest: DeskManifest?
    /// The widgets whose text was read, in file order.
    public var widgets: [DeskWidgetEntry]
    /// Read from one `.desk` file rather than a folder.
    public var isSingleFile: Bool
    /// Listing stopped early (more files than the limit).
    public var isTruncated: Bool

    public init(files: [DeskPackageFile] = [], texts: [DeskFileID: String] = [:], diagnostics: [Diagnostic] = [],
                manifest: DeskManifest? = nil, widgets: [DeskWidgetEntry] = [], isSingleFile: Bool = false,
                isTruncated: Bool = false) {
        self.files = files
        self.texts = texts
        self.diagnostics = diagnostics
        self.manifest = manifest
        self.widgets = widgets
        self.isSingleFile = isSingleFile
        self.isTruncated = isTruncated
    }

    /// `package.desk` when the folder has it and it was read.
    public var packageFile: DeskFileID? {
        let id = DeskFileID(path: Self.packageFileName)
        return texts[id] != nil ? id : nil
    }

    /// The widget files that were read, in file order.
    public var widgetFiles: [DeskFileID] { widgets.map(\.file) }

    /// The entry at exactly this path.
    public func file(at path: String) -> DeskPackageFile? {
        files.first { DeskPackagePath.sameBytes($0.path, path) }
    }

    /// The files of one kind, not shadowed.
    public func files(_ kind: DeskPackageFileKind) -> [DeskPackageFile] {
        files.filter { $0.kind == kind && !$0.isShadowed }
    }

    /// The widget entry of a file.
    public func widget(_ file: DeskFileID) -> DeskWidgetEntry? { widgets.first { $0.file == file } }

    /// Total bytes of the files that count toward the folder's limit (ignored ones do not).
    public var totalSize: Int { files.filter { $0.kind != .ignored }.reduce(0) { $0 + $1.size } }

    /// The same folder with the text of one `.desk` file changed, added (a new widget or `package.desk`) or removed
    /// (nil). The manifest and the widget entries are read again; what loading found about that file is kept only
    /// when it no longer applies to a text.
    public func settingText(_ text: String?, of file: DeskFileID) -> DeskPackage {
        var copy = self
        let isPackage = file.path == Self.packageFileName
        let isTopDesk = !file.path.contains("/") && file.path.lowercased().hasSuffix(".desk")
        guard isTopDesk else { return copy }
        copy.files.removeAll { DeskPackagePath.sameBytes($0.path, file.path) }
        copy.diagnostics.removeAll { $0.file == file && ($0.id == .invalidEncoding || $0.id == .fileTooLarge) }
        if let text {
            copy.texts[file] = text
            copy.files.append(DeskPackageFile(path: file.path, kind: isPackage ? .package : .widget, size: text.utf8.count))
            copy.files.sort { DeskPackagePath.precedes($0.path, $1.path) }
        } else {
            copy.texts[file] = nil
        }
        if isPackage {
            copy.manifest = text.flatMap { DeskPackageReader.manifest(Desk.parse($0, file: file)) }
        } else {
            copy.widgets.removeAll { $0.file == file }
            if let text {
                copy.widgets.append(DeskPackageReader.widgetEntry(Desk.parse(text, file: file)))
                copy.widgets.sort { DeskPackagePath.precedes($0.file.path, $1.file.path) }
            }
        }
        return copy
    }
}

// MARK: - Paths

/// Paths inside a widget folder: `/`-separated, relative, compared by their bytes (Swift's `==` treats the NFC and
/// NFD spellings of a name as equal, which a folder may hold side by side).
public enum DeskPackagePath {
    /// Whether two paths are the same bytes.
    public static func sameBytes(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// Byte order, the order `DeskPackage.files` is sorted in.
    public static func precedes(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    /// Folder by folder, each folder's entries in byte order: the order a walk visits them.
    public static func walkPrecedes(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "/", omittingEmptySubsequences: false)
        let y = b.split(separator: "/", omittingEmptySubsequences: false)
        for (p, q) in zip(x, y) where !p.utf8.elementsEqual(q.utf8) {
            return p.utf8.lexicographicallyPrecedes(q.utf8)
        }
        return x.count < y.count
    }

    /// How a Mac compares names: without regard to case or to how accented letters are stored.
    public static func foldedKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// The parts of a relative path that stays inside the folder (no empty, `.` or `..` part, not absolute, no
    /// drive letter); nil otherwise. A `\` counts as a separator, as archives from Windows write it.
    public static func safeComponents(_ path: String) -> [String]? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.hasPrefix("~") else { return nil }
        let parts = path.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" }.map(String.init)
        if let first = parts.first, first.count == 2, first.hasSuffix(":") { return nil }
        for part in parts where part.isEmpty || part == "." || part == ".." {
            return nil
        }
        return parts
    }

    /// Whether a link at `path` pointing at `destination` stays inside the folder (read as written, never
    /// followed).
    public static func linkStaysInside(path: String, destination: String) -> Bool {
        guard !destination.hasPrefix("/"), !destination.hasPrefix("~") else { return false }
        var stack = path.split(separator: "/").dropLast().map(String.init)
        for part in destination.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                if stack.isEmpty { return false }
                stack.removeLast()
            default:
                stack.append(String(part))
            }
        }
        return !stack.isEmpty
    }

    /// Hidden files and folders, `.DS_Store` and `__MACOSX` (a name of the path, not the whole path).
    public static func isIgnoredName(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "__MACOSX"
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"]
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    /// What a file at this path is, by its place and extension (a `.desk` below the top is `.other`).
    public static func kind(of path: String) -> DeskPackageFileKind {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { isIgnoredName(String($0)) }) { return .ignored }
        let name = String(parts.last ?? "")
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "desk" {
            guard parts.count == 1 else { return .other }
            return name == DeskPackage.packageFileName ? .package : .widget
        }
        if imageExtensions.contains(ext) { return .image }
        if fontExtensions.contains(ext) { return .font }
        return .other
    }
}

// MARK: - Reading info and package blocks

/// The literal fields of `info { }` and `package { }`, read from the tree alone (no catalog, no checker).
enum DeskPackageReader {
    /// The fields of the file's first `info` or `package` block: name → (value node, statement).
    static func fields(_ tree: SyntaxTree, kind: SyntaxKind) -> [(name: String, value: PositionedNode)] {
        var out: [(String, PositionedNode)] = []
        for item in tree.rootNode.childNodes where item.kind == kind {
            guard let body = item.firstChild(.block) else { continue }
            for statement in BlockSyntax(unchecked: body).statements {
                switch statement.kind {
                case .field:
                    let field = FieldSyntax(unchecked: statement)
                    out.append((field.label.name, field.value.node))
                case .assignment:
                    // `info { name = "CPU" }` (DK2035): the field still counts.
                    let assignment = AssignmentSyntax(unchecked: statement)
                    guard assignment.target.path.count == 1 else { continue }
                    out.append((assignment.target.name.token.name, assignment.value.node))
                default:
                    continue
                }
            }
            break
        }
        return out
    }

    static func string(_ node: PositionedNode) -> String? { StringLiteralSyntax.literalValue(of: node.node) }

    static func member(_ node: PositionedNode) -> String? {
        guard node.kind == .implicitMemberExpr else { return nil }
        return ImplicitMemberExprSyntax(unchecked: node).name.token.name
    }

    static func members(_ node: PositionedNode) -> [String] {
        guard node.kind == .listLiteral else { return [] }
        return ListLiteralSyntax(unchecked: node).elements.compactMap { member($0.node) }
    }

    static func strings(_ node: PositionedNode) -> [String] {
        guard node.kind == .listLiteral else { return [] }
        return ListLiteralSyntax(unchecked: node).elements.compactMap { string($0.node) }
    }

    static func integer(_ node: PositionedNode) -> Int? {
        guard node.kind == .numberLiteral, let token = node.children.first?.token, token.token.unit == nil,
              !token.token.text.contains(".") else { return nil }
        return Int(token.token.text)
    }

    static func text(_ tree: SyntaxTree, _ node: PositionedNode) -> String {
        let r = node.quickTextRange
        let bytes = Array(tree.text.utf8)
        guard r.lowerBound >= 0, r.upperBound <= bytes.count else { return "" }
        return String(decoding: bytes[r], as: UTF8.self)
    }

    static func manifest(_ tree: SyntaxTree) -> DeskManifest? {
        guard tree.rootNode.childNodes.contains(where: { $0.kind == .packageBlock }) else { return nil }
        var manifest = DeskManifest()
        for (name, value) in fields(tree, kind: .packageBlock) where manifest.fields[name] == nil {
            manifest.fields[name] = text(tree, value)
            manifest.ranges[name] = value.quickTextRange
            switch name {
            case "name": manifest.name = string(value)
            case "description": manifest.description = string(value)
            case "author": manifest.author = string(value)
            case "version": manifest.version = string(value)
            case "license": manifest.license = string(value)
            case "homepage": manifest.homepage = string(value)
            case "deskVersion": manifest.deskVersion = integer(value)
            case "requires": manifest.requires = string(value).flatMap(AppVersion.init)
            default: break
            }
        }
        return manifest
    }

    static func widgetEntry(_ tree: SyntaxTree) -> DeskWidgetEntry {
        let fileName = (tree.file.path as NSString).lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension
        var entry = DeskWidgetEntry(file: tree.file, name: stem, hasWrittenName: false)
        var seen = Set<String>()
        for (name, value) in fields(tree, kind: .infoBlock) where seen.insert(name).inserted {
            entry.ranges[name] = value.quickTextRange
            switch name {
            case "name":
                if let s = string(value) {
                    entry.name = s
                    entry.hasWrittenName = true
                }
            case "description": entry.description = string(value) ?? ""
            case "size": entry.size = member(value)
            case "category": entry.category = member(value)
            case "deskVersion": entry.deskVersion = integer(value)
            case "requires": entry.requires = string(value).flatMap(AppVersion.init)
            case "permissions": entry.permissions = members(value)
            case "network": entry.network = strings(value)
            default: break
            }
        }
        return entry
    }
}
