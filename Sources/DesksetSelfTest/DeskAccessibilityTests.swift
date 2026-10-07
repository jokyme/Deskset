import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum DeskAccessibilityFixtureError: Error { case program, receipt }

private func accessibilityProgram(_ t: TestRunner, _ source: String) throws -> WidgetProgram {
    let checked = deskCheck(source)
    let result = Desk.compile(checked)
    t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
    t.check(result.issues.isEmpty, "\(result.issues)")
    guard let program = result.program else { throw DeskAccessibilityFixtureError.program }
    return program
}

private func accessibilityEnvironment(_ dark: Bool = false) -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1,
        appearance: AppearanceStamp(value: dark ? .dark : .light, name: dark ? "dark" : "light"), imageGeneration: 0)
}

private func accessibilityDate(_ locale: String = "en_US", seconds: Double = 0) -> ProgramDateInput {
    ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!,
                     locale: Locale(identifier: locale))
}

private func accessibilityMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    SkinSize(width: 20, height: 12)
}

private func accessibilityFacts(_ checked: CheckedFile, symbols: [NodeID: Symbol]? = nil,
                                types: [NodeID: SemType]? = nil, elements: [NodeID: ElementFacts]? = nil,
                                dataUses: [DataUse]? = nil) -> CheckedFile {
    var value = CheckedFile(tree: checked.tree, diagnostics: checked.diagnostics,
        symbols: symbols ?? checked.symbols, types: types ?? checked.types, elements: elements ?? checked.elements,
        dataUses: dataUses ?? checked.dataUses, dependencies: checked.dependencies, reactions: checked.reactions,
        freeformOrders: checked.freeformOrders, stringTable: checked.stringTable, requirements: checked.requirements,
        options: checked.options, styles: checked.styles, translations: checked.translations, root: checked.root)
    value.loopIdentities = checked.loopIdentities; value.assets = checked.assets
    value.declarationTypes = checked.declarationTypes
    value.canonicalNumericValues = checked.canonicalNumericValues; value.numericCoercions = checked.numericCoercions
    return value
}

