import Foundation

/// The pictures and fonts of a widget folder, for the checker (DK4029, DK4032, DK4033): a path written in a widget is
/// looked up relative to the widget's own folder the way a Mac finds a file — without regard to case or to how
/// accented letters are stored. Links and shadowed files are not there (links are never followed). A font file's
/// families count as installed fonts for the widgets of the folder.
public struct PackageResources: ResourceResolving {
    /// The folder the paths are relative to (`""`: the top of the package).
    public let base: String
    private let byPath: [String: DeskPackageFile]
    private let byFamily: [String: [String]]
    private let candidates: [String]

    public init(package: DeskPackage, base: String = "") {
        self.base = base
        var byPath: [String: DeskPackageFile] = [:]
        var byFamily: [String: [String]] = [:]
        var candidates: [String] = []
        for file in package.files where file.kind != .ignored && !file.isShadowed && !file.isLink {
            let key = DeskPackagePath.foldedKey(file.path)
            if byPath[key] == nil { byPath[key] = file }
            if file.kind == .image || file.kind == .font || file.kind == .other {
                candidates.append(file.path)
            }
            if file.kind == .font, let families = file.fontFamilies {
                for family in families { byFamily[DeskPackagePath.foldedKey(family), default: []].append(file.path) }
            }
        }
        self.byPath = byPath
        self.byFamily = byFamily
        self.candidates = candidates
    }

    /// The folder's file a path written in a widget names, nil when there is none (or the path leaves the folder).
    public func file(for relativePath: String) -> DeskPackageFile? {
        guard let path = resolve(relativePath) else { return nil }
        return byPath[DeskPackagePath.foldedKey(path)]
    }

    /// `base` + the path, without `./`; nil when it leaves the folder.
    public func resolve(_ relativePath: String) -> String? {
        var parts = base.split(separator: "/").map(String.init)
        for part in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(part))
            }
        }
        guard !relativePath.hasPrefix("/"), !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// The folder's pictures below `base` whose path or file name starts with `prefix`, in path order.
    public func paths(matching prefix: String, limit: Int) -> [String] {
        let lead = base.isEmpty ? "" : base + "/"
        let folded = DeskPackagePath.foldedKey(prefix)
        var out: [String] = []
        for path in candidates.sorted() where path.hasPrefix(lead) {
            let relative = String(path.dropFirst(lead.count))
            guard byPath[DeskPackagePath.foldedKey(path)]?.kind == .image else { continue }
            let name = (relative as NSString).lastPathComponent
            if folded.isEmpty || DeskPackagePath.foldedKey(relative).hasPrefix(folded) || DeskPackagePath.foldedKey(name).hasPrefix(folded) {
                out.append(relative)
                if out.count >= limit { break }
            }
        }
        return out
    }

    public func kind(of relativePath: String) -> ResourceKind? {
        if let file = file(for: relativePath) {
            switch file.kind {
            case .image:
                return .image(width: file.pixelSize?.width ?? 0, height: file.pixelSize?.height ?? 0)
            case .font:
                return .font(families: file.fontFamilies ?? [])
            default:
                return .other
            }
        }
        // A family of a font file in the folder (`.font("Brush Script Local", 14)`).
        if !relativePath.contains("/"), byFamily[DeskPackagePath.foldedKey(relativePath)] != nil {
            return .font(families: [relativePath])
        }
        return nil
    }

    public func similarPaths(to relativePath: String) -> [String] {
        let wanted = (resolve(relativePath) ?? relativePath).lowercased()
        let limit = max(2, DidYouMean.threshold(for: wanted))
        let prefix = base.isEmpty ? "" : base + "/"
        var scored: [(path: String, distance: Int)] = []
        for path in candidates where path.hasPrefix(prefix) {
            let distance = DidYouMean.distance(path.lowercased(), wanted, limit: limit + 1)
            if distance <= limit { scored.append((path, distance)) }
        }
        scored.sort { a, b in a.distance != b.distance ? a.distance < b.distance : DeskPackagePath.precedes(a.path, b.path) }
        return scored.map { String($0.path.dropFirst(prefix.count)) }
    }
}
