import Foundation
@testable import DesksetCore
@testable import DeskLanguage

enum DeskConditionalBackgroundCompilationTests {
    private enum Failure: Error { case fixture(String) }
    private static let red = RGBA(r: 255, g: 0, b: 0)
    private static let blue = RGBA(r: 0, g: 0, b: 255)

    private static func compile(_ t: TestRunner, _ source: String, package: String? = nil) throws -> DeskCompilationResult {
        let checked: CheckedFile, shared: CheckedFile?
        if let package {
            let folder = CheckedDeskPackage(package: deskMemoryPackage([
                "package.desk": package, "ConditionalBackgrounds.desk": source
            ]))
            guard let widget = folder.files[DeskFileID("ConditionalBackgrounds.desk")],
                  let common = folder.files[DeskFileID("package.desk")] else { throw Failure.fixture("package") }
            checked = widget; shared = common
        } else { checked = deskCheck(source, file: "ConditionalBackgrounds.desk"); shared = nil }
        t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
        if let shared { t.check(shared.diagnostics(.error).isEmpty, deskDescribe(shared)) }
        let result = Desk.compile(checked, package: shared)
        t.equal(result.diagnostics, checked.diagnostics + (shared?.diagnostics ?? []))
        t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
        guard result.program != nil else { throw Failure.fixture("program: \(source)") }
        return result
    }

