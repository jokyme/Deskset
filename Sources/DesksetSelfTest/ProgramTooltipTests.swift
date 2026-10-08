import Foundation
@testable import DesksetCore

func runProgramTooltipTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "tooltips"), imageGeneration: 0)
    let dark = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .dark, name: "tooltips-dark"), imageGeneration: 0)
    let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0),
        timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"))
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, _, _ in
        SkinSize(width: Double(text.utf16.count) * 7, height: 14)
    }
    let containers: [([ProgramElement]) -> ProgramElement.Content] = [
        { .row(spacing: 0, align: .top, children: $0) },
        { .column(spacing: 0, align: .left, children: $0) },
        { .freeform(align: .topLeft, children: $0) }
    ]
    func id(_ index: Int) -> ElementID { ElementID(name: "tooltip-\(index)", index: index) }
    func box(_ tooltip: ProgramTooltip?, index: Int = 0, hidden: Bool = false,
             actions: [ProgramAction]? = nil) -> ProgramElement {
        ProgramElement(id: id(index), content: .rectangle(fill: .literal(.clear)),
            width: .fixed(40), height: .fixed(30), hidden: hidden, onClickActions: actions, tooltip: tooltip)
    }
    func runtime(_ root: ProgramElement, declarations: [ProgramDeclaration] = [],
                 size: ProgramWidgetSize = .fit) throws -> ProgramRuntime {
        try ProgramRuntime(program: WidgetProgram(name: "Tooltips", root: root, declarations: declarations, size: size))
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }
    func tip(_ scene: WidgetScene, _ x: Double = 20, _ y: Double = 15) -> ToolTipInfo? {
        scene.hitMap.toolTipInfo(at: x, y, images: nil)
    }
    func minutes(_ expression: ProgramExpression) -> ProgramExpression {
        .formatNumber(.divide(expression, .quantity(ProgramNumber(60, dimension: .duration))),
                      ProgramNumberFormat(decimals: 1))
    }

    t.suite("Program: tooltips: real boxes and empty containers expose hints without measurement or actions") {
        for content in containers {
            for text in ["Body", ""] {
                let root = ProgramElement(id: id(0), content: content([]), width: .fixed(40), height: .fixed(30),
                    tooltip: ProgramTooltip(text: .string(text)))
                var value = try runtime(root)
                let scene = try value.project(environment: environment) { _, _, _ in
                    t.check(false, "tooltip strings never enter measurement"); return SkinSize()
                }
                t.equal(scene.size, SkinSize(width: 40, height: 30)); t.check(scene.drawingItems.isEmpty)
                t.equal(tip(scene), ToolTipInfo(text: text)); t.equal(scene.hitMap.entries.count, 1)
                t.equal(scene.hitMap.entries.first?.elementID, id(0))
                t.check(scene.hitMap.entries.first?.actions.isEmpty == true)
                t.equal(scene.hitMap.mouseCursorName(at: 20, 15, images: nil), nil)
                for event in [MouseEventKind.leftUp, .rightUp] {
                    t.check(!scene.hitMap.hasAction(event, x: 20, y: 15, images: nil))
                    t.check(try value.clickWithEffects(at: SkinPoint(x: 20, y: 15), expectedGeneration: scene.generation,
                        event: event, environment: environment, measure: measure) == nil)
                    t.equal(value.neededSystemProperties(clickAt: SkinPoint(x: 20, y: 15), event: event), [])
                }
                t.check(try value.activateContainerWithEffects(id(0), expectedGeneration: scene.generation,
                    environment: environment, measure: measure) == nil)
                t.equal(value.generation, scene.generation); t.equal(value.clockPrecision, nil)
            }
            for label in [ProgramExpression?.none, .some(.string("Label only"))] {
                failure(.emptyProgram) {
                    _ = try runtime(ProgramElement(id: id(0), content: content([]), width: .fixed(40),
                        height: .fixed(30), voiceOver: label))
                }
            }
        }
        func program(_ hasTips: Bool) -> WidgetProgram {
            let tooltip = hasTips ? ProgramTooltip(text: .string("Never measure this"), title: .string("Title")) : nil
            let children: [ProgramElement] = [
                ProgramElement(id: id(1), content: .text(ProgramText("Text")), tooltip: tooltip),
                ProgramElement(id: id(2), content: .icon(ProgramIcon(name: .string("star"))), tooltip: tooltip),
                ProgramElement(id: id(3), content: .image(ProgramImage(source: "picture")), tooltip: tooltip),
                ProgramElement(id: id(4), content: .progress(ProgramProgress(value: .number(0.5))),
                    width: .fixed(30), height: .fixed(6), tooltip: tooltip),
                ProgramElement(id: id(5), content: .gauge(ProgramGauge(value: .number(0.5))),
                    width: .fixed(30), height: .fixed(30), tooltip: tooltip),
                box(tooltip, index: 6),
                ProgramElement(id: id(7), content: .shape(kind: .circle, fill: .literal(.white)),
                    width: .fixed(10), height: .fixed(12), tooltip: tooltip)
            ]
            return WidgetProgram(name: "Measured hints", root: ProgramElement(id: id(0),
                content: .column(spacing: 3, align: .left, children: children), tooltip: tooltip))
        }
        let resource = ProgramImageResource(path: "/fixture/tooltip.png", naturalSize: SkinSize(width: 8, height: 10),
            stamp: ImageStamp(seconds: 1, nanoseconds: 0, size: 12, inode: 3))
        var plain = try ProgramRuntime(program: program(false)), decorated = try ProgramRuntime(program: program(true))
        var beforeText: [String] = [], afterText: [String] = [], beforeIcons: [IconRequest] = [], afterIcons: [IconRequest] = []
        let before = try plain.project(environment: environment, images: ["picture": resource], measureIcon: {
            beforeIcons.append($0); return SkinSize(width: 12, height: 10)
        }) { text, style, width in beforeText.append(text); return try measure(text, style, width) }
        let after = try decorated.project(environment: environment, images: ["picture": resource], measureIcon: {
            afterIcons.append($0); return SkinSize(width: 12, height: 10)
        }) { text, style, width in afterText.append(text); return try measure(text, style, width) }
        t.equal(before.size, after.size); t.equal(before.elements.map(\.frame), after.elements.map(\.frame))
        t.equal(before.elements.map(\.kind), after.elements.map(\.kind))
        t.equal(before.elements.map { $0.items.count }, after.elements.map { $0.items.count })
        t.equal(beforeText, afterText); t.check(!afterText.isEmpty && afterText.allSatisfy { $0 == "Text" })
        t.equal(beforeIcons, afterIcons); t.check(!afterIcons.isEmpty)
        t.equal(after.hitMap.entries.count, 8); t.check(before.hitMap.entries.isEmpty)
        t.check(after.elements.allSatisfy { $0.accessibilityLabel == nil }); t.equal(box(nil).tooltip, nil)
    }

    t.suite("Program: tooltips: child empty title-only and absent hints preserve independent event priority") {
        let childTips: [ProgramTooltip?] = [nil, ProgramTooltip(text: .string("")),
            ProgramTooltip(text: .string(""), title: .string("Title only")),
            ProgramTooltip(text: .string("Child"), title: .string("Heading"))]
        let expected = [ToolTipInfo(text: "Parent"), ToolTipInfo(text: ""),
            ToolTipInfo(text: "", title: "Title only"), ToolTipInfo(text: "Child", title: "Heading")]
        let childActions: [[ProgramAction]?] = [nil, []]
        for content in containers {
            for (index, tooltip) in childTips.enumerated() {
                for actions in childActions {
                    let child = ProgramElement(id: id(1), content: .rectangle(fill: .literal(.clear)),
                        width: .fixed(20), height: .fixed(20), cornerRadius: .points(6),
                        onClickActions: actions, tooltip: tooltip)
                    let root = ProgramElement(id: id(0), content: content([child]),
                        padding: SkinInsets(left: 6, top: 6, right: 6, bottom: 6),
                        onClickActions: [.copy(.string("parent"))], onRightClickActions: [.copy(.string("right"))],
                        tooltip: ProgramTooltip(text: .string("Parent")))
                    var value = try runtime(root)
                    let scene = try value.project(environment: environment, measure: measure)
                    t.equal(tip(scene, 10, 10), expected[index])
                    t.equal(tip(scene, 1, 16), ToolTipInfo(text: "Parent"), "parent padding")
                    t.equal(tip(scene, 6.1, 6.1), ToolTipInfo(text: "Parent"), "rounded child corner falls through")
                    t.equal(scene.hitMap.entry(at: 10, 10, handling: .leftUp, images: nil)?.elementID,
                        actions == nil ? id(0) : id(1))
                    t.equal(scene.hitMap.entry(at: 10, 10, handling: .rightUp, images: nil)?.elementID, id(0))
                    t.equal(scene.hitMap.mouseCursorName(at: 10, 10, images: nil), actions == nil ? "HAND" : nil)
                    let clicked = try value.clickWithEffects(at: SkinPoint(x: 10, y: 10), expectedGeneration: scene.generation,
                        environment: environment, measure: measure)
                    t.equal(clicked?.effects, actions == nil ? [.copy("parent")] : [])
                }
            }
        }
        let children = (1...513).map { index in
            ProgramElement(id: id(index), content: .rectangle(fill: .literal(.clear)),
                width: .fixed(2), height: .fixed(2), tooltip: ProgramTooltip(text: .string("\(index)")))
        }
        var many = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: children)))
        let scene = try many.project(environment: environment, measure: measure)
        t.equal(scene.hitMap.entries.count, 513, "Desk targets are not truncated to legacy AppKit tooltip areas")
        t.equal(tip(scene, 1, 1), ToolTipInfo(text: "1")); t.equal(tip(scene, 1, 1025), ToolTipInfo(text: "513"))
    }

    t.suite("Program: tooltips: rounded padding source order negative origins and preset geometry transform once") {
        let padded = ProgramElement(id: id(0), content: .rectangle(fill: .literal(.clear)),
            width: .fixed(40), height: .fixed(30), padding: SkinInsets(left: 4, top: 4, right: 4, bottom: 4),
            cornerRadius: .points(8), tooltip: ProgramTooltip(text: .string("Padding")))
        var value = try runtime(padded)
        let scene = try value.project(environment: environment, measure: measure)
        t.equal(scene.hitMap.entries.first?.frame, SkinRect(width: 40, height: 30))
        t.equal(tip(scene, 1, 15), ToolTipInfo(text: "Padding")); t.equal(tip(scene, 0.1, 0.1), nil)

        let first = ProgramElement(id: id(1), content: .row(spacing: 0, align: .top, children: []),
            width: .fixed(20), height: .fixed(20), position: ProgramPosition(x: -5, y: -5),
            tooltip: ProgramTooltip(text: .string("First")))
        let last = ProgramElement(id: id(2), content: .column(spacing: 0, align: .left, children: []),
            width: .fixed(20), height: .fixed(20), position: ProgramPosition(x: 0, y: 0),
            tooltip: ProgramTooltip(text: .string("Last")))
        let hidden = ProgramElement(id: id(3), content: .rectangle(fill: .literal(.clear)),
            width: .fixed(20), height: .fixed(20), hidden: true, position: ProgramPosition(x: 0, y: 0),
            tooltip: ProgramTooltip(text: .string("Hidden")))
        let root = ProgramElement(id: id(0), content: .freeform(align: .topLeft, children: [first, last, hidden]),
            width: .fixed(40), height: .fixed(40), cornerRadius: .full, tooltip: ProgramTooltip(text: .string("Root")))
        var overlap = try runtime(root)
        let ordered = try overlap.project(environment: environment, measure: measure)
        t.equal(ordered.hitMap.entries.map(\.elementID), [id(2), id(1), id(0)])
        t.equal(tip(ordered, 1, 1), ToolTipInfo(text: "Last"), "rounded parents do not clip their children")
        t.equal(tip(ordered, -4, -4), ToolTipInfo(text: "First"))
        t.equal(tip(ordered, 30, 20), ToolTipInfo(text: "Root")); t.equal(tip(ordered, 39, 1), nil)

        let target = ProgramElement(id: id(1), content: .column(spacing: 0, align: .left, children: []),
            width: .fixed(200), height: .fixed(100), cornerRadius: .points(20),
            position: ProgramPosition(x: -20, y: -10), tooltip: ProgramTooltip(text: .string("Target"), title: .string("Title")))
        let freeform = ProgramElement(id: id(0), content: .freeform(align: .center, children: [target]))
        var fit = try runtime(freeform)
        let ordinary = try fit.project(environment: environment, measure: measure)
        t.equal(ordinary.elements[1].frame, SkinRect(x: -20, y: -10, width: 200, height: 100))
        t.equal(tip(ordinary, -19, 40), ToolTipInfo(text: "Target", title: "Title"))
        var preset = try runtime(freeform, size: .preset(.small, size: SkinSize(width: 100, height: 50)))
        let scaled = try preset.project(environment: environment, measure: measure)
        t.equal(scaled.elements[0].frame, SkinRect(x: 10, y: 5, width: 50, height: 25))
        t.equal(scaled.elements[1].frame, SkinRect(width: 100, height: 50))
        t.equal(scaled.hitMap.entries.first?.frame, scaled.elements[1].frame)
        t.equal(tip(scaled, 1, 5), nil, "radius is ten, not scaled twice to five")
        t.equal(tip(scaled, 1, 25), ToolTipInfo(text: "Target", title: "Title"))
    }

    t.suite("Program: tooltips: text and title share live formatting missing values and declaration snapshots") {
        let tooltip = ProgramTooltip(text: .concatenate([.string("CPU "),
            .formatNumber(.systemProperty(.cpuUsage), ProgramNumberFormat(decimals: 1))]),
            title: .concatenate([.string("Minutes "), minutes(.systemProperty(.batteryTimeRemaining))]))
        var value = try runtime(box(tooltip))
        t.equal(value.neededSystemProperties, [.cpuUsage, .batteryTimeRemaining])
        let first = try value.project(environment: environment, dateInput: date,
            systemInput: ProgramSystemInput(cpuUsage: 12.5, batteryTimeRemaining: 90), measure: measure)
        t.equal(tip(first), ToolTipInfo(text: "CPU 12.5", title: "Minutes 1.5")); t.equal(value.clockPrecision, .second)
        let german = ProgramDateInput(instant: date.instant, timeZone: date.timeZone, locale: Locale(identifier: "de_DE"))
        let localized = try value.project(environment: environment, dateInput: german,
            systemInput: ProgramSystemInput(cpuUsage: 12.5, batteryTimeRemaining: 90), measure: measure)
        t.equal(tip(localized), ToolTipInfo(text: "CPU 12,5", title: "Minutes 1,5"))
        for input in [ProgramSystemInput(), ProgramSystemInput(cpuUsage: .nan, batteryTimeRemaining: -1),
                      ProgramSystemInput(cpuUsage: .infinity, batteryTimeRemaining: Double(Int64.max))] {
            let missing = try value.project(environment: environment, dateInput: date, systemInput: input, measure: measure)
            t.equal(tip(missing), ToolTipInfo(text: "CPU –", title: "Minutes –"))
            t.equal(value.clockPrecision, .second); t.equal(missing.elements[0].frame, first.elements[0].frame)
        }
        t.equal(tip(first), ToolTipInfo(text: "CPU 12.5", title: "Minutes 1.5"), "old scene hints remain immutable")

        let declarations = [
            ProgramDeclaration(name: "frozen", kind: .variable, initial: .systemProperty(.cpuUsage)),
            ProgramDeclaration(name: "live", kind: .computed, initial: minutes(.systemProperty(.batteryTimeRemaining))),
            ProgramDeclaration(name: "hidden", kind: .computed, initial: .concatenate([.systemProperty(.memoryUsed)]))
        ]
        let active = ProgramTooltip(text: .formatNumber(.declaration(0), ProgramNumberFormat(decimals: 0)), title: .declaration(1))
        let root = ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [
            box(active, index: 1), box(ProgramTooltip(text: .declaration(2)), index: 2, hidden: true)]))
        var declared = try runtime(root, declarations: declarations)
        t.equal(declared.neededSystemProperties, [.cpuUsage, .batteryTimeRemaining])
        let initial = try declared.project(environment: environment, dateInput: date,
            systemInput: ProgramSystemInput(cpuUsage: 25, batteryTimeRemaining: 120), measure: measure)
        t.equal(tip(initial), ToolTipInfo(text: "25", title: "2.0"))
        t.equal(declared.neededSystemProperties, [.batteryTimeRemaining]); t.equal(declared.clockPrecision, .minute)
        let updated = try declared.project(environment: environment, dateInput: date,
            systemInput: ProgramSystemInput(cpuUsage: 90, batteryTimeRemaining: 180), measure: measure)
        t.equal(tip(updated), ToolTipInfo(text: "25", title: "3.0")); t.equal(tip(updated, 20, 45), nil)
    }

    t.suite("Program: tooltips: effective visibility and selected branches control evaluation while demand stays conservative") {
        let live = ProgramTooltip(text: .concatenate([.formatDate(.timeNow, .pattern("HH:mm:ss")), .string(" "),
            .systemProperty(.cpuUsage)]), title: minutes(.systemProperty(.batteryTimeRemaining)))
        let hiddenParent = ProgramElement(id: id(1), content: .column(spacing: 0, align: .left,
            children: [box(live, index: 2)]), hidden: true, tooltip: live)
        var hidden = try runtime(ProgramElement(id: id(0), content: .row(spacing: 0, align: .top,
            children: [hiddenParent, box(live, index: 3, hidden: true)])))
        t.equal(hidden.neededSystemProperties, [])
        let absent = try hidden.project(environment: environment, measure: measure)
        t.check(absent.hitMap.entries.isEmpty); t.equal(hidden.clockPrecision, nil)
        t.equal(absent.elements[2].frame.width, 40, "hidden hints do not collapse their box")

        let dynamic = ProgramElement(id: id(0), content: .rectangle(fill: .literal(.clear)),
            width: .fixed(40), height: .fixed(30), hiddenIf: .systemProperty(.batteryCharging), tooltip: live)
        var conditional = try runtime(dynamic)
        let demand: Set<ProgramSystemProperty> = [.batteryCharging, .cpuUsage, .batteryTimeRemaining]
        t.equal(conditional.neededSystemProperties, demand)
        let concealed = try conditional.project(environment: environment,
            systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.check(concealed.hitMap.entries.isEmpty); t.equal(conditional.clockPrecision, nil)
        t.equal(conditional.neededSystemProperties, demand, "last-frame hidden state never removes recovery dependencies")
        let shown = try conditional.project(environment: environment, dateInput: date,
            systemInput: ProgramSystemInput(cpuUsage: 25, batteryCharging: false, batteryTimeRemaining: 120), measure: measure)
        t.equal(tip(shown), ToolTipInfo(text: "00:00:00 25", title: "2.0")); t.equal(conditional.clockPrecision, .second)
        _ = try conditional.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(conditional.clockPrecision, nil)

        let selected = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .systemProperty(.batteryPluggedIn), body: [box(live, index: 2)])
        ], otherwise: [box(ProgramTooltip(text: minutes(.systemProperty(.batteryTimeRemaining))), index: 3)])))
        var branches = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [selected])))
        t.equal(branches.neededSystemProperties, [.batteryPluggedIn, .cpuUsage, .batteryTimeRemaining])
        let fallback = try branches.project(environment: environment,
            systemInput: ProgramSystemInput(batteryPluggedIn: false, batteryTimeRemaining: 180), measure: measure)
        t.equal(fallback.elements.map(\.id), [id(0), id(3)]); t.equal(tip(fallback), ToolTipInfo(text: "3.0"))
        t.equal(branches.clockPrecision, .minute, "inactive tooltip does not request date input or a second timer")
        let active = try branches.project(environment: environment, dateInput: date,
            systemInput: ProgramSystemInput(cpuUsage: 50, batteryPluggedIn: true, batteryTimeRemaining: 60), measure: measure)
        t.equal(active.hitMap.entries.map(\.elementID), [id(2)]); t.equal(branches.clockPrecision, .second)

        let lazy = ProgramTooltip(text: .string(""), title: .conditional(.appearanceDark,
            then: .formatDate(.timeNow, .pattern("HH:mm:ss")), otherwise: .string("")))
        var title = try runtime(box(lazy))
        t.equal(tip(try title.project(environment: environment, measure: measure)), ToolTipInfo(text: ""))
        t.equal(title.clockPrecision, nil)
        t.equal(tip(try title.project(environment: dark, dateInput: date, measure: measure)), ToolTipInfo(text: "", title: "00:00:00"))
        t.equal(title.clockPrecision, .second)
        _ = try title.project(environment: environment, measure: measure); t.equal(title.clockPrecision, nil)
        for size in [SkinSize(width: 0, height: 30), SkinSize(width: 40, height: 0)] {
            var zero = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: []),
                width: .fixed(size.width), height: .fixed(size.height), tooltip: lazy))
            let scene = try zero.project(environment: dark, dateInput: date, measure: measure)
            t.check(scene.hitMap.entries.isEmpty); t.equal(zero.clockPrecision, .second)
            failure(.invalidDateInput) { _ = try zero.project(environment: dark, measure: measure) }
            t.equal(zero.generation, scene.generation)
        }
    }

    t.suite("Program: tooltips: all bindings share validation budgets and failed projection rolls back actions") {
        let invalid: [ProgramExpression] = [.number(1), .boolean(true), .timeNow,
            .conditional(.boolean(false), then: .number(1), otherwise: .string("valid")),
            .string(String(repeating: "x", count: ProgramLimits.maximumTextLength + 1))]
        for hidden in [false, true] {
            for expression in invalid {
                for tooltip in [ProgramTooltip(text: expression), ProgramTooltip(text: .string("body"), title: expression)] {
                    failure(.invalidExpression) { _ = try runtime(box(tooltip, hidden: hidden)) }
                }
            }
            failure(.invalidDeclaration(9)) {
                _ = try runtime(box(ProgramTooltip(text: .string("body"), title: .declaration(9)), hidden: hidden))
            }
        }
        let conditional = ProgramConditional(branches: [ProgramConditionalBranch(condition: .boolean(false), body: [
            box(ProgramTooltip(text: .string("body"), title: .boolean(false)), index: 2)
        ])], otherwise: [box(nil, index: 3)])
        failure(.invalidExpression) {
            _ = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [
                ProgramElement(id: id(1), content: .conditional(conditional))])))
        }
        failure(.invalidGeometry(id(1))) {
            let item = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
                ProgramConditionalBranch(condition: .boolean(true), body: [box(nil, index: 2)])
            ])), tooltip: ProgramTooltip(text: .string("Structural")))
            _ = try runtime(ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: [item])))
        }
        var deep = ProgramExpression.string("title")
        for _ in 0..<ProgramLimits.maximumExpressionDepth { deep = .concatenate([deep]) }
        failure(.expressionDepth) { _ = try runtime(box(ProgramTooltip(text: .string("body"), title: deep), hidden: true)) }
        let declarations = (0..<ProgramLimits.maximumExpressionDepth).map { index in
            ProgramDeclaration(name: "d\(index)", kind: .computed, initial: index == 0 ? .string("title") : .declaration(index - 1))
        }
        failure(.expressionDepth) {
            _ = try runtime(box(ProgramTooltip(text: .string("body"), title: .declaration(declarations.count - 1))), declarations: declarations)
        }
        func budget(_ count: Int) throws -> ProgramRuntime {
            try runtime(ProgramElement(id: id(0), content: .rectangle(fill: .literal(.clear)),
                width: .fixed(40), height: .fixed(30), hidden: true, onClickActions: [.copy(.string("action"))],
                voiceOver: .string("label"), tooltip: ProgramTooltip(text: .concatenate(Array(repeating: .string("a"), count: count)),
                    title: .string("title"))))
        }
        _ = try budget(ProgramLimits.maximumExpressions - 4)
        failure(.expressionLimit) { _ = try budget(ProgramLimits.maximumExpressions - 3) }
        let oversized = ProgramExpression.concatenate([.string(String(repeating: "x", count: ProgramLimits.maximumTextLength)), .string("x")])
        var overflow = try runtime(box(ProgramTooltip(text: .string("body"), title: oversized)))
        failure(.invalidExpression) { _ = try overflow.project(environment: environment, measure: measure) }
        t.equal(overflow.generation, 0); t.equal(overflow.clockPrecision, nil)
        var hidden = try runtime(box(ProgramTooltip(text: oversized), hidden: true))
        t.check(try hidden.project(environment: environment, measure: measure).hitMap.entries.isEmpty)

        let tooltip = ProgramTooltip(text: .declaration(0), title: .formatDate(.timeNow, .pattern("HH:mm")))
        let actions: [ProgramAction] = [.assign(ProgramAssignment(declaration: 0, value: .string("new"))), .copy(.declaration(0))]
        var value = try runtime(box(tooltip, actions: actions), declarations: [
            ProgramDeclaration(name: "caption", kind: .variable, initial: .string("old"))])
        let first = try value.project(environment: environment, dateInput: date, measure: measure)
        t.equal(tip(first), ToolTipInfo(text: "old", title: "00:00")); t.equal(value.clockPrecision, .minute)
        failure(.invalidDateInput) {
            _ = try value.clickWithEffects(at: SkinPoint(x: 2, y: 2), expectedGeneration: first.generation,
                environment: environment, measure: measure)
        }
        t.equal(value.generation, first.generation); t.equal(value.clockPrecision, .minute)
        let recovered = try value.project(environment: environment, dateInput: date, measure: measure)
        t.equal(tip(recovered), ToolTipInfo(text: "old", title: "00:00")); t.equal(recovered.hitMap, first.hitMap)
        let changed = try value.clickWithEffects(at: SkinPoint(x: 2, y: 2), expectedGeneration: recovered.generation,
            environment: environment, dateInput: date, measure: measure)
        t.equal(changed?.effects, [.copy("new")]); t.equal(changed?.scene.hitMap.entries.first?.toolTip, ToolTipInfo(text: "new", title: "00:00"))
        t.equal(tip(first), ToolTipInfo(text: "old", title: "00:00"))
        t.check(try value.clickWithEffects(at: SkinPoint(x: 2, y: 2), expectedGeneration: first.generation,
            environment: environment, dateInput: date, measure: measure) == nil)
    }
}
