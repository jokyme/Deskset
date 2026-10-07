import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum BindingFixtureFailure: Error, Equatable { case program, measurement, assignment }

private struct BindingAssignmentTrace: ProgramAssignmentTarget {
    enum Event: Equatable {
        case resolve(ProgramExpression), write(Int, ProgramScalar)
    }
    var events: [Event] = []
    var values: [Int: ProgramScalar] = [:]
    var failResolve = false
    var failWrite = false

    mutating func resolveAssignmentValue(_ expression: ProgramExpression) throws -> ProgramScalar {
        events.append(.resolve(expression))
        if failResolve { throw BindingFixtureFailure.assignment }
        switch expression {
        case .string(let value): return .string(value)
        case .boolean(let value): return .boolean(value)
        default: throw ProgramRuntimeError.invalidExpression
        }
    }

    mutating func setProgramVariable(_ value: ProgramScalar, at declaration: Int) throws {
        events.append(.write(declaration, value))
        if failWrite { throw BindingFixtureFailure.assignment }
        values[declaration] = value
    }
}

private func bindingEnvironment(_ dark: Bool) -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1,
                     appearance: AppearanceStamp(value: dark ? .dark : .light, name: dark ? "dark" : "light"), imageGeneration: 0)
}

private func bindingText(_ value: ProgramExpression, hidden: Bool = false) -> ProgramElement {
    ProgramElement(id: ElementID(name: "text", index: 0), content: .text(ProgramText(value: value)), hidden: hidden)
}

private func bindingStrings(_ scene: WidgetScene) -> [String] {
    scene.drawingItems.compactMap { if case .text(let value) = $0 { return value.text }; return nil }
}

private func bindingMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    text.isEmpty ? SkinSize() : SkinSize(width: 12, height: 18)
}

private func bindingFailure(_ t: TestRunner, _ expected: ProgramRuntimeError, _ body: () throws -> Void) {
    do { try body(); t.check(false, "expected \(expected)") }
    catch { t.equal(error as? ProgramRuntimeError, expected) }
}

private func checkedBindingProgram(_ t: TestRunner, _ source: String, catalog: DeskCatalog = .current) throws -> WidgetProgram {
    let checked = deskCheck(source, context: CheckContext(catalog: catalog))
    let result = Desk.compile(checked, catalog: catalog)
    t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
    t.check(result.issues.isEmpty, "\(result.issues)")
    guard let program = result.program else { throw BindingFixtureFailure.program }
    return program
}

