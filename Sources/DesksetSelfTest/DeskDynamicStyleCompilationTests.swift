import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum DynamicStyleFixtureError: Error { case program(String), receipt(String) }

private enum DynamicStyleFixture {
    static func checked(_ source: String, package: String? = nil) throws -> (CheckedFile, CheckedFile?) {
        guard let package else { return (deskCheck(source, file: "DynamicStyles.desk"), nil) }
        let folder = CheckedDeskPackage(package: deskMemoryPackage([
            "package.desk": package, "DynamicStyles.desk": source
        ]))
        guard let shared = folder.files[DeskFileID("package.desk")],
              let widget = folder.files[DeskFileID("DynamicStyles.desk")] else {
            throw DynamicStyleFixtureError.receipt("checked package")
        }
        return (widget, shared)
    }

    static func compile(_ t: TestRunner, _ source: String, package: String? = nil) throws -> (CheckedFile, WidgetProgram) {
        let (checked, shared) = try self.checked(source, package: package)
        t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
        if let shared { t.check(shared.diagnostics(.error).isEmpty, deskDescribe(shared)) }
        let result = Desk.compile(checked, package: shared)
        t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
        t.equal(result.diagnostics, checked.diagnostics + (shared?.diagnostics ?? []))
        guard let program = result.program else { throw DynamicStyleFixtureError.program(source) }
        return (checked, program)
    }

    static func environment(_ dark: Bool = false) -> EnvironmentStamp {
        EnvironmentStamp(scale: 1, fontGeneration: 1,
            appearance: AppearanceStamp(value: dark ? .dark : .light, name: "dynamic-styles"), imageGeneration: 0)
    }

    static func date(_ seconds: Double = 0) -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!,
                         locale: Locale(identifier: "en_US"))
    }

    static func measure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
        SkinSize(width: Double(text.utf16.count) * 5, height: TextStyle.pixelSize(points: style.fontSize))
    }

    static func measureIcon(_ request: IconRequest) -> SkinSize? {
        let size = TextStyle.pixelSize(points: request.style.fontSize)
        return SkinSize(width: size * 2, height: size)
    }

    static func input(_ runtime: ProgramRuntime, _ edits: [String: ProgramOptionValue]) -> ProgramOptionsInput {
        ProgramOptionsInput(values: runtime.optionValues.values.merging(edits) { _, new in new })
    }

    static func texts(_ scene: WidgetScene) -> [TextDraw] {
        scene.drawingItems.compactMap { if case .text(let draw) = $0 { return draw }; return nil }
    }

    static func icons(_ scene: WidgetScene) -> [IconDraw] {
        scene.drawingItems.compactMap { if case .icon(let draw) = $0 { return draw }; return nil }
    }

    static func element(_ scene: WidgetScene, _ name: String) throws -> SceneElement {
        guard let element = scene.elements.first(where: { $0.id.name == name }) else {
            throw DynamicStyleFixtureError.receipt(name)
        }
        return element
    }

    static func paints(_ scene: WidgetScene, _ name: String) throws -> [RGBA] {
        try element(scene, name).items.compactMap {
            switch $0 {
            case .fill(_, let paint): return paint.color
            case .bar(let draw): return draw.color
            case .roundline(let draw): return draw.color
            default: return nil
            }
        }
    }

    static func facts(_ checked: CheckedFile, symbols: [NodeID: Symbol]? = nil, types: [NodeID: SemType]? = nil,
                      elements: [NodeID: ElementFacts]? = nil, dataUses: [DataUse]? = nil) -> CheckedFile {
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

    static func reject(_ t: TestRunner, _ checked: CheckedFile, package: CheckedFile? = nil,
                       catalog: DeskCatalog = .current, kind: DeskCompilationIssue.Kind? = nil, _ reason: String) {
        let result = Desk.compile(checked, catalog: catalog, package: package)
        t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty, reason)
        t.check(!result.issues.isEmpty, "\(reason): \(result.issues)")
        if let kind { t.equal(result.issues.first?.kind, kind, reason) }
        t.equal(result.diagnostics, checked.diagnostics + (package?.diagnostics ?? []), reason)
    }
}

