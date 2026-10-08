import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum DeskConditionalFixtureError: Error { case program, receipt, drawing }

private func conditionalProgram(_ t: TestRunner, _ source: String) throws -> WidgetProgram {
    let checked = deskCheck(source)
    let result = Desk.compile(checked)
    t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
    t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
    t.equal(result.diagnostics, checked.diagnostics)
    guard let program = result.program else { throw DeskConditionalFixtureError.program }
    return program
}

private func conditionalEnvironment() -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1,
        appearance: AppearanceStamp(value: .light, name: "light"), imageGeneration: 0)
}

private func conditionalDate(_ seconds: Double = 0) -> ProgramDateInput {
    ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!,
                     locale: Locale(identifier: "en_US"))
}

private func conditionalMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    SkinSize(width: 20, height: 12)
}

private func conditionalTextColors(_ scene: WidgetScene) -> [RGBA] {
    scene.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.style.color }; return nil }
}

private func conditionalFacts(_ checked: CheckedFile, symbols: [NodeID: Symbol]? = nil,
                              types: [NodeID: SemType]? = nil, elements: [NodeID: ElementFacts]? = nil,
                              dataUses: [DataUse]? = nil, canonical: [NodeID: Double]? = nil) -> CheckedFile {
    var value = CheckedFile(tree: checked.tree, diagnostics: checked.diagnostics,
        symbols: symbols ?? checked.symbols, types: types ?? checked.types, elements: elements ?? checked.elements,
        dataUses: dataUses ?? checked.dataUses, dependencies: checked.dependencies, reactions: checked.reactions,
        freeformOrders: checked.freeformOrders, stringTable: checked.stringTable, requirements: checked.requirements,
        options: checked.options, styles: checked.styles, translations: checked.translations, root: checked.root)
    value.loopIdentities = checked.loopIdentities; value.assets = checked.assets
    value.declarationTypes = checked.declarationTypes
    value.canonicalNumericValues = canonical ?? checked.canonicalNumericValues
    value.numericCoercions = checked.numericCoercions
    return value
}