func runProgramBindingTests(_ t: TestRunner) {
    runProgramUnitTests(t)
    runDeskUnitTests(t)
    runProgramNumericTests(t)
    runProgramFontSizeTests(t)
    runProgramSystemDataTests(t)
    runProgramClickEffectTests(t)
    t.suite("Program: bindings: initialized variables persist while computed follows appearance") {
        let declarations = [ProgramDeclaration(name: "openedDark", kind: .variable, initial: .appearanceDark),
                            ProgramDeclaration(name: "caption", kind: .computed,
                                               initial: .conditional(.equal(.declaration(0), .appearanceDark),
                                                                     then: .string("起始😀"), otherwise: .string("外观已变")))]
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Appearance", root: bindingText(.declaration(1)), declarations: declarations))
        let first = try runtime.project(environment: bindingEnvironment(true), measure: bindingMeasure)
        let changed = try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure)
        let restored = try runtime.project(environment: bindingEnvironment(true), measure: bindingMeasure)
        t.equal(bindingStrings(first), ["起始😀"])
        t.equal(bindingStrings(changed), ["外观已变"])
        t.equal(bindingStrings(restored), ["起始😀"])
        t.equal([first.generation, changed.generation, restored.generation], [1, 2, 3])
        t.equal(first.elements[0].id, changed.elements[0].id)
        t.equal(first.size, SkinSize(width: 12, height: 18))
        t.equal(first.elements[0].frame, changed.elements[0].frame)
        t.equal(first.drawingItems.count, 1)
    }

    t.suite("Program: bindings: declaration order forward computed and boolean choices are deterministic") {
        let declarations = [ProgramDeclaration(name: "first", kind: .variable, initial: .string("甲😀")),
                            ProgramDeclaration(name: "second", kind: .variable, initial: .declaration(2)),
                            ProgramDeclaration(name: "forward", kind: .computed, initial: .declaration(0))]
        let condition = ProgramExpression.and(.not(.boolean(false)), .or(.boolean(false), .notEqual(.string("A"), .string("B"))))
        let value = ProgramExpression.conditional(condition, then: .declaration(1), otherwise: .string("wrong"))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Order", root: bindingText(value), declarations: declarations))
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["甲😀"])
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(true), measure: bindingMeasure)), ["甲😀"])
        var hidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden", root: bindingText(.declaration(1), hidden: true), declarations: declarations))
        var measured: [String] = []
        let hiddenScene = try hidden.project(environment: bindingEnvironment(false)) { text, _, _ in
            measured.append(text); return SkinSize(width: 12, height: 18)
        }
        t.equal(measured, ["甲😀"])
        t.check(hiddenScene.drawingItems.isEmpty)
        t.equal(hiddenScene.elements[0].visibility, .hiddenKeepsSpace)
        t.equal(hiddenScene.size, SkinSize(width: 12, height: 18))
        var empty = try ProgramRuntime(program: WidgetProgram(name: "Empty", root: bindingText(.conditional(.boolean(true), then: .string(""), otherwise: .string("unused")))))
        let emptyScene = try empty.project(environment: bindingEnvironment(false), measure: bindingMeasure)
        t.equal(bindingStrings(emptyScene), [""])
        t.equal(emptyScene.size, SkinSize())
    }

    t.suite("Program: bindings: failed startup or measurement commits no partial state") {
        let declarations = [ProgramDeclaration(name: "openedDark", kind: .variable, initial: .appearanceDark)]
        let value = ProgramExpression.conditional(.declaration(0), then: .string("dark"), otherwise: .string("light"))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Transaction", root: bindingText(value), declarations: declarations))
        t.throwsError {
            _ = try runtime.project(environment: bindingEnvironment(true)) { _, _, _ in throw BindingFixtureFailure.measurement }
        }
        t.equal(runtime.generation, 0)
        let first = try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure)
        t.equal(bindingStrings(first), ["light"], "failed dark startup did not freeze a variable")
        bindingFailure(t, .invalidMeasurement(ElementID(name: "text", index: 0))) {
            _ = try runtime.project(environment: bindingEnvironment(true)) { _, _, _ in SkinSize(width: .nan, height: 18) }
        }
        t.equal(runtime.generation, 1)
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(true), measure: bindingMeasure)), ["light"])
        t.equal(runtime.generation, 2)
        let forward = [ProgramDeclaration(name: "first", kind: .variable, initial: .declaration(1)),
                       ProgramDeclaration(name: "later", kind: .variable, initial: .string("later"))]
        var unfinished = try ProgramRuntime(program: WidgetProgram(name: "Uninitialized", root: bindingText(.declaration(0)), declarations: forward))
        for dark in [false, true] {
            bindingFailure(t, .uninitializedDeclaration(1)) { _ = try unfinished.project(environment: bindingEnvironment(dark), measure: bindingMeasure) }
            t.equal(unfinished.generation, 0)
        }
    }

    t.suite("Program: bindings: direct producers reject invalid identities cycles and branch types") {
        for index in [-1, Int.max] {
            bindingFailure(t, .invalidDeclaration(index)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Bad slot", root: bindingText(.declaration(index)))) }
        }
        for expression in [ProgramExpression.boolean(false), .not(.string("A")),
                           .equal(.boolean(true), .string("A")),
                           .conditional(.boolean(true), then: .string("A"), otherwise: .boolean(false))] {
            bindingFailure(t, .invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Bad type", root: bindingText(expression))) }
        }
        let cycles = [ProgramDeclaration(name: "a", kind: .computed, initial: .declaration(1)),
                      ProgramDeclaration(name: "b", kind: .computed, initial: .declaration(0))]
        bindingFailure(t, .cyclicDeclaration(0)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Cycle", root: bindingText(.string("A")), declarations: cycles)) }
        let mixed = [ProgramDeclaration(name: "a", kind: .variable, initial: .declaration(1)),
                     ProgramDeclaration(name: "b", kind: .computed, initial: .declaration(0))]
        bindingFailure(t, .cyclicDeclaration(0)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Mixed cycle", root: bindingText(.string("A")), declarations: mixed)) }
        for names in [["same", "same"], [""]] {
            let invalid = names.map { ProgramDeclaration(name: $0, kind: .computed, initial: .string("A")) }
            bindingFailure(t, .invalidDeclaration(names.count - 1)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Names", root: bindingText(.string("A")), declarations: invalid)) }
        }
    }

    t.suite("Program: bindings: expression reference depth count and text bounds are guarded") {
        let chain = (0..<127).map { ProgramDeclaration(name: "c\($0)", kind: .computed, initial: $0 == 0 ? .string("end") : .declaration($0 - 1)) }
        var accepted = try ProgramRuntime(program: WidgetProgram(name: "128 deep", root: bindingText(.declaration(126)), declarations: chain))
        t.equal(bindingStrings(try accepted.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["end"])
        let deeper = chain + [ProgramDeclaration(name: "c127", kind: .computed, initial: .declaration(126))]
        bindingFailure(t, .expressionDepth) { _ = try ProgramRuntime(program: WidgetProgram(name: "129 deep", root: bindingText(.declaration(127)), declarations: deeper)) }
        let many = (0..<ProgramLimits.maximumExpressions - 1).map { ProgramDeclaration(name: "d\($0)", kind: .computed, initial: .boolean(true)) }
        var bounded = try ProgramRuntime(program: WidgetProgram(name: "5000 nodes", root: bindingText(.string("A")), declarations: many))
        t.equal(bindingStrings(try bounded.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["A"])
        let extra = many + [ProgramDeclaration(name: "extra", kind: .computed, initial: .boolean(true))]
        bindingFailure(t, .expressionLimit) { _ = try ProgramRuntime(program: WidgetProgram(name: "5001 nodes", root: bindingText(.string("A")), declarations: extra)) }
        let maximum = String(repeating: "x", count: ProgramLimits.maximumTextLength)
        var long = try ProgramRuntime(program: WidgetProgram(name: "Text bound", root: bindingText(.string(maximum))))
        t.equal(bindingStrings(try long.project(environment: bindingEnvironment(false), measure: bindingMeasure)), [maximum])
        bindingFailure(t, .invalidText(ElementID(name: "text", index: 0))) { _ = try ProgramRuntime(program: WidgetProgram(name: "Long", root: bindingText(.string(maximum + "x")))) }
    }

    t.suite("Desk: bindings: checked state and appearance expressions produce real shared scenes") {
        let source = "\u{FEFF}" + #"widget { variable heading = "深色😀"; variable startedDark = system.dark; computed caption = system.dark ? heading : "浅色😀"; computed phase = startedDark == system.dark ? "起始外观" : "外观已变"; Column(align: .left) { Text(caption).font(20); Text(phase).font(20) } }"# + "\r\n"
        let program = try checkedBindingProgram(t, source)
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: bindingEnvironment(true), measure: bindingMeasure)
        let second = try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure)
        t.equal(bindingStrings(first), ["深色😀", "起始外观"])
        t.equal(bindingStrings(second), ["浅色😀", "外观已变"])
        t.equal(first.size, SkinSize(width: 12, height: 44))
        t.equal(first.elements.map(\.id.index), [0, 1, 2])
        t.equal(first.elements[2].frame, SkinRect(x: 0, y: 26, width: 12, height: 18))
        for item in first.drawingItems { if case .text(let value) = item { t.close(TextStyle.pixelSize(points: value.style.fontSize), 20) } }
        let forward = try checkedBindingProgram(t, #"widget { variable first = "甲😀"; variable second = forward; computed forward = first; Text(second) }"#)
        var order = try ProgramRuntime(program: forward)
        t.equal(bindingStrings(try order.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["甲😀"])
        let logic = try checkedBindingProgram(t, #"widget { variable flag = true; computed caption = not false and (flag or false) and "A" != "B" ? "yes" : "no"; Text(caption) }"#)
        var boolean = try ProgramRuntime(program: logic)
        t.equal(bindingStrings(try boolean.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["yes"])
    }

    t.suite("Desk: bindings: unsupported data actions persistence and formatting retain source issues") {
        let percent = try checkedBindingProgram(t, #"widget { Text(1%) }"#)
        var runtime = try ProgramRuntime(program: percent)
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["1"])
        let cases = [#"widget { variable x = "A"; Text(x).onWake { x = "B" } }"#,
                     #"widget { variable x = false; Text("A").onDoubleClick { x = true } }"#,
                     #"widget { saved x = "A"; Text(x) }"#,
                     #"widget { Text(true) }"#, #"widget { Text(1°C) }"#,
                     #"widget { variable x = "A"; Text("{x, missing: "–"}") }"#,
                     #"widget { Text(system.name) }"#,
                     #"widget { variable x = true; Text("A").color(.dim, if: x) }"#]
        for source in cases {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil && !result.issues.isEmpty, source)
            t.equal(result.issues.first?.kind, .unsupported)
            t.equal(result.diagnostics, checked.diagnostics)
            if let issue = result.issues.first {
                t.equal(issue.file, checked.tree.file)
                t.check(issue.range.lowerBound >= 0 && issue.range.upperBound <= source.utf8.count && !issue.range.isEmpty)
            }
        }
    }

    t.suite("Desk: bindings: checked scopes catalog lowering and reparsing cannot change slot identity") {
        let source = #"widget { variable seed = "A"; computed caption = system.dark ? seed : "B"; Text(caption) }"#
        let first = try checkedBindingProgram(t, source)
        let reparsed = try checkedBindingProgram(t, "// new bytes and tree version\n" + source)
        t.equal(first, reparsed)
        let invalid = deskCheck(#"widget { variable a = b; variable b = "B"; Text(a) }"#)
        let rejected = Desk.compile(invalid)
        t.check(!invalid.diagnostics(.error).isEmpty)
        t.check(rejected.program == nil && rejected.issues.isEmpty)
        t.equal(rejected.diagnostics, invalid.diagnostics)
        let loop = deskCheck(#"widget { variable seed = "A"; for seed in ["B"] { Text(seed) } }"#)
        t.check(Desk.compile(loop).program == nil, "a loop local cannot become a global program slot")
        var catalog = DeskCatalog.current
        let namespace = catalog.namespaces.firstIndex { $0.name == "system" }!
        let member = catalog.namespaces[namespace].members.firstIndex { $0.name == "dark" }!
        catalog.namespaces[namespace].members[member].lowering = .derived("different kernel")
        let checked = deskCheck(source, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        let wrongKernel = Desk.compile(checked, catalog: catalog)
        t.check(wrongKernel.program == nil)
        t.equal(wrongKernel.issues.first?.kind, .unsupported)
    }

    t.suite("Desk: bindings: valid long computed chains report the shared resource boundary") {
        let declarations = (0..<128).map { "computed c\($0) = " + ($0 == 0 ? "\"end\"" : "c\($0 - 1)") }.joined(separator: "; ")
        let source = "widget { " + declarations + "; Text(c127) }"
        let checked = deskCheck(source)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        let result = Desk.compile(checked)
        t.check(result.program == nil)
        t.equal(result.issues.first?.kind, .resourceLimit)
        t.equal(result.issues.first?.file, checked.tree.file)
    }

    t.suite("Program: onLoad: the shared executor borrows typed state and propagates failures synchronously") {
        let assignment = ProgramAssignment(declaration: 2, value: .string("甲😀"))
        var target = BindingAssignmentTrace()
        try ActionExecutor.perform(assignment, on: &target)
        try ActionExecutor.perform(ProgramAssignment(declaration: 0, value: .boolean(true)), on: &target)
        t.equal(target.events, [.resolve(.string("甲😀")), .write(2, .string("甲😀")),
                                .resolve(.boolean(true)), .write(0, .boolean(true))])
        t.equal(target.values, [2: .string("甲😀"), 0: .boolean(true)])
        for resolving in [true, false] {
            var failed = BindingAssignmentTrace(failResolve: resolving, failWrite: !resolving)
            t.throwsError { try ActionExecutor.perform(assignment, on: &failed) }
            t.equal(failed.events, resolving ? [.resolve(.string("甲😀"))] : [.resolve(.string("甲😀")), .write(2, .string("甲😀"))])
            t.check(failed.values.isEmpty)
        }
    }

    t.suite("Program: onLoad: ordered assignments invalidate pulled computed values and commit once") {
        let declarations = [ProgramDeclaration(name: "flag", kind: .variable, initial: .boolean(false)),
                            ProgramDeclaration(name: "caption", kind: .computed,
                                               initial: .conditional(.declaration(0), then: .string("启用😀"), otherwise: .string("暂停😀"))),
                            ProgramDeclaration(name: "before", kind: .variable, initial: .string("unset")),
                            ProgramDeclaration(name: "after", kind: .variable, initial: .string("unset"))]
        let children = (1...3).map { ProgramElement(id: ElementID(name: "t\($0)", index: $0), content: .text(ProgramText(value: .declaration($0)))) }
        let root = ProgramElement(id: ElementID(name: "root", index: 0), content: .column(spacing: 0, align: .left, children: children))
        let actions = [ProgramAssignment(declaration: 2, value: .declaration(1)),
                       ProgramAssignment(declaration: 0, value: .not(.declaration(0))),
                       ProgramAssignment(declaration: 3, value: .declaration(1))]
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Startup", root: root, declarations: declarations, onLoad: actions))
        for dark in [false, true, false] {
            let scene = try runtime.project(environment: bindingEnvironment(dark), measure: bindingMeasure)
            t.equal(bindingStrings(scene), ["启用😀", "暂停😀", "启用😀"], "later statements see computed changes; another projection cannot toggle again")
        }
        t.equal(runtime.generation, 3)
        var hidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden startup", root: bindingText(.declaration(3), hidden: true), declarations: declarations, onLoad: actions))
        var measured: [String] = []
        let scene = try hidden.project(environment: bindingEnvironment(false)) { text, _, _ in
            measured.append(text); return SkinSize(width: 12, height: 18)
        }
        t.equal(measured, ["启用😀"])
        t.check(scene.drawingItems.isEmpty)
        t.equal(scene.elements[0].visibility, .hiddenKeepsSpace)
        t.equal(scene.size, SkinSize(width: 12, height: 18))
    }

    t.suite("Program: onLoad: failed startup and later measurement retain the previous complete transaction") {
        let declarations = [ProgramDeclaration(name: "flag", kind: .variable, initial: .appearanceDark)]
        let value = ProgramExpression.conditional(.declaration(0), then: .string("dark"), otherwise: .string("light"))
        let program = WidgetProgram(name: "Retry", root: bindingText(value), declarations: declarations,
                                    onLoad: [ProgramAssignment(declaration: 0, value: .not(.declaration(0)))])
        var runtime = try ProgramRuntime(program: program)
        t.throwsError { _ = try runtime.project(environment: bindingEnvironment(false)) { _, _, _ in throw BindingFixtureFailure.measurement } }
        t.equal(runtime.generation, 0)
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(true), measure: bindingMeasure)), ["light"], "failed startup kept neither initializers nor its assignment")
        bindingFailure(t, .invalidMeasurement(ElementID(name: "text", index: 0))) {
            _ = try runtime.project(environment: bindingEnvironment(false)) { _, _, _ in SkinSize(width: .nan, height: 18) }
        }
        t.equal(runtime.generation, 1)
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["light"])
        t.equal(runtime.generation, 2)
        var reopened = try ProgramRuntime(program: program)
        t.equal(bindingStrings(try reopened.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["dark"], "a new instance starts and assigns again")
    }

    t.suite("Program: onLoad: direct producers reject readonly targets wrong types and aggregate budgets") {
        let declarations = [ProgramDeclaration(name: "flag", kind: .variable, initial: .boolean(false)),
                            ProgramDeclaration(name: "caption", kind: .computed, initial: .string("A"))]
        func make(_ actions: [ProgramAssignment]) throws -> ProgramRuntime {
            try ProgramRuntime(program: WidgetProgram(name: "Validation", root: bindingText(.string("A")), declarations: declarations, onLoad: actions))
        }
        for index in [-1, Int.max] {
            bindingFailure(t, .invalidDeclaration(index)) { _ = try make([ProgramAssignment(declaration: index, value: .boolean(true))]) }
        }
        bindingFailure(t, .invalidAssignment(1)) { _ = try make([ProgramAssignment(declaration: 1, value: .string("B"))]) }
        bindingFailure(t, .invalidAssignment(0)) { _ = try make([ProgramAssignment(declaration: 0, value: .string("B"))]) }
        bindingFailure(t, .invalidExpression) { _ = try make([ProgramAssignment(declaration: 0, value: .not(.string("A")))]) }
        var deep = ProgramExpression.boolean(true)
        for _ in 0..<ProgramLimits.maximumExpressionDepth { deep = .not(deep) }
        bindingFailure(t, .expressionDepth) { _ = try make([ProgramAssignment(declaration: 0, value: deep)]) }
        let bounded = Array(repeating: ProgramAssignment(declaration: 0, value: .boolean(true)), count: ProgramLimits.maximumExpressions - 3)
        var accepted = try make(bounded) // Two initializer nodes + one Text node + one node per assignment.
        t.equal(bindingStrings(try accepted.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["A"])
        bindingFailure(t, .expressionLimit) { _ = try make(bounded + [ProgramAssignment(declaration: 0, value: .boolean(true))]) }
        bindingFailure(t, .expressionLimit) { _ = try make(Array(repeating: ProgramAssignment(declaration: 0, value: .boolean(true)), count: ProgramLimits.maximumExpressions + 1)) }
    }

    t.suite("Desk: onLoad: checked root assignments feed shared scenes and preserve original slot identity") {
        // The previous unsupported-onLoad literal is preserved as a real positive now that it has a consumer.
        let original = #"widget { variable x = "A"; Text(x).onLoad { x = "B" } }"#
        var simple = try ProgramRuntime(program: checkedBindingProgram(t, original))
        t.equal(bindingStrings(try simple.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["B"])
        let previousPreview = #"widget { variable state = false; Text("unsupported").onLoad { state = true } }"#
        var previewLiteral = try ProgramRuntime(program: checkedBindingProgram(t, previousPreview))
        t.equal(bindingStrings(try previewLiteral.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["unsupported"])
        let source = #"widget { variable flag = false; computed caption = flag ? "启用😀" : "暂停😀"; variable before = "unset"; variable after = "unset"; Column { Text(before); Text(after); Text(caption) }.onLoad { before = caption; flag = not flag; after = caption } }"#
        let program = try checkedBindingProgram(t, source)
        t.equal(program, try checkedBindingProgram(t, "// a different syntax version\n" + source))
        var runtime = try ProgramRuntime(program: program)
        for dark in [false, true] {
            t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(dark), measure: bindingMeasure)), ["暂停😀", "启用😀", "启用😀"])
        }
        let empty = try checkedBindingProgram(t, #"widget { Text("A").onLoad { } }"#)
        var noActions = try ProgramRuntime(program: empty)
        t.equal(bindingStrings(try noActions.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["A"])
    }

    t.suite("Desk: onLoad: child implicit root and other action bodies fail without dropping checked semantics") {
        let cases = [#"widget { variable x = "A"; Column { Text(x).onLoad { x = "B" } } }"#,
                     #"widget { variable x = "A"; Text(x).onLoad { x = "B" }; Text("second") }"#,
                     #"widget { variable x = false; Text("A").onWake { x = true } }"#,
                     #"widget { saved x = "A"; Text(x).onLoad { x = "B" } }"#,
                     #"widget { variable x = false; Text("A").onLoad { if x { x = false } } }"#,
                     #"widget { Text("A").name("details").onLoad { hide("details") } }"#]
        for source in cases {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil)
            t.equal(result.issues.first?.kind, .unsupported)
            t.equal(result.diagnostics, checked.diagnostics)
            if let issue = result.issues.first {
                t.equal(issue.file, checked.tree.file)
                t.check(!issue.range.isEmpty && issue.range.lowerBound >= 0 && issue.range.upperBound <= source.utf8.count)
            }
        }
        for source in [#"widget { computed x = "A"; Text(x).onLoad { x = "B" } }"#,
                       #"widget { variable x = false; Text("A").onLoad { x = "B" } }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(!checked.diagnostics(.error).isEmpty)
            t.check(result.program == nil && result.issues.isEmpty)
            t.equal(result.diagnostics, checked.diagnostics)
        }
    }

    t.suite("Desk: onLoad: compilation requires the checker's exact reaction and catalog timing contract") {
        let source = #"widget { variable x = "A"; Text(x).onLoad { x = "B" } }"#
        let checked = deskCheck(source)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        func withReactions(_ reactions: [ReactionFacts]) -> CheckedFile {
            var value = CheckedFile(tree: checked.tree, diagnostics: checked.diagnostics, symbols: checked.symbols,
                                    types: checked.types, elements: checked.elements, dataUses: checked.dataUses,
                                    dependencies: checked.dependencies, reactions: reactions, freeformOrders: checked.freeformOrders,
                                    stringTable: checked.stringTable, requirements: checked.requirements, root: checked.root)
            value.declarationTypes = checked.declarationTypes
            return value
        }
        guard let reaction = checked.reactions.first else { throw BindingFixtureFailure.program }
        var foreignElement = reaction
        foreignElement.element = checked.tree.id(of: checked.tree.rootNode)
        for reactions in [[], [reaction, reaction], [foreignElement]] {
            let result = Desk.compile(withReactions(reactions))
            t.check(result.program == nil)
            t.equal(result.issues.first?.kind, .invalidCheckedModel)
        }
        var catalog = DeskCatalog.current
        let index = catalog.modifiers.firstIndex { $0.name == "onLoad" }!
        catalog.modifiers[index].timing = .onWake
        let altered = deskCheck(source, context: CheckContext(catalog: catalog))
        t.check(altered.diagnostics(.error).isEmpty, deskDescribe(altered))
        let result = Desk.compile(altered, catalog: catalog)
        t.check(result.program == nil)
        t.equal(result.issues.first?.kind, .invalidCheckedModel)
    }


    t.suite("Program: clock: typed dates templates and zones use one immutable projection input") {
        let start = Date(timeIntervalSince1970: 1_790_586_059.25)
        let input = ProgramDateInput(instant: start, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"))
        let value = ProgramExpression.concatenate([.string("甲😀 "), .formatDate(.timeNow, .pattern("HH:mm:ss")), .string(" / "),
                                                  .formatDate(.dateIn(.timeNow, timeZone: "Asia/Tokyo"), .pattern("yyyy-MM-dd HH:mm:ss"))])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Clock", root: bindingText(value)))
        let scene = try runtime.project(environment: bindingEnvironment(false), dateInput: input, measure: bindingMeasure)
        t.equal(bindingStrings(scene), ["甲😀 09:00:59 / 2026-09-28 18:00:59"])
        t.equal(runtime.clockPrecision, .second)
        t.equal(runtime.generation, 1)
        let minute = ProgramExpression.formatDate(.timeNow, .pattern("HH:mm 's'"))
        var minuteRuntime = try ProgramRuntime(program: WidgetProgram(name: "Minute", root: bindingText(minute)))
        t.equal(bindingStrings(try minuteRuntime.project(environment: bindingEnvironment(false), dateInput: input, measure: bindingMeasure)), ["09:00 s"])
        t.equal(minuteRuntime.clockPrecision, .minute, "quoted s is literal text")
        var escaped = try ProgramRuntime(program: WidgetProgram(name: "Quoted", root: bindingText(.formatDate(.timeNow, .pattern("HH:mm '' 's'")))))
        t.equal(bindingStrings(try escaped.project(environment: bindingEnvironment(false), dateInput: input, measure: bindingMeasure)), ["09:00 ' s"])
        t.equal(escaped.clockPrecision, .minute, "a doubled quote is literal, not an unclosed quoting region")
        var weekday = try ProgramRuntime(program: WidgetProgram(name: "Date", root: bindingText(.formatDate(.timeNow, .preset(.weekday)))))
        t.equal(bindingStrings(try weekday.project(environment: bindingEnvironment(false), dateInput: input, measure: bindingMeasure)), ["Monday"])
        let chinese = ProgramDateInput(instant: start, timeZone: input.timeZone, locale: Locale(identifier: "zh_Hans_CN"))
        t.equal(bindingStrings(try weekday.project(environment: bindingEnvironment(false), dateInput: chinese, measure: bindingMeasure)), ["星期一"])
        let equal = ProgramExpression.equal(.timeNow, .dateIn(.timeNow, timeZone: "Asia/Tokyo"))
        var equality = try ProgramRuntime(program: WidgetProgram(name: "Equality", root: bindingText(.concatenate([equal]))))
        t.equal(bindingStrings(try equality.project(environment: bindingEnvironment(false), dateInput: chinese, measure: bindingMeasure)), ["是"], "a zone view is the same instant")
        t.equal(equality.clockPrecision, .second)
        t.close(try ProgramClockPrecision.second.delayToNextBoundary(after: start), 0.75)
        t.close(try ProgramClockPrecision.twoSeconds.delayToNextBoundary(after: start), 0.75)
        t.close(try ProgramClockPrecision.twoSeconds.delayToNextBoundary(after: start.addingTimeInterval(0.75)), 2)
        t.close(try ProgramClockPrecision.minute.delayToNextBoundary(after: start), 0.75)
        t.close(try ProgramClockPrecision.minute.delayToNextBoundary(after: start.addingTimeInterval(0.75)), 60)
    }

    t.suite("Program: clock: frozen variables computed dates and startup retain transactional demand") {
        let start = Date(timeIntervalSince1970: 1_790_586_059)
        func input(_ offset: Double) -> ProgramDateInput {
            ProgramDateInput(instant: start.addingTimeInterval(offset), timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"))
        }
        let declarations = [ProgramDeclaration(name: "opened", kind: .variable, initial: .timeNow),
                            ProgramDeclaration(name: "current", kind: .computed, initial: .timeNow)]
        let value = ProgramExpression.concatenate([.formatDate(.declaration(0), .pattern("HH:mm:ss")), .string("/"),
                                                  .formatDate(.declaration(1), .pattern("HH:mm:ss"))])
        let program = WidgetProgram(name: "Clock", root: bindingText(value), declarations: declarations,
                                    onLoad: [ProgramAssignment(declaration: 0, value: .timeNow)])
        var runtime = try ProgramRuntime(program: program)
        bindingFailure(t, .invalidMeasurement(ElementID(name: "text", index: 0))) {
            _ = try runtime.project(environment: bindingEnvironment(false), dateInput: input(0)) { _, _, _ in SkinSize(width: .nan, height: 1) }
        }
        t.equal(runtime.generation, 0); t.equal(runtime.clockPrecision, nil)
        let first = try runtime.project(environment: bindingEnvironment(false), dateInput: input(1), measure: bindingMeasure)
        t.equal(bindingStrings(first), ["09:01:00/09:01:00"], "failed startup did not freeze the earlier date")
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(true), dateInput: input(2), measure: bindingMeasure)), ["09:01:00/09:01:01"])
        t.equal(runtime.clockPrecision, .second)
        let generation = runtime.generation
        bindingFailure(t, .invalidDateInput) { _ = try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure) }
        t.equal(runtime.generation, generation); t.equal(runtime.clockPrecision, .second)
        var frozen = try ProgramRuntime(program: WidgetProgram(name: "Frozen", root: bindingText(.formatDate(.declaration(0), .pattern("HH:mm:ss"))), declarations: [declarations[0]]))
        _ = try frozen.project(environment: bindingEnvironment(false), dateInput: input(0), measure: bindingMeasure)
        t.equal(bindingStrings(try frozen.project(environment: bindingEnvironment(false), dateInput: input(61), measure: bindingMeasure)), ["09:00:59"])
        t.equal(frozen.clockPrecision, nil)
        let conditional = ProgramExpression.conditional(.appearanceDark, then: .formatDate(.timeNow, .pattern("ss")), otherwise: .string("fixed"))
        var lazy = try ProgramRuntime(program: WidgetProgram(name: "Lazy", root: bindingText(conditional)))
        _ = try lazy.project(environment: bindingEnvironment(false), dateInput: input(0), measure: bindingMeasure); t.equal(lazy.clockPrecision, nil)
        _ = try lazy.project(environment: bindingEnvironment(true), dateInput: input(0), measure: bindingMeasure); t.equal(lazy.clockPrecision, .second)
        var hidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden", root: bindingText(value, hidden: true), declarations: declarations))
        let hiddenScene = try hidden.project(environment: bindingEnvironment(false), dateInput: input(0), measure: bindingMeasure)
        t.equal(hidden.clockPrecision, nil); t.equal(hiddenScene.size, first.size)
        t.check(hiddenScene.drawingItems.isEmpty)
    }

    t.suite("Program: clock: invalid inputs formats zones and expansion fail before publication") {
        for expression: ProgramExpression in [.formatDate(.timeNow, .pattern("HH:mm:ss.SSS")),
                                               .formatDate(.timeNow, .pattern("HH:mm 'unclosed")),
                                               .formatDate(.timeNow, .pattern("not-a-format")),
                                               .dateIn(.timeNow, timeZone: "Not/AZone"),
                                               .formatDate(.boolean(true), .preset(.time)), .concatenate([.timeNow])] {
            bindingFailure(t, .invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid", root: bindingText(expression))) }
        }
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Clock", root: bindingText(.formatDate(.timeNow, .pattern("HH:mm:ss")))))
        for value in [Double.nan, .infinity, -.infinity] {
            let input = ProgramDateInput(instant: Date(timeIntervalSince1970: value), timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"))
            bindingFailure(t, .invalidDateInput) { _ = try runtime.project(environment: bindingEnvironment(false), dateInput: input, measure: bindingMeasure) }
            t.equal(runtime.generation, 0); t.equal(runtime.clockPrecision, nil)
        }
        var long = try ProgramRuntime(program: WidgetProgram(name: "Expansion", root: bindingText(.concatenate([.string(String(repeating: "a", count: ProgramLimits.maximumTextLength)), .string("😀")]))))
        bindingFailure(t, .invalidExpression) { _ = try long.project(environment: bindingEnvironment(false), measure: bindingMeasure) }
        t.equal(long.generation, 0)
        let declarations = [ProgramDeclaration(name: "d", kind: .variable, initial: .timeNow)]
        bindingFailure(t, .invalidAssignment(0)) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Wrong", root: bindingText(.string("x")), declarations: declarations,
                                                         onLoad: [ProgramAssignment(declaration: 0, value: .boolean(true))]))
        }
    }

    t.suite("Desk: clock: checked templates dates and real catalog defaults reach shared scenes") {
        let source = #"widget { variable opened = time.now; computed current = time.now; Text("{opened, format: "HH:mm:ss"}/{current.in("Asia/Tokyo"), format: "HH:mm:ss"}").onLoad { opened = time.now } }"#
        let program = try checkedBindingProgram(t, source)
        let input = ProgramDateInput(instant: Date(timeIntervalSince1970: 1_790_586_059), timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"))
        var runtime = try ProgramRuntime(program: program)
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), dateInput: input, measure: bindingMeasure)), ["09:00:59/18:00:59"])
        let next = ProgramDateInput(instant: input.instant.addingTimeInterval(1), timeZone: input.timeZone, locale: input.locale)
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), dateInput: next, measure: bindingMeasure)), ["09:00:59/18:01:00"])
        t.equal(runtime.clockPrecision, .second)
        let originalInterpolation = #"widget { variable x = "A"; Text("{x}") }"#
        var old = try ProgramRuntime(program: checkedBindingProgram(t, originalInterpolation))
        t.equal(bindingStrings(try old.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["A"], "the original unsupported literal now has real matching semantics")
        var catalog = DeskCatalog.current
        let ns = catalog.namespaces.firstIndex { $0.name == "time" }!
        catalog.namespaces[ns].members[0].defaultFormat = .pattern("yyyy-MM-dd")
        var defaults = try ProgramRuntime(program: checkedBindingProgram(t, "widget { Text(time.now) }", catalog: catalog))
        t.equal(bindingStrings(try defaults.project(environment: bindingEnvironment(false), dateInput: input, measure: bindingMeasure)), ["2026-09-28"])
        t.equal(defaults.clockPrecision, .minute)
        let escaped = #"widget { Text("{{甲😀}} {true} {time.now, format: "HH:mm 's'"}") }"#
        var text = try ProgramRuntime(program: checkedBindingProgram(t, escaped))
        t.equal(bindingStrings(try text.project(environment: bindingEnvironment(false), dateInput: input, measure: bindingMeasure)), ["{甲😀} Yes 09:00 s"])
    }

    runProgramClickTests(t)

    t.suite("Desk: clock: unsupported fields reactions and format semantics reject the complete program") {
        let sources = [#"widget { Text("{time.now, format: .relative}") }"#,
                       #"widget { Text("{time.now, format: "ss.SSS"}") }"#,
                       #"widget { Text("{time.now.hour}") }"#,
                       #"widget { variable zone = "UTC"; Text(time.now.in(zone)) }"#,
                       #"widget { Text("{time.now, missing: "–"}") }"#,
                       #"widget { Text("{time.now}").onWake { } }"#,
                       "info { permissions: [.music] }\n" + #"widget { Column { Text("{time.now}"); Text("{music.title}") } }"#]
        for source in sources {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil && !result.issues.isEmpty, source)
            t.equal(result.issues.first?.kind, .unsupported)
            t.equal(result.diagnostics, checked.diagnostics)
            t.equal(result.imageSources, [])
        }
        var catalog = DeskCatalog.current
        let ns = catalog.namespaces.firstIndex { $0.name == "time" }!
        catalog.namespaces[ns].members[0].cadence = .event
        let checked = deskCheck("widget { Text(time.now) }", context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)
    }
}

private func runProgramClickTests(_ t: TestRunner) {
    let point = SkinPoint(x: 6, y: 6)
    let environment = bindingEnvironment(false)
    let start = Date(timeIntervalSince1970: 1_790_586_059.25)
    func input(_ offset: Double = 0) -> ProgramDateInput {
        ProgramDateInput(instant: start.addingTimeInterval(offset), timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"))
    }
    t.suite("Program: click: ordered shared assignments publish variables hit map and demand atomically") {
        let declarations = [ProgramDeclaration(name: "flag", kind: .variable, initial: .boolean(false)),
                            ProgramDeclaration(name: "caption", kind: .computed, initial: .conditional(.declaration(0), then: .string("开😀"), otherwise: .string("关😀"))),
                            ProgramDeclaration(name: "before", kind: .variable, initial: .string("unset")),
                            ProgramDeclaration(name: "after", kind: .variable, initial: .string("unset")),
                            ProgramDeclaration(name: "stamp", kind: .variable, initial: .timeNow)]
        let value = ProgramExpression.concatenate([.declaration(2), .string("/"), .declaration(3), .string("/"),
                                                  .formatDate(.declaration(4), .pattern("HH:mm:ss"))])
        let actions = [ProgramAssignment(declaration: 2, value: .declaration(1)),
                       ProgramAssignment(declaration: 0, value: .not(.declaration(0))),
                       ProgramAssignment(declaration: 3, value: .declaration(1)),
                       ProgramAssignment(declaration: 4, value: .timeNow)]
        let root = ProgramElement(id: ElementID(name: "button", index: 0), content: .text(ProgramText(value: value)),
                                  width: .fixed(40), height: .fixed(30), onClick: actions)
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Click", root: root, declarations: declarations,
                                        onLoad: [ProgramAssignment(declaration: 0, value: .boolean(true))]))
        t.check(try runtime.click(at: point, expectedGeneration: 0, environment: environment, dateInput: input(), measure: bindingMeasure) == nil)
        let first = try runtime.project(environment: environment, dateInput: input(), measure: bindingMeasure)
        t.equal(bindingStrings(first), ["unset/unset/09:00:59"])
        guard let clicked = try runtime.click(at: point, expectedGeneration: first.generation, environment: environment,
                                              dateInput: input(1), measure: bindingMeasure) else { throw BindingFixtureFailure.program }
        t.equal(bindingStrings(clicked), ["开😀/关😀/09:01:00"])
        t.equal(clicked.generation, 2); t.equal(runtime.clockPrecision, nil, "a captured date does not request live ticks")
        t.equal(clicked.hitMap.entry(at: 6, 6, handling: .leftUp, images: nil)?.elementID, root.id)
        let held = try runtime.project(environment: environment, dateInput: input(10), measure: bindingMeasure)
        t.equal(bindingStrings(held), ["开😀/关😀/09:01:00"], "onLoad does not repeat after a click or a projection")
        let rejected = try runtime.click(at: point, expectedGeneration: clicked.generation, environment: environment, dateInput: input(), measure: bindingMeasure)
        t.check(rejected == nil); t.equal(runtime.generation, held.generation)
        for missed in [SkinPoint(x: -1, y: 6), SkinPoint(x: 40, y: 6), SkinPoint(x: .nan, y: 6)] {
            t.check(try runtime.click(at: missed, expectedGeneration: held.generation, environment: environment, dateInput: input(), measure: bindingMeasure) == nil)
        }
        guard let second = try runtime.click(at: point, expectedGeneration: held.generation, environment: environment,
                                             dateInput: input(11), measure: bindingMeasure) else { throw BindingFixtureFailure.program }
        t.equal(bindingStrings(second), ["关😀/开😀/09:01:10"])
    }

    t.suite("Program: click: failed action measurement and layout preserve the preceding complete transaction") {
        let id = ElementID(name: "clock", index: 0)
        let declarations = [ProgramDeclaration(name: "live", kind: .variable, initial: .boolean(true))]
        let value = ProgramExpression.conditional(.declaration(0), then: .formatDate(.timeNow, .pattern("HH:mm:ss")), otherwise: .string("Off"))
        let root = ProgramElement(id: id, content: .text(ProgramText(value: value)), onClick: [ProgramAssignment(declaration: 0, value: .boolean(false))])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Rollback", root: root, declarations: declarations))
        let first = try runtime.project(environment: environment, dateInput: input(), measure: bindingMeasure)
        t.equal(runtime.clockPrecision, .second)
        for size in [SkinSize(width: .nan, height: 10), SkinSize(width: -1, height: 10)] {
            bindingFailure(t, .invalidMeasurement(id)) {
                _ = try runtime.click(at: point, expectedGeneration: first.generation, environment: environment, dateInput: input()) { _, _, _ in size }
            }
            t.equal(runtime.generation, first.generation); t.equal(runtime.clockPrecision, .second)
        }
        do {
            _ = try runtime.click(at: point, expectedGeneration: first.generation, environment: environment, dateInput: input()) { _, _, _ in throw BindingFixtureFailure.measurement }
            t.check(false)
        } catch { t.equal(error as? BindingFixtureFailure, .measurement) }
        let retried = try runtime.project(environment: environment, dateInput: input(1), measure: bindingMeasure)
        t.equal(bindingStrings(retried), ["09:01:00"]); t.equal(runtime.clockPrecision, .second)
        guard let clicked = try runtime.click(at: point, expectedGeneration: retried.generation, environment: environment,
                                              dateInput: input(1), measure: bindingMeasure) else { throw BindingFixtureFailure.program }
        t.equal(bindingStrings(clicked), ["Off"]); t.equal(runtime.clockPrecision, nil)
        let stackID = ElementID(name: "stack", index: 2)
        let children = [ProgramElement(id: id, content: .text(ProgramText(value: .string("A")))),
                        ProgramElement(id: ElementID(name: "second", index: 1), content: .text(ProgramText(value: .string("B"))))]
        let stack = ProgramElement(id: stackID, content: .column(spacing: 0, align: .left, children: children),
                                   onClick: [ProgramAssignment(declaration: 0, value: .boolean(false))])
        var stacked = try ProgramRuntime(program: WidgetProgram(name: "Overflow", root: stack, declarations: declarations))
        let prior = try stacked.project(environment: environment, measure: bindingMeasure)
        bindingFailure(t, .layoutOverflow(stackID)) {
            _ = try stacked.click(at: point, expectedGeneration: prior.generation, environment: environment) { _, _, _ in
                SkinSize(width: 10, height: .greatestFiniteMagnitude)
            }
        }
        t.equal(stacked.generation, prior.generation)
        let bad = ProgramElement(id: id, content: .text(ProgramText(value: .string("A"))),
                                 onClick: [ProgramAssignment(declaration: 0, value: .dateIn(.timeNow, timeZone: "UTC"))])
        var dateRuntime = try ProgramRuntime(program: WidgetProgram(name: "Date failure", root: bad,
                                      declarations: [ProgramDeclaration(name: "stamp", kind: .variable, initial: .timeNow)]))
        let dated = try dateRuntime.project(environment: environment, dateInput: input(), measure: bindingMeasure)
        bindingFailure(t, .invalidDateInput) {
            _ = try dateRuntime.click(at: point, expectedGeneration: dated.generation, environment: environment, measure: bindingMeasure)
        }
        t.equal(dateRuntime.generation, dated.generation)
        for assignment in [ProgramAssignment(declaration: 1, value: .boolean(true)), ProgramAssignment(declaration: 0, value: .string("wrong"))] {
            let direct = ProgramElement(id: id, content: .text(ProgramText(value: .string("A"))), onClick: [assignment])
            bindingFailure(t, assignment.declaration == 1 ? .invalidDeclaration(1) : .invalidAssignment(0)) {
                _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid", root: direct, declarations: declarations))
            }
        }
    }

    t.suite("Program: click: innermost stable identities hidden ancestry and rounded boxes ignore painted alpha") {
        let parentID = ElementID(name: "same", index: 0), childID = ElementID(name: "same", index: 1)
        func box(_ id: ElementID, hidden: Bool = false, radius: ProgramCornerRadius? = nil, actions: [ProgramAssignment]? = []) -> ProgramElement {
            ProgramElement(id: id, content: .rectangle(fill: .literal(.clear)), width: .fixed(20), height: .fixed(20),
                           padding: SkinInsets(left: 4, top: 4, right: 4, bottom: 4), hidden: hidden, cornerRadius: radius, onClick: actions)
        }
        let root = ProgramElement(id: parentID, content: .column(spacing: 0, align: .left, children: [box(childID)]),
                                  padding: SkinInsets(left: 4, top: 4, right: 4, bottom: 4), onClick: [])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Nested", root: root))
        let scene = try runtime.project(environment: environment, measure: bindingMeasure)
        t.equal(scene.hitMap.entries.map(\.elementID), [childID, parentID])
        t.equal(scene.hitMap.entry(at: 6, 6, handling: .leftUp, images: nil)?.elementID, childID)
        t.equal(scene.hitMap.entry(at: 1, 1, handling: .leftUp, images: nil)?.elementID, parentID)
        t.equal(scene.hitMap.entry(at: 6, 6, handling: .leftUp, images: nil)?.action(.leftUp), .caught, "an empty handler consumes without executable text")
        t.check(try runtime.click(at: point, expectedGeneration: scene.generation, environment: environment, measure: bindingMeasure) != nil)
        var rounded = try ProgramRuntime(program: WidgetProgram(name: "Rounded", root: box(parentID, radius: .full)))
        let round = try rounded.project(environment: environment, measure: bindingMeasure)
        t.check(round.hitMap.entry(at: 0.1, 0.1, handling: .leftUp, images: nil) == nil)
        t.equal(round.hitMap.entry(at: 1, 10, handling: .leftUp, images: nil)?.elementID, parentID, "padding is inside the rounded box")
        var circle = try ProgramRuntime(program: WidgetProgram(name: "Circle box", root: ProgramElement(id: childID,
                            content: .shape(kind: .circle, fill: .literal(.clear)), width: .fixed(20), height: .fixed(20), onClick: [])))
        let circular = try circle.project(environment: environment, measure: bindingMeasure)
        t.equal(circular.hitMap.entry(at: 0.1, 0.1, handling: .leftUp, images: nil)?.elementID, childID, "Circle's box is independent of its curve ink")
        for hidden in [box(parentID, hidden: true), ProgramElement(id: parentID,
                       content: .column(spacing: 0, align: .left, children: [box(childID)]), hidden: true, onClick: [])] {
            var hiddenRuntime = try ProgramRuntime(program: WidgetProgram(name: "Hidden", root: hidden))
            let result = try hiddenRuntime.project(environment: environment, measure: bindingMeasure)
            t.equal(result.hitMap.entries.count, 0)
            t.check(try hiddenRuntime.click(at: point, expectedGeneration: result.generation, environment: environment, measure: bindingMeasure) == nil)
        }
    }

    t.suite("Desk: click: actual checked leaf handlers preserve assignments and stable identities across reparsing") {
        let previous = #"widget { variable x = false; Text("A").onClick { x = true } }"#
        let source = #"widget { variable flag = false; computed caption = flag ? "开😀" : "关😀"; Text(caption).size(40, 30).onClick { flag = not flag } }"#
        for literal in [previous, source] {
            let program = try checkedBindingProgram(t, literal)
            var runtime = try ProgramRuntime(program: program)
            let first = try runtime.project(environment: environment, measure: bindingMeasure)
            guard let second = try runtime.click(at: point, expectedGeneration: first.generation, environment: environment, measure: bindingMeasure) else { throw BindingFixtureFailure.program }
            t.equal(bindingStrings(second), literal == previous ? ["A"] : ["开😀"])
            t.equal(program, try checkedBindingProgram(t, literal), "NodeID tree versions are not element identities")
        }
        for leaf in ["Rectangle", "Circle", "Ellipse", "Capsule"] {
            let program = try checkedBindingProgram(t, "widget { variable flag = false; \(leaf)().size(40, 30).onClick { flag = true } }")
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: environment, measure: bindingMeasure)
            t.equal(scene.hitMap.entries.count, 1)
            t.check(try runtime.click(at: point, expectedGeneration: scene.generation, environment: environment, measure: bindingMeasure) != nil)
        }
    }

    t.suite("Desk: click: unsupported actions events roles and foreign catalog identities reject the whole source") {
        let sources = [#"widget { variable x = false; Column { Text("A") }.onClick { x = true } }"#,
                       #"widget { variable x = false; Text("A").onDoubleClick { x = true } }"#,
                       #"widget { variable x = false; Text("A").onClick { if x { x = false } } }"#,
                       #"widget { Text("A").onClick { log("A") } }"#,
                       #"widget { variable x = "A"; Text(x).onClick { x = "{event.x}" } }"#,
                       #"widget { Text("A").onClick { widget.openOptions() } }"#]
        for source in sources {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil); t.equal(result.issues.first?.kind, .unsupported)
            t.equal(result.diagnostics, checked.diagnostics)
            t.equal(result.imageSources, [])
        }
        let source = #"widget { variable flag = false; Text("A").onClick { flag = true } }"#
        let checked = deskCheck(source)
        guard let id = checked.symbols.first(where: { $0.value == .builtIn(.modifier("onClick")) })?.key else { throw BindingFixtureFailure.program }
        var symbols = checked.symbols
        symbols.removeValue(forKey: id)
        var damaged = CheckedFile(tree: checked.tree, diagnostics: checked.diagnostics, symbols: symbols, types: checked.types,
                                  elements: checked.elements, dataUses: checked.dataUses, dependencies: checked.dependencies,
                                  reactions: checked.reactions, freeformOrders: checked.freeformOrders, stringTable: checked.stringTable,
                                  requirements: checked.requirements, root: checked.root)
        damaged.declarationTypes = checked.declarationTypes
        t.equal(Desk.compile(damaged).issues.first?.kind, .invalidCheckedModel)
        var catalog = DeskCatalog.current
        let index = catalog.modifiers.firstIndex { $0.name == "onClick" }!
        catalog.modifiers[index].event?.runtimeEvent = "leftMouseDown"
        let altered = deskCheck(source, context: CheckContext(catalog: catalog))
        t.check(altered.diagnostics(.error).isEmpty, deskDescribe(altered))
        t.equal(Desk.compile(altered, catalog: catalog).issues.first?.kind, .invalidCheckedModel)
    }
}


