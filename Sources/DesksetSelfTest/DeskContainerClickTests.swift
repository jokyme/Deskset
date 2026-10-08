import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum DeskContainerClickFixtureError: Error { case program, structure }

private func containerClickCompilation(_ t: TestRunner, _ source: String) throws -> (CheckedFile, DeskCompilationResult, WidgetProgram) {
    let checked = deskCheck(source), result = Desk.compile(checked)
    t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
    t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
    t.equal(result.diagnostics, checked.diagnostics)
    guard let program = result.program else { throw DeskContainerClickFixtureError.program }
    return (checked, result, program)
}

private func containerClickEnvironment() -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1,
        appearance: AppearanceStamp(value: .light, name: "light"), imageGeneration: 0)
}

private func containerClickMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    SkinSize(width: 10, height: 10)
}

private func containerClickStrings(_ scene: WidgetScene) -> [String] {
    scene.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.text }; return nil }
}

private func containerClickCall(_ component: String) -> String {
    switch component {
    case "Row": return "Row(spacing: 0, align: .top)"
    case "Column": return "Column(spacing: 0, align: .left)"
    default: return "Freeform(align: .topLeft)"
    }
}

private func containerClickFacts(_ checked: CheckedFile, symbols: [NodeID: Symbol]) -> CheckedFile {
    var value = CheckedFile(tree: checked.tree, diagnostics: checked.diagnostics, symbols: symbols,
        types: checked.types, elements: checked.elements, dataUses: checked.dataUses,
        dependencies: checked.dependencies, reactions: checked.reactions, freeformOrders: checked.freeformOrders,
        stringTable: checked.stringTable, requirements: checked.requirements, options: checked.options,
        styles: checked.styles, translations: checked.translations, root: checked.root)
    value.loopIdentities = checked.loopIdentities; value.assets = checked.assets
    value.declarationTypes = checked.declarationTypes
    value.canonicalNumericValues = checked.canonicalNumericValues; value.numericCoercions = checked.numericCoercions
    return value
}

