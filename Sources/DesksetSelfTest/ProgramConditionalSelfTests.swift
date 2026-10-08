import Foundation
@testable import DesksetCore

func runProgramConditionalSelfTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "conditions"), imageGeneration: 0)
    let red = RGBA(r: 210, g: 20, b: 40), blue = RGBA(r: 20, g: 60, b: 210), green = RGBA(r: 20, g: 190, b: 50)
    let cpu = ProgramExpression.greater(.systemProperty(.cpuUsage), .quantity(ProgramNumber(50, dimension: .percent)))
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { _, _, _ in SkinSize(width: 12, height: 14) }
    func id(_ n: Int) -> ElementID { ElementID(name: "condition-\(n)", index: n) }
    func date(_ seconds: Double) -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!,
                         locale: Locale(identifier: "en_US_POSIX"))
    }
    func box(_ n: Int = 0, hidden: Bool = false, condition: ProgramExpression? = nil,
             color: ProgramColor = .literal(.white), actions: [ProgramAction]? = nil,
             label: ProgramExpression? = nil) -> ProgramElement {
        ProgramElement(id: id(n), content: .rectangle(fill: color), width: .fixed(40), height: .fixed(30),
            hidden: hidden, onClickActions: actions, voiceOver: label, hiddenIf: condition)
    }
    func runtime(_ root: ProgramElement, declarations: [ProgramDeclaration] = [], size: ProgramWidgetSize = .fit) throws -> ProgramRuntime {
        try ProgramRuntime(program: WidgetProgram(name: "Conditions", root: root, declarations: declarations, size: size))
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }
    func flattened(_ items: [DrawItem]) -> [DrawItem] {
        items.flatMap { item in
            switch item {
            case .transformed(_, let children), .antialias(_, let children): return flattened(children)
            case .container(_, let mask, let content): return flattened(mask) + flattened(content)
            default: return [item]
            }
        }
    }
    func fills(_ items: [DrawItem]) -> [RGBA] {
        flattened(items).compactMap { item in
            switch item {
            case .fill(_, let paint): return paint.color
            case .text(let text): return text.style.color
            case .icon(let icon): return icon.request.style.color
            case .roundline(let draw): return draw.color
            case .bar(let draw): return draw.color
            default: return nil
            }
        }
    }

    t.suite("Program: conditions: dynamic hiding preserves every supported layout slot and removes paint hits and labels") {
        let resource = ProgramImageResource(path: "/fixture/conditional.png", naturalSize: SkinSize(width: 9, height: 11),
            stamp: ImageStamp(seconds: 1, nanoseconds: 0, size: 12, inode: 3))
        let children: [ProgramElement] = [
            ProgramElement(id: id(1), content: .text(ProgramText("text")), voiceOver: .string("text label")),
            ProgramElement(id: id(2), content: .icon(ProgramIcon(name: .string("symbol"))), voiceOver: .string("icon label")),
            ProgramElement(id: id(3), content: .image(ProgramImage(source: "image"))),
            ProgramElement(id: id(4), content: .progress(ProgramProgress(value: .number(0.5))), width: .fixed(30), height: .fixed(5)),
            ProgramElement(id: id(5), content: .gauge(ProgramGauge(value: .number(0.5))), width: .fixed(30), height: .fixed(30)),
            ProgramElement(id: id(6), content: .shape(kind: .circle, fill: .literal(red)), width: .fixed(10), height: .fixed(12)),
            ProgramElement(id: id(7), content: .spacer(minimum: 4)),
            box(8, actions: [.copy(.string("child"))], label: .string("child")),
            ProgramElement(id: id(9), content: .row(spacing: 0, align: .top, children: [box(10)])),
            ProgramElement(id: id(11), content: .freeform(align: .topLeft, children: [box(12)]))
        ]
        let root = ProgramElement(id: id(0), content: .column(spacing: 2, align: .left, children: children),
            onClickActions: [.copy(.string("root"))], background: .glass(style: .regular),
            voiceOver: .string("group"), hiddenIf: .systemProperty(.batteryCharging))
        var value = try runtime(root)
        var textCalls = 0, iconCalls = 0
        let text: (String, TextStyle, Double?) throws -> SkinSize = { _, _, _ in textCalls += 1; return SkinSize(width: 12, height: 14) }
        let icon: (IconRequest) throws -> SkinSize? = { _ in iconCalls += 1; return SkinSize(width: 20, height: 10) }
        let first = try value.project(environment: environment, images: ["image": resource],
            systemInput: ProgramSystemInput(batteryCharging: false), measureIcon: icon, measure: text)
        let hidden = try value.project(environment: environment, images: ["image": resource],
            systemInput: ProgramSystemInput(batteryCharging: true), measureIcon: icon, measure: text)
        t.equal(first.size, hidden.size); t.equal(first.elements.map(\.frame), hidden.elements.map(\.frame))
        t.equal(textCalls, 2); t.equal(iconCalls, 2, "hidden native content still measures")
        t.check(hidden.elements.allSatisfy { $0.visibility == .hiddenKeepsSpace && $0.items.isEmpty && $0.glass == nil })
        t.check(hidden.elements.allSatisfy { $0.accessibilityLabel == nil && $0.imageDependencies.isEmpty })
        t.check(hidden.drawingItems.isEmpty && hidden.hitMap.entries.isEmpty)
        t.check(!first.drawingItems.isEmpty && !first.hitMap.entries.isEmpty)
        t.equal(value.clockPrecision, nil, "event-only visibility does not invent a polling clock")
        let restored = try value.project(environment: environment, images: ["image": resource],
            systemInput: ProgramSystemInput(batteryCharging: false), measureIcon: icon, measure: text)
        t.equal(restored.elements.map(\.frame), first.elements.map(\.frame))
        t.equal(restored.hitMap, first.hitMap); t.equal(restored.elements.map(\.accessibilityLabel), first.elements.map(\.accessibilityLabel))
        t.equal(box().hiddenIf, nil)
    }

    t.suite("Program: conditions: hiding retains its recovery clock while a hidden ancestor suppresses descendant display clocks") {
        let memory = ProgramExpression.greater(.systemProperty(.memoryUsage), .quantity(ProgramNumber(50, dimension: .percent)))
        let child = ProgramElement(id: id(1), content: .gauge(ProgramGauge(value: .systemProperty(.cpuUsage))),
            width: .fixed(30), height: .fixed(30), voiceOver: .formatDate(.timeNow, .pattern("HH:mm:ss")), hiddenIf: cpu)
        let root = ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [child]), hiddenIf: memory)
        var value = try runtime(root)
        t.equal(value.neededSystemProperties, [.memoryUsage, .cpuUsage])
        let hidden = try value.project(environment: environment,
            systemInput: ProgramSystemInput(cpuUsage: 25, memoryUsed: 75, memoryTotal: 100), measure: measure)
        t.check(hidden.elements.allSatisfy { $0.visibility == .hiddenKeepsSpace })
        t.equal(value.clockPrecision, .twoSeconds, "the parent's true condition remains live, without the child's date input")
        let shown = try value.project(environment: environment, dateInput: date(0),
            systemInput: ProgramSystemInput(cpuUsage: 25, memoryUsed: 25, memoryTotal: 100), measure: measure)
        t.equal(shown.elements[1].visibility, .visible); t.equal(value.clockPrecision, .second)
        _ = try value.project(environment: environment,
            systemInput: ProgramSystemInput(cpuUsage: 75, memoryUsed: 25, memoryTotal: 100), measure: measure)
        t.equal(value.clockPrecision, .second, "the child's own true condition keeps its recovery cadence")
        _ = try value.project(environment: environment,
            systemInput: ProgramSystemInput(cpuUsage: 25, memoryUsed: 75, memoryTotal: 100), measure: measure)
        t.equal(value.clockPrecision, .twoSeconds, "hiding again releases the earlier child display demand")
        let impossibleDate = ProgramExpression.equal(.timeNow, .timeNow)
        var staticHidden = try runtime(box(hidden: true, condition: impossibleDate, color:
            .conditional(impossibleDate, then: .literal(red), otherwise: .literal(blue)), label: .formatDate(.timeNow, .pattern("HH:mm:ss"))))
        t.equal(staticHidden.neededSystemProperties, [])
        t.check(try staticHidden.project(environment: environment, measure: measure).drawingItems.isEmpty)
        t.equal(staticHidden.clockPrecision, nil)
        let sameSecond = ProgramExpression.equal(.formatDate(.timeNow, .pattern("ss")), .string("00"))
        var dated = try runtime(box(condition: sameSecond))
        t.equal(try dated.project(environment: environment, dateInput: date(0), measure: measure).elements[0].visibility, .hiddenKeepsSpace)
        t.equal(dated.clockPrecision, .second)
        t.equal(try dated.project(environment: environment, dateInput: date(1), measure: measure).elements[0].visibility, .visible)
        t.equal(dated.clockPrecision, .second)
    }

    t.suite("Program: conditions: missing Bool logic becomes false only at visibility and color selection boundaries") {
        let cases: [(ProgramExpression, Bool)] = [
            (cpu, false), (.not(cpu), false), (.or(cpu, .boolean(true)), true),
            (.and(cpu, .boolean(false)), false), (.not(.and(cpu, .boolean(false))), true),
            (.not(.or(cpu, .boolean(true))), false), (.isMissing(cpu), true), (.ifMissing(cpu, .boolean(true)), true)
        ]
        for (condition, expected) in cases {
            var hidden = try runtime(box(condition: condition))
            let scene = try hidden.project(environment: environment, systemInput: ProgramSystemInput(), measure: measure)
            t.equal(scene.elements[0].visibility, expected ? .hiddenKeepsSpace : .visible)
            t.equal(hidden.clockPrecision, .second, "missing live input still has a recovery cadence")
            var colored = try runtime(box(color: .conditional(condition, then: .literal(red), otherwise: .literal(blue))))
            let paint = try colored.project(environment: environment, systemInput: ProgramSystemInput(), measure: measure)
            t.equal(fills(paint.drawingItems), [expected ? red : blue])
        }
        for condition in [ProgramExpression.and(.boolean(false), cpu), .or(.boolean(true), cpu)] {
            var value = try runtime(box(condition: condition))
            _ = try value.project(environment: environment, measure: measure)
            t.equal(value.clockPrecision, nil, "short-circuited live data does not create a timer")
        }
    }

    t.suite("Program: conditions: selected color chains preserve priority fallback palette and branch-local clocks") {
        let inherited = ProgramColor.conditional(cpu, then: .literal(red), otherwise: .literal(blue))
        let effective = ProgramColor.conditional(.systemProperty(.batteryCharging), then: .literal(green), otherwise: inherited)
        var value = try runtime(ProgramElement(id: id(0), content: .text(ProgramText("value", color: effective))))
        t.equal(value.neededSystemProperties, [.cpuUsage, .batteryCharging])
        for (charging, usage, expected, cadence) in [
            (true, 75.0, green, Optional<ProgramClockPrecision>.none),
            (false, 75.0, red, .second), (false, 25.0, blue, .second), (true, 25.0, green, nil)
        ] {
            let scene = try value.project(environment: environment,
                systemInput: ProgramSystemInput(cpuUsage: usage, batteryCharging: charging), measure: measure)
            t.equal(fills(scene.drawingItems), [expected]); t.equal(value.clockPrecision, cadence)
        }
        var ownBase = try runtime(ProgramElement(id: id(0), content: .text(ProgramText("own", color: .literal(green)))))
        t.equal(ownBase.neededSystemProperties, [])
        _ = try ownBase.project(environment: environment, measure: measure)
        t.equal(ownBase.clockPrecision, nil, "an overridden ancestor expression is absent from the lowered value")
        var lazy = try runtime(box(color: .conditional(.boolean(true), then: .literal(red),
            otherwise: .conditional(.equal(.timeNow, .timeNow), then: .palette(.pink), otherwise: .palette(.blue)))))
        t.equal(fills(try lazy.project(environment: environment, measure: measure).drawingItems), [red])
        t.equal(lazy.clockPrecision, nil, "unselected date and palette branches are not resolved")
        let palette = ProgramColorInput(colors: Dictionary(uniqueKeysWithValues: ProgramPaletteColor.allCases.map { ($0, green) }))
        var adaptive = try runtime(box(color: .conditional(.appearanceDark, then: .palette(.pink), otherwise: .text)))
        t.equal(fills(try adaptive.project(environment: environment, colorInput: palette, measure: measure).drawingItems), [green])
    }

    t.suite("Program: conditions: hidden Text and Icon measure real conditional colors without retaining display cadence") {
        let color = ProgramColor.conditional(.declaration(0), then: .literal(red), otherwise: .literal(blue))
        let declarations = [ProgramDeclaration(name: "hot", kind: .computed, initial: cpu)]
        func children(visible: Bool) -> [ProgramElement] {
            [ProgramElement(id: id(1), content: .text(ProgramText("text", color: color)), hidden: true),
             ProgramElement(id: id(2), content: .icon(ProgramIcon(name: .string("symbol"), color: color)), hidden: !visible)]
        }
        for visible in [false, true] {
            var value = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: children(visible: visible))),
                                    declarations: declarations)
            t.equal(value.neededSystemProperties, [.cpuUsage])
            for usage in [75.0, 25.0] {
                let expected = usage > 50 ? red : blue
                var measured: [RGBA] = []
                let scene = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: usage),
                    measureIcon: { request in measured.append(request.style.color); return SkinSize(width: request.style.color == red ? 30 : 15, height: 10) },
                    measure: { _, style, _ in measured.append(style.color); return SkinSize(width: style.color == red ? 20 : 10, height: 14) })
                t.equal(measured, [expected, expected]); t.equal(scene.size, SkinSize(width: usage > 50 ? 30 : 15, height: 24))
                t.equal(value.clockPrecision, visible ? .second : nil,
                    "a computed value first used by hidden measurement retains its precision for a later visible use")
                t.equal(scene.elements[1].visibility, .hiddenKeepsSpace)
                t.equal(scene.elements[2].visibility, visible ? .visible : .hiddenKeepsSpace)
            }
        }
        let timeColor = ProgramColor.conditional(.equal(.timeNow, .timeNow), then: .literal(red), otherwise: .literal(blue))
        var dated = try runtime(ProgramElement(id: id(0), content: .text(ProgramText("hidden", color: timeColor)), hidden: true))
        failure(.invalidDateInput) { _ = try dated.project(environment: environment, measure: measure) }
        _ = try dated.project(environment: environment, dateInput: date(0), measure: measure)
        t.equal(dated.clockPrecision, nil, "hidden layout consumes its date snapshot without driving display updates")
    }

    t.suite("Program: conditions: every existing paint slot validates resolves and samples conditional colors consistently") {
        let foreground = ProgramColor.conditional(cpu, then: .literal(red), otherwise: .literal(blue))
        let track = ProgramColor.conditional(cpu, then: .literal(blue), otherwise: .literal(red))
        let nodes: [ProgramElement] = [
            box(1, color: foreground),
            ProgramElement(id: id(2), content: .shape(kind: .circle, fill: foreground), width: .fixed(30), height: .fixed(30)),
            ProgramElement(id: id(3), content: .progress(ProgramProgress(value: .number(0.5), color: foreground, track: track)),
                width: .fixed(30), height: .fixed(8)),
            ProgramElement(id: id(4), content: .gauge(ProgramGauge(value: .number(0.5), color: foreground, track: track)),
                width: .fixed(30), height: .fixed(30)),
            ProgramElement(id: id(5), content: .rectangle(fill: .literal(.clear)), width: .fixed(30), height: .fixed(30),
                stroke: ProgramShapeStroke(color: foreground, width: 2)),
            ProgramElement(id: id(6), content: .row(spacing: 0, align: .top, children: []), width: .fixed(30), height: .fixed(30),
                background: .color(foreground)),
            ProgramElement(id: id(7), content: .row(spacing: 0, align: .top, children: []), width: .fixed(30), height: .fixed(30),
                background: .glass(style: .regular, tint: foreground))
        ]
        var value = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: nodes)))
        t.equal(value.neededSystemProperties, [.cpuUsage])
        for usage in [75.0, 25.0] {
            let fg = usage > 50 ? red : blue, bg = usage > 50 ? blue : red
            let scene = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: usage), measure: measure)
            t.equal(fills(scene.elements[1].items), [fg]); t.equal(fills(scene.elements[3].items), [bg, fg])
            t.equal(fills(scene.elements[4].items), [bg, fg]); t.equal(fills(scene.elements[6].items), [fg])
            if case .shape(let shape)? = scene.elements[2].items.first { t.equal(shape.shapes.first?.fill, .color(fg)) }
            else { t.check(false, "circle fill recipe") }
            if case .shape(let shape)? = scene.elements[5].items.first { t.equal(shape.shapes.first?.stroke, .color(fg)) }
            else { t.check(false, "stroke recipe") }
            t.equal(scene.elements[7].glass?.tint, fg); t.equal(value.clockPrecision, .second)
        }
        var hidden = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: nodes), hidden: true))
        t.equal(hidden.neededSystemProperties, [])
        t.check(try hidden.project(environment: environment, measure: measure).drawingItems.isEmpty)
        t.equal(hidden.clockPrecision, nil)
    }

    t.suite("Program: conditions: declarations and potential display sources remain in a fresh projection's demand") {
        let declarations: [ProgramDeclaration] = [
            .init(name: "frozen", kind: .variable, initial: .systemProperty(.batteryCharging)),
            .init(name: "hot", kind: .computed, initial: cpu)
        ]
        let painted = box(condition: .declaration(0), color: .conditional(.declaration(1), then: .literal(red), otherwise: .literal(blue)),
                          label: .concatenate([.systemProperty(.memoryUsed)]))
        var value = try runtime(painted, declarations: declarations)
        t.equal(value.neededSystemProperties, [.batteryCharging, .cpuUsage, .memoryUsed])
        _ = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(value.clockPrecision, nil)
        t.equal(value.neededSystemProperties, [.cpuUsage, .memoryUsed],
            "potential display demand stays conservative while a frozen variable initial stops sampling")
        let conditional = box(condition: .systemProperty(.batteryCharging), color:
            .conditional(cpu, then: .literal(red), otherwise: .literal(blue)), label: .concatenate([.systemProperty(.memoryUsed)]))
        var dynamic = try runtime(conditional)
        _ = try dynamic.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(dynamic.neededSystemProperties, [.batteryCharging, .cpuUsage, .memoryUsed])
        let shown = try dynamic.project(environment: environment,
            systemInput: ProgramSystemInput(cpuUsage: 75, memoryUsed: 100, batteryCharging: false), measure: measure)
        t.equal(fills(shown.drawingItems), [red]); t.equal(shown.elements[0].visibility, .visible)
        t.equal(dynamic.clockPrecision, .second)
    }

    t.suite("Program: conditions: failed conditional paint rolls back assignments effects visibility generation and hit state") {
        let color = ProgramColor.conditional(.declaration(0), then: .palette(.red), otherwise: .literal(blue))
        let actions: [ProgramAction] = [.assign(.init(declaration: 0, value: .boolean(true))), .copy(.string("accepted"))]
        let root = ProgramElement(id: id(0), content: .text(ProgramText("value", color: color)), width: .fixed(40), height: .fixed(30),
            onClickActions: actions, voiceOver: .concatenate([.declaration(0)]))
        var value = try runtime(root, declarations: [.init(name: "active", kind: .variable, initial: .boolean(false))])
        let first = try value.project(environment: environment, measure: measure)
        failure(.missingColorInput(.red)) {
            _ = try value.clickWithEffects(at: SkinPoint(x: 5, y: 5), expectedGeneration: first.generation,
                environment: environment, measure: measure)
        }
        t.equal(value.generation, first.generation); t.equal(value.clockPrecision, nil)
        let retried = try value.project(environment: environment, measure: measure)
        t.equal(retried.elements[0].accessibilityLabel, "No"); t.equal(retried.hitMap, first.hitMap)
        t.equal(fills(retried.drawingItems), [blue])
        let palette = ProgramColorInput(colors: Dictionary(uniqueKeysWithValues: ProgramPaletteColor.allCases.map { ($0, red) }))
        let accepted = try value.clickWithEffects(at: SkinPoint(x: 5, y: 5), expectedGeneration: retried.generation,
            environment: environment, colorInput: palette, measure: measure)
        t.equal(accepted?.effects, [.copy("accepted")]); t.equal(fills(accepted?.scene.drawingItems ?? []), [red])
        var hiding = try runtime(box(condition: .declaration(0), actions: actions, label: .string("visible")),
            declarations: [.init(name: "hidden", kind: .variable, initial: .boolean(false))])
        let visible = try hiding.project(environment: environment, measure: measure)
        let hidden = try hiding.clickWithEffects(at: SkinPoint(x: 5, y: 5), expectedGeneration: visible.generation,
            environment: environment, measure: measure)
        t.equal(hidden?.effects, [.copy("accepted")]); t.equal(hidden?.scene.elements[0].visibility, .hiddenKeepsSpace)
        t.check(hidden?.scene.hitMap.entries.isEmpty == true); t.equal(hidden?.scene.elements[0].accessibilityLabel, nil)
        t.equal(hiding.neededSystemProperties(clickAt: SkinPoint(x: 5, y: 5)), [])
        t.check(try hiding.clickWithEffects(at: SkinPoint(x: 5, y: 5), expectedGeneration: hiding.generation,
            environment: environment, measure: measure) == nil)
    }

    t.suite("Program: conditions: Freeform and preset transforms use the same resolved visibility as paint and input") {
        let child = ProgramElement(id: id(1), content: .icon(ProgramIcon(name: .string("wide"), hasOwnFont: true)),
            width: .fixed(20), height: .fixed(20), onClickActions: [.copy(.string("icon"))],
            position: ProgramPosition(x: -10, y: -5), voiceOver: .string("icon"), hiddenIf: .systemProperty(.batteryCharging))
        let root = ProgramElement(id: id(0), content: .freeform(align: .topLeft, children: [child]), width: .fixed(100), height: .fixed(100))
        let icon: (IconRequest) throws -> SkinSize? = { _ in SkinSize(width: 200, height: 40) }
        var fit = try runtime(root)
        let fitShown = try fit.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measureIcon: icon, measure: measure)
        let fitHidden = try fit.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measureIcon: icon, measure: measure)
        t.equal(fitShown.elements[1].frame, SkinRect(x: -10, y: -5, width: 20, height: 20))
        t.equal(fitHidden.elements.map(\.frame), fitShown.elements.map(\.frame)); t.equal(fitHidden.size, fitShown.size)
        var preset = try runtime(root, size: .preset(.small, size: SkinSize(width: 100, height: 100)))
        let shown = try preset.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measureIcon: icon, measure: measure)
        let hidden = try preset.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measureIcon: icon, measure: measure)
        t.equal(hidden.elements[0].frame, SkinRect(width: 100, height: 100))
        t.equal(hidden.elements[1].frame, SkinRect(x: -10, y: -5, width: 20, height: 20))
        t.check(shown.elements[0].frame.width < 100, "visible intrinsic glyph overflow participates in the preset fit")
        t.check(hidden.drawingItems.isEmpty && hidden.hitMap.entries.isEmpty)
        t.equal(hidden.elements[1].accessibilityLabel, nil)
        let restored = try preset.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measureIcon: icon, measure: measure)
        t.equal(restored.elements.map(\.frame), shown.elements.map(\.frame)); t.equal(restored.hitMap, shown.hitMap)
        t.equal(restored.elements[1].accessibilityLabel, "icon")
    }

    t.suite("Program: conditions: all branches reject invalid Bool types colors and expanded reference depth at initialization") {
        for hidden in [false, true] {
            for invalid in [ProgramExpression.number(1), .string("true"), .timeNow] {
                failure(.invalidExpression) { _ = try runtime(box(hidden: hidden, condition: invalid)) }
                failure(.invalidExpression) { _ = try runtime(box(hidden: hidden,
                    color: .conditional(.boolean(true), then: .literal(red), otherwise: .conditional(invalid, then: .literal(red), otherwise: .literal(blue))))) }
            }
            for bad in [RGBA(r: .nan, g: 0, b: 0), RGBA(r: 256, g: 0, b: 0), RGBA(r: 0, g: -1, b: 0)] {
                failure(.invalidPaint(id(0))) { _ = try runtime(box(hidden: hidden,
                    color: .conditional(.boolean(true), then: .literal(red), otherwise: .literal(bad)))) }
            }
        }
        let invalidColor = ProgramColor.conditional(.boolean(true), then: .literal(red), otherwise: .literal(RGBA(r: .infinity, g: 0, b: 0)))
        let badSlots: [(ProgramElement, ProgramRuntimeError)] = [
            (ProgramElement(id: id(0), content: .text(ProgramText("text", color: invalidColor)), hidden: true), .invalidText(id(0))),
            (ProgramElement(id: id(0), content: .icon(ProgramIcon(name: .string("icon"), color: invalidColor)), hidden: true), .invalidIcon(id(0))),
            (ProgramElement(id: id(0), content: .progress(ProgramProgress(value: .number(0.5), track: invalidColor)),
                width: .fixed(30), height: .fixed(10), hidden: true), .invalidPaint(id(0))),
            (ProgramElement(id: id(0), content: .gauge(ProgramGauge(value: .number(0.5), color: invalidColor)),
                width: .fixed(30), height: .fixed(30), hidden: true), .invalidPaint(id(0))),
            (ProgramElement(id: id(0), content: .rectangle(fill: .literal(red)), width: .fixed(30), height: .fixed(30),
                hidden: true, stroke: ProgramShapeStroke(color: invalidColor, width: 1)), .invalidPaint(id(0))),
            (ProgramElement(id: id(0), content: .rectangle(fill: .literal(red)), width: .fixed(30), height: .fixed(30),
                hidden: true, background: .color(invalidColor)), .invalidPaint(id(0))),
            (ProgramElement(id: id(0), content: .rectangle(fill: .literal(red)), width: .fixed(30), height: .fixed(30),
                hidden: true, background: .glass(style: .regular, tint: invalidColor)), .invalidPaint(id(0)))
        ]
        for (node, expected) in badSlots { failure(expected) { _ = try runtime(node) } }
        var chain = ProgramColor.literal(red)
        for _ in 0..<(ProgramLimits.maximumExpressionDepth - 1) {
            chain = .conditional(.boolean(false), then: .literal(blue), otherwise: chain)
        }
        _ = try runtime(box(color: chain))
        chain = .conditional(.boolean(true), then: .literal(red), otherwise: chain)
        failure(.expressionDepth) { _ = try runtime(box(color: chain)) }
        let declarations = (0..<64).map { i in
            ProgramDeclaration(name: "b\(i)", kind: .computed, initial: i == 0 ? .boolean(true) : .declaration(i - 1))
        }
        var referenced = ProgramColor.conditional(.declaration(63), then: .literal(red), otherwise: .literal(blue))
        for _ in 0..<62 { referenced = .conditional(.boolean(true), then: .literal(red), otherwise: referenced) }
        _ = try runtime(box(color: referenced), declarations: declarations)
        referenced = .conditional(.boolean(true), then: .literal(red), otherwise: referenced)
        failure(.expressionDepth) { _ = try runtime(box(color: referenced), declarations: declarations) }
        failure(.invalidDeclaration(99)) { _ = try runtime(box(condition: .declaration(99))) }
    }

    t.suite("Program: conditions: new selectors share the total budget without charging existing static paint leaves") {
        func text(_ count: Int, color: ProgramColor = .literal(.white), hiddenIf: ProgramExpression? = nil) -> ProgramElement {
            ProgramElement(id: id(0), content: .text(ProgramText(value: .concatenate(Array(repeating: .string("a"), count: count)), color: color)),
                           hidden: true, hiddenIf: hiddenIf)
        }
        _ = try runtime(text(ProgramLimits.maximumExpressions - 1))
        failure(.expressionLimit) { _ = try runtime(text(ProgramLimits.maximumExpressions - 1, hiddenIf: .boolean(false))) }
        let choice = ProgramColor.conditional(.boolean(true), then: .literal(red), otherwise: .literal(blue))
        _ = try runtime(text(ProgramLimits.maximumExpressions - 3, color: choice))
        failure(.expressionLimit) { _ = try runtime(text(ProgramLimits.maximumExpressions - 2, color: choice)) }
        func wide(_ depth: Int) -> ProgramColor {
            guard depth > 0 else { return .literal(red) }
            let child = wide(depth - 1)
            return .conditional(.boolean(true), then: child, otherwise: child)
        }
        _ = try runtime(box(color: wide(11)))
        failure(.expressionLimit) { _ = try runtime(box(color: wide(12))) }
    }
}
