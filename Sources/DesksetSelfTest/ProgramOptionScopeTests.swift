import Foundation
import DesksetCore

func runProgramOptionScopeTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "option scopes"), imageGeneration: 0)
    let elementID = ElementID(name: "scoped-options", index: 0)
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, _, _ in
        SkinSize(width: Double(text.utf16.count) * 7, height: 14)
    }
    func date(_ locale: String = "en_US_POSIX") -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!,
                         locale: Locale(identifier: locale))
    }
    func root(_ value: ProgramExpression, actions: [ProgramAction]? = nil) -> ProgramElement {
        ProgramElement(id: elementID, content: .text(ProgramText(value: value)), onClickActions: actions)
    }
    func texts(_ scene: WidgetScene) -> [String] {
        scene.elements.flatMap(\.items).compactMap { if case .text(let draw) = $0 { return draw.text }; return nil }
    }
    func resolved(_ items: [ProgramResolvedOptionNode]) -> [ProgramResolvedOption] {
        items.flatMap { item -> [ProgramResolvedOption] in
            switch item {
            case .option(let option): return [option]
            case .section(_, let children): return resolved(children)
            }
        }
    }
    func toggle(_ name: String, scope: ProgramOptionScope, hiddenIf: ProgramExpression? = nil) -> ProgramOptionNode {
        .option(ProgramOption(name: name, title: .string(""), control: .toggle, defaultValue: .boolean(false),
            hiddenIf: hiddenIf, scope: scope))
    }
    func fail(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }

    t.suite("Program: option scopes: public schema resolution preserves scoped order typed values and localized panel metadata") {
        let translations = ProgramTranslations(source: [
            "group": [.text("Panel")], "choice": [.text("Soft "), .placeholder(0)],
            "name": [.text("Name")], "help": [.text("Help")], "placeholder": [.text("Type")]], languages: [
            "fr": ["group": [.text("Groupe")], "choice": [.placeholder(0), .text(" doux")],
                "name": [.text("Nom")], "help": [.text("Aide")], "placeholder": [.text("Saisir")]]])
        let label = ProgramExpression.localized(key: "choice", values: [
            .formatNumber(.number(2.5), ProgramNumberFormat(decimals: 1))])
        let theme = ProgramOption(name: "theme", title: .string("Theme"), control: .picker(choices: [
            ProgramOptionChoice(value: .localCase(option: "theme", name: "soft"), title: label),
            ProgramOptionChoice(value: .localCase(option: "theme", name: "bold"), title: .string("Bold"))]),
            defaultValue: .localCase(option: "theme", name: "soft"), scope: .package)
        // The old initializer remains instance-local; its hidden predicate can read the effective package option.
        let local = ProgramOption(name: "name", title: .localized(key: "name", values: []),
            control: .input(placeholder: .localized(key: "placeholder", values: [])), defaultValue: .string("Raw"),
            help: .localized(key: "help", values: []),
            hiddenIf: .equal(.option("theme"), .localCase(option: "theme", name: "bold")))
        let schema = try ProgramOptionsSchema(options: [.section(title: .localized(key: "group", values: []),
            items: [.option(theme), .option(local)])], translations: translations)
        let first = try schema.resolve(schema.defaults, revision: 17, language: "fr", dateInput: date())
        guard case .section(let title, let items)? = first.items.first else {
            t.check(false, "ordered localized section"); return
        }
        let options = resolved(items)
        t.equal(title, "Groupe"); t.equal(options.map(\.name), ["theme", "name"])
        t.equal(options.filter { $0.scope == .package }.map(\.name), ["theme"])
        t.equal(options.filter { $0.scope == .instance }.map(\.name), ["name"])
        t.equal(first.values, schema.defaults); t.equal(first.revision, 17)
        guard case .picker(let choices) = options[0].control else { t.check(false, "nominal choices"); return }
        t.equal(choices.map(\.title), ["2.5 doux", "Bold"])
        t.equal(choices.map(\.value), [.localCase(option: "theme", name: "soft"), .localCase(option: "theme", name: "bold")])
        t.equal(options[1].title, "Nom"); t.equal(options[1].help, "Aide")
        t.equal(options[1].control, .input(placeholder: "Saisir")); t.check(!options[1].hidden)
        let region = try schema.resolve(first.values, revision: 17, language: "fr", dateInput: date("de_DE"))
        guard case .picker(let regionalChoices) = resolved(region.items)[0].control else {
            t.check(false, "regional choices"); return
        }
        t.equal(regionalChoices[0].title, "2,5 doux")
        t.equal(region.values, first.values); t.equal(region.revision, first.revision)
        var changed = first.values.values
        changed["theme"] = .localCase(option: "theme", name: "bold"); changed["name"] = .string("Untranslated")
        let next = try schema.resolve(ProgramOptionsInput(values: changed), revision: 18, language: nil, dateInput: date())
        let nextOptions = resolved(next.items)
        t.check(nextOptions[1].hidden); t.equal(nextOptions[1].value, .string("Untranslated"))
        t.equal(nextOptions[1].title, "Name"); t.equal(nextOptions[0].scope, .package)
        t.equal(first.values.values["theme"], .localCase(option: "theme", name: "soft"))
        t.equal(schema.defaults.values["name"], .string("Raw"))
        let packageSchema = try ProgramOptionsSchema(options: [.option(theme)], translations: translations)
        let packagePanel = try packageSchema.resolve(packageSchema.defaults, revision: 9, language: "fr", dateInput: date())
        t.equal(resolved(packagePanel.items).map(\.name), ["theme"])
        t.equal(resolved(packagePanel.items).map(\.scope), [.package])
        t.equal(packagePanel.values.values["theme"], first.values.values["theme"])
    }

    t.suite("Program: option scopes: complete inputs and persisted recovery keep one typed effective namespace") {
        let quota = ProgramOption(name: "quota", title: .string("Quota"), control: .slider(
            min: ProgramNumber(0, dimension: .bytes, displayBase: 1024),
            max: ProgramNumber(4096, dimension: .bytes, displayBase: 1024), step: nil),
            defaultValue: .number(ProgramNumber(1024, dimension: .bytes, displayBase: 1024)), scope: .package)
        let local = ProgramOption(name: "name", title: .string("Name"), control: .input(placeholder: nil),
            defaultValue: .string("Default"))
        let theme = ProgramOption(name: "theme", title: .string("Theme"), control: .picker(choices: [
            ProgramOptionChoice(value: .localCase(option: "theme", name: "light"), title: .string("Light"))]),
            defaultValue: .localCase(option: "theme", name: "light"), scope: .package)
        let schema = try ProgramOptionsSchema(options: [.option(quota), .option(local), .option(theme)])
        var values = schema.defaults.values
        values["quota"] = .number(ProgramNumber(2048, dimension: .bytes, displayBase: 1000))
        let normalized = try schema.validate(ProgramOptionsInput(values: values))
        t.equal(normalized.values["quota"], .number(ProgramNumber(2048, dimension: .bytes, displayBase: 1024)))
        var partial = values; partial.removeValue(forKey: "name")
        fail(.invalidOption("name")) { _ = try schema.resolve(ProgramOptionsInput(values: partial), revision: 0, language: nil, dateInput: nil) }
        for bad in [ProgramOptionValue.number(ProgramNumber(4097, dimension: .bytes)),
                    .number(ProgramNumber(4, dimension: .duration)), .string("2048")] {
            var invalid = values; invalid["quota"] = bad
            fail(.invalidOption("quota")) { _ = try schema.validate(ProgramOptionsInput(values: invalid)) }
        }
        var nominal = values; nominal["theme"] = .localCase(option: "other", name: "light")
        fail(.invalidOption("theme")) { _ = try schema.validate(ProgramOptionsInput(values: nominal)) }
        let recovered = schema.reconcilePersisted(["quota": .string("broken"), "name": .string("Kept"),
            "theme": .localCase(option: "theme", name: "removed"), "gone": .boolean(true)])
        t.equal(recovered.restoredNames, ["quota", "theme", "gone"])
        t.equal(recovered.input.values["quota"], quota.defaultValue)
        t.equal(recovered.input.values["name"], .string("Kept")); t.equal(recovered.input.values["theme"], theme.defaultValue)
        t.equal(schema.reconcilePersisted([:]).restoredNames, [])
        let panel = try schema.resolve(recovered.input, revision: 3, language: nil, dateInput: nil)
        t.equal(resolved(panel.items).filter { $0.scope == .instance }.map(\.name), ["name"])
        let localOverride = ProgramOption(name: "quota", title: .string("Own quota"), control: quota.control,
            defaultValue: quota.defaultValue)
        fail(.invalidOption("quota")) {
            _ = try ProgramOptionsSchema(options: [.option(quota), .option(localOverride)])
        }
    }

    t.suite("Program: option scopes: scoped updates and actions retain session state and roll back failed projections") {
        let shared = ProgramOption(name: "level", title: .string("Level"), control: .slider(
            min: ProgramNumber(0, dimension: .plain), max: ProgramNumber(10, dimension: .plain), step: nil),
            defaultValue: .number(ProgramNumber(1, dimension: .plain)), scope: .package)
        let local = ProgramOption(name: "prefix", title: .string("Prefix"), control: .input(placeholder: nil),
            defaultValue: .string("Local"))
        let caption = ProgramExpression.concatenate([.option("prefix"), .string("|"), .option("level"),
            .string("|"), .declaration(0), .string("|"), .declaration(1)])
        let program = WidgetProgram(name: "Scope transactions", root: root(caption, actions: [
            .assignOption(name: "level", value: .number(3)), .assignOption(name: "prefix", value: .string("Action")),
            .copy(caption)]), declarations: [
                ProgramDeclaration(name: "remembered", kind: .variable, initial: .option("level")),
                ProgramDeclaration(name: "loads", kind: .variable, initial: .number(0))],
            onLoad: [ProgramAssignment(declaration: 1, value: .add(.declaration(1), .number(1)))],
            options: [.option(shared), .option(local)])
        var runtime = try ProgramRuntime(program: program)
        let initialMetadata = try runtime.resolveOptions(dateInput: date())
        t.equal(runtime.generation, 0); t.equal(runtime.clockPrecision, nil)
        t.equal(resolved(initialMetadata.items).map(\.scope), [.package, .instance])
        t.equal(texts(try runtime.project(environment: environment, measure: measure)), ["Local|1|1|1"])
        let input = ProgramOptionsInput(values: ["level": .number(ProgramNumber(2, dimension: .plain)), "prefix": .string("Edited")])
        let next = try runtime.updateOptions(input, expectedRevision: 0, environment: environment, measure: measure)!
        t.equal(texts(next), ["Edited|2|1|1"]); t.equal(runtime.optionsRevision, 1)
        let committed = runtime.optionValues, generation = runtime.generation
        fail(.invalidMeasurement(elementID)) {
            _ = try runtime.updateOptions(ProgramOptionsInput(values: ["level": .number(ProgramNumber(4, dimension: .plain)),
                "prefix": .string("Rejected")]), expectedRevision: 1, environment: environment) { _, _, _ in
                    SkinSize(width: .nan, height: 14)
                }
        }
        t.equal(runtime.optionValues, committed); t.equal(runtime.generation, generation); t.equal(runtime.optionsRevision, 1)
        var measured = false
        t.check(try runtime.updateOptions(ProgramOptionsInput(values: [:]), expectedRevision: 0,
            environment: environment) { _, _, _ in measured = true; return SkinSize() } == nil)
        t.check(!measured); t.equal(runtime.optionValues, committed)
        let clicked = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: next.generation,
            environment: environment, measure: measure)
        t.equal(clicked?.effects, [.copy("Action|3|1|1")])
        t.equal(texts(clicked!.scene), ["Action|3|1|1"]); t.equal(runtime.optionsRevision, 2)
        t.equal(resolved(try runtime.resolveOptions(dateInput: date()).items).map(\.scope), [.package, .instance])
        t.equal(runtime.neededSystemProperties, []); t.equal(runtime.clockPrecision, nil)
    }

    t.suite("Program: option scopes: all metadata arms and existing shared expression budgets remain enforced") {
        for scope in [ProgramOptionScope.instance, .package] {
            fail(.invalidExpression) {
                _ = try ProgramOptionsSchema(options: [.option(ProgramOption(name: "bad", title: .conditional(.boolean(true),
                    then: .string("Safe"), otherwise: .concatenate([.systemProperty(.cpuUsage)])), control: .toggle,
                    defaultValue: .boolean(false), scope: scope))])
            }
            fail(.invalidExpression) {
                _ = try ProgramOptionsSchema(options: [toggle("bad", scope: scope,
                    hiddenIf: .or(.boolean(true), .systemProperty(.batteryCharging)))])
            }
        }
        let value = ProgramExpression.concatenate(Array(repeating: .string(""), count: ProgramLimits.maximumExpressions - 2))
        _ = try ProgramRuntime(program: WidgetProgram(name: "Boundary", root: root(value),
            options: [toggle("shared", scope: .package)]))
        fail(.expressionLimit) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Shared budget", root: root(value),
                options: [toggle("shared", scope: .package), toggle("local", scope: .instance)]))
        }
        var condition = ProgramExpression.option("flag")
        for _ in 1..<ProgramLimits.maximumExpressionDepth { condition = .not(condition) }
        _ = try ProgramOptionsSchema(options: [toggle("flag", scope: .package),
            toggle("local", scope: .instance, hiddenIf: condition)])
        fail(.expressionDepth) {
            _ = try ProgramOptionsSchema(options: [toggle("flag", scope: .package),
                toggle("local", scope: .instance, hiddenIf: .not(condition))])
        }
        var nested = toggle("package", scope: .package)
        for _ in 1..<ProgramLimits.maximumDepth { nested = .section(title: .string(""), items: [nested]) }
        _ = try ProgramOptionsSchema(options: [nested])
        fail(.depthLimit) { _ = try ProgramOptionsSchema(options: [.section(title: .string(""), items: [nested])]) }
        let invalidTranslation = ProgramTranslations(source: ["title": [.text("Title")]],
            languages: ["fr": ["title": [.placeholder(0)]]])
        fail(.invalidExpression) {
            _ = try ProgramOptionsSchema(options: [.option(ProgramOption(name: "bad", title: .localized(key: "title", values: []),
                control: .toggle, defaultValue: .boolean(false), scope: .package))], translations: invalidTranslation)
        }
    }
}