func runDeskContainerClickTests(_ t: TestRunner) {
    let environment = containerClickEnvironment(), point = SkinPoint(x: 1, y: 1)

    t.suite("Desk: container clicks: former Column negatives preserve legacy assignments and right effects") {
        let primarySource = #"widget { variable x = false; Column { Text("A") }.onClick { x = true } }"#
        let (_, _, primary) = try containerClickCompilation(t, primarySource)
        t.equal(primary.root.onClick, [ProgramAssignment(declaration: 0, value: .boolean(true))])
        t.check(primary.root.onClickActions == nil && primary.root.onRightClickActions == nil)
        var left = try ProgramRuntime(program: primary)
        let initial = try left.project(environment: environment, measure: containerClickMeasure)
        t.equal(initial.hitMap.entry(at: point.x, point.y, handling: .leftUp, images: nil)?.elementID, primary.root.id)
        guard let assigned = try left.click(at: point, expectedGeneration: initial.generation,
            environment: environment, measure: containerClickMeasure) else { throw DeskContainerClickFixtureError.program }
        t.equal(assigned.generation, initial.generation + 1); t.equal(containerClickStrings(assigned), ["A"])

        let secondarySource = #"widget { Column { Text("Tap") }.onRightClick { copy("A") } }"#
        let (checked, _, secondary) = try containerClickCompilation(t, secondarySource)
        t.check(checked.diagnostics.contains { $0.id == .rootTakesOverPointer && $0.severity == .warning },
                "the root pointer warning remains useful and does not block lowering")
        t.equal(secondary.root.onRightClickActions, [.copy(.string("A"))])
        var right = try ProgramRuntime(program: secondary)
        let scene = try right.project(environment: environment, measure: containerClickMeasure)
        t.check(scene.hitMap.entry(at: point.x, point.y, handling: .leftUp, images: nil) == nil)
        t.equal(try right.clickWithEffects(at: point, expectedGeneration: scene.generation, event: .rightUp,
            environment: environment, measure: containerClickMeasure)?.effects, [.copy("A")])

        for component in ["Row", "Column", "Freeform"] {
            let source = "widget { variable n = 0; \(containerClickCall(component)) { Text(n).size(20) }.size(40, 30).name(card).onClick { n = n + 1; copy(n); open(\"https://example.com/card\") }.onRightClick { n = n + 2; copy(n) } }"
            let (_, result, program) = try containerClickCompilation(t, source)
            t.equal(result.elementRefs.count, 2)
            t.check(program.root.onClick == nil); t.equal(program.root.onClickActions?.count, 3)
            var runtime = try ProgramRuntime(program: program)
            let first = try runtime.project(environment: environment, measure: containerClickMeasure)
            guard let next = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
                environment: environment, measure: containerClickMeasure) else { throw DeskContainerClickFixtureError.program }
            t.equal(next.effects, [.copy("1"), .open("https://example.com/card")]); t.equal(containerClickStrings(next.scene), ["1"])
            let last = try runtime.clickWithEffects(at: point, expectedGeneration: next.scene.generation, event: .rightUp,
                environment: environment, measure: containerClickMeasure)
            t.equal(last?.effects, [.copy("3")]); t.equal(last.map { containerClickStrings($0.scene) }, ["3"])
        }
    }

    t.suite("Desk: container clicks: empty sized containers catch events without paint and hidden boxes do not hit") {
        for component in ["Row", "Column", "Freeform"] {
            for (name, event, other) in [("onClick", MouseEventKind.leftUp, MouseEventKind.rightUp),
                                       ("onRightClick", .rightUp, .leftUp)] {
                let source = "widget { \(component) { }.size(40, 30).name(card).\(name) { } }"
                let (_, _, program) = try containerClickCompilation(t, source)
                if event == .leftUp { t.equal(program.root.onClick, []); t.check(program.root.onClickActions == nil) }
                else { t.equal(program.root.onRightClickActions, []) }
                var runtime = try ProgramRuntime(program: program)
                let scene = try runtime.project(environment: environment, measure: containerClickMeasure)
                t.equal(scene.size, SkinSize(width: 40, height: 30)); t.check(scene.drawingItems.isEmpty)
                t.equal(scene.hitMap.entries.count, 1)
                t.equal(scene.hitMap.entry(at: point.x, point.y, handling: event, images: nil)?.action(event), .caught)
                t.check(try runtime.clickWithEffects(at: point, expectedGeneration: scene.generation, event: other,
                    environment: environment, measure: containerClickMeasure) == nil)
                let caught = try runtime.clickWithEffects(at: point, expectedGeneration: scene.generation, event: event,
                    environment: environment, measure: containerClickMeasure)
                t.check(caught != nil); t.equal(caught?.effects, []); t.equal(caught?.scene.generation, scene.generation + 1)
                t.check(try runtime.clickWithEffects(at: SkinPoint(x: 41, y: 1), expectedGeneration: runtime.generation, event: event,
                    environment: environment, measure: containerClickMeasure) == nil)
            }
            let hiddenSource = "widget { \(component) { }.size(40, 30).hidden(if: battery.charging).onClick { } }"
            var hidden = try ProgramRuntime(program: containerClickCompilation(t, hiddenSource).2)
            let absent = try hidden.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: containerClickMeasure)
            t.equal(absent.size, SkinSize(width: 40, height: 30)); t.check(absent.hitMap.entries.isEmpty)
            let shown = try hidden.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: containerClickMeasure)
            t.equal(shown.hitMap.entries.count, 1)
            let noHandler = Desk.compile(deskCheck("widget { \(component) { }.size(40, 30) }"))
            t.check(noHandler.program == nil); t.equal(noHandler.issues.first?.kind, .invalidProgram,
                "an inert empty tree keeps the original empty-program boundary")
        }
    }

    t.suite("Desk: container clicks: innermost handlers are event specific and empty children never bubble") {
        for component in ["Row", "Column", "Freeform"] {
            for catchesRight in [false, true] {
                let right = catchesRight ? ".onRightClick { }" : ""
                let source = "widget { \(containerClickCall(component)) { Column { }.size(20).name(child).onClick { }\(right) }.size(40).padding(4).rounded(8).background(.glass).name(card).onClick { copy(\"parent left\") }.onRightClick { copy(\"parent right\") } }"
                let (checked, result, program) = try containerClickCompilation(t, source)
                var runtime = try ProgramRuntime(program: program)
                let scene = try runtime.project(environment: environment, measure: containerClickMeasure)
                guard let child = scene.elements.first(where: { $0.id.name == "child" }),
                      let ref = result.elementRefs[child.id] else { throw DeskContainerClickFixtureError.structure }
                t.equal(child.frame, SkinRect(x: 4, y: 4, width: 20, height: 20))
                t.equal(checked.elements[ref]?.parent, checked.root)
                let childPoint = SkinPoint(x: 8, y: 8)
                t.equal(scene.hitMap.entry(at: childPoint.x, childPoint.y, handling: .leftUp, images: nil)?.elementID, child.id)
                let left = try runtime.clickWithEffects(at: childPoint, expectedGeneration: scene.generation,
                    environment: environment, measure: containerClickMeasure)
                t.check(left != nil); t.equal(left?.effects, [], "an empty child prevents the parent's left action")
                let secondary = try runtime.clickWithEffects(at: childPoint, expectedGeneration: runtime.generation, event: .rightUp,
                    environment: environment, measure: containerClickMeasure)
                t.equal(secondary?.effects, catchesRight ? [] : [.copy("parent right")])
                t.equal(runtime.generation, scene.generation + 2)
                let padding = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 20), expectedGeneration: runtime.generation,
                    environment: environment, measure: containerClickMeasure)
                t.equal(padding?.effects, [.copy("parent left")], "padding and glass belong to the parent box")
                t.check(try runtime.clickWithEffects(at: SkinPoint(x: 0.1, y: 0.1), expectedGeneration: runtime.generation,
                    environment: environment, measure: containerClickMeasure) == nil, "rounded corners exclude the box corner")
            }
        }
    }

    t.suite("Desk: container clicks: Freeform overlap negative coordinates and presets keep final hit geometry") {
        let source = #"widget { Freeform { Column { }.size(30, 20).position(x: -10, y: 10).name(lower).onClick { copy("lower") }; Row { }.size(30, 20).position(x: 0, y: 10).hidden(if: battery.charging).name(upper).onClick { }.onRightClick { copy("upper right") } }.size(100).name(card).onClick { copy("card") }.onRightClick { copy("card right") } }"#
        var runtime = try ProgramRuntime(program: containerClickCompilation(t, source).2)
        let first = try runtime.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: containerClickMeasure)
        t.equal(first.elements.map(\.id.name), ["card", "lower", "upper"])
        t.equal(first.elements[1].frame, SkinRect(x: -10, y: 10, width: 30, height: 20))
        let overlap = SkinPoint(x: 5, y: 15)
        t.equal(first.hitMap.entry(at: overlap.x, overlap.y, handling: .leftUp, images: nil)?.elementID, first.elements[2].id)
        t.equal(try runtime.clickWithEffects(at: overlap, expectedGeneration: runtime.generation,
            environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: containerClickMeasure)?.effects, [])
        t.equal(try runtime.clickWithEffects(at: overlap, expectedGeneration: runtime.generation, event: .rightUp,
            environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: containerClickMeasure)?.effects, [.copy("upper right")])
        t.equal(try runtime.clickWithEffects(at: SkinPoint(x: -5, y: 15), expectedGeneration: runtime.generation,
            environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: containerClickMeasure)?.effects, [.copy("lower")])
        let covered = try runtime.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: containerClickMeasure)
        t.equal(covered.hitMap.entry(at: overlap.x, overlap.y, handling: .leftUp, images: nil)?.elementID, first.elements[1].id)
        t.equal(try runtime.clickWithEffects(at: overlap, expectedGeneration: covered.generation, event: .rightUp,
            environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: containerClickMeasure)?.effects, [.copy("card right")])

        let scaled = #"info { size: .small }"# + "\n" + #"widget { Freeform { Column { }.size(340, 170).position(x: -20, y: 0).name(wide).onClick { copy("wide") } }.name(card).onClick { copy("card") } }"#
        var preset = try ProgramRuntime(program: containerClickCompilation(t, scaled).2)
        let scene = try preset.project(environment: environment, measure: containerClickMeasure)
        t.equal(scene.size, SkinSize(width: 170, height: 170)); t.equal(scene.elements[1].frame, SkinRect(x: 0, y: 0, width: 170, height: 85))
        t.equal(scene.elements[0].frame, SkinRect(x: 10, y: 0, width: 85, height: 85))
        t.equal(try preset.clickWithEffects(at: SkinPoint(x: 160, y: 40), expectedGeneration: scene.generation,
            environment: environment, measure: containerClickMeasure)?.effects, [.copy("wide")])
    }

    t.suite("Desk: container clicks: parent actions switch view branches transactionally and reject stale scenes") {
        let source = #"widget { variable page = 0; computed alternate = page > 0; Column(spacing: 0, align: .left) { if alternate { Text("Second").size(40).name(second) } else { Text("First").size(20).name(first) } }.size(60, 50).name(card).onClick { page = 1; copy(page) }.onRightClick { page = 0; copy(page) } }"#
        let (_, result, program) = try containerClickCompilation(t, source)
        t.equal(result.elementRefs.count, 3)
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: environment, measure: containerClickMeasure)
        t.equal(containerClickStrings(first), ["First"]); t.equal(first.hitMap.entries.map(\.elementID), [program.root.id])
        do {
            _ = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
                environment: environment, measure: { _, _, _ in SkinSize(width: -1, height: 10) })
            t.check(false, "invalid selected-branch measurement must roll back parent assignments and effects")
        } catch let error as ProgramRuntimeError {
            guard case .invalidMeasurement = error else { throw error }
        }
        t.equal(runtime.generation, first.generation)
        guard let next = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
            environment: environment, measure: containerClickMeasure) else { throw DeskContainerClickFixtureError.program }
        t.equal(next.effects, [.copy("1")]); t.equal(containerClickStrings(next.scene), ["Second"])
        t.equal(next.scene.elements.first?.id, program.root.id); t.check(next.scene.elements.last?.id != first.elements.last?.id)
        t.check(try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
            environment: environment, measure: containerClickMeasure) == nil)
        let restored = try runtime.clickWithEffects(at: point, expectedGeneration: next.scene.generation, event: .rightUp,
            environment: environment, measure: containerClickMeasure)
        t.equal(restored?.effects, [.copy("0")]); t.equal(restored.map { containerClickStrings($0.scene) }, ["First"])
        t.equal(restored?.scene.elements.last?.id, first.elements.last?.id)
    }

    t.suite("Desk: container clicks: exact checked event contracts and unsupported roles remain guarded") {
        let source = #"widget { Column { Text("A") }.onClick { copy("left") }.onRightClick { copy("right") } }"#
        let (checked, _, _) = try containerClickCompilation(t, source)
        let changes: [(String, (inout ModifierSpec) -> Void)] = [
            ("event", { $0.event?.runtimeEvent = "mouseOver" }),
            ("user", { $0.event?.userInitiated = false }),
            ("record", { $0.event?.eventRecord = nil }),
            ("timing", { $0.timing = .onLoad }),
            ("block", { $0.block = .actions(required: false) }),
            ("signature", { $0.signatures.append($0.signatures[0]) }),
            ("kind", { $0.appliesTo = .of(.text) })]
        for name in ["onClick", "onRightClick"] {
            guard let index = DeskCatalog.current.modifiers.firstIndex(where: { $0.name == name }),
                  let identity = checked.symbols.first(where: { $0.value == .builtIn(.modifier(name)) })?.key else {
                throw DeskContainerClickFixtureError.structure
            }
            for (label, change) in changes {
                var catalog = DeskCatalog.current
                change(&catalog.modifiers[index])
                let result = Desk.compile(checked, catalog: catalog)
                t.check(result.program == nil && result.elementRefs.isEmpty); t.equal(result.issues.first?.kind, .invalidCheckedModel, "\(name): \(label)")
                t.equal(result.diagnostics, checked.diagnostics)
            }
            for remove in [false, true] {
                var symbols = checked.symbols
                if remove { symbols.removeValue(forKey: identity) }
                else { symbols[identity] = .builtIn(.modifier("onLoad")) }
                let result = Desk.compile(containerClickFacts(checked, symbols: symbols))
                t.check(result.program == nil && result.elementRefs.isEmpty); t.equal(result.issues.first?.kind, .invalidCheckedModel)
            }
        }
        for source in [#"widget { Image("unsupported.png").onRightClick { copy("A") } }"#,
                       #"widget { Column { Text("A") }.onDoubleClick { copy("A") } }"#,
                       #"widget { variable flag = false; Column { Text("A") }.onClick { if flag { flag = true } } }"#,
                       #"widget { Column { Text("A") }.onClick { copy("{event.x}") } }"#,
                       #"widget { Column { Text("A") }.onRightClick { log("A") } }"#] {
            let result = Desk.compile(deskCheck(source))
            t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty)
            t.equal(result.issues.first?.kind, .unsupported, "\(source)\n\(result.issues)")
        }
        let spacer = deskCheck(#"widget { Spacer().onClick { } }"#)
        t.check(spacer.diagnostics.contains { $0.id == .notApplicable && $0.severity == .error })
        t.check(Desk.compile(spacer).program == nil)
    }

    t.suite("Desk: container clicks: startup parent child and inactive branch actions share one budget") {
        let source = #"widget { variable flag = false; Column { if true { Text("A").onClick { flag = true } } else { Text("B").onRightClick { flag = false } } }.onLoad { flag = true }.onClick { flag = false }.onRightClick { flag = true } }"#
        let checked = deskCheck(source)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        var catalog = DeskCatalog.current
        catalog.limits.maximumTokens = 9
        let bounded = Desk.compile(checked, catalog: catalog)
        t.check(bounded.issues.isEmpty, "\(bounded.issues)")
        guard let program = bounded.program, case .column(_, _, let children) = program.root.content,
              case .conditional(let conditional)? = children.first?.content else { throw DeskContainerClickFixtureError.structure }
        t.equal(program.onLoad.count, 1); t.equal(program.root.onClick?.count, 1); t.equal(program.root.onRightClickActions?.count, 1)
        t.equal(conditional.branches[0].body[0].onClick?.count, 1); t.equal(conditional.otherwise[0].onRightClickActions?.count, 1)
        t.equal(bounded.elementRefs.count, 3)
        catalog.limits.maximumTokens = 8
        let exceeded = Desk.compile(checked, catalog: catalog)
        t.check(exceeded.program == nil && exceeded.elementRefs.isEmpty && exceeded.imageSources.isEmpty)
        t.equal(exceeded.issues.first?.kind, .resourceLimit); t.equal(exceeded.diagnostics, checked.diagnostics)
    }

    t.suite("Desk: container clicks: action-only system demand follows the hit event without a display clock") {
        let source = #"widget { Column { }.size(40, 30).onClick { copy(cpu.usage) }.onRightClick { copy("{memory.used, unit: .mib, unitStyle: .none, decimals: 0}") } }"#
        var runtime = try ProgramRuntime(program: containerClickCompilation(t, source).2)
        let scene = try runtime.project(environment: environment, measure: containerClickMeasure)
        t.equal(runtime.neededSystemProperties, []); t.equal(runtime.clockPrecision, nil)
        t.equal(runtime.neededSystemProperties(clickAt: point), [.cpuUsage])
        t.equal(runtime.neededSystemProperties(clickAt: point, event: .rightUp), [.memoryUsed])
        t.equal(runtime.neededSystemProperties(clickAt: SkinPoint(x: 100, y: 100)), [])
        let input = ProgramSystemInput(cpuUsage: 42, memoryUsed: 2 * 1024 * 1024)
        let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US"))
        let left = try runtime.clickWithEffects(at: point, expectedGeneration: scene.generation,
            environment: environment, dateInput: date, systemInput: input, measure: containerClickMeasure)
        t.equal(left?.effects, [.copy("42")]); t.equal(runtime.clockPrecision, nil)
        let right = try runtime.clickWithEffects(at: point, expectedGeneration: runtime.generation, event: .rightUp,
            environment: environment, dateInput: date, systemInput: input, measure: containerClickMeasure)
        t.equal(right?.effects, [.copy("2")]); t.equal(runtime.clockPrecision, nil)
    }
}
