import Foundation
@testable import DeskLanguage

// Navigation in the language service: the symbol index, go to definition, find references, highlights, rename,
// the outline, folding ranges and the element at a position. Golden results on the acceptance widgets and the
// Harbor package; properties on the diagnostic fixtures and a sweep of every request at every name of the corpus.
//
// `DESK_NAV_DUMP=path/to/file.desk` prints what the service finds at every name of a file (to write goldens);
// `DESK_NAV_POSITIVE=1` also renames every name of the fixtures' positive parts and reports what changed (their code
// is wrong on purpose, so a rename may fix or reveal a problem).

/// A service for one file, alone or in a folder of texts.
func deskNavService(_ text: String, file: String = "Test.desk", others: [String: String] = [:],
                    language: DiagnosticLanguage = .english) -> DeskLanguageService {
    var files = [DeskFileID(path: file): text]
    for (path, other) in others { files[DeskFileID(path: path)] = other }
    return DeskLanguageService(openFile: DeskFileID(path: file), files: files,
                               options: DeskServiceOptions(messageLanguage: language))
}

/// The position of the `occurrence`-th (1-based) `needle` in the snapshot's text, `into` UTF-16 units into it.
func deskNavPosition(_ snapshot: DeskSnapshot, _ needle: String, occurrence: Int = 1, into: Int = 0) -> DeskPosition {
    let text = snapshot.text as NSString
    var from = 0
    var found = NSRange(location: NSNotFound, length: 0)
    for _ in 0..<occurrence {
        found = text.range(of: needle, options: [], range: NSRange(location: from, length: text.length - from))
        if found.location == NSNotFound { return snapshot.index.position(utf16: 0) }
        from = found.location + max(1, found.length)
    }
    return snapshot.index.position(utf16: found.location + into)
}

/// `file line:column text` (1-based), the text being what the range covers.
func deskNavDescribe(_ location: DeskLocation, texts: [DeskFileID: String]) -> String {
    let text = (texts[location.file] ?? "") as NSString
    let r = location.range
    let covered = r.end.offset <= text.length ? text.substring(with: r.nsRange) : "?"
    return "\(location.file.path) \(r.start.line + 1):\(r.start.column + 1) \(covered)"
}

func deskNavDescribe(_ locations: [DeskLocation], _ snapshot: DeskSnapshot) -> [String] {
    locations.map { deskNavDescribe($0, texts: snapshot.folder) }
}

/// Every name-like token of a file (identifiers, keywords used as names, the text of strings), with its UTF-8
/// range: the places the sweep asks about.
func deskNavTokenStarts(_ tree: SyntaxTree) -> [Range<Int>] {
    var out: [Range<Int>] = []
    tree.root.walkTokens { token, at in
        guard !token.isMissing else { return true }
        switch token.kind {
        case .identifier, .invalidIdentifier, .stringText, .number, .eventKeyword:
            let start = at + token.leadingTrivia.utf8Length
            out.append(start..<(start + token.text.utf8.count))
        default:
            break
        }
        return true
    }
    return out
}

private func deskNavDump(_ path: String) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); return }
    let folder = (path as NSString).deletingLastPathComponent
    var others: [String: String] = [:]
    if FileManager.default.fileExists(atPath: folder + "/package.desk") {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".desk") {
            others[name] = try? String(contentsOfFile: folder + "/" + name, encoding: .utf8)
        }
    }
    let snapshot = deskNavService(text, file: (path as NSString).lastPathComponent, others: others).snapshot
    for token in deskNavTokenStarts(snapshot.tree) {
        let position = snapshot.index.position(utf8: token.lowerBound)
        guard let info = snapshot.symbol(at: position) else { continue }
        let definition = deskNavDescribe(snapshot.definition(at: position), snapshot)
        let references = deskNavDescribe(snapshot.references(at: position), snapshot)
        print("\(position) \(info.name) \(info.kind.rawValue) \(info.role.rawValue) \(info.catalogPath.map { "\($0)" } ?? "")")
        if !definition.isEmpty { print("    definition: \(definition.joined(separator: " | "))") }
        if !references.isEmpty { print("    references: \(references.joined(separator: " | "))") }
    }
    print(snapshot.documentSymbols().map(\.description).joined(separator: "\n"))
    print(snapshot.foldingRanges().map(\.description).joined(separator: ", "))
}

