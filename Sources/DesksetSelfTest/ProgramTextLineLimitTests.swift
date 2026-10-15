import Foundation
@testable import DesksetCore

func runProgramTextLineLimitTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "text-lines"), imageGeneration: 0)
    let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!,
                                locale: Locale(identifier: "en_US_POSIX"))
    func id(_ index: Int = 0) -> ElementID { ElementID(name: "text-lines:\(index)", index: index) }
    func runtime(_ root: ProgramElement, size: ProgramWidgetSize = .fit) throws -> ProgramRuntime {
        try ProgramRuntime(program: WidgetProgram(name: "Text lines", root: root, size: size))
    }
    func texts(_ items: [DrawItem]) -> [TextDraw] {
        items.flatMap { item -> [TextDraw] in
            switch item {
            case .text(let text): return [text]
            case .transformed(_, let children), .antialias(_, let children): return texts(children)
            case .container(_, let mask, let content): return texts(mask) + texts(content)
            default: return []
            }
        }
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }

    t.suite("Program: text lines: optional limits validate every branch without spending expression budget") {
        t.equal(ProgramText("A").maximumLines, nil)
        t.equal(ProgramText(value: .string("A")).maximumLines, nil)
        t.equal(TextStyle().maximumLines, nil)
        for limit in [Int?.none, 1, 1000] {
            let literal = ProgramText("A", maximumLines: limit)
            let expression = ProgramText(value: .string("A"), maximumLines: limit)
            t.equal(literal, expression)
            _ = try runtime(ProgramElement(id: id(), content: .text(literal)))
        }
        for limit in [Int.min, -1, 0, 1001, Int.max] {
            for hidden in [false, true] {
                failure(.invalidText(id(1))) {
                    _ = try runtime(ProgramElement(id: id(1), content: .text(ProgramText("A", maximumLines: limit)), hidden: hidden))
                }
            }
            let child = ProgramElement(id: id(1), content: .text(ProgramText(value: .string("A"), maximumLines: limit)))
            let gate = ProgramElement(id: id(2), content: .conditional(ProgramConditional(branches: [
                ProgramConditionalBranch(condition: .boolean(false), body: [child])
            ])))
            failure(.invalidText(id(1))) {
                _ = try runtime(ProgramElement(id: id(), content: .column(spacing: 0, align: .left, children: [gate])))
            }
        }
        var limitedStyle = TextStyle()
        limitedStyle.maximumLines = 1
        t.equal(Set([TextStyle(), limitedStyle]).count, 2, "layout cache keys distinguish the limit")
        func budget(_ count: Int) -> ProgramElement {
            ProgramElement(id: id(), content: .text(ProgramText(value: .concatenate(
                Array(repeating: .string("a"), count: count)), maximumLines: 1)), hidden: true)
        }
        _ = try runtime(budget(ProgramLimits.maximumExpressions - 1))
        failure(.expressionLimit) { _ = try runtime(budget(ProgramLimits.maximumExpressions)) }
    }

    t.suite("Program: text lines: measured visible line metrics drive padding and the unchanged drawing recipe") {
        let content = "alpha beta gamma delta"
        for limit in [Int?.none, 1, 2] {
            let root = ProgramElement(id: id(), content: .text(ProgramText(content, fontSize: 20, maximumLines: limit)),
                width: .fixed(44), padding: SkinInsets(left: 2, top: 3, right: 2, bottom: 5))
            var value = try runtime(root)
            var queries: [(TextStyle, Double?)] = []
            // A controlled host reports unequal line heights. Core must use these metrics, not fontSize * limit.
            let visibleHeight = limit == 1 ? 12.0 : (limit == 2 ? 28.0 : 48.0)
            let scene = try value.project(environment: environment) { text, style, width in
                t.equal(text, content); t.equal(style.maximumLines, limit); t.equal(style.clip, 0)
                queries.append((style, width))
                return width == nil ? SkinSize(width: 100, height: 12) : SkinSize(width: 40, height: visibleHeight)
            }
            guard let draw = texts(scene.drawingItems).first, queries.count == 2 else {
                return t.check(false, "text recipe measured once at its ideal and assigned width")
            }
            t.equal(queries[0].1, nil); t.equal(queries[1].1, 40)
            t.equal(draw.style, queries[1].0); t.check(draw.style.wrap)
            t.equal(draw.style.maximumLines, limit); t.equal(draw.style.clip, 0)
            t.close(TextStyle.pixelSize(points: draw.style.fontSize), 20)
            t.equal(draw.text, content)
            t.equal(scene.size, SkinSize(width: 44, height: visibleHeight + 8))
            t.equal(draw.frame, SkinRect(width: 44, height: visibleHeight + 8))
            t.equal(draw.contentFrame, SkinRect(x: 2, y: 3, width: 40, height: visibleHeight))
        }
        var empty = try runtime(ProgramElement(id: id(), content: .text(ProgramText("", maximumLines: 1))))
        let emptyScene = try empty.project(environment: environment) { text, style, _ in
            t.equal(text, ""); t.equal(style.maximumLines, 1); return SkinSize()
        }
        t.equal(emptyScene.size, SkinSize()); t.equal(texts(emptyScene.drawingItems).first?.text, "")
    }

    t.suite("Program: text lines: full localized text and UTF16 numeric styles survive the line limit") {
        let expression = ProgramExpression.concatenate([.string("😀 "),
            .formatNumber(.systemProperty(.cpuUsage), ProgramNumberFormat(decimals: 1)), .string("\nTail")])
        for digits in [ProgramText.Digits.automatic, .normal, .equalWidth] {
            let root = ProgramElement(id: id(), content: .text(ProgramText(value: expression, digits: digits, maximumLines: 1)),
                width: .fixed(40), onClickActions: [.copy(expression)], voiceOver: expression,
                tooltip: ProgramTooltip(text: expression, title: .string("Full value")))
            var value = try runtime(root)
            let measure: (String, TextStyle, Double?) throws -> SkinSize = { _, style, width in
                t.equal(style.maximumLines, 1)
                return SkinSize(width: width == nil ? 100 : 40, height: 12)
            }
            let scene = try value.project(environment: environment, dateInput: date,
                systemInput: ProgramSystemInput(cpuUsage: 12.5), measure: measure)
            guard let draw = texts(scene.drawingItems).first else { return t.check(false, "formatted text recipe") }
            t.equal(draw.text, "😀 12.5\nTail")
            let expected: [InlineSpan]
            switch digits {
            case .automatic: expected = [InlineSpan(location: 3, length: 4, setting: .typography(feature: "tnum", value: 1))]
            case .normal: expected = []
            case .equalWidth: expected = [InlineSpan(location: 0, length: 12, setting: .typography(feature: "tnum", value: 1))]
            }
            t.equal(draw.style.inlineSpans, expected)
            t.equal(scene.elements[0].accessibilityLabel, draw.text)
            t.equal(scene.hitMap.entries.first?.toolTip, ToolTipInfo(text: draw.text, title: "Full value"))
            let clicked = try value.clickWithEffects(at: SkinPoint(x: 10, y: 6), expectedGeneration: scene.generation,
                environment: environment, dateInput: date, systemInput: ProgramSystemInput(cpuUsage: 12.5), measure: measure)
            t.equal(clicked?.effects, [.copy("😀 12.5\nTail")])
            let german = ProgramDateInput(instant: date.instant, timeZone: date.timeZone, locale: Locale(identifier: "de_DE"))
            let localized = try value.project(environment: environment, dateInput: german,
                systemInput: ProgramSystemInput(cpuUsage: 12.5), measure: measure)
            t.equal(texts(localized.drawingItems).first?.text, "😀 12,5\nTail")
            let missing = try value.project(environment: environment, dateInput: date,
                systemInput: ProgramSystemInput(), measure: measure)
            t.equal(texts(missing.drawingItems).first?.text, "😀 –\nTail")
            if digits == .automatic { t.equal(texts(missing.drawingItems).first?.style.inlineSpans, []) }
            t.equal(value.clockPrecision, .second)
            t.equal(draw.text, "😀 12.5\nTail", "later layouts leave the original full text unchanged")
        }
    }

    t.suite("Program: text lines: hidden text retains measurement while inactive branches and other content stay independent") {
        let clock = ProgramExpression.concatenate([.formatDate(.timeNow, .pattern("HH:mm:ss")), .string(" tail")])
        let limited = ProgramElement(id: id(1), content: .text(ProgramText(value: clock, maximumLines: 1)), width: .fixed(40))
        let plain = ProgramElement(id: id(2), content: .text(ProgramText("plain")), width: .fixed(40))
        let icon = ProgramElement(id: id(3), content: .icon(ProgramIcon(name: .string("wifi"))))
        var hidden = try runtime(ProgramElement(id: id(), content: .column(spacing: 0, align: .left,
            children: [limited, plain, icon]), hidden: true))
        var limits: [String: Int] = [:], icons = 0
        let hiddenScene = try hidden.project(environment: environment, dateInput: date, measureIcon: { request in
            icons += 1; t.equal(request.style.maximumLines, nil); return SkinSize(width: 10, height: 10)
        }) { text, style, width in
            limits[text] = style.maximumLines ?? 0
            return width == nil ? SkinSize(width: 100, height: 12) :
                SkinSize(width: 40, height: style.maximumLines == nil ? 24 : 12)
        }
        t.equal(limits, ["00:00:00 tail": 1, "plain": 0]); t.equal(icons, 1)
        t.equal(hiddenScene.size, SkinSize(width: 40, height: 46))
        t.check(hiddenScene.drawingItems.isEmpty && hiddenScene.hitMap.entries.isEmpty)
        t.equal(hidden.clockPrecision, nil)

        let live = ProgramElement(id: id(1), content: .text(ProgramText(value: .concatenate([
            .systemProperty(.cpuUsage), .string(" tail")]), maximumLines: 1)), width: .fixed(40))
        let gate = ProgramElement(id: id(2), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .systemProperty(.batteryCharging), body: [live])
        ])))
        var branch = try runtime(ProgramElement(id: id(), content: .column(spacing: 0, align: .left, children: [gate])))
        t.equal(branch.neededSystemProperties, [.batteryCharging, .cpuUsage])
        let absent = try branch.project(environment: environment, systemInput: ProgramSystemInput(batteryCharging: false)) { _, _, _ in
            t.check(false, "an inactive branch does not measure text"); return SkinSize()
        }
        t.equal(absent.elements.map(\.id), [id()]); t.equal(branch.clockPrecision, nil)
        let present = try branch.project(environment: environment, dateInput: date,
            systemInput: ProgramSystemInput(cpuUsage: 25, batteryCharging: true)) { _, style, width in
                t.equal(style.maximumLines, 1)
                return SkinSize(width: width == nil ? 100 : 40, height: 12)
            }
        t.equal(texts(present.drawingItems).first?.text, "25 tail"); t.equal(branch.clockPrecision, .second)
    }

    t.suite("Program: text lines: Freeform and preset fit transform the limited box and interactions once") {
        let fullText = "Full text retained beyond the visible line"
        let child = ProgramElement(id: id(1), content: .text(ProgramText(fullText, maximumLines: 1)),
            width: .fixed(200), height: .fixed(40), padding: SkinInsets(left: 10, top: 4, right: 10, bottom: 4),
            cornerRadius: .points(8), onClickActions: [.copy(.string(fullText))], onRightClickActions: [.copy(.string("secondary"))],
            position: ProgramPosition(x: -100, y: -40), voiceOver: .string(fullText),
            tooltip: ProgramTooltip(text: .string(fullText)), menu: [.item(ProgramMenuItem(title: .string(fullText)))])
        let root = ProgramElement(id: id(), content: .freeform(align: .topLeft, children: [child]),
            width: .fixed(100), height: .fixed(100))
        let measure: (String, TextStyle, Double?) throws -> SkinSize = { _, style, width in
            t.equal(style.maximumLines, 1)
            return width == nil ? SkinSize(width: 300, height: 12) : SkinSize(width: 180, height: 16)
        }
        var raw = try runtime(root)
        let unscaled = try raw.project(environment: environment, measure: measure)
        t.equal(unscaled.elements[1].frame, SkinRect(x: -100, y: -40, width: 200, height: 40))
        var fitted = try runtime(root, size: .preset(.small, size: SkinSize(width: 100, height: 100)))
        let scene = try fitted.project(environment: environment, measure: measure)
        guard case .transformed(let transform, let items)? = scene.elements[1].items.first,
              let draw = texts(items).first else { return t.check(false, "one final transform around the text recipe") }
        t.equal(transform, ShapeTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 50, ty: 20))
        t.equal(scene.elements[1].frame, SkinRect(width: 100, height: 20))
        t.equal(draw.frame, SkinRect(x: -100, y: -40, width: 200, height: 40))
        t.equal(draw.contentFrame, SkinRect(x: -90, y: -36, width: 180, height: 32))
        t.equal(draw.style.maximumLines, 1); t.equal(draw.text, fullText)
        t.equal(scene.elements[1].accessibilityLabel, fullText)
        t.equal(scene.hitMap.entry(at: 0, 0, handling: .leftUp, images: nil)?.elementID, nil)
        t.equal(scene.hitMap.entry(at: 50, 10, handling: .leftUp, images: nil)?.elementID, id(1))
        t.equal(scene.hitMap.entries.first?.toolTip, ToolTipInfo(text: fullText))
        t.equal(scene.hitMap.entries.first?.hasMenu, true)
        let menu = try fitted.resolveMenu(id(1), expectedGeneration: scene.generation, environment: environment)
        t.equal(menu?.items, [.item(id: ProgramMenuItemID(owner: id(1), path: [0]), title: fullText, checked: false, enabled: true)])
        let primary = try fitted.clickWithEffects(at: SkinPoint(x: 50, y: 10), expectedGeneration: scene.generation,
            environment: environment, measure: measure)
        t.equal(primary?.effects, [.copy(fullText)])
        t.check(try fitted.clickWithEffects(at: SkinPoint(x: 50, y: 10), expectedGeneration: scene.generation,
            environment: environment, measure: measure) == nil, "stale gestures remain rejected")
        let secondary = try fitted.clickWithEffects(at: SkinPoint(x: 50, y: 10), expectedGeneration: fitted.generation,
            event: .rightUp, environment: environment, measure: measure)
        t.equal(secondary?.effects, [.copy("secondary")]); t.equal(secondary?.scene.hitMap, scene.hitMap)
    }

    t.suite("Program: text lines: measurement and height overflow retain transactional variables effects and startup") {
        let text = ProgramExpression.concatenate([.declaration(0), .string(" full")])
        let root = ProgramElement(id: id(), content: .text(ProgramText(value: text, maximumLines: 1)),
            width: .fixed(30), height: .fixed(12), onClickActions: [
                .assign(ProgramAssignment(declaration: 0, value: .add(.declaration(0), .number(1)))), .copy(text)
            ], voiceOver: .concatenate([.declaration(0), .string("/"), .declaration(1)]))
        var value = try ProgramRuntime(program: WidgetProgram(name: "Transactional text", root: root, declarations: [
            ProgramDeclaration(name: "clicks", kind: .variable, initial: .number(0)),
            ProgramDeclaration(name: "loads", kind: .variable, initial: .number(0))
        ], onLoad: [ProgramAssignment(declaration: 1, value: .add(.declaration(1), .number(1)))]))
        let measure: (String, TextStyle, Double?) throws -> SkinSize = { _, style, width in
            t.equal(style.maximumLines, 1); t.equal(style.clip, 0)
            return SkinSize(width: width == nil ? 100 : 30, height: 12)
        }
        failure(.invalidMeasurement(id())) {
            _ = try value.project(environment: environment) { _, _, _ in SkinSize(width: .nan, height: 12) }
        }
        t.equal(value.generation, 0)
        let first = try value.project(environment: environment, measure: measure)
        t.equal(first.elements[0].accessibilityLabel, "0/1")
        failure(.invalidMeasurement(id())) {
            _ = try value.clickWithEffects(at: SkinPoint(x: 10, y: 6), expectedGeneration: first.generation,
                environment: environment) { _, style, width in
                    t.equal(style.maximumLines, 1)
                    return SkinSize(width: width == nil ? 100 : 30, height: width == nil ? 12 : .infinity)
                }
        }
        failure(.layoutOverflow(id())) {
            _ = try value.clickWithEffects(at: SkinPoint(x: 10, y: 6), expectedGeneration: first.generation,
                environment: environment) { _, _, width in
                    SkinSize(width: width == nil ? 100 : 30, height: width == nil ? 12 : 13)
                }
        }
        t.equal(value.generation, first.generation); t.equal(value.clockPrecision, nil)
        let restored = try value.project(environment: environment, measure: measure)
        t.equal(texts(restored.drawingItems).first?.text, "0 full")
        t.equal(restored.elements[0].accessibilityLabel, "0/1")
        let accepted = try value.clickWithEffects(at: SkinPoint(x: 10, y: 6), expectedGeneration: restored.generation,
            environment: environment, measure: measure)
        t.equal(accepted?.effects, [.copy("1 full")]); t.equal(accepted?.scene.elements[0].accessibilityLabel, "1/1")
        t.equal(texts(first.drawingItems).first?.text, "0 full")
    }
}
