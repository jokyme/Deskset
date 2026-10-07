import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private func optionFacts(_ checked: CheckedFile, options: [String: OptionFacts]? = nil,
                         symbols: [NodeID: Symbol]? = nil, types: [NodeID: SemType]? = nil,
                         dependencies: [NodeID: Set<DepKey>]? = nil, canonical: [NodeID: Double]? = nil) -> CheckedFile {
    var copy = CheckedFile(tree: checked.tree, diagnostics: checked.diagnostics,
        symbols: symbols ?? checked.symbols, types: types ?? checked.types, elements: checked.elements,
        dataUses: checked.dataUses, dependencies: dependencies ?? checked.dependencies, reactions: checked.reactions,
        freeformOrders: checked.freeformOrders, stringTable: checked.stringTable, requirements: checked.requirements,
        options: options ?? checked.options, styles: checked.styles, translations: checked.translations, root: checked.root)
    copy.loopIdentities = checked.loopIdentities; copy.assets = checked.assets
    copy.declarationTypes = checked.declarationTypes; copy.numericCoercions = checked.numericCoercions
    copy.canonicalNumericValues = canonical ?? checked.canonicalNumericValues
    return copy
}

private func optionNode(_ checked: CheckedFile, kind: SyntaxKind, text: String) throws -> PositionedNode {
    var pending = [checked.tree.rootNode]
    while let node = pending.popLast() {
        if node.kind == kind && node.node.trimmedText == text { return node }
        pending.append(contentsOf: node.childNodes.reversed())
    }
    throw DeskOptionFixtureError.receipt
}

private func optionRejected(_ t: TestRunner, _ checked: CheckedFile, catalog: DeskCatalog = .current, reason: String) {
    let result = Desk.compile(checked, catalog: catalog)
    t.check(result.program == nil && !result.issues.isEmpty, "\(reason): \(result.issues)")
    t.check(result.elementRefs.isEmpty && result.imageSources.isEmpty, reason)
    t.equal(result.diagnostics, checked.diagnostics, reason)
}

