import Foundation
@testable import DesksetCore

func runProgramMenuTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "menus"), imageGeneration: 0)
    let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0),
        timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"))
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, _, _ in
        SkinSize(width: Double(text.utf16.count) * 7, height: 14)
    }
    func id(_ index: Int) -> ElementID { ElementID(name: "menu-\(index)", index: index) }
    func itemID(_ path: [Int], owner: Int = 0) -> ProgramMenuItemID { ProgramMenuItemID(owner: id(owner), path: path) }
    func item(_ title: String, actions: [ProgramAction] = []) -> ProgramMenuNode {
        .item(ProgramMenuItem(title: .string(title), actions: actions))
    }
    func box(_ items: [ProgramMenuNode]?, index: Int = 0, hidden: Bool = false) -> ProgramElement {
        ProgramElement(id: id(index), content: .column(spacing: 0, align: .left, children: []),
            width: .fixed(40), height: .fixed(30), hidden: hidden, menu: items)
    }
    func runtime(_ root: ProgramElement, declarations: [ProgramDeclaration] = [],
                 size: ProgramWidgetSize = .fit) throws -> ProgramRuntime {
        try ProgramRuntime(program: WidgetProgram(name: "Menus", root: root, declarations: declarations, size: size))
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }
    func texts(_ scene: WidgetScene) -> [String] {
        scene.drawingItems.compactMap { if case .text(let text) = $0 { return text.text }; return nil }
    }
    func ids(_ nodes: [ProgramMenuSnapshot.Node]) -> [ProgramMenuItemID] {
        nodes.flatMap { node in
            switch node {
            case .item(let id, _, _, _): return [id]
            case .submenu(_, let items): return ids(items)
            case .divider: return []
            }
        }
    }
    func menuHit(_ scene: WidgetScene, _ x: Double, _ y: Double) -> ElementID? {
        scene.hitMap.entries.first { $0.hasMenu && scene.hitMap.isHit($0, x: x, y: y, images: nil) }?.elementID
    }

    t.suite("Program: menus: opening resolves immutable nested values without layout actions or clock mutation") {
        let menu: [ProgramMenuNode] = [
            .item(ProgramMenuItem(title: .declaration(1), checked: .greater(.declaration(0), .number(0)),
                enabled: .systemProperty(.batteryCharging), actions: [
                    .assign(ProgramAssignment(declaration: 0, value: .number(1))), .copy(.concatenate([.systemProperty(.memoryUsed)]))])),
            .divider,
            .submenu(title: .formatDate(.timeNow, .pattern("HH:mm:ss")), items: [
                .item(ProgramMenuItem(title: .formatNumber(.divide(.systemProperty(.batteryTimeRemaining),
                    .quantity(ProgramNumber(60, dimension: .duration))), ProgramNumberFormat(decimals: 1)))), item("Empty action")])
        ]
        let root = ProgramElement(id: id(0), content: .text(ProgramText(value: .concatenate([
            .declaration(0), .string(" "), .formatDate(.timeNow, .pattern("HH:mm"))]))), menu: menu)
        var value = try runtime(root, declarations: [
            ProgramDeclaration(name: "counter", kind: .variable, initial: .number(0)),
            ProgramDeclaration(name: "caption", kind: .computed, initial: .concatenate([
                .declaration(0), .string("|"), .systemProperty(.cpuUsage)]))])
        t.check(!value.isMenuOwnerVisible(id(0))); t.equal(value.neededSystemProperties(openingMenu: id(0)), [])
        t.check(try value.resolveMenu(id(0), expectedGeneration: 0, environment: environment) == nil)
        var measurements = 0
        let before = try value.project(environment: environment, dateInput: date) { text, style, width in
            measurements += 1; return try measure(text, style, width)
        }
        let count = measurements
        t.equal(value.neededSystemProperties, []); t.equal(value.clockPrecision, .minute)
        t.equal(value.neededSystemProperties(openingMenu: id(0)), [.cpuUsage, .batteryCharging, .batteryTimeRemaining])
        let snapshot = try value.resolveMenu(id(0), expectedGeneration: before.generation, environment: environment,
            dateInput: date, systemInput: ProgramSystemInput(cpuUsage: 25, batteryCharging: true, batteryTimeRemaining: 90))
        t.equal(snapshot, ProgramMenuSnapshot(owner: id(0), sourceGeneration: before.generation, items: [
            .item(id: itemID([0]), title: "0|25", checked: false, enabled: true), .divider,
            .submenu(title: "00:00:00", items: [
                .item(id: itemID([2, 0]), title: "1.5", checked: false, enabled: true),
                .item(id: itemID([2, 1]), title: "Empty action", checked: false, enabled: true)])]))
        t.equal(value.generation, before.generation); t.equal(value.clockPrecision, .minute); t.equal(measurements, count)
        failure(.invalidDateInput) {
            _ = try value.resolveMenu(id(0), expectedGeneration: before.generation, environment: environment)
        }
        t.equal(value.generation, before.generation); t.equal(value.clockPrecision, .minute)
        let german = ProgramDateInput(instant: date.instant, timeZone: date.timeZone, locale: Locale(identifier: "de_DE"))
        let localized = try value.resolveMenu(id(0), expectedGeneration: before.generation, environment: environment,
            dateInput: german, systemInput: ProgramSystemInput(batteryTimeRemaining: 90))
        t.equal(localized?.items.first, .item(id: itemID([0]), title: "0|–", checked: false, enabled: false))
        t.equal(localized?.items.last, .submenu(title: "00:00:00", items: [
            .item(id: itemID([2, 0]), title: "1,5", checked: false, enabled: true),
            .item(id: itemID([2, 1]), title: "Empty action", checked: false, enabled: true)]))
        t.equal(snapshot?.items.first, .item(id: itemID([0]), title: "0|25", checked: false, enabled: true))
        let after = try value.project(environment: environment, dateInput: date, measure: measure)
        t.equal(texts(after), ["0 00:00"]); t.equal(after.hitMap, before.hitMap)
        t.check(try value.resolveMenu(id(0), expectedGeneration: before.generation, environment: environment, dateInput: date) == nil)
    }

    t.suite("Program: menus: conditional source paths stay stable and empty first matches short circuit") {
        let conditional = ProgramMenuConditional(branches: [
            ProgramMenuConditionalBranch(condition: .systemProperty(.batteryCharging), body: [item("Same", actions: [.copy(.string("A"))])]),
            ProgramMenuConditionalBranch(condition: .greater(.systemProperty(.cpuUsage), .quantity(ProgramNumber(50, dimension: .percent))),
                body: [item("Same", actions: [.copy(.string("B"))])])
        ], otherwise: [item("Same", actions: [.copy(.string("C"))])])
        let nested = ProgramMenuConditional(branches: [ProgramMenuConditionalBranch(condition: .systemProperty(.batteryPresent),
            body: [item("Present")])], otherwise: [item("Absent")])
        let empty = ProgramMenuConditional(branches: [ProgramMenuConditionalBranch(condition: .boolean(true), body: []),
            ProgramMenuConditionalBranch(condition: .equal(.timeNow, .timeNow), body: [item("Never")])],
            otherwise: [.item(ProgramMenuItem(title: .formatDate(.timeNow, .pattern("HH:mm:ss"))))])
        var value = try runtime(box([item("First"), .conditional(conditional),
            .submenu(title: .string("Nested"), items: [.conditional(nested)]), .divider, item("Last"), .conditional(empty)]))
        let scene = try value.project(environment: environment, measure: measure)
        let inputs = [ProgramSystemInput(cpuUsage: 75, batteryCharging: true, batteryPresent: true),
            ProgramSystemInput(cpuUsage: 75, batteryCharging: false, batteryPresent: false), ProgramSystemInput()]
        for (index, input) in inputs.enumerated() {
            let snapshot = try value.resolveMenu(id(0), expectedGeneration: scene.generation, environment: environment, systemInput: input)
            t.equal(ids(snapshot?.items ?? []), [itemID([0]), itemID([1, index, 0]),
                itemID([2, 0, index == 0 ? 0 : 1, 0]), itemID([4])])
            t.equal(snapshot?.items.count, 5, "true empty arm does not fall through or evaluate later date expressions")
        }
        let restored = try value.resolveMenu(id(0), expectedGeneration: scene.generation, environment: environment, systemInput: inputs[0])
        t.equal(ids(restored?.items ?? []).dropFirst().first, itemID([1, 0, 0]))
        t.check(try value.activateMenuItemWithEffects(itemID([1, 0, 0]), expectedGeneration: scene.generation,
            environment: environment, systemInput: inputs[1], measure: measure) == nil)
        t.equal(value.generation, scene.generation)
        let selected = try value.activateMenuItemWithEffects(itemID([1, 1, 0]), expectedGeneration: scene.generation,
            environment: environment, systemInput: inputs[1], measure: measure)
        t.equal(selected?.effects, [.copy("B")]); t.equal(value.clockPrecision, nil)
        t.check(try value.activateMenuItemWithEffects(itemID([1, 1, 0]), expectedGeneration: scene.generation,
            environment: environment, systemInput: inputs[1], measure: measure) == nil)
        t.equal(try value.activateMenuItemWithEffects(itemID([1, 2, 0]), expectedGeneration: value.generation,
            environment: environment, systemInput: ProgramSystemInput(), measure: measure)?.effects, [.copy("C")])
    }

    t.suite("Program: menus: selection rechecks enabled and visible owner membership without auto toggling") {
        let command = ProgramMenuNode.item(ProgramMenuItem(title: .string("Checked"), checked: .boolean(true),
            enabled: .greater(.systemProperty(.cpuUsage), .quantity(ProgramNumber(50, dimension: .percent)))))
        let target = ProgramElement(id: id(2), content: .column(spacing: 0, align: .left, children: []),
            width: .fixed(40), height: .fixed(30), hiddenIf: .systemProperty(.batteryCharging),
            menu: [command, .divider, .submenu(title: .string("Empty"), items: [])])
        let branch = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .systemProperty(.batteryPluggedIn), body: [target])
        ])))
        var value = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [branch])))
        for input in [ProgramSystemInput(batteryPluggedIn: false),
                      ProgramSystemInput(batteryCharging: true, batteryPluggedIn: true)] {
            let scene = try value.project(environment: environment, systemInput: input, measure: measure)
            t.check(!value.isMenuOwnerVisible(id(2)))
            t.equal(value.neededSystemProperties(openingMenu: id(2)), [])
            t.equal(value.neededSystemProperties(activatingMenuItem: itemID([0], owner: 2)), [])
            t.check(try value.resolveMenu(id(2), expectedGeneration: scene.generation, environment: environment) == nil)
            t.check(try value.activateMenuItemWithEffects(itemID([0], owner: 2), expectedGeneration: scene.generation,
                environment: environment, measure: measure) == nil)
        }
        let input = ProgramSystemInput(cpuUsage: 75, batteryCharging: false, batteryPluggedIn: true)
        let shown = try value.project(environment: environment, systemInput: input, measure: measure)
        t.check(value.isMenuOwnerVisible(id(2))); t.check(!value.isMenuOwnerVisible(id(0)))
        let opening = try value.resolveMenu(id(2), expectedGeneration: shown.generation, environment: environment, systemInput: input)
        t.equal(opening?.items.first, .item(id: itemID([0], owner: 2), title: "Checked", checked: true, enabled: true))
        for input in [ProgramSystemInput(cpuUsage: 25), ProgramSystemInput()] {
            t.check(try value.activateMenuItemWithEffects(itemID([0], owner: 2), expectedGeneration: shown.generation,
                environment: environment, systemInput: input, measure: measure) == nil)
            t.equal(value.generation, shown.generation)
        }
        let invalid = [itemID([], owner: 2), itemID([-1], owner: 2), itemID([99], owner: 2), itemID([1], owner: 2),
            itemID([2], owner: 2), itemID([0, 1], owner: 2), itemID([0], owner: 99),
            ProgramMenuItemID(owner: ElementID(name: "other", index: 2), path: [0])]
        for id in invalid {
            t.equal(value.neededSystemProperties(activatingMenuItem: id), [])
            t.check(try value.activateMenuItemWithEffects(id, expectedGeneration: shown.generation,
                environment: environment, systemInput: input, measure: measure) == nil)
        }
        let activated = try value.activateMenuItemWithEffects(itemID([0], owner: 2), expectedGeneration: shown.generation,
            environment: environment, systemInput: input, measure: measure)
        t.check(activated != nil); t.equal(activated?.effects, [])
        t.equal(try value.resolveMenu(id(2), expectedGeneration: value.generation, environment: environment,
            systemInput: input)?.items.first, opening?.items.first, "empty actions do not toggle checked")
        _ = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryPluggedIn: false), measure: measure)
        t.check(!value.isMenuOwnerVisible(id(2)))
        _ = try value.project(environment: environment, systemInput: input, measure: measure)
        t.check(value.isMenuOwnerVisible(id(2)), "hosts may retire an old lease at the intervening absence")
    }

    t.suite("Program: menus: menu-only boxes preserve pointer priority rounding and zero-area root overflow") {
        let containers: [([ProgramElement]) -> ProgramElement.Content] = [
            { .row(spacing: 0, align: .top, children: $0) }, { .column(spacing: 0, align: .left, children: $0) },
            { .freeform(align: .topLeft, children: $0) }]
        for content in containers {
            for menu in [[ProgramMenuNode](), [item("Item")]] {
                var value = try runtime(ProgramElement(id: id(0), content: content([]), width: .fixed(40), height: .fixed(30),
                    padding: SkinInsets(left: 4, top: 4, right: 4, bottom: 4), cornerRadius: .points(8), menu: menu))
                let scene = try value.project(environment: environment) { _, _, _ in
                    t.check(false, "menu never enters measurement"); return SkinSize()
                }
                t.check(scene.drawingItems.isEmpty); t.equal(scene.size, SkinSize(width: 40, height: 30))
                t.equal(menuHit(scene, 1, 15), id(0)); t.equal(menuHit(scene, 0.1, 0.1), nil)
                t.equal(scene.hitMap.mouseCursorName(at: 20, 15, images: nil), nil)
                t.check(scene.hitMap.entries.first?.actions.isEmpty == true)
                for event in [MouseEventKind.leftUp, .rightUp] {
                    t.check(!scene.hitMap.hasAction(event, x: 20, y: 15, images: nil))
                    t.check(try value.clickWithEffects(at: SkinPoint(x: 20, y: 15), expectedGeneration: scene.generation,
                        event: event, environment: environment, measure: measure) == nil)
                }
            }
        }
        let child = ProgramElement(id: id(1), content: .rectangle(fill: .literal(.clear)), width: .fixed(40), height: .fixed(30),
            menu: [item("Child")])
        let root = ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [child]),
            onClickActions: [.copy(.string("left"))], onRightClickActions: [],
            tooltip: ProgramTooltip(text: .string("Parent")), menu: [item("Root")])
        var pointer = try runtime(root)
        let scene = try pointer.project(environment: environment, measure: measure)
        t.equal(menuHit(scene, 20, 15), id(1)); t.equal(scene.hitMap.mouseCursorName(at: 20, 15, images: nil), "HAND")
        t.equal(scene.hitMap.entry(at: 20, 15, handling: .rightUp, images: nil)?.elementID, id(0))
        t.equal(scene.hitMap.toolTipInfo(at: 20, 15, images: nil), ToolTipInfo(text: "Parent"))
        t.equal(try pointer.clickWithEffects(at: SkinPoint(x: 20, y: 15), expectedGeneration: scene.generation,
            environment: environment, measure: measure)?.effects, [.copy("left")])

        let overflow = ProgramElement(id: id(1), content: .rectangle(fill: .literal(.clear)), width: .fixed(20), height: .fixed(20),
            position: ProgramPosition(x: -10, y: -10))
        var zero = try runtime(ProgramElement(id: id(0), content: .freeform(align: .topLeft, children: [overflow]),
            width: .fixed(0), height: .fixed(0), menu: [item("Fallback")]))
        let emptyRoot = try zero.project(environment: environment, measure: measure)
        t.equal(emptyRoot.elements[0].frame, SkinRect()); t.equal(emptyRoot.elements[1].frame, SkinRect(x: -10, y: -10, width: 20, height: 20))
        t.check(emptyRoot.hitMap.entries.isEmpty); t.check(zero.isMenuOwnerVisible(id(0)))
        t.equal(try zero.resolveMenu(id(0), expectedGeneration: emptyRoot.generation, environment: environment)?.items,
            [.item(id: itemID([0]), title: "Fallback", checked: false, enabled: true)])

        let target = ProgramElement(id: id(1), content: .column(spacing: 0, align: .left, children: []),
            width: .fixed(200), height: .fixed(100), cornerRadius: .points(20), position: ProgramPosition(x: -20, y: -10), menu: [])
        var preset = try runtime(ProgramElement(id: id(0), content: .freeform(align: .center, children: [target])),
            size: .preset(.small, size: SkinSize(width: 100, height: 50)))
        let scaled = try preset.project(environment: environment, measure: measure)
        t.equal(scaled.hitMap.entries.first?.frame, SkinRect(width: 100, height: 50))
        t.equal(menuHit(scaled, 1, 5), nil); t.equal(menuHit(scaled, 1, 25), id(1))
        let marked = scaled.hitMap.entries[0]
        let legacy = SkinHitMap.Entry(name: marked.name, frame: marked.frame, shape: marked.shape,
            container: nil, glass: nil, isButton: false, actions: [:], cursor: true, cursorName: "", toolTip: nil, elementID: marked.elementID)
        t.check(!legacy.hasMenu); t.check(legacy != marked, "menu membership participates in hit snapshot equality")
    }

    t.suite("Program: menus: demand separates opening selected actions and the ordinary projection") {
        let command = ProgramMenuNode.item(ProgramMenuItem(title: .declaration(1), checked: .systemProperty(.batteryPluggedIn),
            enabled: .greater(.systemProperty(.batteryLevel), .quantity(ProgramNumber(0, dimension: .percent))), actions: [.copy(.declaration(2))]))
        let root = ProgramElement(id: id(0), content: .row(spacing: 0, align: .top, children: [
            ProgramElement(id: id(1), content: .text(ProgramText(value: .concatenate([.systemProperty(.cpuCoreCount)])))),
            box([.item(ProgramMenuItem(title: .concatenate([.systemProperty(.batteryTimeRemaining)])))], index: 2)
        ]), menu: [.conditional(ProgramMenuConditional(branches: [
            ProgramMenuConditionalBranch(condition: .systemProperty(.batteryCharging), body: [command])
        ], otherwise: [.item(ProgramMenuItem(title: .concatenate([.systemProperty(.memoryTotal)]),
            enabled: .systemProperty(.batteryPresent), actions: [.copy(.concatenate([.systemProperty(.cpuUsage)]))]))]))])
        var value = try runtime(root, declarations: [
            ProgramDeclaration(name: "frozen", kind: .variable, initial: .systemProperty(.memoryFree)),
            ProgramDeclaration(name: "title", kind: .computed, initial: .concatenate([.systemProperty(.cpuUsage)])),
            ProgramDeclaration(name: "action", kind: .computed, initial: .concatenate([.systemProperty(.memoryUsed)]))])
        t.equal(value.neededSystemProperties, [.cpuCoreCount, .memoryFree])
        _ = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuCoreCount: 8, memoryFree: 1024), measure: measure)
        t.equal(value.neededSystemProperties, [.cpuCoreCount]); t.equal(value.clockPrecision, nil)
        t.equal(value.neededSystemProperties(openingMenu: id(0)),
            [.batteryCharging, .cpuUsage, .batteryPluggedIn, .batteryLevel, .memoryTotal, .batteryPresent])
        t.equal(value.neededSystemProperties(openingMenu: id(2)), [.batteryTimeRemaining])
        t.equal(value.neededSystemProperties(activatingMenuItem: itemID([0, 0, 0])),
            [.batteryCharging, .batteryLevel, .memoryUsed, .cpuCoreCount])
        t.equal(value.neededSystemProperties(activatingMenuItem: itemID([0, 1, 0])),
            [.batteryCharging, .batteryPresent, .cpuUsage, .cpuCoreCount])
        t.equal(value.neededSystemProperties(openingMenu: id(1)), [])
        t.equal(value.neededSystemProperties(activatingMenuItem: itemID([0], owner: 1)), [])
    }

    t.suite("Program: menus: selection transactions retain ordered effects and roll back failed scene resources") {
        let icon = ProgramElement(id: id(3), content: .icon(ProgramIcon(name: .string("star"))), width: .fixed(20), height: .fixed(20))
        let selection = ProgramElement(id: id(2), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .declaration(1), body: [icon])
        ])))
        let actions: [ProgramAction] = [
            .assign(ProgramAssignment(declaration: 0, value: .add(.declaration(0), .number(1)))), .copy(.declaration(2)),
            .assign(ProgramAssignment(declaration: 0, value: .add(.declaration(0), .number(1)))), .copy(.declaration(2)),
            .assign(ProgramAssignment(declaration: 1, value: .boolean(true)))
        ]
        let root = ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [
            ProgramElement(id: id(1), content: .text(ProgramText(value: .concatenate([.declaration(0)])))), selection
        ]), menu: [.item(ProgramMenuItem(title: .declaration(2), checked: .greater(.declaration(0), .number(0)), actions: actions))])
        var value = try runtime(root, declarations: [
            ProgramDeclaration(name: "count", kind: .variable, initial: .number(0)),
            ProgramDeclaration(name: "show", kind: .variable, initial: .boolean(false)),
            ProgramDeclaration(name: "caption", kind: .computed, initial: .concatenate([.string("n="), .declaration(0)]))])
        let first = try value.project(environment: environment, measure: measure)
        let opening = try value.resolveMenu(id(0), expectedGeneration: first.generation, environment: environment)
        failure(.missingIconMeasurement(id(3))) {
            _ = try value.activateMenuItemWithEffects(itemID([0]), expectedGeneration: first.generation,
                environment: environment, measure: measure)
        }
        t.equal(value.generation, first.generation); t.equal(value.clockPrecision, nil); t.check(value.isMenuOwnerVisible(id(0)))
        failure(.invalidMeasurement(id(3))) {
            _ = try value.activateMenuItemWithEffects(itemID([0]), expectedGeneration: first.generation,
                environment: environment, measureIcon: { _ in SkinSize(width: .nan, height: 10) }, measure: measure)
        }
        let retained = try value.project(environment: environment, measure: measure)
        t.equal(texts(retained), ["0"]); t.equal(retained.hitMap, first.hitMap)
        let accepted = try value.activateMenuItemWithEffects(itemID([0]), expectedGeneration: retained.generation,
            environment: environment, measureIcon: { request in
                t.equal(request.name, "star"); return SkinSize(width: 10, height: 10)
            }, measure: measure)
        t.equal(accepted?.effects, [.copy("n=1"), .copy("n=2")])
        t.equal(accepted.map { texts($0.scene) }, ["2"])
        t.equal(try value.resolveMenu(id(0), expectedGeneration: value.generation, environment: environment)?.items.first,
            .item(id: itemID([0]), title: "n=2", checked: true, enabled: true))
        t.equal(opening?.items.first, .item(id: itemID([0]), title: "n=0", checked: false, enabled: true))
    }

    t.suite("Program: menus: all template arms share view node depth expression and action budgets") {
        let invalid: [ProgramMenuNode] = [
            .item(ProgramMenuItem(title: .boolean(false))), .item(ProgramMenuItem(title: .string("Title"), checked: .number(1))),
            .item(ProgramMenuItem(title: .string("Title"), enabled: .string("true"))),
            .submenu(title: .number(1), items: []), .conditional(ProgramMenuConditional(branches: [])),
            .item(ProgramMenuItem(title: .string(String(repeating: "x", count: ProgramLimits.maximumTextLength + 1))))
        ]
        for node in invalid {
            failure(.invalidExpression) {
                _ = try runtime(box([.conditional(ProgramMenuConditional(branches: [
                    ProgramMenuConditionalBranch(condition: .boolean(false), body: [node])
                ]))], hidden: true))
            }
        }
        failure(.invalidDeclaration(9)) { _ = try runtime(box([.item(ProgramMenuItem(title: .declaration(9)))])) }
        failure(.invalidAssignment(0)) {
            _ = try runtime(box([item("Assign", actions: [.assign(ProgramAssignment(declaration: 0, value: .number(1)))])]),
                declarations: [ProgramDeclaration(name: "constant", kind: .computed, initial: .number(0))])
        }
        failure(.invalidGeometry(id(1))) {
            let structural = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
                ProgramConditionalBranch(condition: .boolean(true), body: [box(nil, index: 2)])
            ])), menu: [])
            _ = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [structural])))
        }
        failure(.emptyProgram) { _ = try runtime(box(nil)) }
        func nodes(_ count: Int) throws -> ProgramRuntime {
            try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [
                ProgramElement(id: id(1), content: .rectangle(fill: .literal(.clear)), width: .fixed(1), height: .fixed(1))
            ]), menu: Array(repeating: .divider, count: count)))
        }
        _ = try nodes(ProgramLimits.maximumElements - 2)
        failure(.elementLimit) { _ = try nodes(ProgramLimits.maximumElements - 1) }
        var deep = ProgramMenuNode.divider
        for _ in 0..<(ProgramLimits.maximumDepth - 2) { deep = .submenu(title: .string("Level"), items: [deep]) }
        _ = try runtime(box([deep]))
        failure(.depthLimit) { _ = try runtime(box([.submenu(title: .string("Too deep"), items: [deep])])) }
        failure(.depthLimit) {
            _ = try runtime(ProgramElement(id: id(1), content: .column(spacing: 0, align: .left, children: [box([deep])])))
        }
        func expressions(_ count: Int) throws -> ProgramRuntime {
            try runtime(ProgramElement(id: id(0), content: .rectangle(fill: .literal(.clear)), width: .fixed(1), height: .fixed(1),
                voiceOver: .string("Label"), menu: [.item(ProgramMenuItem(title: .concatenate(Array(repeating: .string("a"), count: count)),
                    actions: [.copy(.string("Action"))]))]))
        }
        _ = try expressions(ProgramLimits.maximumExpressions - 5)
        failure(.expressionLimit) { _ = try expressions(ProgramLimits.maximumExpressions - 4) }
        var title = ProgramExpression.string("Title")
        for _ in 0..<ProgramLimits.maximumExpressionDepth { title = .concatenate([title]) }
        failure(.expressionDepth) { _ = try runtime(box([.item(ProgramMenuItem(title: title))], hidden: true)) }
        let actions = Array(repeating: ProgramAction.copy(.string("")), count: 2500)
        failure(.expressionLimit) {
            _ = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: []),
                onClickActions: actions, menu: [item("Actions", actions: actions + [.copy(.string(""))])]))
        }
        let oversized = ProgramExpression.concatenate([.string(String(repeating: "x", count: ProgramLimits.maximumTextLength)), .string("x")])
        var value = try runtime(box([.item(ProgramMenuItem(title: oversized))]))
        let scene = try value.project(environment: environment, measure: measure)
        failure(.invalidExpression) { _ = try value.resolveMenu(id(0), expectedGeneration: scene.generation, environment: environment) }
        t.equal(value.generation, scene.generation); t.equal(value.clockPrecision, nil)
    }
}
