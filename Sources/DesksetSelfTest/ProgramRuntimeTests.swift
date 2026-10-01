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

    t.suite("Program: rectangles: solid content uses fixed border boxes without text measurement") {
        let id = ElementID(name: "paint", index: 0)
        let root = ProgramElement(id: id, content: .rectangle(fill: .text), width: .fixed(24), height: .fixed(18),
                                  padding: SkinInsets(left: 2, top: 3, right: 4, bottom: 5))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Rectangle only", root: root))
        var queries = 0
        for (appearance, scale) in [(SkinAppearance.light, 1.0), (.dark, 2.0)] {
            let scene = try runtime.project(environment: programEnvironment(appearance, scale: scale)) { _, _, _ in
                queries += 1; throw ProgramRuntimeError.invalidMeasurement(id)
            }
            t.equal(scene.size, SkinSize(width: 24, height: 18))
            t.equal(scene.elements.map(\.id), [id])
            t.equal(scene.elements[0].kind, .shape)
            t.equal(scene.elements[0].frame, SkinRect(width: 24, height: 18))
            t.equal(scene.drawingItems, [.fill(SkinRect(x: 2, y: 3, width: 18, height: 10), Paint(color: appearance.labelColor))])
            t.check(scene.elements[0].imageDependencies.isEmpty && scene.glass.isEmpty)
        }
        t.equal(queries, 0); t.equal(runtime.generation, 2)
    }

    t.suite("Program: rectangles: mixed order hidden and zero area retain their original layout") {
        let color = RGBA(r: 18, g: 52, b: 86, a: 128)
        let rect = ProgramElement(id: ElementID(name: "rect", index: 1), content: .rectangle(fill: .literal(color)),
                                  width: .fixed(12), height: .fixed(8), padding: SkinInsets(left: 2, top: 2, right: 2, bottom: 2))
        let text = ProgramElement(id: ElementID(name: "text", index: 2), content: .text(ProgramText("A")))
        let hidden = ProgramElement(id: ElementID(name: "hidden", index: 3), content: .rectangle(fill: .accent),
                                    width: .fixed(6), height: .fixed(4), hidden: true)
        let root = ProgramElement(id: ElementID(name: "row", index: 0),
                                  content: .row(spacing: 4, align: .bottom, children: [rect, text, hidden]),
                                  padding: SkinInsets(left: 3, top: 5, right: 7, bottom: 1))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Mixed", root: root))
        var queries = 0
        let scene = try runtime.project(environment: programEnvironment()) { value, _, _ in
            queries += 1; t.equal(value, "A"); return SkinSize(width: 5, height: 10)
        }
        t.equal(queries, 1)
        t.equal(scene.size, SkinSize(width: 41, height: 16))
        t.equal(scene.elements.map(\.id.index), [0, 1, 2, 3])
        t.equal(scene.elements.map(\.frame), [SkinRect(width: 41, height: 16), SkinRect(x: 3, y: 7, width: 12, height: 8),
                                              SkinRect(x: 19, y: 5, width: 5, height: 10), SkinRect(x: 28, y: 11, width: 6, height: 4)])
        t.equal(scene.drawingItems.first, .fill(SkinRect(x: 5, y: 9, width: 8, height: 4), Paint(color: color)))
        t.equal(programDraws(scene).map(\.text), ["A"])
        t.equal(scene.drawingItems.count, 2)
        t.equal(scene.elements[3].visibility, .hiddenKeepsSpace)
        for (width, height, fill) in [(0.0, 8.0, ProgramColor.accent), (8.0, 0.0, .accent), (8.0, 8.0, .literal(.clear))] {
            var empty = try ProgramRuntime(program: WidgetProgram(name: "Empty paint", root:
                ProgramElement(id: rect.id, content: .rectangle(fill: fill), width: .fixed(width), height: .fixed(height))))
            let blank = try empty.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(rect.id) }
            t.equal(blank.size, SkinSize(width: width, height: height))
            if width == 0 || height == 0 { t.check(blank.drawingItems.isEmpty) }
            else { t.equal(blank.drawingItems, [.fill(SkinRect(width: 8, height: 8), Paint(color: .clear))]) }
        }
        var hiddenRuntime = try ProgramRuntime(program: WidgetProgram(name: "Hidden parent", root:
            ProgramElement(id: root.id, content: root.content, padding: root.padding, hidden: true)))
        let invisible = try hiddenRuntime.project(environment: programEnvironment()) { _, _, _ in SkinSize(width: 5, height: 10) }
        t.equal(invisible.size, scene.size)
        t.check(invisible.drawingItems.isEmpty)
    }

    t.suite("Program: rectangles: direct producers reject invalid paint geometry and overflow transactionally") {
        let id = ElementID(name: "rect", index: 0)
        for (width, height) in [(ProgramLength.fit, ProgramLength.fixed(8)), (.fixed(8), .fit),
                                (.fixed(.nan), .fixed(8)), (.fixed(8), .fixed(.infinity)), (.fixed(-1), .fixed(8))] {
            let root = ProgramElement(id: id, content: .rectangle(fill: .accent), width: width, height: height)
            programFailure(t, .invalidGeometry(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Bad box", root: root)) }
        }
        for color in [RGBA(r: .nan, g: 0, b: 0), RGBA(r: 0, g: .infinity, b: 0), RGBA(r: -1, g: 0, b: 0),
                      RGBA(r: 0, g: 0, b: 256), RGBA(r: 0, g: 0, b: 0, a: -1), RGBA(r: 0, g: 0, b: 0, a: 256)] {
            let root = ProgramElement(id: id, content: .rectangle(fill: .literal(color)), width: .fixed(8), height: .fixed(8))
            programFailure(t, .invalidPaint(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Bad color", root: root)) }
        }
        let short = ProgramElement(id: id, content: .rectangle(fill: .accent), width: .fixed(10), height: .fixed(8),
                                   padding: SkinInsets(left: 5, right: 6))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Too much padding", root: short))
        programFailure(t, .layoutOverflow(id)) { _ = try runtime.project(environment: programEnvironment()) { _, _, _ in SkinSize() } }
        t.equal(runtime.generation, 0)
        let huge = (1...2).map { index in
            ProgramElement(id: ElementID(name: "huge", index: index), content: .rectangle(fill: .accent),
                           width: .fixed(Double.greatestFiniteMagnitude), height: .fixed(8))
        }
        var overflowing = try ProgramRuntime(program: WidgetProgram(name: "Overflow", root:
            ProgramElement(id: id, content: .row(spacing: 0, align: .top, children: huge))))
        programFailure(t, .layoutOverflow(id)) { _ = try overflowing.project(environment: programEnvironment()) { _, _, _ in SkinSize() } }
        t.equal(overflowing.generation, 0)
    }
}
