import Foundation
@testable import DesksetCore

func runProgramViewIfTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "view-if"), imageGeneration: 0)
    let cpu = ProgramExpression.greater(.systemProperty(.cpuUsage), .quantity(ProgramNumber(50, dimension: .percent)))
    let red = RGBA(r: 220, g: 30, b: 40), blue = RGBA(r: 20, g: 60, b: 210)
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { _, _, _ in SkinSize(width: 12, height: 8) }
    func id(_ n: Int) -> ElementID { ElementID(name: "view-if-\(n)", index: n) }
    func date(_ seconds: Double = 0) -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!,
                         locale: Locale(identifier: "en_US_POSIX"))
    }
    func leaf(_ n: Int, width: Double = 10, height: Double = 10, hidden: Bool = false) -> ProgramElement {
        ProgramElement(id: id(n), content: .rectangle(fill: .literal(.white)),
                       width: .fixed(width), height: .fixed(height), hidden: hidden)
    }
    func choose(_ n: Int, _ condition: ProgramExpression, _ body: [ProgramElement],
                otherwise: [ProgramElement] = []) -> ProgramElement {
        ProgramElement(id: id(n), content: .conditional(ProgramConditional(
            branches: [ProgramConditionalBranch(condition: condition, body: body)], otherwise: otherwise)))
    }
    func column(_ children: [ProgramElement]) -> ProgramElement {
        ProgramElement(id: id(0), content: .column(spacing: 0, align: .left, children: children))
    }
    func runtime(_ root: ProgramElement, declarations: [ProgramDeclaration] = [],
                 size: ProgramWidgetSize = .fit) throws -> ProgramRuntime {
        try ProgramRuntime(program: WidgetProgram(name: "View if", root: root, declarations: declarations, size: size))
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }
    func texts(_ scene: WidgetScene) -> [String] {
        scene.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.text }; return nil }
    }

    t.suite("Program: view if: selected siblings splice into the parent without wrapper boxes or extra gaps") {
        let gate = choose(2, .systemProperty(.batteryCharging), [leaf(3, width: 10, height: 12), leaf(4, width: 20, height: 6)],
                          otherwise: [leaf(5, width: 7, height: 9)])
        let root = ProgramElement(id: id(0), content: .row(spacing: 3, align: .top,
            children: [leaf(1, width: 5, height: 8), gate, leaf(6, width: 4)]))
        var value = try runtime(root)
        let first = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(first.elements.map(\.id), [0, 1, 3, 4, 6].map(id))
        t.equal(first.size, SkinSize(width: 48, height: 12))
        t.equal(first.elements.dropFirst().map(\.frame), [
            SkinRect(width: 5, height: 8), SkinRect(x: 8, width: 10, height: 12),
            SkinRect(x: 21, width: 20, height: 6), SkinRect(x: 44, width: 4, height: 10)])
        let second = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: measure)
        t.equal(second.elements.map(\.id), [0, 1, 5, 6].map(id))
        t.equal(second.size, SkinSize(width: 22, height: 10))
        t.equal(second.elements.dropFirst().map(\.frame), [
            SkinRect(width: 5, height: 8), SkinRect(x: 8, width: 7, height: 9), SkinRect(x: 18, width: 4, height: 10)])
        let restored = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(restored.elements.map(\.id), first.elements.map(\.id))
        t.equal(restored.elements.map(\.frame), first.elements.map(\.frame))
        t.check(restored.elements.allSatisfy { $0.visibility == .visible })
        t.equal(value.clockPrecision, nil)
    }

    t.suite("Program: view if: ordered arms short circuit and typed missing selects only the fallback") {
        let gate = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .systemProperty(.batteryCharging), body: [leaf(2)]),
            ProgramConditionalBranch(condition: cpu, body: [leaf(3)]),
            ProgramConditionalBranch(condition: .equal(.timeNow, .timeNow), body: [leaf(4)])
        ], otherwise: [leaf(5)])))
        var value = try runtime(column([gate]))
        t.equal(try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true),
            measure: measure).elements.map(\.id), [0, 2].map(id))
        t.equal(value.clockPrecision, nil, "later CPU and date predicates are not evaluated")
        t.equal(try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: 75, batteryCharging: false),
            measure: measure).elements.map(\.id), [0, 3].map(id))
        t.equal(value.clockPrecision, .second)
        let generation = value.generation
        failure(.invalidDateInput) {
            _ = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: 25), measure: measure)
        }
        t.equal(value.generation, generation)
        t.equal(try value.project(environment: environment, dateInput: date(),
            systemInput: ProgramSystemInput(cpuUsage: 25), measure: measure).elements.map(\.id), [0, 4].map(id))
        for (condition, yes) in [(cpu, false), (.not(cpu), false), (.or(cpu, .boolean(true)), true),
                                 (.not(.and(cpu, .boolean(false))), true), (.isMissing(cpu), true)] {
            var missing = try runtime(column([choose(1, condition, [leaf(2)], otherwise: [leaf(3)])]))
            let scene = try missing.project(environment: environment, systemInput: ProgramSystemInput(), measure: measure)
            t.equal(scene.elements.map(\.id), [0, yes ? 2 : 3].map(id))
            t.equal(missing.clockPrecision, .second)
        }
    }

    t.suite("Program: view if: inactive bodies never evaluate text or request icon and image resources") {
        let live = ProgramElement(id: id(2), content: .text(ProgramText(value: .formatDate(.timeNow, .pattern("HH:mm:ss")))))
        let icon = ProgramElement(id: id(3), content: .icon(ProgramIcon(name: .string("live-symbol"))))
        let image = ProgramElement(id: id(4), content: .image(ProgramImage(source: "picture")))
        let fallback = ProgramElement(id: id(5), content: .text(ProgramText("safe")))
        var value = try runtime(column([choose(1, .systemProperty(.batteryCharging), [live, icon, image], otherwise: [fallback])]))
        var measured: [String] = [], requests: [String] = []
        let measuring: (String, TextStyle, Double?) throws -> SkinSize = { text, _, _ in
            measured.append(text); return SkinSize(width: 12, height: 8)
        }
        let symbols: (IconRequest) throws -> SkinSize? = { request in
            requests.append(request.name); return SkinSize(width: 10, height: 10)
        }
        let first = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: measuring)
        t.equal(first.elements.map(\.id), [0, 5].map(id)); t.equal(Set(measured), ["safe"])
        t.equal(value.clockPrecision, nil)
        failure(.invalidDateInput) {
            _ = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measuring)
        }
        failure(.missingIconMeasurement(id(3))) {
            _ = try value.project(environment: environment, dateInput: date(),
                systemInput: ProgramSystemInput(batteryCharging: true), measure: measuring)
        }
        failure(.invalidImage(id(4))) {
            _ = try value.project(environment: environment, dateInput: date(),
                systemInput: ProgramSystemInput(batteryCharging: true), measureIcon: symbols, measure: measuring)
        }
        t.equal(value.generation, first.generation); t.equal(value.clockPrecision, nil)
        let resource = ProgramImageResource(path: "/fixture/view-if.png", naturalSize: SkinSize(width: 10, height: 10),
            stamp: ImageStamp(seconds: 1, nanoseconds: 0, size: 12, inode: 3))
        let shown = try value.project(environment: environment, images: ["picture": resource], dateInput: date(),
            systemInput: ProgramSystemInput(batteryCharging: true), measureIcon: symbols, measure: measuring)
        t.equal(shown.elements.map(\.id), [0, 2, 3, 4].map(id)); t.equal(value.clockPrecision, .second)
        t.equal(shown.elements.last?.imageDependencies.count, 1)
        let requestsBefore = requests
        measured.removeAll()
        let absent = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false),
            measureIcon: symbols, measure: measuring)
        t.equal(requests, requestsBefore); t.equal(Set(measured), ["safe"])
        t.check(absent.elements.allSatisfy { $0.imageDependencies.isEmpty }); t.equal(value.clockPrecision, nil)
    }

    t.suite("Program: view if: an empty active body clears content and retains only its recovery predicates") {
        let target = ProgramElement(id: id(2), content: .rectangle(fill: .literal(.white)), width: .fixed(10), height: .fixed(10),
            onClickActions: [.copy(.string("target"))], voiceOver: .string("Target"))
        var value = try runtime(column([choose(1, cpu, [target])]))
        let empty = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: 25), measure: measure)
        t.equal(empty.size, SkinSize()); t.equal(empty.elements.map(\.id), [id(0)])
        t.check(empty.drawingItems.isEmpty && empty.hitMap.entries.isEmpty); t.equal(value.clockPrecision, .second)
        let shown = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: 75), measure: measure)
        t.equal(shown.size, SkinSize(width: 10, height: 10)); t.equal(shown.elements[1].accessibilityLabel, "Target")
        let gone = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: 25), measure: measure)
        t.equal(gone.elements.map(\.id), [id(0)]); t.check(gone.hitMap.entries.isEmpty)
        t.equal(value.clockPrecision, .second)
        t.check(try value.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: shown.generation,
            environment: environment, measure: measure) == nil)
        var nested = try runtime(column([choose(3, .systemProperty(.batteryCharging), [choose(1, cpu, [target])])]))
        _ = try nested.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: measure)
        t.equal(nested.clockPrecision, nil, "an absent outer arm does not evaluate inner predicates")
        t.equal(nested.neededSystemProperties, [.batteryCharging, .cpuUsage], "pre-sampling demand remains conservative")
        var emptyWinner = try runtime(column([choose(1, .boolean(true), [], otherwise: [target])]))
        t.equal(try emptyWinner.project(environment: environment, measure: measure).elements.map(\.id), [id(0)])
        t.equal(emptyWinner.clockPrecision, nil, "an empty true arm still wins instead of falling through")
    }

    t.suite("Program: view if: hidden parents select and measure layout without retaining display clocks") {
        let predicate = ProgramExpression.declaration(0)
        let color = ProgramColor.conditional(predicate, then: .literal(red), otherwise: .literal(blue))
        let wide = ProgramElement(id: id(3), content: .text(ProgramText("wide", color: color)),
            voiceOver: .formatDate(.timeNow, .pattern("HH:mm:ss")), hiddenIf: .equal(.timeNow, .timeNow))
        let narrow = ProgramElement(id: id(4), content: .text(ProgramText("narrow", color: color)))
        let hidden = ProgramElement(id: id(1), content: .column(spacing: 0, align: .left,
            children: [choose(2, predicate, [wide], otherwise: [narrow])]), hidden: true)
        let declarations = [ProgramDeclaration(name: "large", kind: .computed, initial: cpu)]
        let root = ProgramElement(id: id(0), content: .row(spacing: 0, align: .top, children: [hidden, leaf(5, width: 4, height: 4)]))
        var value = try runtime(root, declarations: declarations)
        var measured: [String] = [], colors: [RGBA] = []
        let measuring: (String, TextStyle, Double?) throws -> SkinSize = { text, style, _ in
            measured.append(text); colors.append(style.color)
            return SkinSize(width: text == "wide" ? 30 : 10, height: 8)
        }
        t.equal(value.neededSystemProperties, [.cpuUsage])
        for (usage, width, name, color) in [(75.0, 34.0, "wide", red), (25.0, 14.0, "narrow", blue)] {
            measured.removeAll(); colors.removeAll()
            let scene = try value.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: usage), measure: measuring)
            t.equal(scene.size, SkinSize(width: width, height: 8)); t.equal(scene.elements.last?.frame.x, width - 4)
            t.equal(Set(measured), [name]); t.check(colors.allSatisfy { $0 == color })
            t.equal(scene.elements[2].visibility, .hiddenKeepsSpace); t.equal(scene.elements[2].accessibilityLabel, nil)
            t.equal(value.clockPrecision, nil)
        }
        let visible = ProgramElement(id: id(5), content: .text(ProgramText("visible", color: color)))
        var memo = try runtime(ProgramElement(id: id(0), content: .row(spacing: 0, align: .top, children: [hidden, visible])),
            declarations: declarations)
        _ = try memo.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: 75), measure: measuring)
        t.equal(memo.clockPrecision, .second, "the visible use recovers precision cached by the hidden predicate")
    }

    t.suite("Program: view if: selected Spacers keep the real parent axis and use only active sibling gaps") {
        let spacer = ProgramElement(id: id(3), content: .spacer(minimum: 0))
        let gate = choose(2, .systemProperty(.batteryCharging), [spacer])
        for vertical in [false, true] {
            let children = [leaf(1), gate, leaf(4)]
            let content: ProgramElement.Content = vertical
                ? .column(spacing: 4, align: .left, children: children)
                : .row(spacing: 4, align: .top, children: children)
            var value = try runtime(ProgramElement(id: id(0), content: content,
                width: .fixed(vertical ? 20 : 100), height: .fixed(vertical ? 100 : 20)))
            let shown = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
            t.equal(shown.elements.map(\.id), [0, 1, 3, 4].map(id))
            t.equal(shown.elements[2].frame, vertical ? SkinRect(y: 14, width: 0, height: 72) : SkinRect(x: 14, width: 72, height: 0))
            t.equal(vertical ? shown.elements[3].frame.y : shown.elements[3].frame.x, 90)
            let gone = try value.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: measure)
            t.equal(gone.elements.map(\.id), [0, 1, 4].map(id))
            t.equal(vertical ? gone.elements[2].frame.y : gone.elements[2].frame.x, 14)
        }
    }

    t.suite("Program: view if: Freeform placement and preset fitting include only selected real boxes") {
        let large = ProgramElement(id: id(2), content: .rectangle(fill: .literal(.clear)),
            width: .fixed(200), height: .fixed(100), cornerRadius: .points(3),
            onClickActions: [.copy(.string("large"))], position: ProgramPosition(x: -20, y: -10),
            background: .glass(style: .regular), voiceOver: .string("Large"))
        let small = ProgramElement(id: id(3), content: .rectangle(fill: .literal(blue)),
            width: .fixed(10), height: .fixed(10), position: ProgramPosition(x: 15, y: 10))
        let root = ProgramElement(id: id(0), content: .freeform(align: .center,
            children: [choose(1, .systemProperty(.batteryCharging), [large], otherwise: [small])]))
        var fit = try runtime(root)
        let first = try fit.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(first.size, SkinSize(width: 180, height: 90))
        t.equal(first.elements[1].frame, SkinRect(x: -20, y: -10, width: 200, height: 100))
        let second = try fit.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: measure)
        t.equal(second.size, SkinSize(width: 25, height: 20)); t.equal(second.elements.map(\.id), [0, 3].map(id))
        var preset = try runtime(root, size: .preset(.small, size: SkinSize(width: 100, height: 50)))
        let scaled = try preset.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(scaled.size, SkinSize(width: 100, height: 50))
        t.equal(scaled.elements[0].frame, SkinRect(x: 10, y: 5, width: 50, height: 25))
        t.equal(scaled.elements[1].frame, SkinRect(width: 100, height: 50))
        t.equal(scaled.elements[1].glass?.rect, scaled.elements[1].frame)
        t.equal(scaled.elements[1].glass?.cornerRadius, 1.5)
        t.equal(scaled.elements[1].accessibilityLabel, "Large"); t.equal(scaled.hitMap.entries.first?.frame, scaled.elements[1].frame)
        let unscaled = try preset.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false), measure: measure)
        t.equal(unscaled.elements[0].frame, SkinRect(width: 100, height: 50)); t.check(unscaled.hitMap.entries.isEmpty)
        let restored = try preset.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: true), measure: measure)
        t.equal(restored.elements.map(\.frame), scaled.elements.map(\.frame)); t.equal(restored.elements[1].glass, scaled.elements[1].glass)
        failure(.invalidGeometry(id(2))) { _ = try runtime(column([choose(1, .boolean(true), [large])])) }
    }

    t.suite("Program: view if: widget declarations persist across arms and sampling demand remains conservative") {
        let declarations = [
            ProgramDeclaration(name: "frozen", kind: .variable, initial: .systemProperty(.cpuUsage)),
            ProgramDeclaration(name: "live", kind: .computed, initial: .systemProperty(.memoryUsage))
        ]
        let first = ProgramElement(id: id(2), content: .text(ProgramText(value: .formatNumber(.declaration(0), ProgramNumberFormat(decimals: 0)))))
        let second = ProgramElement(id: id(3), content: .text(ProgramText(value: .formatNumber(.declaration(1), ProgramNumberFormat(decimals: 0)))))
        var value = try runtime(column([choose(1, .systemProperty(.batteryCharging), [first], otherwise: [second])]), declarations: declarations)
        t.equal(value.neededSystemProperties, [.cpuUsage, .memoryUsage, .batteryCharging])
        t.equal(texts(try value.project(environment: environment, dateInput: date(),
            systemInput: ProgramSystemInput(cpuUsage: 25, memoryUsed: 75, memoryTotal: 100, batteryCharging: false), measure: measure)), ["75"])
        t.equal(value.clockPrecision, .twoSeconds)
        t.equal(value.neededSystemProperties, [.memoryUsage, .batteryCharging])
        t.equal(texts(try value.project(environment: environment, dateInput: date(),
            systemInput: ProgramSystemInput(cpuUsage: 90, memoryUsed: 10, memoryTotal: 100, batteryCharging: true), measure: measure)), ["25"])
        t.equal(value.clockPrecision, nil, "frozen variable reads do not regain the initializer's cadence")
        t.equal(value.neededSystemProperties, [.memoryUsage, .batteryCharging], "inactive live arms stay in the pre-sampling union")
        t.equal(texts(try value.project(environment: environment, dateInput: date(),
            systemInput: ProgramSystemInput(memoryUsed: 30, memoryTotal: 100, batteryCharging: false), measure: measure)), ["30"])
    }

    t.suite("Program: view if: action-driven replacement commits effects labels and hits only after measurement succeeds") {
        let button = ProgramElement(id: id(1), content: .rectangle(fill: .literal(.white)), width: .fixed(10), height: .fixed(10),
            onClickActions: [.assign(ProgramAssignment(declaration: 0, value: .boolean(true))), .copy(.string("switched"))])
        let next = ProgramElement(id: id(3), content: .icon(ProgramIcon(name: .string("next"))), width: .fixed(10), height: .fixed(10),
            onClickActions: [.assign(ProgramAssignment(declaration: 0, value: .boolean(false))), .copy(.string("departed"))],
            onRightClickActions: [.copy(.string("new secondary"))], voiceOver: .string("New"))
        let previous = ProgramElement(id: id(4), content: .rectangle(fill: .literal(.white)), width: .fixed(10), height: .fixed(10),
            onClickActions: [.copy(.string("old"))], voiceOver: .string("Old"))
        var value = try runtime(column([button, choose(2, .declaration(0), [next], otherwise: [previous])]),
            declarations: [ProgramDeclaration(name: "page", kind: .variable, initial: .boolean(false))])
        let initial = try value.project(environment: environment, measure: measure)
        failure(.invalidMeasurement(id(3))) {
            _ = try value.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: initial.generation,
                environment: environment, measureIcon: { _ in SkinSize(width: .nan, height: 10) }, measure: measure)
        }
        t.equal(value.generation, initial.generation)
        let retained = try value.clickWithEffects(at: SkinPoint(x: 1, y: 11), expectedGeneration: initial.generation,
            environment: environment, measure: measure)
        t.equal(retained?.effects, [.copy("old")]); t.equal(retained?.scene.elements.map(\.id), [0, 1, 4].map(id))
        let symbols: (IconRequest) throws -> SkinSize? = { _ in SkinSize(width: 10, height: 10) }
        let switched = try value.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: value.generation,
            environment: environment, measureIcon: symbols, measure: measure)
        t.equal(switched?.effects, [.copy("switched")]); t.equal(switched?.scene.elements.map(\.id), [0, 1, 3].map(id))
        t.equal(switched?.scene.elements.last?.accessibilityLabel, "New")
        t.check(switched?.scene.hitMap.entries.contains(where: { $0.elementID == id(4) }) == false)
        let secondary = try value.clickWithEffects(at: SkinPoint(x: 1, y: 11), expectedGeneration: value.generation, event: .rightUp,
            environment: environment, measureIcon: symbols, measure: measure)
        t.equal(secondary?.effects, [.copy("new secondary")])
        let removed = try value.clickWithEffects(at: SkinPoint(x: 1, y: 11), expectedGeneration: value.generation,
            environment: environment, measure: measure)
        t.equal(removed?.effects, [.copy("departed")]); t.equal(removed?.scene.elements.map(\.id), [0, 1, 4].map(id))
        t.equal(removed?.scene.elements.last?.accessibilityLabel, "Old")
        t.check(try value.clickWithEffects(at: SkinPoint(x: 1, y: 11), expectedGeneration: initial.generation,
            environment: environment, measure: measure) == nil)
    }

    t.suite("Program: view if: structural items reject every box decoration and cannot replace the real root") {
        let content = ProgramElement.Content.conditional(ProgramConditional(
            branches: [ProgramConditionalBranch(condition: .boolean(true), body: [leaf(2)])]))
        let malformed = [
            ProgramElement(id: id(1), content: content, width: .fixed(0)),
            ProgramElement(id: id(1), content: content, height: .fill),
            ProgramElement(id: id(1), content: content, padding: SkinInsets(top: 1)),
            ProgramElement(id: id(1), content: content, hidden: true),
            ProgramElement(id: id(1), content: content, minWidth: 1),
            ProgramElement(id: id(1), content: content, maxWidth: 0),
            ProgramElement(id: id(1), content: content, minHeight: 1),
            ProgramElement(id: id(1), content: content, maxHeight: 0),
            ProgramElement(id: id(1), content: content, idealSize: SkinSize()),
            ProgramElement(id: id(1), content: content, stroke: ProgramShapeStroke(color: .literal(.clear), width: 0)),
            ProgramElement(id: id(1), content: content, cornerRadius: .points(0)),
            ProgramElement(id: id(1), content: content, onClick: []),
            ProgramElement(id: id(1), content: content, onClickActions: []),
            ProgramElement(id: id(1), content: content, onRightClickActions: []),
            ProgramElement(id: id(1), content: content, position: ProgramPosition()),
            ProgramElement(id: id(1), content: content, background: .color(.literal(.clear))),
            ProgramElement(id: id(1), content: content, voiceOver: .string("")),
            ProgramElement(id: id(1), content: content, hiddenIf: .boolean(false))
        ]
        for item in malformed { failure(.invalidGeometry(id(1))) { _ = try runtime(column([item])) } }
        failure(.invalidGeometry(id(1))) { _ = try runtime(ProgramElement(id: id(1), content: content)) }
        let emptyArms = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [], otherwise: [leaf(2)])))
        failure(.invalidGeometry(id(1))) { _ = try runtime(column([emptyArms])) }
    }

    t.suite("Program: view if: inactive arms still validate types identities geometry paint and actions") {
        for bad in [ProgramExpression.number(1), .string("true"), .timeNow] {
            let item = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
                ProgramConditionalBranch(condition: .boolean(true), body: [leaf(2)]),
                ProgramConditionalBranch(condition: bad, body: [leaf(3)])])))
            failure(.invalidExpression) { _ = try runtime(column([item])) }
        }
        failure(.duplicateIdentity(id(2))) {
            _ = try runtime(column([choose(1, .boolean(true), [leaf(2)], otherwise: [leaf(2)])]))
        }
        let invalid: [(ProgramElement, ProgramRuntimeError)] = [
            (leaf(3, width: -1), .invalidGeometry(id(3))),
            (ProgramElement(id: id(3), content: .rectangle(fill: .literal(RGBA(r: .nan, g: 0, b: 0))),
                width: .fixed(10), height: .fixed(10)), .invalidPaint(id(3))),
            (ProgramElement(id: id(3), content: .text(ProgramText("bad", fontSize: 0))), .invalidText(id(3))),
            (ProgramElement(id: id(3), content: .image(ProgramImage(source: ""))), .invalidImage(id(3))),
            (ProgramElement(id: id(3), content: .text(ProgramText("bad")), voiceOver: .number(1)), .invalidExpression),
            (ProgramElement(id: id(3), content: .text(ProgramText("bad")),
                onClickActions: [.assign(ProgramAssignment(declaration: 99, value: .boolean(true)))]), .invalidDeclaration(99))
        ]
        for (node, error) in invalid {
            failure(error) { _ = try runtime(column([choose(1, .boolean(true), [leaf(2)], otherwise: [node])])) }
        }
    }

    t.suite("Program: view if: all arms share node depth and expression budgets before selection") {
        let leaves = (2..<ProgramLimits.maximumElements).map { leaf($0, width: 1, height: 1) }
        _ = try runtime(column([choose(1, .boolean(false), leaves)]))
        failure(.elementLimit) {
            _ = try runtime(column([choose(1, .boolean(false), leaves + [leaf(ProgramLimits.maximumElements)])]))
        }
        func nested(_ count: Int) -> ProgramElement {
            var node = leaf(1000)
            for index in stride(from: count, through: 1, by: -1) { node = choose(index, .boolean(true), [node]) }
            return column([node])
        }
        var deepest = try runtime(nested(ProgramLimits.maximumDepth - 2))
        t.equal(try deepest.project(environment: environment, measure: measure).elements.map(\.id), [id(0), id(1000)])
        failure(.depthLimit) { _ = try runtime(nested(ProgramLimits.maximumDepth - 1)) }
        func textBudget(_ count: Int) -> ProgramElement {
            column([choose(1, .boolean(false), [ProgramElement(id: id(2), content: .text(ProgramText(value:
                .concatenate(Array(repeating: .string("x"), count: count)))))])])
        }
        _ = try runtime(textBudget(ProgramLimits.maximumExpressions - 2))
        failure(.expressionLimit) { _ = try runtime(textBudget(ProgramLimits.maximumExpressions - 1)) }
        let branch = ProgramConditionalBranch(condition: .boolean(true), body: [])
        func branchBudget(_ count: Int) -> ProgramElement {
            column([ProgramElement(id: id(1), content: .conditional(ProgramConditional(
                branches: Array(repeating: branch, count: count), otherwise: [leaf(2)])))])
        }
        _ = try runtime(branchBudget(ProgramLimits.maximumExpressions))
        failure(.expressionLimit) { _ = try runtime(branchBudget(ProgramLimits.maximumExpressions + 1)) }
        var deep = ProgramExpression.boolean(true)
        for _ in 0..<ProgramLimits.maximumExpressionDepth { deep = .not(deep) }
        failure(.expressionDepth) { _ = try runtime(column([choose(1, deep, [leaf(2)])])) }
    }
}
