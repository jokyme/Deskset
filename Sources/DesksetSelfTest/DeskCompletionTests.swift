import Foundation
@testable import DeskLanguage

// Completion in the language service: a table of cases with `|` at the cursor (the place, the items that must come
// first and the ones that must not be offered), every snippet inserted where it is offered and checked, and a sweep of
// every offset of sampled corpus snippets.
//
// `DESK_COMPLETE_DUMP='widget { Text("a").| }'` prints the context and the first items at the `|` (with
// `DESK_COMPLETE_FILE=package.desk` for a package file, `DESK_COMPLETE_ALL=1` for every item, `DESK_COMPLETE_DEBUG=1`
// for every node and token with the types the service sees).

/// A text with `|` at the cursor, and the position of the cursor in the text without it.
func deskCursorText(_ marked: String) -> (text: String, offset: Int) {
    let ns = marked as NSString
    let r = ns.range(of: "|")
    guard r.location != NSNotFound else { return (marked, ns.length) }
    return (ns.replacingCharacters(in: r, with: ""), r.location)
}

/// The completion list at the `|` of a text, alone or in a folder.
func deskCompletions(_ marked: String, file: String = "Test.desk", others: [String: String] = [:],
                     options: DeskServiceOptions = DeskServiceOptions()) -> (DeskSnapshot, DeskCompletionList) {
    let (text, offset) = deskCursorText(marked)
    var files = [DeskFileID(path: file): text]
    for (path, other) in others { files[DeskFileID(path: path)] = other }
    let service = DeskLanguageService(openFile: DeskFileID(path: file), files: files, resources: DeskFakeResources(), options: options)
    let snapshot = service.snapshot
    return (snapshot, snapshot.completions(at: snapshot.index.position(utf16: offset)))
}

struct DeskCompletionCase {
    var text: String
    var place: DeskCompletionPlace
    /// All must be among the first ten, the first among the first three.
    var top: [String]
    /// Offered anywhere in the list.
    var present: [String]
    var absent: [String]
    var file = "Test.desk"
    var others: [String: String] = [:]
    var options = DeskServiceOptions()

    init(_ text: String, _ place: DeskCompletionPlace, top: [String] = [], present: [String] = [], absent: [String] = [],
         file: String = "Test.desk", others: [String: String] = [:], options: DeskServiceOptions = DeskServiceOptions()) {
        self.text = text
        self.place = place
        self.top = top
        self.present = present
        self.absent = absent
        self.file = file
        self.others = others
        self.options = options
    }
}

func runDeskCompletionTests(_ t: TestRunner) {
    if let marked = ProcessInfo.processInfo.environment["DESK_COMPLETE_DUMP"] {
        let file = ProcessInfo.processInfo.environment["DESK_COMPLETE_FILE"] ?? "Test.desk"
        let (_, list) = deskCompletions(marked.replacingOccurrences(of: "\\n", with: "\n"), file: file)
        print("context: \(list.context)  range \(list.context.range)")
        if ProcessInfo.processInfo.environment["DESK_COMPLETE_DEBUG"] != nil {
            let (snap, _) = deskCompletions(marked.replacingOccurrences(of: "\\n", with: "\n"), file: file)
            let table = snap.nodeTable
            for (i, e) in table.entries.enumerated() {
                print("   \(i) \(e.kind) \(e.textStart)..<\(e.textEnd) parent \(e.parent) type \(snap.symbolIndex.valueTypes[i].map { "\($0)" } ?? "-") ns \(snap.symbolIndex.namespaceOf[i] ?? "-") rec \(snap.recordedType(i).map { "\($0.type)" } ?? "-")")
            }
            for e in snap.tokenTable.entries { print("   tok \(e.kind) \(e.textStart) parent \(e.parent) \(e.token.isMissing ? "missing" : e.token.text)") }
        }
        let all = ProcessInfo.processInfo.environment["DESK_COMPLETE_ALL"] != nil
        for item in all ? list.items : Array(list.items.prefix(30)) {
            print("  \(item.label)  [\(item.kind.rawValue)]  \(item.sortText)  \(String(reflecting: item.plainText))\(item.isAlreadyPresent ? " (present)" : "")")
        }
        print("  \(list.items.count) items\(list.isIncomplete ? ", incomplete" : "")")
        return
    }
    runDeskCompletionCaseTests(t)
    runDeskCompletionPropertyTests(t)
    runDeskCompletionSnippetTests(t)
    runDeskCompletionSweep(t)
    runDeskCompletionLatency(t)
}

func runDeskCompletionLatency(_ t: TestRunner) {
    t.suite("Desk: service — completion latency") {
        #if DEBUG
        let build = "debug"
        let factor = 10.0
        #else
        let build = "release"
        let factor = 1.0
        #endif
        func best(_ runs: Int, _ body: () -> Void) -> Double {
            var fastest = Double.infinity
            for _ in 0..<runs {
                let start = ProcessInfo.processInfo.systemUptime
                body()
                fastest = min(fastest, ProcessInfo.processInfo.systemUptime - start)
            }
            return fastest * 1000
        }
        for lines in [300, 2_000] {
            let service = deskNavService(deskLargeWidget(lines: lines), file: "Large.desk")
            let snapshot = service.snapshot
            let places: [(String, DeskPosition)] = [
                ("modifier", deskNavPosition(snapshot, ".padding(", into: 3)),
                ("member", deskNavPosition(snapshot, "cpu.usage", into: 5)),
                ("value", deskNavPosition(snapshot, "page + 1", into: 7)),
                ("element", deskNavPosition(snapshot, "Text(", into: 2)),
            ]
            // The first request of a snapshot builds the node table, the tokens and the symbol index.
            let first = best(3) { _ = service.setMessageLanguage(.english).completions(at: places[0].1) }
            let warm = service.setMessageLanguage(.english)
            _ = warm.completions(at: places[0].1)
            var parts: [String] = []
            var worst = 0.0
            for (name, position) in places {
                let ms = best(3) { _ = warm.completions(at: position) }
                worst = max(worst, ms)
                parts.append(String(format: "%@ %.2f", name as NSString, ms))
            }
            print(String(format: "    Desk completion, %@ build, %d lines: first request %.1f ms, then ", build as NSString, lines, first)
                  + parts.joined(separator: ", ") + " ms")
            let bound = (lines == 300 ? 50.0 : 200.0) * factor
            t.check(first < bound && worst < bound / 5, "completion in \(lines) lines is quick enough to show while typing")
        }
    }
}

