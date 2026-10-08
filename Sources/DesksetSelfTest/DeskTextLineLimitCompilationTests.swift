import Foundation
@testable import DesksetCore
@testable import DeskLanguage

enum DeskTextLineLimitCompilationTests {
    private enum Failure: Error { case fixture(String) }
    private struct Fixture {
        let checked: CheckedFile
        let package: CheckedFile?
        let result: DeskCompilationResult
        let program: WidgetProgram
    }

    private static func compile(_ t: TestRunner, _ source: String, package: String? = nil) throws -> Fixture {
        let checked: CheckedFile, shared: CheckedFile?
        if let package {
            let folder = CheckedDeskPackage(package: deskMemoryPackage([
                "package.desk": package, "Lines.desk": source
            ]))
            guard let widget = folder.files[DeskFileID("Lines.desk")],
                  let common = folder.files[DeskFileID("package.desk")] else { throw Failure.fixture("package") }
            checked = widget; shared = common
        } else { checked = deskCheck(source, file: "Lines.desk"); shared = nil }
        t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
        if let shared { t.check(shared.diagnostics(.error).isEmpty, deskDescribe(shared)) }
        let result = Desk.compile(checked, package: shared)
        t.equal(result.diagnostics, checked.diagnostics + (shared?.diagnostics ?? []))
        t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
        guard let program = result.program else { throw Failure.fixture("program: \(source)") }
        return Fixture(checked: checked, package: shared, result: result, program: program)
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

    private static func reject(_ t: TestRunner, _ checked: CheckedFile, catalog: DeskCatalog = .current,
                               kind: DeskCompilationIssue.Kind? = nil, _ reason: String) {
        let result = Desk.compile(checked, catalog: catalog)
        t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty, reason)
        if checked.diagnostics(.error).isEmpty { t.check(!result.issues.isEmpty, "\(reason): \(result.issues)") }
        else { t.check(result.issues.isEmpty, "checker errors prevent lowering without replacing their diagnostics") }
        if let kind { t.equal(result.issues.first?.kind, kind, reason) }
        t.equal(result.diagnostics, checked.diagnostics, reason)
    }

    private static func text(_ element: ProgramElement) throws -> ProgramText {
        guard case .text(let text) = element.content else { throw Failure.fixture("Text content") }; return text
    }

