import Foundation
@testable import DesksetCore
@testable import DeskLanguage

enum DeskOptionFixtureError: Error { case program(String), receipt }

func deskOptionCompilation(_ t: TestRunner, _ source: String) throws -> (CheckedFile, WidgetProgram) {
    let checked = deskCheck(source, file: "Options.desk"), result = Desk.compile(checked)
    t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
    t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
    t.equal(result.diagnostics, checked.diagnostics)
    guard let program = result.program else { throw DeskOptionFixtureError.program(source) }
    return (checked, program)
}

func deskOptionEnvironment() -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1, appearance: AppearanceStamp(value: .light, name: "options"), imageGeneration: 0)
}

func deskOptionMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    SkinSize(width: 60, height: 12)
}

func deskOptionDefinitions(_ nodes: [ProgramOptionNode]) -> [ProgramOption] {
    nodes.flatMap { node in
        switch node { case .option(let value): return [value]; case .section(_, let children): return deskOptionDefinitions(children) }
    }
}

func deskResolvedOptions(_ nodes: [ProgramResolvedOptionNode]) -> [ProgramResolvedOption] {
    nodes.flatMap { node in
        switch node { case .option(let value): return [value]; case .section(_, let children): return deskResolvedOptions(children) }
    }
}

func deskOptionTexts(_ scene: WidgetScene) -> [String] {
    scene.drawingItems.compactMap { if case .text(let value) = $0 { return value.text }; return nil }
}

