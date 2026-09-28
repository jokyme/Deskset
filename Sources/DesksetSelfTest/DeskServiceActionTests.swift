import Foundation
@testable import DeskLanguage

// Code actions: every action of every diagnostic fixture is applied and the result checked again (the diagnostic it
// fixes goes away, no new error appears, a "Fix all" leaves nothing of its group), and fixed cases for "Fix all",
// the actions per foreign language, the source actions, preferred fixes and titles in both languages.

/// A service for a diagnostic fixture's positive text (and its package), as the diagnostics suite makes it.
private func deskActionService(_ fixture: DeskDiagnosticFixture, text: String, package: String? = nil,
                               language: DiagnosticLanguage = .english) -> (DeskLanguageService, [DeskFileID: String]) {
    let open = DeskFileID(fixture.fileName)
    var files = [open: text]
    if let package = package ?? fixture.package, open.path != "package.desk" { files[DeskFileID("package.desk")] = package }
    let context = deskFixtureContext(fixture, package: nil)
    var options = DeskServiceOptions(context: context)
    options.messageLanguage = language
    return (DeskLanguageService(openFile: open, files: files, resources: context.resources, options: options), files)
}

/// The same group of fix-its after an edit: groups named after an offset (`rainmeter-120`) are compared by their
/// name without it.
private func deskActionGroupName(_ group: String) -> String {
    guard let dash = group.lastIndex(of: "-"), group[group.index(after: dash)...].allSatisfy(\.isNumber) else { return group }
    return String(group[..<dash])
}

/// Every action a snapshot offers: those of each diagnostic's range, and the source actions, without repeats.
private func deskAllActions(_ snapshot: DeskSnapshot, extra: [DeskServiceDiagnostic] = []) -> [DeskCodeAction] {
    var seen = Set<DeskCodeAction>()
    var out: [DeskCodeAction] = []
    for d in snapshot.diagnostics + extra {
        for action in snapshot.codeActions(in: d.range, source: false) where seen.insert(action).inserted { out.append(action) }
    }
    for action in snapshot.sourceActions() where seen.insert(action).inserted { out.append(action) }
    return out
}

