import Foundation
@testable import DesksetCore
@testable import DeskLanguage

enum DeskBatteryDetailsCompilationTests {
    private enum FixtureError: Error { case program, receipt }

    private static func compile(_ t: TestRunner, _ source: String) -> DeskCompilationResult {
        let checked = deskCheck(source, file: "BatteryDetails.desk")
        t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
        let result = Desk.compile(checked)
        t.equal(result.diagnostics, checked.diagnostics)
        t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
        t.check(result.program != nil, "Battery details must publish a complete checked program: \(source)")
        t.check(result.imageSources.isEmpty)
        return result
    }

    private static func program(_ t: TestRunner, _ source: String) throws -> WidgetProgram {
        guard let program = compile(t, source).program else { throw FixtureError.program }
        return program
    }

    private static func environment() -> EnvironmentStamp {
        EnvironmentStamp(scale: 1, fontGeneration: 1,
            appearance: AppearanceStamp(value: .light, name: "light"), imageGeneration: 0)
    }

    private static func date(_ locale: String = "en_US") -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!,
                         locale: Locale(identifier: locale))
    }

    private static func measure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
        SkinSize(width: 20, height: 12)
    }

    private static func strings(_ scene: WidgetScene) -> [String] {
        scene.drawingItems.compactMap { if case .text(let value) = $0 { return value.text }; return nil }
    }

    private static func facts(_ checked: CheckedFile, symbols: [NodeID: Symbol]? = nil,
                              types: [NodeID: SemType]? = nil, dataUses: [DataUse]? = nil) -> CheckedFile {
        var value = CheckedFile(tree: checked.tree, diagnostics: checked.diagnostics,
            symbols: symbols ?? checked.symbols, types: types ?? checked.types, elements: checked.elements,
            dataUses: dataUses ?? checked.dataUses, dependencies: checked.dependencies, reactions: checked.reactions,
            freeformOrders: checked.freeformOrders, stringTable: checked.stringTable, requirements: checked.requirements,
            options: checked.options, styles: checked.styles, translations: checked.translations, root: checked.root)
        value.loopIdentities = checked.loopIdentities; value.assets = checked.assets
        value.declarationTypes = checked.declarationTypes
        value.canonicalNumericValues = checked.canonicalNumericValues; value.numericCoercions = checked.numericCoercions
        return value
    }

    private static func denied(_ t: TestRunner, _ checked: CheckedFile, catalog: DeskCatalog = .current,
                               kind: DeskCompilationIssue.Kind) {
        let result = Desk.compile(checked, catalog: catalog)
        t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty, "\(result.issues)")
        t.equal(result.diagnostics, checked.diagnostics)
        t.equal(result.issues.first?.kind, kind)
    }

    static func run(_ t: TestRunner) {
        t.suite("Desk: battery details compilation: health and cycles display compile together") {
            let result = compile(t, #"widget { Column { Text("{battery.health}%"); Text(battery.cycles) } }"#)
            if let program = result.program {
                t.equal(result.elementRefs.count, 3)
                t.equal(Set(programProperties(program)), ["battery.health", "battery.cycles"])
                var runtime = try ProgramRuntime(program: program)
                let first = try runtime.project(environment: environment(), dateInput: date(),
                    systemInput: ProgramSystemInput(batteryHealth: 94, batteryCycles: 231), measure: measure)
                t.equal(strings(first), ["94%", "231"])
                t.equal(runtime.clockPrecision, .hour)
                let missing = try runtime.project(environment: environment(), dateInput: date(),
                    systemInput: ProgramSystemInput(), measure: measure)
                t.equal(strings(missing), ["–%", "–"])
                let recovered = try runtime.project(environment: environment(), dateInput: date(),
                    systemInput: ProgramSystemInput(batteryHealth: 100, batteryCycles: 0), measure: measure)
                t.equal(strings(recovered), ["100%", "0"])
                t.equal([first.generation, missing.generation, recovered.generation], [1, 2, 3])
                t.equal(runtime.clockPrecision, .hour)
                let observed = try runtime.project(environment: environment(), dateInput: date(),
                    systemInput: ProgramSystemInput(batteryHealth: -1, batteryCycles: 231.5), measure: measure)
                t.equal(strings(observed), ["–%", "231.5"], "cycles retain the catalog's observed numeric range")
            }
        }

        t.suite("Desk: battery details compilation: tooltip and accessibility share supported scalar displays") {
            let result = compile(t, #"widget { Text("A").tooltip(battery.health, title: battery.cycles).voiceOver(battery.health) }"#)
            if let program = result.program {
                t.equal(result.elementRefs.count, 1)
                t.check(program.root.tooltip != nil && program.root.voiceOver != nil)
                t.equal(Set(programProperties(program)), ["battery.health", "battery.cycles"])
                for locale in ["en_US", "zh_CN"] {
                    var runtime = try ProgramRuntime(program: program)
                    let scene = try runtime.project(environment: environment(), dateInput: date(locale),
                        systemInput: ProgramSystemInput(batteryHealth: 94, batteryCycles: 231), measure: measure)
                    t.equal(scene.elements.first?.accessibilityLabel, "94")
                    t.equal(scene.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "94", title: "231"))
                    t.equal(runtime.clockPrecision, .hour)
                    let missing = try runtime.project(environment: environment(), dateInput: date(locale),
                        systemInput: ProgramSystemInput(batteryHealth: .infinity, batteryCycles: -1), measure: measure)
                    t.equal(missing.elements.first?.accessibilityLabel, "–")
                    t.equal(missing.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: "–", title: "–"))
                }
            }
        }

        t.suite("Desk: battery details compilation: menu titles and copy actions retain live data reads") {
            let result = compile(t, #"widget { Text("Details").menu { Item(battery.health).onClick { copy(battery.cycles) } } }"#)
            if let program = result.program {
                t.equal(result.elementRefs.count, 1, "Menu entries never become source view references")
                t.equal(program.root.menu?.count, 1)
                var runtime = try ProgramRuntime(program: program)
                let scene = try runtime.project(environment: environment(), measure: measure)
                t.equal(runtime.neededSystemProperties, [])
                t.equal(runtime.neededSystemProperties(openingMenu: program.root.id), [.batteryHealth])
                let menu = try runtime.resolveMenu(program.root.id, expectedGeneration: scene.generation,
                    environment: environment(), dateInput: date(), systemInput: ProgramSystemInput(batteryHealth: 94))
                guard case .item(let item, let title, _, _)? = menu?.items.first else { throw FixtureError.receipt }
                t.equal(title, "94")
                t.equal(runtime.neededSystemProperties(activatingMenuItem: item), [.batteryCycles])
                let clicked = try runtime.activateMenuItemWithEffects(item, expectedGeneration: scene.generation,
                    environment: environment(), dateInput: date(), systemInput: ProgramSystemInput(batteryCycles: 231), measure: measure)
                t.equal(clicked?.effects, [.copy("231")])
                t.equal(runtime.clockPrecision, nil, "on-demand menu reads do not retain an hourly display timer")
                let missing = try runtime.resolveMenu(program.root.id, expectedGeneration: runtime.generation,
                    environment: environment(), dateInput: date(), systemInput: ProgramSystemInput())
                guard case .item(_, let missingTitle, _, _)? = missing?.items.first else { throw FixtureError.receipt }
                t.equal(missingTitle, "–")
            }
        }

        t.suite("Desk: battery details compilation: stored assignments copy once without retaining live polling") {
            let source = #"widget { variable captured = 0%; Text(captured).onClick { captured = battery.health; copy(captured); copy(battery.cycles) } }"#
            var runtime = try ProgramRuntime(program: program(t, source))
            let first = try runtime.project(environment: environment(), dateInput: date(), measure: measure)
            t.equal(strings(first), ["0"]); t.equal(runtime.neededSystemProperties, [])
            t.equal(runtime.neededSystemProperties(clickAt: SkinPoint(x: 1, y: 1)), [.batteryHealth, .batteryCycles])
            let clicked = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
                environment: environment(), dateInput: date(),
                systemInput: ProgramSystemInput(batteryHealth: 94, batteryCycles: 231), measure: measure)
            t.equal(clicked?.effects, [.copy("94"), .copy("231")])
            t.equal(clicked.map { strings($0.scene) }, ["94"])
            t.equal(runtime.clockPrecision, nil)
            t.equal(strings(try runtime.project(environment: environment(), dateInput: date(),
                systemInput: ProgramSystemInput(batteryHealth: 80, batteryCycles: 300), measure: measure)), ["94"])
        }

        t.suite("Desk: battery details compilation: exact native catalog contracts reject drift and legacy plugin lowering") {
            guard let namespace = DeskCatalog.current.namespaces.firstIndex(where: { $0.name == "battery" }) else { throw FixtureError.receipt }
            for name in ["health", "cycles"] {
                let checked = deskCheck("widget { Text(battery.\(name)) }")
                t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
                guard let index = DeskCatalog.current.namespaces[namespace].members.firstIndex(where: { $0.name == name }) else { throw FixtureError.receipt }
                let changes: [(String, (inout MemberSpec) -> Void)] = [
                    ("type", { $0.type = .bool }),
                    ("range", { $0.range = name == "health" ? .observed : .fixed(0...100) }),
                    ("base", { $0.displayBase = 1000 }), ("format", { $0.defaultFormat = .style(".short") }),
                    ("cadence", { $0.cadence = .periodic(seconds: 60) }), ("sync", { $0.readsSynchronously = true }),
                    ("permission", { $0.permission = "music" }), ("settable", { $0.settable = true }),
                    ("twin", { $0.settableTwin = "battery.level" }), ("user-only", { $0.userInitiatedOnly = true }),
                    ("signature", { $0.signatures = [Signature(params: [])] }),
                    ("native field", { $0.lowering = CatalogData.nativeKernel("battery", field: "level") }),
                    ("legacy plugin", { $0.lowering = CatalogData.pluginKernel("MacSensors", ["Sensor": "battery.\(name)"]) })
                ]
                for (_, change) in changes {
                    var catalog = DeskCatalog.current
                    change(&catalog.namespaces[namespace].members[index])
                    denied(t, checked, catalog: catalog, kind: .unsupported)
                }
                var catalog = DeskCatalog.current; catalog.namespaces[namespace].permission = "music"
                denied(t, checked, catalog: catalog, kind: .unsupported)
            }
        }

        t.suite("Desk: battery details compilation: leaf and transparent wrapper receipts cannot freeze live fields") {
            for name in ["health", "cycles"] {
                let checked = deskCheck("widget { Text((((battery.\(name))))) }")
                t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
                let candidates = checked.types.keys.filter { identity in
                    guard let node = checked.tree.resolve(identity) else { return false }
                    return node.kind == .memberExpr || node.kind == .parenExpr
                }
                t.equal(candidates.count, 4)
                for identity in candidates {
                    t.check(checked.canonicalNumericValues[identity] == nil && checked.numericCoercions[identity] == nil)
                    var constant = checked; constant.canonicalNumericValues[identity] = 94
                    denied(t, constant, kind: .invalidCheckedModel)
                    var converted = checked; converted.numericCoercions[identity] = .percentAsFraction
                    denied(t, converted, kind: .invalidCheckedModel)
                    var types = checked.types; types[identity] = SemType(type: .bool)
                    denied(t, facts(checked, types: types), kind: .invalidCheckedModel)
                }
                guard let leaf = candidates.first(where: { checked.tree.resolve($0)?.kind == .memberExpr }),
                      let node = checked.tree.resolve(leaf), let syntax = MemberExprSyntax(node) else { throw FixtureError.receipt }
                var symbols = checked.symbols; symbols.removeValue(forKey: leaf)
                denied(t, facts(checked, symbols: symbols), kind: .invalidCheckedModel)
                symbols = checked.symbols; symbols[checked.tree.id(of: syntax.base.node)] = .builtIn(.namespace("cpu"))
                denied(t, facts(checked, symbols: symbols), kind: .invalidCheckedModel)
                denied(t, facts(checked, dataUses: []), kind: .unsupported)
                var uses = checked.dataUses; uses[0].nodePath = "cpu"
                denied(t, facts(checked, dataUses: uses), kind: .unsupported)
            }
            let cpu = deskCheck("widget { Text(cpu.usage) }")
            guard let use = cpu.dataUses.first, let node = cpu.tree.resolve(use.reference),
                  let syntax = MemberExprSyntax(node) else { throw FixtureError.receipt }
            var symbols = cpu.symbols
            symbols[use.reference] = .builtIn(.member(namespace: "battery", name: "health"))
            symbols[cpu.tree.id(of: syntax.base.node)] = .builtIn(.namespace("battery"))
            var uses = cpu.dataUses; uses[0].nodePath = "battery"; uses[0].memberPath = "battery.health"
            denied(t, facts(cpu, symbols: symbols, dataUses: uses), kind: .invalidCheckedModel)
        }

        t.suite("Desk: battery details compilation: legitimate health fraction receipts convert once") {
            // Qualify the real expression receipt without admitting the still-unsupported opacity modifier.
            let checked = deskCheck(#"widget { Text("A").opacity((battery.health)) }"#)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.equal(Desk.compile(checked).issues.first?.kind, .unsupported)
            guard let widgetNode = checked.tree.rootNode.childNodes.first(where: { $0.kind == .widgetBlock }),
                  let widget = TopLevelBlockSyntax(widgetNode), let call = widget.block.items.compactMap(CallStmtSyntax.init).first,
                  let expression = call.modifiers.first?.arguments?.arguments.first?.value.node else { throw FixtureError.receipt }
            let identity = checked.tree.id(of: expression)
            t.equal(checked.types[identity]?.type, .plainNumber)
            t.equal(checked.numericCoercions[identity], .percentAsFraction)
            var compiler = ProgramExpressionCompiler(checked: checked, catalog: .current)
            let value = try compiler.text(expression)
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Health fraction",
                root: ProgramElement(id: ElementID(name: "fraction", index: 0), content: .text(ProgramText(value: value)))))
            t.equal(strings(try runtime.project(environment: environment(), dateInput: date(),
                systemInput: ProgramSystemInput(batteryHealth: 94), measure: measure)), ["0.94"])
            t.equal(runtime.clockPrecision, .hour)
            t.equal(strings(try runtime.project(environment: environment(), dateInput: date(),
                systemInput: ProgramSystemInput(), measure: measure)), ["–"])
        }

        t.suite("Desk: battery details compilation: hidden layout and shared expression budgets preserve existing boundaries") {
            var hidden = try ProgramRuntime(program: program(t, #"widget { Text(battery.health).voiceOver(battery.cycles).hidden() }"#))
            let scene = try hidden.project(environment: environment(), dateInput: date(),
                systemInput: ProgramSystemInput(batteryHealth: 94, batteryCycles: 231), measure: measure)
            t.check(scene.drawingItems.isEmpty && scene.elements.allSatisfy { $0.accessibilityLabel == nil })
            t.equal(hidden.neededSystemProperties, [.batteryHealth], "hidden Text retains its real layout expression")
            t.equal(hidden.clockPrecision, nil)
            let checked = deskCheck(#"widget { Text("{battery.health}|{battery.cycles}") }"#)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            var catalog = DeskCatalog.current; catalog.limits.maximumTokens = 1
            denied(t, checked, catalog: catalog, kind: .resourceLimit)
            catalog = DeskCatalog.current; catalog.limits.maximumExpressionNesting = 2
            denied(t, deskCheck("widget { Text((((battery.health)))) }"), catalog: catalog, kind: .resourceLimit)
            for source in ["widget { Text(2W) }", "widget { Text(network.online) }"] {
                let unsupported = deskCheck(source)
                t.check(unsupported.diagnostics(.error).isEmpty, deskDescribe(unsupported))
                denied(t, unsupported, kind: .unsupported)
            }
        }
    }

    private static func programProperties(_ program: WidgetProgram) -> [String] {
        (try? ProgramRuntime(program: program).neededSystemProperties.map(\.rawValue)) ?? []
    }
}

func runDeskBatteryDetailsCompilationTests(_ t: TestRunner) {
    DeskBatteryDetailsCompilationTests.run(t)
}