func runDeskNavigationTests(_ t: TestRunner) {
    if let path = ProcessInfo.processInfo.environment["DESK_NAV_DUMP"] {
        deskNavDump(path)
        return
    }
    runDeskNavigationPropertyTests(t)
}

/// Every place a file writes an own name, found from the tree alone (independently of the service): declared names
/// (declarations, loop variables, `.name(…)`, styles, options), bare names spelled like a declared value name
/// (never a call's callee), the name after `options.`, the argument of `.style(…)` and the targets of assignments.
/// `packageStyles` and `packageOptions` are the package's, which the file may use.
func deskNavOwnNameSites(_ tree: SyntaxTree, packageStyles: Set<String> = [], packageOptions: Set<String> = []) -> [(range: Range<Int>, name: String)] {
    let table = DeskNodeTable(tree: tree)
    var valueNames = Set<String>()
    var styleNames = packageStyles
    var optionNames = packageOptions
    var elementNames = Set<String>()
    var sites: [Range<Int>: String] = [:]
    for entry in table.entries {
        let node = entry.positioned
        switch entry.kind {
        case .declaration:
            let tokens = node.childTokens
            if tokens.count >= 2, tokens[1].kind == .identifier { valueNames.insert(tokens[1].token.name); sites[tokens[1].textRange] = tokens[1].token.name }
        case .forStmt:
            let tokens = node.childTokens
            if tokens.count >= 2, tokens[1].kind == .identifier { valueNames.insert(tokens[1].token.name); sites[tokens[1].textRange] = tokens[1].token.name }
        case .styleDecl:
            let tokens = node.childTokens
            if tokens.count >= 2, tokens[1].kind == .identifier { styleNames.insert(tokens[1].token.name); sites[tokens[1].textRange] = tokens[1].token.name }
        case .optionDecl:
            if let target = node.firstChild(.target) {
                let token = TargetSyntax(unchecked: target).name
                if token.kind == .identifier { optionNames.insert(token.token.name); sites[token.textRange] = token.token.name }
            }
        case .modifierApp:
            let modifier = ModifierAppSyntax(unchecked: node)
            guard ["name", "style"].contains(modifier.name.token.text),
                  let value = modifier.arguments?.arguments.first(where: { $0.label == nil })?.value.node,
                  let (range, name) = DeskSymbolIndex.ownName(in: value) else { continue }
            if modifier.name.token.text == "name" { elementNames.insert(name); valueNames.insert(name) }
            sites[range] = name
        default:
            break
        }
    }
    for (i, entry) in table.entries.enumerated() {
        let node = entry.positioned
        let parent = entry.parent >= 0 ? table.entries[entry.parent] : entry
        switch entry.kind {
        case .identifierExpr:
            let token = IdentifierExprSyntax(unchecked: node).token
            guard token.kind == .identifier, valueNames.contains(token.token.name) else { continue }
            // Not the callee of a call, and not the base of `Type.case`.
            if parent.kind == .callExpr, table.children(of: entry.parent).first == i { continue }
            sites[token.textRange] = token.token.name
        case .memberExpr:
            let tokens = node.childTokens
            guard let base = table.children(of: i).first, table.entries[base].kind == .identifierExpr,
                  IdentifierExprSyntax(unchecked: table.entries[base].positioned).name == "options",
                  let name = tokens.last, name.kind == .identifier, optionNames.contains(name.token.name) else { continue }
            sites[name.textRange] = name.token.name
        case .target:
            guard parent.kind == .assignment else { continue }
            let target = TargetSyntax(unchecked: node)
            if target.path.count == 1, valueNames.contains(target.name.token.name) {
                sites[target.name.textRange] = target.name.token.name
            } else if target.path.count == 2, target.path[0] == "options", let member = target.members.first,
                      optionNames.contains(member.token.name) {
                sites[member.textRange] = member.token.name
            }
        case .stringLiteral:
            // `show("details")`: a quoted element name.
            guard parent.kind == .argument, entry.parent >= 0, table.entries[entry.parent].parent >= 0 else { continue }
            let clause = table.entries[entry.parent].parent
            let call = table.entries[clause].parent
            guard call >= 0, table.entries[call].kind == .callStmt || table.entries[call].kind == .callExpr,
                  let calleeIndex = table.children(of: call).first else { continue }
            let callee = String(decoding: tree.text.utf8.dropFirst(table.entries[calleeIndex].textStart)
                .prefix(table.entries[calleeIndex].textEnd - table.entries[calleeIndex].textStart), as: UTF8.self)
            guard ["show", "hide", "showOrHide"].contains(callee), let (range, name) = DeskSymbolIndex.ownName(in: node),
                  elementNames.contains(name) else { continue }
            sites[range] = name
        default:
            break
        }
    }
    return sites.map { ($0.key, $0.value) }.sorted { $0.range.lowerBound < $1.range.lowerBound }
}

