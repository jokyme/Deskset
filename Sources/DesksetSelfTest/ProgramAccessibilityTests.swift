import Foundation
@testable import DesksetCore

func runProgramAccessibilityTests(_ t: TestRunner) {
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "accessibility"), imageGeneration: 0)
    let dark = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .dark, name: "accessibility-dark"), imageGeneration: 0)
    let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0),
        timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"))
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, _, _ in
        SkinSize(width: Double(text.utf16.count) * 7, height: 14)
    }
    func id(_ index: Int) -> ElementID { ElementID(name: "accessibility-\(index)", index: index) }
    func box(_ label: ProgramExpression?, index: Int = 0, hidden: Bool = false,
             actions: [ProgramAction]? = nil) -> ProgramElement {
        ProgramElement(id: id(index), content: .rectangle(fill: .literal(.white)),
            width: .fixed(40), height: .fixed(30), hidden: hidden, onClickActions: actions, voiceOver: label)
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }

    t.suite("Program: accessibility: every supported box carries its own label without changing layout or measurement") {
        func program(labels: Bool) -> WidgetProgram {
            func label(_ value: String) -> ProgramExpression? { labels ? .string(value) : nil }
            let children: [ProgramElement] = [
                ProgramElement(id: id(1), content: .text(ProgramText("Painted text")), voiceOver: label("Spoken text")),
                ProgramElement(id: id(2), content: .image(ProgramImage(source: "picture")), voiceOver: label("Picture")),
                ProgramElement(id: id(3), content: .progress(ProgramProgress(value: .number(0.5))),
                    width: .fixed(30), height: .fixed(6), voiceOver: label("Progress")),
                ProgramElement(id: id(4), content: .gauge(ProgramGauge(value: .number(0.5))),
                    width: .fixed(30), height: .fixed(30), voiceOver: label("Gauge")),
                ProgramElement(id: id(5), content: .spacer(minimum: 2), voiceOver: label("Spacer")),
                ProgramElement(id: id(6), content: .rectangle(fill: .literal(.white)),
                    width: .fixed(10), height: .fixed(12), voiceOver: label("Rectangle")),
                ProgramElement(id: id(7), content: .shape(kind: .circle, fill: .literal(.white)),
                    width: .fixed(10), height: .fixed(12), voiceOver: label("Circle")),
                ProgramElement(id: id(8), content: .row(spacing: 0, align: .center, children: []), voiceOver: label("Row")),
                ProgramElement(id: id(9), content: .freeform(align: .center, children: []), voiceOver: label("Freeform")),
                box(nil, index: 10),
                box(label(""), index: 11)
            ]
            return WidgetProgram(name: "Labels", root: ProgramElement(id: id(0),
                content: .column(spacing: 3, align: .left, children: children), voiceOver: label("Column")))
        }
        let resource = ProgramImageResource(path: "/fixture/accessibility.png", naturalSize: SkinSize(width: 8, height: 10),
            stamp: ImageStamp(seconds: 1, nanoseconds: 0, size: 12, inode: 3))
        var baseline = try ProgramRuntime(program: program(labels: false))
        var labeled = try ProgramRuntime(program: program(labels: true))
        var baselineMeasured: [String] = [], labeledMeasured: [String] = []
        let before = try baseline.project(environment: environment, images: ["picture": resource]) { text, style, width in
            baselineMeasured.append(text); return try measure(text, style, width)
        }
        let after = try labeled.project(environment: environment, images: ["picture": resource]) { text, style, width in
            labeledMeasured.append(text); return try measure(text, style, width)
        }
        let expected: [String?] = ["Column", "Spoken text", "Picture", "Progress", "Gauge", "Spacer", "Rectangle", "Circle", "Row", "Freeform", nil, ""]
        t.equal(after.elements.map(\.accessibilityLabel), expected)
        t.check(before.elements.allSatisfy { $0.accessibilityLabel == nil })
        t.equal(before.size, after.size); t.equal(before.elements.map(\.frame), after.elements.map(\.frame))
        t.equal(before.elements.map(\.kind), after.elements.map(\.kind))
        t.equal(before.elements.map { $0.items.count }, after.elements.map { $0.items.count })
        t.equal(baselineMeasured, labeledMeasured); t.check(!labeledMeasured.isEmpty)
        t.check(labeledMeasured.allSatisfy { $0 == "Painted text" }, "accessibility labels never enter text measurement")
        t.equal(labeled.clockPrecision, nil); t.equal(labeled.neededSystemProperties, [])
        let legacy = SceneElement(id: id(0), kind: .shape, frame: SkinRect(), anchor: SkinPoint(), visibility: .visible,
            container: nil, isContainer: false, items: [], glass: nil, imageDependencies: [])
        t.equal(legacy.accessibilityLabel, nil); t.equal(box(nil).voiceOver, nil)
    }

    t.suite("Program: accessibility: live formatted values and typed missing use the projection locale and cadence") {
        let label = ProgramExpression.concatenate([
            .string("CPU "), .formatNumber(.systemProperty(.cpuUsage), ProgramNumberFormat(decimals: 1)),
            .string("; minutes "), .formatNumber(.divide(.systemProperty(.batteryTimeRemaining),
                .quantity(ProgramNumber(60, dimension: .duration))), ProgramNumberFormat(decimals: 1))])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Live label", root: box(label)))
        t.equal(runtime.neededSystemProperties, [.cpuUsage, .batteryTimeRemaining])
        let first = try runtime.project(environment: environment, dateInput: date,
            systemInput: ProgramSystemInput(cpuUsage: 12.5, batteryTimeRemaining: 90), measure: measure)
        t.equal(first.elements[0].accessibilityLabel, "CPU 12.5; minutes 1.5")
        t.equal(runtime.clockPrecision, .second)
        let german = ProgramDateInput(instant: date.instant, timeZone: date.timeZone, locale: Locale(identifier: "de_DE"))
        let localized = try runtime.project(environment: environment, dateInput: german,
            systemInput: ProgramSystemInput(cpuUsage: 12.5, batteryTimeRemaining: 90), measure: measure)
        t.equal(localized.elements[0].accessibilityLabel, "CPU 12,5; minutes 1,5")
        for input in [ProgramSystemInput(), ProgramSystemInput(cpuUsage: .nan, batteryTimeRemaining: -1),
                      ProgramSystemInput(cpuUsage: .infinity, batteryTimeRemaining: Double(Int64.max))] {
            let missing = try runtime.project(environment: environment, dateInput: date, systemInput: input, measure: measure)
            t.equal(missing.elements[0].accessibilityLabel, "CPU –; minutes –")
            t.equal(missing.elements[0].frame, first.elements[0].frame)
            t.equal(runtime.clockPrecision, .second, "missing live data retains its recovery cadence")
        }
        t.equal(first.elements[0].accessibilityLabel, "CPU 12.5; minutes 1.5", "previous scenes remain immutable")
    }

    t.suite("Program: accessibility: declaration dependencies freeze variables and retain only visible computed labels") {
        let declarations = [
            ProgramDeclaration(name: "frozen", kind: .variable, initial: .systemProperty(.cpuUsage)),
            ProgramDeclaration(name: "live", kind: .computed, initial: .formatNumber(.divide(.systemProperty(.batteryTimeRemaining),
                .quantity(ProgramNumber(60, dimension: .duration))), ProgramNumberFormat(decimals: 0))),
            ProgramDeclaration(name: "hidden", kind: .computed, initial: .concatenate([.systemProperty(.memoryUsed)]))
        ]
        let label = ProgramExpression.concatenate([.formatNumber(.declaration(0), ProgramNumberFormat(decimals: 0)),
            .string("|"), .declaration(1)])
        let root = ProgramElement(id: id(2), content: .column(spacing: 0, align: .left, children: [
            box(label), box(.declaration(2), index: 1, hidden: true)]))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Declaration labels", root: root, declarations: declarations))
        t.equal(runtime.neededSystemProperties, [.cpuUsage, .batteryTimeRemaining])
        let first = try runtime.project(environment: environment, dateInput: date,
            systemInput: ProgramSystemInput(cpuUsage: 25, batteryTimeRemaining: 120), measure: measure)
        t.equal(first.elements[1].accessibilityLabel, "25|2"); t.equal(first.elements[2].accessibilityLabel, nil)
        t.equal(runtime.neededSystemProperties, [.batteryTimeRemaining]); t.equal(runtime.clockPrecision, .minute)
        let next = try runtime.project(environment: environment, dateInput: date,
            systemInput: ProgramSystemInput(cpuUsage: 90, batteryTimeRemaining: 180), measure: measure)
        t.equal(next.elements[1].accessibilityLabel, "25|3"); t.equal(runtime.clockPrecision, .minute)
    }

    t.suite("Program: accessibility: inherited hiding skips labels while lazy visible labels control the clock") {
        let live = ProgramExpression.concatenate([.formatDate(.timeNow, .pattern("HH:mm:ss")),
            .string(" "), .systemProperty(.cpuUsage)])
        let hiddenParent = ProgramElement(id: id(1), content: .row(spacing: 0, align: .center,
            children: [box(live, index: 2)]), hidden: true, voiceOver: live)
        let root = ProgramElement(id: id(0), content: .column(spacing: 0, align: .left,
            children: [hiddenParent, box(live, index: 3, hidden: true)]), voiceOver: .string("Visible group"))
        var hidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden labels", root: root))
        t.equal(hidden.neededSystemProperties, [])
        let scene = try hidden.project(environment: environment, measure: measure)
        t.equal(scene.elements.map(\.accessibilityLabel), ["Visible group", nil, nil, nil])
        t.check(scene.elements.dropFirst().allSatisfy { $0.visibility == .hiddenKeepsSpace })
        t.equal(scene.elements[2].frame.width, 40); t.equal(scene.elements[2].frame.height, 30)
        t.equal(hidden.clockPrecision, nil, "no date input is needed by hidden labels")

        let conditional = ProgramExpression.conditional(.appearanceDark,
            then: .formatDate(.timeNow, .pattern("HH:mm:ss")), otherwise: .string(""))
        var visible = try ProgramRuntime(program: WidgetProgram(name: "Lazy label", root: box(conditional)))
        t.equal(try visible.project(environment: environment, measure: measure).elements[0].accessibilityLabel, "")
        t.equal(visible.clockPrecision, nil)
        t.equal(try visible.project(environment: dark, dateInput: date, measure: measure).elements[0].accessibilityLabel, "00:00:00")
        t.equal(visible.clockPrecision, .second)
        t.equal(try visible.project(environment: environment, measure: measure).elements[0].accessibilityLabel, "")
        t.equal(visible.clockPrecision, nil, "an inactive label branch releases its previous timer demand")
    }

    t.suite("Program: accessibility: all labels share type length depth and expression budgets including hidden labels") {
        let invalid: [ProgramExpression] = [.number(1), .boolean(true), .timeNow,
            .conditional(.boolean(false), then: .number(1), otherwise: .string("valid branch")),
            .string(String(repeating: "x", count: ProgramLimits.maximumTextLength + 1))]
        for hidden in [false, true] {
            for value in invalid {
                failure(.invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid label", root: box(value, hidden: hidden))) }
            }
            failure(.invalidDeclaration(9)) {
                _ = try ProgramRuntime(program: WidgetProgram(name: "Unknown declaration", root: box(.declaration(9), hidden: hidden)))
            }
        }
        var deep = ProgramExpression.string("label")
        for _ in 0..<ProgramLimits.maximumExpressionDepth { deep = .concatenate([deep]) }
        failure(.expressionDepth) { _ = try ProgramRuntime(program: WidgetProgram(name: "Deep label", root: box(deep, hidden: true))) }
        func budget(_ count: Int) -> WidgetProgram {
            WidgetProgram(name: "Shared budget", root: ProgramElement(id: id(0),
                content: .text(ProgramText(value: .concatenate(Array(repeating: .string("a"), count: count)))),
                hidden: true, voiceOver: .string("label")))
        }
        _ = try ProgramRuntime(program: budget(ProgramLimits.maximumExpressions - 2))
        failure(.expressionLimit) { _ = try ProgramRuntime(program: budget(ProgramLimits.maximumExpressions - 1)) }
        let oversized = ProgramExpression.concatenate([
            .string(String(repeating: "x", count: ProgramLimits.maximumTextLength)), .string("x")])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Expanded label", root: box(oversized)))
        failure(.invalidExpression) { _ = try runtime.project(environment: environment, measure: measure) }
        t.equal(runtime.generation, 0); t.equal(runtime.clockPrecision, nil)
        var hidden = try ProgramRuntime(program: WidgetProgram(name: "Unresolved hidden label", root: box(oversized, hidden: true)))
        t.equal(try hidden.project(environment: environment, measure: measure).elements[0].accessibilityLabel, nil)
    }

    t.suite("Program: accessibility: failed label projection rolls back actions effects generation and hit state") {
        let label = ProgramExpression.concatenate([.declaration(0), .string(" "), .formatDate(.timeNow, .pattern("HH:mm"))])
        let actions: [ProgramAction] = [.assign(ProgramAssignment(declaration: 0, value: .string("new"))), .copy(.declaration(0))]
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Label transaction", root: box(label, actions: actions),
            declarations: [ProgramDeclaration(name: "caption", kind: .variable, initial: .string("old"))]))
        let first = try runtime.project(environment: environment, dateInput: date, measure: measure)
        t.equal(first.elements[0].accessibilityLabel, "old 00:00"); t.equal(runtime.clockPrecision, .minute)
        failure(.invalidDateInput) {
            _ = try runtime.clickWithEffects(at: SkinPoint(x: 2, y: 2), expectedGeneration: first.generation,
                environment: environment, measure: measure)
        }
        t.equal(runtime.generation, first.generation); t.equal(runtime.clockPrecision, .minute)
        let recovered = try runtime.project(environment: environment, dateInput: date, measure: measure)
        t.equal(recovered.elements[0].accessibilityLabel, "old 00:00")
        t.equal(recovered.hitMap, first.hitMap)
        let changed = try runtime.clickWithEffects(at: SkinPoint(x: 2, y: 2), expectedGeneration: recovered.generation,
            environment: environment, dateInput: date, measure: measure)
        t.equal(changed?.effects, [.copy("new")]); t.equal(changed?.scene.elements[0].accessibilityLabel, "new 00:00")
        t.equal(first.elements[0].accessibilityLabel, "old 00:00")
        t.check(try runtime.clickWithEffects(at: SkinPoint(x: 2, y: 2), expectedGeneration: first.generation,
            environment: environment, dateInput: date, measure: measure) == nil)
    }

    t.suite("Program: accessibility: Freeform negative coordinates and preset fit transform frames while retaining labels") {
        let child = ProgramElement(id: id(1), content: .rectangle(fill: .literal(.white)),
            width: .fixed(200), height: .fixed(200), cornerRadius: .points(20), onClickActions: [.copy(.string("child"))],
            position: ProgramPosition(x: -100, y: -100), background: .glass(style: .clear), voiceOver: .string("Child label"))
        let root = ProgramElement(id: id(0), content: .freeform(align: .topLeft, children: [child]),
            width: .fixed(100), height: .fixed(100), background: .color(.literal(.black)), voiceOver: .string("Group label"))
        var fit = try ProgramRuntime(program: WidgetProgram(name: "Negative label", root: root))
        let raw = try fit.project(environment: environment, measure: measure)
        t.equal(raw.elements[1].frame, SkinRect(x: -100, y: -100, width: 200, height: 200))
        var preset = try ProgramRuntime(program: WidgetProgram(name: "Preset label", root: root,
            size: .preset(.small, size: SkinSize(width: 100, height: 100))))
        let scene = try preset.project(environment: environment, measure: measure)
        t.equal(scene.elements.map(\.accessibilityLabel), ["Group label", "Child label"])
        t.equal(scene.elements.map(\.accessibilityLabel), raw.elements.map(\.accessibilityLabel))
        t.equal(scene.elements[0].frame, SkinRect(x: 50, y: 50, width: 50, height: 50))
        t.equal(scene.elements[1].frame, SkinRect(width: 100, height: 100))
        t.equal(scene.elements[1].glass?.rect, scene.elements[1].frame)
        t.equal(scene.elements[1].glass?.cornerRadius, 10)
        t.equal(scene.hitMap.entry(at: 2, 50, handling: .leftUp, images: nil)?.elementID, id(1))
        t.equal(scene.hitMap.entry(at: 0, 0, handling: .leftUp, images: nil)?.elementID, nil)
        let clicked = try preset.clickWithEffects(at: SkinPoint(x: 2, y: 50), expectedGeneration: scene.generation,
            environment: environment, measure: measure)
        t.equal(clicked?.effects, [.copy("child")])
        t.equal(clicked?.scene.elements.map(\.accessibilityLabel), ["Group label", "Child label"])
        t.equal(clicked?.scene.elements.map(\.frame), scene.elements.map(\.frame))
    }
}
