import Foundation
@testable import DeskLanguage

// One test per diagnostic (the language specification §9.4): every id has a fixture
// `TestSkins/Desk/Diagnostics/DKnnnn-name.desk` with a positive part that produces exactly that diagnostic (and the
// ones its header allows) and a negative part, the corrected code, that produces none. Messages render in both
// languages without type or facet ids; every fix-it of the diagnostic is applied and the result re-checked: the
// diagnostic is gone and no new error appears.
//
// Fixture format: header lines `//== expect: DKnnnn`, `//== also: …`, `//== negative-also: …`,
// `//== context: resources symbols fonts layout future target=1.0`, `//== file: package.desk`,
// `//== generate: …` (for inputs too large or too odd to keep as text); then the positive code; `//== negative` and
// the corrected code; optionally `//== package` and a package.desk the check uses.
//
// Folder diagnostics (DK86xx) check a whole widget folder held in memory: the fixture's file, the package, and
// `//== folder-file: Name` sections (each a file of the folder, its text up to the next section),
// `//== asset: path WxH` (a PNG of that size), `//== link: path -> destination` and `//== folder-generate: kind`
// (`manyFiles`, `largeFolder`). Those written after `//== negative` belong to the corrected folder, which otherwise
// has the same folder files and assets (never the links or generated files).

struct DeskDiagnosticFixture {
    var path: String
    var id: String
    var expect: [String] = []
    var also: [String] = []
    var negativeAlso: [String] = []
    var context: [String] = []
    var fileName = "Test.desk"
    var generate: String?
    /// `fixit: may-introduce-errors`: a fix-it chooses one reading, so the other use may become an error (DK4041).
    var fixItsMayIntroduceErrors = false
    var positive = ""
    var negative: String?
    var package: String?
    /// The folder's other files, pictures and links (positive; the negative's when written after `//== negative`).
    var folderFiles: [(name: String, text: String)] = []
    var negativeFolderFiles: [(name: String, text: String)]?
    var assets: [(path: String, width: Int, height: Int)] = []
    var negativeAssets: [(path: String, width: Int, height: Int)]?
    var links: [(path: String, destination: String)] = []
    var negativeLinks: [(path: String, destination: String)] = []
    var folderGenerate: String?

    /// Checked as a whole folder.
    var isFolder: Bool {
        id.hasPrefix("DK86") || !folderFiles.isEmpty || !assets.isEmpty || !links.isEmpty || folderGenerate != nil
            || negativeFolderFiles != nil || negativeAssets != nil
    }

    static func parse(path: String, text: String) -> DeskDiagnosticFixture {
        var fixture = DeskDiagnosticFixture(path: path, id: String((path as NSString).lastPathComponent.prefix(6)))
        var section = "positive"
        var positive: [String] = [], negative: [String] = [], package: [String] = []
        var folderFile: [String] = []
        var folderFileName: String?
        var afterNegative = false
        func endFolderFile() {
            guard let name = folderFileName else { return }
            let file = (name, folderFile.joined(separator: "\n"))
            if afterNegative { fixture.negativeFolderFiles = (fixture.negativeFolderFiles ?? []) + [file] } else { fixture.folderFiles.append(file) }
            folderFileName = nil
            folderFile = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("//== ") {
                let directive = String(line.dropFirst(5))
                func values(_ key: String) -> [String]? {
                    guard directive.hasPrefix(key + ":") else { return nil }
                    return directive.dropFirst(key.count + 1).split(separator: " ").map(String.init)
                }
                if directive == "negative" { endFolderFile(); section = "negative"; afterNegative = true; continue }
                if directive == "package" { endFolderFile(); section = "package"; continue }
                if directive.hasPrefix("folder-file:") {
                    endFolderFile()
                    folderFileName = directive.dropFirst("folder-file:".count).trimmingCharacters(in: .whitespaces)
                    section = "folder-file"
                    continue
                }
                if let v = values("asset"), v.count == 2 {
                    let size = v[1].split(separator: "x").compactMap { Int($0) }
                    let asset = (v[0], size.first ?? 1, size.last ?? 1)
                    if afterNegative { fixture.negativeAssets = (fixture.negativeAssets ?? []) + [asset] } else { fixture.assets.append(asset) }
                    continue
                }
                if directive.hasPrefix("link:") {
                    let parts = directive.dropFirst("link:".count).components(separatedBy: " -> ")
                    if parts.count == 2 {
                        let link = (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces))
                        if afterNegative { fixture.negativeLinks.append(link) } else { fixture.links.append(link) }
                    }
                    continue
                }
                if let v = values("folder-generate"), let kind = v.first { fixture.folderGenerate = kind; continue }
                if let v = values("expect") { fixture.expect += v; continue }
                if let v = values("also") { fixture.also += v; continue }
                if let v = values("negative-also") { fixture.negativeAlso += v; continue }
                if let v = values("context") { fixture.context += v; continue }
                if let v = values("file"), let name = v.first { fixture.fileName = name; continue }
                if let v = values("generate"), let kind = v.first { fixture.generate = kind; continue }
                if let v = values("fixit"), v.first == "may-introduce-errors" { fixture.fixItsMayIntroduceErrors = true; continue }
                continue
            }
            switch section {
            case "negative": negative.append(line)
            case "package": package.append(line)
            case "folder-file": folderFile.append(line)
            default: positive.append(line)
            }
        }
        endFolderFile()
        fixture.positive = positive.joined(separator: "\n")
        if !negative.isEmpty { fixture.negative = negative.joined(separator: "\n") }
        if !package.isEmpty { fixture.package = package.joined(separator: "\n") }
        return fixture
    }
}

