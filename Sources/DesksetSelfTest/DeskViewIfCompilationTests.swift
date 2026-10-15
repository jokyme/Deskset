import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum DeskViewIfFixtureError: Error { case program, structure, receipt }

private func viewIfCompilation(_ t: TestRunner, _ source: String, context: CheckContext = CheckContext()) throws -> (CheckedFile, DeskCompilationResult, WidgetProgram) {
    let checked = deskCheck(source, context: context)
    let result = Desk.compile(checked, catalog: context.catalog)
    t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked, catalog: context.catalog))")
    t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
    t.equal(result.diagnostics, checked.diagnostics)
    guard let program = result.program else { throw DeskViewIfFixtureError.program }
    return (checked, result, program)
}

private func viewIfEnvironment() -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1,
        appearance: AppearanceStamp(value: .light, name: "light"), imageGeneration: 0)
}

private func viewIfDate(_ seconds: Double = 0) -> ProgramDateInput {
    ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!,
                     locale: Locale(identifier: "en_US"))
}

private func viewIfMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    SkinSize(width: 10, height: 10)
}

private func viewIfDraws(_ scene: WidgetScene) -> [TextDraw] {
    scene.drawingItems.compactMap { if case .text(let draw) = $0 { return draw }; return nil }
}

private func viewIfFacts(_ checked: CheckedFile, symbols: [NodeID: Symbol]? = nil,
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

func runDeskViewIfCompilationTests(_ t: TestRunner) {
    t.suite("Desk: view if compilation: a lone if uses an implicit Column and real source refs for every branch") {
        let source = #"widget { if battery.present { Text("Battery").size(20, 10); Text("Charge").size(20, 10) } else { Text("No Battery").size(30, 12) } }"#
        let (checked, result, program) = try viewIfCompilation(t, source)
        guard case .column(let spacing, let align, let children) = program.root.content, children.count == 1,
              case .conditional(let conditional) = children[0].content else { throw DeskViewIfFixtureError.structure }
        t.equal(checked.root, nil); t.equal(spacing, 8); t.equal(align, .center)
        t.equal(conditional.branches.count, 1); t.equal(conditional.branches[0].condition, .systemProperty(.batteryPresent))
        t.equal(conditional.branches[0].body.count, 2); t.equal(conditional.otherwise.count, 1)
        t.equal(result.elementRefs.count, 3); t.equal(Set(result.elementRefs.values), Set(checked.elements.keys))
        t.equal(result.elementRefs[program.root.id], nil); t.equal(result.elementRefs[children[0].id], nil)
        for ref in result.elementRefs.values { t.equal(checked.tree.resolve(ref)?.kind, .callStmt) }
        var runtime = try ProgramRuntime(program: program)
        let present = try runtime.project(environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryPresent: true), measure: viewIfMeasure)
        t.equal(present.size, SkinSize(width: 20, height: 28)); t.equal(viewIfDraws(present).map(\.text), ["Battery", "Charge"])
        t.equal(present.elements.map(\.id.index), [0, 2, 3])
        t.check(checked.elements.values.allSatisfy { $0.parent == nil && $0.insideIf }, "branch calls retain the implicit root's source parent")
        let absent = try runtime.project(environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryPresent: false), measure: viewIfMeasure)
        t.equal(absent.size, SkinSize(width: 30, height: 12)); t.equal(viewIfDraws(absent).map(\.text), ["No Battery"])
        t.equal(absent.elements.map(\.id.index), [0, 4]); t.check(!absent.elements.contains { $0.id == children[0].id })
        let reparsed = deskCheck(source)
        for ref in result.elementRefs.values { t.check(reparsed.tree.resolve(ref) == nil, "same-text reparse does not qualify an old reference") }
    }

    t.suite("Desk: view if compilation: selected branch statements splice into Row and Column without extra spacing") {
        for component in ["Row", "Column"] {
            let align = component == "Row" ? "top" : "left"
            let source = "widget { \(component)(spacing: 3, align: .\(align)) { Text(\"A\").size(10); if battery.present { Text(\"B\").size(20); Text(\"C\").size(30) } else { Text(\"D\").size(40) }; Text(\"E\").size(50) } }"
            let (checked, result, program) = try viewIfCompilation(t, source)
            t.equal(result.elementRefs.count, 6)
            t.check(checked.root != nil)
            t.check(checked.elements.filter { $0.key != checked.root }.values.allSatisfy { $0.parent == checked.root },
                    "branch calls and siblings retain the real stack's source parent")
            var runtime = try ProgramRuntime(program: program)
            for (present, labels, indices, coordinates, length) in [
                (true, ["A", "B", "C", "E"], [0, 1, 3, 4, 6], [0.0, 13, 36, 69], 119.0),
                (false, ["A", "D", "E"], [0, 1, 5, 6], [0.0, 13, 56], 106.0)] {
                let scene = try runtime.project(environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryPresent: present), measure: viewIfMeasure)
                t.equal(viewIfDraws(scene).map(\.text), labels); t.equal(scene.elements.map(\.id.index), indices)
                t.equal(scene.size, component == "Row" ? SkinSize(width: length, height: 50) : SkinSize(width: 50, height: length))
                let actual = scene.elements.dropFirst().map { component == "Row" ? $0.frame.x : $0.frame.y }
                t.equal(actual, coordinates)
                t.equal(scene.elements.count, indices.count, "control flow adds no scene element")
            }
        }
    }

    t.suite("Desk: view if compilation: ordered else if nested conditions and missing use existing Bool semantics") {
        let source = #"widget { if cpu.usage < 20% { Text("Low") } else if battery.charging { if battery.pluggedIn { Text("Charging") } else { Text("Starting") } } else { Text("Other") } }"#
        let (_, _, program) = try viewIfCompilation(t, source)
        guard case .column(_, _, let children) = program.root.content, case .conditional(let outer)? = children.first?.content else {
            throw DeskViewIfFixtureError.structure
        }
        t.equal(outer.branches.count, 2)
        var runtime = try ProgramRuntime(program: program)
        t.equal(runtime.neededSystemProperties, [.cpuUsage, .batteryCharging, .batteryPluggedIn], "the existing demand API remains a conservative union")
        for (input, label) in [
            (ProgramSystemInput(cpuUsage: 10, batteryCharging: true, batteryPluggedIn: true), "Low"),
            (ProgramSystemInput(batteryCharging: true, batteryPluggedIn: true), "Charging"),
            (ProgramSystemInput(cpuUsage: 80, batteryCharging: true, batteryPluggedIn: false), "Starting"),
            (ProgramSystemInput(batteryCharging: false), "Other")] {
            let scene = try runtime.project(environment: viewIfEnvironment(), dateInput: viewIfDate(), systemInput: input, measure: viewIfMeasure)
            t.equal(viewIfDraws(scene).map(\.text), [label]); t.equal(runtime.clockPrecision, .second)
        }
        var negated = try ProgramRuntime(program: viewIfCompilation(t,
            #"widget { if not (cpu.usage >= 20%) { Text("Low") } else { Text("Missing") } }"#).2)
        t.equal(viewIfDraws(try negated.project(environment: viewIfEnvironment(), systemInput: ProgramSystemInput(), measure: viewIfMeasure)).map(\.text), ["Missing"])
        var empty = try ProgramRuntime(program: viewIfCompilation(t,
            #"widget { if battery.present { Text("Battery") } }"#).2)
        let absent = try empty.project(environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryPresent: false), measure: viewIfMeasure)
        t.equal(absent.size, SkinSize()); t.equal(absent.elements.count, 1); t.check(absent.drawingItems.isEmpty && absent.hitMap.entries.isEmpty)
        let restored = try empty.project(environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryPresent: true), measure: viewIfMeasure)
        t.equal(viewIfDraws(restored).map(\.text), ["Battery"]); t.equal(restored.size, SkinSize(width: 10, height: 10))
        var timed = try ProgramRuntime(program: viewIfCompilation(t,
            #"widget { variable began = time.now; if time.now - began < 10s { Text("Before") } else { Text("After") } }"#).2)
        t.equal(viewIfDraws(try timed.project(environment: viewIfEnvironment(), dateInput: viewIfDate(), measure: viewIfMeasure)).map(\.text), ["Before"])
        t.equal(viewIfDraws(try timed.project(environment: viewIfEnvironment(), dateInput: viewIfDate(10), measure: viewIfMeasure)).map(\.text), ["After"])
        t.equal(timed.clockPrecision, .second)
    }

    t.suite("Desk: view if compilation: preset belongs to the implicit root and Freeform keeps real parent placement") {
        let source = #"info { size: .small }"# + "\n" + #"widget { if battery.present { Rectangle().width(20, min: 14, max: 30).height(10) } else { Text("Notice").size(30, 12) } }"#
        let (checked, _, program) = try viewIfCompilation(t, source)
        guard case .column(_, _, let children) = program.root.content, case .conditional(let conditional)? = children.first?.content,
              let rectangle = conditional.branches.first?.body.first else { throw DeskViewIfFixtureError.structure }
        t.equal(program.root.width, .fit); t.equal(rectangle.width, .fixed(20)); t.equal(rectangle.minWidth, 14); t.equal(rectangle.maxWidth, 30)
        t.check(checked.elements.values.allSatisfy { !$0.isRoot }, "the implicit root has no fabricated checked call")
        var runtime = try ProgramRuntime(program: program)
        for present in [false, true] {
            let scene = try runtime.project(environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryPresent: present), measure: viewIfMeasure)
            t.equal(scene.size, SkinSize(width: 170, height: 170)); t.equal(scene.elements.count, 2)
            let frame = scene.elements[1].frame
            t.equal(SkinSize(width: frame.width, height: frame.height), present ? SkinSize(width: 20, height: 10) : SkinSize(width: 30, height: 12))
        }
        let positioned = ##"widget { Freeform { Rectangle().size(4).position(x: 0, y: 0); if battery.present { Rectangle().size(8, 6).position(x: 10, y: 12, anchor: .center) } else { Text("Notice").size(16, 10).position(x: 20, y: 15) } }.size(50).padding(2).color("#010203") }"##
        let (facts, _, placed) = try viewIfCompilation(t, positioned)
        var freeform = try ProgramRuntime(program: placed)
        for (present, expected) in [(true, SkinRect(x: 8, y: 11, width: 8, height: 6)), (false, SkinRect(x: 22, y: 17, width: 16, height: 10))] {
            let scene = try freeform.project(environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryPresent: present), measure: viewIfMeasure)
            t.equal(scene.size, SkinSize(width: 50, height: 50)); t.equal(scene.elements.last?.frame, expected)
            t.equal(scene.elements.count, 3, "the Freeform has only its real root, sibling and selected branch leaf")
            t.check(facts.elements.values.filter { $0.insideIf }.allSatisfy { $0.parent == facts.root })
            if !present { t.equal(viewIfDraws(scene).first?.style.color, RGBA(r: 1, g: 2, b: 3)) }
        }
    }

    t.suite("Desk: view if compilation: inherited colors and shared session declarations survive branch changes transactionally") {
        let source = ##"widget { variable page = 0; computed next = page > 0; Column(spacing: 0) { if next { Text("Second").size(20).color("#0000FF").voiceOver("New").onClick { page = 0; copy(page) } } else { Text("First").size(20).voiceOver("Old").onClick { page = 1; copy(page) } } }.color("#00FF00").color("#FF0000", if: battery.charging) }"##
        let (_, _, program) = try viewIfCompilation(t, source)
        t.equal(program.declarations.map(\.name), ["page", "next"])
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryCharging: true), measure: viewIfMeasure)
        t.equal(viewIfDraws(first).map(\.text), ["First"]); t.equal(viewIfDraws(first).first?.style.color, RGBA(r: 255, g: 0, b: 0))
        t.equal(first.elements.last?.accessibilityLabel, "Old")
        do {
            _ = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
                environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryCharging: true), measure: { _, _, _ in SkinSize(width: -1, height: 10) })
            t.check(false, "invalid selected-branch measurement must roll back assignment and effects")
        } catch let error as ProgramRuntimeError {
            guard case .invalidMeasurement = error else { throw error }
        }
        t.equal(runtime.generation, first.generation)
        let advanced = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryCharging: true), measure: viewIfMeasure)
        guard let scene = advanced?.scene else { throw DeskViewIfFixtureError.structure }
        t.equal(advanced?.effects, [.copy("1")]); t.equal(viewIfDraws(scene).map(\.text), ["Second"])
        t.equal(viewIfDraws(scene).first?.style.color, RGBA(r: 0, g: 0, b: 255))
        t.equal(scene.elements.last?.accessibilityLabel, "New")
        t.check(scene.elements.last?.id != first.elements.last?.id)
        t.check(try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: viewIfEnvironment(), measure: viewIfMeasure) == nil, "the old branch presentation remains stale")
        let returned = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: scene.generation,
            environment: viewIfEnvironment(), systemInput: ProgramSystemInput(batteryCharging: false), measure: viewIfMeasure)
        guard let returnedScene = returned?.scene else { throw DeskViewIfFixtureError.structure }
        t.equal(returned?.effects, [.copy("0")]); t.equal(returned?.scene.elements.last?.id, first.elements.last?.id)
        t.equal(viewIfDraws(returnedScene).first?.style.color, RGBA(r: 0, g: 255, b: 0))
    }

    t.suite("Desk: view if compilation: inactive image demands and source identities remain fully checked") {
        let source = #"widget { if battery.present { Image("A.png").size(10) } else if battery.charging { Image("B.png").size(12) } else { Text("Notice") } }"#
        let empty = CheckContext(resources: PackageResources(package: DeskPackage()))
        let missing = deskCheck(source, context: empty), demand = Desk.compile(missing)
        t.check(demand.program == nil && demand.elementRefs.isEmpty && demand.issues.isEmpty)
        t.equal(demand.imageSources, ["A.png", "B.png"]); t.equal(demand.diagnostics, missing.diagnostics)
        t.equal(missing.diagnostics.filter { $0.id == .fileNotFound && $0.severity == .error }.count, 2)
        let package = DeskPackage(files: ["A.png", "B.png"].map {
            DeskPackageFile(path: $0, kind: .image, size: 10, pixelSize: DeskPixelSize(width: 8, height: 12))
        }, texts: [missing.tree.file: source], isSingleFile: true)
        let (checked, ready, program) = try viewIfCompilation(t, source, context: CheckContext(resources: PackageResources(package: package)))
        t.equal(ready.imageSources, ["A.png", "B.png"]); t.equal(Set(ready.elementRefs.values), Set(checked.elements.keys))
        t.equal(ready.elementRefs.count, 3)
        let images = Dictionary(uniqueKeysWithValues: ["A.png", "B.png"].map { name in
            (name, ProgramImageResource(path: name, naturalSize: SkinSize(width: 8, height: 12),
                stamp: ImageStamp(seconds: 1, nanoseconds: 2, size: 3, inode: 4)))
        })
        var runtime = try ProgramRuntime(program: program)
        let notice = try runtime.project(environment: viewIfEnvironment(), images: images,
            systemInput: ProgramSystemInput(batteryCharging: false, batteryPresent: false), measure: viewIfMeasure)
        t.equal(viewIfDraws(notice).map(\.text), ["Notice"])
        t.check(notice.elements.allSatisfy { $0.imageDependencies.isEmpty })
        let image = try runtime.project(environment: viewIfEnvironment(), images: images,
            systemInput: ProgramSystemInput(batteryPresent: true), measure: viewIfMeasure)
        t.equal(image.elements.last?.imageDependencies.map(\.path), ["A.png"])
    }

    t.suite("Desk: view if compilation: the original inactive styled branch compiles before activation") {
        let source = #"widget { if false { Text("A").style(alert) } else { Text("B") } }"# + "\n" + #"style alert { .color(.red) }"#
        let (checked, result, program) = try viewIfCompilation(t, source)
        guard case .column(_, _, let children) = program.root.content, children.count == 1,
              case .conditional(let conditional) = children[0].content,
              conditional.branches.count == 1, conditional.branches[0].body.count == 1,
              conditional.otherwise.count == 1,
              case .text(let styled) = conditional.branches[0].body[0].content,
              case .text(let fallback) = conditional.otherwise[0].content else { throw DeskViewIfFixtureError.structure }
        t.equal(conditional.branches[0].condition, .boolean(false))
        t.equal(styled.value, .string("A")); t.equal(styled.color, .palette(.red))
        t.equal(fallback.value, .string("B"))
        t.equal(result.elementRefs.count, 2); t.equal(Set(result.elementRefs.values), Set(checked.elements.keys))
        var runtime = try ProgramRuntime(program: program)
        let inactive = try runtime.project(environment: viewIfEnvironment(), measure: viewIfMeasure)
        t.equal(viewIfDraws(inactive).map(\.text), ["B"])
        t.check(!inactive.elements.contains { $0.id == conditional.branches[0].body[0].id })
        let (_, activeResult, activeProgram) = try viewIfCompilation(t, source.replacingOccurrences(of: "if false", with: "if true"))
        t.equal(Set(activeResult.elementRefs.keys), Set(result.elementRefs.keys))
        let red = RGBA(r: 220, g: 32, b: 48)
        let palette = ProgramColorInput(colors: Dictionary(uniqueKeysWithValues: ProgramPaletteColor.allCases.map {
            ($0, $0 == .red ? red : SkinAppearance.light.labelColor)
        }))
        var activeRuntime = try ProgramRuntime(program: activeProgram)
        let active = try activeRuntime.project(environment: viewIfEnvironment(), colorInput: palette, measure: viewIfMeasure)
        t.equal(viewIfDraws(active).map(\.text), ["A"])
        t.equal(viewIfDraws(active).first?.style.color, red)
        t.check(!active.elements.contains { $0.id == conditional.otherwise[0].id })
    }

    t.suite("Desk: view if compilation: inactive backgrounds remain valid in both checked branches") {
        let source = #"widget { if true { Text("A") } else { Text("B").background(.glass, if: false) } }"#
        let reference = #"widget { if true { Text("A") } else { Text("B") } }"#
        for firstBranch in [true, false] {
            let condition = firstBranch ? "if true" : "if false"
            let (_, _, program) = try viewIfCompilation(t, source.replacingOccurrences(of: "if true", with: condition))
            let (_, _, expected) = try viewIfCompilation(t, reference.replacingOccurrences(of: "if true", with: condition))
            var runtime = try ProgramRuntime(program: program)
            var referenceRuntime = try ProgramRuntime(program: expected)
            let scene = try runtime.project(environment: viewIfEnvironment(), measure: viewIfMeasure)
            t.equal(scene, try referenceRuntime.project(environment: viewIfEnvironment(), measure: viewIfMeasure))
            t.equal(viewIfDraws(scene).map(\.text), [firstBranch ? "A" : "B"])
            t.check(scene.elements.allSatisfy { $0.glass == nil })
        }
    }

    t.suite("Desk: view if compilation: unsupported constructs in every branch preserve the explicit boundary") {
        for source in [
            #"widget { variable page = 0; if false { Text("A").onLoad { page = 1 } } else { Text("B") } }"#,
            #"widget { if false { Text("A").hover { .color(.red) } } else { Text("B") } }"#,
            #"widget { if false { for n in [1, 2] { Text(n) } } else { Text("B") } }"#,
            #"widget { if network.online { Text("A") } else { Text("B") } }"#,
            #"widget { if widget.size == .small { Text("A") } else { Text("B") } }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
            t.equal(result.issues.first?.kind, .unsupported, "\(source)\n\(result.issues)")
            if source.contains("network.online"), let issue = result.issues.first {
                t.equal(String(decoding: Array(source.utf16)[issue.range], as: UTF16.self), "network.online",
                        "a legal Bool source reaches the unsupported condition itself")
            }
            t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty)
            t.equal(result.diagnostics, checked.diagnostics)
        }
        let (_, _, mounted) = try viewIfCompilation(t,
            #"widget { variable page = 0; Column { if page == 1 { Text("Ready") } }.onLoad { page = 1 } }"#)
        var runtime = try ProgramRuntime(program: mounted)
        t.equal(viewIfDraws(try runtime.project(environment: viewIfEnvironment(), measure: viewIfMeasure)).map(\.text), ["Ready"], "existing root startup remains supported")
        for source in [#"widget { if true { variable page = 1; Text(page) } }"#,
                       #"widget { if true { Text("A") }.padding(4) }"#,
                       #"widget { if 1 { Text("A") } else { Text("B") } }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(!checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil && result.issues.isEmpty); t.equal(result.diagnostics, checked.diagnostics)
        }
    }

    t.suite("Desk: view if compilation: invalid checked control receipts and all-branch budgets reject without partial maps") {
        let checked = deskCheck(#"widget { if battery.present { Text("A") } else if battery.charging { Text("B") } else { Text("C") } }"#)
        guard let widget = checked.tree.rootNode.childNodes.first(where: { $0.kind == .widgetBlock }),
              let block = widget.firstChild(.block), let statement = block.childNodes.first,
              let syntax = IfStmtSyntax(statement), let anyFacts = checked.elements.values.first else { throw DeskViewIfFixtureError.receipt }
        let condition = checked.tree.id(of: syntax.condition.node), control = checked.tree.id(of: statement)
        var types = checked.types; types[condition] = SemType(type: .plainNumber)
        var elements = checked.elements; elements[control] = anyFacts
        var symbols = checked.symbols; symbols[condition] = .builtIn(.member(namespace: "cpu", name: "usage"))
        for value in [viewIfFacts(checked, types: types), viewIfFacts(checked, elements: elements),
                      viewIfFacts(checked, symbols: symbols), viewIfFacts(checked, dataUses: [])] {
            let result = Desk.compile(value)
            t.check(result.program == nil && !result.issues.isEmpty && result.elementRefs.isEmpty)
            t.equal(result.diagnostics, checked.diagnostics)
        }
        for (nodes, depth, expressions) in [(4, 100, 1000), (100, 2, 1000), (100, 100, 3)] {
            var catalog = DeskCatalog.current
            catalog.limits.maximumElementInstances = nodes; catalog.limits.maximumBlockNesting = depth
            catalog.limits.maximumTokens = expressions
            let result = Desk.compile(checked, catalog: catalog)
            t.equal(result.issues.first?.kind, .resourceLimit, "\(result.issues)")
            t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty)
        }
    }
}
