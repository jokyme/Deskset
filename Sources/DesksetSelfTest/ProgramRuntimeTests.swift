import Foundation
@testable import DesksetCore

private func programEnvironment(_ appearance: SkinAppearance = .light, scale: Double = 1) -> EnvironmentStamp {
    EnvironmentStamp(scale: scale, fontGeneration: 7, appearance: AppearanceStamp(value: appearance, name: "fixture"), imageGeneration: 0)
}

private func programDraws(_ scene: WidgetScene) -> [TextDraw] {
    scene.drawingItems.compactMap { if case .text(let value) = $0 { return value }; return nil }
}

private func programFailure(_ t: TestRunner, _ expected: ProgramRuntimeError, _ body: () throws -> Void) {
    do { try body(); t.check(false, "expected \(expected)") }
    catch { t.equal(error as? ProgramRuntimeError, expected) }
}

func runProgramRuntimeTests(_ t: TestRunner) {
    t.suite("Program: static runtime: rigid nested stacks become independent scene values") {
        func text(_ name: String, _ index: Int) -> ProgramElement {
            ProgramElement(id: ElementID(name: name, index: index), content: .text(ProgramText(name)))
        }
        let row = ProgramElement(id: ElementID(name: "row", index: 2),
                                 content: .row(spacing: 4, align: .bottom, children: [text("B", 3), text("C", 4)]))
        let root = ProgramElement(id: ElementID(name: "root", index: 0),
                                  content: .column(spacing: 6, align: .center, children: [text("A", 1), row]),
                                  padding: SkinInsets(left: 3, top: 7, right: 5, bottom: 11))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Independent", root: root))
        let sizes = ["A": SkinSize(width: 10, height: 20), "B": SkinSize(width: 20, height: 8), "C": SkinSize(width: 3, height: 5)]
        var queries: [(String, TextStyle, Double?)] = []
        let scene = try runtime.project(environment: programEnvironment(.dark)) { text, style, width in
            queries.append((text, style, width)); return sizes[text]!
        }
        t.equal(scene.size, SkinSize(width: 35, height: 52))
        t.equal(scene.elements.map(\.id.index), [0, 1, 2, 3, 4])
        t.equal(scene.elements.map(\.frame), [SkinRect(width: 35, height: 52), SkinRect(x: 11.5, y: 7, width: 10, height: 20),
                                              SkinRect(x: 3, y: 33, width: 27, height: 8), SkinRect(x: 3, y: 33, width: 20, height: 8),
                                              SkinRect(x: 27, y: 36, width: 3, height: 5)])
        let draws = programDraws(scene)
        t.equal(draws.map(\.text), ["A", "B", "C"])
        t.equal(queries.count, 3)
        for i in draws.indices {
            t.equal(draws[i].style, queries[i].1)
            t.equal(queries[i].2, nil)
            t.equal(draws[i].style.color, SkinAppearance.dark.labelColor)
        }
        t.equal(scene.hitMap.width, 35); t.equal(scene.hitMap.height, 52)
        let next = try runtime.project(environment: programEnvironment(.dark, scale: 2)) { text, _, _ in sizes[text]! }
        t.equal(next.elements, scene.elements) // device scale does not change point coordinates
        t.equal(next.generation, 2); t.equal(scene.generation, 1)
        t.equal(next.environment.scale, 2)
    }

    t.suite("Program: static runtime: fixed text uses identical measured drawing style and wrapping width") {
        let id = ElementID(name: "wrapped", index: 0)
        let text = ProgramText("甲😀 wrap", fontSize: 12, color: .literal(RGBA(r: 12, g: 34, b: 56)))
        let root = ProgramElement(id: id, content: .text(text), width: .fixed(24), padding: SkinInsets(left: 2, right: 2))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Wrapped", root: root))
        var queries: [(TextStyle, Double?)] = []
        let scene = try runtime.project(environment: programEnvironment()) { _, style, width in
            queries.append((style, width))
            return width == nil ? SkinSize(width: 50, height: 10) : SkinSize(width: 20, height: 30)
        }
        let draw = programDraws(scene).first!
        t.equal(queries.count, 2); t.equal(queries[1].1, 20)
        t.equal(draw.style, queries[1].0)
        t.equal(draw.text, "甲😀 wrap"); t.equal(draw.contentFrame, SkinRect(x: 2, width: 20, height: 30))
        t.equal(scene.size, SkinSize(width: 24, height: 30))
        t.close(TextStyle.pixelSize(points: draw.style.fontSize), 12)
        t.check(draw.style.accurateText && draw.style.wrap && draw.style.antiAlias)
        t.equal(draw.style.color, RGBA(r: 12, g: 34, b: 56))
    }

    t.suite("Program: static runtime: hidden content keeps space and empty text is explicit") {
        let child = ProgramElement(id: ElementID(name: "text", index: 1), content: .text(ProgramText("A")))
        let root = ProgramElement(id: ElementID(name: "hidden", index: 0), content: .column(spacing: 8, align: .left, children: [child]), hidden: true)
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Hidden", root: root))
        let scene = try runtime.project(environment: programEnvironment()) { _, _, _ in SkinSize(width: 10, height: 20) }
        t.equal(scene.size, SkinSize(width: 10, height: 20))
        t.equal(scene.elements.map(\.visibility), [.hiddenKeepsSpace, .hiddenKeepsSpace])
        t.check(scene.drawingItems.isEmpty)
        t.equal(scene.elements[1].frame, SkinRect(width: 10, height: 20))
        let empty = ProgramElement(id: child.id, content: .text(ProgramText("")))
        var emptyRuntime = try ProgramRuntime(program: WidgetProgram(name: "Empty text", root: empty))
        let emptyScene = try emptyRuntime.project(environment: programEnvironment()) { text, _, _ in
            t.equal(text, ""); return SkinSize()
        }
        t.equal(emptyScene.size, SkinSize())
        t.equal(programDraws(emptyScene).map(\.text), [""]) // known empty literal, no claimed visible ink
        let noContent = ProgramElement(id: root.id, content: .column(spacing: 8, align: .center, children: []))
        programFailure(t, .emptyProgram) { _ = try ProgramRuntime(program: WidgetProgram(name: "No content", root: noContent)) }
    }

    t.suite("Program: static runtime: invalid measurements never publish a generation") {
        let id = ElementID(name: "text", index: 0)
        let root = ProgramElement(id: id, content: .text(ProgramText("A")))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Bad measures", root: root))
        for size in [SkinSize(width: .nan, height: 10), SkinSize(width: 1, height: .infinity),
                     SkinSize(width: -1, height: 10), SkinSize(width: 1, height: -1), SkinSize()] {
            programFailure(t, .invalidMeasurement(id)) { _ = try runtime.project(environment: programEnvironment()) { _, _, _ in size } }
            t.equal(runtime.generation, 0)
        }
        programFailure(t, .invalidEnvironment) { _ = try runtime.project(environment: programEnvironment(scale: .nan)) { _, _, _ in SkinSize(width: 1, height: 10) } }
        let scene = try runtime.project(environment: programEnvironment()) { _, _, _ in SkinSize(width: 1, height: 10) }
        t.equal(scene.generation, 1)
        var overflowing = try ProgramRuntime(program: WidgetProgram(name: "Too short", root:
            ProgramElement(id: id, content: .text(ProgramText("A")), height: .fixed(2))))
        programFailure(t, .layoutOverflow(id)) { _ = try overflowing.project(environment: programEnvironment()) { _, _, _ in SkinSize(width: 1, height: 10) } }
        t.equal(overflowing.generation, 0)
    }

    t.suite("Program: static runtime: direct program geometry identities and budgets are checked") {
        let id = ElementID(name: "root", index: 0)
        let text = ProgramElement(id: id, content: .text(ProgramText("A")))
        for length in [Double.nan, .infinity, -1] {
            let bad = ProgramElement(id: id, content: text.content, width: .fixed(length))
            programFailure(t, .invalidGeometry(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Bad", root: bad)) }
        }
        let badText = ProgramElement(id: id, content: .text(ProgramText("A", fontSize: .infinity)))
        programFailure(t, .invalidText(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Bad font", root: badText)) }
        let duplicate = ProgramElement(id: id, content: .column(spacing: 0, align: .left, children: [text]))
        programFailure(t, .duplicateIdentity(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Duplicate", root: duplicate)) }
        var deep = ProgramElement(id: ElementID(name: "leaf", index: 63), content: text.content)
        for index in (0..<63).reversed() {
            deep = ProgramElement(id: ElementID(name: "stack", index: index), content: .column(spacing: 0, align: .left, children: [deep]))
        }
        _ = try ProgramRuntime(program: WidgetProgram(name: "64 levels", root: deep))
        t.check(true)
        let tooDeep = ProgramElement(id: ElementID(name: "extra", index: 64), content: .column(spacing: 0, align: .left, children: [deep]))
        programFailure(t, .depthLimit) { _ = try ProgramRuntime(program: WidgetProgram(name: "65 levels", root: tooDeep)) }
        let children = (1...ProgramLimits.maximumElements).map { ProgramElement(id: ElementID(name: "child", index: $0), content: text.content) }
        let tooMany = ProgramElement(id: id, content: .column(spacing: 0, align: .left, children: children))
        programFailure(t, .elementLimit) { _ = try ProgramRuntime(program: WidgetProgram(name: "Too many", root: tooMany)) }
        let big = ProgramElement(id: ElementID(name: "big", index: 1), content: text.content)
        let huge = ProgramElement(id: id, content: .row(spacing: 0, align: .top, children: [big,
            ProgramElement(id: ElementID(name: "big", index: 2), content: text.content)]))
        var hugeRuntime = try ProgramRuntime(program: WidgetProgram(name: "Finite overflow", root: huge))
        programFailure(t, .layoutOverflow(id)) {
            _ = try hugeRuntime.project(environment: programEnvironment()) { _, _, _ in SkinSize(width: Double.greatestFiniteMagnitude, height: 10) }
        }
        t.equal(hugeRuntime.generation, 0)
    }
}
