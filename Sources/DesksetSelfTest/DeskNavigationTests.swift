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
    runDeskNavigationGoldenTests(t)
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

// MARK: - Goldens

/// A fixture's text.
func deskNavFixture(_ path: String) -> String {
    (try? String(contentsOf: deskFixtures.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// The Harbor folder as the service sees it, opened on one of its files.
func deskNavHarbor(_ openFile: String, language: DiagnosticLanguage = .english) -> DeskLanguageService {
    DeskLanguageService(package: deskHarbor(), openFile: DeskFileID(path: openFile),
                        options: DeskServiceOptions(messageLanguage: language))
}

/// What the index says at a needle: `name kind role [catalog path]`.
func deskNavSymbol(_ snapshot: DeskSnapshot, _ needle: String, occurrence: Int = 1, into: Int = 0) -> String {
    guard let info = snapshot.symbol(at: deskNavPosition(snapshot, needle, occurrence: occurrence, into: into)) else { return "nothing" }
    return "\(info.name) \(info.kind.rawValue) \(info.role.rawValue)" + (info.catalogPath.map { " \($0)" } ?? "")
}

func deskNavDefinition(_ snapshot: DeskSnapshot, _ needle: String, occurrence: Int = 1, into: Int = 0) -> [String] {
    deskNavDescribe(snapshot.definition(at: deskNavPosition(snapshot, needle, occurrence: occurrence, into: into)), snapshot)
}

func deskNavReferences(_ snapshot: DeskSnapshot, _ needle: String, occurrence: Int = 1, into: Int = 0,
                       includeDeclaration: Bool = true) -> [String] {
    deskNavDescribe(snapshot.references(at: deskNavPosition(snapshot, needle, occurrence: occurrence, into: into),
                                        includeDeclaration: includeDeclaration), snapshot)
}

func runDeskNavigationGoldenTests(_ t: TestRunner) {
    let monthView = deskNavService(deskNavFixture("Acceptance/MonthView.desk"), file: "MonthView.desk").snapshot
    let cpu = deskNavService(deskNavFixture("Acceptance/CPU.desk"), file: "CPU.desk").snapshot

    t.suite("Desk: service — symbol index") {
        let m = monthView
        t.equal(deskNavSymbol(m, "category"), "category infoField read info.category")
        t.equal(deskNavSymbol(m, ".time", into: 1), "time enumCase read Category.time")
        t.equal(deskNavSymbol(m, "weekStart"), "weekStart option declaration")
        t.equal(deskNavSymbol(m, "Picker"), "Picker control read Picker")
        t.equal(deskNavSymbol(m, "default:"), "default label read")
        t.equal(deskNavSymbol(m, "monthsFromNow"), "monthsFromNow variable declaration")
        t.equal(deskNavSymbol(m, "month ="), "month computed declaration")
        t.equal(deskNavSymbol(m, "calendar"), "calendar namespace read calendar")
        t.equal(deskNavSymbol(m, ".month(", into: 1), "month member read calendar.month")
        t.equal(deskNavSymbol(m, "options.weekStart", into: 1), "options namespace read options")
        t.equal(deskNavSymbol(m, "options.weekStart", into: 9), "weekStart option read")
        t.equal(deskNavSymbol(m, "Column"), "Column component read Column")
        t.equal(deskNavSymbol(m, "spacing"), "spacing label read")
        t.equal(deskNavSymbol(m, "month.title", into: 6), "title member read MonthGrid.title")
        t.equal(deskNavSymbol(m, ".font", into: 1), "font modifier read .font")
        t.equal(deskNavSymbol(m, "monthsFromNow = 0", occurrence: 2), "monthsFromNow variable write")
        t.equal(deskNavSymbol(m, "arrow"), "arrow style read")
        t.equal(deskNavSymbol(m, "name in"), "name loopVariable declaration")
        t.equal(deskNavSymbol(m, "Text(name)", into: 5), "name loopVariable read")
        t.equal(deskNavSymbol(m, "day.isToday", into: 4), "isToday member read DayCell.isToday")
        t.equal(deskNavSymbol(m, "style todayCell", into: 6), "todayCell style declaration")
        t.equal(deskNavSymbol(m, "\"Month View\": ", into: 3), "Month View translationKey declaration")
        t.equal(deskNavSymbol(m, "\"Highlight color\"", into: 1), "Highlight color translationKey read")
        t.equal(deskNavSymbol(m, "Column(spacing: 12)", into: 17), "nothing", "a number without a unit")
        t.equal(deskNavSymbol(m, "variable"), "nothing", "a keyword")
        t.equal(deskNavSymbol(m, "monthsFromNow", into: 13), "monthsFromNow variable declaration", "right after the name")
        let units = deskNavService("widget { Text(\"A\").padding(12pt).every(2s) { } }").snapshot
        t.equal(deskNavSymbol(units, "pt"), "pt unit read")
        t.equal(deskNavSymbol(units, "2s", into: 1), "s unit read")
        let files = deskNavHarbor("Tide.desk").snapshot
        t.equal(deskNavSymbol(files, "images/waves.png", into: 2), "images/waves.png asset read")
        t.equal(deskNavSymbol(files, "\"Look\"", into: 1), "Look translationKey read", "an option's label")
        t.equal(deskNavSymbol(files, "heading"), "heading style read")
        t.equal(deskNavSymbol(files, "accent ="), "accent option declaration")
        for info in [cpu.symbol(at: deskNavPosition(cpu, "cpu.usage", into: 5))] {
            t.equal(info?.kind, .member)
            t.equal(info?.catalogPath, .member(namespace: "cpu", name: "usage"))
            t.equal(info.map { cpu.index.utf8Range(of: $0.range) }.map { cpu.text.utf8.dropFirst($0.lowerBound).prefix($0.count) }
                .map { String(decoding: $0, as: UTF8.self) }, "usage")
        }
    }

    t.suite("Desk: service — definition") {
        let m = monthView
        t.equal(deskNavDefinition(m, "monthsFromNow = 0", occurrence: 2), ["MonthView.desk 15:14 monthsFromNow"])
        t.equal(deskNavDefinition(m, "monthsFromNow - 1", into: 3), ["MonthView.desk 15:14 monthsFromNow"])
        t.equal(deskNavDefinition(m, "monthsFromNow", into: 5), ["MonthView.desk 15:14 monthsFromNow"], "at the declaration")
        t.equal(deskNavDefinition(m, "month.days"), ["MonthView.desk 16:14 month"])
        t.equal(deskNavDefinition(m, "day.isToday"), ["MonthView.desk 32:17 day"])
        t.equal(deskNavDefinition(m, "{day.number}", into: 1), ["MonthView.desk 32:17 day"], "inside an interpolation")
        t.equal(deskNavDefinition(m, "Text(name)", into: 5), ["MonthView.desk 29:17 name"])
        t.equal(deskNavDefinition(m, "todayCell"), ["MonthView.desk 48:7 todayCell"])
        t.equal(deskNavDefinition(m, "arrow", occurrence: 2), ["MonthView.desk 45:7 arrow"])
        t.equal(deskNavDefinition(m, "options.highlight", occurrence: 3, into: 8), ["MonthView.desk 11:5 highlight"],
                "an option read in a style")
        t.equal(deskNavDefinition(m, "\"Month View\"", into: 2), ["MonthView.desk 52:9 \"Month View\""], "a text's translation")
        t.equal(deskNavDefinition(m, "\"Week starts on\"", into: 2), ["MonthView.desk 54:9 \"Week starts on\""])
        t.equal(deskNavDefinition(m, "calendar"), [], "a built-in name")
        t.equal(deskNavDefinition(m, ".font", into: 1), [])
        t.equal(deskNavDefinition(m, "Column"), [])
        t.equal(deskNavDefinition(m, "widget"), [], "a keyword")
        t.equal(deskNavDefinition(cpu, "cpu"), [])
        t.equal(deskNavDefinition(cpu, "\"CPU\"", into: 1), [], "no translations")
        // Element names, a loop variable in show(), and a quoted element name.
        let named = deskNavService("""
            info { name: "T" }
            widget {
                variable isOpen = false
                Column {
                    Text("Title").name(title).onClick { showOrHide(details) }
                    Text("Details").name(details)
                    for label in ["a", "b"] {
                        Button(label).onClick { show(label); hide("title"); showOrHide(isOpen) }
                    }
                }
            }
            """).snapshot
        t.equal(deskNavDefinition(named, "showOrHide(details)", into: 11), ["Test.desk 6:30 details"])
        t.equal(deskNavDefinition(named, "hide(\"title\")", into: 7), ["Test.desk 5:28 title"])
        t.equal(deskNavDefinition(named, "show(label)", into: 5), ["Test.desk 7:13 label"])
        t.equal(deskNavDefinition(named, "showOrHide(isOpen)", into: 11), ["Test.desk 3:14 isOpen"])
        t.equal(deskNavReferences(named, "name(title)", into: 5), ["Test.desk 5:28 title", "Test.desk 8:56 title"])
    }

    t.suite("Desk: service — references and highlights") {
        let m = monthView
        let months = ["15:14", "16:45", "23:28", "25:57", "25:73", "26:58", "26:74"].map { "MonthView.desk \($0) monthsFromNow" }
        t.equal(deskNavReferences(m, "monthsFromNow"), months)
        t.equal(deskNavReferences(m, "monthsFromNow + 1", into: 2), months, "from a use")
        t.equal(deskNavReferences(m, "monthsFromNow", includeDeclaration: false), Array(months.dropFirst()))
        let highlights = m.documentHighlights(at: deskNavPosition(m, "monthsFromNow"))
        t.equal(highlights.map(\.role), [.declaration, .read, .write, .write, .read, .write, .read])
        t.equal(highlights.map { "\($0.range.start)" }, ["15:14", "16:45", "23:28", "25:57", "25:73", "26:58", "26:74"])
        t.equal(deskNavReferences(m, "day.isToday"), ["32:17", "33:24", "35:43", "36:37"].map { "MonthView.desk \($0) day" })
        t.equal(deskNavReferences(m, "todayCell"), ["MonthView.desk 35:28 todayCell", "MonthView.desk 48:7 todayCell"])
        t.equal(deskNavReferences(m, "highlight ="),
                ["11:5", "22:41", "45:67", "48:85"].map { "MonthView.desk \($0) highlight" })
        t.equal(deskNavReferences(m, "\"Week starts on\"", into: 1),
                ["MonthView.desk 10:24 \"Week starts on\"", "MonthView.desk 54:9 \"Week starts on\""])
        t.equal(deskNavReferences(m, ".color", into: 1).count, 5, "a modifier's uses")
        t.equal(deskNavReferences(m, "variable"), [], "a keyword")
        t.equal(m.documentHighlights(at: deskNavPosition(m, "12)")), [], "a number")
        t.equal(deskNavReferences(cpu, "cpu"), ["CPU.desk 6:16 cpu", "CPU.desk 8:18 cpu"])
        t.equal(deskNavReferences(cpu, "usage"), ["CPU.desk 6:20 usage", "CPU.desk 8:22 usage"])
        t.equal(deskNavReferences(cpu, "\"CPU\"", into: 1), ["CPU.desk 1:14 \"CPU\"", "CPU.desk 5:14 \"CPU\""],
                "the same text twice")
        t.equal(deskNavReferences(cpu, "Text", occurrence: 2), ["CPU.desk 5:9 Text", "CPU.desk 6:9 Text"])
    }

    t.suite("Desk: service — definition and references across the package") {
        let tide = deskNavHarbor("Tide.desk").snapshot
        t.equal(deskNavDefinition(tide, "heading"), ["package.desk 20:7 heading"], "a package style")
        t.equal(deskNavDefinition(tide, "options.metric", into: 9), ["package.desk 14:9 metric"], "a package option")
        t.equal(deskNavDefinition(tide, "options.accent", into: 9), ["Tide.desk 13:5 accent", "package.desk 12:5 accent"],
                "a widget's option in place of the package's (D99): both")
        t.equal(deskNavDefinition(tide, "accent ="), ["Tide.desk 13:5 accent", "package.desk 12:5 accent"])
        t.equal(deskNavDefinition(tide, "images/waves.png", into: 2), ["images/waves.png 1:1 "], "a picture")
        t.equal(deskNavDefinition(tide, "\"Tide\"", into: 1), ["Tide.desk 29:9 \"Tide\"", "package.desk 30:9 \"Tide\""],
                "the widget's translation, then the package's")
        t.equal(deskNavReferences(tide, "card"),
                ["Tide.desk 24:12 card", "package.desk 19:7 card", "Lamp.desk 20:12 card", "Radio.desk 23:12 card"])
        t.equal(deskNavReferences(tide, "card", includeDeclaration: false),
                ["Tide.desk 24:12 card", "Lamp.desk 20:12 card", "Radio.desk 23:12 card"])
        t.equal(deskNavReferences(tide, "options.accent", into: 9),
                ["Tide.desk 13:5 accent", "Tide.desk 19:89 accent", "package.desk 12:5 accent", "package.desk 20:48 accent"])
        t.equal(deskNavReferences(tide, "showWaves"), ["9:5", "12:33", "22:37"].map { "Tide.desk \($0) showWaves" },
                "the widget's own option stays in the widget")
        t.equal(deskNavReferences(tide, "images/waves.png", into: 2), ["Tide.desk 20:39 \"images/waves.png\""])
        t.equal(tide.documentHighlights(at: deskNavPosition(tide, "card")).map { "\($0.range.start) \($0.role.rawValue)" },
                ["24:12 read"], "highlights stay in the open file")

        let package = deskNavHarbor("package.desk").snapshot
        t.equal(deskNavDefinition(package, "heading"), ["package.desk 20:7 heading"])
        t.equal(deskNavDefinition(package, "options.accent", into: 9), ["package.desk 12:5 accent"])
        t.equal(deskNavReferences(package, "heading"),
                ["package.desk 20:7 heading", "Lamp.desk 16:28 heading", "Radio.desk 18:66 heading", "Tide.desk 18:28 heading"])
        t.equal(deskNavReferences(package, "accent"),
                ["package.desk 12:5 accent", "package.desk 20:48 accent", "Tide.desk 13:5 accent", "Tide.desk 19:89 accent"])
        t.equal(deskNavReferences(package, "metric"), ["package.desk 14:9 metric", "Tide.desk 19:22 metric"])
        t.equal(deskNavDefinition(package, "\"Tide\"", into: 1), ["package.desk 30:9 \"Tide\""])
        t.equal(deskNavReferences(package, "\"Tide\"", into: 1),
                ["package.desk 30:9 \"Tide\"", "Tide.desk 2:11 \"Tide\"", "Tide.desk 18:14 \"Tide\"", "Tide.desk 29:9 \"Tide\""])

        let lamp = deskNavHarbor("Lamp.desk").snapshot
        t.equal(deskNavDefinition(lamp, "images/paper.jpg", into: 2), ["images/paper.jpg 1:1 "])
        t.equal(deskNavDefinition(lamp, "\"Lamp\"", into: 1), [], "no translation of this text")
        t.equal(deskNavDefinition(lamp, "clicks + 1"), ["Lamp.desk 14:11 clicks"])
        // A picture the folder does not have.
        let missing = deskNavService("widget { Image(\"images/none.png\") }", file: "W.desk").snapshot
        t.equal(deskNavDefinition(missing, "none", into: 1), ["images/none.png 1:1 "], "without the folder's files: the path")
        let service = DeskLanguageService(openFile: DeskFileID(path: "W.desk"), files: [DeskFileID(path: "W.desk"): missing.text],
                                          resources: PackageResources(package: deskHarbor()))
        t.equal(deskNavDefinition(service.snapshot, "none", into: 1), [], "the folder has no such picture")
    }

    t.suite("Desk: service — rename") {
        let m = monthView
        func refusal(_ snapshot: DeskSnapshot, _ needle: String, occurrence: Int = 1, into: Int = 0, to newName: String? = nil) -> String {
            let position = deskNavPosition(snapshot, needle, occurrence: occurrence, into: into)
            if let newName {
                if case .failure(let r) = snapshot.rename(at: position, to: newName) { return r.reason.rawValue }
                return "renamed"
            }
            if case .failure(let r) = snapshot.prepareRename(at: position) { return r.reason.rawValue }
            return "allowed"
        }
        // What can be renamed.
        if case .success(let place) = m.prepareRename(at: deskNavPosition(m, "monthsFromNow + 1", into: 4)) {
            t.equal(place.name, "monthsFromNow")
            t.equal(place.kind, .variable)
            t.equal("\(place.range)", "26:74-26:87")
        } else {
            t.check(false, "monthsFromNow can be renamed")
        }
        t.equal(refusal(m, "day.isToday"), "allowed", "a loop variable")
        t.equal(refusal(m, "todayCell"), "allowed", "a style")
        t.equal(refusal(m, "weekStart"), "allowed", "an option")
        t.equal(refusal(m, "calendar"), "builtIn")
        t.equal(refusal(m, ".font", into: 1), "builtIn")
        t.equal(refusal(m, "Column"), "builtIn")
        t.equal(refusal(m, "spacing"), "builtIn", "a label")
        t.equal(refusal(m, "\"Month View\"", into: 3), "insideText")
        t.equal(refusal(m, "chevron.left", into: 2), "insideText", "text no translation keys")
        t.equal(refusal(m, "variable"), "notAName")
        t.equal(refusal(m, "12)"), "notAName")
        t.equal(refusal(m, "Row {", into: 4), "notAName", "punctuation")
        t.equal(refusal(m, "month.title", into: 6), "builtIn", "a field of a record")
        // Messages in both languages.
        let chinese = deskNavService(m.text, file: "MonthView.desk", language: .simplifiedChinese).snapshot
        if case .failure(let r) = chinese.prepareRename(at: deskNavPosition(chinese, "calendar")) {
            t.equal(r.message, "“calendar”是内置的名字，只能给自己起的名字改名。")
            t.equal(deskMessageLeaks(r.message), [])
        }
        if case .failure(let r) = m.prepareRename(at: deskNavPosition(m, "calendar")) {
            t.equal(r.message, "“calendar” is a built-in name. Only names you gave can be renamed.")
        }
        // New names the checker would not take.
        t.equal(refusal(m, "monthsFromNow", to: "Offset"), "invalidName", "a capital first letter")
        t.equal(refusal(m, "monthsFromNow", to: "9lives"), "invalidName")
        t.equal(refusal(m, "monthsFromNow", to: "my-offset"), "invalidName")
        t.equal(refusal(m, "monthsFromNow", to: "页码"), "invalidName")
        t.equal(refusal(m, "monthsFromNow", to: "if"), "reservedWord")
        t.equal(refusal(m, "monthsFromNow", to: "event"), "reservedWord")
        t.equal(refusal(m, "monthsFromNow", to: "widget"), "reservedWord")
        t.equal(refusal(m, "todayCell", to: "style"), "reservedWord")
        t.equal(refusal(m, "monthsFromNow", to: String(repeating: "a", count: 129)), "tooLong")
        t.equal(refusal(m, "monthsFromNow", to: "cpu"), "hidesBuiltIn")
        t.equal(refusal(m, "monthsFromNow", to: "month"), "alreadyUsed")
        t.equal(refusal(m, "day.isToday", to: "name"), "alreadyUsed", "Desk.apply refuses any name the file writes, even out of sight")
        t.equal(refusal(m, "day.isToday", to: "monthsFromNow"), "alreadyUsed")
        t.equal(refusal(m, "todayCell", to: "dateCell"), "alreadyUsed")
        t.equal(refusal(m, "weekStart", to: "highlight"), "alreadyUsed")
        t.equal(refusal(m, "todayCell", to: "cpu"), "renamed", "a style is read only in .style(…)")
        t.equal(refusal(m, "todayCell", to: "todayCell"), "renamed", "the same name: nothing to do")

        // Renames and their results.
        func renamed(_ snapshot: DeskSnapshot, _ needle: String, occurrence: Int = 1, into: Int = 0, to newName: String) -> (String, DeskRename)? {
            guard case .success(let rename) = snapshot.rename(at: deskNavPosition(snapshot, needle, occurrence: occurrence, into: into),
                                                              to: newName) else {
                t.check(false, "\(needle) is renamed to \(newName)")
                return nil
            }
            return (DeskTextEditU16.apply(rename.edit.edits(for: snapshot.file), to: snapshot.text), rename)
        }
        if let (text, rename) = renamed(m, "monthsFromNow", to: "offset") {
            t.equal(rename.edit.changedFiles, [DeskFileID(path: "MonthView.desk")])
            t.equal(rename.edit.edits(for: m.file).count, 7)
            t.equal(rename.notes, [])
            t.check(!text.contains("monthsFromNow") && text.contains("monthsFromNow = 0") == false)
            t.check(text.contains("variable offset = 0") && text.contains("offset: offset,") && text.contains("{ offset = offset - 1 }"))
            let after = deskNavService(text, file: "MonthView.desk").snapshot
            t.equal(deskNavIDs(after.diagnostics), deskNavIDs(m.diagnostics))
            t.equal(deskNavStructure(after), deskNavStructure(m))
        } else {
            t.check(false, "monthsFromNow is renamed")
        }
        if let (text, _) = renamed(m, "{day.number}", into: 2, to: "cell") {
            t.check(text.contains("for cell in month.days") && text.contains("\"{cell.number}\"") && text.contains("if: cell.isToday")
                    && text.contains("not cell.inMonth"))
        }
        if let (text, rename) = renamed(m, "options.highlight", into: 9, to: "accentColor") {
            t.equal(rename.edit.edits(for: m.file).count, 4)
            t.equal(rename.notes, ["People who changed “highlight” in the Options panel get its default back: saved values are kept by the option’s name."])
            t.check(text.contains("accentColor = ColorPicker(") && !text.contains("options.highlight"))
        }
        if let (text, _) = renamed(m, "style todayCell", into: 6, to: "today") {
            t.check(text.contains(".style(today, if: day.isToday)") && text.contains("style today    {"))
        }
        // A quoted element name, the element's uses, and a Picker's own enum written in full.
        let quoted = deskNavService("""
            info { name: "T" }
            options { theme = Picker("Theme", [.light, .sepia], default: .sepia) }
            widget {
                Column {
                    Text("A").name("title").style("big").hidden(if: options.theme == Theme.light)
                    Text("B").onClick { showOrHide(title) }
                }
            }
            style big { .font(20) }
            """).snapshot
        if let (text, _) = renamed(quoted, "showOrHide(title)", into: 11, to: "heading") {
            t.check(text.contains(".name(\"heading\")") && text.contains("showOrHide(heading)"), "the quoted name keeps its quotes")
        }
        if let (text, _) = renamed(quoted, "big {", to: "large") {
            t.check(text.contains(".style(\"large\")") && text.contains("style large {"))
        }
        if let (text, rename) = renamed(quoted, "theme =", to: "look") {
            t.check(text.contains("look = Picker(") && text.contains("options.look == Look.light"), text)
            t.equal(rename.notes.count, 1)
            let after = deskNavService(text).snapshot
            t.equal(deskNavIDs(after.diagnostics), deskNavIDs(quoted.diagnostics))
        }
        // Chinese note.
        if case .success(let rename) = chinese.rename(at: deskNavPosition(chinese, "weekStart"), to: "firstDay") {
            t.equal(rename.notes, ["改过“weekStart”的人会回到默认值：选项的设置按名字保存。"])
        } else {
            t.check(false, "weekStart is renamed")
        }
    }

    t.suite("Desk: service — rename across the package") {
        let harbor = deskHarbor()
        let before = CheckedDeskPackage(package: harbor, context: CheckContext(fonts: DeskFakeFonts()))
        /// Applies a rename to the folder and checks it as a whole.
        func apply(_ rename: DeskRename) -> CheckedDeskPackage {
            var package = harbor
            for file in rename.edit.changedFiles {
                package = package.settingText(DeskTextEditU16.apply(rename.edit.edits(for: file), to: harbor.texts[file] ?? ""), of: file)
            }
            return CheckedDeskPackage(package: package, context: CheckContext(fonts: DeskFakeFonts()))
        }
        func ids(_ checked: CheckedDeskPackage) -> [String] {
            checked.allDiagnostics.map { "\($0.file.path) \($0.id.rawValue)" }.sorted()
        }
        func text(_ checked: CheckedDeskPackage, _ file: String) -> String { checked.package.texts[DeskFileID(path: file)] ?? "" }
        let widgets = ["Lamp.desk", "Radio.desk", "Tide.desk", "package.desk"].map { DeskFileID(path: $0) }

        // A package style, from the package and from a widget: every widget changes.
        for (open, needle) in [("package.desk", "style card"), ("Lamp.desk", "card")] {
            let snapshot = deskNavHarbor(open).snapshot
            guard case .success(let rename) = snapshot.rename(at: deskNavPosition(snapshot, needle, into: needle.count - 4), to: "panel")
            else { t.check(false, "card is renamed from \(open)"); continue }
            t.equal(rename.edit.changedFiles, widgets, "every widget and the package")
            t.equal(rename.notes, [])
            let after = apply(rename)
            t.equal(ids(after), ids(before), "the folder checks the same")
            t.check(text(after, "package.desk").contains("style panel {"))
            for file in ["Lamp.desk", "Radio.desk", "Tide.desk"] { t.check(text(after, file).contains(".style(panel)"), file) }
            t.equal(after.uses.styles["panel"]?.widgets.map(\.path), ["Lamp.desk", "Radio.desk", "Tide.desk"])
        }
        // A package option a widget replaces (D99): the widget's declaration and uses change with the package's.
        let tide = deskNavHarbor("Tide.desk").snapshot
        if case .success(let rename) = tide.rename(at: deskNavPosition(tide, "accent ="), to: "tint") {
            t.equal(rename.edit.changedFiles, [DeskFileID(path: "Tide.desk"), DeskFileID(path: "package.desk")])
            t.equal(rename.notes.count, 1)
            let after = apply(rename)
            t.equal(ids(after), ids(before))
            t.check(text(after, "package.desk").contains("tint = ColorPicker(") && text(after, "package.desk").contains("options.tint"))
            t.check(text(after, "Tide.desk").contains("tint = ColorPicker(") && text(after, "Tide.desk").contains(".color(options.tint)"))
        } else {
            t.check(false, "accent is renamed")
        }
        let package = deskNavHarbor("package.desk").snapshot
        if case .success(let rename) = package.rename(at: deskNavPosition(package, "metric"), to: "useMetric") {
            t.equal(rename.edit.changedFiles, [DeskFileID(path: "Tide.desk"), DeskFileID(path: "package.desk")])
            t.equal(ids(apply(rename)), ids(before))
        } else {
            t.check(false, "metric is renamed")
        }
        // Names already taken somewhere in the folder.
        func reason(_ snapshot: DeskSnapshot, _ needle: String, into: Int = 0, _ newName: String) -> String {
            if case .failure(let r) = snapshot.rename(at: deskNavPosition(snapshot, needle, into: into), to: newName) {
                return r.reason.rawValue + " " + r.message
            }
            return "renamed"
        }
        t.equal(reason(package, "style card", into: 6, "heading"), "alreadyUsed “heading” is already used in package.desk.")
        t.equal(reason(package, "metric", "look"), "alreadyUsed “look” is already used in Tide.desk.",
                "a widget's own option would start replacing it")
        t.equal(reason(tide, "showWaves", "metric"), "alreadyUsed “metric” is already used in package.desk.",
                "a widget's option would start replacing the package's")
        t.equal(reason(tide, "look =", "height"), "alreadyUsed “height” is already used here.")
        t.equal(reason(tide, "heading", "Heading"), "invalidName “Heading” can’t be a name: start with a lowercase letter and use only letters, digits and _.")
        // A widget's own style stays in the widget, and cannot take a package style's name.
        let own = DeskLanguageService(openFile: DeskFileID(path: "Lamp.desk"),
                                      files: [DeskFileID(path: "Lamp.desk"): "info { name: \"L\" }\nwidget { Text(\"A\").style(small).style(card) }\nstyle small { .font(12) }\n",
                                              DeskFileID(path: "package.desk"): "style card { .padding(4) }\n",
                                              DeskFileID(path: "Tide.desk"): "info { name: \"T\" }\nwidget { Text(\"B\").style(card) }\nstyle small { .font(14) }\n"]).snapshot
        t.equal(deskNavReferences(own, "small"), ["Lamp.desk 2:26 small", "Lamp.desk 3:7 small"], "not Tide's style of that name")
        if case .success(let rename) = own.rename(at: deskNavPosition(own, "small"), to: "tiny") {
            t.equal(rename.edit.changedFiles, [DeskFileID(path: "Lamp.desk")])
        } else {
            t.check(false, "small is renamed")
        }
        t.equal(reason(own, "small", "card"), "alreadyUsed “card” is already used in package.desk.")
    }
}
