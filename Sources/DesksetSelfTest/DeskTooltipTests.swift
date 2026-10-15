import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum DeskTooltipFixtureError: Error { case program, receipt }

private func tooltipCompilation(_ t: TestRunner, _ source: String) throws -> (CheckedFile, DeskCompilationResult, WidgetProgram) {
    let checked = deskCheck(source), result = Desk.compile(checked)
    t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
    t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
    t.equal(result.diagnostics, checked.diagnostics)
    guard let program = result.program else { throw DeskTooltipFixtureError.program }
    return (checked, result, program)
}

private func tooltipEnvironment(_ dark: Bool = false) -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1,
        appearance: AppearanceStamp(value: dark ? .dark : .light, name: dark ? "dark" : "light"), imageGeneration: 0)
}

private func tooltipDate(_ locale: String = "en_US", seconds: Double = 0) -> ProgramDateInput {
    ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!,
                     locale: Locale(identifier: locale))
}

private func tooltipMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    SkinSize(width: 20, height: 12)
}

private func tooltipFacts(_ checked: CheckedFile, symbols: [NodeID: Symbol]? = nil,
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

func runDeskTooltipTests(_ t: TestRunner) {
    let point = SkinPoint(x: 1, y: 1)

    t.suite("Desk: tooltips: supported views retain separate own text and title without inheritance") {
        for view in [#"Text("A")"#, #"Icon("wifi")"#, "Rectangle()", "Circle()", "Ellipse()", "Capsule()",
                     #"Image("image.png")"#, "Progress(0.25)", "Gauge(0.25)",
                     #"Column { Text("A") }"#, #"Row { Text("A") }"#, #"Freeform { Text("A") }"#] {
            let (_, _, program) = try tooltipCompilation(t, "widget { \(view).tooltip(\"Body\", title: \"Title\") }")
            t.equal(program.root.tooltip, ProgramTooltip(text: .string("Body"), title: .string("Title")), view)
        }
        let source = #"widget { Column(spacing: 4, align: .left) { Text("A").size(20, 12).tooltip("Inner", title: "Child"); Row { Text("B").size(20, 12) } }.tooltip("Outer", title: "Card") }"#
        let (checked, _, program) = try tooltipCompilation(t, source)
        guard case .column(_, _, let children) = program.root.content,
              children.count == 2,
              case .row(_, _, let rowChildren) = children[1].content else { throw DeskTooltipFixtureError.receipt }
        t.check(children[1].tooltip == nil && rowChildren[0].tooltip == nil)
        t.check(checked.elements.values.allSatisfy { !$0.inherits.contains("tooltip") && !$0.inherits.contains("tooltip.title") })
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: tooltipEnvironment(), measure: tooltipMeasure)
        t.equal(scene.size, SkinSize(width: 20, height: 28))
        t.equal(scene.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "Inner", title: "Child"))
        t.equal(scene.hitMap.toolTipInfo(at: 1, 17, images: nil), ToolTipInfo(text: "Outer", title: "Card"))
        t.check(scene.hitMap.entries.allSatisfy { $0.actions.isEmpty })
        t.check(scene.hitMap.entry(at: point.x, point.y, handling: .leftUp, images: nil) == nil)
        var plain = try ProgramRuntime(program: tooltipCompilation(t,
            #"widget { Column(spacing: 4, align: .left) { Text("A").size(20, 12); Row { Text("B").size(20, 12) } } }"#).2)
        let baseline = try plain.project(environment: tooltipEnvironment(), measure: tooltipMeasure)
        t.equal(scene.elements.map(\.frame), baseline.elements.map(\.frame)); t.equal(scene.drawingItems, baseline.drawingItems)
    }

    t.suite("Desk: tooltips: display values share Text VoiceOver and copy formatting in both locales") {
        let expressions = ["25%", "45deg", "12pt", "8GiB", "90s", "time.now", "battery.present",
                           "(battery.timeRemaining)", "battery.present ? battery.timeRemaining : 90s",
                           #"battery.present ? true : "Unavailable""#,
                           #""{battery.timeRemaining, style: .clock}""#]
        for locale in ["en_US", "zh_CN"] {
            for expression in expressions {
                let source = "widget { Text(\(expression)).size(80, 30).voiceOver(\(expression)).tooltip(\(expression), title: \(expression)).onClick { copy(\(expression)) } }"
                var runtime = try ProgramRuntime(program: tooltipCompilation(t, source).2)
                let date = tooltipDate(locale), input = ProgramSystemInput(batteryPresent: true, batteryTimeRemaining: 273_852)
                let scene = try runtime.project(environment: tooltipEnvironment(), dateInput: date, systemInput: input, measure: tooltipMeasure)
                guard let info = scene.hitMap.toolTipInfo(at: point.x, point.y, images: nil),
                      case .text(let draw)? = scene.drawingItems.first else { throw DeskTooltipFixtureError.program }
                t.equal(info.text, draw.text, "\(locale): \(expression)"); t.equal(info.title, draw.text)
                t.equal(info.text, scene.elements.first?.accessibilityLabel)
                let clicked = try runtime.clickWithEffects(at: point, expectedGeneration: scene.generation,
                    environment: tooltipEnvironment(), dateInput: date, systemInput: input, measure: tooltipMeasure)
                t.equal(clicked?.effects, [.copy(info.text)])
                if expression == "25%" { t.equal(info.text, "25") }
                if expression == "45deg" { t.equal(info.text, "45°") }
                if expression == "battery.present" { t.equal(info.text, locale == "en_US" ? "Yes" : "是") }
                if expression == #""{battery.timeRemaining, style: .clock}""# { t.equal(info.text, "76:04:12") }
            }
        }
        var distinct = try ProgramRuntime(program: tooltipCompilation(t,
            #"widget { Rectangle().size(40).tooltip(battery.timeRemaining, title: cpu.usage) }"#).2)
        let scene = try distinct.project(environment: tooltipEnvironment(), dateInput: tooltipDate(),
            systemInput: ProgramSystemInput(cpuUsage: 42, batteryTimeRemaining: 273_852), measure: tooltipMeasure)
        t.equal(scene.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: "3d 4h", title: "42"))
        t.equal(distinct.clockPrecision, .second)
    }

    t.suite("Desk: tooltips: explicit empty text suppresses parent tips and title only remains meaningful") {
        let source = #"widget { Column(spacing: 4, align: .left) { Text("A").size(20).tooltip(""); Text("B").size(20).tooltip("", title: "Title only"); Text("C").size(20) }.tooltip("Parent") }"#
        var runtime = try ProgramRuntime(program: tooltipCompilation(t, source).2)
        let scene = try runtime.project(environment: tooltipEnvironment(), measure: tooltipMeasure)
        t.equal(scene.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: ""), "an explicit empty child is not an absent tooltip")
        t.equal(scene.hitMap.toolTipInfo(at: 1, 25, images: nil), ToolTipInfo(text: "", title: "Title only"))
        t.equal(scene.hitMap.toolTipInfo(at: 1, 49, images: nil), ToolTipInfo(text: "Parent"))
        for component in ["Row", "Column", "Freeform"] {
            let (_, _, program) = try tooltipCompilation(t, "widget { \(component) { }.size(40, 30).tooltip(\"\", title: \"Title\") }")
            var empty = try ProgramRuntime(program: program)
            let frame = try empty.project(environment: tooltipEnvironment(), measure: tooltipMeasure)
            t.equal(frame.size, SkinSize(width: 40, height: 30)); t.check(frame.drawingItems.isEmpty)
            t.equal(frame.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: "", title: "Title"))
            t.check(frame.hitMap.entries.allSatisfy { $0.actions.isEmpty })
            t.check(try empty.clickWithEffects(at: point, expectedGeneration: frame.generation,
                environment: tooltipEnvironment(), measure: tooltipMeasure) == nil)
        }
    }

    t.suite("Desk: tooltips: missing inputs recover and hidden or inactive tips do not retain clocks") {
        let source = #"widget { Column(spacing: 0) { if battery.present { Text("Live").size(20).tooltip(cpu.usage, title: "{time.now, format: "HH:mm:ss"}") } else { Text("Notice").size(20).tooltip("No battery") } }.tooltip("Card") }"#
        var runtime = try ProgramRuntime(program: tooltipCompilation(t, source).2)
        let first = try runtime.project(environment: tooltipEnvironment(), dateInput: tooltipDate(),
            systemInput: ProgramSystemInput(batteryPresent: true), measure: tooltipMeasure)
        t.equal(first.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: "–", title: "00:00:00"))
        t.equal(runtime.clockPrecision, .second)
        let recovered = try runtime.project(environment: tooltipEnvironment(), dateInput: tooltipDate(seconds: 5),
            systemInput: ProgramSystemInput(cpuUsage: 60, batteryPresent: true), measure: tooltipMeasure)
        t.equal(recovered.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: "60", title: "00:00:05"))
        let inactive = try runtime.project(environment: tooltipEnvironment(), systemInput: ProgramSystemInput(batteryPresent: false), measure: tooltipMeasure)
        t.equal(inactive.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: "No battery"))
        t.equal(runtime.clockPrecision, nil)
        for source in [#"widget { Text("Hidden").tooltip(time.now, title: cpu.usage).hidden() }"#,
                       #"widget { Column { Text("Hidden").tooltip(cpu.usage, title: time.now) }.hidden() }"#] {
            var hidden = try ProgramRuntime(program: tooltipCompilation(t, source).2)
            t.equal(hidden.neededSystemProperties, [])
            let scene = try hidden.project(environment: tooltipEnvironment(), measure: tooltipMeasure)
            t.check(scene.hitMap.entries.isEmpty); t.equal(hidden.clockPrecision, nil)
        }
        var zero = try ProgramRuntime(program: tooltipCompilation(t,
            #"widget { Rectangle().size(0).tooltip(time.now, title: cpu.usage) }"#).2)
        t.equal(zero.neededSystemProperties, [.cpuUsage])
        do {
            _ = try zero.project(environment: tooltipEnvironment(), systemInput: ProgramSystemInput(cpuUsage: 42), measure: tooltipMeasure)
            t.check(false, "a visible zero-area tooltip is still resolved, as a VoiceOver label is")
        } catch let error as ProgramRuntimeError { t.equal(error, .invalidDateInput) }
        let zeroScene = try zero.project(environment: tooltipEnvironment(), dateInput: tooltipDate(),
            systemInput: ProgramSystemInput(cpuUsage: 42), measure: tooltipMeasure)
        t.check(zeroScene.hitMap.entries.isEmpty); t.equal(zero.clockPrecision, .second)
    }

    t.suite("Desk: tooltips: declarations startup and ordered actions update both fields transactionally") {
        let source = #"widget { variable count = 1; computed spoken = system.dark ? count : count + 1; Text("Action").size(80, 30).tooltip(spoken, title: count).onLoad { count = 2 }.onClick { count = count + 1; copy(spoken) } }"#
        var runtime = try ProgramRuntime(program: tooltipCompilation(t, source).2)
        let first = try runtime.project(environment: tooltipEnvironment(), measure: tooltipMeasure)
        t.equal(first.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: "3", title: "2"))
        do {
            _ = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
                environment: tooltipEnvironment(), measure: { _, _, _ in SkinSize(width: -1, height: 12) })
            t.check(false, "a failed projection must not publish tooltip strings or preceding assignments")
        } catch let error as ProgramRuntimeError {
            guard case .invalidMeasurement = error else { throw error }
        }
        t.equal(runtime.generation, first.generation)
        guard let clicked = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
            environment: tooltipEnvironment(), measure: tooltipMeasure) else { throw DeskTooltipFixtureError.program }
        t.equal(clicked.effects, [.copy("4")])
        t.equal(clicked.scene.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: "4", title: "3"))
        let dark = try runtime.project(environment: tooltipEnvironment(true), measure: tooltipMeasure)
        t.equal(dark.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: "3", title: "3"))
        t.check(try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
            environment: tooltipEnvironment(), measure: tooltipMeasure) == nil)
    }

    t.suite("Desk: tooltips: exact two facet catalog and own argument receipts reject forged publication") {
        let checked = deskCheck(#"widget { Rectangle().size(40).tooltip(battery.timeRemaining, title: cpu.usage) }"#)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        guard let element = checked.elements.first, let text = element.value.facets["tooltip"]?.first,
              let title = element.value.facets["tooltip.title"]?.first, case .own(let origin) = text.origin,
              let modifier = DeskCatalog.current.modifiers.firstIndex(where: { $0.name == "tooltip" }) else { throw DeskTooltipFixtureError.receipt }
        func rejected(_ value: CheckedFile, catalog: DeskCatalog = .current) {
            let result = Desk.compile(value, catalog: catalog)
            t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty)
            t.check(!result.issues.isEmpty, "\(result.issues)"); t.equal(result.diagnostics, value.diagnostics)
        }
        var symbols = checked.symbols; symbols.removeValue(forKey: origin)
        rejected(tooltipFacts(checked, symbols: symbols))
        var types = checked.types; types.removeValue(forKey: title.value)
        rejected(tooltipFacts(checked, types: types))
        types = checked.types; types[text.value] = SemType(type: .bool)
        rejected(tooltipFacts(checked, types: types))
        rejected(tooltipFacts(checked, dataUses: []))
        for key in [FacetID("tooltip"), FacetID("tooltip.title")] {
            for damage in ["missing", "value", "origin", "fixed", "duplicate", "inherited", "level", "soft"] {
                var elements = checked.elements
                switch damage {
                case "missing": elements[element.key]?.facets.removeValue(forKey: key)
                case "value": elements[element.key]?.facets[key]?[0].value = key == "tooltip" ? title.value : text.value
                case "origin": elements[element.key]?.facets[key]?[0].origin = .own(text.value)
                case "fixed": elements[element.key]?.facets[key]?[0].fixedValue = #""Forged""#
                case "duplicate": elements[element.key]?.facets[key]?.append(key == "tooltip" ? text : title)
                case "level": elements[element.key]?.facets[key]?[0].level = 2
                case "soft": elements[element.key]?.facets[key]?[0].hard = false
                default: elements[element.key]?.inherits.insert(key)
                }
                rejected(tooltipFacts(checked, elements: elements))
            }
        }
        let changes: [(inout ModifierSpec) -> Void] = [
            { $0.inheritable = true }, { $0.facets.reverse() }, { $0.repeatable = .yes },
            { $0.acceptsCondition = false }, { $0.fixedValues = ["tooltip": #""Fixed""#] },
            { $0.signatures[0].params[0].role = .plain }, { $0.signatures[0].params[1].role = .plain },
            { $0.signatures[0].params[0].type = .any }, { $0.signatures[0].params[1].translatable = false },
            { $0.signatures[0].params[1].required = true }, { $0.signatures[0].params[1].label = "heading" },
            { $0.signatures[0].params[1].defaultValue = .source(#""Default""#) },
            { $0.signatures[0].params[1].facets = ["tooltip"] }]
        for change in changes {
            var catalog = DeskCatalog.current; change(&catalog.modifiers[modifier]); rejected(checked, catalog: catalog)
        }
        for key in [FacetID("tooltip"), FacetID("tooltip.title")] {
            guard let index = DeskCatalog.current.facets.firstIndex(where: { $0.id == key }) else { throw DeskTooltipFixtureError.receipt }
            var catalog = DeskCatalog.current; catalog.facets[index].inheritable = true; rejected(checked, catalog: catalog)
        }
        let absentTitle = deskCheck(#"widget { Text("A").tooltip("Body") }"#)
        guard let own = absentTitle.elements.first, let body = own.value.facets["tooltip"]?.first else { throw DeskTooltipFixtureError.receipt }
        var elements = absentTitle.elements; elements[own.key]?.facets["tooltip.title"] = [body]
        rejected(tooltipFacts(absentTitle, elements: elements))
    }

    t.suite("Desk: tooltips: the original style tooltip supplies its projected text and title") {
        let source = #"widget { Text("A").style(label) }"# + "\n" + #"style label { .tooltip("Body", title: "Title") }"#
        let (_, _, program) = try tooltipCompilation(t, source)
        t.equal(program.root.tooltip, ProgramTooltip(text: .string("Body"), title: .string("Title")))
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: tooltipEnvironment(), measure: tooltipMeasure)
        t.equal(scene.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: "Body", title: "Title"))
        t.equal(scene.hitMap.entries.count, 1)
        t.check(scene.hitMap.entries.allSatisfy { $0.actions.isEmpty })
        var literal = try ProgramRuntime(program: tooltipCompilation(t,
            #"widget { Text("A").tooltip("Body", title: "Title") }"#).2)
        t.equal(scene, try literal.project(environment: tooltipEnvironment(), measure: tooltipMeasure))
    }

    t.suite("Desk: tooltips: the original battery health tip displays live and missing Percent values") {
        let (_, _, program) = try tooltipCompilation(t, #"widget { Text("A").tooltip(battery.health) }"#)
        for (value, expected) in [(Optional(94.0), "94"), (nil, "–")] {
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: tooltipEnvironment(), dateInput: tooltipDate(),
                systemInput: ProgramSystemInput(batteryHealth: value), measure: tooltipMeasure)
            t.equal(scene.hitMap.toolTipInfo(at: point.x, point.y, images: nil), ToolTipInfo(text: expected))
            t.equal(runtime.neededSystemProperties, [.batteryHealth]); t.equal(runtime.clockPrecision, .hour)
            var literal = try ProgramRuntime(program: tooltipCompilation(t,
                "widget { Text(\"A\").tooltip(\"\(expected)\") }").2)
            t.equal(scene, try literal.project(environment: tooltipEnvironment(), measure: tooltipMeasure))
        }
    }

    t.suite("Desk: tooltips: conditions states unknown data and dimensions retain explicit boundaries") {
        for source in [#"widget { Text("A").tooltip("Body", if: false) }"#,
                       #"widget { Text("A").tooltip("Body", title: "Title", if: true) }"#,
                       #"widget { Text("A").hover { .tooltip("Body") } }"#,
                       #"widget { Text("A").pressed { .tooltip("Body") } }"#,
                       #"widget { Text("A").tooltip(2W) }"#,
                       #"widget { Text("A").tooltip("Body", title: 2W) }"#,
                       #"widget { Text("A").tooltip(false ? 2W : "Allowed") }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
            t.check(result.program == nil && !result.issues.isEmpty, "\(source)\n\(result.issues)")
            t.check(result.elementRefs.isEmpty && result.imageSources.isEmpty); t.equal(result.diagnostics, checked.diagnostics)
        }
        let duplicate = deskCheck(#"widget { Text("A").tooltip("First").tooltip("Second") }"#)
        t.check(duplicate.diagnostics.contains { $0.id == .duplicateModifier && $0.severity == .error })
        let spacer = deskCheck(#"widget { Column { Text("A"); Spacer().tooltip("Empty") } }"#)
        t.check(spacer.diagnostics.contains { $0.id == .notApplicable && $0.severity == .error })
        for checked in [duplicate, spacer] {
            let result = Desk.compile(checked)
            t.check(result.program == nil && result.elementRefs.isEmpty); t.equal(result.diagnostics, checked.diagnostics)
        }
    }

    t.suite("Desk: tooltips: both display fields share expression and nesting budgets") {
        let source = #"widget { Text("A").tooltip("Body", title: "Title") }"#
        let checked = deskCheck(source)
        var catalog = DeskCatalog.current; catalog.limits.maximumTokens = 3
        let bounded = Desk.compile(checked, catalog: catalog)
        t.check(bounded.program != nil && bounded.issues.isEmpty, "\(bounded.issues)")
        catalog.limits.maximumTokens = 2
        let failed = Desk.compile(checked, catalog: catalog)
        t.equal(failed.issues.first?.kind, .resourceLimit); t.check(failed.program == nil && failed.elementRefs.isEmpty)
        for (source, depth, tokens) in [
            (#"widget { Text("A").tooltip((((cpu.usage))), title: "Title") }"#, 2, 1000),
            (#"widget { Text("A").tooltip("Body", title: false ? (cpu.usage + 1%) : (cpu.usage + 2%)) }"#, 100, 4)] {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            var catalog = DeskCatalog.current; catalog.limits.maximumExpressionNesting = depth; catalog.limits.maximumTokens = tokens
            let result = Desk.compile(checked, catalog: catalog)
            t.equal(result.issues.first?.kind, .resourceLimit); t.check(result.program == nil && result.elementRefs.isEmpty)
        }
    }
}