func runDeskServiceActionTests(_ t: TestRunner) {
    t.suite("Desk: service — code actions") {
        let fixtures = deskFixtureFiles("Diagnostics").map { DeskDiagnosticFixture.parse(path: $0.path, text: $0.text) }
        var applied: [DeskCodeActionKind: Int] = [:]
        var fixturesWithActions = 0
        var doubledGroups = Set<String>()
        for fixture in fixtures where fixture.generate == nil && fixture.folderGenerate == nil {
            let label = fixture.id
            if fixture.isFolder {
                applied.merge(checkDeskFolderActions(t, fixture)) { $0 + $1 }
                continue
            }
            let (service, files) = deskActionService(fixture, text: fixture.positive)
            let snapshot = service.snapshot
            let actions = deskAllActions(snapshot)
            if actions.contains(where: { !$0.kind.isSource }) { fixturesWithActions += 1 }
            for action in actions {
                applied[action.kind, default: 0] += 1
                checkDeskAction(t, action, snapshot: snapshot, files: files, fixture: fixture)
            }
            // "Fix all" and the actions per language: the line of each diagnostic with a grouped or foreign fix-it
            // written twice, so the file has two of them.
            for d in snapshot.diagnostics where d.file == snapshot.file
                && d.fixIts.contains(where: { $0.group != nil || d.id.rawValue.hasPrefix("DK9") }) {
                let ns = snapshot.text as NSString
                let line = ns.lineRange(for: d.range.nsRange)
                var copy = ns.substring(with: line)
                if !copy.hasSuffix("\n") && !copy.hasSuffix("\r") { copy = "\n" + copy }
                let doubled = ns.replacingCharacters(in: NSRange(location: line.location + line.length, length: 0), with: copy)
                let (twice, twiceFiles) = deskActionService(fixture, text: doubled)
                let second = twice.snapshot
                var seen = Set<DeskCodeAction>()
                for d2 in second.diagnostics where d2.id == d.id {
                    for action in second.codeActions(in: d2.range, source: false)
                        where (action.kind == .fixAll || action.kind == .fixForeign) && seen.insert(action).inserted {
                        applied[action.kind, default: 0] += 1
                        doubledGroups.insert(action.group.map(deskActionGroupName) ?? action.family?.rawValue ?? "")
                        // The doubled code may itself be wrong (a name declared twice), so new errors are not
                        // counted; the action is the quick fixes it stands for, merged.
                        checkDeskAction(t, action, snapshot: second, files: twiceFiles, fixture: fixture, countsNewErrors: false)
                        if action.kind == .fixAll, let group = action.group {
                            var merged: [DeskFileID: [DeskTextEditU16]] = [:]
                            for d3 in second.diagnostics {
                                for fix in d3.fixIts where fix.group == group {
                                    for (file, edits) in fix.edit.files { merged[file, default: []] += edits }
                                }
                            }
                            t.equal(action.edit, DeskWorkspaceEdit(merged), "\(fixture.id): Fix all is its quick fixes merged")
                        }
                    }
                }
            }
            // The first fix-it of each diagnostic is the preferred one; titles in Chinese have no ids either.
            for d in snapshot.diagnostics where !d.fixIts.isEmpty {
                let own = snapshot.codeActions(for: d).filter { $0.kind == .quickFix }
                t.equal(own.first?.isPreferred, true, "\(label): preferred fix of \(d.id.rawValue)")
                t.equal(own.filter(\.isPreferred).count, 1, "\(label): one preferred fix of \(d.id.rawValue)")
            }
            let chinese = service.setMessageLanguage(.simplifiedChinese)
            for action in deskAllActions(chinese) {
                t.check(!action.title.isEmpty && deskMessageLeaks(action.title).isEmpty, "\(label): title \(action.title)")
            }
        }
        let summary = DeskCodeActionKind.allCases.map { "\($0.rawValue) \(applied[$0] ?? 0)" }.joined(separator: ", ")
        print("    \(fixturesWithActions) fixtures with fixes; actions applied: \(summary)")
        print("    groups fixed all at once in fixtures written twice: \(doubledGroups.sorted().joined(separator: ", "))")
        t.check((applied[.quickFix] ?? 0) >= 150, "only \(applied[.quickFix] ?? 0) quick fixes applied")
        t.check((applied[.fixAll] ?? 0) > 0 && (applied[.fixForeign] ?? 0) > 0 && (applied[.formatDocument] ?? 0) > 0
                && (applied[.addMissingPermissions] ?? 0) > 0, "every kind of action was applied")
    }

    t.suite("Desk: service — code actions, fixed cases") {
        let file = DeskFileID("Act.desk")
        func open(_ text: String, _ language: DiagnosticLanguage = .english) -> DeskSnapshot {
            DeskLanguageService(openFile: file, files: [file: text], options: DeskServiceOptions(messageLanguage: language)).snapshot
        }
        func apply(_ action: DeskCodeAction?, to text: String) -> String {
            guard let action else { return text }
            return DeskTextEditU16.apply(action.edit.edits(for: file), to: text)
        }

        // "Fix all" of one group: every full-width mark in the file, from a range holding one of them.
        let marks = "info { name: \"T\" }\nwidget {\n    Text(\"A\")。font(.caption)\n    Text(\"B\")。font(.caption)\n    Text(\"C\")。bold()\n}\n"
        let snapshot = open(marks)
        let first = snapshot.diagnostics.first { $0.id == .fullWidthPunctuation }!
        let actions = snapshot.codeActions(in: first.range, source: false)
        t.equal(actions.first?.kind, .quickFix)
        t.equal(actions.first?.isPreferred, true)
        let fixAll = actions.first { $0.kind == .fixAll }
        t.check(fixAll != nil, "a Fix all for the full-width marks: \(actions)")
        t.equal(fixAll?.diagnostics.count, 3)
        t.check(fixAll?.title.hasPrefix("Fix all 3") == true, fixAll?.title ?? "")
        let fixedAll = apply(fixAll, to: marks)
        t.equal(open(fixedAll).diagnostics.filter { $0.id == .fullWidthPunctuation }.count, 0, fixedAll)
        t.equal(snapshot.fixAllAction(group: fixAll?.group ?? "")?.edit, fixAll?.edit, "fixAllAction(group:)")
        // Titles in Chinese.
        let zh = open(marks, .simplifiedChinese).codeActions(in: first.range, source: false)
        t.check(zh.first { $0.kind == .fixAll }?.title.hasPrefix("全部改正（3 处）") == true, "\(zh.map(\.title))")
        // A range that meets no diagnostic has only the source actions.
        let quiet = snapshot.index.range(utf16: 0..<4)
        t.check(snapshot.codeActions(in: quiet).allSatisfy(\.kind.isSource), "\(snapshot.codeActions(in: quiet))")

        // Two runs of Rainmeter lines: one action fixes every line of both.
        let rainmeter = """
        info { name: "T" }
        widget {
            Text("A")
            FontColor=255,255,255
            FontSize=12
            Text("B")
            FontColor=0,0,0
        }

        """
        let foreign = open(rainmeter)
        let lead = foreign.diagnostics.first { $0.id.rawValue.hasPrefix("DK93") }!
        let family = foreign.codeActions(in: lead.range).first { $0.kind == .fixForeign }
        t.equal(family?.family, .rainmeter, "\(foreign.codeActions(in: lead.range))")
        t.check(family?.title.contains("Rainmeter") == true, family?.title ?? "")
        let rewritten = apply(family, to: rainmeter)
        let after = open(rewritten)
        t.check(!after.diagnostics.contains { $0.id.rawValue.hasPrefix("DK93") }, "\(rewritten)\n\(after.diagnostics)")
        t.check(!after.diagnostics.contains { $0.severity == .error }, "\(after.diagnostics)")

        // Every missing permission in one edit, into a list, as a field, or as a new info block.
        let music = "widget {\n    Text(\"{music.title}\")\n    Text(\"{weather.now.temperature}\")\n}\n"
        for (text, label) in [(music, "no info"), ("info { name: \"T\" }\n" + music, "one-line info"),
                              ("info {\n    name: \"T\"\n}\n" + music, "info on lines"),
                              ("info { name: \"T\", permissions: [] }\n" + music, "an empty list")] {
            let s = open(text)
            let add = s.sourceActions().first { $0.kind == .addMissingPermissions }
            t.check(add != nil, "\(label): \(s.sourceActions())")
            t.equal(add?.diagnostics.count, 2, label)
            t.equal(add?.title, "Add all 2 missing permissions", label)
            let added = apply(add, to: text)
            let checked = open(added)
            t.equal(checked.diagnostics.filter { $0.id == .missingPermission }.count, 0, "\(label): \(added)")
            t.check(!checked.diagnostics.contains { $0.severity == .error }, "\(label): \(checked.diagnostics)")
        }

        // Formatting is offered only when it changes something.
        let messy = "widget {\nText(\"A\")    .bold()\n}\n"
        let format = open(messy).sourceActions().first { $0.kind == .formatDocument }
        t.equal(format?.title, "Format the file")
        let formatted = apply(format, to: messy)
        t.equal(formatted, "widget {\n    Text(\"A\").bold()\n}\n")
        t.check(open(formatted).sourceActions().isEmpty, "nothing left to offer")

        // Actions of package.desk's own checks (DK8604), for the open package.
        var folder = InMemoryPackageSource()
        folder.add("package.desk", text: "package {\n    name: \"Sparks\"\n    requires: \"1.0\"\n}\n")
        folder.add("Spark.desk", text: "info { name: \"Spark\" }\nwidget { Text(\"Hi\").sparkle(2) }\n")
        let package = (try? PackageLoader.load(folder)) ?? DeskPackage()
        let service = DeskLanguageService(package: package, openFile: DeskFileID("package.desk"),
                                          options: DeskServiceOptions(catalog: deskFutureCatalog(),
                                                                      appVersion: AppVersion(major: 1, minor: 2)))
        let requires = (service.text as NSString).range(of: "\"1.0\"")
        let packageActions = service.snapshot.codeActions(in: service.snapshot.index.range(requires)!)
        let bump = packageActions.first { $0.diagnostics.contains { $0.id == .packageRequiresTooOld } }
        t.check(bump != nil, "the package's requires: \(packageActions)")
        t.equal(bump.map { DeskTextEditU16.apply($0.edit.edits(for: DeskFileID("package.desk")), to: service.text) },
                "package {\n    name: \"Sparks\"\n    requires: \"1.2\"\n}\n")
        t.check(service.snapshot.codeActions(in: service.snapshot.index.range(requires)!, folder: false)
                    .allSatisfy { !$0.diagnostics.contains { $0.id == .packageRequiresTooOld } }, "without the folder")
    }
}