func runDeskDynamicStyleCompilationTests(_ t: TestRunner) {
    typealias F = DynamicStyleFixture
    let red = RGBA(r: 255, g: 0, b: 0), green = RGBA(r: 0, g: 255, b: 0)
    let blue = RGBA(r: 0, g: 0, b: 255), yellow = RGBA(r: 255, g: 255, b: 0)

    t.suite("Desk: dynamic styles: option fonts update inherited text and distinguish an Icon style font from inheritance") {
        let source = #"""
            options { size = Stepper("Size", min: 8pt, max: 40pt, default: 12pt) }
            style live { .font(options.size) }
            widget { Row(spacing: 0) {
                Text("Inherited").name(inherited)
                Text("Own").style(live).font(10).name(own)
                Icon("wifi").size(20).style(live).name(explicit)
                Icon("wifi").size(20).name(inheritedIcon)
            }.style(live).onClick { options.size = options.size + 2pt; copy(options.size) } }
            """#
        let (_, program) = try F.compile(t, source)
        guard case .row(_, _, let children) = program.root.content, children.count == 4,
              case .icon(let explicit) = children[2].content,
              case .icon(let inherited) = children[3].content else { throw DynamicStyleFixtureError.receipt("font children") }
        t.check(explicit.hasOwnFont && !inherited.hasOwnFont)
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: F.environment(), dateInput: F.date(),
            measureIcon: F.measureIcon, measure: F.measure)
        t.equal(F.texts(first).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [12, 10])
        t.equal(F.icons(first).map { $0.contentFrame.width }, [24, 20])
        t.equal(F.icons(first).map { $0.contentFrame.height }, [12, 10])
        guard let updated = try runtime.updateOptions(F.input(runtime, ["size": .number(ProgramNumber(24, dimension: .length))]),
            expectedRevision: 0, environment: F.environment(), dateInput: F.date(),
            measureIcon: F.measureIcon, measure: F.measure) else { throw DynamicStyleFixtureError.receipt("font update") }
        t.equal(F.texts(updated).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [24, 10])
        t.equal(F.icons(updated).map { $0.contentFrame.width }, [48, 20])
        t.equal(F.icons(updated).map { $0.contentFrame.height }, [24, 10])
        t.equal(updated.elements.map(\.id), first.elements.map(\.id))
        let clicked = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: updated.generation,
            environment: F.environment(), dateInput: F.date(), measureIcon: F.measureIcon, measure: F.measure)
        t.equal(clicked?.effects, [.copy("26")])
        t.equal(clicked.map { F.texts($0.scene).map { TextStyle.pixelSize(points: $0.style.fontSize) } }, [26, 10])
        t.equal(runtime.optionValues.values["size"], .number(ProgramNumber(26, dimension: .length)))
        t.equal(runtime.optionsRevision, 2); t.equal(runtime.clockPrecision, nil)

        let numericFonts: [(String, Double, Double)] = [
            ("cpu.coreCount", 8, 16), ("cpu.usage / 1%", 20, 40), ("6 + 6", 12, 12)
        ]
        for (expression, firstSize, nextSize) in numericFonts {
            for spelling in [expression, "(\(expression))", "((\(expression)))"] {
                let source = "style live { .font(\(spelling)) }\n" + #"""
                    widget { Column(spacing: 0) {
                        Text("A").style(live)
                        Progress(cpu.usage).size(100, 6)
                    } }
                    """#
                let (checked, program) = try F.compile(t, source)
                guard let progressID = checked.elements.first(where: { $0.value.component == "Progress" })?.key,
                      let node = checked.tree.resolve(progressID), let call = CallStmtSyntax(node),
                      let argument = call.arguments?.arguments.first?.value.node else {
                    throw DynamicStyleFixtureError.receipt("adjacent Percent progress")
                }
                let argumentID = checked.tree.id(of: argument)
                t.equal(checked.types[argumentID]?.type, .percent)
                t.equal(checked.numericCoercions[argumentID], nil,
                        "Progress keeps its Percent value; this is not a Fraction parameter")
                var runtime = try ProgramRuntime(program: program)
                for (cpu, cores, expectedSize) in [(20.0, 8, firstSize), (40.0, 16, nextSize)] {
                    let scene = try runtime.project(environment: F.environment(),
                        systemInput: ProgramSystemInput(cpuUsage: cpu, cpuCoreCount: cores), measure: F.measure)
                    t.equal(F.texts(scene).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [expectedSize], spelling)
                    let bars: [BarDraw] = scene.drawingItems.compactMap { if case .bar(let draw) = $0 { return draw }; return nil }
                    t.equal(bars.flatMap(\.visibleRects).map(\.width), [cpu], spelling)
                }
            }
        }
    }

    t.suite("Desk: dynamic styles: visibility keeps measurement but retires hidden labels hits and unused clocks") {
        let source = #"""
            options { hide = Toggle("Hide") }
            style concealed {
                .hidden(if: options.hide or cpu.usage < 20%)
                .font(system.dark ? 18 : 12)
                .tooltip("{time.now, format: "HH:mm:ss"}")
                .voiceOver(cpu.usage)
            }
            widget { Text("A").size(40, 24).style(concealed).onClick { copy("tap") } }
            """#
        var runtime = try ProgramRuntime(program: F.compile(t, source).1)
        t.equal(runtime.neededSystemProperties, [.cpuUsage])
        let first = try runtime.project(environment: F.environment(), dateInput: F.date(),
            systemInput: ProgramSystemInput(), measure: F.measure)
        t.equal(first.elements.first?.visibility, .visible, "an outer missing condition is false")
        t.equal(first.elements.first?.accessibilityLabel, "–")
        t.equal(first.hitMap.toolTipInfo(at: 1, 1, images: nil)?.text, "00:00:00")
        t.equal(runtime.clockPrecision, .second)
        var measured: [Double] = []
        let hidden = try runtime.project(environment: F.environment(), systemInput: ProgramSystemInput(cpuUsage: 10),
            measure: { text, style, width in
                measured.append(TextStyle.pixelSize(points: style.fontSize))
                return F.measure(text, style, width)
            })
        t.check(!measured.isEmpty && measured.allSatisfy { $0 == 12 }); t.equal(hidden.size, first.size)
        t.equal(hidden.elements.first?.visibility, .hiddenKeepsSpace)
        t.equal(hidden.elements.first?.accessibilityLabel, nil)
        t.check(hidden.drawingItems.isEmpty && hidden.hitMap.entries.isEmpty)
        t.equal(runtime.clockPrecision, .second, "the hiding predicate itself can recover")
        guard let optionHidden = try runtime.updateOptions(F.input(runtime, ["hide": .boolean(true)]), expectedRevision: 0,
            environment: F.environment(true), systemInput: ProgramSystemInput(), measure: F.measure) else {
            throw DynamicStyleFixtureError.receipt("hidden option update")
        }
        t.equal(optionHidden.size, first.size); t.check(optionHidden.hitMap.entries.isEmpty)
        t.equal(runtime.clockPrecision, nil, "the option short-circuits CPU; hidden labels do not read time")
        t.equal(runtime.neededSystemProperties, [.cpuUsage], "sampling remains conservative for a potential visible state")
        let restored = try runtime.updateOptions(F.input(runtime, ["hide": .boolean(false)]), expectedRevision: 1,
            environment: F.environment(true), dateInput: F.date(3), systemInput: ProgramSystemInput(cpuUsage: 80), measure: F.measure)
        t.equal(restored?.elements.first?.accessibilityLabel, "80")
        t.equal(restored?.hitMap.toolTipInfo(at: 1, 1, images: nil)?.text, "00:00:03")
        t.equal(restored.map { F.texts($0).map { TextStyle.pixelSize(points: $0.style.fontSize) } }, [18])
    }

    t.suite("Desk: dynamic styles: active conditions outrank own bases while ancestor fallbacks and meter paints stay independent") {
        let source = ##"""
            options { alert = Toggle("Alert"); later = Toggle("Later") }
            style inherited { .color("#00FF00") }
            style alert { .color("#FF0000", if: options.alert) }
            style later { .color("#FFFF00", if: options.later) }
            style solid { .fill("#0000FF").fill("#FF0000", if: options.alert) }
            style meter {
                .color("#0000FF").color("#FF0000", if: options.alert)
                .track("#00FF00").track("#FFFF00", if: options.later)
            }
            widget { Column(spacing: 0) {
                Column(spacing: 0) {
                    Text("Fallback")
                    Text("Own").color("#0000FF")
                    Text("Variant").style(alert).color("#0000FF").color("#FFFFFF", if: options.later)
                    Text("Order").style(alert).style(later)
                }.style(alert)
                Rectangle().size(20).style(solid).name(shape)
                Progress(0.5).size(40, 8).style(meter).name(progress)
                Gauge(0.5).size(20).style(meter).name(gauge)
            }.style(inherited) }
            """##
        var runtime = try ProgramRuntime(program: F.compile(t, source).1)
        let cases: [(Bool, Bool, [RGBA], RGBA, RGBA)] = [
            (false, false, [green, blue, blue, green], blue, green),
            (true, false, [red, blue, red, red], red, green),
            (true, true, [red, blue, .white, yellow], red, yellow),
            (false, true, [green, blue, .white, yellow], blue, yellow)
        ]
        for (alert, later, textColors, foreground, track) in cases {
            guard let scene = try runtime.updateOptions(F.input(runtime, ["alert": .boolean(alert), "later": .boolean(later)]),
                expectedRevision: runtime.optionsRevision, environment: F.environment(), measure: F.measure) else {
                throw DynamicStyleFixtureError.receipt("paint options")
            }
            t.equal(F.texts(scene).map { $0.style.color }, textColors)
            t.equal(try F.paints(scene, "shape"), [foreground])
            t.equal(try F.paints(scene, "progress"), [track, foreground])
            t.equal(try F.paints(scene, "gauge"), [track, foreground])
            t.equal(runtime.clockPrecision, nil)
        }
    }

    t.suite("Desk: dynamic styles: tooltip fields and VoiceOver retain dynamic display translation and demand") {
        let source = #"""
            options { note = Input("Note", default: "Alpha") }
            style note {
                .tooltip("CPU {cpu.usage}", title: "Name {options.note}")
                .voiceOver("{options.note}: {battery.charging}")
            }
            widget { Text("A").size(120, 24).style(note).tooltip("Own {options.note}") }
            translations { "zh-Hans" {
                "Name {options.note}": "{options.note} 标题"
                "{options.note}: {battery.charging}": "{battery.charging}／{options.note}"
                "Own {options.note}": "自己的 {options.note}"
            } }
            """#
        var runtime = try ProgramRuntime(program: F.compile(t, source).1, language: "zh-Hans")
        t.equal(runtime.neededSystemProperties, [.batteryCharging], "an overridden style body is validated but never sampled")
        let first = try runtime.project(environment: F.environment(), dateInput: F.date(),
            systemInput: ProgramSystemInput(batteryCharging: true), measure: F.measure)
        t.equal(first.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "自己的 Alpha", title: "Alpha 标题"))
        t.equal(first.elements.first?.accessibilityLabel, "Yes／Alpha")
        t.equal(runtime.clockPrecision, nil)
        let next = try runtime.updateOptions(F.input(runtime, ["note": .string("Beta")]), expectedRevision: 0,
            environment: F.environment(), dateInput: F.date(), systemInput: ProgramSystemInput(batteryCharging: false), measure: F.measure)
        t.equal(next?.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "自己的 Beta", title: "Beta 标题"))
        t.equal(next?.elements.first?.accessibilityLabel, "No／Beta")
        let telemetry = #"""
            style telemetry { .tooltip(cpu.usage, title: "{time.now, format: "HH:mm:ss"}").voiceOver(battery.timeRemaining) }
            widget { Rectangle().size(20).style(telemetry) }
            """#
        var live = try ProgramRuntime(program: F.compile(t, telemetry).1)
        t.equal(live.neededSystemProperties, [.cpuUsage, .batteryTimeRemaining])
        let missing = try live.project(environment: F.environment(), dateInput: F.date(),
            systemInput: ProgramSystemInput(), measure: F.measure)
        t.equal(missing.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "–", title: "00:00:00"))
        t.equal(missing.elements.first?.accessibilityLabel, "–")
        let ready = try live.project(environment: F.environment(), dateInput: F.date(42),
            systemInput: ProgramSystemInput(cpuUsage: 42, batteryTimeRemaining: 273_852), measure: F.measure)
        t.equal(ready.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "42", title: "00:00:42"))
        t.equal(ready.elements.first?.accessibilityLabel, "3d 4h")
        t.equal(live.clockPrecision, .second)
    }

    t.suite("Desk: dynamic styles: failed option and action projections preserve variables fonts labels and effects") {
        let source = #"""
            options {
                size = Stepper("Size", min: 0pt, max: 40pt, default: 12pt)
                note = Input("Note", default: "start")
            }
            style live { .font(options.size).tooltip(options.note, title: options.size).voiceOver(options.note) }
            widget {
                variable count = 1
                computed report = "{options.note}:{count}"
                Text(report).size(80, 40).style(live)
                    .onLoad { count = 2 }
                    .onClick { options.note = "accepted"; options.size = 18pt; count = count + 1; copy(report) }
            }
            """#
        let (_, program) = try F.compile(t, source)
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: F.environment(), dateInput: F.date(), measure: F.measure)
        t.equal(F.texts(first).map(\.text), ["start:2"])
        do {
            _ = try runtime.updateOptions(F.input(runtime, ["size": .number(ProgramNumber(0, dimension: .length))]),
                expectedRevision: 0, environment: F.environment(), dateInput: F.date(), measure: F.measure)
            t.check(false, "a valid option range does not make a zero native font valid")
        } catch let error as ProgramRuntimeError { t.equal(error, .invalidText(program.root.id)) }
        t.equal(runtime.generation, first.generation); t.equal(runtime.optionsRevision, 0)
        t.equal(runtime.optionValues.values["size"], .number(ProgramNumber(12, dimension: .length)))
        do {
            _ = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
                environment: F.environment(), dateInput: F.date(), measure: { _, _, _ in SkinSize(width: -1, height: 12) })
            t.check(false, "measurement failure cannot publish preceding option assignments or a copy effect")
        } catch let error as ProgramRuntimeError { t.equal(error, .invalidMeasurement(program.root.id)) }
        t.equal(runtime.generation, first.generation); t.equal(runtime.optionsRevision, 0)
        t.equal(runtime.optionValues.values["note"], .string("start"))
        let unchanged = try runtime.project(environment: F.environment(), dateInput: F.date(), measure: F.measure)
        t.equal(F.texts(unchanged).map(\.text), ["start:2"])
        t.equal(unchanged.elements.first?.accessibilityLabel, "start")
        let accepted = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: unchanged.generation,
            environment: F.environment(), dateInput: F.date(), measure: F.measure)
        t.equal(accepted?.effects, [.copy("accepted:3")])
        t.equal(accepted.map { F.texts($0.scene).map(\.text) }, ["accepted:3"])
        t.equal(accepted?.scene.elements.first?.accessibilityLabel, "accepted")
        t.equal(accepted?.scene.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "accepted", title: "18"))
        t.equal(accepted.map { F.texts($0.scene).map { TextStyle.pixelSize(points: $0.style.fontSize) } }, [18])
        t.equal(runtime.optionsRevision, 1)
    }

    t.suite("Desk: dynamic styles: overridden live expressions require authentic receipts and share expansion budgets") {
        let source = ##"""
            options { size = Stepper("Size", min: 8pt, max: 40pt, default: 12pt); hide = Toggle("Hide") }
            style live {
                .font(options.size)
                .color("#FF0000", if: options.hide)
                .tooltip(cpu.usage, title: options.size)
                .voiceOver(battery.charging)
                .hidden(if: options.hide)
            }
            widget { Text("A").style(live).font(14).color("#00FF00", if: true)
                .tooltip("Own", title: "Own").voiceOver("Own").hidden() }
            """##
        let (checked, _) = try F.compile(t, source)
        guard let root = checked.root, let facts = checked.elements[root],
              let font = facts.facets["font.size"]?.first(where: { $0.level == 2 }),
              let colorIndex = facts.facets["color"]?.firstIndex(where: { $0.level == 2 }),
              let originalSymbol = checked.symbols[font.value] else { throw DynamicStyleFixtureError.receipt("losing font") }
        guard case .option(let declaration, let file) = originalSymbol else {
            throw DynamicStyleFixtureError.receipt("option identity")
        }
        t.equal(declaration, checked.options["size"]?.node); t.equal(file, checked.tree.file)
        var symbols = checked.symbols
        symbols[font.value] = .option(declaration, file: DeskFileID("Other.desk"))
        F.reject(t, F.facts(checked, symbols: symbols), "an overridden option cannot come from another file")
        symbols = checked.symbols; symbols.removeValue(forKey: font.value)
        F.reject(t, F.facts(checked, symbols: symbols), "an overridden option still requires its checked symbol")
        var types = checked.types; types[font.value] = SemType(type: .bool)
        F.reject(t, F.facts(checked, types: types), "an overridden font expression still requires its numeric type")
        var constant = checked; constant.canonicalNumericValues[font.value] = 12
        F.reject(t, constant, "a live losing option must not be frozen by a forged canonical constant")
        constant = checked; constant.numericCoercions[font.value] = .percentAsFraction
        F.reject(t, constant, "a Length option cannot acquire a forged percentage coercion")
        guard let tooltip = facts.facets["tooltip"]?.first(where: { $0.level == 2 }) else {
            throw DynamicStyleFixtureError.receipt("losing CPU tooltip")
        }
        t.equal(checked.types[tooltip.value]?.type, .percent)
        types = checked.types; types[tooltip.value] = SemType(type: .bool)
        F.reject(t, F.facts(checked, types: types), "a losing system display still requires its catalog member type")
        var elements = checked.elements
        elements[root]?.facets["color"]?[colorIndex].condition = nil
        F.reject(t, F.facts(checked, elements: elements), "a losing style condition cannot be removed")
        F.reject(t, F.facts(checked, dataUses: []), "overridden display expressions retain their data receipts")

        let (wrapped, _) = try F.compile(t,
            "style live { .font((cpu.coreCount)) }\n" + #"widget { Text("A").style(live).font(14) }"#)
        guard let wrappedRoot = wrapped.root,
              let wrappedFont = wrapped.elements[wrappedRoot]?.facets["font.size"]?.first(where: { $0.level == 2 }),
              let wrappedNode = wrapped.tree.resolve(wrappedFont.value), let paren = ParenExprSyntax(wrappedNode) else {
            throw DynamicStyleFixtureError.receipt("losing live font parentheses")
        }
        t.equal(wrapped.types[wrappedFont.value]?.type, .plainNumber)
        t.equal(wrapped.types[wrapped.tree.id(of: paren.value.node)]?.type, .plainNumber)
        t.equal(wrapped.canonicalNumericValues[wrappedFont.value], nil)
        var wrappedTypes = wrapped.types; wrappedTypes[wrappedFont.value] = SemType(type: .length)
        F.reject(t, F.facts(wrapped, types: wrappedTypes),
                 "a live Plain wrapper cannot claim the constant-only Length adoption")

        let base = "style live { .font(system.dark ? 18 : 12).tooltip(cpu.usage) }\n"
        let small = deskCheck(base + #"widget { Text("A").style(live) }"#)
        t.check(small.diagnostics(.error).isEmpty, deskDescribe(small))
        var catalog = DeskCatalog.current; catalog.limits.maximumTokens = 128
        let admitted = Desk.compile(small, catalog: catalog)
        t.check(admitted.program != nil && admitted.issues.isEmpty, "one dynamic style fits the reduced shared budget")
        let repeated = deskCheck(base + #"widget { Text("A")"# + String(repeating: ".style(live)", count: 80) +
            #".font(14).tooltip("Own") }"#)
        t.check(repeated.diagnostics(.error).isEmpty, deskDescribe(repeated))
        F.reject(t, repeated, catalog: catalog, kind: .resourceLimit, "overridden dynamic expansions remain bounded")
        let nested = deskCheck(#"style live { .font(((((system.dark ? 18 : 12))))) }"# + "\n" +
            #"widget { Text("A").style(live).font(14) }"#)
        t.check(nested.diagnostics(.error).isEmpty, deskDescribe(nested))
        catalog = .current; catalog.limits.maximumExpressionNesting = 2
        F.reject(t, nested, catalog: catalog, kind: .resourceLimit, "losing dynamic expression nesting is still bounded")
    }

    t.suite("Desk: dynamic styles: package constants can include a local replacement while package dynamics stay explicit") {
        let package = #"""
            package { name: "Shared" }
            style base { .font(10).color(.dim) }
            style card { .style(base).padding(2) }
            """#
        let source = #"""
            options { size = Stepper("Size", min: 8pt, max: 40pt, default: 18pt) }
            style base { .font(options.size).color(.accent) }
            widget { Text("A").style(card) }
            """#
        let (checked, program) = try F.compile(t, source, package: package)
        t.check(checked.diagnostics.contains { $0.id == .styleReplacesPackage })
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: F.environment(), measure: F.measure)
        t.equal(scene.size, SkinSize(width: 9, height: 22))
        t.equal(F.texts(scene).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [18])
        t.equal(F.texts(scene).map { $0.style.color }, [SkinAppearance.light.accentColor])
        let changed = try runtime.updateOptions(F.input(runtime, ["size": .number(ProgramNumber(20, dimension: .length))]),
            expectedRevision: 0, environment: F.environment(), measure: F.measure)
        t.equal(changed?.size, SkinSize(width: 9, height: 24))
        for modifier in [".font(system.dark ? 18 : 12)", ".hidden(if: battery.charging)",
                         ".color(.accent, if: system.dark)", ".tooltip(cpu.usage)", ".voiceOver(battery.charging)"] {
            let shared = "package { name: \"Shared\" }\nstyle remote { \(modifier) }"
            let widget = #"widget { Text("A").style(remote).font(14).color(.text).tooltip("Own").voiceOver("Own").hidden() }"#
            let (checked, package) = try F.checked(widget, package: shared)
            t.check(checked.diagnostics(.error).isEmpty, "\(modifier)\n\(deskDescribe(checked))")
            if let package { t.check(package.diagnostics(.error).isEmpty, deskDescribe(package)) }
            F.reject(t, checked, package: package, kind: .unsupported, "package dynamic source: \(modifier)")
        }
        let unsupported = [
            "style live { .font(12) }\nwidget { Text(\"A\").style(live, if: system.dark) }",
            "style live { .width(system.dark ? 30 : 20) }\nwidget { Text(\"A\").style(live) }",
            "style live { .padding((cpu.coreCount)) }\nwidget { Text(\"A\").style(live) }",
            "style live { .font(12, system.dark ? Weight.bold : Weight.regular) }\nwidget { Text(\"A\").style(live) }",
            "style live { .hover { .color(.accent) } }\nwidget { Text(\"A\").style(live) }",
            "style live { .background(.glass, if: system.dark) }\nwidget { Text(\"A\").style(live) }"
        ]
        for source in unsupported {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
            F.reject(t, checked, kind: .unsupported, source)
        }
    }
}
