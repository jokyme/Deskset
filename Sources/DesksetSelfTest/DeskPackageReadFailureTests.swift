import Foundation
@testable import DeskLanguage

/// A regular file discovered by the walk can become unreadable before the read.
final class DeskPackageReadFailureSource: PackageFileSource, @unchecked Sendable {
    private enum OpaqueFailure: Error, CustomStringConvertible {
        case unavailable
        var description: String { "PRIVATE storage failure details" }
    }

    private let source: InMemoryPackageSource
    private let failures: [String: PackageSourceError]
    private let opaqueFailures: Set<String>
    private let advertisedSizes: [String: Int]
    private let lock = NSLock()
    private var reads: [(path: String, limit: Int)] = []

    convenience init(texts: [String: String], failures: [String: PackageSourceError],
                     opaqueFailures: Set<String> = [], advertisedSizes: [String: Int] = [:]) {
        self.init(source: InMemoryPackageSource(texts: texts), failures: failures,
                  opaqueFailures: opaqueFailures, advertisedSizes: advertisedSizes)
    }

    init(source: InMemoryPackageSource, failures: [String: PackageSourceError],
         opaqueFailures: Set<String> = [], advertisedSizes: [String: Int] = [:]) {
        self.source = source
        self.failures = failures
        self.opaqueFailures = opaqueFailures
        self.advertisedSizes = advertisedSizes
    }

    func walk(_ visit: (PackageEntry) -> PackageWalkStep) throws {
        try source.walk { entry in
            var entry = entry
            if let size = advertisedSizes[entry.path] { entry.size = size }
            return visit(entry)
        }
    }

    func read(_ path: String, limit: Int) throws -> Data {
        lock.lock()
        reads.append((path, limit))
        lock.unlock()
        if let failure = failures[path] { throw failure }
        if opaqueFailures.contains(path) { throw OpaqueFailure.unavailable }
        return try source.read(path, limit: limit)
    }

    var readPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return reads.map(\.path)
    }

    var readLimits: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return reads.map(\.limit)
    }
}

