import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum DeskMenuFixtureError: Error { case program, structure }

private func menuCompilation(_ t: TestRunner, _ source: String) throws -> (CheckedFile, DeskCompilationResult, WidgetProgram) {
    let checked = deskCheck(source), result = Desk.compile(checked)
    t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
    t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
    t.equal(result.diagnostics, checked.diagnostics)
    guard let program = result.program else { throw DeskMenuFixtureError.program }
    return (checked, result, program)
}

private func menuEnvironment() -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1,
        appearance: AppearanceStamp(value: .light, name: "light"), imageGeneration: 0)
}

private func menuMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    SkinSize(width: 20, height: 12)
}

private func menuDate(_ locale: String) -> ProgramDateInput {
    ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!,
                     locale: Locale(identifier: locale))
}

private func menuFacts(_ checked: CheckedFile, symbols: [NodeID: Symbol]? = nil,
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

func runDeskMenuTests(_ t: TestRunner) {
    t.suite("Desk: menus: supported views own menu templates without geometry or source refs for entries") {
        for view in [#"Text("A")"#, #"Icon("wifi")"#, "Rectangle()", "Circle()", "Ellipse()", "Capsule()",
                     #"Image("image.png")"#, "Progress(0.25)", "Gauge(0.25)",
                     #"Column { Text("A") }"#, #"Row { Text("A") }"#, #"Freeform { Text("A") }"#] {
            let (checked, result, program) = try menuCompilation(t,
                "widget { \(view).menu { Item(\"Open\").onClick { open(\"Calendar\") }; Divider(); Menu(\"More\") { Item(\"Copy\").onClick { copy(\"Value\") } } } }")
            guard let items = program.root.menu, items.count == 3,
                  case .item(let open) = items[0], case .divider = items[1],
                  case .submenu(let title, let children) = items[2], case .item(let copy)? = children.first else {
                throw DeskMenuFixtureError.structure
            }
            t.equal(open, ProgramMenuItem(title: .string("Open"), actions: [.open(.string("Calendar"))]))
            t.equal(title, .string("More")); t.equal(copy.actions, [.copy(.string("Value"))])
            let menuRefs = Set(checked.elements.filter { [.item, .menu, .divider].contains($0.value.kind) }.keys)
            t.equal(menuRefs.count, 4)
            t.check(Set(result.elementRefs.values).isDisjoint(with: menuRefs))
            t.equal(result.elementRefs.count, checked.elements.count - menuRefs.count)
        }
        let (_, result, program) = try menuCompilation(t,
            #"widget { Column(spacing: 0) { Text("A").size(20, 12).menu { Item("Child") }; Text("B").size(20, 12) }.menu { Item("Root") } }"#)
        guard case .column(_, _, let children) = program.root.content, children.count == 2 else { throw DeskMenuFixtureError.structure }
        t.equal(program.root.menu, [.item(ProgramMenuItem(title: .string("Root")))])
        t.equal(children[0].menu, [.item(ProgramMenuItem(title: .string("Child")))])
        t.equal(children[1].menu, nil, "menu ownership is not text-style inheritance")
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: menuEnvironment(), measure: menuMeasure)
        t.equal(scene.size, SkinSize(width: 20, height: 24)); t.equal(scene.elements.count, 3)
        t.equal(result.elementRefs.count, 3)
        t.check(scene.hitMap.entries.allSatisfy { $0.actions.isEmpty }, "menus do not create pointer actions")
        var baseline = try ProgramRuntime(program: menuCompilation(t,
            #"widget { Column(spacing: 0) { Text("A").size(20, 12); Text("B").size(20, 12) } }"#).2)
        let plain = try baseline.project(environment: menuEnvironment(), measure: menuMeasure)
        t.equal(scene.elements.map(\.frame), plain.elements.map(\.frame)); t.equal(scene.drawingItems, plain.drawingItems)
    }

    t.suite("Desk: menus: display titles reuse Text VoiceOver and copy expressions while states remain Bool") {
        for expression in ["25%", "45deg", "12pt", "8GiB", "90s", "time.now", "battery.present",
                           "(battery.timeRemaining)", "battery.present ? battery.timeRemaining : 90s",
                           #"battery.present ? true : "Unavailable""#,
                           #""{battery.timeRemaining, style: .clock}""#] {
            let source = "widget { Text(\(expression)).voiceOver(\(expression)).menu { Item(\(expression), checked: battery.charging, enabled: not battery.pluggedIn).onClick { copy(\(expression)) }; Menu(\(expression)) { } } }"
            let (_, _, program) = try menuCompilation(t, source)
            guard case .text(let text) = program.root.content, let nodes = program.root.menu, nodes.count == 2,
                  case .item(let item) = nodes[0], case .submenu(let title, let children) = nodes[1] else {
                throw DeskMenuFixtureError.structure
            }
            t.equal(item.title, text.value, expression); t.equal(title, text.value)
            t.equal(program.root.voiceOver, item.title); t.equal(item.actions, [.copy(item.title)])
            t.equal(item.checked, .systemProperty(.batteryCharging))
            t.equal(item.enabled, .not(.systemProperty(.batteryPluggedIn))); t.check(children.isEmpty)
            for locale in ["en_US", "zh_CN"] {
                var runtime = try ProgramRuntime(program: program)
                let date = menuDate(locale)
                let input = ProgramSystemInput(batteryCharging: true, batteryPluggedIn: false,
                                               batteryPresent: true, batteryTimeRemaining: 273_852)
                let scene = try runtime.project(environment: menuEnvironment(), dateInput: date,
                                                systemInput: input, measure: menuMeasure)
                let precision = runtime.clockPrecision
                guard case .text(let draw)? = scene.drawingItems.first,
                      let opening = try runtime.resolveMenu(program.root.id, expectedGeneration: scene.generation,
                          environment: menuEnvironment(), dateInput: date, systemInput: input), opening.items.count == 2,
                      case .item(let id, let title, let checked, let enabled) = opening.items[0],
                      case .submenu(let submenuTitle, let nested) = opening.items[1] else { throw DeskMenuFixtureError.structure }
                t.equal(title, draw.text, "\(locale): \(expression)"); t.equal(submenuTitle, title)
                t.equal(title, scene.elements.first?.accessibilityLabel); t.check(checked && enabled && nested.isEmpty)
                t.equal(opening.sourceGeneration, scene.generation); t.equal(runtime.generation, scene.generation)
                t.equal(runtime.clockPrecision, precision, "opening has no display-clock side effect")
                let selected = try runtime.activateMenuItemWithEffects(id, expectedGeneration: scene.generation,
                    environment: menuEnvironment(), dateInput: date, systemInput: input, measure: menuMeasure)
                t.equal(selected?.effects, [.copy(title)])
                if expression == "25%" { t.equal(title, "25") }
                if expression == "battery.present" { t.equal(title, locale == "en_US" ? "Yes" : "是") }
                if expression == #""{battery.timeRemaining, style: .clock}""# { t.equal(title, "76:04:12") }
            }
        }
        let (_, _, defaults) = try menuCompilation(t, #"widget { Text("A").menu { Item("Default"); Item("", checked: true, enabled: false) } }"#)
        t.equal(defaults.root.menu, [.item(ProgramMenuItem(title: .string("Default"))),
                                   .item(ProgramMenuItem(title: .string(""), checked: .boolean(true), enabled: .boolean(false)))])
    }

    t.suite("Desk: menus: ordered nested conditionals preserve every branch and real source parents") {
        let source = #"widget { Text("Battery").name(card).menu { if battery.present { Item("Battery"); if battery.charging { Item("Charging") } else { Divider() } } else if cpu.usage < 20% { Menu("Low") { Item("Details") } } else { Item("Energy") }; Item("Always") } }"#
        let (checked, result, program) = try menuCompilation(t, source)
        guard let nodes = program.root.menu, nodes.count == 2, case .conditional(let conditional) = nodes[0],
              conditional.branches.count == 2, conditional.branches[0].body.count == 2,
              case .conditional(let nested) = conditional.branches[0].body[1],
              case .submenu(_, let submenu)? = conditional.branches[1].body.first else { throw DeskMenuFixtureError.structure }
        t.equal(conditional.branches[0].condition, .systemProperty(.batteryPresent))
        t.equal(conditional.branches[1].condition, .less(.systemProperty(.cpuUsage), .quantity(ProgramNumber(20, dimension: .percent))))
        t.equal(nested.branches[0].condition, .systemProperty(.batteryCharging)); t.equal(nested.otherwise, [.divider])
        t.equal(submenu, [.item(ProgramMenuItem(title: .string("Details")))])
        t.equal(conditional.otherwise, [.item(ProgramMenuItem(title: .string("Energy")))])
        t.equal(result.elementRefs.count, 1); t.equal(checked.elements.count, 8)
        guard let owner = checked.root, let menuRef = checked.elements.first(where: { $0.value.kind == .menu })?.key else { throw DeskMenuFixtureError.structure }
        for (ref, facts) in checked.elements where ref != owner {
            t.equal(facts.parent, facts.component == "Item" && checked.tree.resolve(ref)?.node.trimmedText == #"Item("Details")"# ? menuRef : owner)
        }
        let (_, _, noElse) = try menuCompilation(t, #"widget { Text("A").menu { if not (cpu.usage >= 20%) { Item("Low") } } }"#)
        guard case .conditional(let branch)? = noElse.root.menu?.first else { throw DeskMenuFixtureError.structure }
        t.check(branch.otherwise.isEmpty)
        let reparsed = deskCheck(source)
        for ref in result.elementRefs.values { t.check(reparsed.tree.resolve(ref) == nil) }
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: menuEnvironment(), measure: menuMeasure)
        t.equal(runtime.clockPrecision, nil, "menu-only CPU conditions do not schedule display updates")
        for (input, expected) in [(ProgramSystemInput(cpuUsage: 5, batteryCharging: true, batteryPresent: true),
                                  ["Battery", "Charging", "Always"]),
                                 (ProgramSystemInput(cpuUsage: 5, batteryCharging: false, batteryPresent: true),
                                  ["Battery", "Always"]),
                                 (ProgramSystemInput(cpuUsage: 5, batteryPresent: false), ["Details", "Always"]),
                                 (ProgramSystemInput(cpuUsage: 80, batteryPresent: false), ["Energy", "Always"]),
                                 (ProgramSystemInput(), ["Energy", "Always"])] {
            guard let opening = try runtime.resolveMenu(program.root.id, expectedGeneration: scene.generation,
                environment: menuEnvironment(), systemInput: input) else { throw DeskMenuFixtureError.structure }
            func titles(_ nodes: [ProgramMenuSnapshot.Node]) -> [String] {
                nodes.flatMap { node in
                    switch node {
                    case .item(_, let title, _, _): return [title]
                    case .submenu(_, let items): return titles(items)
                    case .divider: return []
                    }
                }
            }
            t.equal(titles(opening.items), expected); t.equal(runtime.generation, scene.generation)
            t.equal(runtime.clockPrecision, nil)
        }
        t.equal(runtime.neededSystemProperties(openingMenu: program.root.id), [.batteryPresent, .batteryCharging, .cpuUsage])
    }

    t.suite("Desk: menus: item actions share declarations startup pointer ordering and checked warnings") {
        let source = #"widget { variable count = 0; computed spoken = count + 1; Text("{count}").onLoad { count = 1 }.onRightClick { count = count + 1 }.menu { Item("Count {count}", checked: count > 0).onClick { count = count + 1; copy(spoken); open("Calendar") }; Item("No action"); Item("Empty action").onClick { } } }"#
        let (checked, _, program) = try menuCompilation(t, source)
        t.check(checked.diagnostics.contains { $0.id == .menuHiddenByRightClick && $0.severity == .warning })
        t.check(checked.diagnostics.contains { $0.id == .rootTakesOverPointer && $0.severity == .warning })
        guard case .item(let item)? = program.root.menu?.first, let nodes = program.root.menu, nodes.count == 3 else { throw DeskMenuFixtureError.structure }
        t.equal(item.actions, [.assign(ProgramAssignment(declaration: 0, value: .add(.declaration(0), .number(1)))),
                               .copy(.formatNumber(.declaration(1), ProgramNumberFormat())), .open(.string("Calendar"))])
        for node in nodes.dropFirst() {
            guard case .item(let empty) = node else { throw DeskMenuFixtureError.structure }
            t.check(empty.actions.isEmpty, "absent and explicit empty Item handlers both retain their item")
        }
        t.equal(program.onLoad, [ProgramAssignment(declaration: 0, value: .number(1))])
        t.equal(program.root.onRightClickActions, [.assign(ProgramAssignment(declaration: 0, value: .add(.declaration(0), .number(1))))])
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: menuEnvironment(), measure: menuMeasure)
        guard let opening = try runtime.resolveMenu(program.root.id, expectedGeneration: scene.generation,
            environment: menuEnvironment()), case .item(let id, let title, let selected, let enabled)? = opening.items.first else {
            throw DeskMenuFixtureError.structure
        }
        t.equal(title, "Count 1"); t.check(selected && enabled)
        do {
            _ = try runtime.activateMenuItemWithEffects(id, expectedGeneration: scene.generation,
                environment: menuEnvironment(), measure: { _, _, _ in SkinSize(width: 20, height: -1) })
            t.check(false, "invalid resulting measurement must roll back menu assignments and effects")
        } catch { t.equal(error as? ProgramRuntimeError, .invalidMeasurement(program.root.id)) }
        t.equal(runtime.generation, scene.generation)
        t.equal(try runtime.resolveMenu(program.root.id, expectedGeneration: scene.generation,
            environment: menuEnvironment()), opening, "failed selection leaves initialized slots and opening values intact")
        guard let result = try runtime.activateMenuItemWithEffects(id, expectedGeneration: scene.generation,
            environment: menuEnvironment(), measure: menuMeasure) else { throw DeskMenuFixtureError.structure }
        t.equal(result.effects, [.copy("3"), .open("Calendar")], "computed copy observes the preceding count assignment")
        t.equal(result.scene.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.text }; return nil }, ["2"])
        t.equal(try runtime.resolveMenu(program.root.id, expectedGeneration: scene.generation, environment: menuEnvironment()), nil)
        let fresh = try runtime.resolveMenu(program.root.id, expectedGeneration: result.scene.generation, environment: menuEnvironment())
        guard let fresh, fresh.items.count == 3,
              case .item(_, let freshTitle, let freshChecked, _) = fresh.items[0],
              case .item(let emptyID, _, _, _) = fresh.items[2] else { throw DeskMenuFixtureError.structure }
        t.equal(freshTitle, "Count 2"); t.check(freshChecked, "checked is a display value, not an automatic toggle")
        let empty = try runtime.activateMenuItemWithEffects(emptyID, expectedGeneration: result.scene.generation,
            environment: menuEnvironment(), measure: menuMeasure)
        t.equal(empty?.effects, []); t.equal(empty?.scene.drawingItems, result.scene.drawingItems)
    }

    t.suite("Desk: menus: empty root menus nested submenus and inactive view ownership remain explicit") {
        for component in ["Row", "Column", "Freeform"] {
            let (_, refs, program) = try menuCompilation(t, "widget { \(component) { }.size(40, 30).menu { } }")
            t.equal(program.root.menu, []); t.equal(refs.elementRefs.count, 1)
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: menuEnvironment(), measure: menuMeasure)
            t.equal(scene.size, SkinSize(width: 40, height: 30)); t.check(scene.drawingItems.isEmpty)
        }
        let (_, result, program) = try menuCompilation(t,
            #"info { size: .small }"# + "\n" + #"widget { if battery.present { Rectangle().size(20).menu { Menu("Empty") { }; Item("Battery") } } else { Text("None").menu { Item("Energy") } } }"#)
        t.equal(program.root.menu, nil, "the implicit widget root has no invented menu modifier")
        t.equal(result.elementRefs.count, 2)
        var runtime = try ProgramRuntime(program: program)
        for present in [true, false] {
            let scene = try runtime.project(environment: menuEnvironment(), systemInput: ProgramSystemInput(batteryPresent: present), measure: menuMeasure)
            t.equal(scene.size, SkinSize(width: 170, height: 170)); t.equal(scene.elements.count, 2)
        }
    }

    t.suite("Desk: menus: unsupported syntax actions data and dimensions reject all branches without partial refs") {
        for source in [#"widget { Text("A").menu { for entry in [1, 2] { Item(entry) } } }"#,
                       #"widget { Text("A").menu { if false { Item(2W) } else { Item("Allowed") } } }"#,
                       #"widget { Text("A").menu { if network.online { Item("Online") } } }"#,
                       #"widget { Text("A").menu { Item("A").onClick { if true { copy("A") } } } }"#,
                       #"widget { saved count = 0; Text("A").menu { Item("A").onClick { count = 1 } } }"#,
                       #"widget { Text("A").menu { Divider().onClick { copy("A") } } }"#,
                       #"widget { Text("A").menu { Item(battery.health) } }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
            t.check(result.program == nil && !result.issues.isEmpty, "\(source)\n\(result.issues)")
            t.check(result.elementRefs.isEmpty && result.imageSources.isEmpty); t.equal(result.diagnostics, checked.diagnostics)
        }
        for source in [#"widget { Text("A").menu(if: true) { Item("A") } }"#,
                       #"widget { Text("A").menu { }.menu { } }"#,
                       #"widget { Column { Spacer().menu { Item("A") } } }"#,
                       #"widget { Text("A").menu { Item("A", shortcut: "a") } }"#,
                       #"widget { Text("A").menu { Text("Not a menu entry") } }"#,
                       #"widget { Text("A").menu { Item("A") { copy("A") } } }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(!checked.diagnostics(.error).isEmpty, source); t.check(result.program == nil)
            t.equal(result.diagnostics, checked.diagnostics); t.check(result.elementRefs.isEmpty)
        }
    }

    t.suite("Desk: menus: exact catalog and checked menu receipts reject forged publication") {
        let source = #"widget { Text("A").menu { if battery.present { Item(cpu.usage, checked: battery.charging).onClick { copy("A") } } else { Menu("More") { Item("B") } }; Divider() } }"#
        let checked = deskCheck(source)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        guard let root = checked.root, let call = checked.tree.resolve(root).flatMap(CallStmtSyntax.init),
              let modifier = call.modifiers.first, let body = modifier.block,
              let conditional = body.items.first.flatMap(IfStmtSyntax.init),
              let item = conditional.block.items.first.flatMap(CallStmtSyntax.init),
              let title = item.arguments?.arguments.first, let state = item.arguments?.arguments.last,
              let action = item.modifiers.first,
              let menuIndex = DeskCatalog.current.modifiers.firstIndex(where: { $0.name == "menu" }),
              let itemIndex = DeskCatalog.current.components.firstIndex(where: { $0.name == "Item" }) else { throw DeskMenuFixtureError.structure }
        func rejected(_ value: CheckedFile, catalog: DeskCatalog = .current) {
            let result = Desk.compile(value, catalog: catalog)
            t.check(result.program == nil && !result.issues.isEmpty, "\(result.issues)")
            t.check(result.elementRefs.isEmpty && result.imageSources.isEmpty); t.equal(result.diagnostics, value.diagnostics)
        }
        for node in [modifier.node, action.node] {
            var symbols = checked.symbols; symbols.removeValue(forKey: checked.tree.id(of: node))
            rejected(menuFacts(checked, symbols: symbols))
        }
        for node in [title.value.node, state.value.node, conditional.condition.node] {
            var types = checked.types; types.removeValue(forKey: checked.tree.id(of: node)); rejected(menuFacts(checked, types: types))
        }
        var types = checked.types; types[checked.tree.id(of: state.value.node)] = SemType(type: .plainNumber)
        rejected(menuFacts(checked, types: types)); rejected(menuFacts(checked, dataUses: []))
        let itemID = checked.tree.id(of: item.node)
        for damage in ["missing", "parent", "kind", "root", "facets", "inherit", "dropped"] {
            var elements = checked.elements
            switch damage {
            case "missing": elements.removeValue(forKey: itemID)
            case "parent": elements[itemID]?.parent = itemID
            case "kind": elements[itemID]?.kind = .text
            case "root": elements[itemID]?.isRoot = true
            case "facets": elements[itemID]?.facets["color"] = []
            case "inherit": elements[itemID]?.inherits.insert("color")
            default: elements[itemID]?.dropped.append(.element(itemID))
            }
            rejected(menuFacts(checked, elements: elements))
        }
        let modifierChanges: [(inout ModifierSpec) -> Void] = [
            { $0.inheritable = true }, { $0.repeatable = .yes }, { $0.acceptsCondition = true },
            { $0.allowedInStyle = true }, { $0.allowedInState = true }, { $0.block = .menuItems(required: false) },
            { $0.facets = ["tooltip"] }, { $0.fixedValues = ["tooltip": #""Fixed""#] }]
        for change in modifierChanges {
            var catalog = DeskCatalog.current; change(&catalog.modifiers[menuIndex]); rejected(checked, catalog: catalog)
        }
        let itemChanges: [(inout ComponentSpec) -> Void] = [
            { $0.allowedParents = nil }, { $0.kind = .text }, { $0.block = .views(required: false) },
            { $0.signatures[0].params[0].role = .plain }, { $0.signatures[0].params[0].translatable = false },
            { $0.signatures[0].params[1].type = .plainNumber }, { $0.signatures[0].params[1].label = "selected" },
            { $0.signatures[0].params[1].defaultValue = .source("1") }, { $0.signatures[0].params[2].required = true }]
        for change in itemChanges {
            var catalog = DeskCatalog.current; change(&catalog.components[itemIndex]); rejected(checked, catalog: catalog)
        }
    }

    t.suite("Desk: menus: inactive nodes nesting expressions and actions share program budgets") {
        for (source, nodes, depth, tokens) in [
            (#"widget { Text("A").menu { if false { Item("A") } else { Item("B") } } }"#, 3, 64, 1000),
            (#"widget { Text("A").menu { Menu("B") { if true { Item("C") } } } }"#, 1000, 3, 1000),
            (#"widget { Text("A").menu { Item(cpu.usage, enabled: battery.present) } }"#, 1000, 64, 2),
            (#"widget { Text("A").menu { Item("B").onClick { copy("A"); copy("B"); copy("C") } } }"#, 1000, 64, 2)] {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            var catalog = DeskCatalog.current
            catalog.limits.maximumElementInstances = nodes; catalog.limits.maximumBlockNesting = depth
            catalog.limits.maximumTokens = tokens
            let result = Desk.compile(checked, catalog: catalog)
            t.equal(result.issues.first?.kind, .resourceLimit, source); t.check(result.program == nil && result.elementRefs.isEmpty)
        }
        let (_, _, program) = try menuCompilation(t, #"widget { Text("A").menu { Menu("B") { if true { Item("C") } } } }"#)
        t.check(program.root.menu != nil)
    }
}
