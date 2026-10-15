import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum SharedReceiptError: Error { case missing }

private func sharedReceiptCopy(_ checked: CheckedFile, symbols: [NodeID: Symbol]? = nil,
                               options: [String: OptionFacts]? = nil) -> CheckedFile {
    var copy = CheckedFile(tree: checked.tree, diagnostics: checked.diagnostics,
        symbols: symbols ?? checked.symbols, types: checked.types, elements: checked.elements,
        dataUses: checked.dataUses, dependencies: checked.dependencies, reactions: checked.reactions,
        freeformOrders: checked.freeformOrders, stringTable: checked.stringTable, requirements: checked.requirements,
        options: options ?? checked.options, styles: checked.styles, translations: checked.translations, root: checked.root)
    copy.loopIdentities = checked.loopIdentities; copy.assets = checked.assets
    copy.declarationTypes = checked.declarationTypes; copy.numericCoercions = checked.numericCoercions
    copy.canonicalNumericValues = checked.canonicalNumericValues
    return copy
}

func runDeskSharedOptionsReceiptTests(_ t: TestRunner) {
    func package(_ source: String) -> CheckedFile {
        let value = deskCheck(source, file: "package.desk")
        t.check(value.diagnostics(.error).isEmpty, deskDescribe(value))
        return value
    }
    func member(_ source: String, _ package: CheckedFile) -> CheckedFile {
        let value = deskCheck(source, file: "Member.desk", context: CheckContext(package: CheckedPackage(file: package)))
        t.check(value.diagnostics(.error).isEmpty, deskDescribe(value))
        return value
    }
    func rejected(_ result: DeskCompilationResult) {
        t.check(result.program == nil && result.packageOptions == nil)
        t.check(result.elementRefs.isEmpty && result.imageSources.isEmpty)
        t.check(!result.issues.isEmpty || result.diagnostics.contains { $0.severity == .error })
    }
    func resolved(_ schema: ProgramOptionsSchema) throws -> [ProgramResolvedOption] {
        let snapshot = try schema.resolve(schema.defaults, revision: 0, language: "zh-Hans", dateInput: nil)
        func flatten(_ nodes: [ProgramResolvedOptionNode]) -> [ProgramResolvedOption] {
            nodes.flatMap { node in
                switch node { case .option(let option): return [option]; case .section(_, let items): return flatten(items) }
            }
        }
        return flatten(snapshot.items)
    }

    t.suite("Desk: shared option receipts: package schema isolates overrides translations and hidden defaults") {
        let shared = package(#"""
            options {
                Section("Group") {
                    show = Toggle("Show", default: true)
                    note = Input("Note", default: "stored").hidden(if: options.show)
                }
            }
            translations { "zh-Hans" { "Show": "包显示"; "Note": "包备注"; "Group": "包分组" } }
            """#)
        let checked = member(#"""
            options { show = Toggle("Local", default: false) }
            widget { Text(options.note) }
            translations { "zh-Hans" { "Note": "成员备注"; "Local": "成员显示" } }
            """#, shared)
        let result = Desk.compile(checked, package: shared)
        t.check(result.issues.isEmpty, "\(result.issues)")
        guard let program = result.program, let schema = result.packageOptions else { throw SharedReceiptError.missing }
        let original = try resolved(schema)
        let effective = try resolved(ProgramOptionsSchema(options: program.options, translations: program.translations))
        t.equal(original.map(\.name), ["show", "note"])
        t.equal(original.map(\.title), ["包显示", "包备注"])
        t.equal(original.map(\.scope), [.package, .package])
        t.equal(original.map(\.hidden), [false, true])
        t.equal(effective.map(\.name), ["show", "note"])
        t.equal(effective.map(\.title), ["成员显示", "成员备注"])
        t.equal(effective.map(\.scope), [.instance, .package])
        t.equal(effective.map(\.hidden), [false, false])
        t.equal(schema.defaults.values["show"], .boolean(true))
        t.equal(schema.defaults.values["note"], .string("stored"))
        t.equal(original, try resolved(schema), "effective resolution cannot mutate package metadata")
    }

    t.suite("Desk: shared option receipts: same enum set permits order labels defaults and typed shared actions") {
        let shared = package(#"options { mode = Picker("Mode", [.dayMode, .nightMode], default: .dayMode) }"#)
        let checked = member(#"""
            options { mode = Picker("Local", [Choice(.nightMode, "Night"), Choice(.dayMode, "Day")], default: .nightMode) }
            widget { Text(options.mode).size(80, 20).onClick { options.mode = .dayMode } }
            """#, shared)
        t.check(!checked.diagnostics.contains { $0.id == .replacedOptionTypeDiffers })
        let result = Desk.compile(checked, package: shared)
        t.check(result.issues.isEmpty, "\(result.issues)")
        guard let program = result.program, let schema = result.packageOptions else { throw SharedReceiptError.missing }
        t.equal(schema.defaults.values["mode"], .localCase(option: "mode", name: "dayMode"))
        let definitions = deskOptionDefinitions(program.options)
        t.equal(definitions.first?.defaultValue, .localCase(option: "mode", name: "nightMode"))
        guard case .picker(let choices) = definitions.first?.control else { throw SharedReceiptError.missing }
        t.equal(choices.map(\.value), [.localCase(option: "mode", name: "nightMode"), .localCase(option: "mode", name: "dayMode")])
        let inherited = member(#"widget { Text(options.mode).size(80, 20).onClick { options.mode = .nightMode } }"#, shared)
        let compiled = Desk.compile(inherited, package: shared)
        t.check(compiled.issues.isEmpty, "\(compiled.issues)")
        guard let inheritedProgram = compiled.program else { throw SharedReceiptError.missing }
        var runtime = try ProgramRuntime(program: inheritedProgram)
        let scene = try runtime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        let clicked = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: scene.generation,
            environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        t.equal(clicked.map { deskOptionTexts($0.scene) }, ["Night Mode"])
    }

    t.suite("Desk: shared option receipts: real cross-file identity is required for reads and assignments") {
        let shared = package(#"options { show = Toggle("Show") }"#)
        let checked = member(#"widget { Text(options.show).onClick { options.show = true } }"#, shared)
        let other = deskCheck(#"options { show = Toggle("Show") }"#, file: "Other/package.desk")
        guard let facts = shared.options["show"], let foreign = other.options["show"] else { throw SharedReceiptError.missing }
        var ids: [NodeID] = [], pending = [checked.tree.rootNode]
        while let node = pending.popLast() {
            if case .option? = checked.symbols[checked.tree.id(of: node)] { ids.append(checked.tree.id(of: node)) }
            pending.append(contentsOf: node.childNodes)
        }
        t.check(ids.count >= 2)
        for id in ids {
            for symbol in [Symbol.option(facts.node, file: other.tree.file), .option(foreign.node, file: shared.tree.file)] {
                var symbols = checked.symbols; symbols[id] = symbol
                rejected(Desk.compile(sharedReceiptCopy(checked, symbols: symbols), package: shared))
            }
        }
        rejected(Desk.compile(checked))
        rejected(Desk.compile(checked, package: other))
        var options = shared.options; options["show"]?.node = foreign.node
        rejected(Desk.compile(checked, package: sharedReceiptCopy(shared, options: options)))
    }

    t.suite("Desk: shared option receipts: replaced metadata and translations retain cumulative budgets") {
        let controls = (0..<8).map { "x\($0) = Toggle(\"Title\($0)\")" }.joined(separator: "; ")
        let source = "options { \(controls) }"
        let shared = package(source)
        let own = deskCheck(source + "\nwidget { Text(\"A\") }")
        let combined = member(source + "\nwidget { Text(\"A\") }", shared)
        let inherited = member("widget { Text(\"A\") }", shared)
        var catalog = DeskCatalog.current; catalog.limits.maximumTokens = 32
        t.check(Desk.compile(own, catalog: catalog).program != nil)
        t.check(Desk.compile(inherited, catalog: catalog, package: shared).program != nil)
        let denied = Desk.compile(combined, catalog: catalog, package: shared)
        rejected(denied); t.equal(denied.issues.first?.kind, .resourceLimit)
        let entries = (0..<8).map { "\"Title\($0)\": \"译\($0)\"" }.joined(separator: "; ")
        let translated = package(source + "\ntranslations { \"zh-Hans\" { \(entries) } }")
        let translatedMember = member("widget { Text(\"A\") }", translated)
        catalog.limits.maximumTokens = 48
        t.check(Desk.compile(inherited, catalog: catalog, package: shared).program != nil)
        let limited = Desk.compile(translatedMember, catalog: catalog, package: translated)
        rejected(limited); t.equal(limited.issues.first?.kind, .resourceLimit)
        t.check(Desk.compile(translatedMember, package: translated).program != nil)
        catalog = .current; catalog.limits.maximumElementInstances = 10
        t.check(Desk.compile(inherited, catalog: catalog, package: shared).program != nil)
        rejected(Desk.compile(combined, catalog: catalog, package: shared))
    }

    t.suite("Desk: shared option receipts: authored translation tables share a construction budget") {
        let entries = (0..<8).map { "\"Unused\($0)\": \"Value\($0)\"" }.joined(separator: "; ")
        let translations = "translations { \"ja\" { \(entries) } }"
        let shared = package(translations)
        let local = deskCheck("widget { Text(\"A\") }\n" + translations)
        let inherited = member("widget { Text(\"A\") }", shared)
        let combined = member("widget { Text(\"A\") }\n" + translations, shared)
        var catalog = DeskCatalog.current; catalog.limits.maximumTokens = 24
        t.check(Desk.compile(local, catalog: catalog).program != nil)
        t.check(Desk.compile(inherited, catalog: catalog, package: shared).program != nil)
        let denied = Desk.compile(combined, catalog: catalog, package: shared)
        rejected(denied); t.equal(denied.issues.first?.kind, .resourceLimit)
        t.check(Desk.compile(combined, package: shared).program != nil)
    }

    t.suite("Desk: shared option receipts: unsupported loser rejects while dynamic package style reads shared options") {
        let shared = package(#"options { tint = ColorPicker("Tint") }"#)
        let checked = member(#"options { tint = ColorPicker("Local") }"# + "\n" + #"widget { Text("A") }"#, shared)
        rejected(Desk.compile(checked, package: shared))
        let styled = package(#"options { size = Slider("Size", min: 1, max: 20) }"# + "\n" + #"style label { .font(options.size) }"#)
        let styledMember = member(#"widget { Text("A").style(label) }"#, styled)
        let admitted = Desk.compile(styledMember, package: styled)
        t.check(admitted.program != nil && admitted.packageOptions != nil)
        t.check(admitted.issues.isEmpty)
        var runtime = try ProgramRuntime(program: admitted.program!)
        let scene = try runtime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        let sizes = scene.drawingItems.compactMap { item -> Double? in
            if case .text(let draw) = item { return TextStyle.pixelSize(points: draw.style.fontSize) }; return nil
        }
        t.equal(sizes, [1])
    }
}