private func runProgramNumericTests(_ t: TestRunner) {
    let utc = TimeZone(identifier: "UTC")!
    func input(_ locale: String) -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: utc, locale: Locale(identifier: locale))
    }
    func scalar(_ expression: ProgramExpression, dateInput: ProgramDateInput? = nil) throws -> ProgramScalar {
        var value = ProgramExpressionEvaluation(declarations: [], dark: false, variables: nil, dateInput: dateInput)
        return try value.resolveAssignmentValue(expression)
    }
    let unavailable = ProgramExpression.divide(.number(1), .number(0))
    let unknown = ProgramExpression.less(unavailable, .number(1))

    t.suite("Program: numeric: finite arithmetic yields typed missing while invalid producers are rejected") {
        let cases: [(ProgramExpression, ProgramScalar)] = [
            (.add(.number(3), .number(0.5)), .number(3.5)), (.subtract(.number(3), .number(5)), .number(-2)),
            (.multiply(.number(-3), .number(2)), .number(-6)), (.divide(.number(7), .number(2)), .number(3.5)),
            (.remainder(.number(-7), .number(3)), .number(-1)), (.negate(.number(4)), .number(-4)),
            (unavailable, .missing(.number)), (.divide(.number(0), .number(0)), .missing(.number)),
            (.remainder(.number(1), .number(0)), .missing(.number)),
            (.multiply(.number(.greatestFiniteMagnitude), .number(2)), .missing(.number)),
            (.add(unavailable, .number(2)), .missing(.number)), (.equal(unavailable, unavailable), .missing(.boolean)),
            (.less(.number(-2), .number(0)), .boolean(true)), (.lessOrEqual(.number(1), .number(1)), .boolean(true)),
            (.greater(.number(1), .number(2)), .boolean(false)), (.greaterOrEqual(.number(2), .number(2)), .boolean(true)),
            (.isMissing(unavailable), .boolean(true)), (.ifMissing(unavailable, .number(9)), .number(9)),
        ]
        for (expression, expected) in cases {
            t.equal(try scalar(expression), expected)
            let shown = expected.type == .boolean ? ProgramExpression.concatenate([expression]) : .formatNumber(expression, ProgramNumberFormat())
            _ = try ProgramRuntime(program: WidgetProgram(name: "Numeric", root: bindingText(shown)))
        }
        for value in [Double.nan, .infinity, -.infinity] {
            bindingFailure(t, .invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Nonfinite literal", root: bindingText(.formatNumber(.number(value), ProgramNumberFormat())))) }
        }
        for expression in [ProgramExpression.add(.string("1"), .number(1)), .formatNumber(.boolean(true), ProgramNumberFormat()),
                           .ifMissing(unavailable, .string("9")), .conditional(.boolean(false), then: .number(.infinity), otherwise: .number(1))] {
            bindingFailure(t, .invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Bad numeric", root: bindingText(.concatenate([expression])))) }
        }
    }

    t.suite("Program: numeric: three-valued boolean tables and lazy branches preserve actual dependencies") {
        let cases: [(ProgramExpression, ProgramScalar)] = [
            (.not(unknown), .missing(.boolean)), (.and(.boolean(false), unknown), .boolean(false)),
            (.and(unknown, .boolean(false)), .boolean(false)), (.and(.boolean(true), unknown), .missing(.boolean)),
            (.and(unknown, .boolean(true)), .missing(.boolean)), (.and(unknown, unknown), .missing(.boolean)),
            (.or(.boolean(true), unknown), .boolean(true)), (.or(unknown, .boolean(true)), .boolean(true)),
            (.or(.boolean(false), unknown), .missing(.boolean)), (.or(unknown, .boolean(false)), .missing(.boolean)),
            (.or(unknown, unknown), .missing(.boolean)), (.conditional(unknown, then: .number(9), otherwise: .number(3)), .number(3)),
            (.isMissing(.not(unknown)), .boolean(true)), (.ifMissing(.not(unknown), .boolean(false)), .boolean(false)),
        ]
        for (expression, expected) in cases { t.equal(try scalar(expression), expected) }
        // A date without its input would throw. Unchosen branches must not read it or start a clock lease.
        let live = ProgramExpression.equal(.timeNow, .timeNow)
        for expression in [ProgramExpression.and(.boolean(false), live), .or(.boolean(true), live),
                           .conditional(.boolean(true), then: .boolean(true), otherwise: live),
                           .ifMissing(.number(5), .conditional(live, then: .number(6), otherwise: .number(7)))] {
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Lazy", root: bindingText(.concatenate([expression]))))
            _ = try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure)
            t.check(runtime.clockPrecision == nil)
        }
        var needed = try ProgramRuntime(program: WidgetProgram(name: "Missing left needs right", root: bindingText(.concatenate([.and(unknown, live)]))))
        bindingFailure(t, .invalidDateInput) { _ = try needed.project(environment: bindingEnvironment(false), measure: bindingMeasure) }
        t.equal(needed.generation, 0)
    }

    t.suite("Program: numeric: locale formatting and frozen UTF16 ranges reach identical measurement and drawing styles") {
        let cases: [(Double, ProgramNumberFormat, String, String)] = [
            (12345.678, ProgramNumberFormat(), "en_US", "12,345.68"), (12345.678, ProgramNumberFormat(), "de_DE", "12.345,68"),
            (-12.3, ProgramNumberFormat(), "en_US", "-12.3"), (1.25, ProgramNumberFormat(decimals: 10), "en_US", "1.2500000000"),
            (12345.678, ProgramNumberFormat(decimals: 0), "en_US", "12,346"),
            (1.25, ProgramNumberFormat(decimals: 1), "en_US", "1.2"),
            (1e20, ProgramNumberFormat(), "en_US", "100,000,000,000,000,000,000"),
        ]
        for (number, format, locale, expected) in cases {
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Region", root: bindingText(.formatNumber(.number(number), format))))
            let scene = try runtime.project(environment: bindingEnvironment(false), dateInput: input(locale), measure: bindingMeasure)
            t.equal(bindingStrings(scene), [expected])
        }
        for decimals in [-1, 11, Int.max] {
            bindingFailure(t, .invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid places", root: bindingText(.formatNumber(.number(1), ProgramNumberFormat(decimals: decimals))))) }
        }
        let large = try scalar(.formatNumber(.number(.greatestFiniteMagnitude), ProgramNumberFormat()), dateInput: input("en_US"))
        t.check((large.text?.text.utf16.count ?? 0) >= 309 && !(large.text?.text.contains("∞") ?? true))
        let rendered = ProgramExpression.concatenate([.string("😀7|"), .formatNumber(.number(12.3), ProgramNumberFormat())])
        let declarations = [ProgramDeclaration(name: "frozen", kind: .variable, initial: rendered)]
        var measured: [TextStyle] = []
        let root = ProgramElement(id: ElementID(name: "text", index: 0), content: .text(ProgramText(value: .declaration(0))), width: .fixed(10))
        var wrapped = try ProgramRuntime(program: WidgetProgram(name: "Ranges", root: root, declarations: declarations))
        let scene = try wrapped.project(environment: bindingEnvironment(false), dateInput: input("en_US")) { _, style, width in
            measured.append(style); return SkinSize(width: width ?? 20, height: width == nil ? 10 : 20)
        }
        let range = [InlineSpan(location: 4, length: 4, setting: .typography(feature: "tnum", value: 1))]
        t.equal(measured.map(\.inlineSpans), [range, range], "natural and wrapped native measurement use the same exact numeric range")
        guard case .text(let drawing)? = scene.drawingItems.first else { throw BindingFixtureFailure.program }
        t.equal(drawing.style, measured.last!); t.equal(drawing.text, "😀7|12.3")
        t.equal(try scalar(.equal(rendered, .string("😀7|12.3"))), .boolean(true), "String equality excludes formatting metadata")
        let missing = try scalar(.formatNumber(unavailable, ProgramNumberFormat(missing: "未知😀")))
        t.equal(missing.text, ProgramTextValue(text: "未知😀"), "placeholder is not numeric ink")
    }

    t.suite("Program: numeric: click assignments commit missing and frozen text atomically with the scene") {
        let declarations = [ProgramDeclaration(name: "count", kind: .variable, initial: .number(0)),
                            ProgramDeclaration(name: "frozen", kind: .variable, initial: .string("start"))]
        let value = ProgramExpression.concatenate([.declaration(1), .string("|"), .formatNumber(.declaration(0), ProgramNumberFormat())])
        let actions = [ProgramAssignment(declaration: 0, value: .add(.ifMissing(.declaration(0), .number(40)), .number(1))),
                       ProgramAssignment(declaration: 1, value: .concatenate([.string("😀"), .formatNumber(.declaration(0), ProgramNumberFormat())]))]
        let root = ProgramElement(id: ElementID(name: "text", index: 0), content: .text(ProgramText(value: value)), onClick: actions)
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Counter", root: root, declarations: declarations,
                                                               onLoad: [ProgramAssignment(declaration: 0, value: unavailable)]))
        let environment = bindingEnvironment(false), point = SkinPoint(x: 1, y: 1)
        let first = try runtime.project(environment: environment, measure: bindingMeasure)
        t.equal(bindingStrings(first), ["start|–"])
        t.throwsError { _ = try runtime.click(at: point, expectedGeneration: first.generation, environment: environment) { _, _, _ in throw BindingFixtureFailure.measurement } }
        t.equal(runtime.generation, first.generation)
        guard let next = try runtime.click(at: point, expectedGeneration: first.generation, environment: environment, measure: bindingMeasure) else { throw BindingFixtureFailure.program }
        t.equal(bindingStrings(next), ["😀41|41"])
        guard case .text(let draw)? = next.drawingItems.first else { throw BindingFixtureFailure.program }
        t.equal(draw.style.inlineSpans, [InlineSpan(location: 2, length: 2, setting: .typography(feature: "tnum", value: 1)),
                                       InlineSpan(location: 5, length: 2, setting: .typography(feature: "tnum", value: 1))])
        t.equal(bindingStrings(try runtime.project(environment: environment, measure: bindingMeasure)), ["😀41|41"], "onLoad does not rerun after missing recovers")
        t.check(try runtime.click(at: point, expectedGeneration: first.generation, environment: environment, measure: bindingMeasure) == nil)
        bindingFailure(t, .invalidAssignment(0)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Type", root: root, declarations: declarations, onLoad: [ProgramAssignment(declaration: 0, value: .string("0"))])) }
    }

    t.suite("Desk: numeric: checked plain counters arithmetic formats and missing recovery produce shared scenes") {
        let original = #"widget { Text(1) }"# // The original unsupported literal now lowers, without dropping its context.
        let program = try checkedBindingProgram(t, original)
        var literal = try ProgramRuntime(program: program)
        t.equal(bindingStrings(try literal.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["1"])
        let source = "\u{FEFF}" + #"widget { variable count = 0; computed twice = count * 2; Text("😀点按 {count} 次 / {twice}").size(120, 30).onClick { count = count + 1 } }"# + "\r\n"
        var runtime = try ProgramRuntime(program: checkedBindingProgram(t, source))
        for expected in ["😀点按 0 次 / 0", "😀点按 1 次 / 2", "😀点按 2 次 / 4"] {
            let scene = try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure)
            t.equal(bindingStrings(scene), [expected])
            _ = try runtime.click(at: SkinPoint(x: 1, y: 1), expectedGeneration: scene.generation, environment: bindingEnvironment(false), measure: bindingMeasure)
        }
        let recovery = #"widget { variable n = 3; computed caption = "{n, decimals: 1, missing: "空😀"}|{n.isMissing}|{n.ifMissing(8)}"; Text(caption).onLoad { n = 1 / 0 } }"#
        var missing = try ProgramRuntime(program: checkedBindingProgram(t, recovery))
        t.equal(bindingStrings(try missing.project(environment: bindingEnvironment(false), dateInput: input("en_US"), measure: bindingMeasure)), ["空😀|Yes|8"])
        let math = #"widget { Text("{-7 % 3}|{-(3 + 2) * 4 / 2}|{2 < 3 and 3 >= 3}|{1 / 0 != 2}|{(1 / 0 < 1) ? 9 : 4}") }"#
        var operators = try ProgramRuntime(program: checkedBindingProgram(t, math))
        t.equal(bindingStrings(try operators.project(environment: bindingEnvironment(false), measure: bindingMeasure)), ["-1|-10|Yes|–|4"])
    }

    t.suite("Desk: numeric: checked dimensions and foreign catalog formats reject the complete program") {
        // The original unit literals are retained unchanged in runDeskUnitTests' positive controls.
        let sources = [#"widget { Text(1°C) }"#, #"widget { Text(1KB / 1s) }"#, #"widget { Text(2s / 1s).margin(1) }"#,
                       #"widget { variable n = 1%; Text("{n}").margin(1) }"#, "info { permissions: [.music] }\n" + #"widget { Text(music.title) }"#,
                       #"widget { Text("{time.now < time.now}") }"#,
                       #"widget { Text(2KB / 1s) }"#, #"widget { Text(100% / 50%).offset(x: 1) }"#,
                       #"widget { Text(round(1.2)) }"#, #"widget { variable places = 2; Text("{1, decimals: places}") }"#]
        for source in sources {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil && !result.issues.isEmpty, source)
            t.equal(result.issues.first?.kind, .unsupported); t.equal(result.diagnostics, checked.diagnostics)
            t.check(result.imageSources.isEmpty)
        }
        // The original compound-assignment literal is parser-invalid, not a successfully checked unsupported program.
        let compound = deskCheck(#"widget { variable n = 1; Text(n).onClick { n += 1 } }"#)
        let refused = Desk.compile(compound)
        t.check(compound.diagnostics.contains { $0.id == .compoundAssignment && $0.severity == .error })
        t.check(refused.program == nil && refused.imageSources.isEmpty)
        t.equal(refused.diagnostics, compound.diagnostics)
        var catalog = DeskCatalog.current
        catalog.typeFormats[catalog.typeFormats.firstIndex { $0.type == .plainNumber }!].decimals = 3
        var checked = deskCheck(#"widget { Text(1) }"#, context: CheckContext(catalog: catalog))
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)
        catalog = .current
        catalog.formatOptions[catalog.formatOptions.firstIndex { $0.label == "decimals" }!].range = 0...11
        checked = deskCheck(#"widget { Text("{1, decimals: 1}") }"#, context: CheckContext(catalog: catalog))
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)
        catalog = .current
        let any = catalog.typeMembers.firstIndex { $0.type == "Any" }!
        let fallback = catalog.typeMembers[any].members.firstIndex { $0.name == "ifMissing" }!
        catalog.typeMembers[any].members[fallback].lowering = .derived("unrecognized")
        checked = deskCheck(#"widget { Text((1 / 0).ifMissing(2)) }"#, context: CheckContext(catalog: catalog))
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)
    }

    t.suite("Desk: numeric: digit policies inherit without applying automatic ranges to literal digits") {
        let source = #"widget { Column { Text("😀7|{12.3}"); Text("😀7|{12.3}").digits(.normal); Text("😀7|{12.3}").digits(.equalWidth) } }"#
        var runtime = try ProgramRuntime(program: checkedBindingProgram(t, source))
        let scene = try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure)
        let spans = scene.drawingItems.compactMap { item -> [InlineSpan]? in if case .text(let draw) = item { return draw.style.inlineSpans }; return nil }
        t.equal(spans, [[InlineSpan(location: 4, length: 4, setting: .typography(feature: "tnum", value: 1))], [],
                        [InlineSpan(location: 0, length: 8, setting: .typography(feature: "tnum", value: 1))]])
        let inherited = #"widget { Column { Text("😀7|{12.3}"); Text("😀7|{12.3}").digits(.normal) }.digits(.equalWidth) }"#
        runtime = try ProgramRuntime(program: checkedBindingProgram(t, inherited))
        let nested = try runtime.project(environment: bindingEnvironment(false), measure: bindingMeasure)
        let recipes = nested.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.style.inlineSpans }; return nil }
        t.equal(recipes, [[InlineSpan(location: 0, length: 8, setting: .typography(feature: "tnum", value: 1))], []])
    }
}

