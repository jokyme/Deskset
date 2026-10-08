import Foundation
@testable import DesksetCore

private enum LocalizationFixtureFailure: Error { case measurement }

func runProgramLocalizationTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "localization"), imageGeneration: 0)
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, _, _ in
        SkinSize(width: Double(text.utf16.count) * 7, height: 14)
    }
    func date(_ locale: String = "en_US_POSIX", _ instant: Double = 0) -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: instant), timeZone: TimeZone(secondsFromGMT: 0)!,
                         locale: Locale(identifier: locale))
    }
    func id(_ index: Int = 0) -> ElementID { ElementID(name: "localized-\(index)", index: index) }
    func text(_ value: ProgramExpression, index: Int = 0, hidden: Bool = false) -> ProgramElement {
        ProgramElement(id: id(index), content: .text(ProgramText(value: value)), hidden: hidden)
    }
    func strings(_ scene: WidgetScene) -> [String] {
        scene.drawingItems.compactMap { if case .text(let value) = $0 { return value.text }; return nil }
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }
    let one = ProgramTranslations(source: ["value": [.text("Value "), .placeholder(0)]],
        languages: ["zh-Hans": ["value": [.placeholder(0), .text(" 值")]]])

    t.suite("Program: localization: fixed language source fallback and metadata retain source identity") {
        let table = ProgramTranslations(source: ["greeting": [.text("Hello")], "absent": [.text("Original")],
            "empty": [.text("Not empty")], "name\\nkey": [.text("Source\nname")]], languages: [
                "zh-Hans": ["greeting": [.text("你好")], "empty": [], "name\\nkey": [.text("组件")]],
                "de": ["greeting": [.text("Hallo")]]])
        let root = ProgramElement(id: id(), content: .column(spacing: 0, align: .left, children: [
            text(.localized(key: "greeting", values: []), index: 1),
            text(.localized(key: "absent", values: []), index: 2),
            text(.localized(key: "empty", values: []), index: 3),
            text(.string("greeting"), index: 4)
        ]))
        let program = WidgetProgram(name: "Fallback name", root: root, translations: table, nameKey: "name\\nkey")
        for (language, greeting, empty, name) in [(nil, "Hello", "Not empty", "Source\nname"),
            ("zh-Hans", "你好", "", "组件"), ("de", "Hallo", "Not empty", "Source\nname"),
            ("unknown", "Hello", "Not empty", "Source\nname")] as [(String?, String, String, String)] {
            var value = try ProgramRuntime(program: program, language: language)
            t.equal(value.language, language); t.equal(value.displayName, name)
            t.equal(program.displayName(language: language), name)
            for locale in ["en_US", "zh_CN", "de_DE"] {
                let scene = try value.project(environment: environment, dateInput: date(locale), measure: measure)
                t.equal(strings(scene).filter { !$0.isEmpty }, [greeting, "Original", empty, "greeting"].filter { !$0.isEmpty })
                t.equal(value.clockPrecision, nil); t.equal(value.neededSystemProperties(), [])
            }
        }
        let plain = WidgetProgram(name: "greeting", root: text(.string("Hello")), translations: table)
        t.equal(plain.displayName(language: "zh-Hans"), "greeting", "cooked names are never reverse looked up")
        t.equal(WidgetProgram(name: "plain", root: text(.string("x"))).translations, ProgramTranslations())
    }

    t.suite("Program: localization: reordered placeholders preserve UTF16 numeric spans and captured formats") {
        let values: [ProgramExpression] = [.formatNumber(.number(12.3), ProgramNumberFormat()), .number(2),
            .string("9"), .boolean(true), .formatDate(.timeNow, .pattern("HH:mm")),
            .divide(.number(1), .number(0))]
        let table = ProgramTranslations(source: ["mixed": values.indices.flatMap { [.placeholder($0), .text("|")] }],
            languages: ["reordered": ["mixed": [.text("😀7|"), .placeholder(1), .text("/"), .placeholder(0),
                .text("|"), .placeholder(2), .text("|"), .placeholder(3), .text("|"), .placeholder(4), .text("|"), .placeholder(5)]]])
        let expression = ProgramExpression.localized(key: "mixed", values: values)
        var value = try ProgramRuntime(program: WidgetProgram(name: "Spans", root: text(expression), translations: table), language: "reordered")
        var styles: [TextStyle] = []
        let scene = try value.project(environment: environment, dateInput: date()) { text, style, width in
            styles.append(style); return try measure(text, style, width)
        }
        t.equal(strings(scene), ["😀7|2/12.3|9|Yes|00:00|–"])
        let spans = [InlineSpan(location: 4, length: 1, setting: .typography(feature: "tnum", value: 1)),
                     InlineSpan(location: 6, length: 4, setting: .typography(feature: "tnum", value: 1))]
        t.check(!styles.isEmpty && styles.allSatisfy { $0.inlineSpans == spans })
        let draws = scene.drawingItems.compactMap { item -> TextDraw? in if case .text(let value) = item { return value }; return nil }
        t.equal(draws.first?.style.inlineSpans, spans)
        t.equal(value.clockPrecision, .minute)
        let german = try value.project(environment: environment, dateInput: date("de_DE"), measure: measure)
        t.equal(strings(german), ["😀7|2/12,3|9|Yes|00:00|–"], "direct Core uses supplied locale without replacing its language")
        let chinese = try value.project(environment: environment, dateInput: date("zh_CN"), measure: measure)
        t.equal(strings(chinese), ["😀7|2/12.3|9|是|00:00|–"])
        var nested = ProgramExpressionEvaluation(declarations: [], dark: false, variables: nil, dateInput: date(),
            translations: table, language: "reordered")
        let outer = try nested.text(.concatenate([.string("前"), expression]))
        t.equal(outer.numberRanges, [5..<6, 7..<11])
    }

    t.suite("Program: localization: live values computed slots and hidden branches preserve dependency clocks") {
        let live = ProgramExpression.localized(key: "value", values: [.declaration(1)])
        let declarations = [ProgramDeclaration(name: "frozen", kind: .variable, initial: .systemProperty(.cpuUsage)),
            ProgramDeclaration(name: "live", kind: .computed, initial: .systemProperty(.cpuUsage))]
        let root = ProgramElement(id: id(), content: .column(spacing: 0, align: .left, children: [
            text(.localized(key: "value", values: [.declaration(0)]), index: 1), text(live, index: 2)
        ]))
        var value = try ProgramRuntime(program: WidgetProgram(name: "Live", root: root, declarations: declarations,
            onLoad: [ProgramAssignment(declaration: 0, value: .quantity(ProgramNumber(10, dimension: .percent)))], translations: one), language: "zh-Hans")
        t.equal(value.neededSystemProperties(), [.cpuUsage])
        for (input, expected) in [(25.0, "25 值"), (75.0, "75 值")] {
            let scene = try value.project(environment: environment, dateInput: date(), systemInput: ProgramSystemInput(cpuUsage: input), measure: measure)
            t.equal(strings(scene), ["10 值", expected]); t.equal(value.clockPrecision, .second)
        }
        var hidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden", root: text(live, hidden: true),
            declarations: declarations, translations: one), language: "zh-Hans")
        var measured: [String] = []
        _ = try hidden.project(environment: environment, dateInput: date(), systemInput: ProgramSystemInput(cpuUsage: 30)) {
            measured.append($0); return try measure($0, $1, $2)
        }
        t.check(measured.contains("30 值")); t.equal(hidden.clockPrecision, nil)
        t.equal(hidden.neededSystemProperties(), [.cpuUsage], "hidden text still measures its actual translated content")
        let branch = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .boolean(false), body: [text(live, index: 2)])
        ], otherwise: [text(.string("Idle"), index: 3)])))
        var inactive = try ProgramRuntime(program: WidgetProgram(name: "Inactive", root: ProgramElement(id: id(),
            content: .column(spacing: 0, align: .left, children: [branch])), declarations: declarations, translations: one), language: "zh-Hans")
        t.equal(inactive.neededSystemProperties(), [.cpuUsage])
        let scene = try inactive.project(environment: environment, dateInput: date(), measure: measure)
        t.equal(strings(scene), ["Idle"]); t.equal(inactive.clockPrecision, nil)
        let lazy = ProgramExpression.conditional(.boolean(true), then: .string("Plain"),
            otherwise: .localized(key: "value", values: [.formatDate(.timeNow, .pattern("HH:mm:ss"))]))
        var unused = try ProgramRuntime(program: WidgetProgram(name: "Lazy", root: text(lazy), translations: one), language: "zh-Hans")
        t.equal(strings(try unused.project(environment: environment, measure: measure)), ["Plain"])
        t.equal(unused.clockPrecision, nil)
    }

    t.suite("Program: localization: tooltips accessibility and menu snapshots share language without permanent menu clocks") {
        let label = ProgramExpression.localized(key: "value", values: [.systemProperty(.cpuUsage)])
        let menuLabel = ProgramExpression.localized(key: "value", values: [.formatDate(.timeNow, .pattern("HH:mm:ss"))])
        let root = ProgramElement(id: id(), content: .rectangle(fill: .literal(.clear)), width: .fixed(40), height: .fixed(30),
            voiceOver: label, tooltip: ProgramTooltip(text: label, title: .localized(key: "value", values: [.string("Title")])),
            menu: [.item(ProgramMenuItem(title: menuLabel))])
        var value = try ProgramRuntime(program: WidgetProgram(name: "Metadata", root: root, translations: one), language: "zh-Hans")
        t.equal(value.neededSystemProperties(), [.cpuUsage])
        let scene = try value.project(environment: environment, dateInput: date(), systemInput: ProgramSystemInput(cpuUsage: 25), measure: measure)
        t.equal(scene.elements.first?.accessibilityLabel, "25 值")
        t.equal(scene.hitMap.toolTipInfo(at: 20, 15, images: nil), ToolTipInfo(text: "25 值", title: "Title 值"))
        t.equal(value.clockPrecision, .second)
        let menu = try value.resolveMenu(id(), expectedGeneration: scene.generation, environment: environment, dateInput: date())
        t.equal(menu?.items, [.item(id: ProgramMenuItemID(owner: id(), path: [0]), title: "00:00:00 值", checked: false, enabled: true)])
        let newer = try value.resolveMenu(id(), expectedGeneration: scene.generation, environment: environment, dateInput: date("en_US", 1))
        t.equal(newer?.items, [.item(id: ProgramMenuItemID(owner: id(), path: [0]), title: "00:00:01 值", checked: false, enabled: true)])
        t.equal(value.generation, scene.generation); t.equal(menu?.items.first, .item(id: ProgramMenuItemID(owner: id(), path: [0]),
            title: "00:00:00 值", checked: false, enabled: true))
        let hidden = ProgramElement(id: id(), content: .rectangle(fill: .literal(.clear)), width: .fixed(40), height: .fixed(30),
            hidden: true, voiceOver: menuLabel, tooltip: ProgramTooltip(text: label))
        var hiddenValue = try ProgramRuntime(program: WidgetProgram(name: "Hidden metadata", root: hidden, translations: one), language: "zh-Hans")
        t.equal(hiddenValue.neededSystemProperties(), [])
        let hiddenScene = try hiddenValue.project(environment: environment, measure: measure)
        t.check(hiddenScene.elements.allSatisfy { $0.accessibilityLabel == nil }); t.check(hiddenScene.hitMap.entries.isEmpty)
        t.equal(hiddenValue.clockPrecision, nil)
    }

    t.suite("Program: localization: ordered actions preserve frozen strings and roll back failed translated projection") {
        let translated = ProgramExpression.localized(key: "value", values: [.declaration(0)])
        let root = ProgramElement(id: id(), content: .text(ProgramText(value: .declaration(1))), width: .fixed(60), height: .fixed(30),
            onClickActions: [.assign(ProgramAssignment(declaration: 0, value: .add(.declaration(0), .number(1)))),
                .assign(ProgramAssignment(declaration: 1, value: translated)), .copy(.declaration(1)),
                .copy(.string("value")), .open(.string("value"))])
        let program = WidgetProgram(name: "Actions", root: root, declarations: [
            ProgramDeclaration(name: "count", kind: .variable, initial: .number(0)),
            ProgramDeclaration(name: "frozen", kind: .variable, initial: .string("Initial"))], translations: one)
        var value = try ProgramRuntime(program: program, language: "zh-Hans")
        let initial = try value.project(environment: environment, dateInput: date(), measure: measure)
        do {
            _ = try value.clickWithEffects(at: SkinPoint(x: 10, y: 10), expectedGeneration: initial.generation,
                environment: environment, dateInput: date()) { _, _, _ in throw LocalizationFixtureFailure.measurement }
            t.check(false, "measurement failure must discard variables and effects")
        } catch { t.check(error is LocalizationFixtureFailure) }
        t.equal(value.generation, initial.generation)
        let selected = try value.clickWithEffects(at: SkinPoint(x: 10, y: 10), expectedGeneration: initial.generation,
            environment: environment, dateInput: date(), measure: measure)
        t.equal(selected?.effects, [.copy("1 值"), .copy("value"), .open("value")])
        t.equal(selected.map { strings($0.scene) }, ["1 值"])
        let later = try value.project(environment: environment, dateInput: date("de_DE", 2), measure: measure)
        t.equal(strings(later), ["1 值"]); t.equal(value.clockPrecision, nil)
        let spans = later.drawingItems.compactMap { item -> [InlineSpan]? in if case .text(let value) = item { return value.style.inlineSpans }; return nil }
        t.equal(spans.first, [InlineSpan(location: 0, length: 1, setting: .typography(feature: "tnum", value: 1))])
    }

    t.suite("Program: localization: all patterns keys and lazy arms reject invalid direct producers") {
        let invalid: [ProgramTranslations] = [
            ProgramTranslations(source: ["value": [.placeholder(-1)]]),
            ProgramTranslations(source: ["value": [.placeholder(1)]]),
            ProgramTranslations(source: ["value": [.placeholder(0), .placeholder(0)]]),
            ProgramTranslations(source: ["value": [.placeholder(0)]], languages: ["unused": ["value": [.text("lost")]]]),
            ProgramTranslations(source: ["value": [.placeholder(0)]], languages: ["unused": ["value": [.placeholder(1)]]]),
            ProgramTranslations(languages: ["unused": ["orphan": [.text("bad")]]]),
            ProgramTranslations(source: ["value": [.text(String(repeating: "x", count: ProgramLimits.maximumTextLength + 1))]]),
            ProgramTranslations(languages: ["": [:]])
        ]
        for table in invalid {
            failure(.invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid", root: text(.string("Safe")), translations: table)) }
        }
        for expression in [ProgramExpression.localized(key: "missing", values: []), .localized(key: "value", values: []),
            .localized(key: "value", values: [.timeNow])] {
            let root = text(.conditional(.boolean(true), then: .string("Safe"), otherwise: expression), hidden: true)
            failure(.invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid arm", root: root, translations: one)) }
        }
        for key in ["missing", "value"] {
            let program = WidgetProgram(name: "Source", root: text(.string("Safe")), translations: one, nameKey: key)
            t.equal(program.displayName(language: "zh-Hans"), "Source")
            failure(.invalidExpression) { _ = try ProgramRuntime(program: program) }
        }
        let longName = WidgetProgram(name: "Source", root: text(.string("Safe")), translations:
            ProgramTranslations(source: ["name": [.text(String(repeating: "x", count: ProgramLimits.maximumTextLength)), .text("x")]]), nameKey: "name")
        t.equal(longName.displayName(language: nil), "Source")
        failure(.invalidExpression) { _ = try ProgramRuntime(program: longName) }
    }

    t.suite("Program: localization: shared table budgets expanded depth and rendered overflow remain transactional") {
        let exact = ProgramTranslations(source: ["empty": Array(repeating: .text(""), count: ProgramLimits.maximumExpressions - 2)])
        _ = try ProgramRuntime(program: WidgetProgram(name: "Exact", root: text(.localized(key: "empty", values: [])), translations: exact))
        let tooMany = ProgramTranslations(source: ["empty": Array(repeating: .text(""), count: ProgramLimits.maximumExpressions - 1)])
        failure(.expressionLimit) { _ = try ProgramRuntime(program: WidgetProgram(name: "Large", root: text(.localized(key: "empty", values: [])), translations: tooMany)) }
        let languages = Dictionary(uniqueKeysWithValues: (0..<ProgramLimits.maximumExpressions).map { ("language-\($0)", [String: [ProgramTranslationPart]]()) })
        failure(.expressionLimit) { _ = try ProgramRuntime(program: WidgetProgram(name: "Many languages", root: text(.string("x")), translations: ProgramTranslations(languages: languages))) }
        let identity = ProgramTranslations(source: ["one": [.placeholder(0)]])
        var nested = ProgramExpression.string("x")
        for _ in 1..<ProgramLimits.maximumExpressionDepth { nested = .localized(key: "one", values: [nested]) }
        _ = try ProgramRuntime(program: WidgetProgram(name: "Exact depth", root: text(nested), translations: identity))
        failure(.expressionDepth) { _ = try ProgramRuntime(program: WidgetProgram(name: "Deep", root: text(.localized(key: "one", values: [nested])), translations: identity)) }
        let declarations = (0..<120).map { index in
            ProgramDeclaration(name: "link\(index)", kind: .computed,
                initial: index == 0 ? .string("x") : .declaration(index - 1))
        }
        var expanded = ProgramExpression.declaration(119)
        for _ in 0..<7 { expanded = .localized(key: "one", values: [expanded]) }
        _ = try ProgramRuntime(program: WidgetProgram(name: "Exact expanded depth", root: text(expanded), declarations: declarations, translations: identity))
        failure(.expressionDepth) { _ = try ProgramRuntime(program: WidgetProgram(name: "Expanded depth", root: text(.localized(key: "one", values: [expanded])),
            declarations: declarations, translations: identity)) }
        let table = ProgramTranslations(source: ["one": [.placeholder(0)]], languages: ["extra": ["one": [.text("!"), .placeholder(0)]]])
        let root = ProgramElement(id: id(), content: .text(ProgramText(value: .localized(key: "one", values: [.declaration(0)]))),
            width: .fixed(40), height: .fixed(30), onClickActions: [
                .assign(ProgramAssignment(declaration: 0, value: .string(String(repeating: "x", count: ProgramLimits.maximumTextLength)))),
                .copy(.string("Only after success"))])
        var value = try ProgramRuntime(program: WidgetProgram(name: "Overflow", root: root,
            declarations: [ProgramDeclaration(name: "text", kind: .variable, initial: .string(""))], translations: table), language: "extra")
        let before = try value.project(environment: environment, measure: measure)
        failure(.invalidExpression) { _ = try value.clickWithEffects(at: SkinPoint(x: 5, y: 5), expectedGeneration: before.generation,
            environment: environment, measure: measure) }
        t.equal(value.generation, before.generation)
        t.equal(strings(try value.project(environment: environment, measure: measure)), ["!"])
    }
}
