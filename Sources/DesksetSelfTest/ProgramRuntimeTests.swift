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
    runProgramFreeformTests(t)
    runProgramPaletteTests(t)
    runProgramPointerTests(t)
    func rectangle(_ index: Int, width: ProgramLength = .fill, height: ProgramLength = .fill,
                   minWidth: Double = 0, maxWidth: Double? = nil, minHeight: Double = 0, maxHeight: Double? = nil,
                   ideal: SkinSize = SkinSize(width: 10, height: 10), hidden: Bool = false) -> ProgramElement {
        ProgramElement(id: ElementID(name: "rect", index: index), content: .rectangle(fill: .accent), width: width, height: height,
                       hidden: hidden, minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight, idealSize: ideal)
    }
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

    t.suite("Program: flex layout: unspecified ideals cross filling and fixed boxes use point proposals") {
        var ideal = try ProgramRuntime(program: WidgetProgram(name: "Producer ideal", root: rectangle(0, ideal: SkinSize(width: 13, height: 7))))
        let original = try ideal.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(ElementID(name: "rect", index: 0)) }
        t.equal(original.size, SkinSize(width: 13, height: 7))
        let root = ProgramElement(id: ElementID(name: "column", index: 0),
                                  content: .column(spacing: 4, align: .right, children: [rectangle(1, height: .fixed(6)),
                                      rectangle(2, width: .fit, height: .fixed(8), ideal: SkinSize(width: 12, height: 10))]),
                                  width: .fixed(40), padding: SkinInsets(left: 2, top: 2, right: 2, bottom: 2))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Cross fill", root: root))
        for scale in [1.0, 2.0] {
            let scene = try runtime.project(environment: programEnvironment(scale: scale)) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(root.id) }
            t.equal(scene.size, SkinSize(width: 40, height: 22))
            t.equal(scene.elements.map(\.frame), [SkinRect(width: 40, height: 22), SkinRect(x: 2, y: 2, width: 36, height: 6),
                                                  SkinRect(x: 26, y: 12, width: 12, height: 8)])
            t.equal(scene.drawingItems, [.fill(SkinRect(x: 2, y: 2, width: 36, height: 6), Paint(color: SkinAppearance.light.accentColor)),
                                         .fill(SkinRect(x: 26, y: 12, width: 12, height: 8), Paint(color: SkinAppearance.light.accentColor))])
        }
    }

    t.suite("Program: flex layout: minimum equal shares caps and redistribution work on both axes") {
        for column in [true, false] {
            for (extent, caps, sizes) in [(100.0, [Double?(15), 30, nil], [15.0, 30, 47]),
                                         (73.0, [nil, nil, nil], [20.0, 30, 15]),
                                         (100.0, [Double?(15), 30, 20], [15.0, 30, 20])] {
                let minima = [10.0, 20, 5]
                let children = (0..<3).map { i in
                    rectangle(i + 1, minWidth: column ? 0 : minima[i], maxWidth: column ? nil : caps[i],
                              minHeight: column ? minima[i] : 0, maxHeight: column ? caps[i] : nil)
                }
                let content: ProgramElement.Content = column ? .column(spacing: 4, align: .left, children: children)
                    : .row(spacing: 4, align: .top, children: children)
                let root = ProgramElement(id: ElementID(name: "root", index: 0), content: content,
                                          width: .fixed(column ? 20 : extent), height: .fixed(column ? extent : 20))
                var runtime = try ProgramRuntime(program: WidgetProgram(name: "Waterfill", root: root))
                let scene = try runtime.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(root.id) }
                t.equal(scene.size, SkinSize(width: column ? 20 : extent, height: column ? extent : 20))
                t.equal(scene.elements.dropFirst().map { column ? $0.frame.height : $0.frame.width }, sizes)
                t.equal(scene.elements.dropFirst().map { column ? $0.frame.y : $0.frame.x }, [0, sizes[0] + 4, sizes[0] + sizes[1] + 8])
                t.equal(scene.elements.dropFirst().map { column ? $0.frame.width : $0.frame.height }, [20, 20, 20])
                t.equal(scene.drawingItems.count, 3)
            }
        }
    }

    t.suite("Program: flex layout: nested fit containers keep rigid minima while propagating flexibility") {
        let a = ProgramElement(id: ElementID(name: "A", index: 1), content: .text(ProgramText("A")))
        let b = ProgramElement(id: ElementID(name: "B", index: 3), content: .text(ProgramText("B")))
        let nested = ProgramElement(id: ElementID(name: "nested", index: 2),
                                    content: .column(spacing: 3, align: .center, children: [b, rectangle(4)]))
        let root = ProgramElement(id: ElementID(name: "root", index: 0),
                                  content: .column(spacing: 2, align: .center, children: [a, nested, rectangle(5, hidden: true)]),
                                  width: .fixed(40), height: .fixed(60))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Nested", root: root))
        var queries: [String] = []
        let scene = try runtime.project(environment: programEnvironment()) { text, _, width in
            queries.append(text); t.equal(width, nil)
            return text == "A" ? SkinSize(width: 10, height: 8) : SkinSize(width: 6, height: 5)
        }
        t.equal(queries, ["A", "B"])
        t.equal(scene.size, SkinSize(width: 40, height: 60))
        t.equal(scene.elements.map(\.frame), [SkinRect(width: 40, height: 60), SkinRect(x: 15, width: 10, height: 8),
                                              SkinRect(y: 10, width: 40, height: 28), SkinRect(x: 17, y: 10, width: 6, height: 5),
                                              SkinRect(y: 18, width: 40, height: 20), SkinRect(y: 40, width: 40, height: 20)])
        t.equal(scene.elements[5].visibility, .hiddenKeepsSpace)
        t.equal(scene.drawingItems.count, 3)
        var leaf = rectangle(63, ideal: SkinSize(width: 13, height: 7))
        for index in (0..<63).reversed() {
            leaf = ProgramElement(id: ElementID(name: "chain", index: index), content: .column(spacing: 0, align: .left, children: [leaf]),
                                  width: index == 0 ? .fixed(100) : .fit, height: index == 0 ? .fixed(100) : .fit)
        }
        var deep = try ProgramRuntime(program: WidgetProgram(name: "64 levels", root: leaf))
        let result = try deep.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(leaf.id) }
        t.equal(result.elements.count, 64)
        t.equal(result.elements.last?.frame, SkinRect(width: 100, height: 100))
        t.equal(result.drawingItems.count, 1)
    }

    t.suite("Program: flex layout: assigned text widths reflow the final fit cross axis") {
        let text = ProgramElement(id: ElementID(name: "text", index: 2), content: .text(ProgramText("wrap")), width: .fill)
        let root = ProgramElement(id: ElementID(name: "row", index: 0),
                                  content: .row(spacing: 4, align: .bottom, children: [rectangle(1, height: .fixed(6)), text]), width: .fixed(50))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Wrapped row", root: root))
        var widths: [Double?] = []
        let scene = try runtime.project(environment: programEnvironment()) { _, style, width in
            widths.append(width); t.equal(style.wrap, width != nil)
            return width == nil ? SkinSize(width: 40, height: 5) : SkinSize(width: 23, height: 15)
        }
        t.equal(widths, [nil, 23])
        t.equal(scene.size, SkinSize(width: 50, height: 15))
        t.equal(scene.elements[1].frame, SkinRect(y: 9, width: 23, height: 6))
        t.equal(scene.elements[2].frame, SkinRect(x: 27, width: 23, height: 15))
        t.equal(programDraws(scene).first?.style.wrap, true)
        t.equal(scene.drawingItems.first, .fill(SkinRect(y: 9, width: 23, height: 6), Paint(color: SkinAppearance.light.accentColor)))
    }

    t.suite("Program: flex layout: invalid limits and minimum overflow cannot commit startup state") {
        let id = ElementID(name: "rect", index: 0)
        for root in [rectangle(0, minWidth: .nan), rectangle(0, maxWidth: .infinity), rectangle(0, minHeight: -1),
                     rectangle(0, minWidth: 11, maxWidth: 10), rectangle(0, ideal: SkinSize(width: -1, height: 10)),
                     rectangle(0, ideal: SkinSize(width: 10, height: .nan))] {
            programFailure(t, .invalidGeometry(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid constraints", root: root)) }
        }
        let caption = ProgramElement(id: ElementID(name: "caption", index: 1), content: .text(ProgramText(value:
            .conditional(.declaration(0), then: .string("Ready"), otherwise: .string("Waiting")))))
        let root = ProgramElement(id: ElementID(name: "root", index: 0),
                                  content: .column(spacing: 2, align: .left, children: [caption, rectangle(2, minHeight: 20)]),
                                  width: .fixed(10), height: .fixed(40))
        let program = WidgetProgram(name: "Retry minimum", root: root,
                                    declarations: [ProgramDeclaration(name: "flag", kind: .variable, initial: .boolean(false))],
                                    onLoad: [ProgramAssignment(declaration: 0, value: .not(.declaration(0)))])
        var runtime = try ProgramRuntime(program: program)
        programFailure(t, .layoutOverflow(root.id)) {
            _ = try runtime.project(environment: programEnvironment()) { _, _, _ in SkinSize(width: 2, height: 30) }
        }
        t.equal(runtime.generation, 0)
        let scene = try runtime.project(environment: programEnvironment()) { _, _, _ in SkinSize(width: 2, height: 2) }
        t.equal(programDraws(scene).map(\.text), ["Ready"], "failed allocation retained neither startup initializers nor assignments")
        t.equal(scene.elements[2].frame, SkinRect(y: 4, width: 10, height: 36))
        t.equal(runtime.generation, 1)
    }

    t.suite("Program: flex precision: fractional shares stay within the exact budget without hiding minimum overflow") {
        // Literal frames are hand calculated. The strict containment checks do not use an epsilon.
        let cases: [(extent: Double, spacing: Double, minima: [Double], caps: [Double?], sizes: [Double], origins: [Double])] = [
            (0.9, 0, [0, 0, 0], [nil, nil, nil], [0.3, 0.3, 0.3], [0, 0.3, 0.6]),
            (30.9, 0, [0, 0, 0], [nil, nil, nil], [10.3, 10.3, 10.3], [0, 10.3, 20.6]),
            (1.4, 0.1, [0, 0, 0, 0, 0], [nil, nil, nil, nil, nil], [0.2, 0.2, 0.2, 0.2, 0.2], [0, 0.3, 0.6, 0.9, 1.2]),
            (0.9, 0, [0, 0, 0], [0.1, nil, nil], [0.1, 0.4, 0.4], [0, 0.1, 0.5]),
            (0.9, 0, [0.1, 0, 0], [0.1, nil, nil], [0.1, 0.4, 0.4], [0, 0.1, 0.5])
        ]
        for column in [false, true] {
            for value in cases {
                let children = value.minima.indices.map { i in
                    rectangle(i + 1, minWidth: column ? 0 : value.minima[i], maxWidth: column ? nil : value.caps[i],
                              minHeight: column ? value.minima[i] : 0, maxHeight: column ? value.caps[i] : nil)
                }
                let root = ProgramElement(id: ElementID(name: "fractional", index: 0),
                                          content: column ? .column(spacing: value.spacing, align: .left, children: children)
                                            : .row(spacing: value.spacing, align: .top, children: children),
                                          width: .fixed(column ? 1 : value.extent), height: .fixed(column ? value.extent : 1))
                var runtime = try ProgramRuntime(program: WidgetProgram(name: "Fractional allocation", root: root))
                let scene = try runtime.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(root.id) }
                t.equal(scene.size, SkinSize(width: column ? 1 : value.extent, height: column ? value.extent : 1))
                t.equal(scene.drawingItems.count, children.count)
                for (i, element) in scene.elements.dropFirst().enumerated() {
                    let origin = column ? element.frame.y : element.frame.x
                    let length = column ? element.frame.height : element.frame.width
                    t.close(length, value.sizes[i]); t.close(origin, value.origins[i])
                    t.check(origin >= 0 && origin + length <= value.extent, "fractional frame must stay inside the exact parent budget")
                }
            }
        }
        // A rigid child is interleaved so subtraction and ordered recomposition have different rounding.
        let mixed = ProgramElement(id: ElementID(name: "mixed", index: 0),
                                   content: .row(spacing: 0, align: .top, children: [rectangle(1), rectangle(2, width: .fixed(0.1)),
                                                                                   rectangle(3), rectangle(4)]),
                                   width: .fixed(0.4), height: .fixed(1))
        var mixedRuntime = try ProgramRuntime(program: WidgetProgram(name: "Rigid and flexible fractions", root: mixed))
        let mixedScene = try mixedRuntime.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(mixed.id) }
        t.equal(mixedScene.drawingItems.count, 4)
        for (i, element) in mixedScene.elements.dropFirst().enumerated() {
            t.close(element.frame.width, 0.1); t.close(element.frame.x, [0.0, 0.1, 0.2, 0.3][i])
            t.check(element.frame.x + element.frame.width <= 0.4)
        }
        // This minimum sum is one representable step beyond 0.9 and must not be forgiven as rounding noise.
        let root = ProgramElement(id: ElementID(name: "too-small", index: 0),
                                  content: .row(spacing: 0, align: .top, children: (1...3).map { rectangle($0, minWidth: 0.30000000000000004) }),
                                  width: .fixed(0.9), height: .fixed(1))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Strict minimum", root: root))
        programFailure(t, .layoutOverflow(root.id)) {
            _ = try runtime.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(root.id) }
        }
        t.equal(runtime.generation, 0)
    }

    t.suite("Program: shapes: curved leaves capture bounded paths and independent appearance payloads") {
        for kind in [ProgramShapeKind.circle, .ellipse, .capsule] {
            let id = ElementID(name: "curve", index: 0)
            let root = ProgramElement(id: id, content: .shape(kind: kind, fill: .text), width: .fixed(24), height: .fixed(18),
                                      padding: SkinInsets(left: 2, top: 3, right: 4, bottom: 5))
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Captured curves", root: root))
            var captured: ShapeDraw?
            for appearance in [SkinAppearance.light, .dark] {
                let scene = try runtime.project(environment: programEnvironment(appearance)) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(id) }
                t.equal(scene.size, SkinSize(width: 24, height: 18))
                t.equal(scene.elements.first?.kind, .shape)
                guard scene.drawingItems.count == 1, case .shape(let draw) = scene.drawingItems[0],
                      draw.shapes.count == 1, case .path(let path) = draw.shapes[0].geometry,
                      path.subpaths.count == 1 else { return t.check(false, "a real curved recipe must be captured") }
                let item = draw.shapes[0], subpath = path.subpaths[0]
                t.equal(draw.contentFrame, SkinRect(x: 2, y: 3, width: 18, height: 10))
                t.equal(item.fill, .color(appearance.labelColor)); t.equal(item.stroke, .none)
                t.check(item.closed && subpath.closed && item.strokePlan == nil)
                t.equal(path.fillRule, .nonZero)
                switch kind {
                case .circle:
                    t.equal(item.bounds, ShapeRect(minX: 4, minY: 0, maxX: 14, maxY: 10))
                    t.equal(subpath.start, ShapePoint(14, 5))
                    t.equal(subpath.segments.map(\.kind.end), [ShapePoint(9, 10), ShapePoint(4, 5), ShapePoint(9, 0), ShapePoint(14, 5)])
                case .ellipse:
                    t.equal(item.bounds, ShapeRect(minX: 0, minY: 0, maxX: 18, maxY: 10))
                    t.equal(subpath.start, ShapePoint(18, 5))
                    t.equal(subpath.segments.map(\.kind.end), [ShapePoint(9, 10), ShapePoint(0, 5), ShapePoint(9, 0), ShapePoint(18, 5)])
                case .capsule:
                    t.equal(item.bounds, ShapeRect(minX: 0, minY: 0, maxX: 18, maxY: 10))
                    t.equal(subpath.start, ShapePoint(5, 0))
                    t.equal(subpath.segments.map(\.kind.end), [ShapePoint(13, 0), ShapePoint(18, 5), ShapePoint(13, 10),
                                                             ShapePoint(5, 10), ShapePoint(0, 5), ShapePoint(5, 0)])
                }
                if let old = captured {
                    t.check(old.sourceID != draw.sourceID, "a new paint payload cannot reuse a different recipe's cache identity")
                    t.equal(old.shapes[0].fill, .color(SkinAppearance.light.labelColor), "captured old curves are immutable")
                    t.equal(old.shapes[0].geometry, item.geometry)
                } else { captured = draw }
            }
        }
    }

    t.suite("Program: shapes: shared layout retains hidden zero and transparent curve semantics") {
        func shape(_ index: Int, _ kind: ProgramShapeKind, width: Double, height: Double, hidden: Bool = false) -> ProgramElement {
            ProgramElement(id: ElementID(name: "curve", index: index), content: .shape(kind: kind, fill: .accent),
                           width: .fixed(width), height: .fixed(height), hidden: hidden)
        }
        let text = ProgramElement(id: ElementID(name: "text", index: 4), content: .text(ProgramText("A")))
        let root = ProgramElement(id: ElementID(name: "column", index: 0), content: .column(spacing: 4, align: .left, children:
            [shape(1, .circle, width: 12, height: 8), shape(2, .ellipse, width: 0, height: 8),
             shape(3, .capsule, width: 6, height: 4, hidden: true), text]))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Curve order", root: root))
        let scene = try runtime.project(environment: programEnvironment()) { value, _, _ in
            t.equal(value, "A"); return SkinSize(width: 5, height: 10)
        }
        t.equal(scene.size, SkinSize(width: 12, height: 42))
        t.equal(scene.elements.map(\.frame), [SkinRect(width: 12, height: 42), SkinRect(width: 12, height: 8),
                                              SkinRect(y: 12, width: 0, height: 8), SkinRect(y: 24, width: 6, height: 4),
                                              SkinRect(y: 32, width: 5, height: 10)])
        t.equal(scene.elements[3].visibility, .hiddenKeepsSpace)
        t.equal(scene.drawingItems.count, 2); t.equal(programDraws(scene).map(\.text), ["A"])
        for kind in [ProgramShapeKind.circle, .ellipse, .capsule] {
            let leaf = ProgramElement(id: ElementID(name: "clear", index: 0), content: .shape(kind: kind, fill: .literal(.clear)),
                                      width: .fixed(8), height: .fixed(8))
            var empty = try ProgramRuntime(program: WidgetProgram(name: "Transparent curve", root: leaf))
            let blank = try empty.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(leaf.id) }
            guard let item = blank.drawingItems.first, case .shape(let draw) = item else { return t.check(false, "transparent positive geometry keeps its recipe") }
            t.check(!draw.shapes[0].fill.isVisible)
        }
    }

    t.suite("Program: shapes: invalid direct producers and finite layout overflow fail before publication") {
        let id = ElementID(name: "invalid-curve", index: 0)
        for kind in [ProgramShapeKind.circle, .ellipse, .capsule] {
            let noIdeal = ProgramElement(id: id, content: .shape(kind: kind, fill: .accent), height: .fixed(8))
            programFailure(t, .invalidGeometry(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Missing ideal", root: noIdeal)) }
            let badColor = ProgramElement(id: id, content: .shape(kind: kind, fill: .literal(RGBA(r: 256, g: 0, b: 0))),
                                          width: .fixed(8), height: .fixed(8))
            programFailure(t, .invalidPaint(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid color", root: badColor)) }
            let negative = ProgramElement(id: id, content: .shape(kind: kind, fill: .accent), width: .fixed(-1), height: .fixed(8))
            programFailure(t, .invalidGeometry(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Negative width", root: negative)) }
            let huge = ProgramElement(id: id, content: .shape(kind: kind, fill: .accent), width: .fixed(Double.greatestFiniteMagnitude), height: .fixed(8),
                                      padding: SkinInsets(left: Double.greatestFiniteMagnitude, top: 0, right: Double.greatestFiniteMagnitude, bottom: 0))
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Overflow", root: huge))
            programFailure(t, .layoutOverflow(id)) {
                _ = try runtime.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(id) }
            }
            t.equal(runtime.generation, 0)
        }
    }

    t.suite("Program: shape style: centered outlines retain layout and immutable appearance recipes") {
        let contents: [ProgramElement.Content] = [.rectangle(fill: .literal(.clear)), .shape(kind: .circle, fill: .literal(.clear)),
            .shape(kind: .ellipse, fill: .literal(.clear)), .shape(kind: .capsule, fill: .literal(.clear))]
        for (index, content) in contents.enumerated() {
            let id = ElementID(name: "outline", index: index)
            let root = ProgramElement(id: id, content: content, width: .fixed(24), height: .fixed(18),
                                      padding: SkinInsets(left: 2, top: 2, right: 2, bottom: 2),
                                      stroke: ProgramShapeStroke(color: .accent, width: 4))
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Outline", root: root))
            var captured: ShapeDraw?
            for appearance in [SkinAppearance.light, .dark] {
                let scene = try runtime.project(environment: programEnvironment(appearance)) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(id) }
                t.equal(scene.size, SkinSize(width: 24, height: 18))
                t.equal(scene.elements[0].frame, SkinRect(width: 24, height: 18))
                guard case .shape(let draw)? = scene.drawingItems.first else { return t.check(false, "actual outline recipe") }
                let item = draw.shapes[0]
                t.equal(draw.contentFrame, SkinRect(x: 2, y: 2, width: 20, height: 14))
                t.check(!item.fill.isVisible && item.strokePlan?.isEmpty == false)
                t.equal(item.stroke, .color(appearance.accentColor)); t.equal(item.strokePlan?.width, 4)
                t.equal(item.strokePlan?.placement, .center)
                let expected = index == 1 ? ShapeRect(minX: 1, minY: -2, maxX: 19, maxY: 16)
                                          : ShapeRect(minX: -2, minY: -2, maxX: 22, maxY: 16)
                t.check(item.visualBounds.minX <= expected.minX && item.visualBounds.minY <= expected.minY)
                t.check(item.visualBounds.maxX >= expected.maxX && item.visualBounds.maxY >= expected.maxY)
                if let old = captured {
                    t.check(old.sourceID != draw.sourceID)
                    t.equal(old.shapes[0].stroke, .color(SkinAppearance.light.accentColor))
                    t.equal(old.shapes[0].geometry, item.geometry)
                } else { captured = draw }
            }
        }
    }

    t.suite("Program: shape style: uniform corner radii clamp without changing empty or fixed boxes") {
        let id = ElementID(name: "rounded", index: 0)
        for (radius, expected) in [(ProgramCornerRadius.points(3), 3.0), (.full, 7.0), (.points(100), 7.0)] {
            let root = ProgramElement(id: id, content: .rectangle(fill: .accent), width: .fixed(20), height: .fixed(14), cornerRadius: radius)
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Rounded", root: root))
            let scene = try runtime.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(id) }
            guard case .shape(let draw)? = scene.drawingItems.first, case .path(let path) = draw.shapes[0].geometry,
                  let sub = path.subpaths.first else { return t.check(false, "rounded native recipe") }
            t.equal(scene.size, SkinSize(width: 20, height: 14))
            t.equal(sub.start, ShapePoint(expected, 0))
            t.equal(sub.segments[0].kind.end, ShapePoint(20 - expected, 0))
            t.equal(sub.segments[1].kind.end, ShapePoint(20, expected))
            t.check(draw.shapes[0].strokePlan == nil)
        }
        let plain = ProgramElement(id: id, content: .rectangle(fill: .accent), width: .fixed(20), height: .fixed(14), cornerRadius: .points(0))
        var original = try ProgramRuntime(program: WidgetProgram(name: "Zero radius", root: plain))
        let scene = try original.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(id) }
        t.equal(scene.drawingItems, [.fill(SkinRect(width: 20, height: 14), Paint(color: SkinAppearance.light.accentColor))])
        for (width, hidden) in [(0.0, false), (20.0, true)] {
            let empty = ProgramElement(id: id, content: plain.content, width: .fixed(width), height: .fixed(14), hidden: hidden,
                                       stroke: ProgramShapeStroke(color: .accent, width: 4), cornerRadius: .full)
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Empty outline", root: empty))
            let output = try runtime.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(id) }
            t.equal(output.size, SkinSize(width: width, height: 14)); t.check(output.drawingItems.isEmpty)
        }
    }

    t.suite("Program: shape style: illegal direct styles and overflowing stroke extents fail transactionally") {
        let id = ElementID(name: "invalid-style", index: 0)
        for value in [-1.0, .nan, .infinity] {
            for root in [ProgramElement(id: id, content: .rectangle(fill: .accent), width: .fixed(20), height: .fixed(14),
                                        stroke: ProgramShapeStroke(color: .accent, width: value)),
                         ProgramElement(id: id, content: .rectangle(fill: .accent), width: .fixed(20), height: .fixed(14), cornerRadius: .points(value))] {
                programFailure(t, .invalidGeometry(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid", root: root)) }
            }
        }
        let badColor = ProgramElement(id: id, content: .rectangle(fill: .accent), width: .fixed(20), height: .fixed(14),
                                      stroke: ProgramShapeStroke(color: .literal(RGBA(r: 256, g: 0, b: 0)), width: 1))
        programFailure(t, .invalidPaint(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid color", root: badColor)) }
        let badText = ProgramElement(id: id, content: .text(ProgramText("A")), stroke: ProgramShapeStroke(color: .accent, width: 1))
        programFailure(t, .invalidGeometry(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Not a shape", root: badText)) }
        let badCircle = ProgramElement(id: id, content: .shape(kind: .circle, fill: .accent), width: .fixed(20), height: .fixed(14), cornerRadius: .full)
        programFailure(t, .invalidGeometry(id)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Not a rectangle", root: badCircle)) }
        let huge = ProgramElement(id: id, content: .rectangle(fill: .accent), width: .fixed(.greatestFiniteMagnitude), height: .fixed(8),
                                  stroke: ProgramShapeStroke(color: .accent, width: .greatestFiniteMagnitude))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Finite paint overflow", root: huge))
        programFailure(t, .layoutOverflow(id)) { _ = try runtime.project(environment: programEnvironment()) { _, _, _ in throw ProgramRuntimeError.invalidMeasurement(id) } }
        t.equal(runtime.generation, 0)
    }

    t.suite("Program: images: supplied natural inputs lower four modes without host measurement") {
        let stamp = ImageStamp(seconds: 7, nanoseconds: 8, size: 123, inode: 9)
        let resource = ProgramImageResource(path: "/fixture/picture.png", naturalSize: SkinSize(width: 20, height: 10), stamp: stamp)
        let id = ElementID(name: "picture", index: 0)
        for (mode, aspect, tiled) in [(ProgramImageMode.fit, 1, false), (.fill, 2, false), (.stretch, 0, false), (.tile, 0, true)] {
            let image = ProgramElement(id: id, content: .image(ProgramImage(source: "picture.png", mode: mode)),
                                       padding: SkinInsets(left: 2, top: 3, right: 2, bottom: 3))
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Picture", root: image))
            let scene = try runtime.project(environment: programEnvironment(), images: ["picture.png": resource]) { _, _, _ in
                throw ProgramRuntimeError.invalidMeasurement(id)
            }
            t.equal(scene.size, SkinSize(width: 24, height: 16)); t.equal(scene.elements[0].id, id)
            guard case .image(let drawing)? = scene.drawingItems.first else { t.check(false); return }
            t.equal(drawing.contentFrame, SkinRect(x: 2, y: 3, width: 20, height: 10))
            t.equal(drawing.path, resource.path); t.check(drawing.options.useExifOrientation)
            t.equal(drawing.preserveAspectRatio, aspect); t.equal(drawing.tile, tiled)
            t.equal(drawing.naturalSize, resource.naturalSize)
            t.equal(scene.elements[0].imageDependencies, [ImageDependency(path: resource.path, stamp: stamp)])
            let resized = ProgramImageResource(path: "/fixture/next.png", naturalSize: SkinSize(width: 30, height: 12), stamp: stamp)
            let next = try runtime.project(environment: programEnvironment(.dark), images: ["picture.png": resized]) { _, _, _ in SkinSize() }
            t.equal(next.size, SkinSize(width: 34, height: 18)); t.equal(scene.size, SkinSize(width: 24, height: 16))
        }
    }

    t.suite("Program: images: shared proposals hidden boxes and startup remain transactional") {
        let first = ElementID(name: "first", index: 1), second = ElementID(name: "second", index: 2)
        let root = ProgramElement(id: ElementID(name: "row", index: 0), content: .row(spacing: 4, align: .center, children: [
            ProgramElement(id: first, content: .image(ProgramImage(source: "a")), width: .fill, height: .fill),
            ProgramElement(id: second, content: .image(ProgramImage(source: "a")), width: .fill, height: .fill, hidden: true)
        ]), width: .fixed(60), height: .fixed(20), padding: SkinInsets(left: 2, top: 2, right: 2, bottom: 2))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Flexible pictures", root: root))
        let input = ProgramImageResource(path: "/fixture/a", naturalSize: SkinSize(width: 16, height: 8),
                                         stamp: ImageStamp(seconds: 1, nanoseconds: 0, size: 12, inode: 3))
        let scene = try runtime.project(environment: programEnvironment(), images: ["a": input]) { _, _, _ in SkinSize() }
        t.equal(scene.elements[1].frame, SkinRect(x: 2, y: 2, width: 26, height: 16))
        t.equal(scene.elements[2].frame, SkinRect(x: 32, y: 2, width: 26, height: 16))
        t.equal(scene.elements[2].visibility, .hiddenKeepsSpace); t.check(scene.elements[2].items.isEmpty)
        t.equal(scene.drawingItems.count, 1)
        programFailure(t, .invalidImage(first)) { _ = try runtime.project(environment: programEnvironment()) { _, _, _ in SkinSize() } }
        t.equal(runtime.generation, 1)
        let zero = ProgramElement(id: first, content: .image(ProgramImage(source: "a")), width: .fixed(0), height: .fixed(8))
        var empty = try ProgramRuntime(program: WidgetProgram(name: "Empty", root: zero))
        t.check(try empty.project(environment: programEnvironment(), images: ["a": input]) { _, _, _ in SkinSize() }.drawingItems.isEmpty)
    }

    t.suite("Program: images: invalid direct sources inputs and overflow never publish a partial scene") {
        let id = ElementID(name: "image", index: 0)
        for source in ["", "a\0b", String(repeating: "x", count: 32_769)] {
            programFailure(t, .invalidImage(id)) {
                _ = try ProgramRuntime(program: WidgetProgram(name: "Bad", root: ProgramElement(id: id, content: .image(ProgramImage(source: source)))))
            }
        }
        let image = ProgramElement(id: id, content: .image(ProgramImage(source: "a")))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Image", root: image))
        for size in [SkinSize(width: 0, height: 1), SkinSize(width: 1, height: -1), SkinSize(width: .nan, height: 2), SkinSize(width: 2, height: .infinity)] {
            let input = ProgramImageResource(path: "/fixture/a", naturalSize: size, stamp: ImageStamp(seconds: 0, nanoseconds: 0, size: 1, inode: 1))
            programFailure(t, .invalidImage(id)) { _ = try runtime.project(environment: programEnvironment(), images: ["a": input]) { _, _, _ in SkinSize() } }
            t.equal(runtime.generation, 0)
        }
        let bad = ProgramImageResource(path: "", naturalSize: SkinSize(width: 8, height: 8), stamp: ImageStamp(seconds: 0, nanoseconds: 0, size: 1, inode: 1))
        programFailure(t, .invalidImage(id)) { _ = try runtime.project(environment: programEnvironment(), images: ["a": bad]) { _, _, _ in SkinSize() } }
        let padded = ProgramElement(id: id, content: .image(ProgramImage(source: "a")), padding: SkinInsets(left: .greatestFiniteMagnitude, top: 0, right: 1, bottom: 0))
        var overflowing = try ProgramRuntime(program: WidgetProgram(name: "Overflow", root: padded))
        let huge = ProgramImageResource(path: "/fixture/a", naturalSize: SkinSize(width: .greatestFiniteMagnitude, height: 1), stamp: bad.stamp)
        programFailure(t, .layoutOverflow(id)) { _ = try overflowing.project(environment: programEnvironment(), images: ["a": huge]) { _, _, _ in SkinSize() } }
        t.equal(overflowing.generation, 0)
    }

}

private func runProgramFreeformTests(_ t: TestRunner) {
    let rootID = ElementID(name: "freeform", index: 0)
    func rectangle(_ index: Int, width: Double = 20, height: Double = 10,
                   hidden: Bool = false, position: ProgramPosition? = nil) -> ProgramElement {
        ProgramElement(id: ElementID(name: "rect", index: index), content: .rectangle(fill: .accent),
                       width: .fixed(width), height: .fixed(height), hidden: hidden, position: position)
    }
    func freeform(_ children: [ProgramElement], align: ProgramAlignment = .center,
                  width: ProgramLength = .fit, height: ProgramLength = .fit, padding: SkinInsets = .zero) -> ProgramElement {
        ProgramElement(id: rootID, content: .freeform(align: align, children: children),
                       width: width, height: height, padding: padding)
    }
    func noText(_ text: String, _ style: TextStyle, _ width: Double?) throws -> SkinSize {
        throw ProgramRuntimeError.invalidMeasurement(rootID)
    }

    t.suite("Program: freeform: all nine alignments and anchors use padded border boxes") {
        let padding = SkinInsets(left: 7, top: 11, right: 13, bottom: 9)
        let expectedAligned = [SkinPoint(x: 7, y: 11), SkinPoint(x: 37, y: 11), SkinPoint(x: 67, y: 11),
                               SkinPoint(x: 7, y: 36), SkinPoint(x: 37, y: 36), SkinPoint(x: 67, y: 36),
                               SkinPoint(x: 7, y: 61), SkinPoint(x: 37, y: 61), SkinPoint(x: 67, y: 61)]
        let expectedAnchored = [SkinPoint(x: 47, y: 41), SkinPoint(x: 37, y: 41), SkinPoint(x: 27, y: 41),
                                SkinPoint(x: 47, y: 36), SkinPoint(x: 37, y: 36), SkinPoint(x: 27, y: 36),
                                SkinPoint(x: 47, y: 31), SkinPoint(x: 37, y: 31), SkinPoint(x: 27, y: 31)]
        t.equal(ProgramAlignment.allCases.count, 9)
        for (i, alignment) in ProgramAlignment.allCases.enumerated() {
            for positioned in [false, true] {
                let child = ProgramElement(id: ElementID(name: "padded", index: 1), content: .rectangle(fill: .accent),
                    width: .fixed(20), height: .fixed(10), padding: SkinInsets(left: 2, top: 1, right: 3, bottom: 2),
                    position: positioned ? ProgramPosition(x: 40, y: 30, anchor: alignment) : nil)
                var runtime = try ProgramRuntime(program: WidgetProgram(name: "Nine", root:
                    freeform([child], align: alignment, width: .fixed(100), height: .fixed(80), padding: padding)))
                let scene = try runtime.project(environment: programEnvironment(), measure: noText)
                let point = positioned ? expectedAnchored[i] : expectedAligned[i]
                t.equal(scene.size, SkinSize(width: 100, height: 80))
                t.equal(scene.elements[1].frame, SkinRect(x: point.x, y: point.y, width: 20, height: 10))
                t.equal(scene.drawingItems, [.fill(SkinRect(x: point.x + 2, y: point.y + 1, width: 15, height: 7),
                                                  Paint(color: SkinAppearance.light.accentColor))])
            }
        }
        t.equal(ProgramPosition(), ProgramPosition(x: 0, y: 0, anchor: .topLeft))
    }

    t.suite("Program: freeform: fit measures extent from origin without translating negative or hidden children") {
        let negative = rectangle(1, width: 10, height: 8, position: ProgramPosition(x: -30, y: -25))
        let hidden = rectangle(2, width: 14, height: 6, hidden: true, position: ProgramPosition(x: 20, y: 12))
        let stacked = rectangle(3, width: 8, height: 20)
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Extent", root:
            freeform([negative, hidden, stacked], padding: SkinInsets(left: 3, top: 4, right: 5, bottom: 6))))
        let scene = try runtime.project(environment: programEnvironment(), measure: noText)
        t.equal(scene.size, SkinSize(width: 42, height: 30))
        t.equal(scene.elements.map(\.id.index), [0, 1, 2, 3])
        t.equal(scene.elements.map(\.frame), [SkinRect(width: 42, height: 30), SkinRect(x: -27, y: -21, width: 10, height: 8),
                                             SkinRect(x: 23, y: 16, width: 14, height: 6), SkinRect(x: 16, y: 4, width: 8, height: 20)])
        t.equal(scene.elements[2].visibility, .hiddenKeepsSpace)
        t.equal(scene.drawingItems.count, 2)
        t.equal(scene.elements[1].items, [.fill(SkinRect(x: -27, y: -21, width: 10, height: 8), Paint(color: SkinAppearance.light.accentColor))])
        var entirelyNegative = try ProgramRuntime(program: WidgetProgram(name: "Negative", root: freeform([negative])))
        let outside = try entirelyNegative.project(environment: programEnvironment(), measure: noText)
        t.equal(outside.size, SkinSize())
        t.equal(outside.elements[1].frame, SkinRect(x: -30, y: -25, width: 10, height: 8))
        t.equal(outside.drawingItems.count, 1, "no implicit clip discards negative content")
    }

    t.suite("Program: freeform: positioned fit is unspecified while fill and stacked text use known inner proposals") {
        let positioned = ProgramElement(id: ElementID(name: "positioned", index: 1), content: .text(ProgramText("positioned")),
                                        position: ProgramPosition(x: 7, y: 5))
        let stacked = ProgramElement(id: ElementID(name: "stacked", index: 2), content: .text(ProgramText("stacked")))
        let fill = ProgramElement(id: ElementID(name: "fill", index: 3), content: .rectangle(fill: .accent),
                                  width: .fill, height: .fill, idealSize: SkinSize(width: 6, height: 8), position: ProgramPosition())
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Proposals", root:
            freeform([positioned, stacked, fill], width: .fixed(40), height: .fixed(60),
                     padding: SkinInsets(left: 10, top: 10, right: 10, bottom: 10))))
        var queries: [String: [Double?]] = [:]
        let scene = try runtime.project(environment: programEnvironment()) { text, _, width in
            queries[text, default: []].append(width)
            return width == nil ? SkinSize(width: 50, height: 10) : SkinSize(width: 20, height: 30)
        }
        t.equal(queries["positioned"], [nil]); t.equal(queries["stacked"], [nil, 20])
        t.equal(scene.elements[1].frame, SkinRect(x: 17, y: 15, width: 50, height: 10))
        t.equal(scene.elements[2].frame, SkinRect(x: 10, y: 15, width: 20, height: 30))
        t.equal(scene.elements[3].frame, SkinRect(x: 10, y: 10, width: 20, height: 40))
        t.check(!programDraws(scene)[0].style.wrap && programDraws(scene)[1].style.wrap)
    }

    t.suite("Program: freeform: unspecified fill stays ideal and nested stacks allocate freeform minima") {
        let child = ProgramElement(id: ElementID(name: "fill", index: 1), content: .rectangle(fill: .accent),
                                   width: .fill, height: .fill, idealSize: SkinSize(width: 10, height: 10),
                                   position: ProgramPosition(x: 10))
        var ideal = try ProgramRuntime(program: WidgetProgram(name: "Ideal", root: freeform([child])))
        let first = try ideal.project(environment: programEnvironment(), measure: noText)
        t.equal(first.size, SkinSize(width: 20, height: 10))
        t.equal(first.elements[1].frame, SkinRect(x: 10, width: 10, height: 10))
        let rigid = rectangle(3, width: 20, height: 10)
        let other = ProgramElement(id: ElementID(name: "other", index: 4), content: .rectangle(fill: .accent),
                                   width: .fill, height: .fill, idealSize: SkinSize(width: 10, height: 10))
        let row = ProgramElement(id: ElementID(name: "row", index: 5),
            content: .row(spacing: 0, align: .top, children: [freeform([child]), rigid, other]), width: .fixed(100), height: .fixed(20))
        var allocated = try ProgramRuntime(program: WidgetProgram(name: "Allocated", root: row))
        let scene = try allocated.project(environment: programEnvironment(), measure: noText)
        t.equal(scene.elements.map(\.frame), [SkinRect(width: 100, height: 20), SkinRect(width: 45, height: 20),
            SkinRect(x: 10, width: 45, height: 20), SkinRect(x: 45, width: 20, height: 10), SkinRect(x: 65, width: 35, height: 20)])
        let outside = ProgramElement(id: child.id, content: child.content, width: .fill, height: .fill,
                                     idealSize: child.idealSize, position: ProgramPosition(x: 100))
        let constrained = ProgramElement(id: rootID, content: .freeform(align: .center, children: [outside]), maxWidth: 20, maxHeight: 6)
        var clamped = try ProgramRuntime(program: WidgetProgram(name: "Constrained", root: constrained))
        let limited = try clamped.project(environment: programEnvironment(), measure: noText)
        t.equal(limited.size, SkinSize(width: 20, height: 6))
        t.equal(limited.elements[1].frame, SkinRect(x: 100, width: 10, height: 10), "max constrains the parent, without clipping or moving the child")
    }

    t.suite("Program: freeform: file draw order and per-event topmost boxes preserve empty hidden and stale click semantics") {
        let lowerID = ElementID(name: "lower", index: 1), upperID = ElementID(name: "upper", index: 2)
        let lower = ProgramElement(id: lowerID, content: .rectangle(fill: .accent), width: .fixed(40), height: .fixed(30),
            onClickActions: [.copy(.string("lower left"))], onRightClickActions: [.copy(.string("lower right"))],
            position: ProgramPosition(x: -5, y: -5))
        func upper(hidden: Bool = false, catchesLeft: Bool = true) -> ProgramElement {
            ProgramElement(id: upperID, content: .rectangle(fill: .literal(.clear)), width: .fixed(20), height: .fixed(20),
                hidden: hidden, onClickActions: catchesLeft ? [] : nil, onRightClickActions: [.copy(.string("upper right"))],
                position: ProgramPosition(x: -2, y: -2))
        }
        let point = SkinPoint(x: -1, y: -1)
        for (hidden, catchesLeft, leftID, rightID) in [(false, true, upperID, upperID),
                                                      (false, false, lowerID, upperID), (true, true, lowerID, lowerID)] {
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Overlap", root: freeform([lower, upper(hidden: hidden, catchesLeft: catchesLeft)])))
            let scene = try runtime.project(environment: programEnvironment(), measure: noText)
            t.equal(scene.elements.map(\.id), [rootID, lowerID, upperID])
            t.equal(scene.hitMap.entry(at: point.x, point.y, handling: .leftUp, images: nil)?.elementID, leftID)
            t.equal(scene.hitMap.entry(at: point.x, point.y, handling: .rightUp, images: nil)?.elementID, rightID)
            let left = try runtime.clickWithEffects(at: point, expectedGeneration: scene.generation, environment: programEnvironment(), measure: noText)
            t.equal(left?.effects, leftID == upperID ? [] : [.copy("lower left")])
            t.check(try runtime.clickWithEffects(at: point, expectedGeneration: scene.generation, event: .rightUp,
                environment: programEnvironment(), measure: noText) == nil)
            let right = try runtime.clickWithEffects(at: point, expectedGeneration: runtime.generation, event: .rightUp,
                environment: programEnvironment(), measure: noText)
            t.equal(right?.effects, [.copy(rightID == upperID ? "upper right" : "lower right")])
            t.equal(runtime.generation, 3)
        }
    }

    t.suite("Program: freeform: images visible clocks and selected action dependencies traverse nested children") {
        let pictureID = ElementID(name: "picture", index: 1)
        let picture = ProgramElement(id: pictureID, content: .image(ProgramImage(source: "picture", mode: .fill)),
                                     position: ProgramPosition(x: -10, y: -8))
        let time = ProgramElement(id: ElementID(name: "clock", index: 2),
            content: .text(ProgramText(value: .formatDate(.timeNow, .pattern("HH:mm:ss")))), position: ProgramPosition(x: 10))
        let system = ProgramElement(id: ElementID(name: "cpu", index: 3),
            content: .text(ProgramText(value: .formatNumber(.systemProperty(.cpuUsage), ProgramNumberFormat()))),
            onClickActions: [.copy(.concatenate([.systemProperty(.memoryUsed)]))],
            onRightClickActions: [.copy(.concatenate([.systemProperty(.cpuCoreCount)]))], position: ProgramPosition(x: 30))
        let resource = ProgramImageResource(path: "/fixture/picture.png", naturalSize: SkinSize(width: 20, height: 12),
                                           stamp: ImageStamp(seconds: 7, nanoseconds: 8, size: 123, inode: 9))
        let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US"))
        let input = ProgramSystemInput(cpuUsage: 42, cpuCoreCount: 8, memoryUsed: 1024)
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Inputs", root: freeform([picture, time, system])))
        t.equal(runtime.neededSystemProperties, [.cpuUsage])
        let measure: (String, TextStyle, Double?) -> SkinSize = { _, _, _ in SkinSize(width: 10, height: 10) }
        let scene = try runtime.project(environment: programEnvironment(), images: ["picture": resource], dateInput: date, systemInput: input, measure: measure)
        t.equal(programDraws(scene).map(\.text), ["00:00:00", "42"]); t.equal(runtime.clockPrecision, .second)
        t.equal(scene.elements[1].frame, SkinRect(x: -10, y: -8, width: 20, height: 12))
        t.equal(scene.elements[1].imageDependencies, [ImageDependency(path: resource.path, stamp: resource.stamp)])
        guard case .image(let drawing) = scene.elements[1].items.first else { return t.check(false, "positioned image recipe") }
        t.equal(drawing.contentFrame, scene.elements[1].frame); t.equal(drawing.preserveAspectRatio, 2)
        let point = SkinPoint(x: 31, y: 1)
        t.equal(runtime.neededSystemProperties(clickAt: point), [.cpuUsage, .memoryUsed])
        t.equal(runtime.neededSystemProperties(clickAt: point, event: .rightUp), [.cpuUsage, .cpuCoreCount])
        t.equal(runtime.neededSystemProperties(clickAt: SkinPoint(x: 100, y: 100)), [])
        let clicked = try runtime.clickWithEffects(at: point, expectedGeneration: scene.generation, event: .rightUp,
            environment: programEnvironment(), images: ["picture": resource], dateInput: date, systemInput: input, measure: measure)
        t.equal(clicked?.effects, [.copy("8")]); t.equal(runtime.clockPrecision, .second)
        let hidden = ProgramElement(id: rootID, content: .freeform(align: .center, children: [time]), hidden: true)
        var invisible = try ProgramRuntime(program: WidgetProgram(name: "Hidden", root: hidden))
        let hiddenScene = try invisible.project(environment: programEnvironment(), dateInput: date, measure: measure)
        t.check(hiddenScene.drawingItems.isEmpty); t.equal(invisible.clockPrecision, nil)
    }

    t.suite("Program: freeform: failed measurement and finite coordinate overflow retain the prior transaction") {
        let textID = ElementID(name: "text", index: 1)
        let text = ProgramElement(id: textID, content: .text(ProgramText(value:
            .conditional(.declaration(0), then: .string("B"), otherwise: .string("A")))),
            onClickActions: [.assign(ProgramAssignment(declaration: 0, value: .boolean(true))), .copy(.string("committed"))],
            position: ProgramPosition(x: 30, anchor: .topRight))
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Transaction", root: freeform([text]),
            declarations: [ProgramDeclaration(name: "flag", kind: .variable, initial: .boolean(false))]))
        let measure: (String, TextStyle, Double?) -> SkinSize = { value, _, _ in SkinSize(width: value == "A" ? 10 : 20, height: 10) }
        let scene = try runtime.project(environment: programEnvironment(), measure: measure)
        t.equal(scene.elements[1].frame, SkinRect(x: 20, width: 10, height: 10))
        programFailure(t, .invalidMeasurement(textID)) {
            _ = try runtime.clickWithEffects(at: SkinPoint(x: 25, y: 5), expectedGeneration: scene.generation,
                environment: programEnvironment()) { _, _, _ in SkinSize(width: .nan, height: 10) }
        }
        t.equal(runtime.generation, 1)
        let unchanged = try runtime.project(environment: programEnvironment(), measure: measure)
        t.equal(programDraws(unchanged).map(\.text), ["A"])
        let clicked = try runtime.clickWithEffects(at: SkinPoint(x: 25, y: 5), expectedGeneration: unchanged.generation,
            environment: programEnvironment(), measure: measure)
        t.equal(clicked?.effects, [.copy("committed")])
        t.equal(clicked?.scene.elements[1].frame, SkinRect(x: 10, width: 20, height: 10))
        for position in [ProgramPosition(x: .greatestFiniteMagnitude), ProgramPosition(x: -.greatestFiniteMagnitude, anchor: .right)] {
            var overflowing = try ProgramRuntime(program: WidgetProgram(name: "Overflow", root:
                freeform([rectangle(1, width: .greatestFiniteMagnitude, position: position)])))
            programFailure(t, .layoutOverflow(rootID)) { _ = try overflowing.project(environment: programEnvironment(), measure: noText) }
            t.equal(overflowing.generation, 0)
        }
    }

    t.suite("Program: freeform: direct placement identities nesting element and action budgets are validated") {
        let childID = ElementID(name: "rect", index: 1)
        let positioned = rectangle(1, position: ProgramPosition())
        programFailure(t, .invalidGeometry(childID)) { _ = try ProgramRuntime(program: WidgetProgram(name: "Root position", root: positioned)) }
        for content in [ProgramElement.Content.column(spacing: 0, align: .left, children: [positioned]),
                        .row(spacing: 0, align: .top, children: [positioned])] {
            programFailure(t, .invalidGeometry(childID)) {
                _ = try ProgramRuntime(program: WidgetProgram(name: "Wrong parent", root: ProgramElement(id: rootID, content: content)))
            }
        }
        for value in [Double.nan, .infinity, -.infinity] {
            for position in [ProgramPosition(x: value), ProgramPosition(y: value)] {
                programFailure(t, .invalidGeometry(childID)) {
                    _ = try ProgramRuntime(program: WidgetProgram(name: "Nonfinite", root: freeform([rectangle(1, position: position)])))
                }
            }
        }
        programFailure(t, .duplicateIdentity(childID)) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Duplicate", root: freeform([rectangle(1), rectangle(1)])))
        }
        let children = (1..<ProgramLimits.maximumElements).map { rectangle($0, width: 1, height: 1) }
        _ = try ProgramRuntime(program: WidgetProgram(name: "At element limit", root: freeform(children)))
        t.check(true)
        programFailure(t, .elementLimit) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Too many", root: freeform(children + [rectangle(ProgramLimits.maximumElements)])))
        }
        var deep = rectangle(63)
        for index in (0..<63).reversed() {
            deep = ProgramElement(id: ElementID(name: "nested", index: index), content: .freeform(align: .center, children: [deep]))
        }
        _ = try ProgramRuntime(program: WidgetProgram(name: "At depth limit", root: deep)); t.check(true)
        programFailure(t, .depthLimit) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Too deep", root:
                ProgramElement(id: ElementID(name: "extra", index: 64), content: .freeform(align: .center, children: [deep]))))
        }
        let actions = ProgramElement(id: childID, content: .rectangle(fill: .accent), width: .fixed(20), height: .fixed(10),
            onRightClickActions: Array(repeating: .copy(.string("request")), count: ProgramLimits.maximumExpressions + 1))
        programFailure(t, .expressionLimit) { _ = try ProgramRuntime(program: WidgetProgram(name: "Actions", root: freeform([actions]))) }
        programFailure(t, .emptyProgram) { _ = try ProgramRuntime(program: WidgetProgram(name: "Empty", root: freeform([]))) }
    }
}