// MARK: - Snippets

/// The contexts snippets are inserted in: every place that offers them, with the names their values refer to.
func deskSnippetContexts() -> [(label: String, text: String, file: String)] {
    let widget = """
    info { name: "Test" }

    options {
        accent = ColorPicker("Accent", default: .blue)
        showDetails = Toggle("Show details")
        folder = FolderPicker("Folder")
    }

    widget {
        variable note = ""
        variable count = 0
        saved on = false
        computed month = calendar.month(offset: count)
    <DECL>
        Column {
            Text("Title").name(title)
    <VIEW>
        }
        .onClick {
    <ACTION>
        }
    }

    style card { .padding(4) }
    """
    func fill(_ decl: String = "", _ view: String = "", _ action: String = "") -> String {
        widget.replacingOccurrences(of: "<DECL>\n", with: decl.isEmpty ? "" : decl + "\n")
            .replacingOccurrences(of: "<VIEW>\n", with: view.isEmpty ? "" : view + "\n")
            .replacingOccurrences(of: "<ACTION>\n", with: action.isEmpty ? "" : action + "\n")
    }
    var out: [(String, String, String)] = [
        ("top level of a new file", "|", "Test.desk"),
        ("top level after a widget", "|\n\nwidget {\n    Text(\"A\")\n}\n", "Test.desk"),
        ("top level of a package", "|", "package.desk"),
        ("info fields", "info {\n    name: \"A\"\n    |\n}\n\nwidget {\n    Text(\"A\")\n}\n", "Test.desk"),
        ("package fields", "package {\n    name: \"P\"\n    |\n}\n", "package.desk"),
        ("option lines", "options {\n    |\n}\n\nwidget {\n    Text(\"A\")\n}\n", "Test.desk"),
        ("option lines in a Section", "options {\n    Section(\"More\") {\n        |\n    }\n}\n\nwidget {\n    Text(\"A\")\n}\n", "Test.desk"),
        ("a control", "options {\n    extra = |\n}\n\nwidget {\n    Text(\"A\")\n}\n", "Test.desk"),
        ("declarations", fill("    |"), "Test.desk"),
        ("elements in a Column", fill("", "        |"), "Test.desk"),
        ("elements in a Row", fill("", "        Row {\n            |\n        }"), "Test.desk"),
        ("elements in a Freeform", fill("", "        Freeform {\n            |\n        }"), "Test.desk"),
        ("elements in a Grid", fill("", "        Grid(columns: 2) {\n            |\n        }"), "Test.desk"),
        ("menu entries", fill("", "        Text(\"M\").menu {\n            |\n        }"), "Test.desk"),
        ("click actions", fill("", "", "        |"), "Test.desk"),
        ("timer actions", fill("", "        Text(\"T\").every(1s) {\n            |\n        }"), "Test.desk"),
        ("style body", fill().replacingOccurrences(of: "style card { .padding(4) }", with: "style card {\n    .|\n}"), "Test.desk"),
        ("style body without a dot", fill().replacingOccurrences(of: "style card { .padding(4) }", with: "style card {\n    |\n}"), "Test.desk"),
        ("hover body", fill("", "        Text(\"H\").hover {\n            .|\n        }"), "Test.desk"),
        ("pressed body", fill("", "        Text(\"H\").pressed {\n            .|\n        }"), "Test.desk"),
        ("control modifiers", "options {\n    extra = Toggle(\"Extra\")\n        .|\n}\n\nwidget {\n    Text(\"A\").hidden(if: options.extra)\n}\n", "Test.desk"),
        ("translations", "widget {\n    Text(\"Hello\")\n}\n\ntranslations {\n    |\n}\n", "Test.desk"),
        ("translation keys", "widget {\n    Text(\"Hello\")\n    Text(\"World\")\n}\n\ntranslations {\n    \"zh-Hans\" {\n        |\n    }\n}\n", "Test.desk"),
        ("calendar members", fill("    computed m2 = calendar.|"), "Test.desk"),
        ("music actions", fill("", "", "        music.|"), "Test.desk"),
        ("text members", fill("", "        Text(note.|)"), "Test.desk"),
        ("list members", fill("", "        Text(\"{month.days.|}\")"), "Test.desk"),
        ("format options of a percentage", fill("", "        Text(\"{cpu.usage, |}\")"), "Test.desk"),
        ("format options of an amount", fill("", "        Text(\"{memory.used, |}\")"), "Test.desk"),
        ("format options of a date", fill("", "        Text(\"{time.now, |}\")"), "Test.desk"),
        ("labels of Grid", fill("", "        Grid(|) {\n            Text(\"G\")\n        }"), "Test.desk"),
        ("labels of .font", fill("", "        Text(\"F\").font(|)"), "Test.desk"),
        ("labels of Progress", fill("", "        Progress(cpu.usage, |)"), "Test.desk"),
        ("values in an interpolation", fill("", "        Text(\"{|}\")"), "Test.desk"),
    ]
    // Modifiers on every kind of element, in a Column (menu entries in a menu, positions in a Freeform).
    let catalog = DeskCatalog.current
    for component in catalog.components {
        let signature = component.signatures.first!
        var params: [String] = []
        for p in DeskSnippet.params(of: signature) {
            let value = ["note", "options.showSeconds", "volume.level"].contains(DeskSnippet.value(of: p, catalog: catalog))
                ? (p.type == .binding(.bool) ? "on" : p.type == .binding(.string) ? "note" : "count")
                : DeskSnippet.value(of: p, catalog: catalog)
            params.append(p.label.map { "\($0): \(value)" } ?? value)
        }
        var element = component.name + "(" + params.joined(separator: ", ") + ")"
        if case .views = component.block { element += " {\n            Text(\"C\")\n        }" }
        if case .menuItems = component.block { element += " {\n            Item(\"C\")\n        }" }
        let placed: String
        switch component.kind {
        case .item, .menu:
            placed = "        Text(\"M\").menu {\n            \(element)\n                .|\n        }"
        case .spacer:
            placed = "        \(element)\n            .|"
        default:
            placed = "        \(element)\n            .|"
        }
        out.append(("modifiers of \(component.name)", fill("", placed), "Test.desk"))
    }
    out.append(("modifiers in a Freeform", fill("", "        Freeform {\n            Text(\"A\").name(first)\n            Text(\"B\")\n                .|\n        }"), "Test.desk"))
    return out
}

