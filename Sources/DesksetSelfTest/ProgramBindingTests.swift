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
    runProgramNumericTests(t)
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
        let cases = [#"widget { variable x = "A"; Text(x).onWake { x = "B" } }"#,
                     #"widget { variable x = false; Text("A").onDoubleClick { x = true } }"#,
                     #"widget { saved x = "A"; Text(x) }"#,
                     #"widget { Text(true) }"#, #"widget { Text(1%) }"#,
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
                       #"widget { Column { Text("{time.now}"); Text("{cpu.usage}%") } }"#]
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
        let sources = [#"widget { Text(1%) }"#, #"widget { Text(1KB) }"#, #"widget { Text(2s / 1s) }"#,
                       #"widget { variable n = 1%; Text("{n}") }"#, #"widget { Text(cpu.usage) }"#,
                       #"widget { Text("{time.now < time.now}") }"#,
                       #"widget { Text(2KB / 1B) }"#, #"widget { Text(100% / 50%) }"#,
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