private func runProgramPointerTests(_ t: TestRunner) {
    let environment = programEnvironment(), point = SkinPoint(x: 12, y: 12)
    let id = ElementID(name: "pointer", index: 0)
    func measure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
        SkinSize(width: 12, height: 18)
    }
    func strings(_ scene: WidgetScene) -> [String] { programDraws(scene).map(\.text) }

    t.suite("Program: pointer events: primary and secondary actions remain separate with legacy primary dispatch") {
        let root = ProgramElement(id: id, content: .text(ProgramText(value: .declaration(0))),
            width: .fixed(40), height: .fixed(30),
            onClick: [ProgramAssignment(declaration: 0, value: .string("left"))],
            onRightClickActions: [.assign(ProgramAssignment(declaration: 0, value: .string("right"))),
                                  .copy(.declaration(0)), .open(.string("https://example.com/right"))])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Separate", root: root,
            declarations: [ProgramDeclaration(name: "caption", kind: .variable, initial: .string("initial"))]))
        let first = try runtime.project(environment: environment, measure: measure)
        t.equal(first.hitMap.entry(at: point.x, point.y, handling: .leftUp, images: nil)?.elementID, id)
        t.equal(first.hitMap.entry(at: point.x, point.y, handling: .rightUp, images: nil)?.elementID, id)
        guard let left = try runtime.click(at: point, expectedGeneration: first.generation,
            environment: environment, measure: measure) else { return t.check(false, "legacy primary click") }
        t.equal(strings(left), ["left"])
        t.check(try runtime.clickWithEffects(at: point, expectedGeneration: first.generation, event: .rightUp,
            environment: environment, measure: measure) == nil, "stale secondary scene is rejected")
        for event in MouseEventKind.allCases where event != .leftUp && event != .rightUp {
            t.check(try runtime.clickWithEffects(at: point, expectedGeneration: left.generation, event: event,
                environment: environment, measure: measure) == nil, "unsupported \(event)")
            t.equal(runtime.neededSystemProperties(clickAt: point, event: event), [])
        }
        t.equal(runtime.generation, left.generation)
        guard let right = try runtime.clickWithEffects(at: point, expectedGeneration: left.generation, event: .rightUp,
            environment: environment, measure: measure) else { return t.check(false, "secondary click") }
        t.equal(strings(right.scene), ["right"])
        t.equal(right.effects, [.copy("right"), .open("https://example.com/right")])
        let next = try runtime.clickWithEffects(at: point, expectedGeneration: right.scene.generation,
            environment: environment, measure: measure)
        t.equal(next?.effects, [])
        t.equal(next.map { strings($0.scene) }, ["left"])
    }

    t.suite("Program: pointer events: empty secondary handlers consume rounded padded boxes without bubbling") {
        let childID = ElementID(name: "child", index: 1)
        func root(_ childRight: [ProgramAction]?, hidden: Bool = false) -> ProgramElement {
            let child = ProgramElement(id: childID, content: .rectangle(fill: .literal(RGBA(r: 0, g: 0, b: 0, a: 0))),
                width: .fixed(40), height: .fixed(30), padding: SkinInsets(left: 4, top: 4, right: 4, bottom: 4),
                cornerRadius: .points(8), onClickActions: [.copy(.string("child left"))], onRightClickActions: childRight)
            return ProgramElement(id: id, content: .column(spacing: 0, align: .left, children: [child]), hidden: hidden,
                onRightClickActions: [.copy(.string("parent right"))])
        }
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Empty child", root: root([])))
        let first = try runtime.project(environment: environment, measure: measure)
        t.equal(first.hitMap.entry(at: point.x, point.y, handling: .rightUp, images: nil)?.elementID, childID)
        let empty = try runtime.clickWithEffects(at: SkinPoint(x: 3, y: 12), expectedGeneration: first.generation,
            event: .rightUp, environment: environment, measure: measure)
        t.check(empty != nil, "padding and transparent paint still hit the rounded box")
        t.equal(empty?.effects, [], "an empty child handler does not bubble to its parent")
        let corner = try runtime.clickWithEffects(at: SkinPoint(x: 1, y: 1), expectedGeneration: runtime.generation,
            event: .rightUp, environment: environment, measure: measure)
        t.equal(corner?.effects, [.copy("parent right")], "a rounded corner miss selects the next right handler")
        var onlyLeftChild = try ProgramRuntime(program: WidgetProgram(name: "Different child event", root: root(nil)))
        let leftScene = try onlyLeftChild.project(environment: environment, measure: measure)
        let parent = try onlyLeftChild.clickWithEffects(at: point, expectedGeneration: leftScene.generation,
            event: .rightUp, environment: environment, measure: measure)
        t.equal(parent?.effects, [.copy("parent right")], "a primary handler does not capture a secondary event")
        var hidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden ancestor", root: root([], hidden: true)))
        let hiddenScene = try hidden.project(environment: environment, measure: measure)
        t.check(hiddenScene.hitMap.entries.isEmpty)
        t.check(try hidden.clickWithEffects(at: point, expectedGeneration: hiddenScene.generation,
            event: .rightUp, environment: environment, measure: measure) == nil)
        for miss in [SkinPoint(x: -1, y: 12), SkinPoint(x: .nan, y: 12)] {
            t.check(try runtime.clickWithEffects(at: miss, expectedGeneration: runtime.generation,
                event: .rightUp, environment: environment, measure: measure) == nil)
        }
    }

    t.suite("Program: pointer events: failed secondary action and projection preserve the prior transaction") {
        let root = ProgramElement(id: id, content: .text(ProgramText(value: .declaration(0))),
            width: .fixed(40), height: .fixed(30),
            onClick: [ProgramAssignment(declaration: 0, value: .string("Off"))],
            onRightClickActions: [.assign(ProgramAssignment(declaration: 0, value: .string("On"))), .copy(.declaration(0)),
                .open(.formatDate(.timeNow, .pattern("HH:mm:ss")))])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Rollback", root: root,
            declarations: [ProgramDeclaration(name: "caption", kind: .variable, initial: .string("Off"))]))
        let first = try runtime.project(environment: environment, measure: measure)
        programFailure(t, .invalidDateInput) {
            _ = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation, event: .rightUp,
                environment: environment, measure: measure)
        }
        t.equal(runtime.generation, first.generation)
        let date = ProgramDateInput(instant: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"))
        programFailure(t, .invalidMeasurement(id)) {
            _ = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation, event: .rightUp,
                environment: environment, dateInput: date) { text, _, _ in
                    text == "On" ? SkinSize(width: -1, height: 18) : SkinSize(width: 12, height: 18)
                }
        }
        t.equal(runtime.generation, first.generation)
        let unchanged = try runtime.project(environment: environment, measure: measure)
        t.equal(strings(unchanged), ["Off"])
        let right = try runtime.clickWithEffects(at: point, expectedGeneration: unchanged.generation, event: .rightUp,
            environment: environment, dateInput: date, measure: measure)
        t.equal(right.map { strings($0.scene) }, ["On"])
        t.equal(right?.effects, [.copy("On"), .open("00:00:00")])
        t.equal(runtime.clockPrecision, nil)
    }

    t.suite("Program: pointer events: startup and both handlers share validation and expression budgets") {
        let assignment = ProgramAssignment(declaration: 0, value: .boolean(true))
        let declarations = [ProgramDeclaration(name: "flag", kind: .variable, initial: .boolean(false))]
        func program(_ right: [ProgramAction], ambiguous: Bool = false) -> WidgetProgram {
            let root = ProgramElement(id: id, content: .text(ProgramText("Tap")),
                onClick: ambiguous ? [] : Array(repeating: assignment, count: ProgramLimits.maximumExpressions - 4),
                onClickActions: ambiguous ? [] : nil, onRightClickActions: right)
            return WidgetProgram(name: "Budget", root: root, declarations: declarations, onLoad: [assignment])
        }
        var accepted = try ProgramRuntime(program: program([.assign(assignment)]))
        t.equal(strings(try accepted.project(environment: environment, measure: measure)), ["Tap"])
        programFailure(t, .expressionLimit) {
            _ = try ProgramRuntime(program: program([.assign(assignment), .assign(assignment)]))
        }
        programFailure(t, .ambiguousClickHandler(id)) { _ = try ProgramRuntime(program: program([], ambiguous: true)) }
        for action in [ProgramAction.copy(.number(1)), .open(.boolean(true))] {
            let root = ProgramElement(id: id, content: .text(ProgramText("Tap")), onRightClickActions: [action])
            programFailure(t, .invalidExpression) { _ = try ProgramRuntime(program: WidgetProgram(name: "Invalid right", root: root)) }
        }
    }

    t.suite("Program: pointer events: dependencies include only the selected handler and shared projection") {
        let root = ProgramElement(id: id,
            content: .text(ProgramText(value: .concatenate([.systemProperty(.cpuCoreCount)]))),
            width: .fixed(40), height: .fixed(30),
            onClickActions: [.copy(.concatenate([.systemProperty(.memoryUsed)]))],
            onRightClickActions: [.copy(.concatenate([.systemProperty(.cpuUsage)]))])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Demand", root: root))
        t.equal(runtime.neededSystemProperties, [.cpuCoreCount])
        t.equal(runtime.neededSystemProperties(clickAt: point, event: .rightUp), [])
        let input = ProgramSystemInput(cpuUsage: 42, cpuCoreCount: 8, memoryUsed: 1024)
        let first = try runtime.project(environment: environment, systemInput: input, measure: measure)
        t.equal(runtime.neededSystemProperties(clickAt: point), [.memoryUsed, .cpuCoreCount])
        t.equal(runtime.neededSystemProperties(clickAt: point, event: .rightUp), [.cpuUsage, .cpuCoreCount])
        t.equal(runtime.neededSystemProperties(clickAt: SkinPoint(x: -1, y: 12), event: .rightUp), [])
        let right = try runtime.clickWithEffects(at: point, expectedGeneration: first.generation, event: .rightUp,
            environment: environment, systemInput: input, measure: measure)
        t.equal(right?.effects, [.copy("42")])
        t.equal(runtime.neededSystemProperties, [.cpuCoreCount])
        t.equal(runtime.clockPrecision, nil)
    }
}

