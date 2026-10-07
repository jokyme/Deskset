import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum DeskIconFixtureError: Error { case program, icon, receipt, measurement }

private func iconProgram(_ t: TestRunner, _ source: String, context: CheckContext = CheckContext()) throws -> WidgetProgram {
    let checked = deskCheck(source, context: context)
    let result = Desk.compile(checked, catalog: context.catalog)
    t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked, catalog: context.catalog))
    t.check(result.issues.isEmpty, "\(result.issues)")
    t.check(result.imageSources.isEmpty, "symbols are not file-image demands")
    guard let program = result.program else { throw DeskIconFixtureError.program }
    return program
}

private func iconEnvironment(_ dark: Bool = false) -> EnvironmentStamp {
    EnvironmentStamp(scale: 2, fontGeneration: 3,
        appearance: AppearanceStamp(value: dark ? .dark : .light, name: dark ? "dark" : "light"), imageGeneration: 4)
}

private func iconDate(_ seconds: Double = 0) -> ProgramDateInput {
    ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!,
                     locale: Locale(identifier: "en_US"))
}

private func iconMeasure(_ request: IconRequest) -> SkinSize? {
    let points = TextStyle.pixelSize(points: request.style.fontSize)
    return SkinSize(width: 2 * points, height: points)
}

private func iconTextMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    SkinSize(width: 20, height: 12)
}

private func iconDraws(_ scene: WidgetScene) -> [IconDraw] {
    scene.drawingItems.compactMap { if case .icon(let draw) = $0 { return draw }; return nil }
}

