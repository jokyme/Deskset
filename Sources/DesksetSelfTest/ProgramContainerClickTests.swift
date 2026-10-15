import Foundation
@testable import DesksetCore

func runProgramContainerClickTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "container-clicks"), imageGeneration: 0)
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { _, _, _ in SkinSize(width: 12, height: 8) }
    let containers: [([ProgramElement]) -> ProgramElement.Content] = [
        { .row(spacing: 0, align: .top, children: $0) },
        { .column(spacing: 0, align: .left, children: $0) },
        { .freeform(align: .topLeft, children: $0) }
    ]
    func id(_ n: Int) -> ElementID { ElementID(name: "container", index: n) }
    func runtime(_ root: ProgramElement, declarations: [ProgramDeclaration] = [],
                 size: ProgramWidgetSize = .fit) throws -> ProgramRuntime {
        try ProgramRuntime(program: WidgetProgram(name: "Container clicks", root: root, declarations: declarations, size: size))
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }
    func texts(_ scene: WidgetScene) -> [String] {
        scene.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.text }; return nil }
    }
    func date() -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!,
                         locale: Locale(identifier: "en_US_POSIX"))
    }

    t.suite("Program: container clicks: empty sized containers retain primary and secondary handlers without paint") {
        for content in containers {
            for event in [MouseEventKind.leftUp, .rightUp] {
                for actions in [[ProgramAction](), [.copy(.string("tap"))]] {
                    let root = ProgramElement(id: id(0), content: content([]), width: .fixed(40), height: .fixed(30),
                        onClickActions: event == .leftUp ? actions : nil,
                        onRightClickActions: event == .rightUp ? actions : nil)
                    var value = try runtime(root)
                    let scene = try value.project(environment: environment, measure: measure)
                    t.equal(scene.size, SkinSize(width: 40, height: 30))
                    t.equal(scene.elements.map(\.frame), [SkinRect(width: 40, height: 30)])
                    t.check(scene.drawingItems.isEmpty && scene.glass.isEmpty)
                    t.equal(scene.hitMap.entry(at: 20, 15, handling: event, images: nil)?.elementID, id(0))
                    t.equal(scene.hitMap.entries.first?.action(event), actions.isEmpty ? .caught : .runs)
                    let result = try value.clickWithEffects(at: SkinPoint(x: 20, y: 15), expectedGeneration: scene.generation,
                        event: event, environment: environment, measure: measure)
                    let effects: [ProgramEffect] = actions.isEmpty ? [] : [.copy("tap")]
                    t.check(result != nil); t.equal(result?.effects, effects)
                    let activation = try value.activateContainerWithEffects(id(0), expectedGeneration: value.generation,
                        environment: environment, measure: measure)
                    if event == .leftUp { t.check(activation != nil); t.equal(activation?.effects, effects) }
                    else { t.check(activation == nil, "a secondary-only container is not a primary activation target") }
                }
            }
            let legacy = ProgramElement(id: id(0), content: content([]), width: .fixed(40), height: .fixed(30), onClick: [])
            var value = try runtime(legacy)
            let scene = try value.project(environment: environment, measure: measure)
            t.equal(try value.activateContainerWithEffects(id(0), expectedGeneration: scene.generation,
                environment: environment, measure: measure)?.effects, [])
            failure(.emptyProgram) {
                _ = try runtime(ProgramElement(id: id(0), content: content([]), width: .fixed(40), height: .fixed(30)))
            }
        }
        let empty = ProgramElement(id: id(1), content: .row(spacing: 0, align: .top, children: []))
        failure(.emptyProgram) {
            _ = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [empty])))
        }
    }

    t.suite("Program: container clicks: pointer targeting remains event-specific through children and padding") {
        let cases: [([ProgramAction]?, [ProgramAction]?)] = [
            (nil, nil), ([.copy(.string("child left"))], nil), (nil, [.copy(.string("child right"))]),
            ([], []), ([.copy(.string("child left"))], [.copy(.string("child right"))])
        ]
        for content in containers {
            for (left, right) in cases {
                let child = ProgramElement(id: id(1), content: .rectangle(fill: .literal(.clear)),
                    width: .fixed(20), height: .fixed(20), padding: SkinInsets(left: 2, top: 2, right: 2, bottom: 2),
                    cornerRadius: .points(6), onClickActions: left, onRightClickActions: right)
                let root = ProgramElement(id: id(0), content: content([child]),
                    padding: SkinInsets(left: 6, top: 6, right: 6, bottom: 6),
                    onClickActions: [.copy(.string("parent left"))], onRightClickActions: [.copy(.string("parent right"))])
                var value = try runtime(root)
                let scene = try value.project(environment: environment, measure: measure)
                t.equal(scene.size, SkinSize(width: 32, height: 32))
                t.equal(scene.elements[1].frame, SkinRect(x: 6, y: 6, width: 20, height: 20))
                for event in [MouseEventKind.leftUp, .rightUp] {
                    let childActions = event == .leftUp ? left : right
                    let target = childActions == nil ? id(0) : id(1)
                    t.equal(scene.hitMap.entry(at: 10, 10, handling: event, images: nil)?.elementID, target)
                    t.equal(scene.hitMap.entry(at: 1, 16, handling: event, images: nil)?.elementID, id(0), "parent padding")
                    t.equal(scene.hitMap.entry(at: 6.1, 6.1, handling: event, images: nil)?.elementID, id(0), "child rounded corner miss")
                    let result = try value.clickWithEffects(at: SkinPoint(x: 10, y: 10), expectedGeneration: value.generation,
                        event: event, environment: environment, measure: measure)
                    let suffix = event == .leftUp ? "left" : "right"
                    let effects: [ProgramEffect] = childActions.map { $0.isEmpty ? [] : [.copy("child \(suffix)")] }
                        ?? [.copy("parent \(suffix)")]
                    t.equal(result?.effects, effects)
                }
            }
        }
    }

    t.suite("Program: container clicks: identity activation reaches a parent covered by primary child handlers") {
        for content in containers {
            for childActions in [[ProgramAction](), [.copy(.string("child"))]] {
                let child = ProgramElement(id: id(1), content: .rectangle(fill: .literal(.clear)),
                    width: .fixed(40), height: .fixed(30), onClickActions: childActions)
                let root = ProgramElement(id: id(0), content: content([child]),
                    onClickActions: [.copy(.string("parent"))], onRightClickActions: [.copy(.string("secondary"))],
                    voiceOver: .string("Parent"))
                var value = try runtime(root)
                let scene = try value.project(environment: environment, measure: measure)
                t.equal(scene.hitMap.entry(at: 20, 15, handling: .leftUp, images: nil)?.elementID, id(1))
                let parent = try value.activateContainerWithEffects(id(0), expectedGeneration: scene.generation,
                    environment: environment, measure: measure)
                t.equal(parent?.effects, [.copy("parent")])
                let pointer = try value.clickWithEffects(at: SkinPoint(x: 20, y: 15), expectedGeneration: value.generation,
                    environment: environment, measure: measure)
                t.equal(pointer?.effects, childActions.isEmpty ? [] : [.copy("child")])
                let generation = value.generation
                for rejected in [id(1), id(99), ElementID(name: "different", index: 0)] {
                    t.check(try value.activateContainerWithEffects(rejected, expectedGeneration: generation,
                        environment: environment, measure: measure) == nil)
                    t.equal(value.neededSystemProperties(activatingContainer: rejected), [])
                }
                t.check(try value.activateContainerWithEffects(id(0), expectedGeneration: scene.generation,
                    environment: environment, measure: measure) == nil)
                t.equal(value.generation, generation)
            }
        }
    }

    t.suite("Program: container clicks: uninitialized hidden and zero-area targets never activate or sample") {
        for content in containers {
            let actions: [ProgramAction] = [.copy(.concatenate([.systemProperty(.cpuUsage)]))]
            let root = ProgramElement(id: id(0), content: content([]), width: .fixed(40), height: .fixed(30), onClickActions: actions)
            var value = try runtime(root)
            t.equal(value.neededSystemProperties(activatingContainer: id(0)), [])
            t.check(try value.activateContainerWithEffects(id(0), expectedGeneration: 0, environment: environment,
                measure: { _, _, _ in t.check(false, "uninitialized activation cannot project"); return SkinSize() }) == nil)
            for (width, height, hidden) in [(0.0, 30.0, false), (40.0, 0.0, false), (40.0, 30.0, true)] {
                let unavailable = ProgramElement(id: id(0), content: content([]), width: .fixed(width), height: .fixed(height),
                    hidden: hidden, onClickActions: actions)
                var invisible = try runtime(unavailable)
                let scene = try invisible.project(environment: environment, measure: measure)
                t.check(scene.hitMap.entries.isEmpty)
                t.equal(invisible.neededSystemProperties(activatingContainer: id(0)), [])
                t.check(try invisible.activateContainerWithEffects(id(0), expectedGeneration: scene.generation,
                    environment: environment, measure: measure) == nil)
                t.equal(invisible.generation, scene.generation)
            }
            let visible = try value.project(environment: environment, measure: measure)
            for point in [SkinPoint(x: .nan, y: 10), SkinPoint(x: 10, y: .infinity), SkinPoint(x: 40, y: 15)] {
                t.check(try value.clickWithEffects(at: point, expectedGeneration: visible.generation,
                    environment: environment, measure: measure) == nil)
            }
            t.equal(value.generation, visible.generation)
        }
    }

    t.suite("Program: container clicks: dynamic hiding and view-if membership qualify the current identity") {
        let target = ProgramElement(id: id(2), content: .row(spacing: 0, align: .top, children: []),
            width: .fixed(40), height: .fixed(30), onClickActions: [.copy(.string("target"))],
            voiceOver: .string("Target"), hiddenIf: .systemProperty(.batteryCharging))
        let selection = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .systemProperty(.batteryPluggedIn), body: [target])
        ])))
        let root = ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [selection]))
        var value = try runtime(root)
        let absent = try value.project(environment: environment,
            systemInput: ProgramSystemInput(batteryCharging: false, batteryPluggedIn: false), measure: measure)
        t.equal(absent.elements.map(\.id), [id(0)]); t.check(absent.hitMap.entries.isEmpty)
        t.check(try value.activateContainerWithEffects(id(2), expectedGeneration: absent.generation,
            environment: environment, measure: measure) == nil)
        let hidden = try value.project(environment: environment,
            systemInput: ProgramSystemInput(batteryCharging: true, batteryPluggedIn: true), measure: measure)
        t.equal(hidden.elements.last?.visibility, .hiddenKeepsSpace); t.equal(hidden.elements.last?.accessibilityLabel, nil)
        t.equal(value.neededSystemProperties(activatingContainer: id(2)), [])
        t.check(try value.activateContainerWithEffects(id(2), expectedGeneration: hidden.generation,
            environment: environment, measure: measure) == nil)
        let input = ProgramSystemInput(batteryCharging: false, batteryPluggedIn: true)
        let shown = try value.project(environment: environment, systemInput: input, measure: measure)
        t.equal(value.neededSystemProperties(activatingContainer: id(2)), [.batteryCharging, .batteryPluggedIn])
        t.equal(shown.elements.last?.accessibilityLabel, "Target")
        t.check(try value.activateContainerWithEffects(id(2), expectedGeneration: hidden.generation,
            environment: environment, systemInput: input, measure: measure) == nil)
        let activated = try value.activateContainerWithEffects(id(2), expectedGeneration: shown.generation,
            environment: environment, systemInput: input, measure: measure)
        t.equal(activated?.effects, [.copy("target")])
        let removed = try value.project(environment: environment,
            systemInput: ProgramSystemInput(batteryCharging: false, batteryPluggedIn: false), measure: measure)
        t.check(try value.activateContainerWithEffects(id(2), expectedGeneration: removed.generation,
            environment: environment, measure: measure) == nil)
        let restored = try value.project(environment: environment, systemInput: input, measure: measure)
        t.equal(restored.hitMap, shown.hitMap)
        let hiddenRoot = ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [target]), hidden: true)
        var ancestor = try runtime(hiddenRoot)
        let scene = try ancestor.project(environment: environment, measure: measure)
        t.check(scene.hitMap.entries.isEmpty)
        t.check(try ancestor.activateContainerWithEffects(id(2), expectedGeneration: scene.generation,
            environment: environment, measure: measure) == nil)
    }

    t.suite("Program: container clicks: overlapping Freeform boxes preserve source order without implicit parent clipping") {
        let first = ProgramElement(id: id(1), content: .row(spacing: 0, align: .top, children: []),
            width: .fixed(20), height: .fixed(20), onClickActions: [.copy(.string("first"))],
            onRightClickActions: [.copy(.string("first right"))], position: ProgramPosition(x: -5, y: -5))
        let last = ProgramElement(id: id(2), content: .column(spacing: 0, align: .left, children: []),
            width: .fixed(20), height: .fixed(20), onClickActions: [], position: ProgramPosition(x: 0, y: 0))
        let root = ProgramElement(id: id(0), content: .freeform(align: .topLeft, children: [first, last]),
            width: .fixed(40), height: .fixed(40), cornerRadius: .full, onClickActions: [.copy(.string("root"))])
        var value = try runtime(root)
        let scene = try value.project(environment: environment, measure: measure)
        t.equal(scene.hitMap.entries.map(\.elementID), [id(2), id(1), id(0)])
        t.equal(scene.hitMap.entry(at: 1, 1, handling: .leftUp, images: nil)?.elementID, id(2))
        t.equal(scene.hitMap.entry(at: 1, 1, handling: .rightUp, images: nil)?.elementID, id(1))
        t.equal(scene.hitMap.entry(at: -4, -4, handling: .leftUp, images: nil)?.elementID, id(1))
        t.equal(scene.hitMap.entry(at: 30, 20, handling: .leftUp, images: nil)?.elementID, id(0))
        t.check(scene.hitMap.entry(at: 39, 1, handling: .leftUp, images: nil) == nil)
        t.equal(try value.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: scene.generation,
            environment: environment, measure: measure)?.effects, [])
        t.equal(try value.activateContainerWithEffects(id(0), expectedGeneration: value.generation,
            environment: environment, measure: measure)?.effects, [.copy("root")])
    }

    t.suite("Program: container clicks: negative origins and preset fitting transform box and rounding once") {
        let target = ProgramElement(id: id(1), content: .column(spacing: 0, align: .left, children: []),
            width: .fixed(200), height: .fixed(100), cornerRadius: .points(20), onClickActions: [.copy(.string("target"))],
            position: ProgramPosition(x: -20, y: -10), background: .glass(style: .regular), voiceOver: .string("Target"))
        let root = ProgramElement(id: id(0), content: .freeform(align: .center, children: [target]))
        var fit = try runtime(root)
        let ordinary = try fit.project(environment: environment, measure: measure)
        t.equal(ordinary.size, SkinSize(width: 180, height: 90))
        t.equal(ordinary.elements[1].frame, SkinRect(x: -20, y: -10, width: 200, height: 100))
        t.equal(ordinary.hitMap.entry(at: -19, 40, handling: .leftUp, images: nil)?.elementID, id(1))
        t.equal(try fit.clickWithEffects(at: SkinPoint(x: -19, y: 40), expectedGeneration: ordinary.generation,
            environment: environment, measure: measure)?.effects, [.copy("target")])
        var preset = try runtime(root, size: .preset(.small, size: SkinSize(width: 100, height: 50)))
        let scene = try preset.project(environment: environment, measure: measure)
        t.equal(scene.elements[0].frame, SkinRect(x: 10, y: 5, width: 50, height: 25))
        t.equal(scene.elements[1].frame, SkinRect(width: 100, height: 50))
        t.equal(scene.elements[1].glass?.rect, SkinRect(width: 100, height: 50))
        t.equal(scene.elements[1].glass?.cornerRadius, 10)
        t.equal(scene.hitMap.entries.first?.frame, SkinRect(width: 100, height: 50))
        t.check(scene.hitMap.entry(at: 1, 5, handling: .leftUp, images: nil) == nil, "radius is 10, not a second scale to 5")
        t.equal(scene.hitMap.entry(at: 1, 25, handling: .leftUp, images: nil)?.elementID, id(1))
        t.equal(try preset.activateContainerWithEffects(id(1), expectedGeneration: scene.generation,
            environment: environment, measure: measure)?.effects, [.copy("target")])
    }

    t.suite("Program: container clicks: identity demand includes only the chosen primary actions and normal projection") {
        let child = ProgramElement(id: id(1), content: .rectangle(fill: .literal(.clear)), width: .fixed(40), height: .fixed(30),
            onClickActions: [.copy(.concatenate([.systemProperty(.batteryLevel)]))])
        let text = ProgramElement(id: id(2), content: .text(ProgramText(value: .concatenate([.systemProperty(.cpuCoreCount)]))))
        let root = ProgramElement(id: id(0), content: .row(spacing: 0, align: .top, children: [child, text]),
            onClickActions: [.copy(.declaration(1))], onRightClickActions: [.copy(.concatenate([.systemProperty(.cpuUsage)]))])
        var value = try runtime(root, declarations: [
            ProgramDeclaration(name: "frozen", kind: .variable, initial: .systemProperty(.cpuUsage)),
            ProgramDeclaration(name: "argument", kind: .computed, initial: .concatenate([.systemProperty(.memoryUsed)]))
        ])
        t.equal(value.neededSystemProperties, [.cpuUsage, .cpuCoreCount])
        t.equal(value.neededSystemProperties(activatingContainer: id(0)), [])
        let input = ProgramSystemInput(cpuUsage: 25, cpuCoreCount: 8, memoryUsed: 1024, batteryLevel: 90)
        _ = try value.project(environment: environment, systemInput: input, measure: measure)
        t.equal(value.neededSystemProperties, [.cpuCoreCount])
        t.equal(value.neededSystemProperties(activatingContainer: id(0)), [.memoryUsed, .cpuCoreCount])
        t.equal(value.neededSystemProperties(clickAt: SkinPoint(x: 10, y: 10)), [.batteryLevel, .cpuCoreCount])
        t.equal(value.neededSystemProperties(clickAt: SkinPoint(x: 10, y: 10), event: .rightUp), [.cpuUsage, .cpuCoreCount])
        t.equal(value.neededSystemProperties(activatingContainer: id(1)), [])
        let result = try value.activateContainerWithEffects(id(0), expectedGeneration: value.generation,
            environment: environment, systemInput: input, measure: measure)
        t.equal(result?.effects.count, 1); t.equal(result.map { texts($0.scene) }, ["8"])
        t.equal(value.clockPrecision, nil, "an action-only data source does not retain a display timer")
    }

    t.suite("Program: container clicks: identity and pointer share ordered effects and transactional rollback") {
        let text = ProgramElement(id: id(1), content: .text(ProgramText(value: .declaration(0))))
        let root = ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [text]),
            padding: SkinInsets(left: 4, top: 4, right: 4, bottom: 4),
            onClickActions: [.assign(ProgramAssignment(declaration: 0, value: .string("On"))), .copy(.declaration(0)),
                            .open(.formatDate(.timeNow, .pattern("HH:mm:ss")))], voiceOver: .declaration(0))
        var value = try runtime(root, declarations: [ProgramDeclaration(name: "caption", kind: .variable, initial: .string("Off"))])
        let first = try value.project(environment: environment, measure: measure)
        failure(.invalidDateInput) {
            _ = try value.activateContainerWithEffects(id(0), expectedGeneration: first.generation,
                environment: environment, measure: measure)
        }
        t.equal(value.generation, first.generation)
        failure(.invalidMeasurement(id(1))) {
            _ = try value.activateContainerWithEffects(id(0), expectedGeneration: first.generation,
                environment: environment, dateInput: date()) { text, _, _ in
                    text == "On" ? SkinSize(width: -1, height: 8) : SkinSize(width: 12, height: 8)
                }
        }
        t.equal(value.generation, first.generation)
        let unchanged = try value.project(environment: environment, measure: measure)
        t.equal(texts(unchanged), ["Off"]); t.equal(unchanged.elements.first?.accessibilityLabel, "Off")
        t.equal(unchanged.hitMap, first.hitMap)
        var pointer = value
        let activated = try value.activateContainerWithEffects(id(0), expectedGeneration: unchanged.generation,
            environment: environment, dateInput: date(), measure: measure)
        let clicked = try pointer.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: unchanged.generation,
            environment: environment, dateInput: date(), measure: measure)
        t.equal(activated?.effects, [.copy("On"), .open("00:00:00")]); t.equal(activated?.effects, clicked?.effects)
        t.equal(activated.map { texts($0.scene) }, ["On"]); t.equal(activated.map { texts($0.scene) }, clicked.map { texts($0.scene) })
        t.equal(activated?.scene.elements.first?.accessibilityLabel, "On")
        t.equal(activated?.scene.hitMap, clicked?.scene.hitMap); t.equal(value.generation, pointer.generation)
        t.equal(value.clockPrecision, nil)
    }

    t.suite("Program: container clicks: identity projection keeps new icon resources inside the action transaction") {
        let icon = ProgramElement(id: id(2), content: .icon(ProgramIcon(name: .string("next"))), width: .fixed(20), height: .fixed(20))
        let selection = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .declaration(0), body: [icon])
        ])))
        let root = ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [selection]),
            width: .fixed(40), height: .fixed(30), onClickActions: [
                .assign(ProgramAssignment(declaration: 0, value: .boolean(true))), .copy(.string("ready"))
            ])
        var value = try runtime(root, declarations: [ProgramDeclaration(name: "show", kind: .variable, initial: .boolean(false))])
        let first = try value.project(environment: environment, measure: measure)
        t.equal(first.elements.map(\.id), [id(0)])
        failure(.missingIconMeasurement(id(2))) {
            _ = try value.activateContainerWithEffects(id(0), expectedGeneration: first.generation,
                environment: environment, measure: measure)
        }
        t.equal(value.generation, first.generation)
        failure(.invalidMeasurement(id(2))) {
            _ = try value.activateContainerWithEffects(id(0), expectedGeneration: first.generation,
                environment: environment, measureIcon: { _ in SkinSize(width: .nan, height: 10) }, measure: measure)
        }
        t.equal(value.generation, first.generation)
        let retained = try value.project(environment: environment, measure: measure)
        t.equal(retained.elements.map(\.id), [id(0)])
        var names: [String] = []
        let result = try value.activateContainerWithEffects(id(0), expectedGeneration: retained.generation,
            environment: environment, measureIcon: { request in names.append(request.name); return SkinSize(width: 10, height: 10) },
            measure: measure)
        t.equal(names, ["next"]); t.equal(result?.effects, [.copy("ready")])
        t.equal(result?.scene.elements.map(\.id), [id(0), id(2)])
    }

    t.suite("Program: container clicks: empty handlers do not bypass action validation or shared budgets") {
        let content = ProgramElement.Content.column(spacing: 0, align: .left, children: [])
        failure(.ambiguousClickHandler(id(0))) {
            _ = try runtime(ProgramElement(id: id(0), content: content, onClick: [], onClickActions: []))
        }
        for actions in [[ProgramAction.copy(.number(1))], [.open(.boolean(true))]] {
            failure(.invalidExpression) {
                _ = try runtime(ProgramElement(id: id(0), content: content, hidden: true, onRightClickActions: actions))
            }
        }
        let action = ProgramAction.copy(.string("request"))
        let accepted = ProgramElement(id: id(0), content: content, width: .fixed(40), height: .fixed(30),
            onClickActions: Array(repeating: action, count: ProgramLimits.maximumExpressions - 1), onRightClickActions: [action])
        _ = try runtime(accepted); t.check(true, "both events fit the shared expression limit exactly")
        failure(.expressionLimit) {
            _ = try runtime(ProgramElement(id: id(0), content: content,
                onClickActions: Array(repeating: action, count: ProgramLimits.maximumExpressions), onRightClickActions: [action]))
        }
        let invalid = ProgramElement(id: id(2), content: content, onClickActions: [.copy(.number(1))])
        let inactive = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .boolean(false), body: [invalid])
        ])))
        failure(.invalidExpression) {
            _ = try runtime(ProgramElement(id: id(0), content: .row(spacing: 0, align: .top, children: [inactive]), onClickActions: []))
        }
    }
}
