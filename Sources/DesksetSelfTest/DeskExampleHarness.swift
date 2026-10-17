import Foundation
@testable import DeskLanguage

// The example harness (the language specification §9.7, D136): every catalog example is checked where its
// `exampleContext` puts it, in a widget that declares every permission, the network hosts `example.com` and
// `*.example.com`, the options `weekStart`, `highlight`, `showSeconds`, `city`, `folder`, `apiKey`, the variables
// `page`, `seconds`, `plays`, `dice`, `flags`, `monthsFromNow`, `note`, the computed `month`, and the named elements
// `title`, `details`, `toast`. A name the example declares replaces the harness's item of the same name. The example
// must produce no diagnostic, except the "unused" family and anything located in the harness's own lines.

struct DeskExampleHarness {
    let catalog: DeskCatalog

    struct Built {
        var text: String
        var exampleRange: Range<Int>
    }

    static let permissions = ["music", "location", "calendar", "microphone", "systemAudio", "commands", "notifications",
                              "files", "accessibility"]
    static let options: [(String, String)] = [
        ("weekStart", "Picker(\"Week starts on\", [.sunday, .monday])"), ("highlight", "ColorPicker(\"Highlight color\")"),
        ("showSeconds", "Toggle(\"Show seconds\")"), ("city", "Input(\"City\", default: \"Oslo\")"),
        ("folder", "FolderPicker(\"Folder\")"), ("apiKey", "Secret(\"API key\")"),
    ]
    static let declarations: [(String, String)] = [
        ("page", "variable page = 0"), ("seconds", "variable seconds = 0"), ("plays", "variable plays = 0"),
        ("dice", "variable dice = 1"), ("flags", "variable flags = 0"), ("monthsFromNow", "variable monthsFromNow = 0"),
        ("note", "saved note = \"\""), ("month", "computed month = calendar.month(offset: monthsFromNow)"),
    ]
    static let elements: [(String, String)] = [
        ("title", "Text(\"Title\").name(title)"), ("details", "Text(\"Details\").name(details)"),
        ("toast", "Text(\"Saved\").name(toast)"),
    ]

    /// The element a modifier example is written on: the context's, else one the modifier applies to.
    func host(for example: String, context: ExampleContext) -> String {
        if let kind = context.attachTo { return Self.sample(kind) }
        let name = example.dropFirst().prefix { $0.isLetter || $0.isNumber }
        guard let modifier = catalog.modifier(named: String(name)) else { return Self.sample(.text) }
        for kind in [ElementKind.text, .rectangle, .progress, .image, .icon, .label, .column, .input, .graph] where modifier.appliesTo.contains(kind) {
            return Self.sample(kind)
        }
        return Self.sample(modifier.appliesTo.kinds.first ?? .text)
    }

    static func sample(_ kind: ElementKind) -> String {
        switch kind {
        case .text: return "Text(\"Sample\")"
        case .label: return "Label(\"Sample\", icon: \"wifi\")"
        case .icon: return "Icon(\"wifi\")"
        case .image: return "Image(\"photo.png\")"
        case .progress: return "Progress(cpu.usage)"
        case .gauge: return "Gauge(cpu.usage)"
        case .graph: return "Graph(cpu.usage)"
        case .rectangle: return "Rectangle()"
        case .circle: return "Circle()"
        case .ellipse: return "Ellipse()"
        case .capsule: return "Capsule()"
        case .line: return "Line()"
        case .arc: return "Arc(from: 0, to: 90)"
        case .path: return "Path(\"M0 0 L10 10\")"
        case .input: return "Input(note)"
        case .column: return "Column { Text(\"Sample\") }"
        case .row: return "Row { Text(\"Sample\") }"
        case .button: return "Button(\"Sample\")"
        default: return "Text(\"Sample\")"
        }
    }

    func build(_ example: String, context: ExampleContext) -> Built {
        var replaced = Set(context.replaces)
        // A declaration or option the example writes replaces the harness's item of that name.
        for keyword in ["variable ", "saved ", "computed "] where example.hasPrefix(keyword) {
            replaced.insert(String(example.dropFirst(keyword.count).prefix { $0.isLetter || $0.isNumber }))
        }
        var text = ""
        var exampleRange = 0..<0
        func append(_ piece: String) { text += piece }
        func appendExample(_ prefix: String, _ suffix: String = "") {
            text += prefix
            let start = text.utf8.count
            text += example
            exampleRange = start..<text.utf8.count
            text += suffix
        }
        // info
        append("info {\n")
        if context.placement == .infoField {
            appendExample("    ", "\n")
        }
        if !replaced.contains("name") || context.placement != .infoField { append("    name: \"Harness\"\n") }
        if !replaced.contains("permissions") {
            append("    permissions: [" + Self.permissions.map { "." + $0 }.joined(separator: ", ") + "]\n")
        }
        if !replaced.contains("network") { append("    network: [\"example.com\", \"*.example.com\"]\n") }
        if context.convertedFile { append("    convertedFrom: \"rainmeter\"\n") }
        append("}\n\n")
        // options
        append("options {\n")
        for (name, control) in Self.options where !replaced.contains(name) { append("    \(name) = \(control)\n") }
        if context.placement == .optionItem { appendExample("    ", "\n") }
        if context.placement == .modifiers && context.parent == .options { appendExample("    extra = Toggle(\"Extra\")", "\n") }
        if context.placement == .view && (context.parent == .options || context.parent == .section) { appendExample("    ", "\n") }
        append("}\n\n")
        // widget
        append("widget {\n")
        for declaration in context.declarations where !declaration.hasPrefix("style ") { append("    \(declaration)\n") }
        for (name, declaration) in Self.declarations where !replaced.contains(name) { append("    \(declaration)\n") }
        if context.placement == .declaration { appendExample("    ", "\n") }
        append("\n    Column {\n")
        for (name, element) in Self.elements where !replaced.contains(name) && !(context.parent == .freeform && name == "title") {
            append("        \(element)\n")
        }
        let parentOpen: String, parentClose: String
        switch context.parent {
        case .freeform: parentOpen = "        Freeform {\n"; parentClose = "        }\n"
        case .grid: parentOpen = "        Grid(columns: 2) {\n"; parentClose = "        }\n"
        case .row: parentOpen = "        Row {\n"; parentClose = "        }\n"
        case .menu: parentOpen = "        Text(\"Menu\").menu {\n"; parentClose = "        }\n"
        default: parentOpen = "        Column {\n"; parentClose = "        }\n"
        }
        if context.placement == .view || context.placement == .modifiers || context.placement == .actions,
           !(context.parent == .options || context.parent == .section) {
            append(parentOpen)
            for sibling in context.siblings { append("            \(sibling)\n") }
            switch context.placement {
            case .view:
                appendExample("            ", "\n")
            case .modifiers:
                appendExample("            " + host(for: example, context: context), "\n")
            default:
                appendExample("            Text(\"Act\").onClick {\n                ", "\n            }\n")
            }
            append(parentClose)
        }
        append("    }\n}\n")
        for declaration in context.declarations where declaration.hasPrefix("style ") { append("\n\(declaration)\n") }
        if context.placement == .topLevel { appendExample("\n", "\n") }
        return Built(text: text, exampleRange: exampleRange)
    }

