import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum CompilationFixtureError: Error { case missingProgram }

private func compileFixture(_ t: TestRunner, _ text: String, file: String = "Fixture.desk") throws -> WidgetProgram {
    let checked = deskCheck(text, file: file)
    let result = Desk.compile(checked)
    t.check(result.diagnostics(.error).isEmpty, "\(deskDescribe(checked))")
    t.check(result.issues.isEmpty, "\(result.issues)")
    guard let program = result.program else { throw CompilationFixtureError.missingProgram }
    return program
}

private extension DeskCompilationResult {
    func diagnostics(_ severity: Severity) -> [Diagnostic] { diagnostics.filter { $0.severity == severity } }
}

private func compileEnvironment(_ appearance: SkinAppearance = .light) -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1, appearance: AppearanceStamp(value: appearance, name: "fixture"), imageGeneration: 0)
}

private func compiledDraws(_ scene: WidgetScene) -> [TextDraw] {
    scene.drawingItems.compactMap { if case .text(let value) = $0 { return value }; return nil }
}

func runDeskCompilationTests(_ t: TestRunner) {
    t.suite("Desk: compilation: checked literal text becomes shared program and scene") {
        let source = "\u{FEFF}info { name: \"Literal\", size: .fit }\r\nwidget { Text(\"甲😀\\nB\").font(12).color(\"#123456\").name(title) }\r\n"
        let checked = deskCheck(source)
        let result = Desk.compile(checked)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked)); t.check(result.issues.isEmpty, "\(result.issues)")
        guard let program = result.program else { throw CompilationFixtureError.missingProgram }
        t.equal(program.name, "Literal"); t.equal(program.root.id, ElementID(name: "title", index: 0))
        var runtime = try ProgramRuntime(program: program)
        var actualStyle: TextStyle?
        let scene = try runtime.project(environment: compileEnvironment()) { text, style, width in
            t.equal(text, "甲😀\nB"); t.equal(width, nil); actualStyle = style
            return SkinSize(width: 14, height: 30)
        }
        let draw = compiledDraws(scene).first!
        t.equal(draw.text, "甲😀\nB"); t.equal(draw.style, actualStyle!)
        t.equal(draw.style.color, RGBA(r: 18, g: 52, b: 86)); t.close(TextStyle.pixelSize(points: draw.style.fontSize), 12)
        t.equal(scene.size, SkinSize(width: 14, height: 30)); t.equal(scene.elements[0].backing, .content)
        t.equal(checked.tree.text, source)
    }

    t.suite("Desk: compilation: nested stacks use catalog defaults and stable source order") {
        let program = try compileFixture(t, #"widget { Column(align: .left) { Text("A"); Row(align: .bottom) { Text("B"); Text("C") } } }"#)
        var runtime = try ProgramRuntime(program: program)
        let sizes = ["A": SkinSize(width: 10, height: 20), "B": SkinSize(width: 20, height: 8), "C": SkinSize(width: 3, height: 5)]
        let scene = try runtime.project(environment: compileEnvironment()) { text, _, _ in sizes[text]! }
        t.equal(scene.size, SkinSize(width: 31, height: 36)) // 20 + catalog 8 + 8; row 20 + 8 + 3
        t.equal(scene.elements.map(\.id.index), [0, 1, 2, 3, 4])
        t.equal(scene.elements[1].frame, SkinRect(width: 10, height: 20))
        t.equal(scene.elements[3].frame, SkinRect(x: 0, y: 28, width: 20, height: 8))
        t.equal(scene.elements[4].frame, SkinRect(x: 28, y: 31, width: 3, height: 5))
        t.equal(compiledDraws(scene).map(\.text), ["A", "B", "C"])
        let implicit = try compileFixture(t, #"widget { Text("A"); Text("B") }"#)
        var implicitRuntime = try ProgramRuntime(program: implicit)
        let implicitScene = try implicitRuntime.project(environment: compileEnvironment()) { text, _, _ in sizes[text]! }
        t.equal(implicit.root.id, ElementID(name: "widget", index: 0))
        t.equal(implicitScene.size, SkinSize(width: 20, height: 36))
        t.equal(implicitScene.elements[1].frame.x, 5)
    }

    t.suite("Desk: compilation: facet precedence inheritance and appearance stay typed") {
        let program = try compileFixture(t, ##"widget { Column { Text("A").font(13).bold(); Text("B").font(.caption).color("#00AA88") }.font(.headline).color(.dim) }"##)
        var runtime = try ProgramRuntime(program: program)
        let light = try runtime.project(environment: compileEnvironment()) { _, _, _ in SkinSize(width: 10, height: 16) }
        let dark = try runtime.project(environment: compileEnvironment(.dark)) { _, _, _ in SkinSize(width: 10, height: 16) }
        let draws = compiledDraws(light), darkDraws = compiledDraws(dark)
        t.equal(draws.count, 2)
        t.close(TextStyle.pixelSize(points: draws[0].style.fontSize), 13); t.equal(draws[0].style.fontWeight, 700)
        t.close(TextStyle.pixelSize(points: draws[1].style.fontSize), 11); t.equal(draws[1].style.fontWeight, 500)
        t.equal(draws[0].style.color, SkinAppearance.light.secondaryLabelColor)
        t.equal(darkDraws[0].style.color, SkinAppearance.dark.secondaryLabelColor)
        t.equal(draws[1].style.color, RGBA(r: 0, g: 170, b: 136)); t.equal(darkDraws[1].style.color, draws[1].style.color)
        t.equal(light.elements.map(\.frame), dark.elements.map(\.frame))
        let hidden = try compileFixture(t, #"widget { Column(spacing: 2, align: .left) { Text("A").font(13).padding(1).size(12, 22).hidden(); Text("B") }.padding(3) }"#)
        var hiddenRuntime = try ProgramRuntime(program: hidden)
        let hiddenScene = try hiddenRuntime.project(environment: compileEnvironment()) { text, _, _ in
            text == "A" ? SkinSize(width: 10, height: 20) : SkinSize(width: 6, height: 8)
        }
        t.equal(hiddenScene.size, SkinSize(width: 18, height: 38))
        t.equal(hiddenScene.elements[1].visibility, .hiddenKeepsSpace)
        t.equal(hiddenScene.elements[2].frame, SkinRect(x: 3, y: 27, width: 6, height: 8))
        t.equal(compiledDraws(hiddenScene).map(\.text), ["B"])
    }

    t.suite("Desk: compilation: unsupported semantics fail with original source diagnostics") {
        let cases = [#"info { size: .small }"# + "\n" + #"widget { Text("A") }"#,
                     #"info { description: "Metadata" }"# + "\n" + #"widget { Text("A") }"#,
                     #"options { show = Toggle("Show") }"# + "\n" + #"widget { Text("A") }"#,
                     #"style label { .font(13) }"# + "\n" + #"widget { Text("A").style(label) }"#,
                     #"widget { Grid(columns: 2) { Text("A") } }"#,
                     #"widget { Freeform { Text("A") } }"#,
                     #"widget { Text("A").width(.fill) }"#,
                     #"widget { Text("A").width(20, min: 10) }"#,
                     #"widget { Text("A").offset(x: 2) }"#,
                     #"widget { Text("A").color(.red) }"#,
                     #"widget { Text("A").color(.dim, if: true) }"#,
                     #"widget { Text("A").font(.largeNumber) }"#,
                     #"widget { Text("{cpu.usage}") }"#,
                     #"widget { computed value = 1; Text(value) }"#,
                     #"widget { Row(align: .baseline) { Text("A") } }"#]
        for source in cases {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked)) // genuinely checked unsupported input
            let result = Desk.compile(checked)
            t.check(result.program == nil, source)
            t.check(!result.issues.isEmpty, source)
            if let issue = result.issues.first {
                t.equal(issue.file, checked.tree.file)
                t.check(issue.range.lowerBound >= 0 && issue.range.upperBound <= source.utf8.count && !issue.message.isEmpty)
            }
            t.equal(result.diagnostics.map(\.id), checked.diagnostics.map(\.id))
        }
        let bad = deskCheck(#"widget { Text("A").unknownModifier() }"#)
        let invalid = Desk.compile(bad)
        t.check(!bad.diagnostics(.error).isEmpty)
        t.check(invalid.program == nil); t.equal(invalid.diagnostics.map(\.id), bad.diagnostics.map(\.id))
    }

    t.suite("Desk: compilation: reparsing preserves identity and compiler budgets are enforced") {
        let first = #"widget { Column { Text("A").name(first); Text("B") } }"#
        let second = "// moved bytes, a new tree version\nwidget {\n    Column { Text(\"A\").name(first);\n        Text(\"B\") }\n}\n"
        let a = try compileFixture(t, first), b = try compileFixture(t, second)
        t.equal(a, b)
        var ra = try ProgramRuntime(program: a), rb = try ProgramRuntime(program: b)
        let sa = try ra.project(environment: compileEnvironment()) { _, _, _ in SkinSize(width: 10, height: 16) }
        let sb = try rb.project(environment: compileEnvironment()) { _, _, _ in SkinSize(width: 10, height: 16) }
        t.equal(sa.elements.map(\.id), sb.elements.map(\.id))
        var catalog = DeskCatalog.current
        catalog.limits.maximumElementInstances = 2
        let checkerLimited = deskCheck(first, context: CheckContext(catalog: catalog))
        let rejected = Desk.compile(checkerLimited, catalog: catalog)
        t.check(checkerLimited.diagnostics.contains { $0.id == .tooManyElements && $0.severity == .error })
        t.check(rejected.program == nil && rejected.issues.isEmpty)
        t.equal(rejected.diagnostics.map(\.id), checkerLimited.diagnostics.map(\.id))
        // Two checked elements fit the catalog budget, but their implicit Column is a third shared element.
        let checked = deskCheck(#"widget { Text("A"); Text("B") }"#, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        let limited = Desk.compile(checked, catalog: catalog)
        t.check(limited.program == nil)
        t.equal(limited.issues.first?.kind, .resourceLimit)
        let noContent = Desk.compile(deskCheck("widget { Column { } }"))
        t.check(noContent.program == nil)
        t.check(!noContent.issues.isEmpty || noContent.diagnostics.contains { $0.severity == .error })
    }
}
