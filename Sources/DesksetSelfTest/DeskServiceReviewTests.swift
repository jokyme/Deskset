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

/// `DESK_ACTIONS_DUMP='widget { … }'` prints each diagnostic of a text with its quick fixes, each applied and checked
/// again (`*` marks the preferred one).
private func deskReviewActionsDump(_ text: String) {
    let file = DeskFileID("Test.desk")
    let snapshot = DeskLanguageService(openFile: file, files: [file: text]).snapshot
    for d in snapshot.diagnostics {
        print("\(d.id.rawValue) \(d.severity) \(d.range) \(d.message)")
        for action in snapshot.codeActions(for: d) where action.kind == .quickFix {
            let fixed = DeskTextEditU16.apply(action.edit.edits(for: file), to: text)
            let after = DeskLanguageService(openFile: file, files: [file: fixed]).snapshot.diagnostics
            print("    \(action.isPreferred ? "*" : " ") \(action.title) → \(fixed.debugDescription)")
            print("        \(after.map { "\($0.id.rawValue)\($0.severity == .error ? "!" : "")" })")
        }
    }
}

/// A Mac's symbols and fonts that can be listed by prefix, as the Studio's index lists them.
private struct DeskReviewSymbols: SymbolValidating {
    let all = ["cloud.sun.fill", "cloud.rain.fill", "wifi", "wifi.slash", "sun.max.fill", "cpu"]
    func exists(_ symbol: String) -> Bool { all.contains(symbol) }
    func minimumMacOS(of symbol: String) -> Int? { nil }
    func similarSymbols(to symbol: String) -> [String] { all.filter { DidYouMean.distance($0, symbol) <= 2 } }
    func symbols(matching prefix: String, limit: Int) -> [String] {
        Array(all.filter { name in prefix.isEmpty || name.hasPrefix(prefix) || name.split(separator: ".").contains { $0.hasPrefix(prefix) } }
            .prefix(limit))
    }
}

private struct DeskReviewFonts: FontCataloging {
    let installed = ["Helvetica", "Helvetica Neue", "Futura", "Menlo"]
    func isInstalled(family: String) -> Bool { installed.contains(family) }
    func macSubstitute(forWindowsFamily family: String) -> String? { nil }
    func similarFamilies(to family: String) -> [String] { installed.filter { DidYouMean.distance($0, family) <= 2 } }
    func families(matching prefix: String, limit: Int) -> [String] {
        Array(installed.filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix.lowercased()) }.prefix(limit))
    }
}