private func runProgramPaletteTests(_ t: TestRunner) {
    let color = RGBA(r: 17, g: 31, b: 45, a: 96)
    let input = ProgramColorInput(colors: Dictionary(uniqueKeysWithValues: ProgramPaletteColor.allCases.map { ($0, color) }))
    func legacy(_ key: ProgramPaletteColor) -> ProgramColor {
        switch key {
        case .text: return .text
        case .dim: return .dim
        case .faint: return .faint
        case .accent: return .accent
        case .separator: return .separator
        default: return .palette(key)
        }
    }
    t.suite("Program: palette: every named color feeds the measured text fill and outline from one input") {
        for key in ProgramPaletteColor.allCases {
            let text = ProgramElement(id: ElementID(name: "text", index: 1), content: .text(ProgramText("色😀", color: legacy(key))))
            let fill = ProgramElement(id: ElementID(name: "fill", index: 2), content: .rectangle(fill: legacy(key)), width: .fixed(12), height: .fixed(10))
            let outline = ProgramElement(id: ElementID(name: "outline", index: 3), content: .rectangle(fill: .literal(.clear)),
                                         width: .fixed(12), height: .fixed(10), stroke: ProgramShapeStroke(color: legacy(key), width: 2))
            let root = ProgramElement(id: ElementID(name: "row", index: 0), content: .row(spacing: 2, align: .top, children: [text, fill, outline]))
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Palette", root: root))
            var measured: TextStyle?
            let scene = try runtime.project(environment: programEnvironment(), colorInput: input) { _, style, _ in
                measured = style; t.equal(style.color, color)
                return SkinSize(width: 8, height: 10)
            }
            guard scene.drawingItems.count == 3, case .fill(_, let paint) = scene.drawingItems[1],
                  case .shape(let drawing) = scene.drawingItems[2] else { return t.check(false, "complete palette recipe") }
            t.equal(programDraws(scene)[0].style, measured)
            t.equal(paint.color, color); t.equal(drawing.shapes[0].stroke, .color(color))
            t.equal(drawing.shapes[0].fill, .color(.clear))
        }
        let literal = RGBA(r: 1, g: 2, b: 3, a: 4)
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Literal", root:
            ProgramElement(id: ElementID(name: "text", index: 0), content: .text(ProgramText("A", color: .literal(literal))))))
        let scene = try runtime.project(environment: programEnvironment(), colorInput: input) { _, _, _ in SkinSize(width: 8, height: 10) }
        t.equal(programDraws(scene)[0].style.color, literal, "a platform palette never replaces a literal")
    }
    t.suite("Program: palette: absent input preserves the original eight colors and refuses new system hues") {
        let originals: [(ProgramPaletteColor, RGBA)] = [(.text, SkinAppearance.light.labelColor), (.dim, SkinAppearance.light.secondaryLabelColor),
            (.faint, SkinAppearance.light.tertiaryLabelColor), (.accent, SkinAppearance.light.accentColor), (.separator, SkinAppearance.light.separatorColor),
            (.white, .white), (.black, .black), (.clear, .clear)]
        for key in ProgramPaletteColor.allCases {
            var runtime = try ProgramRuntime(program: WidgetProgram(name: key.rawValue, root:
                ProgramElement(id: ElementID(name: "text", index: 0), content: .text(ProgramText("A", color: legacy(key))))))
            if let expected = originals.first(where: { $0.0 == key })?.1 {
                let scene = try runtime.project(environment: programEnvironment()) { _, _, _ in SkinSize(width: 8, height: 10) }
                t.equal(programDraws(scene)[0].style.color, expected)
            } else {
                programFailure(t, .missingColorInput(key)) { _ = try runtime.project(environment: programEnvironment()) { _, _, _ in SkinSize(width: 8, height: 10) } }
                t.equal(runtime.generation, 0)
            }
        }
    }
    t.suite("Program: palette: incomplete or invalid inputs retain neither startup nor failed click state") {
        let id = ElementID(name: "text", index: 0)
        let node = ProgramElement(id: id, content: .text(ProgramText(value:
            .conditional(.declaration(0), then: .string("On"), otherwise: .string("Off")), color: .palette(.blue))),
            onClick: [ProgramAssignment(declaration: 0, value: .not(.declaration(0)))])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Rollback", root: node,
            declarations: [ProgramDeclaration(name: "flag", kind: .variable, initial: .boolean(false))],
            onLoad: [ProgramAssignment(declaration: 0, value: .not(.declaration(0)))]))
        var incomplete = input.colors; incomplete.removeValue(forKey: .clear)
        var bad = [ProgramColorInput(colors: [:]), ProgramColorInput(colors: incomplete)]
        for component in [Double.nan, .infinity, -1, 256] {
            var colors = input.colors; colors[.blue] = RGBA(r: 17, g: component, b: 45, a: 96)
            bad.append(ProgramColorInput(colors: colors))
        }
        for colors in bad {
            programFailure(t, .invalidColorInput) { _ = try runtime.project(environment: programEnvironment(), colorInput: colors) { _, _, _ in SkinSize(width: 8, height: 10) } }
            t.equal(runtime.generation, 0)
        }
        let scene = try runtime.project(environment: programEnvironment(), colorInput: input) { _, _, _ in SkinSize(width: 8, height: 10) }
        t.equal(programDraws(scene).map(\.text), ["On"]); t.equal(scene.generation, 1)
        for colors in bad {
            programFailure(t, .invalidColorInput) {
                _ = try runtime.click(at: SkinPoint(x: 4, y: 4), expectedGeneration: 1, environment: programEnvironment(), colorInput: colors) { _, _, _ in SkinSize(width: 8, height: 10) }
            }
            t.equal(runtime.generation, 1); t.equal(runtime.clockPrecision, nil)
        }
        let recovered = try runtime.project(environment: programEnvironment(.dark), colorInput: input) { _, _, _ in SkinSize(width: 8, height: 10) }
        t.equal(programDraws(recovered).map(\.text), ["On"], "neither rejected assignments nor repeated onLoad changed the variable")
        let clicked = try runtime.click(at: SkinPoint(x: 4, y: 4), expectedGeneration: recovered.generation, environment: programEnvironment(.dark), colorInput: input) { _, _, _ in SkinSize(width: 8, height: 10) }
        t.equal(clicked.map { programDraws($0).map(\.text) }, ["Off"])
    }
}