/// The errors of a text checked the way completion offered it.
func deskSnippetErrors(_ text: String, file: String) -> [String] {
    var files = [DeskFileID(path: file): text]
    if file != "package.desk" { files[DeskFileID(path: "Other.desk")] = nil }
    let service = DeskLanguageService(openFile: DeskFileID(path: file), files: files, resources: DeskFakeResources())
    let snapshot = service.snapshot
    return snapshot.checked.diagnostics.filter { $0.severity == .error }.map { d in
        "\(d.id.rawValue) \(snapshot.index.position(utf8: d.range.lowerBound)) \(d.message(in: .english))"
    }
}

func runDeskCompletionSnippetTests(_ t: TestRunner) {
    t.suite("Desk: service — completion snippets") {
        var inserted = 0
        var places = Set<DeskCompletionPlace>()
        for (label, marked, file) in deskSnippetContexts() {
            let (snapshot, list) = deskCompletions(marked, file: file)
            let (text, _) = deskCursorText(marked)
            let before = deskSnippetErrors(text, file: file)
            let snippets = list.items.filter { $0.isSnippet || $0.plainText.contains("(") || $0.plainText.contains("{") }
            if !label.hasPrefix("modifiers of") { t.check(!snippets.isEmpty, "\(label): offers snippets (\(list.context))") }
            places.insert(list.context.place)
            for item in snippets {
                inserted += 1
                // The snippet with its values filled in, at the cursor.
                let edits = ([DeskTextEditU16(range: item.range, newText: item.plainText)] + item.additionalEdits)
                    .sorted { $0.range.start.offset < $1.range.start.offset }
                let result = DeskTextEditU16.apply(edits, to: snapshot.text)
                let tree = Desk.parse(result, file: DeskFileID(path: file))
                let syntax = tree.diagnostics.filter { $0.severity == .error }.map { "\($0.id.rawValue)" }
                t.check(syntax.isEmpty, "\(label): \(item.label) parses: \(syntax)\n\(result)")
                // An error the context had before is not the snippet's.
                let errors = deskSnippetErrors(result, file: file).filter { e in !before.contains { $0.prefix(6) == e.prefix(6) } }
                t.check(errors.isEmpty, "\(label): \(item.label) checks: \(errors)\n\(result)")
                // The snippet's tab stops hold the same text.
                t.equal(deskSnippetPlain(item.insertText), item.plainText, "\(label): \(item.label) snippet and plain text")
            }
        }
        t.check(inserted > 1_000, "snippets inserted: \(inserted)")
        print("    (\(inserted) snippets inserted in \(deskSnippetContexts().count) contexts)")
    }
}

/// A snippet's text with its tab stops replaced by their values and the escapes removed.
func deskSnippetPlain(_ snippet: String) -> String {
    var out = ""
    let chars = Array(snippet)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\\", i + 1 < chars.count {
            out.append(chars[i + 1])
            i += 2
            continue
        }
        if c == "$" {
            var j = i + 1
            if j < chars.count, chars[j] == "{" {
                j += 1
                while j < chars.count, chars[j].isNumber { j += 1 }
                if j < chars.count, chars[j] == ":" { j += 1 }
                i = j
                continue
            }
            while j < chars.count, chars[j].isNumber { j += 1 }
            if j > i + 1 { i = j; continue }
        }
        if c == "}" {
            // The end of a placeholder (a literal `}` outside one is kept: placeholders never nest here).
            if deskPlaceholderDepth(chars, before: i) > 0 { i += 1; continue }
        }
        out.append(c)
        i += 1
    }
    return out
}

/// How many placeholders are open before position `end` of a snippet.
func deskPlaceholderDepth(_ chars: [Character], before end: Int) -> Int {
    var depth = 0
    var i = 0
    while i < end {
        if chars[i] == "\\" { i += 2; continue }
        if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "{" { depth += 1; i += 2; continue }
        if chars[i] == "}", depth > 0 { depth -= 1 }
        i += 1
    }
    return depth
}

// MARK: - Cases

/// A service on the Harbor package with one of its widgets' text replaced by a marked text.
func deskHarborCompletions(_ marked: String, file: String = "Tide.desk") -> (DeskSnapshot, DeskCompletionList) {
    let (text, offset) = deskCursorText(marked)
    let service = DeskLanguageService(package: deskHarbor(), openFile: DeskFileID(path: file))
    let snapshot = service.replaceText(text, version: 1)
    return (snapshot, snapshot.completions(at: snapshot.index.position(utf16: offset)))
}

let deskCompletionPackage = """
options {
    shared = Toggle("Shared")
}
style card { .padding(14) }
style heading { .font(.headline) }
"""

/// `W` wraps a body in a widget with a few declarations and a named element.
func deskW(_ body: String) -> String {
    """
    options {
        accent = ColorPicker("Accent", default: .blue)
        theme = Picker("Theme", [.light, .dark])
    }

    widget {
        variable page = 0
        variable size = .small
        computed month = calendar.month(offset: page)
        Column {
            Text("Title").name(title)
    \(body)
        }
    }

    style card { .padding(4) }
    style big { .font(20) }
    """
}