private func iconFacts(_ checked: CheckedFile, symbols: [NodeID: Symbol]? = nil,
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

func runDeskIconTests(_ t: TestRunner) {
    t.suite("Desk: icons: literal conditional names warn at their own ranges without guessing dynamic values") {
        let context = CheckContext(symbols: DeskFakeSymbols())
        for expression in [#"system.dark ? "wifi" : "wifi.slashh""#,
                           #"(system.dark ? ("wifi.slashh") : "wifi")"#,
                           #"system.dark ? "wifi" : (system.dark ? "wifi.slash" : "wifi.slashh")"#] {
            let source = "widget { Icon(\(expression)) }"
            let checked = deskCheck(source, context: context)
            let warnings = checked.diagnostics.filter { $0.id == .unknownSymbol }
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.equal(warnings.count, 1)
            guard let warning = warnings.first else { throw DeskIconFixtureError.receipt }
            t.equal(warning.severity, .warning)
            t.equal(String(decoding: Array(source.utf8)[warning.range], as: UTF8.self), #""wifi.slashh""#)
            t.equal(warning.fixIts.first.map { TextEdit.apply($0.edits, to: source) },
                    source.replacingOccurrences(of: "wifi.slashh", with: "wifi.slash"))
            t.check(Desk.compile(checked).program != nil, "warnings preserve the checked program")
            t.check(!deskCheck(source).diagnostics.contains { $0.id == .unknownSymbol })
        }
        let dynamic = #"widget { variable name = "wifi"; Icon(system.dark ? name : "wifi.slashh") }"#
        let checked = deskCheck(dynamic, context: context)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        t.equal(checked.diagnostics.filter { $0.id == .unknownSymbol }.count, 1,
                "a dynamic alternative does not hide the independently known literal")
        for source in [#"widget { Icon(system.dark ? "wifi" : "wifi.slash") }"#,
                       #"widget { Text(system.dark ? "wifi" : "wifi.slashh") }"#,
                       #"widget { variable name = "wifi"; Icon("{name}") }"#] {
            let value = deskCheck(source, context: context)
            t.check(value.diagnostics(.error).isEmpty, deskDescribe(value))
            t.check(!value.diagnostics.contains { $0.id == .unknownSymbol }, source)
        }
    }

    t.suite("Desk: icons: checked names use body font and monochrome while unknown symbols retain warnings") {
        let source = #"widget { Icon("wifi") }"#
        let checked = deskCheck(source, context: CheckContext(symbols: DeskFakeSymbols()))
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        let result = Desk.compile(checked)
        guard let program = result.program, case .icon(let icon) = program.root.content else {
            throw DeskIconFixtureError.icon
        }
        t.equal(icon.name, .string("wifi")); t.equal(icon.fontFamily, "System")
        t.equal(icon.fontSize, 13); t.equal(icon.fontWeight, 400); t.equal(icon.colors, .monochrome)
        t.equal(icon.color, .text); t.equal(icon.align, .center); t.check(!icon.italic && !icon.hasOwnFont)
        t.equal(program.root.width, .fit); t.equal(program.root.height, .fit)
        t.equal(result.elementRefs.count, 1); t.equal(result.imageSources, [])
        t.check(!checked.types.values.contains { $0.type == .symbolName }, "literal SymbolName parameters retain String facts")
        var runtime = try ProgramRuntime(program: program)
        var requests: [IconRequest] = []
        let scene = try runtime.project(environment: iconEnvironment(), measureIcon: { request in
            requests.append(request); return iconMeasure(request)
        }, measure: iconTextMeasure)
        t.equal(requests.count, 1); t.equal(requests.first?.name, "wifi")
        t.equal(requests.first?.style.fontSize, 9.75); t.equal(requests.first?.appearance, iconEnvironment().appearance)
        t.equal(scene.size, SkinSize(width: 26, height: 13)); t.equal(iconDraws(scene).first?.contentFrame, SkinRect(width: 26, height: 13))
        t.equal(scene.elements.first?.kind, .image); t.equal(scene.elements.first?.imageDependencies, [])
        t.equal(runtime.clockPrecision, nil)

        let unknown = deskCheck(#"widget { Icon("wifi.slashh").size(20) }"#, context: CheckContext(symbols: DeskFakeSymbols()))
        t.check(unknown.diagnostics.contains { $0.id.rawValue == "DK4031" && $0.severity == .warning }, deskDescribe(unknown))
        let unknownResult = Desk.compile(unknown)
        t.equal(unknownResult.diagnostics, unknown.diagnostics)
        guard let unknownProgram = unknownResult.program else { throw DeskIconFixtureError.program }
        var unknownRuntime = try ProgramRuntime(program: unknownProgram)
        var unknownNames: [String] = []
        let absent = try unknownRuntime.project(environment: iconEnvironment(), measureIcon: { request in
            unknownNames.append(request.name); return nil
        }, measure: iconTextMeasure)
        t.equal(unknownNames, ["wifi.slashh"]); t.equal(absent.size, SkinSize(width: 20, height: 20))
        t.check(absent.drawingItems.isEmpty, "an unknown symbol is an empty image, not a fallback file")
    }

    t.suite("Desk: icons: dynamic names remain raw through conditional parentheses templates and aliases") {
        let expressions: [(String, String, String)] = [
            (#"system.dark ? "moon.fill" : "sun.max.fill""#, "sun.max.fill", "moon.fill"),
            (#"((system.dark ? ("moon.fill") : ("sun.max.fill")))"#, "sun.max.fill", "moon.fill"),
            (#"system.dark ? (battery.charging ? "bolt.fill" : "battery.100") : "wifi""#, "wifi", "bolt.fill"),
            (#""battery.{25}""#, "battery.25", "battery.25"),
            (#"("wifi").ifMissing("wifi.slash")"#, "wifi", "wifi")]
        for (expression, light, dark) in expressions {
            var runtime = try ProgramRuntime(program: iconProgram(t, "widget { Icon(\(expression)).size(30) }"))
            for (appearance, expected) in [(false, light), (true, dark)] {
                let scene = try runtime.project(environment: iconEnvironment(appearance), dateInput: iconDate(),
                    systemInput: ProgramSystemInput(batteryCharging: true), measureIcon: iconMeasure, measure: iconTextMeasure)
                t.equal(iconDraws(scene).first?.request.name, expected, expression)
                t.equal(scene.size, SkinSize(width: 30, height: 30))
            }
        }
        let source = #"widget { variable chosen = "wifi"; computed glyph = battery.charging ? chosen : "battery.100"; Icon(glyph).size(30).voiceOver(glyph).onClick { chosen = "bolt.fill"; copy(chosen) }.onRightClick { chosen = "wifi.slash" } }"#
        var runtime = try ProgramRuntime(program: iconProgram(t, source))
        let input = ProgramSystemInput(batteryCharging: true)
        t.equal(runtime.neededSystemProperties, [.batteryCharging])
        let first = try runtime.project(environment: iconEnvironment(), systemInput: input,
            measureIcon: iconMeasure, measure: iconTextMeasure)
        t.equal(iconDraws(first).first?.request.name, "wifi"); t.equal(first.elements.first?.accessibilityLabel, "wifi")
        let primary = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: iconEnvironment(), systemInput: input, measureIcon: iconMeasure, measure: iconTextMeasure)
        t.equal(primary?.effects, [.copy("bolt.fill")]); t.equal(primary.map { iconDraws($0.scene).first?.request.name }, "bolt.fill")
        t.equal(primary?.scene.elements.first?.accessibilityLabel, "bolt.fill")
        guard let primary else { throw DeskIconFixtureError.program }
        let secondary = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: primary.scene.generation,
            event: .rightUp, environment: iconEnvironment(), systemInput: input, measureIcon: iconMeasure, measure: iconTextMeasure)
        t.equal(secondary.map { iconDraws($0.scene).first?.request.name }, "wifi.slash")
        t.equal(secondary?.scene.elements.first?.accessibilityLabel, "wifi.slash")
        t.check(try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: iconEnvironment(), systemInput: input, measureIcon: iconMeasure, measure: iconTextMeasure) == nil)
        t.equal(runtime.clockPrecision, nil, "names based on event-only charging do not poll")
    }

    t.suite("Desk: icons: own font versus inherited and bold italic preserves the fixed-box fitting contract") {
        let examples: [(String, Bool, Int, Bool, SkinRect)] = [
            (#"Icon("wifi").size(20)"#, false, 400, false, SkinRect(y: 5, width: 20, height: 10)),
            (#"Icon("wifi").size(20).bold().italic()"#, false, 700, true, SkinRect(y: 5, width: 20, height: 10)),
            (#"Icon("wifi").size(20).font(40)"#, true, 400, false, SkinRect(x: -30, y: -10, width: 80, height: 40))]
        for (view, own, weight, italic, expected) in examples {
            let program = try iconProgram(t, "widget { \(view) }")
            guard case .icon(let icon) = program.root.content else { throw DeskIconFixtureError.icon }
            t.equal(icon.hasOwnFont, own); t.equal(icon.fontWeight, weight); t.equal(icon.italic, italic)
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: iconEnvironment(), measureIcon: iconMeasure, measure: iconTextMeasure)
            t.equal(iconDraws(scene).first?.contentFrame, expected, view)
            t.equal(scene.elements.first?.frame, SkinRect(width: 20, height: 20), "glyph overflow does not rewrite the box")
        }
        let inherited = try iconProgram(t,
            #"widget { Column(spacing: 0) { Icon("wifi").size(20); Icon("wifi").width(20).height(20); Icon("wifi").width(20) }.font(40).bold().italic() }"#)
        guard case .column(_, _, let children) = inherited.root.content else { throw DeskIconFixtureError.icon }
        for child in children {
            guard case .icon(let icon) = child.content else { throw DeskIconFixtureError.icon }
            t.check(!icon.hasOwnFont); t.equal(icon.fontSize, 40); t.equal(icon.fontWeight, 700); t.check(icon.italic)
        }
        var runtime = try ProgramRuntime(program: inherited)
        let scene = try runtime.project(environment: iconEnvironment(), measureIcon: iconMeasure, measure: iconTextMeasure)
        let draws = iconDraws(scene)
        t.equal(draws.map { $0.contentFrame.width }, [20, 20, 80], "both fixed axes, rather than one, enable fitting")
        t.equal(draws.map { $0.contentFrame.height }, [10, 10, 40])

        for (align, x) in [("left", 2.0), ("center", 10.0), ("right", 18.0)] {
            var aligned = try ProgramRuntime(program: iconProgram(t,
                "widget { Icon(\"wifi\").font(10).size(40, 30).padding(2).align(.\(align)) }"))
            let draw = iconDraws(try aligned.project(environment: iconEnvironment(), measureIcon: iconMeasure, measure: iconTextMeasure)).first
            t.equal(draw?.contentFrame, SkinRect(x: x, y: 10, width: 20, height: 10))
        }
    }

    t.suite("Desk: icons: complete supported font styles and live inherited sizes reach typed symbol requests") {
        for (font, family, weight) in [("20, .rounded, .semibold", "System Rounded", 600),
                                     ("20, .mono", "System Mono", 400), ("20, .serif", "System Serif", 400),
                                     (#""Menlo", 20, .bold"#, "Menlo", 700), (".largeNumber", "System Rounded", 600)] {
            let program = try iconProgram(t, "widget { Icon(\"wifi\").font(\(font)).italic().color(\"#E05020\").align(.right) }")
            guard case .icon(let icon) = program.root.content else { throw DeskIconFixtureError.icon }
            t.equal(icon.fontFamily, family); t.equal(icon.fontWeight, weight); t.check(icon.italic && icon.hasOwnFont)
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: iconEnvironment(), measureIcon: iconMeasure, measure: iconTextMeasure)
            guard let draw = iconDraws(scene).first else { throw DeskIconFixtureError.icon }
            t.equal(draw.request.style.fontFace, family); t.equal(draw.request.style.fontWeight, weight)
            t.check(draw.request.style.italic); t.equal(draw.request.style.horizontalAlign, .right)
            t.equal(draw.request.style.color, RGBA(r: 224, g: 80, b: 32))
            t.close(TextStyle.pixelSize(points: draw.request.style.fontSize), icon.fontSize)
            t.check(draw.request.style.inlineSpans.isEmpty, "font-preset digits are not text spans on a symbol")
        }
        let source = #"widget { variable points = 10pt; Column(spacing: 0) { Icon("wifi").size(40).onClick { points = 20pt }; Icon("wifi").font(points) }.font(points, .semibold) }"#
        var runtime = try ProgramRuntime(program: iconProgram(t, source))
        var requests: [IconRequest] = []
        let measurement: (IconRequest) -> SkinSize? = { request in requests.append(request); return iconMeasure(request) }
        let first = try runtime.project(environment: iconEnvironment(), measureIcon: measurement, measure: iconTextMeasure)
        t.equal(requests.map { TextStyle.pixelSize(points: $0.style.fontSize) }, [10, 10])
        t.equal(iconDraws(first).map { $0.contentFrame.width }, [40, 20])
        requests.removeAll()
        let changed = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: iconEnvironment(), measureIcon: measurement, measure: iconTextMeasure)
        t.equal(requests.map { TextStyle.pixelSize(points: $0.style.fontSize) }, [20, 20], "one measurement per icon in each projection")
        t.equal(changed.map { iconDraws($0.scene).map { $0.contentFrame.width } }, [40, 40])
    }

    t.suite("Desk: icons: static color modes backgrounds rounding and labels remain separate ordered recipes") {
        for mode in ["monochrome", "hierarchical", "multicolor"] {
            for spelling in [".\(mode)", "IconColors.\(mode)"] {
                var runtime = try ProgramRuntime(program: iconProgram(t,
                    "widget { Icon(\"wifi\").size(40).iconColors(\(spelling)).background(.glass, tint: .accent).rounded(4).voiceOver(\"Network\") }"))
                let scene = try runtime.project(environment: iconEnvironment(), measureIcon: iconMeasure, measure: iconTextMeasure)
                t.equal(iconDraws(scene).first?.request.colors, IconColors(rawValue: mode))
                t.equal(scene.elements.first?.accessibilityLabel, "Network")
                t.equal(scene.elements.first?.glass?.cornerRadius, 4)
                t.equal(scene.drawingItems.count, 2)
                if case .glass? = scene.drawingItems.first { t.check(true) } else { t.check(false, "glass precedes the icon") }
                if case .icon? = scene.drawingItems.last { t.check(true) } else { t.check(false, "icon remains a typed symbol recipe") }
            }
        }
        var catalog = DeskCatalog.current
        guard let component = catalog.components.firstIndex(where: { $0.name == "Icon" }) else { throw DeskIconFixtureError.receipt }
        catalog.components[component].defaults["iconColors"] = ".hierarchical"
        let program = try iconProgram(t, #"widget { Icon("wifi") }"#, context: CheckContext(catalog: catalog))
        guard case .icon(let icon) = program.root.content else { throw DeskIconFixtureError.icon }
        t.equal(icon.colors, .hierarchical, "the exact checking catalog owns the default")
        var column = try ProgramRuntime(program: iconProgram(t,
            #"widget { Column { Icon("wifi").iconColors(.multicolor); Icon("wifi") }.color(.accent) }"#))
        let scene = try column.project(environment: iconEnvironment(), measureIcon: iconMeasure, measure: iconTextMeasure)
        t.equal(iconDraws(scene).map { $0.request.colors }, [.multicolor, .monochrome], "IconColors do not inherit")
        t.check(iconDraws(scene).allSatisfy { $0.request.style.color == SkinAppearance.light.accentColor })
    }

    t.suite("Desk: icons: hidden names keep measured space without clock and failed action measurement rolls back") {
        let source = #"widget { variable began = time.now; Column(spacing: 0) { Icon(((time.now - began) / 1s) >= 1 ? "bolt.fill" : "wifi").size(30).voiceOver(battery.timeRemaining).hidden(); Text("A") } }"#
        var hidden = try ProgramRuntime(program: iconProgram(t, source))
        var names: [String] = []
        let scene = try hidden.project(environment: iconEnvironment(), dateInput: iconDate(), measureIcon: { request in
            names.append(request.name); return iconMeasure(request)
        }, measure: iconTextMeasure)
        t.equal(names, ["wifi"]); t.equal(scene.size, SkinSize(width: 30, height: 42))
        t.equal(scene.elements[1].visibility, .hiddenKeepsSpace); t.equal(scene.elements[1].accessibilityLabel, nil)
        t.equal(hidden.neededSystemProperties, [], "hidden labels do not demand Battery inputs")
        t.equal(hidden.clockPrecision, nil); t.check(iconDraws(scene).isEmpty)

        var runtime = try ProgramRuntime(program: iconProgram(t,
            #"widget { variable name = "wifi"; Icon(name).size(30).voiceOver(name).onClick { name = "bolt.fill"; copy(name) } }"#))
        let first = try runtime.project(environment: iconEnvironment(), measureIcon: iconMeasure, measure: iconTextMeasure)
        t.throwsError("measurement failure must abort variables, labels, generation and effects") {
            _ = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
                environment: iconEnvironment(), measureIcon: { request in
                    if request.name == "bolt.fill" { throw DeskIconFixtureError.measurement }
                    return iconMeasure(request)
                }, measure: iconTextMeasure)
        }
        t.equal(runtime.generation, first.generation)
        let recovered = try runtime.project(environment: iconEnvironment(), measureIcon: iconMeasure, measure: iconTextMeasure)
        t.equal(iconDraws(recovered).first?.request.name, "wifi"); t.equal(recovered.elements.first?.accessibilityLabel, "wifi")
        let missing = try runtime.project(environment: iconEnvironment(), measureIcon: { _ in nil }, measure: iconTextMeasure)
        t.check(missing.drawingItems.isEmpty); t.equal(missing.elements.first?.accessibilityLabel, "wifi")
        t.equal(iconDraws(try runtime.project(environment: iconEnvironment(), measureIcon: iconMeasure, measure: iconTextMeasure))
            .first?.request.name, "wifi", "a later valid symbol recovers normally")
    }

    t.suite("Desk: icons: damaged catalog types data and color-mode receipts prevent program publication") {
        let checked = deskCheck(#"widget { Icon(battery.charging ? "bolt.fill" : "wifi").iconColors(.multicolor) }"#)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        guard let element = checked.elements.first, let call = checked.tree.resolve(element.key).flatMap(CallStmtSyntax.init),
              let argument = call.arguments?.arguments.first?.value.node,
              let condition = TernaryExprSyntax(argument)?.condition.node,
              let candidate = element.value.facets["iconColors"]?.first, case .own(let origin) = candidate.origin,
              let component = DeskCatalog.current.components.firstIndex(where: { $0.name == "Icon" }),
              let modifier = DeskCatalog.current.modifiers.firstIndex(where: { $0.name == "iconColors" }),
              let facet = DeskCatalog.current.facets.firstIndex(where: { $0.id == "iconColors" }) else {
            throw DeskIconFixtureError.receipt
        }
        func rejected(_ value: CheckedFile, catalog: DeskCatalog = .current) {
            let result = Desk.compile(value, catalog: catalog)
            t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty)
            t.check(!result.issues.isEmpty, "\(result.issues)"); t.equal(result.diagnostics, value.diagnostics)
        }
        var types = checked.types; types.removeValue(forKey: checked.tree.id(of: argument)); rejected(iconFacts(checked, types: types))
        types = checked.types; types[checked.tree.id(of: argument)] = SemType(type: .bool); rejected(iconFacts(checked, types: types))
        types = checked.types; types.removeValue(forKey: candidate.value); rejected(iconFacts(checked, types: types))
        var symbols = checked.symbols; symbols.removeValue(forKey: checked.tree.id(of: condition)); rejected(iconFacts(checked, symbols: symbols))
        symbols = checked.symbols; symbols.removeValue(forKey: origin); rejected(iconFacts(checked, symbols: symbols))
        symbols = checked.symbols; symbols[candidate.value] = .enumCase(type: "Digits", case: "equalWidth")
        rejected(iconFacts(checked, symbols: symbols)); rejected(iconFacts(checked, dataUses: []))
        for damage in ["missing", "fixed", "origin", "duplicate", "inherited"] {
            var elements = checked.elements
            switch damage {
            case "missing": elements[element.key]?.facets.removeValue(forKey: "iconColors")
            case "fixed": elements[element.key]?.facets["iconColors"]?[0].fixedValue = ".monochrome"
            case "origin": elements[element.key]?.facets["iconColors"]?[0].origin = .own(candidate.value)
            case "duplicate": elements[element.key]?.facets["iconColors"]?.append(candidate)
            default: elements[element.key]?.inherits.insert("iconColors")
            }
            rejected(iconFacts(checked, elements: elements))
        }
        let componentChanges: [(inout ComponentSpec) -> Void] = [
            { $0.signatures[0].params[0].type = .string }, { $0.signatures[0].params[0].role = .display },
            { $0.signatures[0].params[0].translatable = true }]
        for change in componentChanges {
            var catalog = DeskCatalog.current; change(&catalog.components[component]); rejected(checked, catalog: catalog)
        }
        let modifierChanges: [(inout ModifierSpec) -> Void] = [
            { $0.inheritable = true }, { $0.facets = [] }, { $0.signatures[0].params[0].type = .any },
            { $0.signatures[0].params[0].role = .display }, { $0.signatures[0].params[0].source = .literal }]
        for change in modifierChanges {
            var catalog = DeskCatalog.current; change(&catalog.modifiers[modifier]); rejected(checked, catalog: catalog)
        }
        var catalog = DeskCatalog.current; catalog.facets[facet].inheritable = true; rejected(checked, catalog: catalog)
        catalog = DeskCatalog.current; catalog.components[component].defaults.removeValue(forKey: "iconColors")
        rejected(deskCheck(#"widget { Icon("wifi") }"#), catalog: catalog)
        // A forged String fact cannot turn numeric branches into symbol names through display formatting.
        let numeric = deskCheck(#"widget { Icon(system.dark ? 42 : 80) }"#)
        let clean = deskCheck(#"widget { Text(system.dark ? 42 : 80) }"#)
        t.check(!numeric.diagnostics(.error).isEmpty)
        t.check(clean.diagnostics(.error).isEmpty, deskDescribe(clean))
        guard let textElement = clean.elements.first,
              let textCall = clean.tree.resolve(textElement.key).flatMap(CallStmtSyntax.init),
              let numericArgument = textCall.arguments?.arguments.first?.value.node else { throw DeskIconFixtureError.receipt }
        var compiler = ProgramExpressionCompiler(checked: clean, catalog: .current)
        let raw = try compiler.symbolName(numericArgument)
        t.throwsError("raw symbol names do not acquire numeric display coercions") {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Bad name", root: ProgramElement(id: ElementID(name: "Icon", index: 0),
                content: .icon(ProgramIcon(name: raw)))))
        }
    }

    t.suite("Desk: icons: the original conditional color follows each current appearance") {
        let program = try iconProgram(t, #"widget { Icon("wifi").color(.accent, if: system.dark) }"#)
        var runtime = try ProgramRuntime(program: program)
        for dark in [false, true, false] {
            let scene = try runtime.project(environment: iconEnvironment(dark), measureIcon: iconMeasure, measure: iconTextMeasure)
            t.equal(iconDraws(scene).map(\.request.name), ["wifi"])
            t.equal(iconDraws(scene).first?.request.style.color,
                    dark ? SkinAppearance.dark.accentColor : SkinAppearance.light.labelColor)
            t.equal(iconDraws(scene).first?.request.colors, .monochrome)
        }
    }

    t.suite("Desk: icons: unsupported effects styles dimensions and resource limits remain explicit") {
        for source in [#"info { permissions: [.location] }"# + "\n" + #"widget { Icon(weather.now.symbol) }"#,
                       #"widget { Icon(moon.symbol) }"#,
                       #"widget { Icon("wifi").iconEffect(.pulse) }"#, #"widget { Icon("wifi").flip(.horizontal) }"#,
                       #"widget { Icon("wifi").iconColors(system.dark ? .multicolor : .monochrome) }"#,
                       #"widget { Icon("wifi").font(20, if: system.dark) }"#,
                       #"widget { Icon("wifi").iconColors(.multicolor(123)) }"#,
                       #"widget { Icon("wifi").style(symbol) }"# + "\n" + #"style symbol { .font(20) }"#] {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
            let result = Desk.compile(checked)
            t.check(result.program == nil && !result.issues.isEmpty, source)
            t.equal(result.diagnostics, checked.diagnostics); t.check(result.elementRefs.isEmpty && result.imageSources.isEmpty)
        }
        let inapplicable = deskCheck(#"widget { Icon("wifi").digits(.equalWidth) }"#)
        t.equal(inapplicable.diagnostics(.error).map(\.id), [.notApplicable], deskDescribe(inapplicable))
        let rejected = Desk.compile(inapplicable)
        t.check(rejected.program == nil && rejected.issues.isEmpty, "catalog errors prevent lowering")
        t.equal(rejected.diagnostics, inapplicable.diagnostics)
        t.check(rejected.elementRefs.isEmpty && rejected.imageSources.isEmpty)
        for (source, nesting, tokens) in [
            (#"widget { Icon((((battery.charging ? "bolt.fill" : "wifi")))) }"#, 2, 1000),
            (#"widget { Icon(battery.charging ? "bolt.fill" : "wifi") }"#, 100, 2)] {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            var catalog = DeskCatalog.current
            catalog.limits.maximumExpressionNesting = nesting; catalog.limits.maximumTokens = tokens
            let result = Desk.compile(checked, catalog: catalog)
            t.equal(result.issues.first?.kind, .resourceLimit); t.check(result.program == nil && result.elementRefs.isEmpty)
        }
    }
}