private func runProgramUnitTests(_ t: TestRunner) {
    func q(_ n: Double, _ dimension: ProgramNumberDimension, _ base: Int? = nil) -> ProgramExpression {
        .quantity(ProgramNumber(n, dimension: dimension, displayBase: base))
    }
    func input(_ seconds: Double = 0, _ locale: String = "en_US") -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: locale))
    }
    func scalar(_ expression: ProgramExpression, _ date: ProgramDateInput? = nil) throws -> ProgramScalar {
        var value = ProgramExpressionEvaluation(declarations: [], dark: false, variables: nil, dateInput: date)
        return try value.resolveAssignmentValue(expression)
    }
    let missingBytes = ProgramExpression.divide(q(1, .bytes, 1024), .number(0))
    t.suite("Program: units: canonical arithmetic preserves dimensions bases and typed missing") {
        let cases: [(ProgramExpression, ProgramScalar)] = [
            (.multiply(q(50, .percent), q(2000, .bytes)), .numeric(ProgramNumber(1000, dimension: .bytes))),
            (.multiply(q(120, .duration), q(25, .percent)), .numeric(ProgramNumber(30, dimension: .duration))),
            (.multiply(q(50, .percent), .number(3)), .numeric(ProgramNumber(150, dimension: .percent))),
            (.multiply(.number(3), q(50, .percent)), .numeric(ProgramNumber(150, dimension: .percent))),
            (.divide(q(100, .percent), q(50, .percent)), .number(2)),
            (.divide(q(6, .bytes), q(2, .bytes)), .number(3)),
            (.divide(q(90, .duration), .number(2)), .numeric(ProgramNumber(45, dimension: .duration))),
            (.remainder(q(90, .duration), q(60, .duration)), .numeric(ProgramNumber(30, dimension: .duration))),
            (.remainder(q(-90, .duration), q(60, .duration)), .numeric(ProgramNumber(-30, dimension: .duration))),
            (.negate(q(12.5, .bytes)), .numeric(ProgramNumber(-12.5, dimension: .bytes))),
            (.add(q(1000, .bytes, 1000), q(24, .bytes, 1024)), .numeric(ProgramNumber(1024, dimension: .bytes, displayBase: 1000))),
            (.equal(q(1024, .bytes, 1000), q(1024, .bytes, 1024)), .boolean(true)),
            (.less(q(-2, .percent), q(0, .percent)), .boolean(true)),
            (missingBytes, .missing(.numeric(.bytes, displayBase: 1024))),
            (.remainder(q(90, .duration), q(0, .duration)), .missing(.numeric(.duration))),
            (.multiply(q(.greatestFiniteMagnitude, .bytes), .number(2)), .missing(.numeric(.bytes))),
            (.add(missingBytes, q(2, .bytes)), .missing(.numeric(.bytes, displayBase: 1024))),
            (.less(missingBytes, q(2, .bytes)), .missing(.boolean)),
            (.ifMissing(missingBytes, q(9, .bytes, 1000)), .numeric(ProgramNumber(9, dimension: .bytes, displayBase: 1000))),
        ]
        for (expression, expected) in cases {
            t.equal(try scalar(expression), expected)
            let shown = expected.type == .boolean ? ProgramExpression.concatenate([expression]) : .formatNumber(expression, ProgramNumberFormat())
            _ = try ProgramRuntime(program: WidgetProgram(name: "Units", root: bindingText(shown)))
        }
        let base = try scalar(.add(q(1000, .bytes, 1000), q(24, .bytes, 1024)))
        t.equal(base.type.displayBase, 1000)
        t.equal(try scalar(missingBytes).type.displayBase, 1024)
        for expression in [ProgramExpression.add(q(1, .bytes), .number(1)), .equal(q(1, .percent), .number(1)),
                           .multiply(q(1, .percent), q(1, .percent)), .divide(q(1, .bytes), q(1, .duration)),
                           .less(.timeNow, .timeNow), .subtract(q(1, .duration), .timeNow),
                           q(.infinity, .bytes), q(.nan, .duration), q(1, .bytes, 10), q(1, .percent, 1000)] {
            bindingFailure(t, .invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid units", root: bindingText(.concatenate([expression])))) }
        }
        let unavailable = ProgramExpression.less(missingBytes, q(1, .bytes))
        t.equal(try scalar(.and(unavailable, .boolean(false))), .boolean(false))
        t.equal(try scalar(.or(unavailable, .boolean(true))), .boolean(true))
        t.equal(try scalar(.conditional(unavailable, then: q(9, .bytes), otherwise: q(3, .bytes))), .numeric(ProgramNumber(3, dimension: .bytes)))
        t.equal(try scalar(.ifMissing(q(1, .duration), .subtract(.timeNow, .timeNow))), .numeric(ProgramNumber(1, dimension: .duration)), "lazy fallback does not read an absent date input")
    }

    t.suite("Program: units: explicit locales unit choices and native numeric fields remain distinct") {
        let cases: [(ProgramExpression, ProgramNumberFormat, String, String, [Range<Int>])] = [
            (q(12.5, .percent), ProgramNumberFormat(), "en_US", "12", [0..<2]),
            (q(12.5, .percent), ProgramNumberFormat(decimals: 1), "de_DE", "12,5", [0..<4]),
            (q(12500, .bytes), ProgramNumberFormat(), "en_US", "12.5 KB", [0..<4]),
            (q(12500, .bytes), ProgramNumberFormat(), "zh_CN", "12.5 KB", [0..<4]),
            (q(12500, .bytes), ProgramNumberFormat(), "de_DE", "12,5 KB", [0..<4]),
            (q(12500, .bytes), ProgramNumberFormat(), "ar_EG", "١٢٫٥ KB", [0..<4]),
            (q(12500, .bytes), ProgramNumberFormat(unitStyle: .full), "en_US", "12.5 kilobytes", [0..<4]),
            (q(12500, .bytes), ProgramNumberFormat(unitStyle: .full), "zh_CN", "12.5千字节", [0..<4]),
            (q(12500, .bytes), ProgramNumberFormat(unitStyle: .some(.none)), "de_DE", "12,5", [0..<4]),
            (q(100000, .bytes), ProgramNumberFormat(), "en_US", "100 KB", [0..<3]),
            (q(0, .bytes), ProgramNumberFormat(), "en_US", "0.0 B", [0..<3]),
            (q(-12500, .bytes), ProgramNumberFormat(), "en_US", "-12.5 KB", [0..<5]),
            (q(273852, .duration), ProgramNumberFormat(), "en_US", "3 days, 4 hours", [0..<1, 8..<9]),
            (q(273852, .duration), ProgramNumberFormat(durationStyle: .short), "en_US", "3d 4h", [0..<1, 3..<4]),
            (q(273852, .duration), ProgramNumberFormat(durationStyle: .clock), "en_US", "76:04:12", [0..<2, 3..<5, 6..<8]),
            (q(90, .duration), ProgramNumberFormat(), "de_DE", "1 Minute und 30 Sekunden", [0..<1, 13..<15]),
            (q(90, .duration), ProgramNumberFormat(durationStyle: .clock), "ar_EG", "١:٣٠", [0..<1, 2..<4]),
            (q(-90, .duration), ProgramNumberFormat(durationStyle: .clock), "en_US", "-1:30", [0..<2, 3..<5]),
            (q(0.125, .duration), ProgramNumberFormat(), "en_US", "0 seconds", [0..<1]),
            (q(0, .duration), ProgramNumberFormat(durationStyle: .clock), "en_US", "0:00", [0..<1, 2..<4]),
        ]
        for (quantity, format, locale, expected, ranges) in cases {
            let value = try scalar(.formatNumber(quantity, format), input(0, locale))
            t.equal(value.text, ProgramTextValue(text: expected, numberRanges: ranges))
        }
        let units: [(ProgramNumberFormat.ByteUnit, String)] = [
            (.auto, "1.0 MB"), (.bytes, "1,048,576 B"), (.kb, "1,049 KB"), (.mb, "1.0 MB"), (.gb, "0.0 GB"), (.tb, "0.0 TB"),
            (.kib, "1,024 KiB"), (.mib, "1.0 MiB"), (.gib, "0.0 GiB"), (.tib, "0.0 TiB"),
        ]
        t.equal(Set(units.map(\.0)), Set(ProgramNumberFormat.ByteUnit.allCases))
        for (unit, expected) in units {
            t.equal(try scalar(.formatNumber(q(1048576, .bytes), ProgramNumberFormat(unit: unit)), input()).text?.text, expected)
        }
        t.equal(try scalar(.formatNumber(q(1024, .bytes, 1024), ProgramNumberFormat()), input()).text?.text, "1.0 KB")
        let missing = try scalar(.formatNumber(missingBytes, ProgramNumberFormat(missing: "空😀")), input())
        t.equal(missing.text, ProgramTextValue(text: "空😀"))
        let huge = try scalar(.formatNumber(q(.greatestFiniteMagnitude, .bytes), ProgramNumberFormat(unit: .bytes)), input())
        t.check((huge.text?.text.utf16.count ?? 0) >= 309 && !(huge.text?.text.contains("∞") ?? true))
        for (value, format) in [(q(1, .duration), ProgramNumberFormat(decimals: 0)),
                                (q(1, .percent), ProgramNumberFormat(unit: .auto)),
                                (q(1, .bytes), ProgramNumberFormat(durationStyle: .full)),
                                (ProgramExpression.number(1), ProgramNumberFormat(unitStyle: .some(.none)))] {
            bindingFailure(t, .invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid format", root: bindingText(.formatNumber(value, format)))) }
        }
        var unrepresentable = try ProgramRuntime(program: WidgetProgram(name: "Long duration", root: bindingText(.formatNumber(q(.greatestFiniteMagnitude, .duration), ProgramNumberFormat()))))
        bindingFailure(t, .invalidExpression) { _ = try unrepresentable.project(environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure) }
        t.equal(unrepresentable.generation, 0)
    }

    t.suite("Program: units: frozen UTF16 spans and unit assignments publish with one scene transaction") {
        let text = ProgramExpression.concatenate([.string("😀7|"), .formatNumber(.declaration(0), ProgramNumberFormat()), .string("\r\n"),
                                                .formatNumber(.declaration(1), ProgramNumberFormat(durationStyle: .clock))])
        let declarations = [ProgramDeclaration(name: "bytes", kind: .variable, initial: q(1000, .bytes)),
                            ProgramDeclaration(name: "duration", kind: .variable, initial: q(90, .duration)),
                            ProgramDeclaration(name: "frozen", kind: .variable, initial: text)]
        let assignments = [ProgramAssignment(declaration: 0, value: q(1024, .bytes, 1024)),
                           ProgramAssignment(declaration: 1, value: .add(.declaration(1), q(1, .duration))),
                           ProgramAssignment(declaration: 2, value: text)]
        let root = ProgramElement(id: ElementID(name: "text", index: 0), content: .text(ProgramText(value: .declaration(2))), onClick: assignments)
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Transaction", root: root, declarations: declarations))
        var measured: [TextStyle] = []
        let first = try runtime.project(environment: bindingEnvironment(false), dateInput: input()) { _, style, _ in
            measured.append(style); return SkinSize(width: 120, height: 40)
        }
        t.equal(bindingStrings(first), ["😀7|1.0 KB\r\n1:30"])
        let ranges = [InlineSpan(location: 4, length: 3, setting: .typography(feature: "tnum", value: 1)),
                      InlineSpan(location: 12, length: 1, setting: .typography(feature: "tnum", value: 1)),
                      InlineSpan(location: 14, length: 2, setting: .typography(feature: "tnum", value: 1))]
        t.equal(measured.first?.inlineSpans, ranges)
        guard case .text(let draw)? = first.drawingItems.first else { throw BindingFixtureFailure.program }
        t.equal(draw.style, measured.first)
        t.throwsError { _ = try runtime.click(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
                                            environment: bindingEnvironment(false), dateInput: input()) { _, _, _ in throw BindingFixtureFailure.measurement } }
        t.equal(runtime.generation, first.generation)
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure)), ["😀7|1.0 KB\r\n1:30"])
        guard let changed = try runtime.click(at: SkinPoint(x: 1, y: 1), expectedGeneration: runtime.generation,
                                              environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure) else { throw BindingFixtureFailure.program }
        t.equal(bindingStrings(changed), ["😀7|1.0 KB\r\n1:31"])
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(true), dateInput: input(60, "de_DE"), measure: bindingMeasure)), ["😀7|1.0 KB\r\n1:31"], "a String freezes locale and the numeric ranges")
        bindingFailure(t, .invalidAssignment(0)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Wrong unit", root: root, declarations: declarations,
                                                   onLoad: [ProgramAssignment(declaration: 0, value: q(1, .percent))])) }
    }

    t.suite("Program: units: date arithmetic keeps zones and live duration demand without freezing a timer") {
        let now = input(0)
        t.equal(try scalar(.subtract(.timeNow, .timeNow), now), .numeric(ProgramNumber(0, dimension: .duration)))
        let zoned = ProgramExpression.dateIn(.timeNow, timeZone: "Asia/Tokyo")
        let plus = try scalar(.add(zoned, q(90, .duration)), now)
        t.equal(plus, .date(ProgramDateValue(instant: Date(timeIntervalSince1970: 90), timeZone: TimeZone(identifier: "Asia/Tokyo")!)))
        t.equal(try scalar(.add(q(90, .duration), zoned), now), plus)
        t.equal(try scalar(.subtract(zoned, q(90, .duration)), now), .date(ProgramDateValue(instant: Date(timeIntervalSince1970: -90), timeZone: TimeZone(identifier: "Asia/Tokyo")!)))
        let declarations = [ProgramDeclaration(name: "started", kind: .variable, initial: .timeNow),
                            ProgramDeclaration(name: "elapsed", kind: .computed, initial: .subtract(.timeNow, .declaration(0)))]
        let caption = ProgramExpression.formatNumber(.declaration(1), ProgramNumberFormat(durationStyle: .clock))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Elapsed", root: bindingText(caption), declarations: declarations))
        t.throwsError { _ = try runtime.project(environment: bindingEnvironment(false), dateInput: now) { _, _, _ in throw BindingFixtureFailure.measurement } }
        t.check(runtime.clockPrecision == nil); t.equal(runtime.generation, 0)
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), dateInput: input(1), measure: bindingMeasure)), ["0:00"])
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), dateInput: input(91), measure: bindingMeasure)), ["1:30"])
        t.equal(runtime.clockPrecision, .second)
        var frozen = try ProgramRuntime(program: WidgetProgram(name: "Frozen", root: bindingText(.formatNumber(.declaration(0), ProgramNumberFormat())),
            declarations: [ProgramDeclaration(name: "duration", kind: .variable, initial: .subtract(.timeNow, .timeNow))]))
        _ = try frozen.project(environment: bindingEnvironment(false), dateInput: now, measure: bindingMeasure)
        _ = try frozen.project(environment: bindingEnvironment(false), dateInput: input(90), measure: bindingMeasure)
        t.check(frozen.clockPrecision == nil)
        var hidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden", root: bindingText(caption, hidden: true), declarations: declarations))
        _ = try hidden.project(environment: bindingEnvironment(false), dateInput: now, measure: bindingMeasure)
        t.check(hidden.clockPrecision == nil)
        var minute = try ProgramRuntime(program: WidgetProgram(name: "Minute", root: bindingText(.formatDate(.add(.timeNow, q(90, .duration)), .pattern("HH:mm")))))
        t.equal(bindingStrings(try minute.project(environment: bindingEnvironment(false), dateInput: now, measure: bindingMeasure)), ["00:01"])
        t.equal(minute.clockPrecision, .minute)
        var overflow = try ProgramRuntime(program: WidgetProgram(name: "Overflow", root: bindingText(.formatDate(.add(.timeNow, q(.greatestFiniteMagnitude, .duration)), .preset(.time)))))
        t.equal(bindingStrings(try overflow.project(environment: bindingEnvironment(false), dateInput: input(.greatestFiniteMagnitude), measure: bindingMeasure)), ["–"])
    }
}

