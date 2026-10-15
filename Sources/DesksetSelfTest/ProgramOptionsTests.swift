import Foundation
@testable import DesksetCore

func runProgramOptionsTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "options"), imageGeneration: 0)
    let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0),
        timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"))
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, _, _ in
        SkinSize(width: Double(text.utf16.count) * 7, height: 14)
    }
    func id(_ value: Int = 0) -> ElementID { ElementID(name: "option-\(value)", index: value) }
    func text(_ expression: ProgramExpression, actions: [ProgramAction]? = nil) -> ProgramElement {
        ProgramElement(id: id(), content: .text(ProgramText(value: expression)), onClickActions: actions)
    }
    func box() -> ProgramElement {
        ProgramElement(id: id(), content: .rectangle(fill: .text), width: .fixed(20), height: .fixed(20))
    }
    func toggle(_ name: String = "show", value: Bool = false) -> ProgramOptionNode {
        .option(ProgramOption(name: name, title: .string(name), control: .toggle, defaultValue: .boolean(value)))
    }
    func number(_ name: String = "level", dimension: ProgramNumberDimension = .plain,
                base: Int? = nil, value: Double = 1) -> ProgramOptionNode {
        .option(ProgramOption(name: name, title: .string(name),
            control: .slider(min: ProgramNumber(0, dimension: dimension, displayBase: base),
                max: ProgramNumber(100, dimension: dimension, displayBase: base), step: nil),
            defaultValue: .number(ProgramNumber(value, dimension: dimension, displayBase: base))))
    }
    func picker(_ name: String = "theme", firstTitle: ProgramExpression = .string("Light")) -> ProgramOptionNode {
        .option(ProgramOption(name: name, title: .string(name), control: .picker(choices: [
            ProgramOptionChoice(value: .localCase(option: name, name: "light"), title: firstTitle),
            ProgramOptionChoice(value: .localCase(option: name, name: "dark"), title: .string("Dark"))]),
            defaultValue: .localCase(option: name, name: "light")))
    }
    func input(_ name: String = "name", value: String = "A") -> ProgramOptionNode {
        .option(ProgramOption(name: name, title: .string(name), control: .input(placeholder: .string("Name")),
            defaultValue: .string(value)))
    }
    func texts(_ scene: WidgetScene) -> [String] {
        scene.elements.flatMap(\.items).compactMap { if case .text(let text) = $0 { return text.text }; return nil }
    }
    func fail(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }
    func fails(_ body: () throws -> Void) {
        do { try body(); t.check(false, "expected invalid options") }
        catch { t.check(error is ProgramRuntimeError) }
    }
    func changed(_ runtime: ProgramRuntime, _ name: String, _ value: ProgramOptionValue) -> ProgramOptionsInput {
        var values = runtime.optionValues.values; values[name] = value
        return ProgramOptionsInput(values: values)
    }

    t.suite("Program: options: typed complete inputs validate ranges choices dimensions and stored recovery") {
        let dimensions: [ProgramNumberDimension] = [.plain, .percent, .bytes, .duration, .length, .angle]
        var nodes = [toggle(), input(), picker()]
        for (index, dimension) in dimensions.enumerated() {
            nodes.append(number("n\(index)", dimension: dimension, base: dimension == .bytes ? 1024 : nil))
        }
        nodes.append(.option(ProgramOption(name: "step", title: .string("Step"),
            control: .stepper(min: ProgramNumber(-4, dimension: .plain), max: ProgramNumber(4, dimension: .plain),
                step: ProgramNumber(2, dimension: .plain)), defaultValue: .number(ProgramNumber(-4, dimension: .plain)))))
        nodes.append(.option(ProgramOption(name: "word", title: .string("Word"), control: .picker(choices: [
            ProgramOptionChoice(value: .string("x"), title: .string("Ex"))]), defaultValue: .string("x"))))
        let schema = try ProgramOptionsSchema(options: nodes)
        t.equal(schema.defaults.values.count, 11)
        t.equal(try schema.validate(schema.defaults), schema.defaults)
        var values = schema.defaults.values
        values["n2"] = .number(ProgramNumber(1, dimension: .bytes, displayBase: 1000))
        values["step"] = .number(ProgramNumber(-2.5, dimension: .plain))
        let normalized = try schema.validate(ProgramOptionsInput(values: values))
        t.equal(normalized.values["n2"], .number(ProgramNumber(1, dimension: .bytes, displayBase: 1024)))
        t.equal(normalized.values["step"], values["step"], "step is UI spacing, not a stored-value grid")
        for (name, bad) in [("show", ProgramOptionValue.string("false")), ("name", .boolean(false)),
                            ("theme", .localCase(option: "other", name: "light")),
                            ("theme", .localCase(option: "theme", name: "removed")), ("word", .string("y")),
                            ("n0", .number(ProgramNumber(101, dimension: .plain))),
                            ("n1", .number(ProgramNumber(1, dimension: .duration))),
                            ("n2", .number(ProgramNumber(.infinity, dimension: .bytes))),
                            ("n2", .number(ProgramNumber(1, dimension: .bytes, displayBase: 2)))] {
            var invalid = values; invalid[name] = bad
            fails { _ = try schema.validate(ProgramOptionsInput(values: invalid)) }
        }
        var missing = values; missing.removeValue(forKey: "show")
        fail(.invalidOption("show")) { _ = try schema.validate(ProgramOptionsInput(values: missing)) }
        var unknown = values; unknown["gone"] = .string("old")
        fail(.invalidOption("gone")) { _ = try schema.validate(ProgramOptionsInput(values: unknown)) }
        let recovered = schema.reconcilePersisted(["show": .string("bad"), "name": .string("Kept"),
            "theme": .localCase(option: "theme", name: "removed"), "n2": values["n2"]!, "gone": .boolean(true)])
        t.equal(recovered.restoredNames, ["show", "theme", "gone"])
        t.equal(recovered.input.values["name"], .string("Kept")); t.equal(recovered.input.values["show"], .boolean(false))
        t.equal(recovered.input.values["n2"], normalized.values["n2"])
        t.equal(schema.reconcilePersisted([:]).restoredNames, [])
        for control in [ProgramOptionControl.slider(min: ProgramNumber(4, dimension: .plain), max: ProgramNumber(1, dimension: .plain), step: nil),
                        .stepper(min: ProgramNumber(0, dimension: .plain), max: ProgramNumber(2, dimension: .plain), step: ProgramNumber(0, dimension: .plain)),
                        .slider(min: ProgramNumber(0, dimension: .length), max: ProgramNumber(2, dimension: .length), step: nil)] {
            fails { _ = try ProgramOptionsSchema(options: [.option(ProgramOption(name: "bad", title: .string("Bad"),
                control: control, defaultValue: .number(ProgramNumber(1, dimension: .plain))))]) }
        }
        fails { _ = try ProgramOptionsSchema(options: [number(value: 101)]) }
    }

    t.suite("Program: options: localized ordered panel metadata and nominal labels resolve without state or clocks") {
        let translations = ProgramTranslations(source: ["label": [.text("Light "), .placeholder(0)]],
            languages: ["zh": ["label": [.placeholder(0), .text(" 浅色")]]])
        let label = ProgramExpression.localized(key: "label", values: [.formatNumber(.number(2.5), ProgramNumberFormat(decimals: 1))])
        let nodes: [ProgramOptionNode] = [toggle(), .section(title: .string("Group"), items: [
            picker(firstTitle: label), .option(ProgramOption(name: "name", title: .string("Name"),
                control: .input(placeholder: .string("Type")), defaultValue: .string("Raw"), help: .string("Help"),
                hiddenIf: .option("show")))])]
        let root = text(.concatenate([.option("theme"), .string("|"), .option("name")]))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Options", root: root,
            translations: translations, options: nodes), language: "zh")
        let snapshot = try runtime.resolveOptions(dateInput: date)
        t.equal(runtime.generation, 0); t.equal(runtime.optionsRevision, 0); t.equal(runtime.clockPrecision, nil)
        t.equal(runtime.neededSystemProperties, [])
        guard case .section(let title, let children) = snapshot.items[1],
              case .option(let theme) = children[0], case .picker(let choices) = theme.control,
              case .option(let name) = children[1] else { t.check(false, "ordered section metadata"); return }
        t.equal(title, "Group"); t.equal(choices.map(\.title), ["2.5 浅色", "Dark"])
        t.equal(name.help, "Help"); t.equal(name.control, .input(placeholder: "Type")); t.check(!name.hidden)
        let before = try runtime.project(environment: environment, dateInput: date, measure: measure)
        t.equal(texts(before), ["2.5 浅色|Raw"])
        if case .text(let draw) = before.elements[0].items[0] {
            t.equal(draw.style.inlineSpans, [InlineSpan(location: 0, length: 3, setting: .typography(feature: "tnum", value: 1))])
        }
        else { t.check(false, "text drawing") }
        _ = try runtime.updateOptions(changed(runtime, "show", .boolean(true)), expectedRevision: 0,
            environment: environment, dateInput: date, measure: measure)
        let hidden = try runtime.resolveOptions(dateInput: date)
        if case .section(_, let children) = hidden.items[1], case .option(let name) = children[1] { t.check(name.hidden) }
        else { t.check(false, "hidden metadata remains in panel snapshot") }
        t.equal(runtime.optionValues.values["name"], .string("Raw")); t.equal(runtime.clockPrecision, nil)
        t.equal(snapshot.values.values["show"], .boolean(false), "previous snapshot remains immutable")
    }

    t.suite("Program: options: complete updates retain session variables and startup while failures and stale inputs roll back") {
        let declarations = [ProgramDeclaration(name: "remembered", kind: .variable, initial: .option("name")),
            ProgramDeclaration(name: "count", kind: .variable, initial: .number(0))]
        let root = text(.concatenate([.option("name"), .string("|"), .declaration(0), .string("|"), .declaration(1)]))
        let program = WidgetProgram(name: "Updates", root: root, declarations: declarations,
            onLoad: [ProgramAssignment(declaration: 1, value: .add(.declaration(1), .number(1)))], options: [input()])
        var runtime = try ProgramRuntime(program: program, options: ProgramOptionsInput(values: ["name": .string("Loaded")]))
        _ = try runtime.resolveOptions(dateInput: date)
        let first = try runtime.project(environment: environment, measure: measure)
        t.equal(texts(first), ["Loaded|Loaded|1"])
        _ = try runtime.project(environment: environment, measure: measure)
        let updated = try runtime.updateOptions(changed(runtime, "name", .string("Edited")), expectedRevision: 0,
            environment: environment, measure: measure)
        t.equal(texts(updated!), ["Edited|Loaded|1"]); t.equal(runtime.optionsRevision, 1)
        let generation = runtime.generation, committed = runtime.optionValues
        var measured = false
        t.check(try runtime.updateOptions(changed(runtime, "name", .string("Stale")), expectedRevision: 0,
            environment: environment) { _, _, _ in measured = true; return SkinSize() } == nil)
        t.check(!measured); t.equal(runtime.generation, generation)
        fail(.invalidMeasurement(id())) {
            _ = try runtime.updateOptions(changed(runtime, "name", .string("Fail")), expectedRevision: 1,
                environment: environment) { _, _, _ in SkinSize(width: .nan, height: 14) }
        }
        t.equal(runtime.optionValues, committed); t.equal(runtime.optionsRevision, 1); t.equal(runtime.generation, generation)
        _ = try runtime.updateOptions(committed, expectedRevision: 1, environment: environment, measure: measure)
        t.equal(runtime.optionsRevision, 1, "same values do not invalidate other panel revisions")
        var other = try ProgramRuntime(program: program)
        t.equal(texts(try other.project(environment: environment, measure: measure)), ["A|A|1"])
        var fresh = try ProgramRuntime(program: program)
        fail(.invalidMeasurement(id())) {
            _ = try fresh.updateOptions(changed(fresh, "name", .string("Uncommitted")), expectedRevision: 0,
                environment: environment) { _, _, _ in SkinSize(width: .nan, height: 14) }
        }
        t.equal(texts(try fresh.project(environment: environment, measure: measure)), ["A|A|1"])
    }

    t.suite("Program: options: ordered option and variable actions share computed invalidation effects and rollback") {
        let actions: [ProgramAction] = [
            .copy(.declaration(1)), .assignOption(name: "level", value: .number(7)), .copy(.declaration(1)),
            .assign(ProgramAssignment(declaration: 0, value: .add(.declaration(0), .number(1)))),
            .assignOption(name: "theme", value: .localCase(option: "theme", name: "dark")),
            .copy(.concatenate([.option("theme"), .string("|"), .declaration(1)]))]
        let declarations = [ProgramDeclaration(name: "counter", kind: .variable, initial: .number(0)),
            ProgramDeclaration(name: "caption", kind: .computed, initial: .concatenate([.option("level"), .string("/"), .declaration(0)]))]
        let options = [number(), picker()]
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Actions", root: text(.declaration(1), actions: actions),
            declarations: declarations, options: options))
        let first = try runtime.project(environment: environment, measure: measure)
        let result = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: environment, measure: measure)
        t.equal(result?.effects, [.copy("1/0"), .copy("7/0"), .copy("Dark|7/1")])
        t.equal(texts(result!.scene), ["7/1"]); t.equal(runtime.optionsRevision, 1)
        t.equal(runtime.optionValues.values["theme"], .localCase(option: "theme", name: "dark"))
        for bad in [ProgramExpression.number(101), .divide(.number(1), .number(0))] {
            var invalid = try ProgramRuntime(program: WidgetProgram(name: "Rollback",
                root: text(.declaration(1), actions: [.assignOption(name: "level", value: .number(3)),
                    .assign(ProgramAssignment(declaration: 0, value: .number(9))), .copy(.string("Discard")),
                    .assignOption(name: "level", value: bad)]), declarations: declarations, options: options))
            let before = try invalid.project(environment: environment, measure: measure)
            fail(.invalidOption("level")) {
                _ = try invalid.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: before.generation,
                    environment: environment, measure: measure)
            }
            t.equal(invalid.generation, before.generation); t.equal(invalid.optionsRevision, 0)
            t.equal(texts(try invalid.project(environment: environment, measure: measure)), ["1/0"])
        }
        var pending = try ProgramRuntime(program: WidgetProgram(name: "Measurement", root: text(.declaration(1), actions: actions),
            declarations: declarations, options: options))
        let before = try pending.project(environment: environment, measure: measure)
        fail(.invalidMeasurement(id())) {
            _ = try pending.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: before.generation,
                environment: environment) { _, _, _ in SkinSize(width: .nan, height: 14) }
        }
        t.equal(pending.optionsRevision, 0); t.equal(pending.optionValues.values["level"], .number(ProgramNumber(1, dimension: .plain)))
        let retry = try pending.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: before.generation,
            environment: environment, measure: measure)
        t.equal(retry?.effects, result?.effects)
        let same = ProgramExpression.conditional(.equal(.option("theme"), .declaration(0)), then: .string("same"), otherwise: .string("changed"))
        var enumVariable = try ProgramRuntime(program: WidgetProgram(name: "Nominal variable", root: text(same, actions: [
            .assignOption(name: "theme", value: .localCase(option: "theme", name: "dark")), .copy(same),
            .assign(ProgramAssignment(declaration: 0, value: .option("theme"))), .copy(.concatenate([.declaration(0)]))]),
            declarations: [ProgramDeclaration(name: "remembered", kind: .variable, initial: .option("theme"))], options: [picker()]))
        let enumScene = try enumVariable.project(environment: environment, measure: measure)
        let enumResult = try enumVariable.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: enumScene.generation,
            environment: environment, measure: measure)
        t.equal(enumResult?.effects, [.copy("changed"), .copy("Dark")]); t.equal(texts(enumResult!.scene), ["same"])
    }

    t.suite("Program: options: reads drive active views clocks labels tooltips and menu action dependencies") {
        let caption = ProgramExpression.concatenate([.option("theme")])
        let child = ProgramElement(id: id(2), content: .text(ProgramText(value: .formatDate(.timeNow, .pattern("HH:mm:ss")))),
            voiceOver: caption, tooltip: ProgramTooltip(text: caption), menu: [
                .item(ProgramMenuItem(title: caption, enabled: .option("show"), actions: [
                    .assignOption(name: "level", value: .systemProperty(.cpuUsage))]))])
        let branch = ProgramElement(id: id(1), content: .conditional(ProgramConditional(branches: [
            ProgramConditionalBranch(condition: .option("show"), body: [child])], otherwise: [])))
        let root = ProgramElement(id: id(), content: .column(spacing: 0, align: .left, children: [branch]))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Views", root: root,
            options: [toggle(), picker(), number(dimension: .percent)]))
        let empty = try runtime.project(environment: environment, measure: measure)
        t.equal(empty.elements.count, 1); t.equal(runtime.clockPrecision, nil); t.equal(runtime.neededSystemProperties, [])
        let shown = try runtime.updateOptions(changed(runtime, "show", .boolean(true)), expectedRevision: 0,
            environment: environment, dateInput: date, measure: measure)!
        t.equal(runtime.clockPrecision, .second); t.equal(shown.elements.last?.accessibilityLabel, "Light")
        t.equal(shown.hitMap.entries.first?.toolTip?.text, "Light")
        let menuID = ProgramMenuItemID(owner: id(2), path: [0])
        t.equal(runtime.neededSystemProperties(activatingMenuItem: menuID), [.cpuUsage])
        let menu = try runtime.resolveMenu(id(2), expectedGeneration: shown.generation, environment: environment)
        t.equal(menu?.items, [.item(id: menuID, title: "Light", checked: false, enabled: true)])
        _ = try runtime.activateMenuItemWithEffects(menuID, expectedGeneration: shown.generation,
            environment: environment, dateInput: date, systemInput: ProgramSystemInput(cpuUsage: 75), measure: measure)
        t.equal(runtime.optionValues.values["level"], .number(ProgramNumber(75, dimension: .percent)))
        let hidden = try runtime.updateOptions(changed(runtime, "show", .boolean(false)), expectedRevision: runtime.optionsRevision,
            environment: environment, measure: measure)!
        t.equal(hidden.elements.count, 1); t.equal(runtime.clockPrecision, nil); t.check(!runtime.isMenuOwnerVisible(id(2)))
    }

    t.suite("Program: options: all metadata branches nominal types and shared expression node and depth budgets validate") {
        fails { _ = try ProgramOptionsSchema(options: [toggle(), toggle()]) }
        for bad in [ProgramExpression.option("show"), .declaration(0), .appearanceDark,
                    .formatDate(.timeNow, .pattern("HH")), .concatenate([.systemProperty(.cpuUsage)])] {
            fails { _ = try ProgramOptionsSchema(options: [toggle(), .option(ProgramOption(name: "bad", title: bad,
                control: .toggle, defaultValue: .boolean(false)))]) }
        }
        fails { _ = try ProgramOptionsSchema(options: [.option(ProgramOption(name: "bad", title: .string("Bad"),
            control: .toggle, defaultValue: .boolean(false), hiddenIf: .or(.boolean(true), .systemProperty(.batteryCharging))))]) }
        for invalid in [ProgramExpression.equal(.option("theme"), .localCase(option: "other", name: "light")),
                        .equal(.option("theme"), .string("light")),
                        .equal(.option("theme"), .localCase(option: "theme", name: "removed"))] {
            fails { _ = try ProgramRuntime(program: WidgetProgram(name: "Types", root: text(.concatenate([invalid])),
                options: [picker(), picker("other")])) }
        }
        fail(.invalidOption("level")) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Wrong assignment", root: text(.string("A"),
                actions: [.assignOption(name: "level", value: .quantity(ProgramNumber(1, dimension: .length)))]), options: [number()]))
        }
        let expression = ProgramExpression.concatenate(Array(repeating: .string(""), count: ProgramLimits.maximumExpressions - 2))
        _ = try ProgramRuntime(program: WidgetProgram(name: "Boundary", root: text(expression), options: [toggle()]))
        fail(.expressionLimit) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Too wide", root: text(expression), options: [toggle(), toggle("more")]))
        }
        let sections = Array(repeating: ProgramOptionNode.section(title: .string(""), items: []), count: ProgramLimits.maximumElements)
        _ = try ProgramRuntime(program: WidgetProgram(name: "Node boundary", root: box(), options: Array(sections.dropLast())))
        fail(.elementLimit) { _ = try ProgramRuntime(program: WidgetProgram(name: "Too many", root: box(), options: sections)) }
        var nested = toggle()
        for _ in 1..<ProgramLimits.maximumDepth { nested = .section(title: .string(""), items: [nested]) }
        _ = try ProgramOptionsSchema(options: [nested])
        fail(.depthLimit) { _ = try ProgramOptionsSchema(options: [.section(title: .string(""), items: [nested])]) }
        var condition = ProgramExpression.boolean(false)
        for _ in 1..<ProgramLimits.maximumExpressionDepth { condition = .not(condition) }
        _ = try ProgramOptionsSchema(options: [.option(ProgramOption(name: "deep", title: .string(""),
            control: .toggle, defaultValue: .boolean(false), hiddenIf: condition))])
        fail(.expressionDepth) {
            _ = try ProgramOptionsSchema(options: [.option(ProgramOption(name: "deep", title: .string(""),
                control: .toggle, defaultValue: .boolean(false), hiddenIf: .not(condition)))])
        }
        var label = ProgramExpression.string("Label")
        for _ in 1..<(ProgramLimits.maximumExpressionDepth - 1) { label = .concatenate([label]) }
        _ = try ProgramOptionsSchema(options: [picker(firstTitle: label)])
        fail(.expressionDepth) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Expanded label", root: text(.concatenate([.option("theme")])),
                options: [picker(firstTitle: label)]))
        }
    }
}