func deskCompletionCases() -> [DeskCompletionCase] {
    typealias C = DeskCompletionCase
    let future = DeskServiceOptions(catalog: deskFutureCatalog(), appVersion: AppVersion(major: 1, minor: 2))
    let fonts = DeskServiceOptions(fonts: DeskFakeFonts())
    return [
        // Top level.
        C("|", .topLevel, top: ["widget", "info", "options"], absent: ["Text", "package", "Column"]),
        C("wid|", .topLevel, top: ["widget"], absent: ["info"]),
        C("info { name: \"A\" }\n\n|\n\nwidget {\n    Text(\"A\")\n}\n", .topLevel, top: ["options", "style"], absent: ["info", "widget"]),
        C("|", .topLevel, top: ["package", "options"], absent: ["widget", "info"], file: "package.desk"),
        C("package { name: \"P\" }\n|", .topLevel, top: ["options"], absent: ["package", "widget"], file: "package.desk"),
        // Info and package fields.
        C("info {\n    name: \"A\"\n    |\n}\n", .fields, top: ["size", "description"], absent: ["name", "Text"]),
        C("info {\n    si|\n}\n", .fields, top: ["size"], absent: ["name"]),
        C("info {\n    perm|\n}\n", .fields, top: ["permissions"]),
        C("package {\n    |\n}\n", .fields, top: ["name"], absent: ["size", "permissions", "category"], file: "package.desk"),
        C("info {\n    category: .|\n}\n", .implicitMember, top: ["developer", "time"], absent: ["small", "red"]),
        C("info {\n    size: .|\n}\n", .implicitMember, top: ["small", "medium", "large"], absent: ["caption"]),
        C("info {\n    permissions: [.music, .|]\n}\n", .implicitMember, top: ["accessibility", "calendar"], absent: ["small"]),
        // Options.
        C("options {\n    |\n}\n", .optionItems, top: ["Picker", "Toggle"], absent: ["Text", "Choice", "Column"]),
        C("options {\n    Section(\"More\") {\n        |\n    }\n}\n", .optionItems, top: ["Picker", "Toggle"], absent: ["Text"]),
        C("options {\n    Sec|\n}\n", .optionItems, top: ["Section"]),
        C("options {\n    a = |\n}\n", .control, top: ["Picker", "Toggle"], absent: ["Section", "Choice", "Text"]),
        C("options {\n    a = Pi|\n}\n", .control, top: ["Picker"], absent: ["Toggle"]),
        C("options {\n    a = Toggle(\"A\")\n        .|\n}\n", .modifiers, top: ["hidden", "help"], absent: ["font", "onClick", "padding"]),
        // Views.
        C("widget {\n    |\n}\n", .views, top: ["Text", "Column", "Row"], present: ["variable", "saved", "computed", "if", "for"],
          absent: ["Item", "open", "Picker"]),
        C("widget {\n    Text(\"A\")\n    |\n}\n", .views, top: ["Text"], absent: ["variable", "saved", "Item"]),
        // A declaration being typed, in another language's words too (`var`, `let`).
        C("widget {\n    v|\n}\n", .views, present: ["variable"]),
        C("widget {\n    var|\n}\n", .views, top: ["variable"]),
        C("widget {\n    varia|\n}\n", .views, top: ["variable"]),
        C("widget {\n    let|\n}\n", .views, present: ["variable"]),
        C("widget {\n    sav|\n}\n", .views, top: ["saved"]),
        C("widget {\n    comp|\n}\n", .views, top: ["computed"]),
        C("widget {\n    variable a = 1\n    sav|\n}\n", .views, top: ["saved"]),
        C("widget {\n    Text(\"A\")\n    sav|\n}\n", .views, absent: ["saved"]),
        C("widget {\n    Column {\n        Te|\n    }\n}\n", .views, top: ["Text"], absent: ["Column"]),
        C("widget {\n    VStack|\n}\n", .views, top: ["Column"], absent: ["Row"]),
        C("widget {\n    HStack|\n}\n", .views, top: ["Row"]),
        C("widget {\n    ZStack|\n}\n", .views, top: ["Freeform"]),
        C("widget {\n    Column {\n        fo|\n    }\n}\n", .views, top: ["for"]),
        C("widget {\n    Column {\n        if|\n    }\n}\n", .views, top: ["if", "if else"]),
        C("widget {\n    Text(\"A\").menu {\n        |\n    }\n}\n", .views, top: ["Item", "Menu", "Divider"], absent: ["Text", "Column"]),
        C("widget {\n    Text(\"A\").menu {\n        Menu(\"More\") {\n            |\n        }\n    }\n}\n", .views, top: ["Item"], absent: ["Text"]),
        C("widget {\n    Column {\n        Text(\"A\")\n        |", .views, top: ["Text"], absent: ["widget"]),
        C("widget {\n    Column {\n        Te|", .views, top: ["Text"]),
        C("widget {\n    Column {\n        Str|\n    }\n}\n", .views, top: ["Text"]),
        // Actions.
        C(deskW("        Text(\"A\").onClick {\n            |\n        }"), .actions, top: ["page", "open"], absent: ["Text", "font", "month"]),
        C(deskW("        Text(\"A\").onClick { op| }"), .actions, top: ["open"]),
        C(deskW("        Text(\"A\").every(1s) {\n            |\n        }"), .actions, top: ["page"], absent: ["open", "copy", "run", "Text"]),
        C(deskW("        Text(\"A\").onClick {\n            after(1s) {\n                |\n            }\n        }"), .actions, top: ["page", "open"], absent: ["Text"]),
        C(deskW("        Text(\"A\").onClick {\n            if page > 1 {\n                |\n            }\n        }"), .actions, top: ["page"], absent: ["Text"]),
        C(deskW("        Text(\"A\").onClick {\n            mus|\n        }"), .actions, top: ["music"]),
        // Modifiers.
        C(deskW("        Text(\"A\").|"), .modifiers, top: ["color", "font"], absent: ["Item", "tint", "fill", "Text"]),
        C(deskW("        Text(\"A\")\n            .|"), .modifiers, top: ["color", "font"], absent: ["tint"]),
        C(deskW("        Text(\"A\")\n            .pa|"), .modifiers, top: ["padding"], absent: ["font"]),
        C(deskW("        Text(\"A\").foregroundC|"), .modifiers, top: ["color"]),
        C(deskW("        Icon(\"wifi\").|"), .modifiers, top: ["color"], absent: ["lines", "uppercase"]),
        C(deskW("        Image(\"cover.png\").|"), .modifiers, top: ["background", "imageMode"], present: ["tint"], absent: ["lines", "fill"]),
        C(deskW("        Circle().|"), .modifiers, top: ["fill"], absent: ["lines", "tint"]),
        C(deskW("        Text(\"A\").position(x: 4).|"), .modifiers, absent: ["position", "rainmeter"]),
        C(deskW("        Freeform {\n            Text(\"A\").pos|\n        }"), .modifiers, top: ["position"]),
        C("widget {\n    Text(\"A\")\n}\n\nstyle s {\n    .|\n}\n", .modifiers, top: ["color", "font"], absent: ["onClick", "name", "every", "menu"]),
        C("widget {\n    Text(\"A\")\n}\n\nstyle s {\n    pad|\n}\n", .modifiers, top: [".padding"]),
        C(deskW("        Text(\"A\").hover {\n            .|\n        }"), .modifiers, top: ["color"], absent: ["onClick", "hover", "menu", "name"]),
        C(deskW("        Text(\"A\").pressed { .sc| }"), .modifiers, top: ["scale"]),
        // Members.
        C(deskW("        Text(cpu.|)"), .member, top: ["usage"], absent: ["title", "play"]),
        C(deskW("        Text(cpu.us|)"), .member, top: ["usage"]),
        C(deskW("        Text(audio.|)"), .member, top: ["level"], absent: ["usage"]),
        C(deskW("        Text(audio.microphone.|)"), .member, top: ["level"]),
        C(deskW("        Text(\"A\").hidden(if: options.|)"), .member, top: ["accent", "theme"], absent: ["usage"]),
        C(deskW("        Text(calendar.month(offset: 1).|)"), .member, top: ["title"]),
        C(deskW("        Text(month.|)"), .member, top: ["title"], absent: ["usage"]),
        C(deskW("        Text(\"{month.days.|}\")"), .member, top: ["count"], absent: ["usage"]),
        C(deskW("        Text(music.title.|)"), .member, top: ["length"], absent: ["split", "usage"]),
        C(deskW("        Text(\"A\").onClick {\n            if event.|\n        }"), .member, absent: ["usage"]),
        C(deskW("        Text(\"A\").onClick {\n            music.|\n        }"), .member, top: ["playPause", "next"], absent: ["title", "artist"]),
        C(deskW("        Text(music.|)"), .member, top: ["title", "artist"], absent: ["play", "next"]),
        C(deskW("        Text(\"A\").onClick {\n            volume.|\n        }"), .member, top: ["set"], present: ["level", "muted"]),
        C(deskW("        Text(\"A\").onClick {\n            options.|\n        }"), .member, top: ["accent", "theme"]),
        C(deskW("        Freeform {\n            Text(\"A\").name(first)\n            Text(\"B\").position(x: first.|)\n        }"), .member,
          top: ["left", "right", "top"], absent: ["usage"]),
        C("widget {\n    computed m = calendar.|\n}\n", .member, top: ["month"]),
        // Implicit members with an expected type.
        C(deskW("        Text(\"A\").font(.|)"), .implicitMember, top: ["caption", "headline"], absent: ["red", "small"]),
        C(deskW("        Text(\"A\").font(.he|)"), .implicitMember, top: ["headline"]),
        C(deskW("        if widget.size == .| {\n            Text(\"B\")\n        }"), .implicitMember, top: ["small", "medium"], absent: ["caption"]),
        C(deskW("        Text(\"A\").onClick { size = .| }"), .implicitMember, top: ["small"], absent: ["caption"]),
        C(deskW("        Text(\"A\").hidden(if: options.theme == .|)"), .implicitMember, top: ["dark", "light"], absent: ["small"]),
        C(deskW("        Text(\"A\").color(page > 1 ? .red : .|)"), .implicitMember, top: ["accent"], absent: ["small", "caption"]),
        C(deskW("        Text(\"A\").color(options.accent.ifMissing(.|))"), .implicitMember, top: ["accent"], absent: ["caption"]),
        C(deskW("        Text(\"A\").background(.|)"), .implicitMember, top: ["glass"], absent: ["caption"]),
        C(deskW("        Text(\"A\").width(.|)"), .implicitMember, top: ["fill", "fit"], absent: ["caption", "red"]),
        C("options {\n    day = Picker(\"Day\", [.sunday, .|])\n}\n", .implicitMember, top: ["monday"]),
        // Argument labels and values.
        C(deskW("        Grid(|) {\n            Text(\"G\")\n        }"), .argument, top: ["columns:"], absent: ["cpu"]),
        C(deskW("        Grid(col|) {\n            Text(\"G\")\n        }"), .argument, top: ["columns:"]),
        C(deskW("        Progress(cpu.usage, |)"), .argument, top: ["total:"], absent: ["cpu", "page"]),
        C(deskW("        Text(\"A\").padding(|)"), .argument, top: ["8"], present: ["horizontal:"], absent: ["caption", "time"]),
        C(deskW("        Text(\"A\").color(.red, |)"), .argument, top: ["if:"]),
        C(deskW("        Text(\"A\").font(|)"), .argument, top: [".caption"], absent: ["columns:"]),
        C(deskW("        Text(|)"), .argument, top: ["page", "month"], absent: ["columns:"]),
        // Units.
        C(deskW("        Text(\"A\").every(5|) { page = page + 1 }"), .unit, top: ["s", "ms", "min"], absent: ["pt", "%", "GB"]),
        C(deskW("        Text(\"A\").every(5m|) { page = page + 1 }"), .unit, top: ["ms", "min"], absent: ["s", "h"]),
        C(deskW("        Text(\"A\").padding(4|)"), .unit, top: ["pt"], absent: ["s"]),
        C(deskW("        Text(\"A\").opacity(50|)"), .unit, top: ["%"], absent: ["s", "pt"]),
        C(deskW("        Text(\"A\").hidden(if: memory.free < 2|)"), .unit, top: ["GB", "MB"], absent: ["s", "pt"]),
        // Styles, elements and Freeform geometry.
        C(deskW("        Text(\"A\").style(|)"), .styleName, top: ["big", "card"], absent: ["Text", "cpu"]),
        C(deskW("        Text(\"A\").style(ca|)"), .styleName, top: ["card"], absent: ["big"]),
        C("widget {\n    Text(\"A\").style(|)\n}\n\nstyle own { .padding(2) }\n", .styleName, top: ["own", "card", "heading"],
          others: ["package.desk": deskCompletionPackage]),
        C(deskW("        Text(\"A\").onClick { hide(|) }"), .elementName, top: ["title"], absent: ["page", "cpu"]),
        C(deskW("        Text(\"A\").onClick { showOrHide(ti|) }"), .elementName, top: ["title"]),
        C(deskW("        Freeform {\n            Text(\"A\").name(first)\n            Text(\"B\").position(x: |)\n        }"), .value,
          top: ["first"], absent: ["Text"]),
        C(deskW("        Text(\"A\").name(|)"), .none, absent: ["title", "page"]),
        // Values and interpolations.
        C(deskW("        Text(\"{|}\")"), .value, top: ["page", "month"], absent: ["Text", "open"]),
        C(deskW("        Text(\"{cp|}\")"), .value, top: ["cpu"]),
        C(deskW("        Text(\"{cpu.usage, |}\")"), .formatOption, top: ["decimals:"], absent: ["unit:", "format:", "bits:"]),
        // An interpolation whose `}` is not typed yet.
        C("widget {\n    Text(\"{cpu.|\")\n}\n", .member, top: ["usage", "core", "coreCount"]),
        C("widget {\n    Text(\"{cpu.us|\")\n}\n", .member, top: ["usage"]),
        C("widget {\n    Text(\"{cpu.usage} {mem|\")\n}\n", .value, top: ["memory"]),
        C("widget {\n    Text(\"{cp|", .value, top: ["cpu"]),
        C("widget {\n    Text(\"{cpu.usage, |\")\n}\n", .formatOption, top: ["decimals:"]),
        C(deskW("        Text(\"{memory.used, |}\")"), .formatOption, top: ["unit:", "decimals:"], absent: ["format:"]),
        C(deskW("        Text(\"{time.now, |}\")"), .formatOption, top: ["format:"], absent: ["unit:", "decimals:"]),
        C(deskW("        Text(\"{memory.used, decimals: 1, |}\")"), .formatOption, top: ["unit:"], absent: ["decimals:"]),
        C(deskW("        Text(\"{memory.used, unit: .|}\")"), .implicitMember, top: ["gb", "mb"], absent: ["celsius", "caption"]),
        C(deskW("        if |"), .value, top: ["true", "false", "not"], present: ["page", "cpu"], absent: ["Text"]),
        C(deskW("        for d in | {\n        }"), .value, top: ["disks"], present: ["month"], absent: ["Text"]),
        C("widget {\n    variable x = |\n}\n", .value, top: ["cpu"], present: ["true"], absent: ["Text", "open", "x"]),
        C(deskW("        Text(\"A\").onClick { page = page + | }"), .value, top: ["page"], absent: ["open", "Text"]),
        // Pictures, fonts, translations and languages.
        C("widget {\n    Image(\"|\")\n}\n", .imagePath, top: ["images/buoy.gif", "images/paper.jpg", "images/waves.png"], absent: ["fonts/HarborSans.ttf"]),
        C("widget {\n    Image(\"images/w|\")\n}\n", .imagePath, top: ["images/waves.png"], absent: ["images/buoy.gif"]),
        C("widget {\n    Text(\"A\").font(\"|\", 13)\n}\n", .fontFamily, top: ["Harbor Sans", "System"]),
        C("widget {\n    Text(\"A\").font(\"Futur|\", 13)\n}\n", .fontFamily, top: ["Futura"], options: fonts),
        C("widget {\n    Text(\"Hello\")\n    Text(\"Bye\")\n}\n\ntranslations {\n    \"zh-Hans\" {\n        \"Hello\": \"你好\"\n        |\n    }\n}\n",
          .translationKey, top: ["Bye"], absent: ["Hello"]),
        C("widget {\n    Text(\"Hello\")\n    Text(\"Bye\")\n}\n\ntranslations {\n    \"zh-Hans\" {\n        \"B|\"\n    }\n}\n",
          .translationKey, top: ["Bye"], absent: ["Hello"]),
        C("widget {\n    Text(\"Hello\")\n}\n\ntranslations {\n    \"zh-Hans\" {\n        \"Hello\": \"你好\"\n    }\n    |\n}\n",
          .languageTag, top: ["zh-Hant", "ja"], absent: ["zh-Hans"]),
        C("widget {\n    Text(\"Hello\")\n}\n\ntranslations {\n    \"j|\"\n}\n", .languageTag, top: ["ja"], absent: ["de"]),
        C("widget {\n    Text(\"Hello\")\n}\n\ntranslations {\n    \"zh-CN\" {\n    }\n    |\n}\n", .languageTag, top: ["zh-Hant"], absent: ["zh-Hans"]),
        // Nothing newer than the file's requires or target (D89).
        C("widget {\n    Text(\"A\").spa|\n}\n", .modifiers, top: ["sparkle"], options: future),
        C("info {\n    requires: \"1.0\"\n}\n\nwidget {\n    Text(\"A\").spa|\n}\n", .modifiers, absent: ["sparkle"], options: future),
        C("widget {\n    Text(\"A\").spa|\n}\n", .modifiers, absent: ["sparkle"],
          options: DeskServiceOptions(catalog: deskFutureCatalog(), appVersion: AppVersion(major: 1, minor: 2),
                                      targetAppVersion: .deskFirstRelease)),
        // Nowhere to complete.
        C("widget {\n    // Te|\n    Text(\"A\")\n}\n", .none, absent: ["Text"]),
        C("widget {\n    Text(\"Hel|lo\")\n}\n", .none, absent: ["Text"]),
        C("widget {\n    Text(\"A\").padding(1|2)\n}\n", .none, absent: ["pt"]),
        C("widget {\n    Text(\"A\") |\n}\n", .none, absent: ["Text", "font"]),
    ]
}