func runDeskAccessibilityTests(_ t: TestRunner) {
    t.suite("Desk: accessibility: supported views retain own labels without inheritance or layout changes") {
        for view in [#"Text("A")"#, "Rectangle()", "Circle()", "Ellipse()", "Capsule()",
                     #"Image("image.png")"#, "Progress(0.25)", "Gauge(0.25)",
                     #"Column { Text("A") }"#, #"Row { Text("A") }"#, #"Freeform { Text("A") }"#] {
            let program = try accessibilityProgram(t, "widget { \(view).voiceOver(\"Explicit label\") }")
            t.equal(program.root.voiceOver, .string("Explicit label"), view)
        }
        let source = #"widget { Column { Text("A").voiceOver("Inner"); Row { Text("B") } }.voiceOver("Outer") }"#
        var runtime = try ProgramRuntime(program: accessibilityProgram(t, source))
        let scene = try runtime.project(environment: accessibilityEnvironment(), measure: accessibilityMeasure)
        t.equal(scene.elements.map(\.accessibilityLabel), ["Outer", "Inner", nil, nil])
        t.equal(scene.size, SkinSize(width: 20, height: 32), "labels do not participate in layout")
        var plain = try ProgramRuntime(program: accessibilityProgram(t,
            #"widget { Column { Text("A"); Row { Text("B") } } }"#))
        let baseline = try plain.project(environment: accessibilityEnvironment(), measure: accessibilityMeasure)
        t.equal(scene.elements.map(\.frame), baseline.elements.map(\.frame))
        t.equal(scene.drawingItems, baseline.drawingItems)

        var empty = try ProgramRuntime(program: accessibilityProgram(t, #"widget { Text("A").voiceOver("") }"#))
        t.equal(try empty.project(environment: accessibilityEnvironment(), measure: accessibilityMeasure)
            .elements.first?.accessibilityLabel, "", "an explicit empty label is distinct from no label")
        var implicit = try ProgramRuntime(program: accessibilityProgram(t,
            #"widget { Text("A").voiceOver("First"); Text("B").voiceOver("Second") }"#))
        t.equal(try implicit.project(environment: accessibilityEnvironment(), measure: accessibilityMeasure)
            .elements.map(\.accessibilityLabel), [nil, "First", "Second"])
    }

    t.suite("Desk: accessibility: numeric Bool Duration Date and conditional labels share text and copy formatting") {
        let expressions = ["42", "25%", "90s", "time.now", "battery.present", "battery.timeRemaining",
            "battery.present ? battery.timeRemaining : 90s", #""CPU {cpu.usage}""#,
            #"battery.present ? true : "Unavailable""#]
        for locale in ["en_US", "zh_CN"] {
            for expression in expressions {
                let source = "widget { Text(\(expression)).size(80, 30).voiceOver(\(expression)).onClick { copy(\(expression)) } }"
                var runtime = try ProgramRuntime(program: accessibilityProgram(t, source))
                let date = accessibilityDate(locale)
                let input = ProgramSystemInput(cpuUsage: 42, batteryPresent: true, batteryTimeRemaining: 273_852)
                let scene = try runtime.project(environment: accessibilityEnvironment(), dateInput: date,
                    systemInput: input, measure: accessibilityMeasure)
                guard let label = scene.elements.first?.accessibilityLabel,
                      case .text(let draw)? = scene.drawingItems.first else { throw DeskAccessibilityFixtureError.program }
                t.equal(label, draw.text, "\(locale): \(expression)")
                let clicked = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: scene.generation,
                    environment: accessibilityEnvironment(), dateInput: date, systemInput: input, measure: accessibilityMeasure)
                t.equal(clicked?.effects, [.copy(label)], "\(locale): \(expression)")
                t.equal(clicked?.scene.elements.first?.accessibilityLabel, label)
                if expression == "42" { t.equal(label, "42") }
                if expression == "25%" { t.equal(label, "25", "the catalog percent default omits the written percent sign") }
                if expression == "battery.present" { t.equal(label, locale == "en_US" ? "Yes" : "是") }
            }
        }
        var conditional = try ProgramRuntime(program: accessibilityProgram(t,
            #"widget { Text("Visible").voiceOver(battery.present ? battery.timeRemaining : 90s) }"#))
        let falseBranch = try conditional.project(environment: accessibilityEnvironment(), dateInput: accessibilityDate(),
            systemInput: ProgramSystemInput(batteryPresent: false), measure: accessibilityMeasure)
        t.equal(falseBranch.elements.first?.accessibilityLabel, "1 minute, 30 seconds")
        t.equal(conditional.clockPrecision, nil, "the selected literal branch has no live clock")
    }

    t.suite("Desk: accessibility: label-only live inputs recover from missing and hidden labels do not poll") {
        var cpu = try ProgramRuntime(program: accessibilityProgram(t, #"widget { Rectangle().size(40).voiceOver(cpu.usage) }"#))
        t.equal(cpu.neededSystemProperties, [.cpuUsage])
        let first = try cpu.project(environment: accessibilityEnvironment(), dateInput: accessibilityDate(),
            systemInput: ProgramSystemInput(cpuUsage: 42), measure: accessibilityMeasure)
        t.equal(first.elements.first?.accessibilityLabel, "42")
        let missing = try cpu.project(environment: accessibilityEnvironment(), dateInput: accessibilityDate(),
            systemInput: ProgramSystemInput(), measure: accessibilityMeasure)
        t.equal(missing.elements.first?.accessibilityLabel, "–")
        let recovered = try cpu.project(environment: accessibilityEnvironment(), dateInput: accessibilityDate(),
            systemInput: ProgramSystemInput(cpuUsage: 60), measure: accessibilityMeasure)
        t.equal(recovered.elements.first?.accessibilityLabel, "60")
        t.equal([first.generation, missing.generation, recovered.generation], [1, 2, 3])

        var remaining = try ProgramRuntime(program: accessibilityProgram(t,
            #"widget { Text("Battery").voiceOver((battery.timeRemaining)) }"#))
        t.equal(remaining.neededSystemProperties, [.batteryTimeRemaining])
        t.equal(try remaining.project(environment: accessibilityEnvironment(), dateInput: accessibilityDate(),
            systemInput: ProgramSystemInput(batteryTimeRemaining: 273_852), measure: accessibilityMeasure)
            .elements.first?.accessibilityLabel, "3d 4h")
        t.equal(remaining.clockPrecision, .minute)

        for source in [#"widget { Text("Hidden").voiceOver(time.now).hidden() }"#,
                       #"widget { Text("Hidden").voiceOver(cpu.usage).hidden() }"#,
                       #"widget { Column { Text("Hidden").voiceOver(battery.timeRemaining) }.hidden() }"#] {
            var hidden = try ProgramRuntime(program: accessibilityProgram(t, source))
            t.equal(hidden.neededSystemProperties, [], source)
            let scene = try hidden.project(environment: accessibilityEnvironment(), measure: accessibilityMeasure)
            t.check(scene.elements.allSatisfy { $0.accessibilityLabel == nil }, source)
            t.equal(hidden.clockPrecision, nil)
            t.check(scene.drawingItems.isEmpty)
        }
    }

    t.suite("Desk: accessibility: declarations startup and ordered actions update computed labels transactionally") {
        let source = #"widget { variable count = 1; computed spoken = system.dark ? count : count + 1; Text("Action").size(80, 30).voiceOver(spoken).onLoad { count = 2 }.onClick { count = count + 1; copy(spoken) } }"#
        var runtime = try ProgramRuntime(program: accessibilityProgram(t, source))
        let first = try runtime.project(environment: accessibilityEnvironment(), measure: accessibilityMeasure)
        t.equal(first.elements.first?.accessibilityLabel, "3")
        let clicked = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: accessibilityEnvironment(), measure: accessibilityMeasure)
        t.equal(clicked?.effects, [.copy("4")])
        t.equal(clicked?.scene.elements.first?.accessibilityLabel, "4")
        let dark = try runtime.project(environment: accessibilityEnvironment(true), measure: accessibilityMeasure)
        t.equal(dark.elements.first?.accessibilityLabel, "3", "computed labels use this scene's appearance and committed variable")
        t.equal(runtime.clockPrecision, nil)
        t.check(try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: accessibilityEnvironment(), measure: accessibilityMeasure) == nil, "stale actions do not change labels")
    }

    t.suite("Desk: accessibility: damaged display catalog and own argument receipts reject publication") {
        let checked = deskCheck(#"widget { Rectangle().size(40).voiceOver(battery.timeRemaining) }"#)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        guard let element = checked.elements.first, let candidate = element.value.facets["voiceOver"]?.first,
              case .own(let origin) = candidate.origin,
              let modifierIndex = DeskCatalog.current.modifiers.firstIndex(where: { $0.name == "voiceOver" }),
              let facetIndex = DeskCatalog.current.facets.firstIndex(where: { $0.id == "voiceOver" }) else {
            throw DeskAccessibilityFixtureError.receipt
        }
        func rejected(_ value: CheckedFile, catalog: DeskCatalog = .current) {
            let result = Desk.compile(value, catalog: catalog)
            t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty)
            t.check(!result.issues.isEmpty, "\(result.issues)")
            t.equal(result.diagnostics, value.diagnostics)
        }
        var symbols = checked.symbols; symbols.removeValue(forKey: origin)
        rejected(accessibilityFacts(checked, symbols: symbols))
        symbols = checked.symbols; symbols.removeValue(forKey: candidate.value)
        rejected(accessibilityFacts(checked, symbols: symbols))
        var types = checked.types; types.removeValue(forKey: candidate.value)
        rejected(accessibilityFacts(checked, types: types))
        types = checked.types; types[candidate.value] = SemType(type: .bool)
        rejected(accessibilityFacts(checked, types: types))
        rejected(accessibilityFacts(checked, dataUses: []))
        for damage in ["missing", "value", "origin", "fixed", "duplicate", "inherited"] {
            var elements = checked.elements
            switch damage {
            case "missing": elements[element.key]?.facets.removeValue(forKey: "voiceOver")
            case "value": elements[element.key]?.facets["voiceOver"]?[0].value = origin
            case "origin": elements[element.key]?.facets["voiceOver"]?[0].origin = .own(candidate.value)
            case "fixed": elements[element.key]?.facets["voiceOver"]?[0].fixedValue = #""Forged""#
            case "duplicate": elements[element.key]?.facets["voiceOver"]?.append(candidate)
            default: elements[element.key]?.inherits.insert("voiceOver")
            }
            rejected(accessibilityFacts(checked, elements: elements))
        }
        let changes: [(inout ModifierSpec) -> Void] = [
            { $0.inheritable = true }, { $0.facets = [] }, { $0.fixedValues = ["voiceOver": #""Fixed""#] },
            { $0.signatures[0].params[0].type = .any }, { $0.signatures[0].params[0].role = .plain },
            { $0.signatures[0].params[0].translatable = false }, { $0.signatures[0].params[0].source = .literal },
            { $0.signatures[0].params[0].defaultValue = .source(#""Default""#) },
            { $0.signatures[0].params[0].facets = [] }]
        for change in changes {
            var catalog = DeskCatalog.current; change(&catalog.modifiers[modifierIndex])
            rejected(checked, catalog: catalog)
        }
        var catalog = DeskCatalog.current; catalog.facets[facetIndex].inheritable = true
        rejected(checked, catalog: catalog)
    }

    t.suite("Desk: accessibility: unsupported dimensions styles conditions and limits remain explicit") {
        for source in [#"widget { Text("A").voiceOver(2W) }"#,
                       #"widget { Text("A").voiceOver(true ? 2W : "Allowed") }"#,
                       #"widget { Text("A").voiceOver("Label", if: true) }"#,
                       #"widget { Text("A").voiceOver(battery.health) }"#,
                       #"widget { Text("A").voiceOver("Label").margin(1) }"#,
                       #"widget { Text("A").style(label) }"# + "\n" + #"style label { .voiceOver("Label") }"#] {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            let result = Desk.compile(checked)
            t.check(result.program == nil && !result.issues.isEmpty, source)
            t.equal(result.diagnostics, checked.diagnostics)
            t.check(result.elementRefs.isEmpty && result.imageSources.isEmpty)
        }
        let spacer = deskCheck(#"widget { Column { Text("A"); Spacer().voiceOver("Empty") } }"#)
        t.check(spacer.diagnostics.contains { $0.id == .notApplicable })
        t.check(Desk.compile(spacer).program == nil)
        for (source, nesting, tokens) in [
            (#"widget { Text("A").voiceOver((((cpu.usage)))) }"#, 2, 1000),
            (#"widget { Text("A").voiceOver(system.dark ? (cpu.usage + 1%) : (cpu.usage + 2%)) }"#, 100, 4)] {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            var catalog = DeskCatalog.current
            catalog.limits.maximumExpressionNesting = nesting; catalog.limits.maximumTokens = tokens
            let result = Desk.compile(checked, catalog: catalog)
            t.equal(result.issues.first?.kind, .resourceLimit)
            t.check(result.program == nil && result.elementRefs.isEmpty)
        }
    }
}