func runDeskPackageReadFailureTests(_ t: TestRunner) {
    let goodID = DeskFileID("Good.desk")
    let good = "// Preserve the original bytes.\r\nwidget { Text(\"Good\") }\r\n"
    let limits = DeskCatalog.current.limits

    t.suite("Desk: package read failures: an unreadable member blocks the whole package without losing a good member") {
        let badID = DeskFileID("Broken.desk")
        let source = DeskPackageReadFailureSource(
            texts: [goodID.path: good, badID.path: "widget { Text(\"Broken\") }"],
            failures: [badID.path: .cannotRead(badID.path)])
        let package = try PackageLoader.load(source)
        let checked = CheckedDeskPackage(package: package)

        t.equal(package.files(.widget).map(\.path), [badID.path, goodID.path], "both discovered files remain in the inventory")
        t.equal(package.texts[goodID].map { Data($0.utf8) }, Data(good.utf8), "the good member is not rewritten")
        t.equal(package.texts[badID], nil, "a failed read must not manufacture an empty source")
        t.equal(package.widgetFiles, [goodID])
        t.check(checked.files[goodID]?.diagnostics(.error).isEmpty == true, "the good member is fully checked")
        t.check(!checked.allDiagnostics.filter { $0.severity == .error }.isEmpty, "the package cannot appear valid after losing a member")
        t.equal(checked.allDiagnostics.filter { $0.id.rawValue == "DK8610" }.map { "\($0.id.rawValue)@\($0.file.path)" },
                ["DK8610@Broken.desk"], "the error identifies the unreadable member")
        t.equal(source.readPaths, [badID.path, goodID.path], "each discovered source is read once")
        t.equal(source.readLimits, Array(repeating: limits.maximumFileBytes + 1, count: 2), "the original read bound is preserved")
    }

    t.suite("Desk: package read failures: an unreadable package file cannot silently become an absent package") {
        let packageID = DeskFileID("package.desk")
        let source = DeskPackageReadFailureSource(
            texts: [goodID.path: good, packageID.path: "style base { .color(.red) }"],
            failures: [packageID.path: .notARegularFile(packageID.path)])
        let package = try PackageLoader.load(source)
        let checked = CheckedDeskPackage(package: package)

        t.equal(package.files(.package).map(\.path), [packageID.path], "the discovered package file remains in the inventory")
        t.equal(package.texts[packageID], nil, "no package source is invented after a failed read")
        t.equal(package.texts[goodID].map { Data($0.utf8) }, Data(good.utf8))
        t.equal(package.widgetFiles, [goodID])
        t.check(checked.files[goodID]?.diagnostics(.error).isEmpty == true, "good members remain available for diagnosis")
        t.check(!checked.allDiagnostics.filter { $0.severity == .error }.isEmpty, "the whole package remains blocked")
        t.equal(checked.allDiagnostics.filter { $0.id.rawValue == "DK8610" }.map { "\($0.id.rawValue)@\($0.file.path)" },
                ["DK8610@package.desk"], "the error identifies the actual package file")
        t.equal(source.readPaths, [goodID.path, packageID.path], "there is no retry or whole-folder abort")
        t.equal(source.readLimits, Array(repeating: limits.maximumFileBytes + 1, count: 2))
    }

    t.suite("Desk: package read failures: source error kinds produce the same localized path-only error") {
        let source = DeskPackageReadFailureSource(
            texts: [goodID.path: good, "Denied.desk": "widget { Text(\"D\") }",
                    "Replaced.desk": "widget { Text(\"R\") }", "Unknown.desk": "widget { Text(\"U\") }"],
            failures: ["Denied.desk": .cannotRead("PRIVATE permission details"),
                       "Replaced.desk": .notARegularFile("PRIVATE replacement details")],
            opaqueFailures: ["Unknown.desk"])
        let package = try PackageLoader.load(source)
        let errors = package.diagnostics
        t.equal(errors.map(\.id), Array(repeating: .packageFileUnreadable, count: 3))
        t.equal(errors.map { $0.file.path }, ["Denied.desk", "Replaced.desk", "Unknown.desk"])
        for error in errors {
            t.equal(error.severity, .error)
            t.equal(error.range, 0..<0, "an unread file has no invented source span")
            t.equal(error.arguments, ["path": .code(error.file.path)])
            t.equal(error.fixIts.count, 0, "a read failure has no source correction to invent")
            t.equal(error.notes.count, 0)
            t.equal(error.message(in: .english), "The file `\(error.file.path)` could not be read.")
            t.equal(error.message(in: .simplifiedChinese), "无法读取文件 `\(error.file.path)`。")
            t.check(!error.message(in: .english).contains("PRIVATE"), "the source's underlying error stays private")
            t.equal(package.texts[error.file], nil)
        }
        t.equal(package.texts[goodID].map { Data($0.utf8) }, Data(good.utf8))
        t.equal(source.readPaths, ["Denied.desk", goodID.path, "Replaced.desk", "Unknown.desk"])
        let spec = DeskCatalog.current.diagnostic(.packageFileUnreadable)
        t.equal(spec?.severity, .error)
        t.equal(spec?.placeholders, ["path": .code])
        t.equal(spec?.fixIts.count, 0)
    }

    t.suite("Desk: package read failures: known and growing oversized sources retain the existing size diagnostic") {
        var smallLimits = limits
        smallLimits.maximumFileBytes = 256
        let large = String(repeating: "x", count: smallLimits.maximumFileBytes + 1)
        let source = DeskPackageReadFailureSource(
            texts: [goodID.path: good, "Grew.desk": large, "Huge.desk": large],
            failures: ["Huge.desk": .cannotRead("must not be read")], advertisedSizes: ["Grew.desk": 1])
        let package = try PackageLoader.load(source, limits: smallLimits)
        t.equal(package.diagnostics.map(\.id), [.fileTooLarge, .fileTooLarge])
        t.equal(package.diagnostics.map { $0.file.path }, ["Grew.desk", "Huge.desk"])
        t.equal(package.files(.widget).map(\.path), [goodID.path, "Grew.desk", "Huge.desk"])
        t.equal(package.texts.keys.map(\.path), [goodID.path])
        t.equal(source.readPaths, [goodID.path, "Grew.desk"], "known oversize files are never read")
        t.equal(source.readLimits, [257, 257], "growth is detected with the original bounded read")
        t.equal(CheckedDeskPackage(package: package).allDiagnostics.filter { $0.severity == .error }.map(\.id),
                [.fileTooLarge, .fileTooLarge])
    }

    t.suite("Desk: package read failures: hidden shadowed and nested source files are not newly read") {
        let skipped = ["good.desk", ".Secret.desk", ".hidden/Private.desk", "__MACOSX/Hidden.desk", "Extras/Nested.desk"]
        var texts = Dictionary(uniqueKeysWithValues: skipped.map { ($0, "widget { Text(\"Skipped\") }") })
        texts[goodID.path] = good
        let source = DeskPackageReadFailureSource(texts: texts,
            failures: Dictionary(uniqueKeysWithValues: skipped.map { ($0, PackageSourceError.cannotRead($0)) }))
        let package = try PackageLoader.load(source)
        t.equal(source.readPaths, [goodID.path])
        t.equal(package.texts.keys.map(\.path), [goodID.path])
        t.equal(package.file(at: "good.desk")?.isShadowed, true)
        t.equal(package.file(at: ".Secret.desk")?.kind, .ignored)
        t.equal(package.file(at: ".hidden")?.kind, .ignored)
        t.equal(package.file(at: "__MACOSX")?.kind, .ignored)
        t.equal(package.file(at: "Extras/Nested.desk")?.kind, .other)
        t.equal(package.diagnostics.map(\.id), [.fileNameClash])
        t.check(!CheckedDeskPackage(package: package).allDiagnostics.contains { $0.id == .packageFileUnreadable })
    }

    t.suite("Desk: package read failures: image header and font probing remain best effort") {
        let source = DeskPackageReadFailureSource(
            texts: [goodID.path: good, "image.png": "image bytes", "font.ttf": "font bytes"],
            failures: ["image.png": .cannotRead("image.png"), "font.ttf": .cannotRead("font.ttf")])
        let package = try PackageLoader.load(source, fonts: DeskFakeFontFiles())
        t.equal(package.diagnostics, [])
        t.equal(package.file(at: "image.png")?.kind, .image)
        t.equal(package.file(at: "image.png")?.pixelSize, nil)
        t.equal(package.file(at: "font.ttf")?.kind, .font)
        t.equal(package.file(at: "font.ttf")?.fontFamilies, nil)
        t.equal(source.readPaths, [goodID.path, "font.ttf", "image.png"])
        t.check(CheckedDeskPackage(package: package).allDiagnostics.filter { $0.severity == .error }.isEmpty)
    }

    t.suite("Desk: package read failures: language service preserves loader errors until a fresh package is readable") {
        let bad = "Broken.desk"
        let source = DeskPackageReadFailureSource(texts: [goodID.path: good, bad: "widget { Text(\"Fixed\") }"],
                                                failures: [bad: .cannotRead(bad)])
        let package = try PackageLoader.load(source)
        let service = DeskLanguageService(package: package, openFile: goodID)
        let initial = service.snapshot.packageCheck()
        t.equal(initial.folderDiagnostics.filter { $0.id == .packageFileUnreadable }.map { $0.file.path }, [bad])
        t.equal(initial.allDiagnostics.filter { $0.severity == .error }.map(\.id), [.packageFileUnreadable])
        t.equal(initial.problemCounts()[DeskFileID(bad)]?.errors, 1)
        t.equal(service.snapshot.checked.diagnostics(.error), [], "the open good member remains valid on its own")
        t.equal(service.snapshot.text, good)

        let repairedSource = DeskPackageReadFailureSource(texts: [goodID.path: good, bad: "widget { Text(\"Fixed\") }"], failures: [:])
        let repaired = try PackageLoader.load(repairedSource)
        let after = service.setPackage(repaired).packageCheck()
        t.check(after.allDiagnostics.filter { $0.severity == .error }.isEmpty)
        t.equal(after.widgetFiles, [DeskFileID(bad), goodID])
        t.equal(after.files[DeskFileID(bad)]?.diagnostics(.error), [])
        t.equal(service.snapshot.text, good, "reloading resources preserves the open document's bytes")
        t.equal(source.readPaths, [bad, goodID.path])
        t.equal(repairedSource.readPaths, [bad, goodID.path])
    }
}