func runDeskCompletionCaseTests(_ t: TestRunner) {
    t.suite("Desk: service — completion") {
        let cases = deskCompletionCases()
        t.check(cases.count >= 80, "at least 80 cases: \(cases.count)")
        var places = Set<DeskCompletionPlace>()
        for c in cases {
            let harbor = c.text.contains("Image(") || c.text.contains("font(\"|") && c.options.fonts == nil
            let (snapshot, list) = harbor ? deskHarborCompletions(c.text) : deskCompletions(c.text, file: c.file, others: c.others, options: c.options)
            let label = c.text.replacingOccurrences(of: "\n", with: "⏎")
            places.insert(list.context.place)
            t.equal(list.context.place, c.place, "\(label): place (\(list.context))")
            let labels = list.labels
            if let first = c.top.first {
                t.check(labels.prefix(3).contains(first), "\(label): \(first) among the first three of \(labels.prefix(8))")
            }
            for item in c.present {
                t.check(labels.contains(item), "\(label): \(item) is offered")
            }
            for item in c.top {
                t.check(labels.prefix(10).contains(item), "\(label): \(item) among the first ten of \(labels.prefix(12))")
            }
            for item in c.absent {
                t.check(!labels.contains(item), "\(label): \(item) is not offered")
            }
            // Every range inside the text, every item well formed.
            let length = snapshot.index.utf16Count
            for item in list.items {
                t.check(item.range.start.offset >= 0 && item.range.end.offset <= length, "\(label): \(item.label) range \(item.range)")
                t.check(!item.label.isEmpty && !item.plainText.isEmpty && !item.sortText.isEmpty, "\(label): \(item.label) complete")
                for text in [item.detail.en, item.detail.zh, item.documentation?.en ?? "", item.documentation?.zh ?? ""] {
                    t.equal(deskMessageLeaks(text), [], "\(label): \(item.label) text \(text)")
                }
            }
            t.check(list.items.map(\.sortText) == list.items.map(\.sortText).sorted(), "\(label): sorted by sortText")
        }
        // Every place is reached by some case.
        for place in DeskCompletionPlace.allCases where place != .symbolName {
            t.check(places.contains(place), "a case reaches \(place)")
        }
    }
}