    private static func program(_ result: DeskCompilationResult) throws -> WidgetProgram {
        guard let value = result.program else { throw Failure.fixture("program") }; return value
    }
    private static func environment() -> EnvironmentStamp {
        EnvironmentStamp(scale: 1, fontGeneration: 1,
            appearance: AppearanceStamp(value: .light, name: "conditional-backgrounds"), imageGeneration: 0)
    }
    private static func measure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
        SkinSize(width: 9, height: 8)
    }
    private static func fills(_ scene: WidgetScene) -> [RGBA] {
        scene.drawingItems.compactMap { if case .fill(_, let paint) = $0 { return paint.color }; return nil }
    }
    private static func first(_ scene: WidgetScene) throws -> SceneElement {
        guard let value = scene.elements.first else { throw Failure.fixture("scene element") }; return value
    }
    private static func facts(_ value: CheckedFile, symbols: [NodeID: Symbol]? = nil,
                              types: [NodeID: SemType]? = nil, elements: [NodeID: ElementFacts]? = nil) -> CheckedFile {
        var result = CheckedFile(tree: value.tree, diagnostics: value.diagnostics,
            symbols: symbols ?? value.symbols, types: types ?? value.types, elements: elements ?? value.elements,
            dataUses: value.dataUses, dependencies: value.dependencies, reactions: value.reactions,
            freeformOrders: value.freeformOrders, stringTable: value.stringTable, requirements: value.requirements,
            options: value.options, styles: value.styles, translations: value.translations, root: value.root)
        result.loopIdentities = value.loopIdentities; result.assets = value.assets
        result.declarationTypes = value.declarationTypes
        result.canonicalNumericValues = value.canonicalNumericValues; result.numericCoercions = value.numericCoercions
        return result
    }
    private static func reject(_ t: TestRunner, _ value: CheckedFile, catalog: DeskCatalog = .current,
                               kind: DeskCompilationIssue.Kind? = nil, _ reason: String) {
        let result = Desk.compile(value, catalog: catalog)
        t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty, reason)
        t.check(!result.issues.isEmpty, "\(reason): \(result.issues)")
        if let kind { t.equal(result.issues.first?.kind, kind, reason) }
        t.equal(result.diagnostics, value.diagnostics, reason)
    }

    static func run(_ t: TestRunner) {
        ordinary(t)
        independentTint(t)
        styleChains(t)
        transactions(t)
        receipts(t)
        budgets(t)
        unsupported(t)
    }

    private static func ordinary(_ t: TestRunner) {
        t.suite("Desk: conditional backgrounds: active candidates select color glass or no background without changing the box") {
            let source = ##"widget { Text("A").size(40, 20).padding(3).background("#FF0000", if: cpu.usage >= 50%).background(.glass, if: battery.charging) }"##
            let result = try compile(t, source)
            var runtime = try ProgramRuntime(program: program(result))
            t.equal(runtime.neededSystemProperties, [.cpuUsage, .batteryCharging])
            let cases: [(ProgramSystemInput, RGBA?, Bool)] = [
                (ProgramSystemInput(batteryCharging: false), nil, false),
                (ProgramSystemInput(cpuUsage: 25, batteryCharging: false), nil, false),
                (ProgramSystemInput(cpuUsage: 75, batteryCharging: false), red, false),
                (ProgramSystemInput(cpuUsage: 75, batteryCharging: true), nil, true)]
            for (input, color, glass) in cases {
                let scene = try runtime.project(environment: environment(), systemInput: input, measure: measure)
                let element = try first(scene)
                t.equal(scene.size, SkinSize(width: 40, height: 20))
                t.equal(element.frame, SkinRect(width: 40, height: 20))
                t.equal(fills(scene), color.map { [$0] } ?? [])
                t.equal(element.glass != nil, glass)
                t.equal(scene.drawingItems.count, color != nil || glass ? 2 : 1)
                if let region = element.glass {
                    t.equal(region.rect, element.frame); t.equal(region.style, .regular); t.check(region.tint == nil)
                }
                if !glass && color == nil {
                    t.check(element.items.allSatisfy { if case .text = $0 { return true }; return false },
                        "an inactive background is absent, without a transparent fill")
                }
                t.equal(runtime.clockPrecision, glass ? nil : .second, "only selected condition paths retain a clock")
            }
            t.equal(result.elementRefs.count, 1)
        }
    }

    private static func independentTint(_ t: TestRunner) {
        t.suite("Desk: conditional backgrounds: paint and tint precedence remain independent and color ignores glass tint") {
            let base = "style base { .background(.glass, tint: \"#FF0000\") }\n"
            var plain = try ProgramRuntime(program: program(compile(t,
                base + ##"widget { Text("A").size(40, 20).style(base).background("#0000FF") }"##)))
            let color = try plain.project(environment: environment(), measure: measure)
            t.equal(fills(color), [blue]); t.check(try first(color).glass == nil)
            let source = base + "style live { .style(base, if: cpu.usage >= 50%) }\n" + ##"widget { Text("A").size(40, 20).style(live, if: battery.pluggedIn).background("#0000FF").background(.clearGlass, if: battery.charging) }"##
            var runtime = try ProgramRuntime(program: program(compile(t, source)))
            for (input, style, tint) in [
                (ProgramSystemInput(cpuUsage: 75, batteryCharging: false, batteryPluggedIn: false), Optional<GlassStyle>.none, Optional<RGBA>.none),
                (ProgramSystemInput(cpuUsage: 75, batteryCharging: false, batteryPluggedIn: true), .regular, red),
                (ProgramSystemInput(cpuUsage: 25, batteryCharging: true, batteryPluggedIn: true), .clear, nil),
                (ProgramSystemInput(cpuUsage: 75, batteryCharging: true, batteryPluggedIn: true), .clear, red)] {
                let scene = try runtime.project(environment: environment(), systemInput: input, measure: measure)
                let element = try first(scene)
                t.equal(element.glass?.style, style); t.equal(element.glass?.tint, tint)
                t.equal(fills(scene), style == nil ? [blue] : [])
                t.equal(element.frame, SkinRect(width: 40, height: 20))
            }
        }
    }

    private static func styleChains(_ t: TestRunner) {
        t.suite("Desk: conditional backgrounds: package constants and complete nested style conditions retain real element references") {
            let package = "style base { .background(.glass, tint: \"#FF0000\") }"
            let source = ##"""
            options { active = Toggle("Active") }
            style card { .style(base, if: true) }
            widget { Text("A").size(40, 20).style(card, if: options.active) }
            """##
            let result = try compile(t, source, package: package)
            var runtime = try ProgramRuntime(program: program(result))
            let off = try runtime.project(environment: environment(), measure: measure)
            t.check(try first(off).glass == nil); t.equal(fills(off), [])
            let on = try runtime.updateOptions(ProgramOptionsInput(values: ["active": .boolean(true)]),
                expectedRevision: runtime.optionsRevision, environment: environment(), measure: measure)
            guard let on else { throw Failure.fixture("options update") }
            t.equal(try first(on).glass?.style, .regular); t.equal(try first(on).glass?.tint, red)
            t.equal(on.elements.map(\.id), off.elements.map(\.id))
            t.equal(result.elementRefs.count, 1); t.equal(on.size, off.size)
        }
    }

    private static func transactions(_ t: TestRunner) {
        t.suite("Desk: conditional backgrounds: ordered option actions commit only after a complete successful projection") {
            let source = ##"""
            options { active = Toggle("Active") }
            widget { Text("A").size(40, 20).padding(3).rounded(4)
                .background(.glass, tint: "#FF0000", if: options.active)
                .onClick { options.active = true; copy(options.active) } }
            """##
            var runtime = try ProgramRuntime(program: program(compile(t, source)))
            let scene = try runtime.project(environment: environment(), measure: measure)
            t.check(try first(scene).glass == nil)
            do {
                _ = try runtime.clickWithEffects(at: SkinPoint(x: 20, y: 10), expectedGeneration: scene.generation,
                    environment: environment(), measure: { _, _, _ in throw Failure.fixture("measurement") })
                t.check(false, "a failed candidate must not return effects or advance options")
            } catch { t.check(true) }
            t.equal(runtime.generation, scene.generation); t.equal(runtime.optionsRevision, 0)
            t.equal(runtime.optionValues.values["active"], .boolean(false))
            let accepted = try runtime.clickWithEffects(at: SkinPoint(x: 20, y: 10), expectedGeneration: scene.generation,
                environment: environment(), measure: measure)
            guard let accepted else { throw Failure.fixture("accepted click") }
            t.equal(accepted.effects, [.copy("Yes")]); t.equal(runtime.optionsRevision, 1)
            t.equal(runtime.optionValues.values["active"], .boolean(true))
            t.equal(try first(accepted.scene).glass?.tint, red)
            t.equal(try first(accepted.scene).glass?.cornerRadius, 4)
            t.equal(accepted.scene.elements.map(\.frame), scene.elements.map(\.frame))
            t.check(try runtime.clickWithEffects(at: SkinPoint(x: 20, y: 10), expectedGeneration: scene.generation,
                environment: environment(), measure: measure) == nil, "stale input cannot repeat effects")
        }
    }

    private static func receipts(_ t: TestRunner) {
        t.suite("Desk: conditional backgrounds: inactive losing paint and tint receipts are validated independently") {
            let source = ##"""
            options { active = Toggle("Active") }
            style base { .background(.glass, tint: "#FF0000", if: cpu.usage > 50%) }
            style gate { .style(base, if: options.active) }
            widget { Text("A").style(gate, if: false).background("#0000FF", if: true) }
            """##
            let checked = deskCheck(source)
            var runtime = try ProgramRuntime(program: program(compile(t, source)))
            let scene = try runtime.project(environment: environment(), systemInput: ProgramSystemInput(cpuUsage: 75), measure: measure)
            t.equal(fills(scene), [blue]); t.check(try first(scene).glass == nil)
            t.equal(runtime.clockPrecision, nil)
            guard let root = checked.root, let original = checked.elements[root],
                  let paintIndex = original.facets["background"]?.firstIndex(where: { $0.level == 2 }),
                  let tintIndex = original.facets["background.tint"]?.firstIndex(where: { $0.level == 2 }),
                  let paint = original.facets["background"]?[paintIndex],
                  let tint = original.facets["background.tint"]?[tintIndex],
                  case .all(let chain)? = paint.condition else { throw Failure.fixture("background receipts") }
            t.equal(chain.count, 3); t.equal(tint.condition, paint.condition)
            var edits: [ElementFacts] = []
            var changed = original; changed.facets["background"]?[paintIndex].value = tint.value; edits.append(changed)
            changed = original; changed.facets["background.tint"]?[tintIndex].value = paint.value; edits.append(changed)
            changed = original; changed.facets["background.tint"]?[tintIndex].condition = nil; edits.append(changed)
            changed = original; changed.facets["background"]?[paintIndex].condition = .all(Array(chain.reversed())); edits.append(changed)
            changed = original; changed.facets["background"]?[paintIndex].position += 1_000; edits.append(changed)
            changed = original; changed.facets["background.tint"]?[tintIndex].fixedValue = ".red"; edits.append(changed)
            changed = original; changed.facets["background"]?.remove(at: paintIndex); edits.append(changed)
            changed = original; changed.facets["background.tint"]?.remove(at: tintIndex); edits.append(changed)
            for changed in edits {
                var elements = checked.elements; elements[root] = changed
                reject(t, facts(checked, elements: elements), kind: .invalidCheckedModel, "losing facets cannot change source, condition or order")
            }
            for id in [paint.value, tint.value] {
                var forged = checked; forged.canonicalNumericValues[id] = 999
                reject(t, forged, "static paint and tint cannot acquire numeric canonical receipts")
                forged = checked; forged.numericCoercions[id] = .percentAsFraction
                reject(t, forged, "static paint and tint cannot acquire numeric coercion receipts")
            }
            var symbols = checked.symbols; symbols.removeValue(forKey: paint.value)
            reject(t, facts(checked, symbols: symbols), "the losing glass still requires its checked Paint symbol")
            for condition in chain {
                guard case .expr(let id) = condition else { throw Failure.fixture("flat condition") }
                var types = checked.types; types[id] = SemType(type: .plainNumber)
                reject(t, facts(checked, types: types), "every application include and leaf condition requires checked Bool")
            }
            var catalog = DeskCatalog.current
            guard let index = catalog.modifiers.firstIndex(where: { $0.name == "background" }) else { throw Failure.fixture("catalog") }
            catalog.modifiers[index].acceptsCondition = false
            reject(t, checked, catalog: catalog, kind: .unsupported, "condition support must come from the exact checking catalog")
        }
    }

    private static func budgets(_ t: TestRunner) {
        t.suite("Desk: conditional backgrounds: tint cross products are bounded before constructing inactive selector trees") {
            var catalog = DeskCatalog.current; catalog.limits.maximumTokens = 64
            let small = deskCheck(#"widget { Text("A").background(.glass, tint: .red, if: false) }"#)
            t.check(small.diagnostics(.error).isEmpty, deskDescribe(small))
            t.check(Desk.compile(small, catalog: catalog).program != nil, "one tiny conditional background fits the shared budget")
            let repeated = String(repeating: #".background(.glass, tint: .red, if: false)"#, count: 48)
            let source = #"widget { Text("A")"# + repeated + ##".background("#0000FF") }"##
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            reject(t, checked, catalog: catalog, kind: .resourceLimit,
                "false paint and tint selectors share the bounded expression budget despite an own base")
        }
    }

    private static func unsupported(_ t: TestRunner) {
        t.suite("Desk: conditional backgrounds: unsupported leaves states and other conditional facets remain explicit") {
            for source in [
                #"widget { Text("A").background(system.accentColor, if: false) }"#,
                #"widget { Text("A").background(.glass, tint: system.accentColor, if: false) }"#,
                #"widget { Text("A").background(gradient(.red, .blue), if: false) }"#,
                #"widget { Text("A").background(image: "A.png", if: false) }"#,
                #"widget { Text("A").background(.glass, if: network.online) }"#,
                #"widget { Text("A").background(.glass(123), if: false) }"#,
                #"widget { Text("A").background(.red(123), if: false) }"#,
                #"widget { Text("A").background(.glass).rounded(3, if: false) }"#,
                #"widget { Text("A").hover { .background(.glass) } }"#,
                "style card { .background(.glass).font(12) }\nwidget { Text(\"A\").style(card, if: false) }"] {
                let checked = deskCheck(source)
                t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
                reject(t, checked, kind: .unsupported, source)
            }
            let direct = deskCheck(#"widget { Text("A").background(.blue, tint: .red, if: false) }"#)
            let result = Desk.compile(direct)
            t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty)
            t.equal(result.diagnostics, direct.diagnostics)
            let package = "style card { .background(.glass, if: system.dark) }"
            let folder = CheckedDeskPackage(package: deskMemoryPackage([
                "package.desk": package, "ConditionalBackgrounds.desk": #"widget { Text("A").style(card) }"#
            ]))
            guard let widget = folder.files[DeskFileID("ConditionalBackgrounds.desk")],
                  let shared = folder.files[DeskFileID("package.desk")] else { throw Failure.fixture("dynamic package") }
            t.check(widget.diagnostics(.error).isEmpty); t.check(shared.diagnostics(.error).isEmpty)
            let denied = Desk.compile(widget, package: shared)
            t.check(denied.program == nil && denied.elementRefs.isEmpty && denied.imageSources.isEmpty)
            t.equal(denied.issues.first?.kind, .unsupported)
        }
    }
}

func runDeskConditionalBackgroundCompilationTests(_ t: TestRunner) {
    DeskConditionalBackgroundCompilationTests.run(t)
}
