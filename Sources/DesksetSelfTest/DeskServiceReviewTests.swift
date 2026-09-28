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
}