/// The own-name property on one text: every own-name site has a definition, and the references of each definition
/// (asked in the file that holds it) contain the site.
func deskNavCheckOwnNames(_ t: TestRunner, _ text: String, file: String = "Test.desk", package: String?, label: String) {
    let others = package.map { ["package.desk": $0] } ?? [:]
    let snapshot = deskNavService(text, file: file, others: others).snapshot
    let names = snapshot.packageNames
    var packageSnapshot: DeskSnapshot?
    for site in deskNavOwnNameSites(snapshot.tree, packageStyles: names.styles, packageOptions: names.options) {
        let position = snapshot.index.position(utf8: site.range.lowerBound)
        let here = DeskLocation(file: snapshot.file, range: snapshot.index.range(utf8: site.range))
        let definitions = snapshot.definition(at: position)
        guard !definitions.isEmpty else {
            t.check(false, "\(label) \(position) \(site.name): no definition")
            continue
        }
        for definition in definitions {
            let references: [DeskLocation]
            if definition.file == snapshot.file {
                references = snapshot.references(at: definition.range.start)
            } else if definition.file == snapshot.packageFile, let package {
                if packageSnapshot == nil { packageSnapshot = deskNavService(package, file: "package.desk", others: [file: text]).snapshot }
                references = packageSnapshot!.references(at: definition.range.start)
            } else {
                t.check(false, "\(label) \(position) \(site.name): definition in \(definition.file.path)")
                continue
            }
            t.check(references.contains(here), "\(label) \(position) \(site.name): not among the references of \(definition)")
        }
    }
}

