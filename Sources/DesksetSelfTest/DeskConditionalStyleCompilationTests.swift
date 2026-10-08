import Foundation
@testable import DesksetCore
@testable import DeskLanguage

enum DeskConditionalStyleCompilationTests {
    private enum Failure: Error { case fixture(String) }
    private struct Fixture {
        let checked: CheckedFile
        let package: CheckedFile?
        let program: WidgetProgram
    }
    private static let red = RGBA(r: 255, g: 0, b: 0)
    private static let green = RGBA(r: 0, g: 255, b: 0)
    private static let blue = RGBA(r: 0, g: 0, b: 255)
    private static let yellow = RGBA(r: 255, g: 255, b: 0)

    private static func checked(_ source: String, package: String? = nil) throws -> (CheckedFile, CheckedFile?) {
        guard let package else { return (deskCheck(source, file: "ConditionalStyles.desk"), nil) }
        let folder = CheckedDeskPackage(package: deskMemoryPackage([
            "package.desk": package, "ConditionalStyles.desk": source
        ]))
        guard let widget = folder.files[DeskFileID("ConditionalStyles.desk")],
              let shared = folder.files[DeskFileID("package.desk")] else { throw Failure.fixture("checked package") }
        return (widget, shared)
    }

    private static func compile(_ t: TestRunner, _ source: String, package: String? = nil) throws -> Fixture {
        let (checked, shared) = try self.checked(source, package: package)
        t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
        if let shared { t.check(shared.diagnostics(.error).isEmpty, deskDescribe(shared)) }
        let result = Desk.compile(checked, package: shared)
        t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
        t.equal(result.diagnostics, checked.diagnostics + (shared?.diagnostics ?? []))
        guard let program = result.program else { throw Failure.fixture("compile: \(source)") }
        return Fixture(checked: checked, package: shared, program: program)
    }