    /// Diagnostics the example causes (the harness's own and the unused family are filtered).
    func problems(_ example: String, context: ExampleContext, checkContext: CheckContext) -> [Diagnostic] {
        let built = build(example, context: context)
        let checked = Desk.check(Desk.parse(built.text, fileName: "Harness.desk"), context: checkContext)
        let unused: Set<DiagnosticID> = [.unusedDeclaration, .unusedStyle, .unusedOption, .unusedPermission, .unusedHost]
        return checked.diagnostics.filter { d in
            !unused.contains(d.id) && built.exampleRange.overlaps(d.range.lowerBound..<max(d.range.upperBound, d.range.lowerBound + 1))
        }
    }
}

func runDeskExampleHarnessTests(_ t: TestRunner) {
    let catalog = DeskCatalog.current
    let harness = DeskExampleHarness(catalog: catalog)
    var checkContext = CheckContext()
    checkContext.resources = DeskFakeResources()

    t.suite("Desk: example harness — the harness itself is clean") {
        let built = harness.build("Text(\"Harness\")", context: ExampleContext())
        let checked = Desk.check(Desk.parse(built.text, fileName: "Harness.desk"), context: checkContext)
        let unused: Set<DiagnosticID> = [.unusedDeclaration, .unusedStyle, .unusedOption, .unusedPermission, .unusedHost]
        let errors = checked.diagnostics.filter { !unused.contains($0.id) }
        t.equal(errors.map { "\($0.id.rawValue)@\(checked.tree.location(of: $0.range.lowerBound)): \($0.message(in: .english))" }, [])
    }

    t.suite("Desk: example harness — every catalog example checks clean") {
        var count = 0
        var failures = 0
        for item in catalog.documentedItems() {
            let example = item.doc.example
            guard !example.isEmpty else { continue }
            count += 1
            let problems = harness.problems(example, context: item.doc.exampleContext, checkContext: checkContext)
            if !problems.isEmpty {
                failures += 1
                let built = harness.build(example, context: item.doc.exampleContext)
                let checked = Desk.parse(built.text, fileName: "Harness.desk")
                let described = problems.map { "\($0.id.rawValue)@\(checked.location(of: $0.range.lowerBound)): \($0.message(in: .english))" }
                t.check(false, "\(item.path): \(example) → \(described)")
            }
        }
        t.check(count > 400, "examples: \(count)")
        if failures > 0 { print("    \(failures) of \(count) examples have problems") }
        // The harness catches what is wrong in an example.
        for wrong in ["Text(\"{cpuu.usage}\")", ".colour(.red)", "Txt(\"A\")", ".every(500) { page = page + 1 }",
                      "computed x = cpu.usage + memory.used", "Text(\"A\").style(nothing)"] {
            let context = DeskCatalog.current.documentedItems().first.map { _ in ExampleContext() } ?? ExampleContext()
            var c = context
            if wrong.hasPrefix(".") { c.placement = .modifiers }
            if wrong.hasPrefix("computed") { c.placement = .declaration }
            t.check(!harness.problems(wrong, context: c, checkContext: checkContext).isEmpty, "the harness catches \(wrong)")
        }
    }
}

/// `DESK_HARNESS_DUMP=substring`: prints the harness text and every diagnostic of the examples containing it.
func runDeskHarnessDump(_ t: TestRunner) {
    guard let needle = ProcessInfo.processInfo.environment["DESK_HARNESS_DUMP"] else { return }
    let harness = DeskExampleHarness(catalog: .current)
    t.suite("Desk: harness dump") {
        for item in DeskCatalog.current.documentedItems() where item.doc.example.contains(needle) {
            let built = harness.build(item.doc.example, context: item.doc.exampleContext)
            print("=== \(item.path)\n\(built.text)")
            print(deskDescribe(Desk.check(Desk.parse(built.text, fileName: "Harness.desk"))))
        }
    }
}