/// Every action of a folder fixture's open file, applied to the folder and checked again.
private func checkDeskFolderActions(_ t: TestRunner, _ fixture: DeskDiagnosticFixture) -> [DeskCodeActionKind: Int] {
    var applied: [DeskCodeActionKind: Int] = [:]
    let label = fixture.id
    let source = deskFixtureFolder(fixture, text: fixture.positive, negative: false)
    guard let package = try? PackageLoader.load(source) else { return applied }
    let open = DeskFileID(fixture.fileName)
    guard package.texts[open] != nil else { return applied }
    var options = DeskServiceOptions(context: deskFixtureContext(fixture, package: nil))
    options.messageLanguage = .english
    let snapshot = DeskLanguageService(package: package, openFile: open, options: options).snapshot
    let checked = deskCheckFixtureFolder(source, fixture)
    let before = checked.allDiagnostics
    let errorsBefore = Set(before.filter { $0.severity == .error }.map(\.id))
    let folderOwn = snapshot.packageCheck().folderDiagnostics.filter { $0.file == open }.map(snapshot.serviceDiagnostic)
    for action in deskAllActions(snapshot, extra: folderOwn) where !action.kind.isSource {
        applied[action.kind, default: 0] += 1
        var edited: [String: String] = [:]
        for file in action.edit.changedFiles {
            guard let text = package.texts[file] else { continue }
            edited[file.path] = DeskTextEditU16.apply(action.edit.edits(for: file), to: text)
        }
        let after = deskCheckFixtureFolder(deskFixtureFolder(fixture, text: fixture.positive, negative: false, edited: edited), fixture)
        let all = after.allDiagnostics
        for id in Set(action.diagnostics.map(\.id)) {
            t.check(all.filter { $0.id == id }.count < before.filter { $0.id == id }.count, "\(label): \(action) left \(id.rawValue)")
        }
        let newErrors = Set(all.filter { $0.severity == .error }.map(\.id)).subtracting(errorsBefore)
        t.check(newErrors.isEmpty, "\(label): \(action) brought \(newErrors.map(\.rawValue).sorted())")
    }
    return applied
}