// MARK: - Properties and the sweep

func runDeskCompletionPropertyTests(_ t: TestRunner) {
    t.suite("Desk: service — completion items") {
        // A modifier already on the element is marked, and still offered (it may be added again with `if:`).
        let (_, present) = deskCompletions(deskW("        Text(\"A\").font(.caption).|"))
        t.equal(present.items.first { $0.label == "font" }?.isAlreadyPresent, true)
        t.equal(present.items.first { $0.label == "padding" }?.isAlreadyPresent, false)
        t.check((present.items.firstIndex { $0.label == "font" } ?? 0) > (present.items.firstIndex { $0.label == "padding" } ?? 0),
                "a present modifier comes after the others")
        // A deprecated name is marked and comes last.
        let future = DeskServiceOptions(catalog: deskFutureCatalog(), appVersion: AppVersion(major: 1, minor: 2))
        let (_, deprecated) = deskCompletions("widget {\n    Text(\"A\").gl|\n}\n", options: future)
        t.equal(deprecated.items.first { $0.label == "glow" }?.isDeprecated, true)
        // The words an item is found by: keywords and other languages' spellings.
        let (_, views) = deskCompletions("widget {\n    |\n}\n")
        let column = views.items.first { $0.label == "Column" }
        t.check(column?.filterText.contains("VStack") == true, "Column is found by VStack: \(column?.filterText ?? "")")
        t.check(views.items.first { $0.label == "Text" }?.filterText.contains("String") == true, "Text is found by String")
        // Documentation in both languages, a detail, a catalog path.
        for item in views.items where item.kind == .component {
            t.check(item.documentation?.isComplete == true, "\(item.label) documented")
            t.check(!item.detail.en.isEmpty && !item.detail.zh.isEmpty, "\(item.label) detail")
            t.check(item.catalogPath != nil, "\(item.label) path")
        }
        // Snippets: tab stops with the preview values, the final cursor, the line's indentation.
        let grid = views.items.first { $0.label == "Grid" }
        t.equal(grid?.insertText, "Grid(columns: ${1:7}) {\n        $0\n    }")
        t.equal(grid?.plainText, "Grid(columns: 7) {\n        \n    }")
        t.equal(grid?.isSnippet, true)
        let text = views.items.first { $0.label == "Text" }
        t.equal(text?.insertText, "Text(\"${1:Text}\")$0")
        // Editing a name before its `(`: the name alone replaces the whole word.
        let (snapshot, renamed) = deskCompletions("widget {\n    Te|xt(\"A\")\n}\n")
        let replacement = renamed.items.first { $0.label == "Text" }
        t.equal(replacement?.insertText, "Text")
        t.equal(replacement.map { (snapshot.text as NSString).substring(with: $0.range.nsRange) }, "Text")
        // A permission the item needs is added to `info`.
        let (musicSnapshot, music) = deskCompletions("info {\n    name: \"A\"\n}\n\nwidget {\n    Text(\"A\").onClick {\n        music.|\n    }\n}\n")
        if let play = music.items.first(where: { $0.label == "play" }) {
            let edits = ([DeskTextEditU16(range: play.range, newText: play.plainText)] + play.additionalEdits)
                .sorted { $0.range.start.offset < $1.range.start.offset }
            let result = DeskTextEditU16.apply(edits, to: musicSnapshot.text)
            t.check(result.contains("    permissions: [.music]\n"), "permission added: \(result)")
            t.equal(deskSnippetErrors(result, file: "Test.desk"), [])
        } else {
            t.check(false, "music.play offered")
        }
        let (_, listed) = deskCompletions("info {\n    permissions: [.music]\n}\n\nwidget {\n    Text(\"A\").onClick {\n        music.|\n    }\n}\n")
        t.equal(listed.items.first { $0.label == "play" }?.additionalEdits, [])
        let (_, noInfo) = deskCompletions("widget {\n    Text(\"A\").onClick {\n        music.|\n    }\n}\n")
        t.equal(noInfo.items.first { $0.label == "play" }?.additionalEdits.first?.newText, "info { permissions: [.music] }\n\n")
        // Chinese text for every item of a few lists, and no leaked ids.
        for marked in ["widget {\n    |\n}\n", deskW("        Text(\"A\").|"), deskW("        Text(cpu.|)"), "info {\n    |\n}\n"] {
            let (_, list) = deskCompletions(marked)
            for item in list.items {
                t.check(!item.detail.zh.isEmpty, "\(item.label): Chinese detail")
                t.equal(deskMessageLeaks(item.detail.zh) + deskMessageLeaks(item.documentation?.zh ?? ""), [], "\(item.label)")
            }
        }
        // The limit.
        let (_, limited) = deskCompletions("options {\n    day = Picker(\"Day\", [.|])\n}\n")
        let (_, few) = { () -> (DeskSnapshot, DeskCompletionList) in
            let (text, offset) = deskCursorText("options {\n    day = Picker(\"Day\", [.|])\n}\n")
            let snapshot = DeskLanguageService(openFile: DeskFileID(path: "Test.desk"), files: [DeskFileID(path: "Test.desk"): text]).snapshot
            return (snapshot, snapshot.completions(at: snapshot.index.position(utf16: offset), limit: 5))
        }()
        t.equal(few.items.count, 5)
        t.equal(few.isIncomplete, true)
        t.equal(few.labels, Array(limited.labels.prefix(5)))
    }
}