func runDeskServiceReviewTests(_ t: TestRunner) {
    if let text = ProcessInfo.processInfo.environment["DESK_ACTIONS_DUMP"] {
        deskReviewActionsDump(text.replacingOccurrences(of: "\\n", with: "\n"))
        return
    }
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

    t.suite("Desk: service — file names match as a Mac matches them") {
        let package = "package { name: \"Pack\" }\nstyle card { .padding(8) }\n"
        let a = "info { name: \"A\" }\nwidget { Text(\"A\").style(card) }\n"
        let b = "info { name: \"B\" }\nwidget { Text(\"B\").style(card) }\n"
        // `Package.desk` is the package, in the service and in the folder model.
        let files = [DeskFileID("Package.desk"): package, DeskFileID("A.desk"): a, DeskFileID("B.DESK"): b]
        let widget = DeskLanguageService(openFile: DeskFileID("A.desk"), files: files).snapshot
        t.equal(widget.packageFile, DeskFileID("Package.desk"))
        let all = widget.folder.keys.sorted { $0.path < $1.path }.flatMap { file in
            widget.folderDiagnostics(of: file).map { "\(file.path) \($0.id.rawValue) \($0.message)" }
        }
        t.equal(all, [], "the style resolves, the package is no widget, no widget is missing")
        t.equal(widget.packageCheck().uses.styles["card"]?.widgets.map(\.path), ["A.desk", "B.DESK"])
        let opened = DeskLanguageService(openFile: DeskFileID("Package.desk"), files: files)
        t.check(opened.isEditingPackage)
        t.equal(opened.snapshot.diagnostics.map(\.id.rawValue), [])
        var model = DeskPackage()
        for (file, text) in files { model = model.settingText(text, of: file) }
        t.equal(model.packageFile, DeskFileID("Package.desk"))
        t.equal(model.manifest?.name, "Pack")
        t.equal(model.widgetFiles.map(\.path), ["A.desk", "B.DESK"])
        t.equal(DeskPackagePath.kind(of: "PACKAGE.DESK"), .package)
        t.equal(CheckedDeskPackage(package: model).allDiagnostics.map { "\($0.file.path) \($0.id.rawValue)" }, [])
        // `B.DESK` is found by references and changed by a rename.
        t.equal(deskNavReferences(widget, "card", includeDeclaration: false), ["A.desk 2:26 card", "B.DESK 2:26 card"])
        if case .success(let rename) = widget.rename(at: deskNavPosition(widget, "card"), to: "tile") {
            t.equal(rename.edit.changedFiles.map(\.path).sorted(), ["A.desk", "B.DESK", "Package.desk"])
        } else {
            t.check(false, "card is renamed")
        }
        // Loaded from a folder.
        var folder = InMemoryPackageSource()
        for (file, text) in files { folder.add(file.path, text: text) }
        let loaded = (try? PackageLoader.load(folder)) ?? DeskPackage()
        t.equal(loaded.packageFile, DeskFileID("Package.desk"))
        t.equal(CheckedDeskPackage(package: loaded).allDiagnostics.map { "\($0.file.path) \($0.id.rawValue)" }, [])
    }

    t.suite("Desk: service — renaming a saved value says the saved values stay behind") {
        let text = "info { name: \"T\" }\nwidget {\n    saved threshold = 80%\n    Text(\"{threshold}\").onClick { threshold = threshold + 1% }\n}\n"
        for language in [DiagnosticLanguage.english, .simplifiedChinese] {
            let snapshot = deskNavService(text, language: language).snapshot
            guard case .success(let rename) = snapshot.rename(at: deskNavPosition(snapshot, "threshold"), to: "limit") else {
                t.check(false, "threshold is renamed")
                continue
            }
            t.equal(rename.notes, [language == .english
                ? "Values people’s widgets saved under “threshold” are not carried over: saved values are kept by name."
                : "各人的小组件以“threshold”保存的值不会带过去：保存的值按名字存放。"])
            t.equal(deskMessageLeaks(rename.notes[0]), [])
        }
        let variable = deskNavService(text.replacingOccurrences(of: "saved", with: "variable")).snapshot
        if case .success(let rename) = variable.rename(at: deskNavPosition(variable, "threshold"), to: "limit") {
            t.equal(rename.notes, [], "a variable keeps nothing")
        }
    }

    t.suite("Desk: service — a snapshot checked in the background keeps the last check's results meanwhile") {
        let file = DeskFileID("Big.desk")
        var lines = ["info { name: \"Big\" }", "options { accent = ColorPicker(\"Accent\", default: .blue) }", "widget {",
                     "    Text(\"A\").colr(.red)", "    Text(\"B\").style(card).name(title)"]
        for k in 0..<40 { lines.append("    Text(\"Line \\(k)\")") }
        lines += ["    Text(\"C\").color(options)", "    Text(\"D\").style()", "}", "style card { .padding(4) }", ""]
        let text = lines.joined(separator: "\n")
        var options = DeskServiceOptions()
        options.backgroundCheckBytes = 1
        let service = DeskLanguageService(openFile: file, files: [file: text], options: options)
        let typo = service.snapshot.diagnostics.first { service.snapshot.text[Range(NSRange(location: $0.range.start.offset, length: 4), in: service.snapshot.text)!] == "colr" }
        t.check(typo != nil, "the typo is reported: \(service.snapshot.diagnostics.map(\.id.rawValue))")
        let dot = (text as NSString).range(of: "color(options").location + "color(options".utf16.count
        _ = service.beginUpdate(changes: [DeskTextChange(range: dot..<dot, text: ".")], version: 1)
        let syntax = service.snapshot
        t.check(!syntax.isChecked)
        t.check(syntax.diagnostics.contains { $0.id == typo?.id && $0.range == typo?.range }, "the squiggle on the typo stays")
        t.check(syntax.completions(at: syntax.index.position(utf16: dot + 1)).labels.contains("accent"), "options are offered")
        let style = (syntax.text as NSString).range(of: "style()").location + "style(".utf16.count
        t.check(syntax.completions(at: syntax.index.position(utf16: style)).labels.contains("card"), "styles are offered")
        // A second key before the check: still there, moved.
        _ = service.beginUpdate(changes: [DeskTextChange(range: 0..<0, text: "// top\n")], version: 2)
        let again = service.snapshot
        t.check(again.diagnostics.contains { $0.id == typo?.id && $0.range.start.line == (typo?.range.start.line ?? 0) + 1 },
                "moved by the second edit")
        // The check replaces them with its own.
        let fresh = DeskLanguageService(openFile: file, files: [file: again.text]).snapshot
        let pending = service.beginUpdate(changes: [], version: 3)
        t.equal(service.accept(pending.run())?.diagnostics, fresh.diagnostics, "the check's own results")

        // A small file whose check takes long is checked in the background too.
        var slow = DeskServiceOptions()
        slow.backgroundCheckMilliseconds = 0
        let small = DeskLanguageService(openFile: file, files: [file: "widget { Text(\"A\") }\n"], options: slow)
        let queue = DispatchQueue(label: "desk.review.check")
        let owner = DispatchQueue(label: "desk.review.owner")
        let delivered = DispatchSemaphore(value: 0)
        var returned: DeskSnapshot?
        owner.sync {
            returned = small.update(changes: [DeskTextChange(range: 0..<0, text: " ")], version: 1, checkingOn: queue,
                                    deliverOn: owner) { _ in delivered.signal() }
        }
        t.check(returned?.isChecked == false, "the syntax snapshot comes first")
        t.check(delivered.wait(timeout: .now() + 120) == .success, "the check is delivered")
        owner.sync { t.check(small.snapshot.isChecked) }
        t.check(small.lastCheckMilliseconds > 0, "the check was timed")
    }

    t.suite("Desk: service — a control with nothing to bind to declares a variable for it") {
        func accept(_ marked: String, _ label: String) -> (String, DeskCompletionItem)? {
            let (snapshot, list) = deskCompletions(marked)
            guard let item = list.items.first(where: { $0.label == label }) else { return nil }
            let edits = ([DeskTextEditU16(range: item.range, newText: item.plainText)] + item.additionalEdits)
                .sorted { $0.range.start.offset < $1.range.start.offset }
            return (DeskTextEditU16.apply(edits, to: snapshot.text), item)
        }
        let info = "info { name: \"T\" }\n"
        for (marked, label, expect) in [
            (info + "widget {\n    Tog|\n}\n", "Toggle", ["variable showSeconds = false", "Toggle(\"Show seconds\", showSeconds)"]),
            (info + "widget {\n    Text(\"A\")\n    Inp|\n}\n", "Input", ["variable note = \"\"", "Input(note)"]),
            (info + "widget { Tog| }\n", "Toggle", ["variable showSeconds = false"]),
            (info + "widget {\n    variable note = 1\n    Inp|\n}\n", "Input", ["variable note2 = \"\"", "Input(note2)"]),
        ] {
            guard let (result, _) = accept(marked, label) else { t.check(false, "\(label) offered in \(marked)"); continue }
            for piece in expect { t.check(result.contains(piece), "\(piece) in \(result)") }
            t.equal(deskSnippetErrors(result, file: "Test.desk"), [], result)
        }
        // A value that fits is taken, and nothing is declared.
        if let (result, item) = accept(info + "widget {\n    variable on = true\n    Tog|\n}\n", "Toggle") {
            t.check(result.contains("Toggle(\"Show seconds\", on)"), result)
            t.equal(item.additionalEdits, [])
        } else {
            t.check(false, "Toggle offered")
        }
    }

    t.suite("Desk: service — placeholders are no sample data, and option labels come from their names") {
        func plain(_ marked: String, _ label: String, file: String = "Test.desk") -> String? {
            deskCompletions(marked, file: file).1.items.first { $0.label == label }?.plainText
        }
        t.equal(plain("options {\n    |\n}\n", "ColorPicker"), "accent = ColorPicker(\"Accent\")")
        t.equal(plain("options {\n    |\n}\n", "Slider"), "amount = Slider(\"Amount\", min: 0, max: 100)")
        t.equal(plain("options {\n    |\n}\n", "Toggle"), "showDetails = Toggle(\"Show details\")")
        t.equal(plain("options {\n    city = |\n}\n", "Input"), "Input(\"City\")")
        t.equal(plain("options {\n    showWaves = Tog|\n}\n", "Toggle"), "Toggle(\"Show waves\")")
        t.equal(plain("widget {\n    Te|\n}\n", "Text"), "Text(\"Text\")")
        t.equal(plain("info {\n    |\n}\n", "name", file: "Tide.desk"), "name: \"Tide\"")
        t.equal(plain("info {\n    |\n}\n", "author"), "author: \"\"")
        t.equal(plain("info {\n    |\n}\n", "license"), "license: \"\"")
        let chinese = DeskServiceOptions(messageLanguage: .simplifiedChinese)
        let (_, list) = deskCompletions("options {\n    x = |\n}\n", options: chinese)
        t.equal(list.items.first { $0.label == "Toggle" }?.plainText, "Toggle(\"X\")")
    }

    t.suite("Desk: service — arguments: the value first, labels in the catalog's order, data only of the expected type") {
        func labels(_ marked: String) -> [String] { deskCompletions(marked).1.labels }
        let color = labels("widget {\n    Text(\"a\").color(|)\n}\n")
        t.check(color.first?.hasPrefix(".") == true, "a color first: \(color.prefix(5))")
        if let white = color.firstIndex(of: ".white"), let dark = color.firstIndex(of: "dark:") {
            t.check(white < dark, "the colors before the other form's labels")
        } else {
            t.check(false, "colors and labels offered: \(color)")
        }
        let progress = labels("widget {\n    Progress(|)\n}\n")
        t.check(progress.first.map { !$0.hasSuffix(":") } == true, "a value first: \(progress.prefix(5))")
        let padding = labels("widget {\n    Text(\"a\").padding(4, |)\n}\n").filter { $0.hasSuffix(":") }
        t.equal(padding.last, "if:", "if: last")
        t.equal(Array(padding.prefix(2)), ["horizontal:", "vertical:"], "the catalog's order")
        // Data only when it has a value of the expected type; durations and lengths written out.
        let every = labels("widget {\n    Text(\"a\").every(|)\n}\n")
        t.equal(Array(every.prefix(3)), ["1s", "500ms", "5min"])
        t.check(!every.contains("time") && !every.contains("memory"), "\(every)")
        t.check(!labels("widget {\n    Text(\"a\").color(re|)\n}\n").contains("trash"))
        t.check(labels("widget {\n    if |\n}\n").contains("cpu"), "a condition compares any data")
        t.check(labels("widget {\n    Text(|)\n}\n").contains("memory"), "text shows any data")
        // A picture of the folder, quoted.
        let (_, images) = deskHarborCompletions("widget {\n    Image(|)\n}\n")
        t.check(images.labels.contains("\"images/waves.png\""), "\(images.labels.prefix(8))")
    }

    t.suite("Desk: service — modifiers a container only passes down do not lead its list") {
        let column = deskCompletions("widget {\n    Column { }.|\n}\n").1.labels
        for general in ["padding", "background"] {
            if let g = column.firstIndex(of: general), let a = column.firstIndex(of: "align") {
                t.check(g < a, "\(general) before align on a Column: \(column.prefix(10))")
            } else {
                t.check(false, "\(general) and align offered: \(column.prefix(10))")
            }
        }
        let text = deskCompletions("widget {\n    Text(\"a\").|\n}\n").1.labels
        if let font = text.firstIndex(of: "font"), let align = text.firstIndex(of: "align") {
            t.check(font < align, "font before align on Text: \(text.prefix(10))")
        }
        let rectangle = deskCompletions("widget {\n    Rectangle().|\n}\n").1.labels
        t.check(Array(rectangle.prefix(3)).contains("fill"), "a shape's fill stays near the top: \(rectangle.prefix(5))")
    }

    t.suite("Desk: service — details and signature help read cleanly") {
        let (_, music) = deskCompletions("widget {\n    Text(\"a\").onClick {\n        music.|\n    }\n}\n")
        for item in music.items {
            t.check(!item.detail.en.contains("()") && !item.detail.zh.contains("（）"), "\(item.label): \(item.detail.en) / \(item.detail.zh)")
        }
        let (_, views) = deskCompletions("widget {\n    |\n}\n")
        for item in views.items {
            t.check(!item.detail.en.contains("((") && !item.detail.en.contains("))") && !item.detail.zh.contains("（（")
                    && !item.detail.en.contains("Bool"), "\(item.label): \(item.detail.en) / \(item.detail.zh)")
        }
        t.equal(views.items.first { $0.label == "Toggle" }?.detail.en, "Switch (text in quotes, yes or no)")
        t.check(views.items.first { $0.label == "Toggle" }?.documentation?.en.contains("Bool") == false)
        // Parameters in the order they are written, the one being written in bold.
        let text = "widget {\n    Progress(cpu.usage, total: |)\n}\n"
        let (marked, offset) = deskCursorText(text)
        let snapshot = deskNavService(marked).snapshot
        if let help = snapshot.signatureHelp(at: snapshot.index.position(utf16: offset)) {
            let lines = help.markdown(.english).split(separator: "\n").filter { $0.hasPrefix("- ") }
            t.check(lines.first?.hasPrefix("- `") == true, "the first parameter first, not in bold: \(lines)")
            t.check(lines.contains { $0.hasPrefix("- **total:**") }, "the active one in bold: \(lines)")
        } else {
            t.check(false, "signature help for Progress")
        }
        let font = deskNavService("widget {\n    Text(\"a\").font()\n}\n", language: .simplifiedChinese).snapshot
        if let help = font.signatureHelp(at: deskNavPosition(font, "font()", into: 5)) {
            let markdown = help.markdown(.simplifiedChinese)
            t.check(markdown.components(separatedBy: "文字预设").count <= 2, markdown)
        }
        t.equal(DeskHoverWords.choiceOf.zh, "可选值，属于")
    }

    t.suite("Desk: service — a fix's title says what it writes") {
        func titles(_ body: String, _ language: DiagnosticLanguage = .english) -> [String] {
            let snapshot = deskNavService("info { name: \"T\" }\nwidget {\n    \(body)\n}\n", language: language).snapshot
            return snapshot.codeActions(in: snapshot.index.range(utf16: 0..<(snapshot.text as NSString).length), source: false)
                .filter { $0.kind == .quickFix }.map(\.title)
        }
        let swiftUI = titles("Text(\"CPU\").frame(width: 100, height: 20).cornerRadius(8)")
        t.check(swiftUI.contains("Change to `.size(100, 20)`") && swiftUI.contains("Change to `.rounded(8)`"), "\(swiftUI)")
        t.equal(Set(swiftUI).count, swiftUI.count, "no title twice")
        t.check(titles("Text(\"CPU\").font -size(14)").contains("Remove `-size(14)`"))
        t.check(titles("Text(\"CPU\").font-size(14)").contains("Change to `.font(14)`"))
        t.check(titles("VStack { Text(\"a\") }", .simplifiedChinese).contains("改成 `Column`"))
    }

    t.suite("Desk: service — symbols, fonts and pictures are listed by what is typed, not by misspelling") {
        var options = DeskServiceOptions()
        options.symbols = DeskReviewSymbols()
        options.fonts = DeskReviewFonts()
        func labels(_ marked: String) -> [String] { deskCompletions(marked, options: options).1.labels }
        let empty = labels("widget {\n    Icon(\"|\")\n}\n")
        t.check(empty.contains("cloud.sun.fill") && empty.contains("wifi"), "\(empty.prefix(8))")
        let clo = labels("widget {\n    Icon(\"clo|\")\n}\n")
        t.check(clo.contains("cloud.sun.fill") && clo.contains("cloud.rain.fill"), "\(clo)")
        t.check(labels("widget {\n    Icon(\"sun|\")\n}\n").contains("cloud.sun.fill"), "a part of the name")
        t.check(labels("widget {\n    Icon(\"wfi|\")\n}\n").contains("wifi"), "a misspelling when nothing starts so")
        let hel = labels("widget {\n    Text(\"a\").font(\"Hel|\")\n}\n")
        t.check(hel.contains("Helvetica Neue") && hel.contains("Helvetica"), "\(hel)")
        // Without a list, the usual symbols still come.
        let plain = deskCompletions("widget {\n    Icon(\"|\")\n}\n").1.labels
        t.check(plain.contains("wifi"), "\(plain.prefix(8))")
        // The folder's pictures by prefix, when the service has only its resources.
        let service = DeskLanguageService(openFile: DeskFileID("W.desk"),
                                          files: [DeskFileID("W.desk"): "widget {\n    Image(\"im\")\n}\n"],
                                          resources: PackageResources(package: deskHarbor()))
        let snapshot = service.snapshot
        let at = (snapshot.text as NSString).range(of: "\"im").location + 3
        let pictures = snapshot.completions(at: snapshot.index.position(utf16: at)).labels
        t.check(pictures.contains("images/waves.png"), "\(pictures)")
    }

    t.suite("Desk: service — a choice written with its type: completion, hover and the name") {
        let options = "options { look = Picker(\"Look\", [.calm, .storm]) }\n"
        func labels(_ marked: String) -> [String] { deskCompletions(marked).1.labels }
        t.equal(labels(options + "widget {\n    Text(\"a\").hidden(if: options.look == Look.|)\n}\n"), ["calm", "storm"])
        t.equal(labels(options + "widget {\n    Text(\"a\").hidden(if: options.look == Look.st|)\n}\n"), ["storm"])
        t.check(labels(options + "widget {\n    Text(\"a\").hidden(if: options.look == Lo|)\n}\n").contains("Look"))
        t.check(labels("widget {\n    Text(\"a\").align(HAlign.|)\n}\n").contains("left"))
        t.check(labels("widget {\n    variable side = HAlign.|\n}\n").contains("right"))
        t.check(labels("widget {\n    Text(\"a\").color(Color.|)\n}\n").contains("red"))
        let text = options + "widget {\n    Text(\"a\").align(HAlign.left).hidden(if: options.look == Look.calm)\n}\n"
        let snapshot = deskNavService(text).snapshot
        for (needle, into) in [("HAlign.left", 1), ("Look.calm", 1)] {
            let position = deskNavPosition(snapshot, needle, into: into)
            t.check(snapshot.hover(at: position) != nil, "a hover on the type of \(needle)")
            t.equal(snapshot.symbol(at: position)?.kind, .type, needle)
        }
        t.check(snapshot.hover(at: deskNavPosition(snapshot, "Look.calm", into: 1))?.paragraphs.first?.en.contains("`.storm`") == true)
    }

    t.suite("Desk: service — the preferred fix of code written in another language's way leaves no error") {
        let cases: [(String, String)] = [
            ("Text(\"CPU\").style(\"color: red; font-size: 14px\")", "Text(\"CPU\").color(.red).font(14)"),
            ("Text(\"CPU\").fontColor(255, 0, 0)", "Text(\"CPU\").color(rgb(255, 0, 0))"),
            ("Text(\"CPU\").FontColor(\"255,0,0\")", "Text(\"CPU\").color(rgb(255, 0, 0))"),
            ("Text(\"CPU: \" + cpu.usage + \"%\")", "Text(\"CPU: {cpu.usage}%\")"),
            ("Text(\"CPU\").font-size(14)", "Text(\"CPU\").font(14)"),
            ("Text(`${cpu.usage}%`)", "Text(\"{cpu.usage}%\")"),
            ("Text({cpu.usage})", "Text(\"{cpu.usage}\")"),
            ("Progress({cpu.usage}, total: 100)", "Progress(cpu.usage, total: 100)"),
        ]
        for (body, expected) in cases {
            let text = "info { name: \"T\" }\nwidget {\n    \(body)\n}\n"
            let snapshot = deskNavService(text).snapshot
            let whole = snapshot.index.range(utf16: 0..<(text as NSString).length)
            let actions = snapshot.codeActions(in: whole, source: false).filter { $0.kind == .quickFix }
            t.equal(actions.filter(\.isPreferred).count >= 1, true, "\(body): a preferred fix: \(actions)")
            guard let preferred = actions.first(where: \.isPreferred) else { continue }
            let fixed = DeskTextEditU16.apply(preferred.edit.edits(for: snapshot.file), to: text)
            t.check(fixed.contains(expected), "\(body) → \(fixed)")
            let after = deskNavService(fixed).snapshot
            t.equal(after.diagnostics.filter { $0.severity == .error }.map(\.id.rawValue), [], "\(body) → \(fixed)")
        }
        // A style that can't be named so is not offered to be created.
        let quoted = deskNavService("info { name: \"T\" }\nwidget {\n    Text(\"a\").style(\"my card\")\n}\n").snapshot
        t.check(!quoted.diagnostics.flatMap(\.fixIts).contains { $0.title.hasPrefix("Create") }, "\(quoted.diagnostics)")
        // `.font -size(14)` with a space is not CSS.
        let spaced = deskNavService("info { name: \"T\" }\nwidget {\n    Text(\"a\").font -size(14)\n}\n").snapshot
        t.check(!spaced.diagnostics.contains { $0.id == .cssDeclaration }, "\(spaced.diagnostics.map(\.id.rawValue))")
    }
}
