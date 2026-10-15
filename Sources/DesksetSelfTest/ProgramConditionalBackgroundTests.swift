import Foundation
@testable import DesksetCore

func runProgramConditionalBackgroundTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "conditional-backgrounds"), imageGeneration: 0)
    let red = RGBA(r: 220, g: 30, b: 40), blue = RGBA(r: 20, g: 60, b: 210), green = RGBA(r: 20, g: 180, b: 50)
    let cpu = ProgramExpression.greater(.systemProperty(.cpuUsage), .quantity(ProgramNumber(50, dimension: .percent)))
    let clock = ProgramExpression.equal(.timeNow, .timeNow)
    let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!,
                                locale: Locale(identifier: "en_US_POSIX"))
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { _, _, _ in SkinSize(width: 12, height: 8) }
    func id(_ n: Int = 0) -> ElementID { ElementID(name: "background:\(n)", index: n) }
    func box(_ background: ProgramBackground?, hidden: Bool = false, width: Double = 40,
             condition: ProgramExpression? = nil) -> ProgramElement {
        ProgramElement(id: id(), content: .freeform(align: .topLeft, children: []), width: .fixed(width), height: .fixed(30),
                       hidden: hidden, background: background, hiddenIf: condition)
    }
    func runtime(_ root: ProgramElement, declarations: [ProgramDeclaration] = [],
                 size: ProgramWidgetSize = .fit) throws -> ProgramRuntime {
        try ProgramRuntime(program: WidgetProgram(name: "Conditional backgrounds", root: root, declarations: declarations, size: size))
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }

    t.suite("Program: conditional backgrounds: absent solid and glass choices preserve the same box input and accessibility") {
        let background = ProgramBackground.conditional(.systemProperty(.batteryCharging),
            then: .glass(style: .regular, tint: .literal(red)), otherwise:
                .conditional(.systemProperty(.batteryPluggedIn), then: .glass(style: .clear), otherwise:
                    .conditional(cpu, then: .color(.literal(.clear)), otherwise: nil)))
        let root = ProgramElement(id: id(), content: .freeform(align: .topLeft, children: []),
            width: .fixed(40), height: .fixed(30), cornerRadius: .points(5), onClickActions: [.copy(.string("box"))],
            background: background, voiceOver: .string("box label"), tooltip: ProgramTooltip(text: .string("box tip")))
        var value = try runtime(root)
        let regular = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        let clear = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryPluggedIn: true), measure: measure)
        let solid = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: 75), measure: measure)
        let absent = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: 25), measure: measure)
        guard let region = regular.elements[0].glass, let clearRegion = clear.elements[0].glass else {
            return t.check(false, "both glass choices produce a native region")
        }
        t.equal(region.style, .regular); t.equal(region.tint, red); t.equal(region.cornerRadius, 5)
        t.equal(clearRegion.style, .clear); t.equal(clearRegion.tint, nil); t.equal(clearRegion.id, region.id)
        for scene in [regular, clear, solid, absent] {
            t.equal(scene.elements.count, 1); t.equal(scene.elements[0].id, id())
            t.equal(scene.elements[0].frame, SkinRect(width: 40, height: 30))
            t.equal(scene.elements[0].visibility, .visible); t.equal(scene.elements[0].accessibilityLabel, "box label")
            t.equal(scene.hitMap, regular.hitMap); t.check(scene.background.isEmpty && scene.glass.isEmpty)
        }
        t.equal(solid.elements[0].backing, .content); t.equal(solid.elements[0].glass, nil)
        guard case .shape(let solidDraw)? = solid.elements[0].items.first else {
            return t.check(false, "transparent rounded color remains a solid paint item")
        }
        t.equal(solidDraw.shapes.first?.fill, .color(.clear))
        t.equal(absent.elements[0].backing, .content); t.equal(absent.elements[0].glass, nil)
        t.check(absent.drawingItems.isEmpty, "no selected background is not a transparent filler")
        t.equal(absent.hitMap.entry(at: 10, 10, handling: .leftUp, images: nil)?.elementID, id())
        t.equal(absent.hitMap.entry(at: 0, 0, handling: .leftUp, images: nil)?.elementID, nil)
        let clicked = try value.clickWithEffects(at: SkinPoint(x: 10, y: 10), expectedGeneration: absent.generation,
            environment: environment, systemInput: ProgramSystemInput(cpuUsage: 25), measure: measure)
        t.equal(clicked?.effects, [.copy("box")]); t.check(clicked?.scene.drawingItems.isEmpty == true)
        let restored = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(restored.elements[0].glass, region)
        t.equal(regular.elements[0].glass, region, "later projections never rewrite an earlier scene")
    }

    t.suite("Program: conditional backgrounds: source order negative origins and preset fitting transform the selected paint once") {
        let first = ProgramElement(id: id(1), content: .rectangle(fill: .literal(blue)), width: .fixed(200), height: .fixed(200),
                                   position: ProgramPosition(x: -100, y: -100))
        let middle = ProgramElement(id: id(2), content: .text(ProgramText("A")), width: .fixed(200), height: .fixed(200),
            padding: SkinInsets(left: 10, top: 10, right: 10, bottom: 10), cornerRadius: .points(20),
            onClickActions: [.copy(.string("middle"))], position: ProgramPosition(x: -100, y: -100),
            background: .conditional(.systemProperty(.batteryCharging), then: .glass(style: .clear), otherwise: nil),
            voiceOver: .string("middle label"))
        let last = ProgramElement(id: id(3), content: .rectangle(fill: .literal(green)), width: .fixed(10), height: .fixed(10),
                                  position: ProgramPosition(x: 80, y: 80))
        let root = ProgramElement(id: id(), content: .freeform(align: .topLeft, children: [first, middle, last]),
            width: .fixed(100), height: .fixed(100), cornerRadius: .points(30), background: .color(.literal(red)))
        var fit = try runtime(root)
        let raw = try fit.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(raw.elements[2].glass?.rect, SkinRect(x: -100, y: -100, width: 200, height: 200))
        t.equal(raw.elements[2].glass?.cornerRadius, 20)
        var preset = try runtime(root, size: .preset(.small, size: SkinSize(width: 100, height: 100)))
        let shown = try preset.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        let absent = try preset.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: measure)
        let matrix = ShapeTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 50, ty: 50)
        guard let region = shown.elements[2].glass,
              case .transformed(let transform, let items)? = shown.elements[2].items.first,
              case .text(let text)? = items.first else { return t.check(false, "one final bitmap matrix and native region") }
        t.equal(transform, matrix); t.equal(text.frame, SkinRect(x: -100, y: -100, width: 200, height: 200))
        t.equal(region.rect, SkinRect(width: 100, height: 100)); t.equal(region.cornerRadius, 10)
        t.equal(shown.elements.map(\.id), [0, 1, 2, 3].map(id))
        t.equal(shown.elements.map(\.frame), absent.elements.map(\.frame)); t.equal(shown.hitMap, absent.hitMap)
        t.equal(shown.elements[2].accessibilityLabel, "middle label"); t.equal(absent.elements[2].accessibilityLabel, "middle label")
        t.equal(absent.elements[2].glass, nil); t.equal(absent.elements[2].backing, .content)
        t.equal(shown.drawingItems, shown.elements[0].items + shown.elements[1].items + [.glass(region)]
            + shown.elements[2].items + shown.elements[3].items, "glass follows preceding bitmap and precedes its content and later siblings")
        t.equal(absent.drawingItems, absent.elements.flatMap(\.items))
        t.equal(shown.hitMap.entry(at: 0, 0, handling: .leftUp, images: nil)?.elementID, nil)
        t.equal(shown.hitMap.entry(at: 2, 50, handling: .leftUp, images: nil)?.elementID, id(2))
    }

    t.suite("Program: conditional backgrounds: lazy three valued selection retains only evaluated clocks and conservative data demand") {
        let battery = ProgramExpression.greater(.systemProperty(.batteryLevel), .quantity(ProgramNumber(50, dimension: .percent)))
        let background = ProgramBackground.conditional(.systemProperty(.batteryCharging), then: .color(.literal(red)), otherwise:
            .conditional(cpu, then: .glass(style: .regular, tint: .conditional(battery, then: .literal(blue), otherwise: .literal(green))), otherwise: nil))
        var value = try runtime(box(background))
        t.equal(value.neededSystemProperties, [.batteryCharging, .cpuUsage, .batteryLevel])
        let first = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(first.drawingItems, [.fill(SkinRect(width: 40, height: 30), Paint(color: red))]); t.equal(value.clockPrecision, nil)
        let missing = try value.project(environment: environment, systemInput: ProgramSystemInput(), measure: measure)
        t.check(missing.drawingItems.isEmpty); t.equal(value.clockPrecision, .second)
        t.equal(value.neededSystemProperties, [.batteryCharging, .cpuUsage, .batteryLevel], "sampling remains a potential-arm union")
        let glass = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: 75, batteryLevel: 75), measure: measure)
        t.equal(glass.elements[0].glass?.tint, blue); t.equal(value.clockPrecision, .second)

        let unknown = ProgramExpression.greater(.systemProperty(.cpuCoreCount), .number(0))
        let cases: [(ProgramExpression, Bool, ProgramClockPrecision?)] = [
            (.and(unknown, .boolean(false)), false, nil), (.and(.boolean(false), clock), false, nil),
            (.and(unknown, clock), false, .second), (.not(.and(unknown, .boolean(false))), true, nil),
            (.or(unknown, .boolean(true)), true, nil)
        ]
        for (condition, painted, precision) in cases {
            var selected = try runtime(box(.conditional(condition, then: .glass(style: .regular), otherwise: nil)))
            let scene = try selected.project(environment: environment, dateInput: precision == nil ? nil : date,
                                             systemInput: ProgramSystemInput(), measure: measure)
            t.equal(scene.elements[0].glass != nil, painted); t.equal(selected.clockPrecision, precision)
        }
        var tinted = try runtime(box(.conditional(.systemProperty(.batteryCharging), then: .color(.literal(red)), otherwise:
            .glass(style: .regular, tint: .conditional(clock, then: .literal(blue), otherwise: .palette(.red))))))
        _ = try tinted.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(tinted.clockPrecision, nil, "a solid winner never evaluates the glass tint's clock or palette")
        failure(.invalidDateInput) { _ = try tinted.project(environment: environment, measure: measure) }
        let tintedGlass = try tinted.project(environment: environment, dateInput: date, measure: measure)
        t.equal(tintedGlass.elements[0].glass?.tint, blue); t.equal(tinted.clockPrecision, .second)
    }

    t.suite("Program: conditional backgrounds: hidden inactive and zero boxes preserve visibility and potential content rules") {
        let background = ProgramBackground.conditional(clock,
            then: .glass(style: .regular, tint: .conditional(cpu, then: .literal(red), otherwise: .literal(blue))), otherwise: nil)
        let child = ProgramElement(id: id(1), content: .text(ProgramText("kept")), width: .fixed(40), height: .fixed(30), background: background)
        let parent = ProgramElement(id: id(), content: .column(spacing: 0, align: .left, children: [child]), hidden: true)
        var hidden = try runtime(parent)
        var measurements = 0
        let hiddenScene = try hidden.project(environment: environment) { _, _, _ in
            measurements += 1; return SkinSize(width: 12, height: 8)
        }
        t.check(measurements > 0, "hidden text still measures its retained slot")
        t.equal(hidden.neededSystemProperties, []); t.equal(hidden.clockPrecision, nil)
        t.check(hiddenScene.drawingItems.isEmpty); t.equal(hiddenScene.size, SkinSize(width: 40, height: 30))
        var dynamic = try runtime(box(background, condition: .systemProperty(.batteryCharging)))
        t.equal(dynamic.neededSystemProperties, [.batteryCharging, .cpuUsage])
        t.check(try dynamic.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure).drawingItems.isEmpty)
        t.equal(dynamic.clockPrecision, nil)
        let restored = try dynamic.project(environment: environment, dateInput: date,
            systemInput: ProgramSystemInput(cpuUsage: 75, batteryCharging: false), measure: measure)
        t.equal(restored.elements[0].glass?.tint, red); t.equal(dynamic.clockPrecision, .second)

        let gate = ProgramElement(id: id(2), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .systemProperty(.batteryCharging), body: [child])
        ])))
        var branched = try runtime(ProgramElement(id: id(), content: .column(spacing: 0, align: .left, children: [gate])))
        t.equal(branched.neededSystemProperties, [.batteryCharging, .cpuUsage])
        let inactive = try branched.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: measure)
        t.equal(inactive.elements.map(\.id), [id()]); t.equal(branched.clockPrecision, nil)
        t.check(inactive.drawingItems.isEmpty)
        var zero = try runtime(box(background, width: 0))
        let zeroScene = try zero.project(environment: environment, dateInput: date, systemInput: ProgramSystemInput(cpuUsage: 75), measure: measure)
        t.check(zeroScene.drawingItems.isEmpty && zeroScene.hitMap.entries.isEmpty)
        t.equal(zeroScene.elements[0].glass, nil); t.equal(zero.clockPrecision, .second, "visible zero-area paints still resolve")
        var potential = try runtime(box(.conditional(.boolean(false), then: .glass(style: .regular), otherwise: nil)))
        t.check(try potential.project(environment: environment, measure: measure).drawingItems.isEmpty)
        let emptyChoices: [ProgramBackground?] = [nil, .conditional(.boolean(true), then: nil, otherwise: nil),
            .conditional(.boolean(false), then: nil, otherwise: .conditional(.boolean(true), then: nil, otherwise: nil))]
        for absent in emptyChoices {
            failure(.emptyProgram) { _ = try runtime(box(absent)) }
        }
        let decorated = ProgramElement(id: id(2), content: gate.content,
            background: .conditional(.boolean(false), then: .glass(style: .regular), otherwise: nil))
        failure(.invalidGeometry(id(2))) {
            _ = try runtime(ProgramElement(id: id(), content: .column(spacing: 0, align: .left, children: [decorated])))
        }
    }

    t.suite("Program: conditional backgrounds: failed selected paint and later measurement roll back options variables and effects") {
        let enabled = ProgramExpression.or(.option("glass"), .declaration(0))
        let background = ProgramBackground.conditional(enabled, then: .glass(style: .regular, tint: .palette(.red)), otherwise: .color(.literal(blue)))
        let label = ProgramExpression.concatenate([.conditional(.declaration(0), then: .string("yes "), otherwise: .string("no ")), .declaration(1)])
        let root = ProgramElement(id: id(), content: .text(ProgramText("A")), width: .fixed(40), height: .fixed(30),
            onClickActions: [.assign(ProgramAssignment(declaration: 0, value: .boolean(true))),
                            .assignOption(name: "glass", value: .boolean(true)), .copy(.concatenate([.string("load "), .declaration(1)]))],
            background: background, voiceOver: label)
        let program = WidgetProgram(name: "Rollback", root: root, declarations: [
            ProgramDeclaration(name: "clicked", kind: .variable, initial: .boolean(false)),
            ProgramDeclaration(name: "loads", kind: .variable, initial: .number(0))
        ], onLoad: [ProgramAssignment(declaration: 1, value: .add(.declaration(1), .number(1)))], options: [
            .option(ProgramOption(name: "glass", title: .string("Glass"), control: .toggle, defaultValue: .boolean(false)))
        ])
        var value = try ProgramRuntime(program: program)
        let first = try value.project(environment: environment, measure: measure)
        t.equal(first.elements[0].accessibilityLabel, "no 1")
        let originalOptions = value.optionValues, originalRevision = value.optionsRevision
        let changed = ProgramOptionsInput(values: ["glass": .boolean(true)])
        failure(.missingColorInput(.red)) {
            _ = try value.clickWithEffects(at: SkinPoint(x: 10, y: 10), expectedGeneration: first.generation,
                environment: environment, measure: measure)
        }
        t.equal(value.generation, first.generation); t.equal(value.optionValues, originalOptions); t.equal(value.optionsRevision, originalRevision)
        failure(.missingColorInput(.red)) {
            _ = try value.updateOptions(changed, expectedRevision: originalRevision, environment: environment, measure: measure)
        }
        let palette = ProgramColorInput(colors: Dictionary(uniqueKeysWithValues: ProgramPaletteColor.allCases.map { ($0, red) }))
        failure(.invalidMeasurement(id())) {
            _ = try value.updateOptions(changed, expectedRevision: originalRevision, environment: environment, colorInput: palette) { _, _, _ in
                throw ProgramRuntimeError.invalidMeasurement(id())
            }
        }
        t.equal(value.generation, first.generation); t.equal(value.optionValues, originalOptions); t.equal(value.optionsRevision, originalRevision)
        t.equal(value.clockPrecision, nil)
        let retried = try value.project(environment: environment, measure: measure)
        t.equal(retried.elements[0].accessibilityLabel, "no 1"); t.equal(retried.hitMap, first.hitMap)
        t.equal(retried.elements[0].glass, nil)
        let accepted = try value.updateOptions(changed, expectedRevision: originalRevision,
            environment: environment, colorInput: palette, measure: measure)
        t.equal(accepted?.elements[0].glass?.tint, red); t.equal(accepted?.elements[0].accessibilityLabel, "no 1")
        t.equal(value.optionsRevision, originalRevision + 1)
        let clicked = try value.clickWithEffects(at: SkinPoint(x: 10, y: 10), expectedGeneration: value.generation,
            environment: environment, colorInput: palette, measure: measure)
        t.equal(clicked?.effects, [.copy("load 1")]); t.equal(clicked?.scene.elements[0].accessibilityLabel, "yes 1")
        t.equal(value.optionsRevision, originalRevision + 1, "assigning an unchanged option does not invent a revision")
        let generation = value.generation
        t.equal(try value.updateOptions(originalOptions, expectedRevision: originalRevision,
            environment: environment, measure: measure), nil)
        t.equal(value.generation, generation); t.equal(value.optionValues, changed)
    }

    t.suite("Program: conditional backgrounds: all arms share expression budgets and combined background color declaration depth") {
        for hidden in [false, true] {
            for bad in [ProgramExpression.number(1), .string("true"), .timeNow] {
                failure(.invalidExpression) { _ = try runtime(box(.conditional(.boolean(false),
                    then: .conditional(bad, then: .glass(style: .regular), otherwise: nil), otherwise: .color(.literal(red))), hidden: hidden)) }
            }
            for bad in [RGBA(r: .nan, g: 0, b: 0), RGBA(r: .infinity, g: 0, b: 0),
                        RGBA(r: -1, g: 0, b: 0), RGBA(r: 0, g: 0, b: 0, a: 256)] {
                for leaf in [ProgramBackground.color(.literal(bad)), .glass(style: .clear, tint: .literal(bad))] {
                    failure(.invalidPaint(id())) { _ = try runtime(box(.conditional(.boolean(false), then: leaf,
                        otherwise: .color(.literal(blue))), hidden: hidden)) }
                }
            }
        }
        failure(.invalidDeclaration(99)) { _ = try runtime(box(.conditional(.declaration(99), then: .glass(style: .regular), otherwise: nil))) }
        var deep = ProgramBackground.glass(style: .regular)
        for _ in 0..<(ProgramLimits.maximumExpressionDepth - 1) {
            deep = .conditional(.boolean(false), then: nil, otherwise: deep)
        }
        var valid = try runtime(box(deep))
        t.equal(try valid.project(environment: environment, measure: measure).elements[0].glass?.style, .regular)
        failure(.expressionDepth) { _ = try runtime(box(.conditional(.boolean(true), then: nil, otherwise: deep))) }
        let declarations = (0..<64).map { index in
            ProgramDeclaration(name: "b\(index)", kind: .computed, initial: index == 0 ? .boolean(true) : .declaration(index - 1))
        }
        var color = ProgramColor.conditional(.declaration(63), then: .literal(red), otherwise: .literal(blue))
        for _ in 0..<32 { color = .conditional(.boolean(false), then: .literal(blue), otherwise: color) }
        var mixed = ProgramBackground.glass(style: .regular, tint: color)
        for _ in 0..<30 { mixed = .conditional(.boolean(false), then: nil, otherwise: mixed) }
        // 30 background selectors + 33 color selectors + the Bool reference's expanded height of 65 = 128.
        var boundary = try runtime(box(mixed), declarations: declarations)
        t.equal(try boundary.project(environment: environment, measure: measure).elements[0].glass?.tint, red)
        failure(.expressionDepth) { _ = try runtime(box(.conditional(.boolean(true), then: nil, otherwise: mixed)), declarations: declarations) }

        func budget(_ count: Int, _ background: ProgramBackground) -> ProgramElement {
            ProgramElement(id: id(), content: .text(ProgramText(value: .concatenate(Array(repeating: .string("a"), count: count)))),
                           hidden: true, background: background)
        }
        for leaf in [ProgramBackground.color(.literal(red)), .glass(style: .regular), .glass(style: .clear, tint: .literal(blue))] {
            _ = try runtime(budget(ProgramLimits.maximumExpressions - 1, leaf))
        }
        let combined = ProgramBackground.conditional(.boolean(true),
            then: .color(.conditional(.boolean(true), then: .literal(red), otherwise: .literal(blue))), otherwise: nil)
        _ = try runtime(budget(ProgramLimits.maximumExpressions - 5, combined))
        failure(.expressionLimit) { _ = try runtime(budget(ProgramLimits.maximumExpressions - 4, combined)) }
        func wide(_ depth: Int) -> ProgramBackground {
            guard depth > 0 else { return .glass(style: .regular) }
            let child = wide(depth - 1)
            return .conditional(.boolean(true), then: child, otherwise: child)
        }
        _ = try runtime(box(wide(11)))
        failure(.expressionLimit) { _ = try runtime(box(wide(12))) }
    }
}