/// 500 corpus snippets (the 100 longest and 400 spread evenly over the rest), then the acceptance widgets, the
/// Harbor files and every tenth diagnostic fixture.
func deskCompletionSweepTexts() -> [String] {
    var texts = deskCompletionSweepSample()
    for file in deskFixtureFiles() where !file.path.hasPrefix("Diagnostics/") && file.path.hasSuffix(".desk") && !file.path.contains(".formatted") {
        texts.append(file.text)
    }
    for (k, file) in deskFixtureFiles("Diagnostics").enumerated() where k % 10 == 0 {
        texts.append(DeskDiagnosticFixture.parse(path: file.path, text: file.text).positive)
    }
    return texts
}

/// 500 corpus snippets: the 100 longest and 400 spread evenly over the rest.
func deskCompletionSweepSample() -> [String] {
    let corpus = deskExampleCorpus()
    let byLength = corpus.enumerated().sorted { $0.element.utf16.count > $1.element.utf16.count }
    let longest = Set(byLength.prefix(100).map(\.offset))
    let rest = corpus.indices.filter { !longest.contains($0) }
    var picked = longest.sorted()
    if !rest.isEmpty {
        let step = max(1, rest.count / 400)
        picked += stride(from: 0, to: rest.count, by: step).prefix(400).map { rest[$0] }
    }
    return picked.map { corpus[$0] }
}