func runDeskNavigationPropertyTests(_ t: TestRunner) {
    t.suite("Desk: service — every own name finds its definition") {
        for file in deskFixtureFiles("Acceptance") {
            deskNavCheckOwnNames(t, file.text, file: (file.path as NSString).lastPathComponent, package: nil, label: file.path)
        }
        for file in deskFixtureFiles("Diagnostics") {
            let fixture = DeskDiagnosticFixture.parse(path: file.path, text: file.text)
            guard let negative = fixture.negative, fixture.generate == nil else { continue }
            deskNavCheckOwnNames(t, negative, file: fixture.fileName,
                                 package: fixture.fileName == "package.desk" ? nil : fixture.package, label: fixture.id)
        }
    }

    t.suite("Desk: service — rename keeps the meaning") {
        var renamed = 0
        for file in deskFixtureFiles("Acceptance") {
            renamed += deskNavCheckRenames(t, file.text, file: (file.path as NSString).lastPathComponent, package: nil, label: file.path)
        }
        for file in deskFixtureFiles("Diagnostics") {
            let fixture = DeskDiagnosticFixture.parse(path: file.path, text: file.text)
            guard let negative = fixture.negative, fixture.generate == nil else { continue }
            renamed += deskNavCheckRenames(t, negative, file: fixture.fileName,
                                           package: fixture.fileName == "package.desk" ? nil : fixture.package, label: fixture.id)
        }
        t.check(renamed > 100, "renamed \(renamed) names")
        if ProcessInfo.processInfo.environment["DESK_NAV_POSITIVE"] != nil {
            for file in deskFixtureFiles("Diagnostics") {
                let fixture = DeskDiagnosticFixture.parse(path: file.path, text: file.text)
                guard fixture.generate == nil else { continue }
                deskNavCheckRenames(t, fixture.positive, file: fixture.fileName,
                                    package: fixture.fileName == "package.desk" ? nil : fixture.package, label: fixture.id + "+")
            }
        }
    }
}

/// The own names of a checked text in document order, each as (kind, role, which name it is): equal before and
/// after a rename when the rename kept what every name means.
func deskNavStructure(_ snapshot: DeskSnapshot) -> [String] {
    var order: [DeskSymbolKey: Int] = [:]
    var out: [String] = []
    for occurrence in snapshot.symbolIndex.names where occurrence.kind.isOwnName {
        guard let key = occurrence.key else { out.append("\(occurrence.kind.rawValue) \(occurrence.role.rawValue) ?"); continue }
        if order[key] == nil { order[key] = order.count }
        out.append("\(occurrence.kind.rawValue) \(occurrence.role.rawValue) \(order[key]!)")
    }
    return out
}

/// The ids of diagnostics, sorted (their messages may quote the renamed name).
func deskNavIDs(_ diagnostics: [DeskServiceDiagnostic]) -> [String] {
    diagnostics.map { "\($0.id.rawValue) \($0.severity.rawValue)" }.sorted()
}

/// Renames every own name a text declares, one at a time, and checks that the result re-checks with the same
/// diagnostics and the same structure of names. Returns how many renames were made.
@discardableResult
func deskNavCheckRenames(_ t: TestRunner, _ text: String, file: String = "Test.desk", package: String?, label: String) -> Int {
    let others = package.map { ["package.desk": $0] } ?? [:]
    let service = deskNavService(text, file: file, others: others)
    let snapshot = service.snapshot
    let before = deskNavStructure(snapshot)
    let beforeIDs = deskNavIDs(snapshot.diagnostics)
    var count = 0
    for occurrence in snapshot.symbolIndex.names where occurrence.kind.isOwnName && occurrence.role == .declaration {
        let position = snapshot.index.position(utf8: occurrence.range.lowerBound)
        let newName = "renamed\(count)Name"
        guard case .success(let rename) = snapshot.rename(at: position, to: newName) else {
            // Refused: a name written the way another language writes it, or one the checker did not accept.
            continue
        }
        count += 1
        let newText = DeskTextEditU16.apply(rename.edit.edits(for: snapshot.file), to: text)
        var newOthers = others
        if let package, !rename.edit.edits(for: snapshot.packageFile).isEmpty {
            newOthers["package.desk"] = DeskTextEditU16.apply(rename.edit.edits(for: snapshot.packageFile), to: package)
        }
        let after = deskNavService(newText, file: file, others: newOthers).snapshot
        let where_ = "\(label) \(occurrence.name) → \(newName)"
        t.equal(deskNavIDs(after.diagnostics), beforeIDs, "\(where_): diagnostics")
        t.equal(deskNavStructure(after), before, "\(where_): names")
        t.check(newText.contains(newName), "\(where_): the new name is written")
    }
    return count
}