/// Files in a fake widget folder.
struct DeskFakeResources: ResourceResolving {
    let files = ["pause.png", "cover.png", "photo.png", "paper.png", "bg.png"]
    func kind(of relativePath: String) -> ResourceKind? { files.contains(relativePath) ? .image(width: 64, height: 64) : nil }
    func similarPaths(to relativePath: String) -> [String] {
        files.filter { DidYouMean.distance($0, relativePath) <= 2 }
    }
}

struct DeskFakeSymbols: SymbolValidating {
    let known: Set<String> = ["wifi", "wifi.slash", "chevron.left", "chevron.right", "flame.fill", "play.fill", "pause.fill"]
    func exists(_ symbol: String) -> Bool { known.contains(symbol) }
    func minimumMacOS(of symbol: String) -> Int? { nil }
    func similarSymbols(to symbol: String) -> [String] { known.filter { DidYouMean.distance($0, symbol) <= 2 }.sorted() }
}

struct DeskFakeFonts: FontCataloging {
    let installed: Set<String> = ["Futura", "Helvetica Neue", "PingFang SC", "Menlo", "Helvetica"]
    func isInstalled(family: String) -> Bool { installed.contains(family) }
    func macSubstitute(forWindowsFamily family: String) -> String? {
        ["Segoe UI": "Helvetica Neue", "Arial": "Helvetica", "Tahoma": "Helvetica Neue"][family]
    }
    func similarFamilies(to family: String) -> [String] { installed.filter { DidYouMean.distance($0, family) <= 2 }.sorted() }
}

/// Text measured as 0.6 em per character and 1.2 em per line.
struct DeskFakeLayout: LayoutMeasuring {
    func textSize(_ text: String, font: ResolvedFont, maxWidth: Double?, lines: Int?) -> (width: Double, height: Double) {
        (Double(text.count) * font.size * 0.6, font.size * 1.2)
    }
    func imageSize(relativePath: String) -> (width: Double, height: Double)? { (64, 64) }
}

/// A catalog from a later Deskset: a modifier added in 1.2 (`.sparkle`) and a deprecated one (`.glow`).
func deskFutureCatalog() -> DeskCatalog {
    var catalog = DeskCatalog.current
    let v12 = AppVersion(major: 1, minor: 2)
    var sparkle = catalog.modifier(named: "blur")!
    sparkle.name = "sparkle"
    sparkle.doc.since = v12
    sparkle.doc.keywords = ["sparkle"]
    sparkle.signatures = sparkle.signatures.map { var s = $0; s.since = v12; return s }
    var glow = catalog.modifier(named: "blur")!
    glow.name = "glow"
    glow.doc.deprecated = Deprecation(since: .deskFirstRelease, replacement: ".blur")
    glow.doc.keywords = ["glow"]
    catalog.modifiers += [sparkle, glow]
    return catalog
}

/// The context a fixture is checked with.
func deskFixtureContext(_ fixture: DeskDiagnosticFixture, package: CheckedPackage?) -> CheckContext {
    var catalog = DeskCatalog.current
    var appVersion: AppVersion?
    var target: AppVersion?
    for flag in fixture.context {
        if flag == "future" { catalog = deskFutureCatalog(); appVersion = AppVersion(major: 1, minor: 2) }
        if flag.hasPrefix("target=") { target = AppVersion(String(flag.dropFirst(7))) }
    }
    var context = CheckContext(catalog: catalog, package: package, appVersion: appVersion, targetAppVersion: target)
    if fixture.context.contains("resources") { context.resources = DeskFakeResources() }
    if fixture.context.contains("symbols") { context.symbols = DeskFakeSymbols() }
    if fixture.context.contains("fonts") { context.fonts = DeskFakeFonts() }
    if fixture.context.contains("layout") { context.layout = DeskFakeLayout() }
    return context
}

