import Foundation

/// The folder checks (DK86xx) that need the checked files: a folder with no widget (DK8601), two widgets with one
/// library name (DK8603), a package `requires` older than its widgets need (DK8604), a `.desk` in a subfolder
/// (DK8605) and pictures no widget shows (DK8609). What loading finds (DK8602, DK8606–DK8608) is in
/// `DeskPackage.diagnostics`.
public enum PackageValidator {
    /// The folder checks' diagnostics, sorted as loading sorts its own.
    public static func validate(_ package: DeskPackage, files: [DeskFileID: CheckedFile],
                                catalog: DeskCatalog = .current) -> [Diagnostic] {
        var out: [Diagnostic] = []
        func severity(_ id: DiagnosticID) -> Severity { catalog.diagnostic(id)?.severity ?? .error }
        let packageID = DeskFileID(path: DeskPackage.packageFileName)

        // DK8601: no widget file at all.
        if !package.isTruncated, package.files(.widget).isEmpty {
            var file = DeskPackage.folderFile
            var range = 0..<0
            if let text = package.texts[packageID] {
                file = packageID
                let tree = files[packageID]?.tree ?? Desk.parse(text, file: packageID)
                if let block = tree.rootNode.childNodes.first(where: { $0.kind == .packageBlock }) {
                    range = TopLevelBlockSyntax(unchecked: block).keyword.textRange
                }
            }
            out.append(Diagnostic(id: .packageWithoutWidget, severity: severity(.packageWithoutWidget), file: file, range: range))
        }

        // DK8603: two widgets with one library name.
        var firstByName: [String: DeskWidgetEntry] = [:]
        for entry in package.widgets {
            let key = entry.name.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive], locale: nil)
            guard !key.isEmpty else { continue }
            guard let first = firstByName[key] else {
                firstByName[key] = entry
                continue
            }
            out.append(Diagnostic(id: .duplicateWidgetName, severity: severity(.duplicateWidgetName), file: entry.file,
                                  range: entry.ranges["name"] ?? 0..<0, arguments: ["name": .code(entry.name)],
                                  notes: [Note(file: first.file, range: first.ranges["name"] ?? 0..<0, messageKey: "otherFile")]))
        }

        // DK8604: the package runs on an older Deskset than a widget (or its shared styles) needs.
        if let manifest = package.manifest, let written = manifest.requires, let range = manifest.ranges["requires"] {
            var needed = written
            var neededBy: (file: DeskFileID, range: Range<Int>)?
            if let own = files[packageID]?.requirements.minimumAppVersion, own > needed {
                needed = own
                neededBy = (packageID, range)
            }
            for entry in package.widgets {
                var version = files[entry.file]?.requirements.minimumAppVersion ?? .deskFirstRelease
                if let requires = entry.requires { version = max(version, requires) }
                if version > needed {
                    needed = version
                    neededBy = (entry.file, entry.ranges["requires"] ?? 0..<0)
                }
            }
            if let neededBy {
                let fixed = "\"\(needed)\""
                let who = neededBy.file == packageID ? "package.desk" : neededBy.file.path
                out.append(Diagnostic(
                    id: .packageRequiresTooOld, severity: severity(.packageRequiresTooOld), file: packageID, range: range,
                    arguments: ["version": .code(written.description), "widget": .code(who), "needed": .code(needed.description)],
                    notes: neededBy.file == packageID ? [] : [Note(file: neededBy.file, range: neededBy.range, messageKey: "needsVersion",
                                                                   arguments: ["version": .text(LocalizedText(needed.description, needed.description))])],
                    fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code(fixed)],
                                   edits: [TextEdit(file: packageID, range: range, replacement: fixed)])]))
            }
        }

        // DK8605: a `.desk` below the top is never loaded.
        for file in package.files where file.kind == .other && !file.isLink && !file.isShadowed
            && file.path.contains("/") && (file.path as NSString).pathExtension.lowercased() == "desk" {
            out.append(Diagnostic(id: .widgetInSubfolder, severity: severity(.widgetInSubfolder), file: file.id, range: 0..<0,
                                  arguments: ["path": .code(file.path)]))
        }

        // DK8609: pictures no file names, when every picture path of the folder is written out.
        out += unusedPictures(package, files: files, severity: severity(.unusedAsset))
        return PackageLoader.sorted(out)
    }

    /// The folder's pictures that no widget or shared style names; empty when some picture comes from data, an
    /// option or a template, or when a `.desk` file could not be read or checked.
    static func unusedPictures(_ package: DeskPackage, files: [DeskFileID: CheckedFile], severity: Severity) -> [Diagnostic] {
        guard !package.isTruncated else { return [] }
        let desks = package.files.filter { ($0.kind == .widget || $0.kind == .package) && !$0.isShadowed }
        guard !desks.isEmpty, desks.allSatisfy({ files[$0.id] != nil }) else { return [] }
        guard !files.values.contains(where: { $0.assets.computedImages }) else { return [] }
        let resources = PackageResources(package: package)
        var used = Set<String>()
        for checked in files.values {
            for site in checked.assets.images {
                if let file = resources.file(for: site.path) { used.insert(DeskPackagePath.foldedKey(file.path)) }
            }
        }
        return package.files(.image).filter { !$0.isLink && !used.contains(DeskPackagePath.foldedKey($0.path)) }.map {
            Diagnostic(id: .unusedAsset, severity: severity, file: $0.id, range: 0..<0, arguments: ["path": .code($0.path)])
        }
    }
}
