import Foundation
@testable import DeskLanguage

// Regression tests for problems a review of the language service found: each suite names what went wrong.

/// Everything the folder check says, file by file, and what the package's shared names are used by: what a fresh
/// service must agree with.
private func deskReviewFolderSummary(_ snapshot: DeskSnapshot) -> [String] {
    var out: [String] = []
    for file in snapshot.folder.keys.sorted(by: { $0.path < $1.path }) {
        for d in snapshot.folderDiagnostics(of: file) { out.append("\(file.path) \(d.id.rawValue) \(d.range) \(d.message)") }
    }
    let uses = snapshot.packageCheck().uses
    for (name, entry) in uses.styles.sorted(by: { $0.key < $1.key }) {
        out.append("style \(name): \(entry.uses.map { "\($0.file.path)" }.sorted())")
    }
    for (name, entry) in uses.options.sorted(by: { $0.key < $1.key }) {
        out.append("option \(name): \(entry.uses.map { "\($0.file.path)" }.sorted())")
    }
    return out
}

/// A fresh service on the same folder, open on the same file.
private func deskReviewFresh(_ snapshot: DeskSnapshot) -> DeskSnapshot {
    DeskLanguageService(openFile: snapshot.file, files: snapshot.folder).snapshot
}

func runDeskServiceReviewTests(_ t: TestRunner) {
    t.suite("Desk: service — another parse of the same package does not reuse the widgets' checks") {
        let package = DeskFileID("package.desk")
        let lamp = DeskFileID("Lamp.desk")
        let other = DeskFileID("Other.desk")
        let packageText = """
        package { name: "Pack" }
        options {
            accent = ColorPicker("Accent", default: .accent)
        }
        style card { .padding(8) }
        """
        let files: [DeskFileID: String] = [
            package: packageText,
            lamp: "info { name: \"Lamp\" }\nwidget { Text(\"A\").style(card).color(options.accent) }\n",
            other: "info { name: \"Other\" }\nwidget { Text(\"B\") }\n",
        ]
        func agrees(_ snapshot: DeskSnapshot, _ what: String) {
            let summary = deskReviewFolderSummary(snapshot)
            t.equal(summary, deskReviewFolderSummary(deskReviewFresh(snapshot)), what)
            t.check(!summary.contains { $0.contains("DK") && $0.contains("never used") }, "\(what): no false “never used”")
        }

        // Editing package.desk: type a letter and undo it, or replace the text with itself.
        let editing = DeskLanguageService(openFile: package, files: files)
        agrees(editing.snapshot, "package tab, first")
        editing.update(changes: [DeskTextChange(range: 0..<0, text: "x")], version: 1)
        editing.update(changes: [DeskTextChange(range: 0..<1, text: "")], version: 2)
        agrees(editing.snapshot, "package tab, a letter typed and undone")
        t.equal(editing.snapshot.packageCheck().uses.styles["card"]?.widgets, [lamp])
        editing.replaceText(packageText, version: 3)
        agrees(editing.snapshot, "package tab, the same text again")

        // Editing a widget while package.desk changes and changes back, or is removed and restored.
        let widget = DeskLanguageService(openFile: other, files: files)
        agrees(widget.snapshot, "widget tab, first")
        widget.setText(packageText + "\n", of: package)
        widget.setText(packageText, of: package)
        agrees(widget.snapshot, "widget tab, package changed and changed back")
        widget.setText(nil, of: package)
        _ = widget.snapshot.folderResults()
        widget.setText(packageText, of: package)
        agrees(widget.snapshot, "widget tab, package removed and restored")
        t.equal(widget.snapshot.packageCheck().uses.options["accent"]?.widgets, [lamp])

        // Random edits of the package, a sibling and the open file, asked in between or not, against fresh services.
        var random = DeskRandom(seed: 7)
        let pieces = ["\n", "// c\n", "style extra { .padding(1) }\n", " "]
        var disagreements = 0
        for run in 0..<60 {
            let service = DeskLanguageService(openFile: run % 2 == 0 ? package : other, files: files)
            for _ in 0..<6 {
                switch random.int(5) {
                case 0:
                    let text = random.chance(50) ? packageText : packageText + random.pick(pieces)
                    if service.isEditingPackage { service.replaceText(text, version: 1) } else { service.setText(text, of: package) }
                case 1:
                    service.setText(files[lamp]! + (random.chance(50) ? "" : random.pick(pieces)), of: lamp)
                case 2:
                    let text = service.text
                    service.replaceText(random.chance(50) ? text : text + random.pick(pieces), version: 2)
                case 3:
                    _ = service.snapshot.folderResults()
                default:
                    _ = service.snapshot.packageCheck()
                }
            }
            if deskReviewFolderSummary(service.snapshot) != deskReviewFolderSummary(deskReviewFresh(service.snapshot)) {
                disagreements += 1
            }
        }
        t.equal(disagreements, 0, "random edits agree with fresh services")
    }

    t.suite("Desk: service — renaming a quoted element name that is not a name renames its show and hide texts") {
        let text = """
        info { name: "T" }
        widget {
            Column {
                Text("A").name("my title")
                Text("B").onClick { show("my title") }
                Text("C").onClick { hide("my title") }
                Text("D").onClick { showOrHide("my title") }
                Text("my title")
            }
        }
        """
        let snapshot = deskNavService(text).snapshot
        guard case .success(let rename) = snapshot.rename(at: deskNavPosition(snapshot, "my title", into: 1), to: "head") else {
            t.check(false, "my title is renamed")
            return
        }
        let renamed = DeskTextEditU16.apply(rename.edit.edits(for: snapshot.file), to: snapshot.text)
        t.check(renamed.contains(".name(\"head\")"), renamed)
        t.check(renamed.contains("show(\"head\")") && renamed.contains("hide(\"head\")") && renamed.contains("showOrHide(\"head\")"),
                renamed)
        t.check(renamed.contains("Text(\"my title\")"), "a text that only looks like the name stays")
        let after = deskNavService(renamed).snapshot
        t.check(!deskNavIDs(after.diagnostics).contains { $0.contains("DK3002") || $0.contains("unknown") }, "\(deskNavIDs(after.diagnostics))")
    }

    t.suite("Desk: service — renaming a package option renames it inside translations") {
        let package = DeskFileID("package.desk")
        let widget = DeskFileID("T.desk")
        let files: [DeskFileID: String] = [
            package: """
            package { name: "Weather" }
            options {
                city = Input("City", default: "Oslo")
            }
            translations {
                "zh-Hans" { "Weather in {options.city}": "{options.city}的天气" }
            }
            """,
            widget: """
            info { name: "T" }
            widget {
                Text("Weather in {options.city}")
            }
            translations {
                "de" { "Weather in {options.city}": "Wetter in {options.city}" }
            }
            """,
        ]
        func ids(_ texts: [DeskFileID: String]) -> [String] {
            var model = DeskPackage()
            for (file, text) in texts { model = model.settingText(text, of: file) }
            return CheckedDeskPackage(package: model).allDiagnostics.map { "\($0.file.path) \($0.id.rawValue)" }.sorted()
        }
        let before = ids(files)
        for (open, needle, into) in [(widget, "options.city", 8), (package, "city =", 0)] {
            let snapshot = DeskLanguageService(openFile: open, files: files).snapshot
            guard case .success(let rename) = snapshot.rename(at: deskNavPosition(snapshot, needle, into: into), to: "town") else {
                t.check(false, "city is renamed from \(open.path)")
                continue
            }
            var after = files
            for file in rename.edit.changedFiles { after[file] = DeskTextEditU16.apply(rename.edit.edits(for: file), to: files[file] ?? "") }
            t.check(after[package]!.contains("\"Weather in {options.town}\": \"{options.town}的天气\""), after[package]!)
            t.check(after[widget]!.contains("\"Weather in {options.town}\": \"Wetter in {options.town}\""), after[widget]!)
            t.check(after[widget]!.contains("Text(\"Weather in {options.town}\")"), after[widget]!)
            t.equal(ids(after), before, "from \(open.path): the folder checks the same")
        }
        // A widget's own names read in its own texts, translated by the widget and by the package; a text another
        // widget still writes keeps the package's entry.
        let own: [DeskFileID: String] = [
            package: """
            package { name: "Clicks" }
            translations {
                "de" {
                    "Clicks: {count}": "Klicks: {count}"
                    "Mode {options.mode}": "Modus {options.mode}"
                    "Shared {count}": "Geteilt {count}"
                }
            }
            """,
            widget: """
            info { name: "T" }
            options { mode = Input("Mode", default: "a") }
            widget {
                variable count = 0
                Text("Clicks: {count}").onClick { count = count + 1 }
                Text("Mode {options.mode}")
                Text("Shared {count}")
            }
            translations {
                "fr" { "Clicks: {count}": "Clics : {count}" }
            }
            """,
            DeskFileID("U.desk"): """
            info { name: "U" }
            widget {
                variable count = 1
                Text("Shared {count}")
            }
            """,
        ]
        let ownBefore = ids(own)
        let snapshot = DeskLanguageService(openFile: widget, files: own).snapshot
        for (needle, newName) in [("count = 0", "taps"), ("mode =", "style2")] {
            guard case .success(let rename) = snapshot.rename(at: deskNavPosition(snapshot, needle), to: newName) else {
                t.check(false, "\(needle) is renamed")
                continue
            }
            var after = own
            for file in rename.edit.changedFiles { after[file] = DeskTextEditU16.apply(rename.edit.edits(for: file), to: own[file] ?? "") }
            t.equal(ids(after), ownBefore, "\(needle): the folder checks the same")
            if newName == "taps" {
                t.check(after[package]!.contains("\"Clicks: {taps}\": \"Klicks: {taps}\""), after[package]!)
                t.check(after[widget]!.contains("\"Clicks: {taps}\": \"Clics : {taps}\""), after[widget]!)
                t.check(after[package]!.contains("\"Shared {count}\": \"Geteilt {count}\""), "U.desk still writes it")
            } else {
                t.check(after[package]!.contains("\"Mode {options.style2}\": \"Modus {options.style2}\""), after[package]!)
            }
        }
    }

    t.suite("Desk: service — a permission added to a list with a trailing comma, or after a field's comment") {
        let music = "\n\nwidget {\n    Text(\"{music.title}\")\n    Text(\"{weather.now.temperature}\")\n}\n"
        let lists: [(String, String)] = [
            ("info {\n    name: \"T\"\n    permissions: [\n        .notifications,\n    ]\n}", "on lines, trailing comma"),
            ("info {\n    name: \"T\"\n    permissions: [\n        .notifications, // tell\n    ]\n}", "on lines, trailing comma and comment"),
            ("info {\n    name: \"T\"\n    permissions: [\n        .notifications\n    ]\n}", "on lines, no trailing comma"),
            ("info {\n    name: \"T\"\n    permissions: [\n        .notifications // tell\n    ]\n}", "on lines, a comment"),
            ("info { name: \"T\", permissions: [.notifications,] }", "one line, trailing comma"),
            ("info { name: \"T\", permissions: [.notifications] }", "one line"),
            ("info {\n    name: \"T\" // the name\n}", "a field's comment"),
        ]
        func errors(_ text: String) -> [String] {
            let snapshot = deskNavService(text).snapshot
            return snapshot.diagnostics.filter { $0.severity == .error || $0.id == .missingPermission }.map { "\($0.id.rawValue) \($0.message)" }
        }
        for (info, label) in lists {
            // Completion of `music.title` adds `.music`.
            let marked = info + "\n\nwidget {\n    Text(\"{music.|}\")\n}\n"
            let (snapshot, list) = deskCompletions(marked)
            if let item = list.items.first(where: { $0.label == "title" }) {
                let edits = ([DeskTextEditU16(range: item.range, newText: item.plainText)] + item.additionalEdits)
                    .sorted { $0.range.start.offset < $1.range.start.offset }
                let result = DeskTextEditU16.apply(edits, to: snapshot.text)
                t.equal(errors(result), [], "\(label): \(result)")
                t.check(result.contains(".music"), "\(label): \(result)")
                if label.contains("comment") { t.check(result.contains("// tell\n") || result.contains("// the name\n"), "\(label): the comment stays on its line: \(result)") }
            } else {
                t.check(false, "\(label): music.title offered")
            }
            // The source action adds both.
            let both = info + music
            let actionSnapshot = deskNavService(both).snapshot
            guard let add = actionSnapshot.sourceActions().first(where: { $0.kind == .addMissingPermissions }) else {
                t.check(false, "\(label): the action is offered")
                continue
            }
            let added = DeskTextEditU16.apply(add.edit.edits(for: actionSnapshot.file), to: both)
            t.equal(errors(added), [], "\(label): \(added)")
            // The DK8101 fix-it on its own.
            if let d = actionSnapshot.diagnostics.first(where: { $0.id == .missingPermission }), let fix = d.fixIts.first {
                let fixed = DeskTextEditU16.apply(fix.edit.edits(for: actionSnapshot.file), to: both)
                t.equal(errors(fixed).filter { !$0.hasPrefix("DK8101") }, [], "\(label): the fix-it: \(fixed)")
            }
        }
    }
}
