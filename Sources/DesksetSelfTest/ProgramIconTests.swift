import Foundation
@testable import DesksetCore

func runProgramIconTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "icons"), imageGeneration: 0)
    let dark = EnvironmentStamp(scale: 2, fontGeneration: 1,
        appearance: AppearanceStamp(value: .dark, name: "icons-dark"), imageGeneration: 0)
    let rootID = ElementID(name: "icon", index: 0)
    let noText: (String, TextStyle, Double?) throws -> SkinSize = { _, _, _ in
        t.check(false, "Icon does not measure itself as Text"); return SkinSize()
    }
    let wide = SkinSize(width: 24, height: 12)
    func element(_ icon: ProgramIcon, width: ProgramLength = .fit, height: ProgramLength = .fit,
                 hidden: Bool = false, padding: SkinInsets = .zero, actions: [ProgramAction]? = nil,
                 voiceOver: ProgramExpression? = nil) -> ProgramElement {
        ProgramElement(id: rootID, content: .icon(icon), width: width, height: height, padding: padding,
            hidden: hidden, onClickActions: actions, voiceOver: voiceOver)
    }
    func icons(_ items: [DrawItem]) -> [IconDraw] {
        items.flatMap { item -> [IconDraw] in
            switch item {
            case .icon(let draw): return [draw]
            case .transformed(_, let children), .antialias(_, let children): return icons(children)
            case .container(_, let mask, let content): return icons(mask) + icons(content)
            default: return []
            }
        }
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }

    t.suite("Program: icons: typed requests preserve complete font color appearance and rendering without file resources") {
        let red = RGBA(r: 210, g: 30, b: 40, a: 128)
        for colors in IconColors.allCases {
            for family in ["System", "System Rounded", "System Serif", "System Mono", "Custom Face"] {
                let icon = ProgramIcon(name: .string("wifi"), fontFamily: family, fontSize: 20,
                    fontWeight: 650, italic: true, color: .literal(red), align: .right, colors: colors, hasOwnFont: true)
                var runtime = try ProgramRuntime(program: WidgetProgram(name: "Full font", root: element(icon)))
                var requests: [IconRequest] = []
                let scene = try runtime.project(environment: dark, measureIcon: { request in requests.append(request); return wide }, measure: noText)
                guard let draw = icons(scene.drawingItems).first, let request = requests.first else { return t.check(false, "typed symbol recipe") }
                t.equal(requests.count, 1); t.equal(draw.request, request); t.equal(draw.naturalSize, wide)
                t.equal(request.name, "wifi"); t.equal(request.colors, colors); t.equal(request.appearance, dark.appearance)
                t.equal(request.scale, 2, "native measurement uses the actual destination scale")
                t.equal(request.style.fontFace, family); t.equal(request.style.fontSize, 15)
                t.equal(request.style.fontWeight, 650); t.check(request.style.italic); t.equal(request.style.color, red)
                t.equal(request.style.horizontalAlign, .right); t.equal(request.style.verticalAlign, .center)
                t.check(!request.style.wrap); t.equal(scene.size, wide)
                t.equal(draw.contentFrame, SkinRect(width: 24, height: 12)); t.equal(scene.elements[0].kind, .image)
                t.check(scene.elements[0].imageDependencies.isEmpty); t.check(scene.backgroundImageDependencies.isEmpty)
                t.equal(runtime.clockPrecision, nil)
            }
        }
        t.equal(ProgramIcon(name: .string("wifi")).colors, .monochrome)
        var scaled = try ProgramRuntime(program: WidgetProgram(name: "Scale", root: element(ProgramIcon(name: .string("wifi")))))
        for input in [environment, dark, environment] {
            let scene = try scaled.project(environment: input, measureIcon: { request in
                t.equal(request.scale, input.scale)
                return SkinSize(width: 20 + request.scale, height: 10)
            }, measure: noText)
            t.equal(scene.size, SkinSize(width: 20 + input.scale, height: 10))
        }
    }

    t.suite("Program: icons: fixed boxes fit inherited fonts while explicit own fonts retain natural geometry") {
        let padding = SkinInsets(left: 4, top: 2, right: 6, bottom: 4)
        for own in [false, true] {
            let icon = ProgramIcon(name: .string("wifi"), fontFamily: "System Rounded", fontSize: 48,
                fontWeight: 700, italic: true, hasOwnFont: own)
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Font ownership", root:
                element(icon, width: .fixed(40), height: .fixed(30), padding: padding)))
            let scene = try runtime.project(environment: environment, measureIcon: { _ in wide }, measure: noText)
            t.equal(scene.elements[0].frame, SkinRect(width: 40, height: 30))
            t.equal(icons(scene.drawingItems).first?.contentFrame,
                own ? SkinRect(x: 7, y: 8, width: 24, height: 12) : SkinRect(x: 4, y: 6.5, width: 30, height: 15))
        }
        for (align, x) in [(HorizontalTextAlign.left, 4.0), (.center, 13.0), (.right, 22.0)] {
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Aligned fit", root:
                element(ProgramIcon(name: .string("person"), align: align), width: .fixed(40), height: .fixed(30), padding: padding)))
            let scene = try runtime.project(environment: environment, measureIcon: { _ in SkinSize(width: 12, height: 24) }, measure: noText)
            t.equal(icons(scene.drawingItems).first?.contentFrame, SkinRect(x: x, y: 2, width: 12, height: 24))
        }
        var oneAxis = try ProgramRuntime(program: WidgetProgram(name: "One fixed axis", root:
            element(ProgramIcon(name: .string("wifi")), width: .fixed(10))))
        let single = try oneAxis.project(environment: environment, measureIcon: { _ in wide }, measure: noText)
        t.equal(single.size, SkinSize(width: 10, height: 12))
        t.equal(icons(single.drawingItems).first?.contentFrame, SkinRect(x: -7, width: 24, height: 12))
    }

    t.suite("Program: icons: unknown and empty names draw nothing while fixed boxes background hits and labels survive") {
        // There is no public String-valued data source yet. Seed its typed missing scalar at the evaluator
        // boundary, while the runtime cases below verify that an absent name never reaches the symbol provider.
        var missing = ProgramExpressionEvaluation(declarations: [ProgramDeclaration(name: "name", kind: .variable, initial: .string("wifi"))],
            dark: false, variables: [.missing(.string)])
        t.equal(try missing.iconName(.declaration(0)), nil)
        t.equal(try missing.iconName(.ifMissing(.declaration(0), .string("wifi"))), "wifi")
        t.equal(try missing.iconName(.string("–")), "–", "a literal dash is a name, not a missing sentinel")
        failure(.invalidExpression) { _ = try missing.iconName(.number(1)) }
        for name in ["", "not-a-known-symbol"] {
            let node = ProgramElement(id: rootID, content: .icon(ProgramIcon(name: .string(name))),
                width: .fixed(40), height: .fixed(30), onClickActions: [.copy(.string("empty"))],
                background: .glass(style: .regular), voiceOver: .string("Unavailable icon"))
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Unknown", root: node))
            var calls = 0
            let scene = try runtime.project(environment: environment, measureIcon: { _ in calls += 1; return nil }, measure: noText)
            t.equal(calls, name.isEmpty ? 0 : 1); t.check(icons(scene.drawingItems).isEmpty)
            t.equal(scene.elements[0].frame, SkinRect(width: 40, height: 30))
            t.equal(scene.elements[0].glass?.rect, scene.elements[0].frame)
            t.equal(scene.elements[0].accessibilityLabel, "Unavailable icon")
            t.equal(scene.hitMap.entry(at: 5, 5, handling: .leftUp, images: nil)?.elementID, rootID)
            let clicked = try runtime.clickWithEffects(at: SkinPoint(x: 5, y: 5), expectedGeneration: scene.generation,
                environment: environment, measureIcon: { _ in nil }, measure: noText)
            t.equal(clicked?.effects, [.copy("empty")]); t.check(clicked.map { icons($0.scene.drawingItems).isEmpty } == true)
        }
        var natural = try ProgramRuntime(program: WidgetProgram(name: "Unknown natural", root: element(ProgramIcon(name: .string("unknown")))))
        let empty = try natural.project(environment: environment, measureIcon: { _ in nil }, measure: noText)
        t.equal(empty.size, SkinSize()); t.check(empty.drawingItems.isEmpty)
        var literal = try ProgramRuntime(program: WidgetProgram(name: "Literal dash", root: element(ProgramIcon(name: .string("–")))))
        var literalCalls = 0
        _ = try literal.project(environment: environment, measureIcon: { request in
            literalCalls += 1; t.equal(request.name, "–"); return nil
        }, measure: noText)
        t.equal(literalCalls, 1)
        for (width, height) in [(0.0, 20.0), (20.0, 0.0)] {
            var zero = try ProgramRuntime(program: WidgetProgram(name: "Zero fitted box", root:
                element(ProgramIcon(name: .string("wifi")), width: .fixed(width), height: .fixed(height))))
            t.check(try zero.project(environment: environment, measureIcon: { _ in wide }, measure: noText).drawingItems.isEmpty)
        }
    }

    t.suite("Program: icons: names and live font sizes share one projection snapshot and visible display cadence") {
        let name = ProgramExpression.conditional(.systemProperty(.batteryCharging), then: .string("bolt"), otherwise: .string("battery"))
        let size = ProgramExpression.add(.number(10), .divide(.systemProperty(.cpuUsage), .quantity(ProgramNumber(1, dimension: .percent))))
        let icon = ProgramIcon(name: .declaration(0), fontSizeExpression: size)
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Live icon", root: element(icon),
            declarations: [ProgramDeclaration(name: "symbol", kind: .computed, initial: name)]))
        t.equal(runtime.neededSystemProperties, [.batteryCharging, .cpuUsage])
        var requests: [IconRequest] = []
        let measureIcon: (IconRequest) throws -> SkinSize? = { request in
            requests.append(request); return SkinSize(width: request.style.fontSize * (96.0 / 72.0), height: 10)
        }
        let first = try runtime.project(environment: environment, systemInput: ProgramSystemInput(cpuUsage: 10, batteryCharging: true),
            measureIcon: measureIcon, measure: noText)
        t.equal(requests.last?.name, "bolt"); t.equal(requests.last?.style.fontSize, 15)
        t.equal(first.size, SkinSize(width: 20, height: 10)); t.equal(runtime.clockPrecision, .second)
        let next = try runtime.project(environment: dark, systemInput: ProgramSystemInput(cpuUsage: 30, batteryCharging: false),
            measureIcon: measureIcon, measure: noText)
        t.equal(requests.count, 2); t.equal(requests.last?.name, "battery"); t.equal(requests.last?.style.fontSize, 30)
        t.equal(requests.last?.style.color, dark.appearance.value.labelColor)
        t.equal(next.size, SkinSize(width: 40, height: 10)); t.equal(runtime.clockPrecision, .second)
        t.equal(icons(first.drawingItems).first?.request.name, "bolt")
    }

    t.suite("Program: icons: hidden symbols retain measured slots and layout dependencies without label or timer demand") {
        let name = ProgramExpression.conditional(.systemProperty(.batteryCharging), then: .string("bolt"), otherwise: .string("battery"))
        let icon = ProgramIcon(name: name, fontSizeExpression: .systemProperty(.cpuCoreCount))
        let label = ProgramExpression.concatenate([.formatDate(.timeNow, .pattern("HH:mm:ss")), .systemProperty(.memoryUsed)])
        let hidden = element(icon, hidden: true, voiceOver: label)
        let sibling = ProgramElement(id: ElementID(name: "sibling", index: 1), content: .rectangle(fill: .literal(.white)),
            width: .fixed(40), height: .fixed(40))
        let root = ProgramElement(id: ElementID(name: "root", index: 2), content: .column(spacing: 3, align: .center, children: [hidden, sibling]))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Hidden icon", root: root))
        t.equal(runtime.neededSystemProperties, [.batteryCharging, .cpuCoreCount])
        var calls = 0
        let scene = try runtime.project(environment: environment, systemInput: ProgramSystemInput(cpuCoreCount: 8, batteryCharging: true),
            measureIcon: { request in calls += 1; t.equal(request.name, "bolt"); return wide }, measure: noText)
        t.equal(calls, 1, "repeated stack proposals reuse a single symbol measurement")
        t.equal(scene.size, SkinSize(width: 40, height: 55))
        t.equal(scene.elements[1].frame, SkinRect(x: 8, width: 24, height: 12))
        t.equal(scene.elements[1].visibility, .hiddenKeepsSpace); t.equal(scene.elements[1].accessibilityLabel, nil)
        t.check(icons(scene.drawingItems).isEmpty); t.equal(runtime.clockPrecision, nil)
        var dynamicHidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden date name", root:
            element(ProgramIcon(name: .formatDate(.timeNow, .pattern("HH:mm:ss"))), hidden: true)))
        failure(.invalidDateInput) { _ = try dynamicHidden.project(environment: environment, measureIcon: { _ in wide }, measure: noText) }
        t.equal(dynamicHidden.generation, 0, "hidden names still evaluate for intrinsic layout, unlike hidden voiceOver")
        let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"))
        let dated = try dynamicHidden.project(environment: environment, dateInput: date, measureIcon: { request in
            t.equal(request.name, "00:00:00"); return wide
        }, measure: noText)
        t.equal(dated.size, wide); t.equal(dynamicHidden.clockPrecision, nil)
    }

    t.suite("Program: icons: invalid producers missing measurement and bad resource geometry fail explicitly") {
        for invalid in [ProgramIcon(name: .number(1)), ProgramIcon(name: .boolean(true)), ProgramIcon(name: .timeNow),
                        ProgramIcon(name: .string("wifi"), fontSizeExpression: .boolean(true))] {
            failure(.invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid type", root: element(invalid, hidden: true))) }
        }
        for invalid in [ProgramIcon(name: .string("bad\0name")), ProgramIcon(name: .string("wifi"), fontFamily: ""),
                        ProgramIcon(name: .string("wifi"), fontSize: 0), ProgramIcon(name: .string("wifi"), fontSize: .infinity),
                        ProgramIcon(name: .string("wifi"), fontWeight: 0), ProgramIcon(name: .string("wifi"), color: .literal(RGBA(r: .nan, g: 0, b: 0)))] {
            failure(.invalidIcon(rootID)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid icon", root: element(invalid, hidden: true))) }
        }
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Needs provider", root: element(ProgramIcon(name: .string("wifi")))))
        failure(.missingIconMeasurement(rootID)) { _ = try runtime.project(environment: environment, measure: noText) }
        t.equal(runtime.generation, 0)
        enum ResourceFailure: Error { case unavailable }
        do {
            _ = try runtime.project(environment: environment, measureIcon: { _ in throw ResourceFailure.unavailable }, measure: noText)
            t.check(false, "host resource failures cannot masquerade as unknown names")
        } catch ResourceFailure.unavailable { t.check(true) }
        t.equal(runtime.generation, 0)
        for bad in [SkinSize(), SkinSize(width: -1, height: 10), SkinSize(width: 10, height: 0),
                    SkinSize(width: .nan, height: 10), SkinSize(width: 10, height: .infinity)] {
            failure(.invalidMeasurement(rootID)) { _ = try runtime.project(environment: environment, measureIcon: { _ in bad }, measure: noText) }
            t.equal(runtime.generation, 0)
        }
        let huge = String(repeating: "x", count: ProgramLimits.maximumTextLength + 1)
        failure(.invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Long name", root: element(ProgramIcon(name: .string(huge))))) }
        var deep = ProgramExpression.string("wifi")
        for _ in 0..<ProgramLimits.maximumExpressionDepth { deep = .concatenate([deep]) }
        failure(.expressionDepth) { _ = try ProgramRuntime(program: WidgetProgram(name: "Deep name", root: element(ProgramIcon(name: deep)))) }
        let crowded = ProgramExpression.concatenate(Array(repeating: .string("x"), count: ProgramLimits.maximumExpressions - 1))
        failure(.expressionLimit) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Shared budget", root:
                element(ProgramIcon(name: crowded, fontSizeExpression: .number(20)))))
        }
        var tiny = try ProgramRuntime(program: WidgetProgram(name: "Finite fit", root:
            element(ProgramIcon(name: .string("wifi")), width: .fixed(40), height: .fixed(20))))
        let scene = try tiny.project(environment: environment,
            measureIcon: { _ in SkinSize(width: Double.leastNonzeroMagnitude, height: Double.leastNonzeroMagnitude) }, measure: noText)
        t.equal(icons(scene.drawingItems).first?.contentFrame, SkinRect(x: 10, width: 20, height: 20))
    }

    t.suite("Program: icons: failed symbol measurement rolls back dynamic names actions and accessibility labels") {
        let icon = ProgramIcon(name: .declaration(0))
        let actions: [ProgramAction] = [.assign(ProgramAssignment(declaration: 0, value: .string("new"))), .copy(.declaration(0))]
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Icon transaction", root:
            element(icon, width: .fixed(40), height: .fixed(30), actions: actions, voiceOver: .declaration(0)),
            declarations: [ProgramDeclaration(name: "name", kind: .variable, initial: .string("old"))]))
        let first = try runtime.project(environment: environment, measureIcon: { _ in wide }, measure: noText)
        failure(.invalidMeasurement(rootID)) {
            _ = try runtime.clickWithEffects(at: SkinPoint(x: 2, y: 2), expectedGeneration: first.generation,
                environment: environment, measureIcon: { _ in SkinSize(width: .nan, height: 10) }, measure: noText)
        }
        t.equal(runtime.generation, first.generation)
        let recovered = try runtime.project(environment: environment, measureIcon: { request in
            t.equal(request.name, "old"); return wide
        }, measure: noText)
        t.equal(recovered.elements[0].accessibilityLabel, "old"); t.equal(recovered.hitMap, first.hitMap)
        let changed = try runtime.clickWithEffects(at: SkinPoint(x: 2, y: 2), expectedGeneration: recovered.generation,
            environment: environment, measureIcon: { _ in wide }, measure: noText)
        t.equal(changed?.effects, [.copy("new")]); t.equal(changed?.scene.elements[0].accessibilityLabel, "new")
        t.equal(changed.flatMap { icons($0.scene.drawingItems).first?.request.name }, "new")
        t.equal(icons(first.drawingItems).first?.request.name, "old")
        t.check(try runtime.clickWithEffects(at: SkinPoint(x: 2, y: 2), expectedGeneration: first.generation,
            environment: environment, measureIcon: { _ in wide }, measure: noText) == nil)
    }

    t.suite("Program: icons: preset fitting includes actual glyph overflow once and keeps box background hits and labels aligned") {
        let child = ProgramElement(id: rootID, content: .icon(ProgramIcon(name: .string("wide"), hasOwnFont: true)),
            width: .fixed(20), height: .fixed(20), cornerRadius: .full, onClickActions: [.copy(.string("icon"))],
            position: ProgramPosition(x: -30, y: -10), background: .glass(style: .clear), voiceOver: .string("Wide symbol"))
        let root = ProgramElement(id: ElementID(name: "root", index: 1), content: .freeform(align: .topLeft, children: [child]),
            width: .fixed(100), height: .fixed(100), background: .color(.literal(.black)))
        let measureIcon: (IconRequest) throws -> SkinSize? = { _ in SkinSize(width: 200, height: 100) }
        var fit = try ProgramRuntime(program: WidgetProgram(name: "Overflow", root: root))
        let raw = try fit.project(environment: environment, measureIcon: measureIcon, measure: noText)
        t.equal(raw.elements[1].frame, SkinRect(x: -30, y: -10, width: 20, height: 20))
        t.equal(icons(raw.drawingItems).first?.contentFrame, SkinRect(x: -120, y: -50, width: 200, height: 100))
        var preset = try ProgramRuntime(program: WidgetProgram(name: "Preset overflow", root: root,
            size: .preset(.small, size: SkinSize(width: 100, height: 100))))
        let scene = try preset.project(environment: environment, measureIcon: measureIcon, measure: noText)
        guard case .transformed(let matrix, let items)? = scene.elements[1].items.first,
              let draw = icons(items).first else { return t.check(false, "one final transform around the measured symbol") }
        t.close(matrix.a, 5.0 / 11); t.close(matrix.d, 5.0 / 11)
        t.close(matrix.tx, 600.0 / 11); t.close(matrix.ty, 250.0 / 11)
        t.equal(draw.contentFrame, SkinRect(x: -120, y: -50, width: 200, height: 100))
        t.close(scene.elements[1].frame.x, 450.0 / 11); t.close(scene.elements[1].frame.y, 200.0 / 11)
        t.close(scene.elements[1].frame.width, 100.0 / 11); t.close(scene.elements[1].frame.height, 100.0 / 11)
        t.equal(scene.elements[1].glass?.rect, scene.elements[1].frame)
        t.close(scene.elements[1].glass?.cornerRadius ?? -1, 50.0 / 11)
        t.equal(scene.elements[1].accessibilityLabel, "Wide symbol")
        t.equal(scene.hitMap.entry(at: 45, 22.5, handling: .leftUp, images: nil)?.elementID, rootID)
        t.equal(scene.hitMap.entry(at: 10, 10, handling: .leftUp, images: nil)?.elementID, nil,
                "overflowing glyph ink does not enlarge the authored hit box")
        let clicked = try preset.clickWithEffects(at: SkinPoint(x: 45, y: 22.5), expectedGeneration: scene.generation,
            environment: environment, measureIcon: measureIcon, measure: noText)
        t.equal(clicked?.effects, [.copy("icon")]); t.equal(clicked?.scene.elements[1].frame, scene.elements[1].frame)
    }
}