func runDeskConditionalCompilationTests(_ t: TestRunner) {
    let red = RGBA(r: 255, g: 0, b: 0), green = RGBA(r: 0, g: 255, b: 0), blue = RGBA(r: 0, g: 0, b: 255)

    t.suite("Desk: conditional compilation: battery status icons and gauge paints use live captured inputs") {
        let source = ##"widget { Column(spacing: 0) { Icon("bolt.fill").size(16).hidden(if: not battery.charging); Icon("powerplug.fill").size(16).hidden(if: not battery.pluggedIn or battery.charging); Gauge(battery.level).size(40).color("#00FF00").color("#FF0000", if: not battery.charging and battery.level <= 20%).track("#0000FF").track("#00FF00", if: battery.charging) } }"##
        var runtime = try ProgramRuntime(program: conditionalProgram(t, source))
        t.equal(runtime.neededSystemProperties, [.batteryCharging, .batteryPluggedIn, .batteryLevel])
        let states: [(ProgramSystemInput, [Visibility], RGBA, RGBA)] = [
            (ProgramSystemInput(batteryLevel: 10, batteryCharging: false, batteryPluggedIn: false),
                [.visible, .hiddenKeepsSpace, .hiddenKeepsSpace, .visible], red, blue),
            (ProgramSystemInput(batteryLevel: 10, batteryCharging: true, batteryPluggedIn: true),
                [.visible, .visible, .hiddenKeepsSpace, .visible], green, green),
            (ProgramSystemInput(batteryLevel: 80, batteryCharging: false, batteryPluggedIn: true),
                [.visible, .hiddenKeepsSpace, .visible, .visible], green, blue)]
        var frames: [SkinRect]?
        for (input, visibility, foreground, track) in states {
            let scene = try runtime.project(environment: conditionalEnvironment(), dateInput: conditionalDate(), systemInput: input,
                measureIcon: { _ in SkinSize(width: 16, height: 16) }, measure: conditionalMeasure)
            t.equal(scene.elements.map(\.visibility), visibility)
            if let frames { t.equal(scene.elements.map(\.frame), frames) }
            else { frames = scene.elements.map(\.frame) }
            t.equal(scene.size, SkinSize(width: 40, height: 72), "hidden icons retain their allocated space")
            let colors = scene.drawingItems.compactMap { if case .roundline(let draw) = $0 { return draw.color }; return nil }
            t.equal(colors, [track, foreground])
            t.equal(runtime.clockPrecision, .minute)
        }
    }

    t.suite("Desk: conditional compilation: repeated hidden conditions OR without converting internal missing") {
        for expression in ["cpu.usage < 20%", "not (cpu.usage >= 20%)", "cpu.usage < 20% and true"] {
            let source = "widget { Text(\"A\").hidden(if: \(expression)).hidden(if: battery.charging) }"
            var runtime = try ProgramRuntime(program: conditionalProgram(t, source))
            for (input, expected) in [
                (ProgramSystemInput(batteryCharging: false), Visibility.visible),
                (ProgramSystemInput(batteryCharging: true), Visibility.hiddenKeepsSpace),
                (ProgramSystemInput(cpuUsage: 10, batteryCharging: false), Visibility.hiddenKeepsSpace),
                (ProgramSystemInput(cpuUsage: 80, batteryCharging: false), Visibility.visible)] {
                let scene = try runtime.project(environment: conditionalEnvironment(), dateInput: conditionalDate(),
                    systemInput: input, measure: conditionalMeasure)
                t.equal(scene.elements.first?.visibility, expected, expression)
                t.equal(scene.size, SkinSize(width: 20, height: 12))
                t.equal(runtime.clockPrecision, input.batteryCharging == true ? nil : .second,
                    "a live visibility condition polls while hidden; an earlier true OR short-circuits it")
            }
        }
        for source in [#"widget { Text("A").hidden(if: false).hidden() }"#,
                       #"widget { Text("A").hidden().hidden(if: cpu.usage < 20%) }"#] {
            var runtime = try ProgramRuntime(program: conditionalProgram(t, source))
            t.equal(try runtime.project(environment: conditionalEnvironment(), systemInput: ProgramSystemInput(cpuUsage: 80),
                measure: conditionalMeasure).elements.first?.visibility, .hiddenKeepsSpace)
        }
        var desktop = try ProgramRuntime(program: conditionalProgram(t,
            #"widget { Text("Charging").hidden(if: not battery.charging) }"#))
        t.equal(try desktop.project(environment: conditionalEnvironment(), systemInput: ProgramSystemInput(),
            measure: conditionalMeasure).elements.first?.visibility, .hiddenKeepsSpace)
    }

    t.suite("Desk: conditional compilation: active later paints win and missing selects the unconditional fallback") {
        let source = ##"widget { Text("A").color("#0000FF").color("#FF0000", if: cpu.usage < 50%).color("#00FF00", if: battery.charging) }"##
        var runtime = try ProgramRuntime(program: conditionalProgram(t, source))
        for (input, expected) in [
            (ProgramSystemInput(cpuUsage: 10, batteryCharging: true), green),
            (ProgramSystemInput(cpuUsage: 10, batteryCharging: false), red),
            (ProgramSystemInput(cpuUsage: 80, batteryCharging: false), blue),
            (ProgramSystemInput(batteryCharging: false), blue)] {
            let scene = try runtime.project(environment: conditionalEnvironment(), dateInput: conditionalDate(),
                systemInput: input, measure: conditionalMeasure)
            t.equal(conditionalTextColors(scene), [expected])
            t.equal(runtime.clockPrecision, input.batteryCharging == true ? nil : .second)
        }
        let reordered = ##"widget { Text("A").color("#FF0000", if: battery.charging).color("#00FF00", if: cpu.usage < 50%).color("#0000FF") }"##
        var later = try ProgramRuntime(program: conditionalProgram(t, reordered))
        t.equal(conditionalTextColors(try later.project(environment: conditionalEnvironment(),
            systemInput: ProgramSystemInput(cpuUsage: 10, batteryCharging: true), measure: conditionalMeasure)), [green],
            "a later base does not outrank an active condition")
        for paint in [".red", "Color.red", "((.red))", "(\"#FF0000\")"] {
            let value = try conditionalProgram(t, "widget { Text(\"A\").color(\(paint), if: battery.charging) }")
            guard case .text(let text) = value.root.content else { throw DeskConditionalFixtureError.drawing }
            let leaf: ProgramColor = paint.contains("#") ? .literal(red) : .palette(.red)
            t.equal(text.color, .conditional(.systemProperty(.batteryCharging), then: leaf, otherwise: .text))
        }
    }

    t.suite("Desk: conditional compilation: inherited dynamic fallback never overrides a child own base") {
        let source = ##"widget { Column(spacing: 0) { Column(spacing: 0) { Text("Inherited"); Text("Own").color("#0000FF"); Text("Variant").color("#0000FF", if: battery.pluggedIn) }.color("#FF0000", if: battery.charging) }.color("#00FF00") }"##
        var runtime = try ProgramRuntime(program: conditionalProgram(t, source))
        for (input, expected) in [
            (ProgramSystemInput(batteryCharging: false, batteryPluggedIn: false), [green, blue, green]),
            (ProgramSystemInput(batteryCharging: true, batteryPluggedIn: false), [red, blue, red]),
            (ProgramSystemInput(batteryCharging: true, batteryPluggedIn: true), [red, blue, blue]),
            (ProgramSystemInput(batteryCharging: false, batteryPluggedIn: true), [green, blue, blue])] {
            t.equal(conditionalTextColors(try runtime.project(environment: conditionalEnvironment(), systemInput: input,
                measure: conditionalMeasure)), expected)
        }
        var rootFallback = try ProgramRuntime(program: conditionalProgram(t,
            ##"widget { Column { Text("A") }.color("#FF0000", if: battery.charging) }"##))
        t.equal(conditionalTextColors(try rootFallback.project(environment: conditionalEnvironment(),
            systemInput: ProgramSystemInput(batteryCharging: false), measure: conditionalMeasure)),
            [SkinAppearance.light.labelColor])
    }

    t.suite("Desk: conditional compilation: fill defaults retain outline policy and meter facets choose independently") {
        for shape in ["Rectangle", "Circle", "Ellipse", "Capsule"] {
            let source = "widget { \(shape)().size(20).stroke(\"#0000FF\", width: 0).fill(\"#FF0000\", if: battery.charging) }"
            var runtime = try ProgramRuntime(program: conditionalProgram(t, source))
            for (charging, expected) in [(false, RGBA.clear), (true, red)] {
                let scene = try runtime.project(environment: conditionalEnvironment(),
                    systemInput: ProgramSystemInput(batteryCharging: charging), measure: conditionalMeasure)
                guard case .shape(let draw)? = scene.drawingItems.first, let item = draw.shapes.first else {
                    throw DeskConditionalFixtureError.drawing
                }
                t.equal(item.fill, .color(expected)); t.equal(item.stroke, .color(blue)); t.equal(item.strokeStyle.width, 0)
            }
        }
        var rectangle = try ProgramRuntime(program: conditionalProgram(t,
            ##"widget { Rectangle().size(20).fill("#FF0000", if: battery.charging) }"##))
        for (charging, expected) in [(false, SkinAppearance.light.labelColor), (true, red)] {
            let scene = try rectangle.project(environment: conditionalEnvironment(),
                systemInput: ProgramSystemInput(batteryCharging: charging), measure: conditionalMeasure)
            guard case .fill(_, let paint)? = scene.drawingItems.first else { throw DeskConditionalFixtureError.drawing }
            t.equal(paint.color, expected)
        }
        var meter = try ProgramRuntime(program: conditionalProgram(t,
            ##"widget { Progress(50%).size(20, 10).color("#0000FF").color("#FF0000", if: battery.charging).track("#0000FF").track("#00FF00", if: battery.pluggedIn) }"##))
        for (input, expected) in [
            (ProgramSystemInput(batteryCharging: false, batteryPluggedIn: true), [green, blue]),
            (ProgramSystemInput(batteryCharging: true, batteryPluggedIn: false), [blue, red])] {
            let scene = try meter.project(environment: conditionalEnvironment(), systemInput: input, measure: conditionalMeasure)
            let colors = scene.drawingItems.compactMap { item -> RGBA? in
                switch item { case .fill(_, let paint): return paint.color; case .bar(let bar): return bar.color; default: return nil }
            }
            t.equal(colors, expected)
        }
    }

    t.suite("Desk: conditional compilation: hidden actions labels and glass recover after ordered session assignments") {
        let source = ##"widget { variable page = 0; computed alternate = page > 0; Row(spacing: 0, align: .top) { Text("Next").size(20).onClick { page = 1; copy(page) }; Rectangle().size(20).background(.glass).voiceOver("Target").hidden(if: not alternate).fill("#FF0000", if: alternate).onClick { copy("Target") } } }"##
        var runtime = try ProgramRuntime(program: conditionalProgram(t, source))
        let first = try runtime.project(environment: conditionalEnvironment(), measure: conditionalMeasure)
        let target = first.elements[2]
        t.equal(target.visibility, .hiddenKeepsSpace); t.equal(target.accessibilityLabel, nil)
        t.equal(target.glass, nil); t.check(target.items.isEmpty)
        let targetPoint = SkinPoint(x: target.frame.x + 1, y: target.frame.y + 1)
        t.check(try runtime.clickWithEffects(at: targetPoint, expectedGeneration: first.generation,
            environment: conditionalEnvironment(), measure: conditionalMeasure) == nil)
        let clicked = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: conditionalEnvironment(), measure: conditionalMeasure)
        t.equal(clicked?.effects, [.copy("1")])
        guard let scene = clicked?.scene else { throw DeskConditionalFixtureError.drawing }
        t.equal(scene.elements.map(\.frame), first.elements.map(\.frame)); t.equal(scene.size, first.size)
        t.equal(scene.elements[2].visibility, .visible); t.equal(scene.elements[2].accessibilityLabel, "Target")
        t.check(scene.elements[2].glass != nil)
        t.equal(try runtime.clickWithEffects(at: targetPoint, expectedGeneration: scene.generation,
            environment: conditionalEnvironment(), measure: conditionalMeasure)?.effects, [.copy("Target")])
        t.check(try runtime.clickWithEffects(at: targetPoint, expectedGeneration: first.generation,
            environment: conditionalEnvironment(), measure: conditionalMeasure) == nil, "old generations remain stale")
    }

    t.suite("Desk: conditional compilation: inactive style colors preserve the default text appearance") {
        let styled = try conditionalProgram(t, #"widget { Text("A").style(alert, if: false) }"# + "\n" + #"style alert { .color(.red) }"#)
        let explicit = try conditionalProgram(t, #"widget { Text("A").color(.red, if: false) }"#)
        t.equal(styled, explicit)
        var styledRuntime = try ProgramRuntime(program: styled)
        var explicitRuntime = try ProgramRuntime(program: explicit)
        t.equal(try styledRuntime.project(environment: conditionalEnvironment(), measure: conditionalMeasure),
                try explicitRuntime.project(environment: conditionalEnvironment(), measure: conditionalMeasure))
    }

    t.suite("Desk: conditional compilation: inactive backgrounds preserve the complete unpainted scene") {
        for source in [#"widget { Text("A").background(.glass, if: false) }"#,
                       #"widget { Text("A").background(.glass, tint: .red, if: false) }"#] {
            var runtime = try ProgramRuntime(program: conditionalProgram(t, source))
            var reference = try ProgramRuntime(program: conditionalProgram(t, #"widget { Text("A") }"#))
            let scene = try runtime.project(environment: conditionalEnvironment(), measure: conditionalMeasure)
            t.equal(scene, try reference.project(environment: conditionalEnvironment(), measure: conditionalMeasure), source)
            t.check(scene.elements.allSatisfy { $0.glass == nil }, "inactive background leaves no native region")
        }
    }

    t.suite("Desk: conditional compilation: inactive unsupported facets and paints still reject the whole program") {
        for source in [
            #"widget { Rectangle().stroke(.red, if: false) }"#,
            #"widget { Text("A").font(20, if: false) }"#,
            #"widget { Text("A").width(20, if: false) }"#,
            #"widget { Text("A").color(.red).hover { .color(.blue) } }"#,
            #"widget { Text("A").pressed { .color(.red) } }"#,
            #"widget { Text("A").color(light: .red, dark: .blue, if: false) }"#,
            #"widget { Rectangle().fill(system.dark ? .red : .blue, if: false) }"#,
            #"widget { Text("A").color(system.dark ? .red : .blue, if: false) }"#,
            #"info { permissions: [.music] }"# + "\n" + #"widget { Text("A").hidden(if: music.playing) }"#,
            #"widget { Text("A").style(alert, if: false) }"# + "\n" + #"style alert { .font(12) }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
            t.equal(result.issues.first?.kind, .unsupported, "\(source)\n\(result.issues)")
            t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty)
            t.equal(result.diagnostics, checked.diagnostics)
        }
        for source in [#"widget { Text("A").color(.red(123), if: false) }"#,
                       #"widget { Rectangle().fill(.red(123), if: false) }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(result.program == nil, "catalog values with arguments must never be silently accepted")
            t.check(!checked.diagnostics(.error).isEmpty || !result.issues.isEmpty)
        }
    }

    t.suite("Desk: conditional compilation: forged candidate value condition origin type and order receipts reject") {
        let checked = deskCheck(##"widget { Text("A").color("#0000FF").color("#FF0000", if: battery.charging).color("#00FF00", if: battery.pluggedIn).hidden(if: cpu.usage < 20%) }"##)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        guard let identity = checked.elements.keys.first, let facts = checked.elements[identity],
              let colors = facts.facets["color"], colors.count == 3,
              let hidden = facts.facets["hidden"]?.first,
              case .expr(let condition)? = colors.first?.condition,
              case .own(let owner)? = colors.first?.origin else { throw DeskConditionalFixtureError.receipt }
        func reject(_ value: CheckedFile) {
            let result = Desk.compile(value)
            t.check(result.program == nil && result.elementRefs.isEmpty)
            t.equal(result.issues.first?.kind, .invalidCheckedModel, "\(result.issues)")
            t.equal(result.diagnostics, checked.diagnostics)
        }
        var edits: [ElementFacts] = []
        var changed = facts; changed.facets["color"]?.removeLast(); edits.append(changed)
        changed = facts; changed.facets["color"]?.reverse(); edits.append(changed)
        changed = facts; changed.facets["color"]?[0].value = colors[1].value; edits.append(changed)
        changed = facts; changed.facets["color"]?[0].condition = .expr(colors[0].value); edits.append(changed)
        changed = facts; changed.facets["color"]?[0].condition = nil; edits.append(changed)
        changed = facts; changed.facets["color"]?[0].condition = .all([.expr(condition)]); edits.append(changed)
        changed = facts; changed.facets["color"]?[0].origin = .own(checked.tree.id(of: checked.tree.rootNode)); edits.append(changed)
        changed = facts; changed.facets["color"]?[0].level = 2; edits.append(changed)
        changed = facts; changed.facets["color"]?[0].hard = false; edits.append(changed)
        changed = facts; changed.facets["color"]?[0].fixedValue = ".red"; edits.append(changed)
        changed = facts; changed.facets["color"]?[0].position = 999; edits.append(changed)
        changed = facts; changed.facets["hidden"]?[0].fixedValue = "false"; edits.append(changed)
        changed = facts; changed.facets["hidden"]?[0].value = colors[0].value; edits.append(changed)
        changed = facts; changed.inherits.insert("color"); edits.append(changed)
        for change in edits { var elements = checked.elements; elements[identity] = change; reject(conditionalFacts(checked, elements: elements)) }
        var symbols = checked.symbols; symbols[owner] = .builtIn(.modifier("track")); reject(conditionalFacts(checked, symbols: symbols))
        var types = checked.types; types[condition] = SemType(type: .plainNumber); reject(conditionalFacts(checked, types: types))
        symbols = checked.symbols; symbols[condition] = .builtIn(.member(namespace: "cpu", name: "usage"))
        t.check(Desk.compile(conditionalFacts(checked, symbols: symbols)).program == nil, "live member identities retain their catalog contracts")
        var canonical = checked.canonicalNumericValues; canonical[colors[0].value] = 1
        reject(conditionalFacts(checked, canonical: canonical))
        canonical = checked.canonicalNumericValues; canonical[condition] = 1
        reject(conditionalFacts(checked, canonical: canonical))
        t.check(Desk.compile(conditionalFacts(checked, dataUses: [])).program == nil, "conditions require the checked data-use receipt")
        t.equal(hidden.fixedValue, "true", "the hidden candidate value is fixed, not its condition")
    }

    t.suite("Desk: conditional compilation: catalog drift and combined expression budgets preserve rejection") {
        let source = ##"widget { Text("A").color("#FF0000", if: battery.charging).hidden(if: cpu.usage < 20%).hidden(if: battery.pluggedIn) }"##
        let checked = deskCheck(source)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        var variants: [DeskCatalog] = []
        var catalog = DeskCatalog.current
        guard let hidden = catalog.modifiers.firstIndex(where: { $0.name == "hidden" }),
              let color = catalog.modifiers.firstIndex(where: { $0.name == "color" }),
              let facet = catalog.facets.firstIndex(where: { $0.id == "color" }) else { throw DeskConditionalFixtureError.receipt }
        catalog.modifiers[hidden].acceptsCondition = false; variants.append(catalog)
        catalog = .current; catalog.modifiers[hidden].signatures[0].params[0].defaultValue = .source("false"); variants.append(catalog)
        catalog = .current; catalog.modifiers[color].inheritable = false; variants.append(catalog)
        catalog = .current; catalog.modifiers[color].signatures[0].params[0].type = .paint; variants.append(catalog)
        catalog = .current; catalog.facets[facet].valueType = .paint; variants.append(catalog)
        for catalog in variants {
            let result = Desk.compile(checked, catalog: catalog)
            t.equal(result.issues.first?.kind, .unsupported); t.check(result.program == nil && result.elementRefs.isEmpty)
        }
        for (component, source, keys) in [
            ("Rectangle", ##"widget { Rectangle().size(20).fill("#0000FF").fill("#FF0000", if: battery.charging) }"##, ["fill"]),
            ("Progress", ##"widget { Progress(50%).size(20).color("#0000FF").color("#FF0000", if: battery.charging).track("#00FF00") }"##, ["color", "track"]),
            ("Gauge", ##"widget { Gauge(50%).size(20).color("#0000FF").color("#FF0000", if: battery.charging).track("#00FF00") }"##, ["color", "track"])] {
            var catalog = DeskCatalog.current
            guard let index = catalog.components.firstIndex(where: { $0.name == component }) else {
                throw DeskConditionalFixtureError.receipt
            }
            for key in keys { catalog.components[index].defaults.removeValue(forKey: FacetID(key)) }
            let checked = deskCheck(source, context: CheckContext(catalog: catalog))
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked, catalog: catalog))
            let result = Desk.compile(checked, catalog: catalog)
            t.check(result.issues.isEmpty && result.program != nil,
                "\(component) does not parse a missing catalog fallback when source supplies the unconditional base: \(result.issues)")
            guard let program = result.program else { throw DeskConditionalFixtureError.program }
            var runtime = try ProgramRuntime(program: program)
            for (charging, expected) in [(false, blue), (true, red)] {
                let scene = try runtime.project(environment: conditionalEnvironment(),
                    systemInput: ProgramSystemInput(batteryCharging: charging), measure: conditionalMeasure)
                guard let item = scene.drawingItems.last else { throw DeskConditionalFixtureError.drawing }
                switch item {
                case .fill(_, let paint): t.equal(paint.color, expected)
                case .bar(let bar): t.equal(bar.color, expected)
                case .roundline(let draw): t.equal(draw.color, expected)
                default: throw DeskConditionalFixtureError.drawing
                }
            }
            let withoutBase = source.replacingOccurrences(of: component == "Rectangle" ? ##".fill("#0000FF")"## : ##".color("#0000FF")"##, with: "")
            let missingFallback = Desk.compile(deskCheck(withoutBase, context: CheckContext(catalog: catalog)), catalog: catalog)
            t.check(missingFallback.program == nil && !missingFallback.issues.isEmpty, "a genuinely required missing default is still rejected")
        }
        for (source, nesting, tokens) in [
            (#"widget { Text("A").hidden(if: (((battery.charging)))) }"#, 2, 1000),
            (#"widget { Text("A").hidden(if: battery.charging).hidden(if: battery.pluggedIn) }"#, 100, 2),
            (##"widget { Text("A").color("#FF0000", if: cpu.usage < 20%) }"##, 100, 2)] {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            var catalog = DeskCatalog.current
            catalog.limits.maximumExpressionNesting = nesting; catalog.limits.maximumTokens = tokens
            let result = Desk.compile(checked, catalog: catalog)
            t.equal(result.issues.first?.kind, .resourceLimit, "\(source)\n\(result.issues)")
            t.check(result.program == nil && result.elementRefs.isEmpty)
        }
    }
}