func runDeskCompletionSweep(_ t: TestRunner) {
    t.suite("Desk: service — completion sweep") {
        t.check(deskCompletionSweepSample().count >= 500, "500 snippets sampled")
        let sample = deskCompletionSweepTexts()
        var positions = 0
        var nonEmpty = 0
        var slowest = (0.0, "")
        for text in sample {
            let snapshot = DeskLanguageService(openFile: DeskFileID(path: "Test.desk"), files: [DeskFileID(path: "Test.desk"): text],
                                               resources: DeskFakeResources()).snapshot
            let length = snapshot.index.utf16Count
            var problems: [String] = []
            for offset in 0...length {
                positions += 1
                let start = ProcessInfo.processInfo.systemUptime
                let list = snapshot.completions(at: snapshot.index.position(utf16: offset))
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if elapsed > slowest.0 { slowest = (elapsed, String(text.prefix(40))) }
                if !list.items.isEmpty { nonEmpty += 1 }
                let r = list.context.range
                if !(0 <= r.start.offset && r.start.offset <= r.end.offset && r.end.offset <= length) { problems.append("context range \(r) at \(offset)") }
                if !(r.start.offset <= offset && offset <= r.end.offset) { problems.append("range \(r) does not hold \(offset)") }
                for item in list.items {
                    let ir = item.range
                    if !(0 <= ir.start.offset && ir.end.offset <= length) { problems.append("\(item.label) range \(ir) at \(offset)") }
                    for edit in item.additionalEdits where !(0 <= edit.range.start.offset && edit.range.end.offset <= length) {
                        problems.append("\(item.label) edit \(edit) at \(offset)")
                    }
                }
            }
            t.check(problems.isEmpty, "\(text.prefix(60)): \(problems.prefix(5))")
        }
        print("    (\(positions) positions of \(sample.count) texts, \(nonEmpty) with items; slowest \(String(format: "%.1f", slowest.0 * 1000)) ms: \(slowest.1.replacingOccurrences(of: "\n", with: "⏎")))")
    }
}