func runDeskOptionReceiptTests(_ t: TestRunner) {
    t.suite("Desk: option receipts: every final declaration fact matches its real source") {
        let (checked, _) = try deskOptionCompilation(t,
            #"options { level = Slider("Level", min: 0, max: 10, default: 5); show = Toggle("Show") }"# + "\n" + #"widget { Text(options.level) }"#)
        guard let original = checked.options["level"], let other = checked.options["show"] else { throw DeskOptionFixtureError.receipt }
        let changes: [(String, (inout OptionFacts) -> Void)] = [
            ("name", { $0.name = "renamed" }), ("control", { $0.control = "Stepper" }),
            ("type", { $0.type = .string }), ("base", { $0.displayBase = 1024 }),
            ("scope", { $0.scope = .package }), ("node", { $0.node = other.node }),
            ("default", { $0.defaultText = "6" }), ("choices", { $0.choices = ["other"] })]
        for (reason, change) in changes {
            var value = original; change(&value)
            var facts = checked.options; facts["level"] = value
            optionRejected(t, optionFacts(checked, options: facts), reason: reason)
        }
        var missing = checked.options; missing["show"] = nil
        optionRejected(t, optionFacts(checked, options: missing), reason: "omitted authored declaration")
    }

    t.suite("Desk: option receipts: numeric leaves wrappers and defaults retain exact canonical dimensions") {
        let (checked, _) = try deskOptionCompilation(t,
            #"options { length = Slider("Length", min: (1pt), max: 10pt, default: 5pt) }"# + "\n" + #"widget { Text(options.length) }"#)
        for (kind, text) in [(SyntaxKind.numberLiteral, "1pt"), (.parenExpr, "(1pt)"), (.numberLiteral, "10pt"), (.numberLiteral, "5pt")] {
            let node = try optionNode(checked, kind: kind, text: text), id = checked.tree.id(of: node)
            var values = checked.canonicalNumericValues; values[id] = 999
            optionRejected(t, optionFacts(checked, canonical: values), reason: "changed canonical \(text)")
            var types = checked.types; types[id] = SemType(type: .duration)
            optionRejected(t, optionFacts(checked, types: types), reason: "changed dimension \(text)")
            values = checked.canonicalNumericValues; values[id] = nil
            optionRejected(t, optionFacts(checked, canonical: values), reason: "removed canonical \(text)")
        }
        let invalid = deskCheck(#"options { duration = Stepper("Duration", min: 1s, max: 10s, default: 5) }"# + "\n" + #"widget { Text("A") }"#)
        t.check(invalid.diagnostics(.error).contains { $0.id == .unitNeeded })
        t.check(Desk.compile(invalid).program == nil)
    }

    t.suite("Desk: option receipts: local enum choices defaults and actions use final nominal membership") {
        let source = #"options { theme = Picker("Theme", [.dayMode, .nightMode], default: .nightMode) }"# + "\n" +
            #"widget { Text(options.theme).size(60).onClick { options.theme = .dayMode } }"#
        let (checked, program) = try deskOptionCompilation(t, source)
        let choice = try optionNode(checked, kind: .implicitMemberExpr, text: ".dayMode")
        t.check(checked.types[checked.tree.id(of: choice)] == nil, "the real enum choice has no invented expression type")
        guard var facts = checked.options["theme"] else { throw DeskOptionFixtureError.receipt }
        t.equal(facts.type, .enumeration("Theme"))
        var options = checked.options; facts.choices.reverse(); options["theme"] = facts
        optionRejected(t, optionFacts(checked, options: options), reason: "reordered case facts")
        facts = checked.options["theme"]!; facts.localEnum = "Other"; facts.type = .enumeration("Other"); options["theme"] = facts
        optionRejected(t, optionFacts(checked, options: options), reason: "renamed nominal identity")
        var types = checked.types; types[checked.tree.id(of: choice)] = SemType(type: .string)
        optionRejected(t, optionFacts(checked, types: types), reason: "forged choice type")
        var symbols = checked.symbols; symbols[checked.tree.id(of: choice)] = .enumCase(type: "Other", case: "dayMode")
        optionRejected(t, optionFacts(checked, symbols: symbols), reason: "forged choice symbol")
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        let accepted = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        t.equal(accepted.map { deskOptionTexts($0.scene) }, ["Day Mode"])
        let nonmember = deskCheck(source.replacingOccurrences(of: "options.theme = .dayMode", with: "options.theme = .otherMode"))
        let denied = Desk.compile(nonmember)
        t.check(denied.program == nil, "even the checker's deferred bare case must belong to the final option enum")
        let (_, repeated) = try deskOptionCompilation(t,
            #"options { theme = Picker("Theme", [Choice(.dayMode, "First"), Choice(.dayMode, "Second"), .nightMode]); number = Picker("Number", [1, 1, 2]); word = Picker("Word", ["A", "A", "B"]) }"# + "\n" + #"widget { Text(options.theme) }"#)
        let definitions = deskOptionDefinitions(repeated.options)
        for definition in definitions {
            guard case .picker(let choices) = definition.control else { throw DeskOptionFixtureError.receipt }
            t.equal(choices.count, 3); t.equal(choices[0].value, choices[1].value)
        }
        var duplicate = try ProgramRuntime(program: repeated)
        t.equal(deskOptionTexts(try duplicate.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)), ["First"])
    }

    t.suite("Desk: option receipts: reads and assignment targets cannot change identity or fold live values") {
        let (checked, _) = try deskOptionCompilation(t,
            #"options { level = Slider("Level", min: 0, max: 10); other = Slider("Other", min: 0, max: 10) }"# + "\n" +
            #"widget { Text((options.level)).onClick { options.level = 5 } }"#)
        let member = try optionNode(checked, kind: .memberExpr, text: "options.level"), id = checked.tree.id(of: member)
        guard let other = checked.options["other"] else { throw DeskOptionFixtureError.receipt }
        var symbols = checked.symbols; symbols[id] = .option(other.node, file: checked.tree.file)
        optionRejected(t, optionFacts(checked, symbols: symbols), reason: "read another declaration")
        symbols = checked.symbols; symbols[id] = .option(checked.options["level"]!.node, file: DeskFileID("Other.desk"))
        optionRejected(t, optionFacts(checked, symbols: symbols), reason: "read another source")
        for node in [member, try optionNode(checked, kind: .parenExpr, text: "(options.level)")] {
            var values = checked.canonicalNumericValues; values[checked.tree.id(of: node)] = 999
            optionRejected(t, optionFacts(checked, canonical: values), reason: "folded live option \(node.node.trimmedText)")
        }
        var pending = [checked.tree.rootNode], target: PositionedNode?
        while let node = pending.popLast() {
            if let assignment = AssignmentSyntax(node) { target = assignment.target.node; break }
            pending.append(contentsOf: node.childNodes)
        }
        guard let target else { throw DeskOptionFixtureError.receipt }
        symbols = checked.symbols; symbols[checked.tree.id(of: target)] = .option(other.node, file: checked.tree.file)
        optionRejected(t, optionFacts(checked, symbols: symbols), reason: "assignment changed its receiver")
    }

    t.suite("Desk: option receipts: hidden conditions retain exact dependencies and real option leaves") {
        let (checked, _) = try deskOptionCompilation(t,
            #"options { show = Toggle("Show"); note = Input("Note").hidden(if: options.show) }"# + "\n" + #"widget { Text("A") }"#)
        let node = try optionNode(checked, kind: .memberExpr, text: "options.show"), id = checked.tree.id(of: node)
        t.equal(checked.dependencies[id], Set([.option("show")]))
        var dependencies = checked.dependencies; dependencies[id] = []
        optionRejected(t, optionFacts(checked, dependencies: dependencies), reason: "missing source dependency")
        dependencies = checked.dependencies; dependencies[id] = [.data("battery.charging")]
        optionRejected(t, optionFacts(checked, dependencies: dependencies), reason: "non-option dependency")
        var types = checked.types; types[id] = SemType(type: .string)
        optionRejected(t, optionFacts(checked, types: types), reason: "non-Bool hidden value")
        var symbols = checked.symbols; symbols[id] = .builtIn(.member(namespace: "battery", name: "charging"))
        optionRejected(t, optionFacts(checked, symbols: symbols), reason: "data disguised as local option")
    }

    t.suite("Desk: option receipts: exact control modifier and Choice catalog contracts are required") {
        let source = #"options { theme = Picker("Theme", [Choice(.dayMode, "Day"), .nightMode]); level = Slider("Level", min: 0, max: 10); note = Input("Note").help("Help").hidden() }"# + "\n" + #"widget { Text("A") }"#
        let (checked, _) = try deskOptionCompilation(t, source)
        for name in ["Picker", "Slider", "Choice", "Input"] {
            var catalog = DeskCatalog.current
            guard let index = catalog.controls.firstIndex(where: { $0.name == name }) else { throw DeskOptionFixtureError.receipt }
            catalog.controls[index].signatures[0].params[0].translatable.toggle()
            optionRejected(t, checked, catalog: catalog, reason: "changed \(name) parameter contract")
        }
        for name in ["help", "hidden"] {
            var catalog = DeskCatalog.current
            guard let index = catalog.modifiers.firstIndex(where: { $0.name == name }) else { throw DeskOptionFixtureError.receipt }
            catalog.modifiers[index].repeatable = .yes
            if name == "hidden" { catalog.modifiers[index].repeatable = .no }
            optionRejected(t, checked, catalog: catalog, reason: "changed \(name) repeatability")
        }
        let control = try optionNode(checked, kind: .callee, text: "Slider")
        var symbols = checked.symbols; symbols[checked.tree.id(of: control)] = .builtIn(.control("Toggle"))
        optionRejected(t, optionFacts(checked, symbols: symbols), reason: "changed actual control symbol")
    }

    t.suite("Desk: option receipts: metadata shares expression node text and storage budgets") {
        var catalog = DeskCatalog.current; catalog.limits.maximumTokens = 32
        let tiny = deskCheck(#"options { show = Toggle("Show") }"# + "\n" + #"widget { Text("A") }"#)
        t.check(Desk.compile(tiny, catalog: catalog).program != nil)
        let controls = (0..<24).map { "x\($0) = Toggle(\"X\")" }.joined(separator: "; ")
        let checked = deskCheck("options { \(controls) }\nwidget { Text(\"A\") }")
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        let limited = Desk.compile(checked, catalog: catalog)
        t.equal(limited.issues.first?.kind, .resourceLimit); t.check(limited.program == nil && limited.elementRefs.isEmpty)
        catalog = .current; catalog.limits.maximumElementInstances = 1
        t.equal(Desk.compile(tiny, catalog: catalog).issues.first?.kind, .resourceLimit, "option and view share the node limit")
        let text = deskCheck(#"options { note = Input("N", default: "😀😀😀") }"# + "\n" + #"widget { Text("A") }"#)
        catalog = .current; catalog.limits.maximumSavedValueBytes = 8
        t.equal(Desk.compile(text, catalog: catalog).issues.first?.kind, .resourceLimit, "stored String counts UTF8 bytes")
    }
}