/// Inputs too large or too odd to keep as fixture text.
func deskGeneratedText(_ kind: String) -> String {
    let info = "info { name: \"T\" }\n"
    switch kind {
    case "deepNesting":
        return info + "widget {\n" + String(repeating: "Column {\n", count: 70) + "Text(\"A\")\n" + String(repeating: "}\n", count: 70) + "}\n"
    case "manyProblems":
        return info + "widget {\n    Column {\n" + String(repeating: "        Txt(\"A\")\n", count: 520) + "    }\n}\n"
    case "longList":
        let items = (1...1_200).map(String.init).joined(separator: ", ")
        return info + "widget {\n    computed numbers = [\(items)]\n    Text(\"{numbers.count}\")\n}\n"
    case "manyOptions":
        var lines = info + "options {\n"
        for i in 1...101 { lines += "    o\(i) = Toggle(\"Option \(i)\")\n" }
        lines += "}\nwidget { Text(\"A\").hidden(if: " + (1...101).map { "options.o\($0)" }.joined(separator: " or ") + ") }\n"
        return lines
    case "hugeFile":
        return info + "widget { Text(\"A\") }\n" + String(repeating: "// padding padding padding padding padding padding padding\n", count: 20_000)
    case "longText":
        return info + "widget { Text(\"" + String(repeating: "a", count: 33_000) + "\") }\n"
    case "iniFile":
        var text = info + "widget { Text(\"A\") }\n"
        for i in 1...30 { text += "[Meter\(i)]\nMeter=String\nText=Hello\n" }
        return text
    default:
        return ""
    }
}