/// Applies an action to the fixture's files, checks them again, and checks what the action promised: the diagnostics
/// it fixes are fewer, no new error appeared, a "Fix all" of a named group left none of the group, formatting is done.
private func checkDeskAction(_ t: TestRunner, _ action: DeskCodeAction, snapshot: DeskSnapshot, files: [DeskFileID: String],
                             fixture: DeskDiagnosticFixture, countsNewErrors: Bool = true) {
    let label = fixture.id
    let open = snapshot.file
    let before = snapshot.checked.diagnostics
    let errorsBefore = Set(before.filter { $0.severity == .error }.map(\.id))
    t.check(!action.title.isEmpty && deskMessageLeaks(action.title).isEmpty, "\(label): title \(action.title)")
    t.check(!action.edit.isEmpty, "\(label): \(action) has no edit")
    var edited = files
    for file in action.edit.changedFiles {
        guard let text = files[file] else {
            t.check(false, "\(label): \(action) edits \(file.path), which the folder does not have")
            continue
        }
        edited[file] = DeskTextEditU16.apply(action.edit.edits(for: file), to: text)
    }
    let (after, _) = deskActionService(fixture, text: edited[open] ?? "", package: edited[DeskFileID("package.desk")])
    let result = after.snapshot
    let diagnostics = result.checked.diagnostics
    func count(_ id: DiagnosticID, _ list: [Diagnostic]) -> Int { list.filter { $0.id == id }.count }
    let newErrors = Set(diagnostics.filter { $0.severity == .error }.map(\.id)).subtracting(errorsBefore)
    t.check(newErrors.isEmpty || fixture.fixItsMayIntroduceErrors || !countsNewErrors,
            "\(label): \(action) brought \(newErrors.map(\.rawValue).sorted()): \(result.text.debugDescription)")
    switch action.kind {
    case .quickFix, .fixForeign:
        for id in Set(action.diagnostics.map(\.id)) {
            t.check(count(id, diagnostics) < count(id, before),
                    "\(label): \(action) left \(id.rawValue): \(result.text.debugDescription)")
        }
        if let family = action.family {
            let left = result.diagnostics.filter { result.foreignFamily(of: $0) == family && !$0.fixIts.isEmpty }
            let had = snapshot.diagnostics.filter { snapshot.foreignFamily(of: $0) == family && !$0.fixIts.isEmpty }
            t.check(left.count < had.count, "\(label): \(action) left \(left.map(\.id.rawValue)): \(result.text.debugDescription)")
        }
    case .fixAll:
        let group = deskActionGroupName(action.group ?? "")
        if group == action.group {
            let left = diagnostics.filter { d in d.fixIts.contains { $0.group == group } }
            t.check(left.isEmpty, "\(label): \(action) left \(left.map(\.id.rawValue)): \(result.text.debugDescription)")
        }
        for id in Set(action.diagnostics.map(\.id)) {
            t.check(count(id, diagnostics) < count(id, before), "\(label): \(action) left \(id.rawValue): \(result.text.debugDescription)")
        }
    case .addMissingPermissions:
        t.equal(count(.missingPermission, diagnostics), 0, "\(label): \(action)")
    case .formatDocument:
        t.check(result.sourceActions().allSatisfy { $0.kind != .formatDocument }, "\(label): formatting twice changes more")
    }
}
