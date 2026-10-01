import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum BindingFixtureFailure: Error { case program, measurement, assignment }

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
                     #"widget { variable x = false; Text("A").onClick { x = true } }"#,
                     #"widget { saved x = "A"; Text(x) }"#,
                     #"widget { Text(true) }"#, #"widget { Text(1) }"#,
                     #"widget { variable x = "A"; Text("{x}") }"#,
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
}