/// Ids a message must never show: type, facet and grammar ids.
func deskMessageLeaks(_ message: String) -> [String] {
    var leaks: [String] = []
    for marker in ["enum:", "type:", "facet:", "dimension:", "record:", "slot:", "component:", "construct:", "place:", "content:",
                   "kind:", "preset:"] where message.contains(marker) {
        leaks.append(marker)
    }
    if message.range(of: #"\{[a-zA-Z]+\}"#, options: .regularExpression) != nil { leaks.append("placeholder") }
    return leaks
}

func runDeskDiagnosticsTests(_ t: TestRunner) {
    let files = deskFixtureFiles("Diagnostics")
    let fixtures = files.map { DeskDiagnosticFixture.parse(path: $0.path, text: $0.text) }

    t.suite("Desk: diagnostics — every id has a fixture") {
        let ids = Set(DiagnosticID.allCases.map(\.rawValue))
        let covered = Set(fixtures.map(\.id))
        for id in ids.subtracting(covered).sorted() { t.check(false, "\(id) has no fixture") }
        for fixture in fixtures {
            t.check(ids.contains(fixture.id), "\(fixture.path): \(fixture.id) is not a diagnostic")
            t.check(fixture.expect.contains(fixture.id), "\(fixture.path) does not expect its own id")
            let name = (fixture.path as NSString).lastPathComponent
            if let id = DiagnosticID(rawValue: fixture.id) {
                t.equal(name, "\(id.rawValue)-\(id.symbolicName).desk", "fixture file name")
            }
        }
    }

    t.suite("Desk: diagnostics — positive and negative fixtures") {
        for fixture in fixtures {
            checkDeskFixture(t, fixture)
        }
    }
}

func deskCheckFixtureText(_ text: String, _ fixture: DeskDiagnosticFixture) -> CheckedFile {
    var packageFile: CheckedPackage?
    if let package = fixture.package {
        let packageTree = Desk.parse(package, file: DeskFileID(path: "package.desk"))
        packageFile = CheckedPackage(file: Desk.check(packageTree, context: deskFixtureContext(fixture, package: nil)))
    }
    return Desk.check(Desk.parse(text, file: DeskFileID(path: fixture.fileName)), context: deskFixtureContext(fixture, package: packageFile))
}

func checkDeskFixture(_ t: TestRunner, _ fixture: DeskDiagnosticFixture) {
    let label = fixture.id
    if fixture.isFolder {
        checkDeskFolderFixture(t, fixture)
        return
    }
    // DK1008 happens before parsing: the bytes are not UTF-8.
    if fixture.generate == "invalidUTF8" {
        let result = Desk.load(Data([0x77, 0x69, 0xFF, 0xFE, 0x20]), fileName: "Test.desk")
        if case .rejected(let d) = result {
            t.equal(d.id, .invalidEncoding, label)
            t.check(!d.message(in: .english).isEmpty && deskMessageLeaks(d.message(in: .simplifiedChinese)).isEmpty, label)
        } else {
            t.check(false, "\(label): invalid UTF-8 was not rejected")
        }
        if let negative = fixture.negative {
            let checked = deskCheckFixtureText(negative, fixture)
            t.equal(deskDiagnosticSummary(checked), [], "\(label) negative")
        }
        return
    }
    let positiveText = fixture.generate.map(deskGeneratedText) ?? fixture.positive
    let checked = deskCheckFixtureText(positiveText, fixture)
    let produced = Set(checked.diagnostics.map(\.id.rawValue))
    let allowed = Set(fixture.expect + fixture.also)
    for id in fixture.expect { t.check(produced.contains(id), "\(label): expected \(id), got \(deskDiagnosticSummary(checked))") }
    for id in produced.subtracting(allowed).sorted() {
        let d = checked.diagnostics.first { $0.id.rawValue == id }!
        t.check(false, "\(label): unexpected \(id) at \(checked.tree.location(of: d.range.lowerBound)): \(d.message(in: .english))")
    }
    // Messages in both languages, without ids.
    for d in checked.diagnostics {
        for language in [DiagnosticLanguage.english, .simplifiedChinese] {
            let message = d.message(in: language)
            t.check(!message.isEmpty, "\(label): empty message for \(d.id.rawValue)")
            let leaks = deskMessageLeaks(message)
            t.check(leaks.isEmpty, "\(label): \(d.id.rawValue) message shows \(leaks): \(message)")
            for f in d.fixIts {
                let title = f.title(in: language)
                t.check(deskMessageLeaks(title).isEmpty && !title.isEmpty, "\(label): fix-it title \(title)")
            }
        }
    }
    // Fix-its of the expected diagnostic: applied, the diagnostic is gone and no new error appears.
    if fixture.generate == nil {
        let before = checked.diagnostics
        let errorsBefore = Set(before.filter { $0.severity == .error }.map(\.id.rawValue))
        for d in before where fixture.expect.contains(d.id.rawValue) {
            for f in d.fixIts {
                let edits = f.edits.filter { $0.file == checked.tree.file }
                guard !edits.isEmpty else { continue }
                let fixed = TextEdit.apply(edits, to: checked.tree.text)
                let after = deskCheckFixtureText(fixed, fixture)
                let countBefore = before.filter { $0.id == d.id }.count
                let countAfter = after.diagnostics.filter { $0.id == d.id }.count
                t.check(countAfter < countBefore, "\(label): fix-it \(f.titleKey) left \(d.id.rawValue): \(fixed.debugDescription)")
                let newErrors = Set(after.diagnostics.filter { $0.severity == .error }.map(\.id.rawValue)).subtracting(errorsBefore)
                t.check(newErrors.isEmpty || fixture.fixItsMayIntroduceErrors, "\(label): fix-it \(f.titleKey) brought \(newErrors.sorted()): \(fixed.debugDescription)")
            }
        }
    }
    // The corrected code is clean.
    if let negative = fixture.negative {
        let clean = deskCheckFixtureText(negative, fixture)
        let left = clean.diagnostics.filter { !fixture.negativeAlso.contains($0.id.rawValue) }
        t.check(left.isEmpty, "\(label) negative: \(left.map { "\($0.id.rawValue)@\(clean.tree.location(of: $0.range.lowerBound)): \($0.message(in: .english))" })")
    }
}

// MARK: - Folder fixtures

/// A PNG of this size: its signature, header and end, with no pixels (the loader reads only the header).
func deskPNG(width: Int, height: Int) -> Data {
    func crc(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return c ^ 0xFFFF_FFFF
    }
    func be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + body
        return be(body.count) + typed + be(Int(crc(typed)))
    }
    let header = be(width) + be(height) + [8, 6, 0, 0, 0]
    return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", header) + chunk("IEND", []))
}