private func runDeskUnitTests(_ t: TestRunner) {
    func input(_ seconds: Double = 0, _ locale: String = "en_US") -> ProgramDateInput {
        ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: locale))
    }
    t.suite("Desk: units: original unit literals and settled canonical values produce shared scenes") {
        let originals = [(#"widget { Text(1%) }"#, "1"), (#"widget { Text(1KB) }"#, "1.0 KB"),
                         (#"widget { Text(2s / 1s) }"#, "2"), (#"widget { variable n = 1%; Text("{n}") }"#, "1"),
                         (#"widget { Text(2KB / 1B) }"#, "2,000"), (#"widget { Text(100% / 50%) }"#, "2")]
        for (source, expected) in originals {
            var runtime = try ProgramRuntime(program: checkedBindingProgram(t, source))
            t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure)), [expected], source)
        }
        let cases = [(#"widget { computed b = 1KB + 1KiB; Text("{b, unit: .bytes}") }"#, "2,048 B"),
                     (#"widget { variable b = 1KB; Text("{b + 1, unit: .bytes}") }"#, "1,001 B"),
                     (#"widget { Text("{(1 + 2) + 1B, unit: .bytes}") }"#, "4.0 B"),
                     (#"widget { Text("{50% * 2KB, unit: .bytes}|{120s * 25%, style: .clock}") }"#, "1,000 B|0:30"),
                     (#"widget { Text("{1GB, unit: .bytes}|{1GiB, unit: .bytes}") }"#, "1,000,000,000 B|1,073,741,824 B"),
                     (#"widget { Text("{150%}|{-90s, style: .clock}|{0s, style: .short}") }"#, "150|-1:30|0s")]
        for (source, expected) in cases {
            var runtime = try ProgramRuntime(program: checkedBindingProgram(t, source))
            t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure)), [expected], source)
        }
        let source = #"widget { variable b = 1KB; Text("{b, unit: .bytes}").onClick { b = 1KiB } }"#
        let program = try checkedBindingProgram(t, source)
        t.equal(program.declarations[0].initial, .quantity(ProgramNumber(1024, dimension: .bytes, displayBase: 1024)))
        var runtime = try ProgramRuntime(program: program)
        let initial = try runtime.project(environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure)
        t.equal(bindingStrings(initial), ["1,024 B"])
        guard let next = try runtime.click(at: SkinPoint(x: 1, y: 1), expectedGeneration: initial.generation,
                                          environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure) else { throw BindingFixtureFailure.program }
        t.equal(bindingStrings(next), ["1,024 B"])
        let leftBare = #"widget { variable b = 1KB; Text("{1 + b, unit: .kb, decimals: 3}").onClick { b = 1KiB } }"#
        runtime = try ProgramRuntime(program: checkedBindingProgram(t, leftBare))
        let leftFirst = try runtime.project(environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure)
        t.equal(bindingStrings(leftFirst), ["1.001 KB"], "the bare left operand uses the settled 1024 base")
        guard let leftNext = try runtime.click(at: SkinPoint(x: 1, y: 1), expectedGeneration: leftFirst.generation,
                                              environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure) else {
            throw BindingFixtureFailure.program
        }
        t.equal(bindingStrings(leftNext), ["1.001 KB"])
    }

    t.suite("Desk: units: explicit constant and dynamic fraction receipts convert once without folding variables") {
        // An ordinary Plain is not implicitly a 0...1 fraction. Write the shared Percent/Percent quotient.
        let source = #"widget { variable p = 50%; computed n = p / 100%; Text("{50% / 100% == n}|{p / 100% == n}|{(p + 10%) / 100% > n}|{p * 2KB, unit: .bytes}").onClick { p = p + 25% } }"#
        let program = try checkedBindingProgram(t, source)
        t.equal(program.declarations[0].initial, .quantity(ProgramNumber(50, dimension: .percent)))
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure)
        t.equal(bindingStrings(first), ["Yes|Yes|Yes|1,000 B"])
        t.throwsError { _ = try runtime.click(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
                                            environment: bindingEnvironment(false), dateInput: input()) { _, _, _ in throw BindingFixtureFailure.measurement } }
        t.equal(runtime.generation, first.generation)
        guard let next = try runtime.click(at: SkinPoint(x: 1, y: 1), expectedGeneration: first.generation,
                                          environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure) else { throw BindingFixtureFailure.program }
        t.equal(bindingStrings(next), ["No|Yes|Yes|1,500 B"])
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(true), dateInput: input(), measure: bindingMeasure)), ["No|Yes|Yes|1,500 B"])

        // Qualify real use-site lowering without claiming support for the complete opacity facet/document.
        // These are the checker's actual constant and dynamic Fraction parameter uses, never fabricated maps.
        let fractions = deskCheck(#"widget { variable p = 50%; Text("A").opacity(p).onClick { p = p + 25% }; Text("A").opacity(50%); Text("A").opacity(p + 10%); Text("{p}") }"#)
        t.check(fractions.diagnostics(.error).isEmpty, deskDescribe(fractions))
        t.equal(Desk.compile(fractions).issues.first?.kind, .unsupported, "opacity remains a whole-program capability boundary")
        guard let widgetNode = fractions.tree.rootNode.childNodes.first(where: { $0.kind == .widgetBlock }),
              let widget = TopLevelBlockSyntax(widgetNode) else { throw BindingFixtureFailure.program }
        let calls = widget.block.items.compactMap(CallStmtSyntax.init)
        let uses = calls.flatMap(\.modifiers).filter { $0.name.token.name == "opacity" }
            .compactMap { $0.arguments?.arguments.first?.value.node }
        guard uses.count == 3, let last = calls.last?.arguments?.arguments.first?.value.node,
              let click = calls.first?.modifiers.first(where: { $0.name.token.name == "onClick" }),
              let statement = click.block?.items.first, let syntax = AssignmentSyntax(statement) else {
            throw BindingFixtureFailure.program
        }
        let dynamicID = fractions.tree.id(of: uses[0]), constantID = fractions.tree.id(of: uses[1])
        t.equal(fractions.types[dynamicID]?.type, .plainNumber)
        t.equal(fractions.numericCoercions[dynamicID], .percentAsFraction)
        t.equal(fractions.canonicalNumericValues[dynamicID], nil, "mutable reads are not folded from their initializer")
        t.equal(fractions.canonicalNumericValues[constantID], 0.5)
        t.equal(fractions.numericCoercions[constantID], .percentAsFraction)
        var compiler = ProgramExpressionCompiler(checked: fractions, catalog: .current)
        let declarations = try compiler.declarations(widget.block.items.compactMap(DeclarationSyntax.init))
        let dynamic = try compiler.text(uses[0]), constant = try compiler.text(uses[1]),
            compound = try compiler.text(uses[2]), percent = try compiler.text(last)
        let assignment = try compiler.assignment(syntax)
        let expression = ProgramExpression.concatenate([dynamic, .string("|"), constant, .string("|"), compound, .string("|"), percent])
        let root = ProgramElement(id: ElementID(name: "checked fraction uses", index: 0),
                                  content: .text(ProgramText(value: expression)), onClick: [assignment])
        var qualified = try ProgramRuntime(program: WidgetProgram(name: "Expression qualification", root: root, declarations: declarations))
        let qualifiedFirst = try qualified.project(environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure)
        t.equal(bindingStrings(qualifiedFirst), ["0.5|0.5|0.6|50"], "constant, dynamic and compound use conversions occur exactly once")
        guard let qualifiedNext = try qualified.click(at: SkinPoint(x: 1, y: 1), expectedGeneration: qualifiedFirst.generation,
                                                     environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure) else {
            throw BindingFixtureFailure.program
        }
        t.equal(bindingStrings(qualifiedNext), ["0.75|0.5|0.85|75"], "one shared assignment updates the real Percent declaration")
        let notFraction = deskCheck(#"widget { variable p = 50%; computed n = p / 100%; Text("{p == n}") }"#)
        t.check(!notFraction.diagnostics(.error).isEmpty, "ordinary Plain does not acquire a fraction range")
        t.check(Desk.compile(notFraction).program == nil)
        let date = #"widget { variable opened = time.now; Text("{time.now - opened, style: .clock}|{time.now + 90s, format: "HH:mm:ss"}") }"#
        var clock = try ProgramRuntime(program: checkedBindingProgram(t, date))
        t.equal(bindingStrings(try clock.project(environment: bindingEnvironment(false), dateInput: input(0), measure: bindingMeasure)), ["0:00|00:01:30"])
        t.equal(bindingStrings(try clock.project(environment: bindingEnvironment(false), dateInput: input(90), measure: bindingMeasure)), ["1:30|00:03:00"])
        t.equal(clock.clockPrecision, .second)
    }

    t.suite("Desk: units: formats honor catalog enums while unsupported dimensions and missing receipts reject fully") {
        let source = #"widget { Text("{1KB, unit: .bytes, unitStyle: .none, decimals: 2}|{90s, style: .short}|{50%, decimals: 1}") }"#
        var runtime = try ProgramRuntime(program: checkedBindingProgram(t, source))
        t.equal(bindingStrings(try runtime.project(environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure)), ["1,000.00|1m 30s|50.0"])
        let missing = #"widget { variable b = 1KB; Text("{b, missing: "空😀"}|{b.isMissing}|{b.ifMissing(1KiB), unit: .bytes}").onLoad { b = 1KB / 0 } }"#
        runtime = try ProgramRuntime(program: checkedBindingProgram(t, missing))
        let shown = try runtime.project(environment: bindingEnvironment(false), dateInput: input(), measure: bindingMeasure)
        t.equal(bindingStrings(shown), ["空😀|Yes|1,024 B"])
        let durationDecimals = #"widget { Text("{1s, decimals: 1}") }"#
        for source in [durationDecimals, #"widget { Text(1KB / 1s) }"#, #"widget { Text(1°C) }"#,
                       #"widget { Text("{time.now < time.now}") }"#, "info { permissions: [.music] }\n" + #"widget { Text(music.title) }"#,
                       #"widget { Text(true ? 1KB : 2KB).margin(1) }"#,
                       #"widget { Text(true ? 1KB : round(2KB)) }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil && result.issues.first?.kind == .unsupported, source)
            t.equal(result.diagnostics, checked.diagnostics); t.check(result.imageSources.isEmpty)
            if source == durationDecimals {
                t.equal(result.issues.map(\.message), ["Duration decimals are not implemented"])
            }
        }
        let checked = deskCheck(#"widget { Text(1KB) }"#)
        var damaged = checked
        damaged.canonicalNumericValues.removeAll()
        t.equal(Desk.compile(damaged).issues.first?.kind, .invalidCheckedModel)
        var catalog = DeskCatalog.current
        catalog.typeFormats[catalog.typeFormats.firstIndex { $0.type == .percent }!].decimals = 2
        let custom = deskCheck(#"widget { Text(50%) }"#, context: CheckContext(catalog: catalog))
        t.equal(Desk.compile(custom, catalog: catalog).issues.first?.kind, .unsupported)
    }
}


private func runProgramFontSizeTests(_ t: TestRunner) {
    let id = ElementID(name: "font", index: 0)
    func q(_ value: Double, _ dimension: ProgramNumberDimension = .length) -> ProgramExpression {
        .quantity(ProgramNumber(value, dimension: dimension))
    }
    func root(_ size: ProgramExpression, hidden: Bool = false, assignments: [ProgramAssignment]? = nil) -> ProgramElement {
        ProgramElement(id: id, content: .text(ProgramText("甲😀", fontSizeExpression: size)), hidden: hidden, onClick: assignments)
    }
    func measure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
        let points = TextStyle.pixelSize(points: style.fontSize)
        return SkinSize(width: points * 2, height: points)
    }
    func draws(_ scene: WidgetScene) -> [TextDraw] {
        scene.drawingItems.compactMap { if case .text(let draw) = $0 { return draw }; return nil }
    }
    t.suite("Program: font size: typed points share measured drawing styles and UTF16 numeric ranges") {
        let declaration = ProgramDeclaration(name: "points", kind: .variable, initial: q(20))
        let text = ProgramExpression.concatenate([.string("甲😀"), .formatNumber(.declaration(0), ProgramNumberFormat())])
        let element = ProgramElement(id: id, content: .text(ProgramText(value: text,
                                          fontSizeExpression: .multiply(.declaration(0), .number(2)))),
                                     width: .fixed(60), padding: SkinInsets(left: 2, top: 2, right: 2, bottom: 2))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Points", root: element, declarations: [declaration]))
        var measured: [TextStyle] = []
        let scene = try runtime.project(environment: bindingEnvironment(false)) { text, style, width in
            t.equal(text, "甲😀20"); t.close(TextStyle.pixelSize(points: style.fontSize), 40)
            measured.append(style)
            return width == nil ? SkinSize(width: 80, height: 40) : SkinSize(width: 56, height: 80)
        }
        let draw = draws(scene).first!
        t.equal(scene.size, SkinSize(width: 60, height: 84))
        t.equal(draw.text, "甲😀20"); t.equal(draw.style, measured.last)
        t.equal(draw.contentFrame, SkinRect(x: 2, y: 2, width: 56, height: 80))
        t.equal(draw.style.inlineSpans, [InlineSpan(location: 3, length: 2, setting: .typography(feature: "tnum", value: 1))])
        t.check(draw.style.wrap && measured.count == 2)
        var evaluation = ProgramExpressionEvaluation(declarations: [], dark: false, variables: nil)
        t.equal(try evaluation.resolveAssignmentValue(.divide(q(24), q(2))), .number(12))
        t.equal(try evaluation.resolveAssignmentValue(.multiply(q(40), q(50, .percent))), .numeric(ProgramNumber(20, dimension: .length)))
        t.equal(try evaluation.resolveAssignmentValue(.formatNumber(q(12.5), ProgramNumberFormat(decimals: 1))),
                .formattedString(ProgramTextValue(text: "12.5", numberRanges: [0..<4])))
    }
    t.suite("Program: font size: invalid values failed startup and clicks retain the complete transaction") {
        let declarations = [ProgramDeclaration(name: "points", kind: .variable, initial: q(20)),
                            ProgramDeclaration(name: "bad", kind: .variable, initial: .boolean(false))]
        let size = ProgramExpression.conditional(.declaration(1), then: q(0), otherwise: .declaration(0))
        let element = root(size, assignments: [ProgramAssignment(declaration: 0, value: q(28)),
                                               ProgramAssignment(declaration: 1, value: .boolean(true))])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Font transaction", root: element, declarations: declarations,
                                        onLoad: [ProgramAssignment(declaration: 0, value: q(24))]))
        do { _ = try runtime.project(environment: bindingEnvironment(false)) { _, _, _ in throw BindingFixtureFailure.measurement }; t.check(false) }
        catch { t.equal(error as? BindingFixtureFailure, .measurement) }
        t.equal(runtime.generation, 0)
        let first = try runtime.project(environment: bindingEnvironment(false), measure: measure)
        t.close(TextStyle.pixelSize(points: draws(first)[0].style.fontSize), 24)
        bindingFailure(t, .invalidText(id)) {
            _ = try runtime.click(at: SkinPoint(x: 6, y: 6), expectedGeneration: first.generation,
                                  environment: bindingEnvironment(false), measure: measure)
        }
        t.equal(runtime.generation, first.generation); t.equal(runtime.clockPrecision, nil)
        let kept = try runtime.project(environment: bindingEnvironment(true), measure: measure)
        t.close(TextStyle.pixelSize(points: draws(kept)[0].style.fontSize), 24)
        t.equal(kept.hitMap.entries.first?.elementID, id)
        for value in [ProgramExpression.number(0), .number(-1), q(0), .divide(q(1), .number(0)),
                      .multiply(q(.greatestFiniteMagnitude), .number(2))] {
            var invalid = try ProgramRuntime(program: WidgetProgram(name: "Invalid size", root: root(value)))
            bindingFailure(t, .invalidText(id)) { _ = try invalid.project(environment: bindingEnvironment(false), measure: measure) }
            t.equal(invalid.generation, 0)
        }
        for value in [ProgramExpression.string("20"), .boolean(true), .timeNow, q(20, .bytes), q(20, .duration), q(20, .percent),
                      .number(.nan), .number(.infinity), .quantity(ProgramNumber(20, dimension: .length, displayBase: 1000)),
                      .add(q(20), .number(4))] {
            bindingFailure(t, .invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid type", root: root(value))) }
        }
    }
    t.suite("Program: font size: live size dependencies short circuit while hidden layout keeps space") {
        func input(_ seconds: Double) -> ProgramDateInput {
            ProgramDateInput(instant: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US"))
        }
        let started = ProgramDeclaration(name: "started", kind: .variable, initial: .timeNow)
        let elapsed = ProgramExpression.divide(.subtract(.timeNow, .declaration(0)), q(1, .duration))
        let size = ProgramExpression.conditional(.appearanceDark, then: .add(.number(20), elapsed), otherwise: .number(20))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Live size", root: root(size), declarations: [started]))
        let light = try runtime.project(environment: bindingEnvironment(false), dateInput: input(0), measure: measure)
        t.equal(light.size, SkinSize(width: 40, height: 20)); t.equal(runtime.clockPrecision, nil)
        let dark = try runtime.project(environment: bindingEnvironment(true), dateInput: input(4), measure: measure)
        t.equal(dark.size, SkinSize(width: 48, height: 24)); t.equal(runtime.clockPrecision, .second)
        t.equal(try runtime.project(environment: bindingEnvironment(false), dateInput: input(8), measure: measure).size,
                SkinSize(width: 40, height: 20)); t.equal(runtime.clockPrecision, nil)
        var hidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden size", root: root(size, hidden: true), declarations: [started]))
        _ = try hidden.project(environment: bindingEnvironment(true), dateInput: input(0), measure: measure)
        let hiddenScene = try hidden.project(environment: bindingEnvironment(true), dateInput: input(4), measure: measure)
        t.equal(hiddenScene.size, dark.size); t.equal(hidden.clockPrecision, nil)
        t.check(hiddenScene.drawingItems.isEmpty)
        t.equal(hiddenScene.elements[0].visibility, .hiddenKeepsSpace)
    }
}

private func runProgramSystemDataTests(_ t: TestRunner) {
    t.suite("Desk: system data: compilation lowers supported properties to program AST") {
        let sources: [(String, ProgramSystemProperty)] = [
            (#"widget { Text("{cpu.usage}%") }"#, .cpuUsage),
            (#"widget { Text("{cpu.coreCount} cores") }"#, .cpuCoreCount),
            (#"widget { Text("{memory.used}") }"#, .memoryUsed),
            (#"widget { Text("{memory.total}") }"#, .memoryTotal),
            (#"widget { Text("{memory.free}") }"#, .memoryFree),
            (#"widget { Text("{memory.usage}%") }"#, .memoryUsage),
            (#"widget { Text("{battery.level}%") }"#, .batteryLevel),
            (#"widget { Text(battery.charging ? "C" : "D") }"#, .batteryCharging),
            (#"widget { Text(battery.pluggedIn ? "P" : "B") }"#, .batteryPluggedIn),
        ]
        for (source, expectedProp) in sources {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, "\(source): \(deskDescribe(checked))")
            let result = Desk.compile(checked)
            t.check(result.issues.isEmpty, "\(source): \(result.issues)")
            guard let program = result.program else {
                t.check(false, "Failed to compile: \(source)")
                continue
            }
            func containsProp(_ expr: ProgramExpression) -> Bool {
                if case .systemProperty(let p) = expr { return p == expectedProp }
                switch expr {
                case .formatNumber(let child, _), .formatDate(let child, _), .not(let child), .negate(let child),
                     .isMissing(let child), .dateIn(let child, _):
                    return containsProp(child)
                case .concatenate(let parts): return parts.contains(where: containsProp)
                case .add(let l, let r), .subtract(let l, let r), .multiply(let l, let r), .divide(let l, let r),
                     .remainder(let l, let r), .and(let l, let r), .or(let l, let r), .equal(let l, let r),
                     .notEqual(let l, let r), .less(let l, let r), .lessOrEqual(let l, let r), .greater(let l, let r),
                     .greaterOrEqual(let l, let r), .ifMissing(let l, let r):
                    return containsProp(l) || containsProp(r)
                case .conditional(let c, let y, let n):
                    return containsProp(c) || containsProp(y) || containsProp(n)
                default: return false
                }
            }
            if case .text(let text) = program.root.content {
                t.check(containsProp(text.value), "AST did not contain \(expectedProp): \(text.value)")
            } else {
                t.check(false, "Root content is not text: \(program.root)")
            }
        }
    }

    t.suite("Desk: system data: custom catalog contract deviations reject compilation") {
        // 1. Alter cpu.usage range
        var catalog = DeskCatalog.current
        let cpuNs = catalog.namespaces.firstIndex { $0.name == "cpu" }!
        let cpuUsageIdx = catalog.namespaces[cpuNs].members.firstIndex { $0.name == "usage" }!
        catalog.namespaces[cpuNs].members[cpuUsageIdx].range = .none
        var checked = deskCheck(#"widget { Text("{cpu.usage}%") }"#, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty)
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)

        // 2. Alter cpu.usage cadence
        catalog = DeskCatalog.current
        catalog.namespaces[cpuNs].members[cpuUsageIdx].cadence = .periodic(seconds: 2)
        checked = deskCheck(#"widget { Text("{cpu.usage}%") }"#, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty)
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)

        // 3. Alter cpu.usage lowering
        catalog = DeskCatalog.current
        catalog.namespaces[cpuNs].members[cpuUsageIdx].lowering = CatalogData.measureKernel("CPU", ["Processor": "1"])
        checked = deskCheck(#"widget { Text("{cpu.usage}%") }"#, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty)
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)

        // 4. Alter memory.used displayBase
        catalog = DeskCatalog.current
        let memNs = catalog.namespaces.firstIndex { $0.name == "memory" }!
        let memUsedIdx = catalog.namespaces[memNs].members.firstIndex { $0.name == "used" }!
        catalog.namespaces[memNs].members[memUsedIdx].displayBase = 1000
        checked = deskCheck(#"widget { Text("{memory.used}") }"#, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty)
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)

        // 5. Alter memory.total displayBase
        catalog = DeskCatalog.current
        let memTotalIdx = catalog.namespaces[memNs].members.firstIndex { $0.name == "total" }!
        catalog.namespaces[memNs].members[memTotalIdx].displayBase = nil
        checked = deskCheck(#"widget { Text("{memory.total}") }"#, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty)
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)

        // 6. Alter memory.usage range
        catalog = DeskCatalog.current
        let memUsageIdx = catalog.namespaces[memNs].members.firstIndex { $0.name == "usage" }!
        catalog.namespaces[memNs].members[memUsageIdx].range = .none
        checked = deskCheck(#"widget { Text("{memory.usage}%") }"#, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty)
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)

        // 7. Alter battery.level range
        catalog = DeskCatalog.current
        let batNs = catalog.namespaces.firstIndex { $0.name == "battery" }!
        let batLevelIdx = catalog.namespaces[batNs].members.firstIndex { $0.name == "level" }!
        catalog.namespaces[batNs].members[batLevelIdx].range = .none
        checked = deskCheck(#"widget { Text("{battery.level}%") }"#, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty)
        t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)
    }

    t.suite("Desk: system data: evaluation and formatting with ProgramSystemInput") {
        let systemInput = ProgramSystemInput(
            cpuUsage: 42.0,
            cpuCoreCount: 8,
            memoryUsed: 16 * 1024 * 1024 * 1024,
            memoryTotal: 32 * 1024 * 1024 * 1024,
            memoryFree: 16 * 1024 * 1024 * 1024,
            batteryLevel: 95.0,
            batteryCharging: true,
            batteryPluggedIn: true
        )

        // 1. CPU usage & core count
        let cpuWidget = try checkedBindingProgram(t, #"widget { Text("{cpu.usage}% on {cpu.coreCount} cores") }"#)
        var runtime = try ProgramRuntime(program: cpuWidget)
        let scene = try runtime.project(environment: bindingEnvironment(false), systemInput: systemInput, measure: bindingMeasure)
        t.equal(bindingStrings(scene), ["42% on 8 cores"])
        t.equal(runtime.clockPrecision, .second)

        // 2. Memory used / total / free / usage
        let memWidget = try checkedBindingProgram(t, #"widget { Text("{memory.used, unit: .gib} / {memory.total, unit: .gib} ({memory.usage}%)") }"#)
        var memRuntime = try ProgramRuntime(program: memWidget)
        let memScene = try memRuntime.project(environment: bindingEnvironment(false), systemInput: systemInput, measure: bindingMeasure)
        t.equal(bindingStrings(memScene), ["16.0 GiB / 32.0 GiB (50%)"])
        t.equal(memRuntime.clockPrecision, .twoSeconds)

        // 3. Battery level, charging, pluggedIn
        let batWidget = try checkedBindingProgram(t, #"widget { Text("{battery.level}%|{battery.charging}|{battery.pluggedIn}") }"#)
        var batRuntime = try ProgramRuntime(program: batWidget)
        let batScene = try batRuntime.project(environment: bindingEnvironment(false), systemInput: systemInput, measure: bindingMeasure)
        t.equal(bindingStrings(batScene), ["95%|Yes|Yes"])
        t.equal(batRuntime.clockPrecision, .minute)

        // 4. Missing inputs produce expected defaults
        let emptyInput = ProgramSystemInput()
        var emptyRuntime = try ProgramRuntime(program: batWidget)
        let emptyScene = try emptyRuntime.project(environment: bindingEnvironment(false), systemInput: emptyInput, measure: bindingMeasure)
        t.equal(bindingStrings(emptyScene), ["–%|No|No"])

        // 5. Only coreCount (cadence .once) produces nil clockPrecision
        let staticWidget = try checkedBindingProgram(t, #"widget { Text("{cpu.coreCount} cores") }"#)
        var staticRuntime = try ProgramRuntime(program: staticWidget)
        let staticScene = try staticRuntime.project(environment: bindingEnvironment(false), systemInput: systemInput, measure: bindingMeasure)
        t.equal(bindingStrings(staticScene), ["8 cores"])
        t.equal(staticRuntime.clockPrecision, nil)

        // 6. Pure event properties (battery.charging) have nil clockPrecision (not minute-polled)
        let eventWidget = try checkedBindingProgram(t, #"widget { Text(battery.charging ? "Charging" : "Discharging") }"#)
        let eventRuntime = try ProgramRuntime(program: eventWidget)
        t.equal(eventRuntime.clockPrecision, nil)

        // 7. Invalid numbers (>100% or overflow) produce missing defaults
        let invalidCpuFixture = CountingSystemFixture(cpu: 150.0, memUsed: 40 * 1024 * 1024 * 1024, memTotal: 16 * 1024 * 1024 * 1024)
        let invalidInput = ProgramSystemInput.sample(from: invalidCpuFixture)
        t.equal(invalidInput.cpuUsage, nil)
        t.equal(invalidInput.memoryUsed, nil)
        var invalidRuntime = try ProgramRuntime(program: memWidget)
        let invalidScene = try invalidRuntime.project(environment: bindingEnvironment(false), systemInput: invalidInput, measure: bindingMeasure)
        t.equal(bindingStrings(invalidScene), ["– / 16.0 GiB (–%)"])

        // 8. Variable initial value sampled ONLY on first initialization; subsequent ticks do not resample
        let varWidget = try checkedBindingProgram(t, #"widget { variable initialCpu = cpu.usage; Text("Hello") }"#)
        var varRuntime = try ProgramRuntime(program: varWidget)
        t.equal(varRuntime.neededSystemProperties, [.cpuUsage], "uninitialized variables need initial expression properties")
        let countFixture = CountingSystemFixture()
        let varInput = varRuntime.neededSystemProperties.isEmpty ? nil : ProgramSystemInput.sample(from: countFixture, for: varRuntime.neededSystemProperties)
        t.check(varInput != nil)
        t.equal(countFixture.cpuCalls, 1)
        _ = try varRuntime.project(environment: bindingEnvironment(false), systemInput: varInput, measure: bindingMeasure)
        t.equal(varRuntime.neededSystemProperties, [], "initialized variables freeze value and do not re-sample initial expressions")
        let nextInput = varRuntime.neededSystemProperties.isEmpty ? nil : ProgramSystemInput.sample(from: countFixture, for: varRuntime.neededSystemProperties)
        t.equal(nextInput, nil)
        t.equal(countFixture.cpuCalls, 1, "no additional CPU sample on subsequent ticks")

        // 9. Click dependency: before click CPU 0 reads, after click 1 read
        let clickWidget = try checkedBindingProgram(t, #"widget { variable c = 0; Text("Tap").onClick { c = cpu.usage } }"#)
        var clickRuntime = try ProgramRuntime(program: clickWidget)
        t.equal(clickRuntime.neededSystemProperties, [], "actions are not sampled during normal project")
        let tapFixture = CountingSystemFixture()
        let initialInput = clickRuntime.neededSystemProperties.isEmpty ? nil : ProgramSystemInput.sample(from: tapFixture, for: clickRuntime.neededSystemProperties)
        t.equal(tapFixture.cpuCalls, 0)
        let initialScene = try clickRuntime.project(environment: bindingEnvironment(false), systemInput: initialInput, measure: bindingMeasure)
        t.equal(tapFixture.cpuCalls, 0, "CPU calls remain 0 before click")

        // Missed click:
        let missNeeded = clickRuntime.neededSystemProperties(clickAt: SkinPoint(x: -10, y: -10))
        t.equal(missNeeded, [])
        let missInput = missNeeded.isEmpty ? nil : ProgramSystemInput.sample(from: tapFixture, for: missNeeded)
        t.equal(missInput, nil)
        t.equal(tapFixture.cpuCalls, 0)

        // Valid click hit:
        let hitNeeded = clickRuntime.neededSystemProperties(clickAt: SkinPoint(x: 5, y: 5))
        t.equal(hitNeeded, [.cpuUsage])
        let hitInput = hitNeeded.isEmpty ? nil : ProgramSystemInput.sample(from: tapFixture, for: hitNeeded)
        t.equal(tapFixture.cpuCalls, 1)
        let clickedScene = try clickRuntime.click(at: SkinPoint(x: 5, y: 5), expectedGeneration: initialScene.generation,
                                                   environment: bindingEnvironment(false), systemInput: hitInput, measure: bindingMeasure)
        t.check(clickedScene != nil)
        t.equal(tapFixture.cpuCalls, 1, "exactly 1 CPU call after click")

        // 10. Hidden text with dynamic font size preserves layout space and measures without invalidText
        let hiddenDynamicFont = try checkedBindingProgram(t, #"widget { Text("Hidden").font(cpu.usage / 1%).hidden() }"#)
        var hiddenRuntime = try ProgramRuntime(program: hiddenDynamicFont)
        t.equal(hiddenRuntime.neededSystemProperties, [.cpuUsage], "hidden element text/font are layout dependencies to preserve space")
        let hiddenScene = try hiddenRuntime.project(environment: bindingEnvironment(false), systemInput: systemInput, measure: bindingMeasure)
        t.check(hiddenScene.size.width > 0)

        // 11. Computed dependency expands only when referenced
        let computedDependencyWidget = try checkedBindingProgram(t, #"widget { computed mem = "{memory.free, unit: .gib}"; Text(mem) }"#)
        let computedRuntime = try ProgramRuntime(program: computedDependencyWidget)
        t.equal(computedRuntime.neededSystemProperties, [.memoryFree])

        let unreferencedComputedWidget = try checkedBindingProgram(t, #"widget { computed unused = "{cpu.usage}%"; Text("Static") }"#)
        let unreferencedRuntime = try ProgramRuntime(program: unreferencedComputedWidget)
        t.equal(unreferencedRuntime.neededSystemProperties, [], "unreferenced computed declarations are not expanded")

        // 12. ProgramSystemSampler enforces independent cadences for mixed dependencies: CPU 1s, Memory 2s, Battery 60s, Static once
        let mixedNeeded: Set<ProgramSystemProperty> = [.cpuUsage, .cpuCoreCount, .memoryUsed, .memoryTotal, .batteryLevel, .batteryCharging]
        var sampler = ProgramSystemSampler()
        let samplerFixture = CountingSystemFixture()

        // T = 0.25: Non-integer instant start -> all needed sources sampled initially (bucket 0)
        let s0 = sampler.sample(from: samplerFixture, for: mixedNeeded, at: 0.25)
        t.equal(s0?.cpuUsage, 42.0)
        t.equal(s0?.cpuCoreCount, 8)
        t.equal(s0?.batteryLevel, 90.0)
        t.equal(s0?.batteryCharging, true)
        t.equal(samplerFixture.cpuCalls, 1)
        t.equal(samplerFixture.procCalls, 1)
        t.equal(samplerFixture.memCalls, 1)
        t.equal(samplerFixture.batteryCalls, 1)

        // T = 1.0: 1s integer wall-clock boundary -> CPU re-sampled (1s), memory/battery/proc NOT re-sampled
        let s1 = sampler.sample(from: samplerFixture, for: mixedNeeded, at: 1.0)
        t.equal(s1?.cpuUsage, 42.0)
        t.equal(s1?.cpuCoreCount, 8)
        t.equal(samplerFixture.cpuCalls, 2, "CPU sampled at 1s boundary even when started at 0.25s")
        t.equal(samplerFixture.procCalls, 1, "processorCount sampled once")
        t.equal(samplerFixture.memCalls, 1, "memory not sampled at 1s (needs 2s)")
        t.equal(samplerFixture.batteryCalls, 1, "battery not sampled at 1s (needs 60s)")

        // T = 2.0: 2s integer wall-clock boundary -> CPU (1s) and Memory (2s) re-sampled; battery/proc NOT re-sampled
        let s2 = sampler.sample(from: samplerFixture, for: mixedNeeded, at: 2.0)
        t.equal(s2?.cpuUsage, 42.0)
        t.equal(samplerFixture.cpuCalls, 3)
        t.equal(samplerFixture.procCalls, 1)
        t.equal(samplerFixture.memCalls, 2, "memory sampled at 2s boundary")
        t.equal(samplerFixture.batteryCalls, 1)

        // T = 60.0: 60s integer wall-clock boundary -> Battery re-sampled
        let s60 = sampler.sample(from: samplerFixture, for: mixedNeeded, at: 60.0)
        t.equal(s60?.batteryLevel, 90.0)
        t.equal(samplerFixture.cpuCalls, 4)
        t.equal(samplerFixture.memCalls, 3)
        t.equal(samplerFixture.batteryCalls, 2, "battery level sampled at 60s boundary")
        t.equal(samplerFixture.procCalls, 1, "processorCount remains once")

        // Positive time jump (e.g. forward 240s across sleep to T = 300.0)
        _ = sampler.sample(from: samplerFixture, for: mixedNeeded, at: 300.0)
        t.equal(samplerFixture.cpuCalls, 5, "CPU sampled after positive jump")
        t.equal(samplerFixture.memCalls, 4, "memory sampled after positive jump")
        t.equal(samplerFixture.batteryCalls, 3, "battery sampled after positive jump")
        t.equal(samplerFixture.procCalls, 1, "processorCount never re-read on jump")

        // Negative time jump (e.g. clock adjusted backwards from 300.0 to 10.0)
        _ = sampler.sample(from: samplerFixture, for: mixedNeeded, at: 10.0)
        t.equal(samplerFixture.cpuCalls, 6, "CPU re-sampled after negative jump")
        t.equal(samplerFixture.memCalls, 5, "memory re-sampled after negative jump")
        t.equal(samplerFixture.batteryCalls, 4, "battery re-sampled after negative jump")
        t.equal(samplerFixture.procCalls, 1, "processorCount remains once on negative jump")

        // Dynamic memory updates do NOT overwrite once-sampled memoryTotal
        samplerFixture.memTotal = 64 * 1024 * 1024 * 1024
        samplerFixture.memUsed = 20 * 1024 * 1024 * 1024
        let sMem = sampler.sample(from: samplerFixture, for: mixedNeeded, at: 12.0)
        t.equal(sMem?.memoryUsed, 20 * 1024 * 1024 * 1024)
        t.equal(sMem?.memoryTotal, 32 * 1024 * 1024 * 1024, "memoryTotal remains once-sampled value and is not overwritten by dynamic memory updates")

        // Power notification invalidates battery cache -> immediate re-sample
        sampler.invalidateBattery()
        _ = sampler.sample(from: samplerFixture, for: mixedNeeded, at: 12.5)
        t.equal(samplerFixture.batteryCalls, 5, "power invalidation causes immediate battery sample")
        t.equal(samplerFixture.cpuCalls, 7, "CPU not sampled at 12.5 (under 1s)")
        t.equal(samplerFixture.memCalls, 6, "Memory not sampled at 12.5 (under 2s)")

        // 13. Nil battery device with [.cpuUsage, .batteryCharging] does NOT poll battery every second
        let noBatFixture = CountingSystemFixture(hasBatteryDevice: false)
        var noBatSampler = ProgramSystemSampler()
        let noBatNeeded: Set<ProgramSystemProperty> = [.cpuUsage, .batteryCharging]

        let nb0 = noBatSampler.sample(from: noBatFixture, for: noBatNeeded, at: 0.25)
        t.equal(nb0?.batteryCharging, false)
        t.equal(noBatFixture.cpuCalls, 1)
        t.equal(noBatFixture.batteryCalls, 1, "initial observation of nil battery")

        _ = noBatSampler.sample(from: noBatFixture, for: noBatNeeded, at: 1.0)
        t.equal(noBatFixture.cpuCalls, 2)
        t.equal(noBatFixture.batteryCalls, 1, "nil battery is not re-polled on 1s CPU ticks")

        _ = noBatSampler.sample(from: noBatFixture, for: noBatNeeded, at: 2.0)
        t.equal(noBatFixture.cpuCalls, 3)
        t.equal(noBatFixture.batteryCalls, 1, "nil battery is still not re-polled at 2s")

        _ = noBatSampler.sample(from: noBatFixture, for: noBatNeeded, at: 60.0)
        t.equal(noBatFixture.cpuCalls, 4)
        t.equal(noBatFixture.batteryCalls, 1, "pure event battery is not polled at 60s")

        // Power change event invalidates nil battery cache and allows one re-sample
        noBatSampler.invalidateBattery()
        _ = noBatSampler.sample(from: noBatFixture, for: noBatNeeded, at: 60.5)
        t.equal(noBatFixture.batteryCalls, 2, "event invalidation allows one re-sample for battery")

        // 14. Once-properties with invalid initial values are observed once and not infinitely re-read
        let invalidStaticFixture = CountingSystemFixture(memTotal: -100, processorCount: 0)
        var invalidStaticSampler = ProgramSystemSampler()
        let staticNeeded: Set<ProgramSystemProperty> = [.cpuCoreCount, .memoryTotal]
        let is0 = invalidStaticSampler.sample(from: invalidStaticFixture, for: staticNeeded, at: 0.0)
        t.equal(is0?.cpuCoreCount, nil)
        t.equal(is0?.memoryTotal, nil)
        t.equal(invalidStaticFixture.procCalls, 1)
        t.equal(invalidStaticFixture.memCalls, 1)

        _ = invalidStaticSampler.sample(from: invalidStaticFixture, for: staticNeeded, at: 10.0)
        t.equal(invalidStaticFixture.procCalls, 1, "invalid coreCount is observed once and not infinitely re-read")
        t.equal(invalidStaticFixture.memCalls, 1, "invalid memoryTotal is observed once and not infinitely re-read")

        // 15. Invalid dynamic memory reading (used < 0) with valid total samples hardware once and preserves valid total
        let mixedMemFixture = CountingSystemFixture(memUsed: -1, memTotal: 32 * 1024 * 1024 * 1024)
        var mixedMemSampler = ProgramSystemSampler()
        let memNeeded: Set<ProgramSystemProperty> = [.memoryUsed, .memoryTotal]
        let mm0 = mixedMemSampler.sample(from: mixedMemFixture, for: memNeeded, at: 0.0)
        t.equal(mixedMemFixture.memCalls, 1, "hardware memory status read exactly once per projection turn")
        t.equal(mm0?.memoryUsed, nil, "invalid used memory (< 0) rejected")
        t.equal(mm0?.memoryTotal, 32 * 1024 * 1024 * 1024, "valid memoryTotal from same reading accepted")

        let mm1 = mixedMemSampler.sample(from: mixedMemFixture, for: memNeeded, at: 2.0)
        t.equal(mixedMemFixture.memCalls, 2, "dynamic memory re-sampled on 2s boundary")
        t.equal(mm1?.memoryTotal, 32 * 1024 * 1024 * 1024, "memoryTotal remains once-sampled value")

        // 16. Finite extreme time values do not trap on Int64 overflow and handle negative/large boundaries safely
        var extremeSampler = ProgramSystemSampler()
        let extremeFixture = CountingSystemFixture()
        let extremeNeeded: Set<ProgramSystemProperty> = [.cpuUsage]

        let sMax = extremeSampler.sample(from: extremeFixture, for: extremeNeeded, at: Double.greatestFiniteMagnitude)
        t.check(sMax != nil)
        t.equal(extremeFixture.cpuCalls, 1)

        let sNeg = extremeSampler.sample(from: extremeFixture, for: extremeNeeded, at: -1e20)
        t.check(sNeg != nil)
        t.equal(extremeFixture.cpuCalls, 2)
    }
}

private func runProgramClickEffectTests(_ t: TestRunner) {
    let point = SkinPoint(x: 6, y: 6)
    let environment = bindingEnvironment(false)
    let source = #"widget { variable n = 0; computed twice = n * 2; Text("{n}").size(80, 30).onClick { n = n + 1; copy("{twice}"); n = n + 1; open("https://example.com/?n={n}"); copy("{cpu.usage}%") } }"#
    let input = ProgramSystemInput(cpuUsage: 42)
    let expected: [ProgramEffect] = [.copy("2"), .open("https://example.com/?n=2"), .copy("42%")]

    t.suite("Desk: click effects: ordered arguments capture preceding assignments and computed values") {
        let program = try checkedBindingProgram(t, source)
        t.check(program.root.onClick == nil)
        t.equal(program.root.onClickActions?.count, 5)
        var runtime = try ProgramRuntime(program: program)
        t.equal(runtime.neededSystemProperties, [])
        let first = try runtime.project(environment: environment, measure: bindingMeasure)
        t.equal(bindingStrings(first), ["0"])
        t.equal(runtime.clockPrecision, nil)
        t.equal(runtime.neededSystemProperties(clickAt: point), [.cpuUsage])
        t.equal(runtime.neededSystemProperties(clickAt: SkinPoint(x: -1, y: 6)), [])
        guard let clicked = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
            environment: environment, systemInput: input, measure: bindingMeasure) else { throw BindingFixtureFailure.program }
        t.equal(clicked.effects, expected)
        t.equal(bindingStrings(clicked.scene), ["2"])
        t.equal(runtime.clockPrecision, nil, "action-only data does not schedule ongoing sampling")
        t.equal(runtime.neededSystemProperties, [])
        t.check(try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
            environment: environment, systemInput: input, measure: bindingMeasure) == nil)
        let next = try runtime.project(environment: environment, measure: bindingMeasure)
        t.equal(bindingStrings(next), ["2"], "redraw does not rerun user actions")

        let legacy = try checkedBindingProgram(t, #"widget { variable n = 0; Text("{n}").onClick { n = 1 } }"#)
        t.equal(legacy.root.onClick?.count, 1)
        t.check(legacy.root.onClickActions == nil)
        var old = try ProgramRuntime(program: legacy)
        let oldFirst = try old.project(environment: environment, measure: bindingMeasure)
        let oldNext = try old.click(at: point, expectedGeneration: oldFirst.generation,
                                   environment: environment, measure: bindingMeasure)
        t.equal(oldNext.map(bindingStrings), ["1"])
    }

    t.suite("Desk: click effects: failed projection and legacy calls commit no variables or effects") {
        let program = try checkedBindingProgram(t, source)
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: environment, measure: bindingMeasure)
        bindingFailure(t, .unhandledClickEffects) {
            _ = try runtime.click(at: point, expectedGeneration: first.generation,
                                  environment: environment, systemInput: input, measure: bindingMeasure)
        }
        t.equal(runtime.generation, first.generation)
        do {
            _ = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
                environment: environment, systemInput: input) { _, _, _ in throw BindingFixtureFailure.measurement }
            t.check(false, "measurement failure must not return an executable effect batch")
        } catch { t.equal(error as? BindingFixtureFailure, .measurement) }
        t.equal(runtime.generation, first.generation)
        for missed in [SkinPoint(x: -1, y: 6), SkinPoint(x: .nan, y: 6)] {
            t.check(try runtime.clickWithEffects(at: missed, expectedGeneration: first.generation,
                environment: environment, systemInput: input, measure: bindingMeasure) == nil)
        }
        guard let retried = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation,
            environment: environment, systemInput: input, measure: bindingMeasure) else { throw BindingFixtureFailure.program }
        t.equal(retried.effects, expected, "neither failed path applies the earlier increment")
        t.equal(bindingStrings(retried.scene), ["2"])

        let dateProgram = try checkedBindingProgram(t,
            #"widget { variable n = 0; Text("{n}").onClick { n = 1; copy("before"); open("{time.now, format: "HH:mm:ss"}") } }"#)
        var dated = try ProgramRuntime(program: dateProgram)
        let datedFirst = try dated.project(environment: environment, measure: bindingMeasure)
        bindingFailure(t, .invalidDateInput) {
            _ = try dated.clickWithEffects(at: point, expectedGeneration: datedFirst.generation,
                                          environment: environment, measure: bindingMeasure)
        }
        t.equal(dated.generation, datedFirst.generation)
        let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0),
                                   timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"))
        let recovered = try dated.clickWithEffects(at: point, expectedGeneration: datedFirst.generation,
            environment: environment, dateInput: date, measure: bindingMeasure)
        t.equal(recovered?.effects, [.copy("before"), .open("00:00:00")])
        t.equal(recovered.map { bindingStrings($0.scene) }, ["1"])
    }

    t.suite("Desk: click effects: direct programs retain strict strings shared limits and hidden hit rules") {
        let id = ElementID(name: "effect", index: 0)
        func element(_ actions: [ProgramAction], hidden: Bool = false) -> ProgramElement {
            ProgramElement(id: id, content: .text(ProgramText(value: .string("Tap"))),
                           width: .fixed(40), height: .fixed(30), hidden: hidden, onClickActions: actions)
        }
        let ambiguous = ProgramElement(id: id, content: .text(ProgramText(value: .string("Tap"))),
                                       onClick: [], onClickActions: [])
        bindingFailure(t, .ambiguousClickHandler(id)) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Ambiguous", root: ambiguous))
        }
        for value in [ProgramExpression.number(1), .boolean(true), .timeNow,
                      .string(String(repeating: "a", count: ProgramLimits.maximumTextLength + 1))] {
            for action in [ProgramAction.copy(value), .open(value)] {
                bindingFailure(t, .invalidExpression) {
                    _ = try ProgramRuntime(program: WidgetProgram(name: "Wrong argument", root: element([action])))
                }
            }
        }
        bindingFailure(t, .expressionLimit) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Too many actions",
                root: element(Array(repeating: .copy(.string("A")), count: ProgramLimits.maximumExpressions + 1))))
        }
        for root in [element([.copy(.string("hidden"))], hidden: true),
                     ProgramElement(id: ElementID(name: "parent", index: 1),
                         content: .column(spacing: 0, align: .left, children: [element([.open(.string("hidden"))])]),
                         hidden: true)] {
            var hidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden", root: root))
            let scene = try hidden.project(environment: environment, measure: bindingMeasure)
            t.equal(scene.hitMap.entries.count, 0)
            t.check(try hidden.clickWithEffects(at: point, expectedGeneration: scene.generation,
                environment: environment, measure: bindingMeasure) == nil)
        }
        var empty = try ProgramRuntime(program: WidgetProgram(name: "Empty handler", root: element([])))
        let scene = try empty.project(environment: environment, measure: bindingMeasure)
        let clicked = try empty.clickWithEffects(at: point, expectedGeneration: scene.generation,
                                                environment: environment, measure: bindingMeasure)
        t.check(clicked != nil)
        t.equal(clicked?.effects, [])
    }

    t.suite("Desk: click effects: catalog drift and unsupported action contexts refuse the complete program") {
        let changes: [(String, (inout FunctionSpec) -> Void)] = [
            ("kind", { $0.kind = .field }),
            ("user-only", { $0.userInitiatedOnly = false }),
            ("permission", { $0.permission = "music" }),
            ("pure", { $0.pure = true }),
            ("context", { $0.onlyInActions = false }),
            ("block", { $0.takesActionBlock = true }),
            ("arity", { $0.signatures[0].params.append($0.signatures[0].params[0]) }),
            ("type", { $0.signatures[0].params[0].type = .plainNumber }),
            ("label", { $0.signatures[0].params[0].label = "value" }),
            ("source", { $0.signatures[0].params[0].source = .literal }),
            ("optional", { $0.signatures[0].params[0].required = false }),
            ("variadic", { $0.signatures[0].params[0].variadic = true })
        ]
        for name in ["copy", "open"] {
            let checked = deskCheck("widget { Text(\"Tap\").onClick { \(name)(\"A\") } }")
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            guard let index = DeskCatalog.current.functions.firstIndex(where: { $0.name == name }) else {
                throw BindingFixtureFailure.program
            }
            for (label, change) in changes {
                var catalog = DeskCatalog.current
                change(&catalog.functions[index])
                let result = Desk.compile(checked, catalog: catalog)
                t.check(result.program == nil, "\(name) changed \(label)")
                t.equal(result.issues.first?.kind, .unsupported, "\(name) changed \(label)")
            }
            var catalog = DeskCatalog.current
            catalog.functions[index].signatures[0].params[0].role = name == "copy" ? .plain : .display
            t.equal(Desk.compile(checked, catalog: catalog).issues.first?.kind, .unsupported)
        }
        for source in [#"widget { Text("Tap").onLoad { copy("A") } }"#,
                       #"widget { Text("Tap").onClick { open(1) } }"#,
                       #"widget { Text("Tap").onClick { copy("A", "B") } }"#,
                       #"widget { Text("Tap").onDoubleClick { copy("A") } }"#,
                       #"widget { Text("Tap").onClick { log("A") } }"#] {
            t.check(Desk.compile(deskCheck(source)).program == nil, source)
        }
        let displayNumber = deskCheck(#"widget { Text("Tap").onClick { copy(42) } }"#)
        t.check(displayNumber.diagnostics(.error).isEmpty, deskDescribe(displayNumber))
        t.equal(Desk.compile(displayNumber).issues.first?.kind, .unsupported,
                "copy does not silently inherit display-value coercion")
    }
}

private final class CountingSystemFixture: SystemDataSource {
    var cpu: Double
    var procCalls: Int = 0
    var customProcessorCount: Int?
    var processorCount: Int { procCalls += 1; return customProcessorCount ?? 8 }
    var memUsed: Double
    var memTotal: Double
    var cpuCalls: Int = 0
    var memCalls: Int = 0
    var batteryCalls: Int = 0
    var hasBatteryDevice: Bool = true
    var customBattery: BatteryStatus?

    init(cpu: Double = 42.0, memUsed: Double = 16 * 1024 * 1024 * 1024, memTotal: Double = 32 * 1024 * 1024 * 1024,
         processorCount: Int? = nil, hasBatteryDevice: Bool = true) {
        self.cpu = cpu
        self.memUsed = memUsed
        self.memTotal = memTotal
        self.customProcessorCount = processorCount
        self.hasBatteryDevice = hasBatteryDevice
        if hasBatteryDevice {
            self.customBattery = BatteryStatus(percent: 90, isCharging: true, isPluggedIn: true)
        } else {
            self.customBattery = nil
        }
    }

    func cpuUsage(processor: Int) -> Double { cpuCalls += 1; return cpu }
    func memoryStatus() -> MemoryStatus { memCalls += 1; return MemoryStatus(physicalTotal: memTotal, physicalUsed: memUsed) }
    func networkInterfaces() -> [String] { [] }
    func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters() }
    func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
    func availableDiskSpace(path: String) -> Double? { nil }
    func uptime() -> TimeInterval { 120 }
    func battery() -> BatteryStatus? { batteryCalls += 1; return customBattery }
    func isProcessRunning(_ name: String) -> Bool { false }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
}