    static func run(_ t: TestRunner) {
        t.suite("Desk: text line limits compilation: ordinary positive whole literals and transparent parentheses compile") {
            for (value, expected) in [("1", 1), ("2", 2), ("1000", 1000), ("((2))", 2)] {
                let fixture = try compile(t, "widget { Text(\"Alpha beta gamma\").width(40).lines(\(value)) }")
                t.equal(fixture.result.elementRefs.count, 1)
                guard let root = fixture.checked.root else { throw Failure.fixture("root") }
                t.equal(fixture.result.elementRefs[fixture.program.root.id], root)
                t.equal(fixture.program.root.width, .fixed(40))
                t.equal(try text(fixture.program.root).maximumLines, expected)
            }
            let plain = try compile(t, #"widget { Text("Alpha beta gamma").width(40) }"#)
            t.check(try text(plain.program.root).maximumLines == nil)
            var measured: [Int?] = []
            var runtime = try ProgramRuntime(program: compile(t, #"widget { Text("Alpha beta gamma").width(40).lines(2) }"#).program)
            let scene = try runtime.project(environment: EnvironmentStamp(scale: 1, fontGeneration: 1,
                appearance: AppearanceStamp(value: .light, name: "line-limits"), imageGeneration: 0),
                measure: { _, style, _ in measured.append(style.maximumLines); return SkinSize(width: 40, height: 12) })
            t.check(!measured.isEmpty && measured.allSatisfy { $0 == 2 })
            guard case .text(let drawing)? = scene.elements.first?.items.first else { throw Failure.fixture("Text drawing") }
            t.equal(drawing.style.maximumLines, 2)
        }

        t.suite("Desk: text line limits compilation: nested repeated constant styles and own overrides preserve checked precedence") {
            let definitions = """
            style brief { .lines(1) }
            style detail { .lines(3) }
            style card { .style(brief).lines((2)) }
            """
            for (modifiers, expected) in [(".style(card)", 2), (".style(brief).style(detail).style(brief)", 1), (".style(card).lines(4)", 4)] {
                let fixture = try compile(t, definitions + "\nwidget { Text(\"Alpha beta gamma\").width(40)\(modifiers) }")
                t.equal(fixture.result.elementRefs.count, 1)
                t.equal(fixture.program.root.width, .fixed(40))
                guard let root = fixture.checked.root,
                      let candidates = fixture.checked.elements[root]?.facets["lines"] else { throw Failure.fixture("line candidates") }
                t.check(candidates.allSatisfy { $0.condition == nil })
                t.check(!candidates.isEmpty)
                t.equal(try text(fixture.program.root).maximumLines, expected)
            }
        }

        t.suite("Desk: text line limits compilation: package constants retain definition identities without inheriting lines") {
            let package = "style brief { .lines((2)) }"
            let source = #"widget { Column { Text("Alpha").style(brief); Text("Beta") }.style(brief) }"#
            let fixture = try compile(t, source, package: package)
            guard let shared = fixture.package,
                  case .column(_, _, let children) = fixture.program.root.content,
                  children.count == 2,
                  let first = fixture.result.elementRefs[children[0].id],
                  let second = fixture.result.elementRefs[children[1].id],
                  let firstFacts = fixture.checked.elements[first],
                  let secondFacts = fixture.checked.elements[second],
                  let candidate = firstFacts.facets["lines"]?.first else { throw Failure.fixture("package line candidates") }
            t.equal(fixture.result.elementRefs.count, 3)
            t.equal(candidate.value.treeVersion, shared.tree.version)
            t.check(shared.tree.resolve(candidate.value) != nil)
            t.check(!firstFacts.inherits.contains("lines"))
            t.check(secondFacts.facets["lines"] == nil && !secondFacts.inherits.contains("lines"))
            t.equal(try text(children[0]).maximumLines, 2)
            t.check(try text(children[1]).maximumLines == nil)
        }

        receipts(t)
        catalog(t)
        ranges(t)
        unsupported(t)
        budgets(t)
    }

    private static func receipts(_ t: TestRunner) {
        t.suite("Desk: text line limits compilation: all winning and losing literal receipts retain their source and occurrence") {
            let fixture = try compile(t, "style brief { .lines((2)) }\nwidget { Text(\"A\").style(brief).lines((4)) }")
            let checked = fixture.checked
            guard let root = checked.root, let original = checked.elements[root],
                  let candidates = original.facets["lines"], candidates.count == 2 else { throw Failure.fixture("line receipts") }
            for index in candidates.indices {
                let damage: [(String, (inout Candidate) -> Void)] = [
                    ("value", { $0.value = candidates[1 - index].value }),
                    ("fixed", { $0.fixedValue = "999" }),
                    ("condition", { $0.condition = .expr(candidates[index].value) }),
                    ("level", { $0.level = 1 }), ("hard", { $0.hard = false }),
                    ("position", { $0.position = 0 }),
                    ("origin", { $0.origin = candidates[1 - index].origin })]
                for (name, change) in damage {
                    var changed = original
                    var candidate = candidates[index]; change(&candidate)
                    changed.facets["lines"]?[index] = candidate
                    var elements = checked.elements; elements[root] = changed
                    reject(t, facts(checked, elements: elements), "\(name) candidate \(index)")
                }
                let identity = candidates[index].value
                guard var leaf = checked.tree.resolve(identity) else { throw Failure.fixture("line value") }
                var identities = [identity]
                while let paren = ParenExprSyntax(leaf) {
                    leaf = paren.value.node; identities.append(checked.tree.id(of: leaf))
                }
                for identity in identities {
                    var types = checked.types; types[identity] = SemType(type: .length)
                    reject(t, facts(checked, types: types), "every line wrapper and leaf keeps Plain type")
                    types = checked.types; types.removeValue(forKey: identity)
                    reject(t, facts(checked, types: types), "every line wrapper and leaf has a checked type")
                    var symbols = checked.symbols; symbols[identity] = .builtIn(.modifier("lines"))
                    reject(t, facts(checked, symbols: symbols), "numeric line syntax cannot acquire a symbol")
                    var forged = checked; forged.canonicalNumericValues[identity] = 999
                    reject(t, forged, "every line wrapper and leaf preserves its canonical receipt")
                    forged = checked; forged.numericCoercions[identity] = .percentAsFraction
                    reject(t, forged, "Plain lines cannot acquire fraction coercions")
                }
                let modifier: NodeID
                switch candidates[index].origin {
                case .own(let identity): modifier = identity
                case .style(_, let identity, _): modifier = identity
                }
                var symbols = checked.symbols; symbols.removeValue(forKey: modifier)
                reject(t, facts(checked, symbols: symbols), "the line modifier requires its checked built-in identity")
            }
            var changed = original; changed.facets["lines"]?.removeLast()
            var elements = checked.elements; elements[root] = changed
            reject(t, facts(checked, elements: elements), "an own override does not erase its losing source")
            changed = original; changed.inherits.insert("lines")
            elements = checked.elements; elements[root] = changed
            reject(t, facts(checked, elements: elements), kind: .invalidCheckedModel, "line limits never inherit")
        }
    }

    private static func catalog(_ t: TestRunner) {
        t.suite("Desk: text line limits compilation: exact modifier parameter and facet contracts are required") {
            let checked = deskCheck(#"widget { Text("A").lines(2) }"#)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            guard let modifier = DeskCatalog.current.modifiers.firstIndex(where: { $0.name == "lines" }),
                  let facet = DeskCatalog.current.facets.firstIndex(where: { $0.id == "lines" }) else { throw Failure.fixture("catalog") }
            let edits: [(inout DeskCatalog) -> Void] = [
                { $0.modifiers[modifier].inheritable = true },
                { $0.modifiers[modifier].acceptsCondition = false },
                { $0.modifiers[modifier].repeatable = .yes },
                { $0.modifiers[modifier].signatures[0].params[0].range = 0...1000 },
                { $0.modifiers[modifier].signatures[0].params[0].wholeNumber = false },
                { $0.modifiers[modifier].signatures[0].params[0].type = .length },
                { $0.modifiers[modifier].signatures[0].params[0].defaultValue = .source("1") },
                { $0.modifiers[modifier].signatures[0].params[0].role = .display },
                { $0.modifiers[modifier].signatures[0].params[0].source = .literal },
                { $0.modifiers[modifier].signatures[0].params[0].unit = "pt" },
                { $0.modifiers[modifier].signatures[0].params[0].sameAs = "other" },
                { $0.facets[facet].inheritable = true },
                { $0.facets[facet].valueType = .length },
                { $0.facets[facet].range = 1...999 }]
            for edit in edits {
                var catalog = DeskCatalog.current; edit(&catalog)
                reject(t, checked, catalog: catalog, kind: .unsupported, "the authored line count requires the checking catalog contract")
            }
        }
    }

    private static func ranges(_ t: TestRunner) {
        t.suite("Desk: text line limits compilation: original range whole number and duplicate errors prevent publication") {
            for (value, diagnostic) in [("0", "DK4014"), ("1001", "DK4014"), ("1.5", "DK4015")] {
                let checked = deskCheck("widget { Text(\"A\").lines(\(value)) }")
                t.check(checked.diagnostics(.error).contains { $0.id.rawValue == diagnostic }, deskDescribe(checked))
                reject(t, checked, "the original range and whole-number diagnostics remain authoritative")
            }
            for source in [#"widget { Text("A").lines(1).lines(2) }"#,
                           "style brief { .lines(1).lines(2) }\nwidget { Text(\"A\").style(brief) }"] {
                let checked = deskCheck(source)
                t.check(checked.diagnostics(.error).contains { $0.id.rawValue == "DK5001" }, deskDescribe(checked))
                reject(t, checked, "two unconditional copies in one source remain a checker error")
            }
        }
    }

    private static func unsupported(_ t: TestRunner) {
        t.suite("Desk: text line limits compilation: dynamic conditional state and Label sources remain explicit boundaries") {
            for source in [
                #"widget { Text("A").lines(cpu.coreCount) }"#,
                #"widget { variable count = 2; Text("A").lines(count) }"#,
                "options { count = Stepper(\"Count\", min: 1, max: 3) }\nwidget { Text(\"A\").lines(options.count) }",
                #"widget { Text("A").lines(1 + 1) }"#,
                #"widget { Text("A").lines(((1 + 1))) }"#,
                "style brief { .lines((1 + 1)) }\nwidget { Text(\"A\").style(brief).lines(4) }",
                #"widget { Text("A").lines(2, if: false) }"#,
                #"widget { Text("A").hover { .lines(2) } }"#,
                #"widget { Text("A").pressed { .lines(2) } }"#,
                "style brief { .lines(2, if: false) }\nwidget { Text(\"A\").style(brief) }",
                "style brief { .lines(2) }\nwidget { Text(\"A\").style(brief, if: false) }",
                "style brief { .lines(cpu.coreCount) }\nwidget { Text(\"A\").style(brief).lines(4) }",
                #"widget { Label("A", icon: "wifi").lines(2) }"#] {
                let checked = deskCheck(source)
                t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
                reject(t, checked, kind: .unsupported, source)
            }
        }
    }

    private static func budgets(_ t: TestRunner) {
        t.suite("Desk: text line limits compilation: repeated losing constant styles share the existing expansion budget") {
            var catalog = DeskCatalog.current; catalog.limits.maximumTokens = 32
            let definition = "style brief { .lines(2) }\n"
            let small = deskCheck(definition + #"widget { Text("A").style(brief) }"#)
            t.check(small.diagnostics(.error).isEmpty, deskDescribe(small))
            t.check(Desk.compile(small, catalog: catalog).program != nil)
            let checked = deskCheck(definition + #"widget { Text("A")"# + String(repeating: ".style(brief)", count: 48) + ".lines(4) }")
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            reject(t, checked, catalog: catalog, kind: .resourceLimit,
                "the own winner does not exempt repeated losing sources from the shared style budget")
        }
    }
}

func runDeskTextLineLimitCompilationTests(_ t: TestRunner) {
    DeskTextLineLimitCompilationTests.run(t)
}