/// The folder a folder fixture describes, with `text` as the fixture's own file.
func deskFixtureFolder(_ fixture: DeskDiagnosticFixture, text: String, negative: Bool,
                       edited: [String: String] = [:]) -> InMemoryPackageSource {
    var source = InMemoryPackageSource()
    var texts: [(String, String)] = [(fixture.fileName, text)]
    if let package = fixture.package, fixture.fileName != "package.desk" { texts.append(("package.desk", package)) }
    let files = negative ? (fixture.negativeFolderFiles ?? fixture.folderFiles) : fixture.folderFiles
    texts += files.map { ($0.name, $0.text) }
    for (name, text) in texts { source.add(name, text: edited[name] ?? text) }
    for asset in negative ? (fixture.negativeAssets ?? fixture.assets) : fixture.assets {
        source.add(asset.path, .file(deskPNG(width: asset.width, height: asset.height)))
    }
    for link in negative ? fixture.negativeLinks : fixture.links { source.add(link.path, .link(link.destination)) }
    if !negative {
        switch fixture.folderGenerate {
        case "manyFiles"?:
            for i in 1...2_001 { source.add(String(format: "notes/n%04d.txt", i), text: "note \(i)") }
        case "largeFolder"?:
            source.add("clip.mov", .file(Data(count: 101 * 1_048_576)))
        default:
            break
        }
    }
    return source
}

func deskCheckFixtureFolder(_ source: InMemoryPackageSource, _ fixture: DeskDiagnosticFixture) -> CheckedDeskPackage {
    var context = deskFixtureContext(fixture, package: nil)
    context.resources = nil
    let package = (try? PackageLoader.load(source)) ?? DeskPackage()
    return CheckedDeskPackage(package: package, context: context)
}

func deskFolderSummary(_ checked: CheckedDeskPackage) -> [String] {
    checked.allDiagnostics.map { "\($0.id.rawValue)@\($0.file.path):\($0.range.lowerBound)" }
}

func checkDeskFolderFixture(_ t: TestRunner, _ fixture: DeskDiagnosticFixture) {
    let label = fixture.id
    let source = deskFixtureFolder(fixture, text: fixture.positive, negative: false)
    let checked = deskCheckFixtureFolder(source, fixture)
    let all = checked.allDiagnostics
    let produced = Set(all.map(\.id.rawValue))
    let allowed = Set(fixture.expect + fixture.also)
    for id in fixture.expect { t.check(produced.contains(id), "\(label): expected \(id), got \(deskFolderSummary(checked))") }
    for id in produced.subtracting(allowed).sorted() {
        let d = all.first { $0.id.rawValue == id }!
        t.check(false, "\(label): unexpected \(id) in \(d.file.path): \(d.message(in: .english))")
    }
    for d in all {
        for language in [DiagnosticLanguage.english, .simplifiedChinese] {
            let message = d.message(in: language)
            t.check(!message.isEmpty && deskMessageLeaks(message).isEmpty, "\(label): \(d.id.rawValue) message: \(message)")
            for note in d.notes {
                let text = note.message(in: language)
                t.check(!text.isEmpty && text != note.messageKey && deskMessageLeaks(text).isEmpty, "\(label): note \(text)")
            }
            for f in d.fixIts {
                let title = f.title(in: language)
                t.check(deskMessageLeaks(title).isEmpty && !title.isEmpty, "\(label): fix-it title \(title)")
            }
        }
    }
    // Fix-its of the expected diagnostic, applied to the folder's texts.
    let errorsBefore = Set(all.filter { $0.severity == .error }.map(\.id.rawValue))
    for d in all where fixture.expect.contains(d.id.rawValue) {
        for f in d.fixIts where !f.edits.isEmpty {
            var edited: [String: String] = [:]
            for (file, edits) in Dictionary(grouping: f.edits, by: \.file) {
                guard let text = checked.package.texts[file] else { continue }
                edited[file.path] = TextEdit.apply(edits, to: text)
            }
            let after = deskCheckFixtureFolder(deskFixtureFolder(fixture, text: fixture.positive, negative: false, edited: edited), fixture)
            let countBefore = all.filter { $0.id == d.id }.count
            let countAfter = after.allDiagnostics.filter { $0.id == d.id }.count
            t.check(countAfter < countBefore, "\(label): fix-it \(f.titleKey) left \(d.id.rawValue)")
            let newErrors = Set(after.allDiagnostics.filter { $0.severity == .error }.map(\.id.rawValue)).subtracting(errorsBefore)
            t.check(newErrors.isEmpty, "\(label): fix-it \(f.titleKey) brought \(newErrors.sorted())")
        }
    }
    if let negative = fixture.negative {
        let clean = deskCheckFixtureFolder(deskFixtureFolder(fixture, text: negative, negative: true), fixture)
        let left = clean.allDiagnostics.filter { !fixture.negativeAlso.contains($0.id.rawValue) }
        t.check(left.isEmpty, "\(label) negative: \(left.map { "\($0.id.rawValue)@\($0.file.path): \($0.message(in: .english))" })")
    }
}