func runDeskOptionsCompilationTests(_ t: TestRunner) {
    t.suite("Desk: options compilation: the original Toggle source has a typed independent default") {
        let source = #"options { show = Toggle("Show") }"# + "\n" + #"widget { Text("A") }"#
        let (checked, program) = try deskOptionCompilation(t, source)
        t.equal(program.options, [.option(ProgramOption(name: "show", title: .string("Show"), control: .toggle, defaultValue: .boolean(false)))])
        t.equal(program.declarations, []); t.equal(program.onLoad, [])
        t.equal(checked.options["show"]?.type, .bool)
        t.equal(Desk.compile(checked).elementRefs.count, 1, "panel metadata is not a view")
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        t.equal(deskOptionTexts(scene), ["A"]); t.equal(runtime.optionValues.values, ["show": .boolean(false)])
    }

    t.suite("Desk: options compilation: controls preserve defaults dimensions continuous sliders and canonical steps") {
        let source = #"""
            options {
                show = Toggle("Show", default: (not false))
                note = Input("Note")
                level = Slider("Level", min: 0, max: 100)
                count = Stepper("Count", min: -2, max: 5)
                delay = Stepper("Delay", min: 0s, max: 10s, default: 2s)
                size = Stepper("Size", min: 0pt, max: 24pt, default: 12pt)
                angle = Slider("Angle", min: 0deg, max: 360deg, step: 15deg, default: 1rad)
                bytes = Slider("Bytes", min: 0GiB, max: 8GiB, default: 2GiB)
            }
            widget { Text(options.level > cpu.usage) }
            """#
        let (checked, program) = try deskOptionCompilation(t, source)
        let values = Dictionary(uniqueKeysWithValues: deskOptionDefinitions(program.options).map { ($0.name, $0) })
        t.equal(values["show"]?.defaultValue, .boolean(true)); t.equal(values["note"]?.defaultValue, .string(""))
        t.equal(values["level"]?.control, .slider(min: ProgramNumber(0, dimension: .percent), max: ProgramNumber(100, dimension: .percent), step: nil))
        t.equal(checked.options["level"]?.type, .percent)
        t.equal(values["count"]?.control, .stepper(min: ProgramNumber(-2, dimension: .plain), max: ProgramNumber(5, dimension: .plain), step: ProgramNumber(1, dimension: .plain)))
        t.equal(values["delay"]?.control, .stepper(min: ProgramNumber(0, dimension: .duration), max: ProgramNumber(10, dimension: .duration), step: ProgramNumber(1, dimension: .duration)))
        t.equal(values["size"]?.defaultValue, .number(ProgramNumber(12, dimension: .length)))
        t.equal(values["angle"]?.defaultValue, .number(ProgramNumber(180 / Double.pi, dimension: .angle)))
        t.equal(values["bytes"]?.defaultValue, .number(ProgramNumber(2 * pow(1024, 3), dimension: .bytes, displayBase: 1024)))
        let schema = try ProgramOptionsSchema(options: program.options, translations: program.translations)
        t.equal(schema.defaults.values["note"], .string("")); t.equal(schema.defaults.values.count, 8)
    }

    t.suite("Desk: options compilation: scalar and nominal Picker values keep choice identities and labels") {
        let source = #"""
            options {
                word = Picker("Word", ["One", Choice("Two", "Second")], default: "Two")
                number = Picker("Number", [1, Choice(2, "Double")], default: 2)
                theme = Picker("Theme", [Choice(.dayMode, "Shared"), Choice(.nightMode, "Shared")])
            }
            widget { Column(spacing: 0) { Text(options.word); Text(options.number); Text(options.theme); Text(options.theme == .nightMode) }.onClick { options.theme = .nightMode; copy(options.theme) } }
            translations { "zh-Hans" { "Shared": "相同" } }
            """#
        let (checked, program) = try deskOptionCompilation(t, source)
        t.equal(checked.options["theme"]?.localEnum, "Theme")
        let values = deskOptionDefinitions(program.options)
        t.equal(values[0].defaultValue, .string("Two")); t.equal(values[1].defaultValue, .number(ProgramNumber(2, dimension: .plain)))
        t.equal(values[2].defaultValue, .localCase(option: "theme", name: "dayMode"))
        guard case .picker(let choices) = values[2].control else { throw DeskOptionFixtureError.receipt }
        t.check(choices[0].value != choices[1].value, "identical translated titles are not identical cases")
        var runtime = try ProgramRuntime(program: program, language: "zh-Hans")
        let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US"))
        let first = try runtime.project(environment: deskOptionEnvironment(), dateInput: date, measure: deskOptionMeasure)
        t.equal(deskOptionTexts(first), ["Two", "2", "相同", "No"])
        let changed = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: deskOptionEnvironment(), dateInput: date, measure: deskOptionMeasure)
        t.equal(changed?.effects, [.copy("相同")]); t.equal(runtime.optionValues.values["theme"], .localCase(option: "theme", name: "nightMode"))
        t.equal(changed.map { deskOptionTexts($0.scene) }, ["Two", "2", "相同", "Yes"])
    }

    t.suite("Desk: options compilation: String Choice defaults compare values and fix to the unwrapped first choice") {
        for suffix in ["", #", default: "Two""#] {
            let source = #"options { word = Picker("Word", [Choice("Two", "Second"), "One"]"# + suffix + ") }\nwidget { Text(options.word) }"
            let (_, program) = try deskOptionCompilation(t, source)
            t.equal(deskOptionDefinitions(program.options)[0].defaultValue, .string("Two"))
            var runtime = try ProgramRuntime(program: program)
            t.equal(deskOptionTexts(try runtime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)), ["Two"])
        }
        for invalid in ["Second", "Missing"] {
            let source = #"options { word = Picker("Word", [Choice("Two", "Second"), "One"], default: ""# + invalid + #"") }"# + "\nwidget { Text(options.word) }"
            let checked = deskCheck(source)
            t.equal(checked.diagnostics(.error).map(\.id), [.pickerDefaultNotAChoice], deskDescribe(checked))
            t.check(Desk.compile(checked).program == nil)
            guard let diagnostic = checked.diagnostics.first(where: { $0.id == .pickerDefaultNotAChoice }),
                  let fix = diagnostic.fixIts.first else { throw DeskOptionFixtureError.receipt }
            t.equal(fix.titleKey, "useFirstChoice")
            t.equal(fix.edits.first?.replacement, #""Two""#, "a label and the entire Choice call are not option values")
            let repaired = TextEdit.apply(fix.edits, to: source)
            t.equal(repaired, source.replacingOccurrences(of: "default: \"\(invalid)\"", with: "default: \"Two\""))
            let (_, program) = try deskOptionCompilation(t, repaired)
            t.equal(deskOptionDefinitions(program.options)[0].defaultValue, .string("Two"))
        }
    }

    t.suite("Desk: options compilation: ordered option variable and menu assignments commit once and roll back together") {
        let source = #"""
            options { level = Slider("Level", min: 0, max: 10, step: 5); show = Toggle("Show") }
            widget { variable count = 1; computed sum = options.level + count; Text(sum).size(60, 30)
                .onClick { options.level = 7; options.show = not options.show; count = count + 1; copy(sum) }
                .menu { Item("Set").onClick { options.level = 4; copy(sum) } } }
            """#
        let (_, program) = try deskOptionCompilation(t, source)
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        t.equal(deskOptionTexts(first), ["1"])
        do {
            _ = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
                environment: deskOptionEnvironment(), measure: { _, _, _ in SkinSize(width: -1, height: 12) })
            t.check(false, "a rejected projection must not persist preceding options")
        } catch let error as ProgramRuntimeError { t.equal(error, .invalidMeasurement(program.root.id)) }
        t.equal(runtime.optionValues.values["level"], .number(ProgramNumber(0, dimension: .plain))); t.equal(runtime.optionsRevision, 0)
        let accepted = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        t.equal(accepted?.effects, [.copy("9")]); t.equal(runtime.optionsRevision, 1)
        t.equal(runtime.optionValues.values["level"], .number(ProgramNumber(7, dimension: .plain)), "off-grid in-range values remain valid")
        guard let scene = accepted?.scene,
              let menu = try runtime.resolveMenu(program.root.id, expectedGeneration: scene.generation, environment: deskOptionEnvironment()),
              case .item(let item, _, _, _)? = menu.items.first else { throw DeskOptionFixtureError.receipt }
        let menuResult = try runtime.activateMenuItemWithEffects(item, expectedGeneration: scene.generation,
            environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        t.equal(menuResult?.effects, [.copy("6")]); t.equal(runtime.optionsRevision, 2)
        t.equal(runtime.optionValues.values["show"], .boolean(true))
    }

    t.suite("Desk: options compilation: Sections translated panel text and generated titles retain raw storage") {
        let source = #"""
            options { Section("Card") {
                show = Toggle("Keep {2} items").help("Details")
                note = Input("Note", default: "Oslo", placeholder: "City")
                word = Picker("Word", ["One", "Two"])
                mode = Picker("Mode", [.dayMode, .nightMode])
            } }
            widget { Text(options.word).size(60).onClick { copy(options.word); open(options.note) } }
            translations { "zh-Hans" {
                "Card": "卡片"; "Keep {2} items": "保留 {2} 项"; "Details": "说明"; "Note": "备注"; "City": "城市"
                "One": "一"; "Two": "二"; "Day Mode": "白天"; "Night Mode": "夜间"
            } }
            """#
        let (_, program) = try deskOptionCompilation(t, source)
        var runtime = try ProgramRuntime(program: program, language: "zh-Hans")
        let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US"))
        let panel = try runtime.resolveOptions(dateInput: date)
        guard case .section(let title, let nodes)? = panel.items.first else { throw DeskOptionFixtureError.receipt }
        t.equal(title, "卡片")
        let controls = deskResolvedOptions(nodes)
        t.equal(controls[0].title, "保留 2 项"); t.equal(controls[0].help, "说明")
        t.equal(controls[1].control, .input(placeholder: "城市")); t.equal(controls[1].value, .string("Oslo"))
        guard case .picker(let words) = controls[2].control, case .picker(let modes) = controls[3].control else { throw DeskOptionFixtureError.receipt }
        t.equal(words.map(\.title), ["一", "二"]); t.equal(words.map(\.value), [.string("One"), .string("Two")])
        t.equal(modes.map(\.title), ["白天", "夜间"])
        let first = try runtime.project(environment: deskOptionEnvironment(), dateInput: date, measure: deskOptionMeasure)
        t.equal(deskOptionTexts(first), ["One"])
        let click = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
            environment: deskOptionEnvironment(), dateInput: date, measure: deskOptionMeasure)
        t.equal(click?.effects, [.copy("One"), .open("Oslo")])
        let sameKey = #"options { mode = Picker("Mode", [.dayMode, .nightMode]) }"# + "\n" +
            #"widget { Text("Day Mode") }"# + "\n" + #"translations { "zh-Hans" { "Day Mode": "白天" } }"#
        let (_, shared) = try deskOptionCompilation(t, sameKey)
        t.equal(shared.translations.source["Day Mode"], [.text("Day Mode")])
    }

    t.suite("Desk: options compilation: repeated panel hidden conditions react only to option values") {
        let source = #"""
            options {
                show = Toggle("Show")
                hide = Toggle("Hide")
                note = Input("Note").hidden(if: options.show).hidden(if: options.hide)
                always = Toggle("Always").hidden()
                theme = Picker("Theme", [.dayMode, .nightMode])
                extra = Input("Extra").hidden(if: options.theme == Theme.nightMode)
            }
            widget { Text("A") }
            """#
        let (_, program) = try deskOptionCompilation(t, source)
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        t.equal(runtime.clockPrecision, nil); t.equal(first.elements.count, 1)
        t.equal(deskResolvedOptions(try runtime.resolveOptions().items).map(\.hidden), [false, false, false, true, false, false])
        for value in ["show", "hide"] {
            var input = runtime.optionValues.values; input[value] = .boolean(true)
            _ = try runtime.updateOptions(ProgramOptionsInput(values: input), expectedRevision: runtime.optionsRevision,
                environment: deskOptionEnvironment(), measure: deskOptionMeasure)
            t.equal(deskResolvedOptions(try runtime.resolveOptions().items)[2].hidden, true)
            input[value] = .boolean(false)
            _ = try runtime.updateOptions(ProgramOptionsInput(values: input), expectedRevision: runtime.optionsRevision,
                environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        }
        var input = runtime.optionValues.values; input["theme"] = .localCase(option: "theme", name: "nightMode")
        _ = try runtime.updateOptions(ProgramOptionsInput(values: input), expectedRevision: runtime.optionsRevision,
            environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        t.equal(deskResolvedOptions(try runtime.resolveOptions().items)[5].hidden, true)
        t.equal(runtime.clockPrecision, nil)
    }

    t.suite("Desk: options compilation: invalid constraints defaults and unsupported dynamic values fail without publication") {
        let checkedUnsupported = [
            #"options { x = Slider("X", min: 5, max: 1) }"#,
            #"options { x = Stepper("X", min: 0, max: 10, step: 0) }"#,
            #"options { x = Slider("X", min: 0, max: 10, default: 11) }"#,
            #"options { x = Picker("X", [1, 2], default: 3) }"#,
            #"options { x = Slider("X", min: 0, max: 100, default: cpu.usage) }"#,
            #"options { x = Toggle("X", default: battery.charging) }"#,
            #"options { x = Picker("X", [.sunday, .monday]) }"#,
            #"options { x = ColorPicker("X") }"#]
        for prefix in checkedUnsupported {
            let checked = deskCheck(prefix + "\nwidget { Text(\"A\") }")
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            let result = Desk.compile(checked)
            t.check(result.program == nil && !result.issues.isEmpty, "\(prefix): \(result.issues)")
            t.check(result.elementRefs.isEmpty && result.imageSources.isEmpty); t.equal(result.diagnostics, checked.diagnostics)
        }
        let startup = deskCheck(#"options { x = Toggle("X") }"# + "\n" + #"widget { Text("A").onLoad { options.x = true } }"#)
        t.check(startup.diagnostics(.error).isEmpty, deskDescribe(startup)); t.equal(Desk.compile(startup).issues.first?.kind, .unsupported)
        let blocked = deskCheck(#"options { x = Input("X").hidden(if: battery.charging) }"# + "\n" + #"widget { Text("A") }"#)
        t.check(blocked.diagnostics(.error).contains { $0.id == .optionConditionNotOption })
        t.check(Desk.compile(blocked).program == nil)
        let wrappedChoice = deskCheck(#"options { x = Picker("X", [("A"), "B"]) }"# + "\n" + #"widget { Text("A") }"#)
        t.check(!wrappedChoice.diagnostics(.error).isEmpty, deskDescribe(wrappedChoice))
        t.check(Desk.compile(wrappedChoice).program == nil, "the checker only admits literal scalar Picker choices")
    }

    t.suite("Desk: options compilation: package options remain an explicit boundary") {
        let source = #"widget { Text("A") }"#
        let folder = CheckedDeskPackage(package: deskMemoryPackage([
            "package.desk": #"options { show = Toggle("Show") }"#, "Options.desk": source
        ]))
        guard let package = folder.files[DeskFileID("package.desk")], let checked = folder.files[DeskFileID("Options.desk")] else { throw DeskOptionFixtureError.receipt }
        t.check(package.diagnostics(.error).isEmpty && checked.diagnostics(.error).isEmpty)
        let denied = Desk.compile(checked, package: package)
        t.equal(denied.issues.first?.kind, .unsupported); t.equal(denied.issues.first?.file, package.tree.file)
        t.check(denied.program == nil && denied.elementRefs.isEmpty)
    }

    t.suite("Desk: options compilation: the original option driven style updates like an own font modifier") {
        let dynamicStyle = deskCheck(#"options { size = Slider("Size", min: 1, max: 20) }"# + "\n" +
            #"style label { .font(options.size) }"# + "\n" + #"widget { Text("A").style(label) }"#, file: "Options.desk")
        t.check(dynamicStyle.diagnostics(.error).isEmpty, deskDescribe(dynamicStyle))
        let result = Desk.compile(dynamicStyle)
        t.check(result.issues.isEmpty); t.equal(result.diagnostics, dynamicStyle.diagnostics)
        guard let program = result.program else { throw DeskOptionFixtureError.receipt }
        let (_, direct) = try deskOptionCompilation(t, #"options { size = Slider("Size", min: 1, max: 20) }"# + "\n" +
            #"widget { Text("A").font(options.size) }"#)
        t.equal(program, direct)
        t.equal(dynamicStyle.options["size"]?.type, .length)
        var styledRuntime = try ProgramRuntime(program: program), directRuntime = try ProgramRuntime(program: direct)
        let initial = try styledRuntime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        t.equal(initial, try directRuntime.project(environment: deskOptionEnvironment(), measure: deskOptionMeasure))
        let input = ProgramOptionsInput(values: ["size": .number(ProgramNumber(20, dimension: .length))])
        let updated = try styledRuntime.updateOptions(input, expectedRevision: 0,
            environment: deskOptionEnvironment(), measure: deskOptionMeasure)
        t.equal(updated, try directRuntime.updateOptions(input, expectedRevision: 0,
            environment: deskOptionEnvironment(), measure: deskOptionMeasure))
        t.equal(initial.drawingItems.compactMap { item -> Double? in
            if case .text(let value) = item { return TextStyle.pixelSize(points: value.style.fontSize) }; return nil
        }, [1])
        t.equal(updated?.drawingItems.compactMap { item -> Double? in
            if case .text(let value) = item { return TextStyle.pixelSize(points: value.style.fontSize) }; return nil
        }, [20])
        t.equal(styledRuntime.optionsRevision, 1)
    }
}