    private static func environment(_ dark: Bool = false) -> EnvironmentStamp {
        EnvironmentStamp(scale: 1, fontGeneration: 1,
            appearance: AppearanceStamp(value: dark ? .dark : .light, name: "conditional-styles"), imageGeneration: 0)
    }
    private static func measure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
        SkinSize(width: Double(text.utf16.count) * 5, height: TextStyle.pixelSize(points: style.fontSize))
    }
    private static func input(_ runtime: ProgramRuntime, _ changes: [String: ProgramOptionValue]) -> ProgramOptionsInput {
        ProgramOptionsInput(values: runtime.optionValues.values.merging(changes) { _, new in new })
    }
    private static func element(_ scene: WidgetScene, _ name: String) throws -> SceneElement {
        guard let element = scene.elements.first(where: { $0.id.name == name }) else { throw Failure.fixture(name) }
        return element
    }
    private static func textColor(_ scene: WidgetScene, _ name: String) throws -> RGBA {
        guard let color = try element(scene, name).items.compactMap({ item -> RGBA? in
            if case .text(let draw) = item { return draw.style.color }; return nil
        }).first else { throw Failure.fixture("text color: \(name)") }
        return color
    }
    private static func paints(_ scene: WidgetScene, _ name: String) throws -> [RGBA] {
        try element(scene, name).items.compactMap {
            switch $0 {
            case .fill(_, let paint): return paint.color
            case .bar(let draw): return draw.color
            case .roundline(let draw): return draw.color
            default: return nil
            }
        }
    }
    private static func conditions(_ value: CandidateCondition?) -> [NodeID] {
        switch value {
        case .expr(let id): return [id]
        case .all(let children): return children.flatMap { conditions($0) }
        default: return []
        }
    }
    private static func facts(_ value: CheckedFile, symbols: [NodeID: Symbol]? = nil,
                              types: [NodeID: SemType]? = nil, elements: [NodeID: ElementFacts]? = nil,
                              dataUses: [DataUse]? = nil) -> CheckedFile {
        var result = CheckedFile(tree: value.tree, diagnostics: value.diagnostics,
            symbols: symbols ?? value.symbols, types: types ?? value.types, elements: elements ?? value.elements,
            dataUses: dataUses ?? value.dataUses, dependencies: value.dependencies, reactions: value.reactions,
            freeformOrders: value.freeformOrders, stringTable: value.stringTable, requirements: value.requirements,
            options: value.options, styles: value.styles, translations: value.translations, root: value.root)
        result.loopIdentities = value.loopIdentities; result.assets = value.assets
        result.declarationTypes = value.declarationTypes
        result.canonicalNumericValues = value.canonicalNumericValues; result.numericCoercions = value.numericCoercions
        return result
    }
    private static func reject(_ t: TestRunner, _ checked: CheckedFile, package: CheckedFile? = nil,
                               catalog: DeskCatalog = .current, kind: DeskCompilationIssue.Kind = .invalidCheckedModel,
                               _ reason: String) {
        let result = Desk.compile(checked, catalog: catalog, package: package)
        t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty, reason)
        t.equal(result.issues.first?.kind, kind, "\(reason): \(result.issues)")
        t.equal(result.diagnostics, checked.diagnostics + (package?.diagnostics ?? []), reason)
    }

    static func run(_ t: TestRunner) {
        optionsAndActions(t)
        nestedConditions(t)
        precedence(t)
        packages(t)
        receiptsAndBudgets(t)
        unsupported(t)
    }

    private static func optionsAndActions(_ t: TestRunner) {
        t.suite("Desk: conditional styles: options and actions apply four slots while preserving layout and identity") {
            let source = ##"""
            options { active = Toggle("Active"); concealed = Toggle("Concealed") }
            style alert { .color("#FF0000").fill("#FF0000").track("#FFFF00").hidden(if: options.concealed) }
            widget { Row(spacing: 0, align: .top) {
                Text("A").font(12).size(30, 24).color("#0000FF").style(alert, if: options.active).name(label)
                Rectangle().size(24).fill("#0000FF").style(alert, if: options.active).name(block)
                Progress(50%).size(40, 24).color("#0000FF").track("#00FF00")
                    .style(alert, if: options.active).name(meter)
            }.name(card).onClick { options.active = not options.active; copy("applied") } }
            """##
            let fixture = try compile(t, source)
            var runtime = try ProgramRuntime(program: fixture.program)
            let first = try runtime.project(environment: environment(), measure: measure)
            t.equal(try textColor(first, "label"), blue)
            t.equal(try paints(first, "block"), [blue])
            t.equal(try paints(first, "meter"), [green, blue])
            let click = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
                environment: environment(), measure: measure)
            guard let click else { throw Failure.fixture("card click") }
            t.equal(click.effects, [.copy("applied")])
            t.equal(runtime.optionValues.values["active"], .boolean(true))
            t.equal(runtime.optionsRevision, 1)
            t.equal(try textColor(click.scene, "label"), red)
            t.equal(try paints(click.scene, "block"), [red])
            t.equal(try paints(click.scene, "meter"), [yellow, red])
            guard let hidden = try runtime.updateOptions(input(runtime, ["concealed": .boolean(true)]),
                expectedRevision: 1, environment: environment(), measure: measure) else { throw Failure.fixture("hidden update") }
            for name in ["label", "block", "meter"] {
                t.equal(try element(hidden, name).visibility, .hiddenKeepsSpace)
            }
            t.equal(hidden.elements.map(\.frame), first.elements.map(\.frame))
            t.equal(hidden.elements.map(\.id), first.elements.map(\.id))
            guard let restored = try runtime.updateOptions(input(runtime, ["active": .boolean(false)]),
                expectedRevision: 2, environment: environment(), measure: measure) else { throw Failure.fixture("restore") }
            t.equal(try textColor(restored, "label"), blue)
            t.equal(try paints(restored, "block"), [blue])
            t.equal(try paints(restored, "meter"), [green, blue])
            t.check(restored.elements.allSatisfy { $0.visibility == .visible },
                    "a false application condition also suppresses the style's true hidden leaf")
            t.equal(runtime.optionsRevision, 3); t.equal(runtime.clockPrecision, nil)
            t.equal(runtime.neededSystemProperties, [])
        }
    }

    private static func nestedConditions(_ t: TestRunner) {
        t.suite("Desk: conditional styles: application include and leaf conditions AND lazily and preserve missing clocks") {
            let source = ##"""
            options { outer = Toggle("Outer"); middle = Toggle("Middle") }
            style colorLeaf { .color("#FF0000", if: cpu.usage > 50%) }
            style hiddenLeaf { .hidden(if: cpu.usage > 50%) }
            style colorGate { .style(colorLeaf, if: options.middle) }
            style hiddenGate { .style(hiddenLeaf, if: options.middle) }
            widget { Column(spacing: 0, align: .left) {
                Text("Color").size(40, 24).color("#0000FF").style(colorGate, if: options.outer).name(label)
                Text("Hidden").size(40, 24).style(hiddenGate, if: options.outer).name(target)
            } }
            """##
            var runtime = try ProgramRuntime(program: compile(t, source).program)
            let first = try runtime.project(environment: environment(), systemInput: ProgramSystemInput(), measure: measure)
            t.equal(runtime.neededSystemProperties, [.cpuUsage])
            t.equal(runtime.clockPrecision, nil)
            let cases: [(Bool, Bool, Double?)] = [
                (false, false, 75), (false, true, 75), (true, false, 75), (true, true, 25),
                (true, true, 75), (true, true, nil), (false, true, nil)
            ]
            for (outer, middle, cpu) in cases {
                guard let scene = try runtime.updateOptions(input(runtime, ["outer": .boolean(outer), "middle": .boolean(middle)]),
                    expectedRevision: runtime.optionsRevision, environment: environment(),
                    systemInput: ProgramSystemInput(cpuUsage: cpu), measure: measure) else { throw Failure.fixture("AND update") }
                let holds = outer && middle && (cpu.map { $0 > 50 } ?? false)
                t.equal(try textColor(scene, "label"), holds ? red : blue)
                t.equal(try element(scene, "target").visibility, holds ? .hiddenKeepsSpace : .visible)
                t.equal(scene.elements.map(\.frame), first.elements.map(\.frame))
                t.equal(runtime.clockPrecision, outer && middle ? .second : nil,
                        "only an evaluated CPU leaf contributes a clock; missing still has its recovery cadence")
            }
            let missingSource = ##"""
            style leaf { .color("#FF0000", if: time.now == time.now) }
            style inner { .style(leaf, if: true) }
            style wrapper { .style(inner, if: battery.charging) }
            widget { Text("A").color("#0000FF").style(wrapper, if: cpu.coreCount > 0).name(label) }
            """##
            var missing = try ProgramRuntime(program: compile(t, missingSource).program)
            let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0),
                timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US"))
            for (cores, charging) in [(Int?.none, false), (Int?.none, true), (4, true), (4, false)] {
                let scene = try missing.project(environment: environment(), dateInput: charging ? date : nil,
                    systemInput: ProgramSystemInput(cpuCoreCount: cores, batteryCharging: charging), measure: measure)
                t.equal(try textColor(scene, "label"), cores != nil && charging ? red : blue)
                t.equal(missing.clockPrecision, charging ? .second : nil,
                        "missing AND false can short-circuit later time, but missing AND true must still read time")
            }
            for clockFirst in [false, true] {
                let applications = clockFirst
                    ? ".style(power, if: true).style(clock, if: true)"
                    : ".style(clock, if: true).style(power, if: true)"
                let source = """
                style clock { .hidden(if: time.now == time.now) }
                style power { .hidden(if: battery.charging) }
                widget { Text("A").size(30, 24)\(applications).name(label) }
                """
                var hidden = try ProgramRuntime(program: compile(t, source).program)
                for charging in [true, false] {
                    let readsTime = clockFirst || !charging
                    let scene = try hidden.project(environment: environment(), dateInput: readsTime ? date : nil,
                        systemInput: ProgramSystemInput(batteryCharging: charging), measure: measure)
                    t.equal(try element(scene, "label").visibility, .hiddenKeepsSpace)
                    t.equal(hidden.clockPrecision, readsTime ? .second : nil,
                            "hidden candidates OR in best-first order without reading a lower-priority clock")
                }
            }
        }
    }

    private static func precedence(_ t: TestRunner) {
        t.suite("Desk: conditional styles: repeated source origins retain occurrence order and ancestor fallback") {
            let source = ##"""
            options { early = Toggle("Early"); late = Toggle("Late"); own = Toggle("Own") }
            style red { .color("#FF0000") }
            style green { .color("#00FF00") }
            style concealed { .hidden() }
            widget { Column(spacing: 0, align: .left) {
                Text("Repeat").color("#0000FF").style(red, if: options.early)
                    .style(green, if: true).style(red, if: options.late).name(repeated)
                Text("Own").color("#0000FF").style(red, if: options.late)
                    .color("#FFFF00", if: options.own).name(own)
                Column(spacing: 0, align: .left) {
                    Text("Inherited").name(inherited)
                    Text("Base").color("#0000FF").name(base)
                }.style(red, if: options.early)
                Text("Hidden").style(concealed, if: options.early).style(concealed, if: options.late).name(target)
            }.color("#00FF00") }
            """##
            let fixture = try compile(t, source)
            guard let repeatedFacts = fixture.checked.elements.values.first(where: { $0.name == "repeated" }),
                  let colors = repeatedFacts.facets["color"] else { throw Failure.fixture("repeated receipts") }
            let occurrences = colors.filter { if case .style("red", _, _) = $0.origin { return true }; return false }
            t.equal(occurrences.count, 2)
            t.equal(Set(occurrences.map(\.origin)).count, 1); t.equal(Set(occurrences.map(\.value)).count, 1)
            t.equal(Set(occurrences.map(\.position)).count, 2)
            t.equal(Set(occurrences.compactMap(\.condition)).count, 2)
            var runtime = try ProgramRuntime(program: fixture.program)
            for (early, late, own) in [(false, false, false), (true, false, false), (false, true, false),
                                       (true, true, true), (false, false, true)] {
                guard let scene = try runtime.updateOptions(input(runtime, ["early": .boolean(early),
                    "late": .boolean(late), "own": .boolean(own)]), expectedRevision: runtime.optionsRevision,
                    environment: environment(), measure: measure) else { throw Failure.fixture("precedence update") }
                t.equal(try textColor(scene, "repeated"), late ? red : green)
                t.equal(try textColor(scene, "own"), own ? yellow : late ? red : blue)
                t.equal(try textColor(scene, "inherited"), early ? red : green)
                t.equal(try textColor(scene, "base"), blue, "ancestor conditions cannot outrank a child's own base")
                t.equal(try element(scene, "target").visibility, early || late ? .hiddenKeepsSpace : .visible)
            }
            let variableSource = ##"""
            style selected { .color("#FF0000") }
            widget { variable selected = false
                Text("A").size(30, 24).color("#0000FF").style(selected, if: selected).name(label)
                    .onClick { selected = true; copy("selected") }
            }
            """##
            var variable = try ProgramRuntime(program: compile(t, variableSource).program)
            let initial = try variable.project(environment: environment(), measure: measure)
            t.equal(try textColor(initial, "label"), blue)
            let clicked = try variable.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: initial.generation,
                environment: environment(), measure: measure)
            guard let clicked else { throw Failure.fixture("application variable click") }
            t.equal(clicked.effects, [.copy("selected")]); t.equal(try textColor(clicked.scene, "label"), red)
        }
    }

    private static func packages(_ t: TestRunner) {
        t.suite("Desk: conditional styles: widget conditions qualify package constants and local replacements use real source trees") {
            let package = ##"""
            package { name: "Shared" }
            style base { .color("#FF0000") }
            style card { .style(base, if: true) }
            """##
            for replace in [false, true] {
                let source = ##"""
                options { active = Toggle("Active") }
                """## + "\n" + (replace ? "style base { .color(\"#00FF00\") }\n" : "") + ##"""
                widget { Text("A").color("#0000FF").style(card, if: options.active).name(label) }
                """##
                let fixture = try compile(t, source, package: package)
                guard let shared = fixture.package, let root = fixture.checked.root,
                      let candidate = fixture.checked.elements[root]?.facets["color"]?.first(where: { $0.level == 2 }),
                      case .style("base", let origin, let file) = candidate.origin else { throw Failure.fixture("package receipt") }
                let chain = conditions(candidate.condition)
                guard chain.count == 2 else { throw Failure.fixture("package condition chain") }
                t.equal(candidate.condition, .all(chain.map(CandidateCondition.expr)))
                let definition = replace ? fixture.checked : shared
                t.equal(file, definition.tree.file); t.equal(origin.treeVersion, definition.tree.version)
                t.check(definition.tree.resolve(candidate.value) != nil)
                t.equal(chain[0].treeVersion, fixture.checked.tree.version,
                        "the application condition belongs to the widget even when the value belongs to the package")
                t.equal(chain[1].treeVersion, shared.tree.version, "the constant include condition keeps its package tree")
                var runtime = try ProgramRuntime(program: fixture.program)
                let initial = try runtime.project(environment: environment(), measure: measure)
                t.equal(try textColor(initial, "label"), blue)
                guard let enabled = try runtime.updateOptions(input(runtime, ["active": .boolean(true)]),
                    expectedRevision: 0, environment: environment(), measure: measure) else { throw Failure.fixture("package update") }
                t.equal(try textColor(enabled, "label"), replace ? green : red)
                let fresh = try checked(source, package: package)
                reject(t, fixture.checked, package: fresh.1, "an identical package text cannot replace the checked definition tree")
            }
        }
    }

    private static func receiptsAndBudgets(_ t: TestRunner) {
        t.suite("Desk: conditional styles: false losing occurrences retain complete condition receipts and bounded expansion") {
            let source = ##"""
            options { middle = Toggle("Middle") }
            style leaf { .color("#FF0000", if: cpu.usage > 50%) }
            style gate { .style(leaf, if: options.middle) }
            widget { Text("A").color("#0000FF").style(gate, if: false).color("#FFFFFF", if: true) }
            """##
            let fixture = try compile(t, source)
            let checked = fixture.checked
            guard let root = checked.root, let original = checked.elements[root],
                  let index = original.facets["color"]?.firstIndex(where: { $0.level == 2 }),
                  let candidate = original.facets["color"]?[index] else { throw Failure.fixture("losing occurrence") }
            let chain = conditions(candidate.condition)
            guard chain.count == 3 else { throw Failure.fixture("three condition receipts") }
            t.equal(candidate.condition, .all(chain.map(CandidateCondition.expr)))
            t.equal(Set(chain).count, 3)
            var edits: [ElementFacts] = []
            var changed = original; changed.facets["color"]?[index].condition = nil; edits.append(changed)
            changed = original; changed.facets["color"]?[index].condition = .all(chain.dropFirst().map(CandidateCondition.expr)); edits.append(changed)
            changed = original; changed.facets["color"]?[index].condition = .all(chain.reversed().map(CandidateCondition.expr)); edits.append(changed)
            changed = original; changed.facets["color"]?[index].condition = .all([.all(chain.map(CandidateCondition.expr))]); edits.append(changed)
            changed = original; changed.facets["color"]?[index].position += 1_000; edits.append(changed)
            changed = original; changed.facets["color"]?[index].level = 3; edits.append(changed)
            changed = original; changed.facets["color"]?[index].hard = false; edits.append(changed)
            changed = original; changed.facets["color"]?[index].fixedValue = ".red"; edits.append(changed)
            changed = original; changed.facets["color"]?.remove(at: index); edits.append(changed)
            changed = original; changed.facets["color"]?.append(candidate); edits.append(changed)
            for changed in edits {
                var elements = checked.elements; elements[root] = changed
                reject(t, facts(checked, elements: elements), "false or overridden candidates still require exact receipts")
            }
            for condition in chain {
                var types = checked.types; types[condition] = SemType(type: .plainNumber)
                reject(t, facts(checked, types: types), "every AND operand retains its checked Bool type")
                var forged = checked; forged.canonicalNumericValues[condition] = 1
                reject(t, forged, "a condition cannot acquire a forged numeric constant")
            }
            guard let optionCondition = chain.first(where: { if case .option? = checked.symbols[$0] { return true }; return false }) else {
                throw Failure.fixture("include option symbol")
            }
            var symbols = checked.symbols; symbols.removeValue(forKey: optionCondition)
            reject(t, facts(checked, symbols: symbols), "the losing include still needs its option symbol")
            reject(t, facts(checked, dataUses: []), kind: .unsupported,
                   "a false outer condition does not erase the CPU receipt")
            let application = try compile(t, """
                style leaf { .color(.red) }
                widget { Text("A").style(leaf, if: false and cpu.usage > 50%).color(.white, if: true) }
                """).checked
            guard let applicationRoot = application.root,
                  let applicationCandidate = application.elements[applicationRoot]?.facets["color"]?.first(where: { $0.level == 2 }),
                  case .expr(let applicationCondition)? = applicationCandidate.condition,
                  let cpu = application.symbols.first(where: {
                      $0.value == .builtIn(.member(namespace: "cpu", name: "usage"))
                  })?.key else { throw Failure.fixture("application system condition") }
            var types = application.types; types[cpu] = SemType(type: .bool)
            reject(t, facts(application, types: types), kind: .unsupported,
                   "a false application cannot reinterpret CPU Percent as Bool")
            var forged = application; forged.canonicalNumericValues[applicationCondition] = 1
            reject(t, forged, "an application Bool root cannot acquire a numeric canonical receipt")
            forged = application; forged.numericCoercions[applicationCondition] = .percentAsFraction
            reject(t, forged, "an application Bool root cannot acquire a percentage coercion")
            forged = application; forged.canonicalNumericValues[cpu] = 75
            reject(t, forged, "a false losing application still validates its live numeric leaf")
            for expression in ["cpu.usage > 50%", "((cpu.usage)) > 50%", "level > 50%"] {
                let live = try compile(t, """
                    style alert { .color("#FF0000") }
                    widget { variable level = 25%
                        Text("A").size(30, 24).color("#0000FF").style(alert, if: \(expression)).name(label)
                            .onClick { level = 75%; copy("changed") }
                    }
                    """)
                var runtime = try ProgramRuntime(program: live.program)
                let before = try runtime.project(environment: environment(),
                    systemInput: ProgramSystemInput(cpuUsage: 25), measure: measure)
                t.equal(try textColor(before, "label"), blue)
                let clicked = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: before.generation,
                    environment: environment(), systemInput: ProgramSystemInput(cpuUsage: 75), measure: measure)
                guard let clicked else { throw Failure.fixture("live condition action") }
                t.equal(clicked.effects, [.copy("changed")])
                t.equal(try textColor(clicked.scene, "label"), red, "the authentic condition remains dynamic")
                guard let root = live.checked.root,
                      let candidate = live.checked.elements[root]?.facets["color"]?.first(where: { $0.level == 2 }),
                      case .expr(let condition)? = candidate.condition,
                      let node = live.checked.tree.resolve(condition), let comparison = BinaryExprSyntax(node) else {
                    throw Failure.fixture("live numeric condition subtree")
                }
                let number = live.checked.tree.id(of: comparison.left.node)
                t.equal(live.checked.types[number]?.type, .percent)
                t.equal(live.checked.canonicalNumericValues[number], nil)
                var frozen = live.checked; frozen.canonicalNumericValues[number] = 75
                reject(t, frozen, "live numeric leaf, parent wrapper or variable cannot become a canonical constant: \(expression)")
            }
            let fresh = try self.checked(source).0
            var stale = checked.elements
            if let freshRoot = fresh.root, let freshCandidate = fresh.elements[freshRoot]?.facets["color"]?.first(where: { $0.level == 2 }) {
                stale[root]?.facets["color"]?[index].origin = freshCandidate.origin
                reject(t, facts(checked, elements: stale), "the same leaf source offset from another tree is stale")
            } else { throw Failure.fixture("fresh receipt") }

            let prefix = "style leaf { .color(.red) }\n"
            let small = deskCheck(prefix + #"widget { Text("A").style(leaf, if: false) }"#)
            var catalog = DeskCatalog.current; catalog.limits.maximumTokens = 128
            t.check(Desk.compile(small, catalog: catalog).program != nil, "one conditional expansion fits the reduced budget")
            // Each application consumes at least one expansion, before its facet and expression costs.
            let repeated = deskCheck(prefix + #"widget { Text("A")"# +
                String(repeating: ".style(leaf, if: false)", count: 160) + ".color(.white, if: true) }")
            t.check(repeated.diagnostics(.error).isEmpty, deskDescribe(repeated))
            reject(t, repeated, catalog: catalog, kind: .resourceLimit, "false losing applications still consume expansion budget")
            let deep = deskCheck("style leaf { .color(.red, if: ((((cpu.usage > 50%))))) }\n" +
                #"widget { Text("A").style(leaf, if: false) }"#)
            t.check(deep.diagnostics(.error).isEmpty, deskDescribe(deep))
            catalog = .current; catalog.limits.maximumExpressionNesting = 2
            reject(t, deep, catalog: catalog, kind: .resourceLimit, "unselected leaf expressions remain depth bounded")
        }
    }

    private static func unsupported(_ t: TestRunner) {
        t.suite("Desk: conditional styles: unsupported conditional facets states and package dynamics never hide behind false") {
            let inapplicable = try compile(t, "style limited { .tint(.red) }\n" +
                #"widget { Text("A").background(.glass).style(limited, if: false) }"#)
            let literal = try compile(t, #"widget { Text("A").background(.glass) }"#)
            t.equal(inapplicable.program, literal.program, "a picture tint in a style does not apply to Text")
            for dark in [false, true] {
                var styled = try ProgramRuntime(program: inapplicable.program)
                var explicit = try ProgramRuntime(program: literal.program)
                t.equal(try styled.project(environment: environment(dark), measure: measure),
                        try explicit.project(environment: environment(dark), measure: measure),
                        "an inapplicable tint leaves the complete glass scene unchanged")
            }
            let cases: [(String, String)] = [
                (".font(12)", #"Text("A").font(18)"#),
                (#".tooltip("Style")"#, #"Text("A").tooltip("Own")"#),
                (#".voiceOver("Style")"#, #"Text("A").voiceOver("Own")"#),
                (".background(.glass)", #"Text("A").background(.dim)"#),
                (".background(.glass, tint: .red)", #"Text("A").background(.glass)"#),
                (".size(20)", #"Text("A").size(40)"#),
                (".padding(2)", #"Text("A").padding(4)"#),
                (".stroke(.red, width: 2)", "Rectangle().size(40).stroke(.blue, width: 1)"),
                (".iconColors(.hierarchical)", #"Icon("wifi").iconColors(.monochrome)"#),
                (".hover { .color(.red) }", #"Text("A").color(.blue)"#),
                (".pressed { .color(.red) }", #"Text("A").color(.blue)"#)
            ]
            for (modifier, element) in cases {
                let source = "style limited { \(modifier) }\nwidget { \(element).style(limited, if: false) }"
                let checked = try self.checked(source).0
                t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
                reject(t, checked, kind: .unsupported, "unsupported conditional style facet: \(modifier)")
            }
            let nested = deskCheck("style font { .font(12) }\nstyle gate { .style(font, if: false) }\n" +
                #"widget { Text("A").style(gate).font(18) }"#)
            t.check(nested.diagnostics(.error).isEmpty, deskDescribe(nested))
            reject(t, nested, kind: .unsupported, "conditional includes cannot disguise an unsupported leaf facet")
            for modifier in [".color(.red, if: system.dark)", ".hidden(if: battery.charging)"] {
                let package = "package { name: \"Shared\" }\nstyle remote { \(modifier) }"
                let (checked, shared) = try self.checked(#"widget { Text("A").color(.blue).style(remote, if: false) }"#,
                                                       package: package)
                t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
                if let shared { t.check(shared.diagnostics(.error).isEmpty, deskDescribe(shared)) }
                reject(t, checked, package: shared, kind: .unsupported, "package-defined dynamic expressions remain unsupported")
            }
        }
    }
}
