import Foundation
@testable import DeskLanguage

// Completion in the language service: a table of cases with `|` at the cursor (the place, the items that must come
// first and the ones that must not be offered), every snippet inserted where it is offered and checked, and a sweep of
// every offset of sampled corpus snippets.
//
// `DESK_COMPLETE_DUMP='widget { Text("a").| }'` prints the context and the first items at the `|` (with
// `DESK_COMPLETE_FILE=package.desk` for a package file, `DESK_COMPLETE_ALL=1` for every item).

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
    /// The first must be the first item; all must be among the first ten.
    var top: [String]
    var absent: [String]
    var file = "Test.desk"
    var others: [String: String] = [:]
    var options = DeskServiceOptions()

    init(_ text: String, _ place: DeskCompletionPlace, top: [String] = [], absent: [String] = [], file: String = "Test.desk",
         others: [String: String] = [:], options: DeskServiceOptions = DeskServiceOptions()) {
        self.text = text
        self.place = place
        self.top = top
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
    runDeskCompletionSnippetTests(t)
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
