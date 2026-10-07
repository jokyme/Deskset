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
    runDeskPaletteCompilationTests(t)
    runDeskFontSizeCompilationTests(t)
    runDeskCompilationReferenceTests(t)
    runDeskPointRadiusCompilationTests(t)
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

    t.suite("Desk: compilation: original numeric and number-preset literals produce exact shared styles") {
        // These original unsupported controls become positive when plain numbers and equal-width digits are implemented.
        let number = try compileFixture(t, #"widget { computed value = 1; Text(value) }"#)
        t.equal(number.declarations, [ProgramDeclaration(name: "value", kind: .computed, initial: .number(1))])
        var numericRuntime = try ProgramRuntime(program: number)
        let numericScene = try numericRuntime.project(environment: compileEnvironment()) { _, _, _ in SkinSize(width: 10, height: 16) }
        guard let numericDraw = compiledDraws(numericScene).first else { throw CompilationFixtureError.missingProgram }
        t.equal(numericDraw.text, "1")
        t.equal(numericDraw.style.inlineSpans, [InlineSpan(location: 0, length: 1, setting: .typography(feature: "tnum", value: 1))])

        let percentage = try compileFixture(t, #"widget { computed value = 1%; Text(value) }"#)
        t.equal(percentage.declarations, [ProgramDeclaration(name: "value", kind: .computed, initial: .quantity(ProgramNumber(1, dimension: .percent)))])
        var percentRuntime = try ProgramRuntime(program: percentage)
        let percentScene = try percentRuntime.project(environment: compileEnvironment()) { _, _, _ in SkinSize(width: 10, height: 16) }
        guard let percentDraw = compiledDraws(percentScene).first else { throw CompilationFixtureError.missingProgram }
        t.equal(percentDraw.text, "1")
        t.equal(percentDraw.style.inlineSpans, [InlineSpan(location: 0, length: 1, setting: .typography(feature: "tnum", value: 1))])

        let preset = try compileFixture(t, #"widget { Text("A").font(.largeNumber) }"#)
        var presetRuntime = try ProgramRuntime(program: preset)
        var measuredStyle: TextStyle?
        let presetScene = try presetRuntime.project(environment: compileEnvironment()) { text, style, _ in
            t.equal(text, "A"); measuredStyle = style
            return SkinSize(width: 10, height: 16)
        }
        guard let presetDraw = compiledDraws(presetScene).first else { throw CompilationFixtureError.missingProgram }
        t.equal(presetDraw.text, "A"); t.equal(presetDraw.style.fontFace, "System Rounded")
        t.close(TextStyle.pixelSize(points: presetDraw.style.fontSize), 34); t.equal(presetDraw.style.fontWeight, 600)
        t.equal(presetDraw.style.inlineSpans, [InlineSpan(location: 0, length: 1, setting: .typography(feature: "tnum", value: 1))])
        t.equal(presetDraw.style, measuredStyle, "the equal-width preset is measured with its final drawing style")
    }

    t.suite("Desk: compilation: unsupported semantics fail with original source diagnostics") {
        let cases = [#"info { size: .small }"# + "\n" + #"widget { Text("A") }"#,
                     #"info { description: "Metadata" }"# + "\n" + #"widget { Text("A") }"#,
                     #"options { show = Toggle("Show") }"# + "\n" + #"widget { Text("A") }"#,
                     #"style label { .font(13) }"# + "\n" + #"widget { Text("A").style(label) }"#,
                     #"widget { Grid(columns: 2) { Text("A") } }"#,
                     #"widget { Freeform { Text("A") } }"#,
                     #"widget { Text("A").width(.fill).margin(1) }"#,
                     #"widget { Text("A").width(20, min: 10).margin(1) }"#,
                     #"widget { Text("A").offset(x: 2) }"#,
                     #"widget { Text("A").color(.red, if: true) }"#,
                     #"widget { Text("A").color(.dim, if: true) }"#,
                     #"widget { Text("A").font(.largeNumber).margin(1) }"#,
                     #"widget { computed value = 1KB / 1s; Text(value) }"#,
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

    t.suite("Desk: rectangles: checked solid boxes retain defaults identity order and text-only inheritance") {
        let source = ##"widget { Column(spacing: 3, align: .left) { Rectangle().size(12, 8).padding(2).name(first); Rectangle().width(6).height(4).fill("#12345680").hidden(); Text("A") }.font(20).color(.dim) }"##
        let program = try compileFixture(t, source)
        var runtime = try ProgramRuntime(program: program)
        for appearance in [SkinAppearance.light, .dark] {
            var queries = 0
            let scene = try runtime.project(environment: compileEnvironment(appearance)) { text, style, _ in
                queries += 1; t.equal(text, "A"); t.close(TextStyle.pixelSize(points: style.fontSize), 20)
                return SkinSize(width: 5, height: 10)
            }
            t.equal(queries, 1)
            t.equal(scene.size, SkinSize(width: 12, height: 28))
            t.equal(scene.elements.map(\.id.index), [0, 1, 2, 3])
            t.equal(scene.elements[1].id, ElementID(name: "first", index: 1))
            t.equal(scene.elements[2].frame, SkinRect(x: 0, y: 11, width: 6, height: 4))
            t.equal(scene.elements[3].frame, SkinRect(x: 0, y: 18, width: 5, height: 10))
            t.equal(scene.drawingItems.first, .fill(SkinRect(x: 2, y: 2, width: 8, height: 4), Paint(color: appearance.labelColor)))
            t.equal(scene.drawingItems.count, 2)
            t.equal(compiledDraws(scene).first?.style.color, appearance.secondaryLabelColor)
        }
        let literal = try compileFixture(t, ##"widget { Rectangle().size(18).fill("#12345680") }"##)
        var literalRuntime = try ProgramRuntime(program: literal)
        let scene = try literalRuntime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }
        t.equal(scene.drawingItems, [.fill(SkinRect(width: 18, height: 18), Paint(color: RGBA(r: 18, g: 52, b: 86, a: 128)))])
        let moved = try compileFixture(t, "// moved UTF8 bytes 😀\n" + source)
        t.equal(moved, program, "rectangle identity is the original occurrence, not the syntax tree version")
    }

    t.suite("Desk: rectangles: the actual checking catalog supplies the solid fill default") {
        var catalog = DeskCatalog.current
        guard let index = catalog.components.firstIndex(where: { $0.name == "Rectangle" }) else { throw CompilationFixtureError.missingProgram }
        catalog.components[index].defaults["fill"] = ".accent"
        let source = #"widget { Rectangle().size(12, 8) }"#
        let checked = deskCheck(source, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        let compiled = Desk.compile(checked, catalog: catalog)
        t.check(compiled.issues.isEmpty, "\(compiled.issues)")
        guard let program = compiled.program else { throw CompilationFixtureError.missingProgram }
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: compileEnvironment(.dark)) { _, _, _ in throw CompilationFixtureError.missingProgram }
        t.equal(scene.drawingItems, [.fill(SkinRect(width: 12, height: 8), Paint(color: SkinAppearance.dark.accentColor))])
        catalog.components[index].defaults.removeValue(forKey: "fill")
        let absent = deskCheck(source, context: CheckContext(catalog: catalog))
        t.check(absent.diagnostics(.error).isEmpty, deskDescribe(absent))
        let missing = Desk.compile(absent, catalog: catalog)
        t.check(missing.program == nil)
        t.equal(missing.issues.first?.kind, .invalidCheckedModel)
        t.equal(missing.diagnostics.map(\.id), absent.diagnostics.map(\.id))
    }

    t.suite("Desk: rectangles: unsupported paint sizing and facets reject the complete checked program") {
        let sources = [#"Rectangle().margin(1)"#, #"Rectangle().width(12).offset(x: 1)"#, #"Rectangle().height(8).margin(1)"#,
                       #"Rectangle().width(.fit).height(8).margin(1)"#, #"Rectangle().width(.fill).height(8).offset(x: 1)"#,
                       #"Rectangle().width(12, min: 8).height(8).margin(1)"#, #"Rectangle().size(12).rounded(2, topLeft: 0)"#,
                       #"Rectangle().size(12).stroke(.accent, dash: [2, 3])"#, #"Rectangle().size(12).fill(.accent).stroke(gradient(.black, .white))"#,
                       #"Rectangle().size(12).fill(gradient(.black, .white))"#,
                       #"Rectangle().size(12).fill(radialGradient(.white, .clear))"#,
                       #"Rectangle().size(12).fill(.red, if: true)"#, #"Rectangle().size(12).fill(.accent, if: true)"#,
                       #"Rectangle().size(12).background(.accent)"#, #"Rectangle().size(12).opacity(0.5)"#,
                       #"Circle().size(12).fill(.accent).stroke(.white, dash: [2, 3])"#]
        for element in sources {
            let source = "widget { Column { Text(\"must not paint partially\"); " + element + " } }"
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            let result = Desk.compile(checked)
            t.check(result.program == nil, source)
            t.equal(result.issues.first?.kind, .unsupported, source)
            guard let issue = result.issues.first else { throw CompilationFixtureError.missingProgram }
            t.equal(issue.file, checked.tree.file)
            t.check(issue.range.lowerBound >= 0 && issue.range.upperBound <= source.utf8.count && !issue.range.isEmpty)
            t.equal(result.diagnostics.map(\.id), checked.diagnostics.map(\.id))
        }
        let checked = deskCheck(#"widget { Rectangle().size(-1).unknownModifier() }"#)
        t.check(!checked.diagnostics(.error).isEmpty)
        let invalid = Desk.compile(checked)
        t.check(invalid.program == nil && invalid.issues.isEmpty)
        t.equal(invalid.diagnostics.map(\.id), checked.diagnostics.map(\.id))
    }

    t.suite("Desk: flex layout: original unsupported sizing literals now use checked catalog ideals") {
        let cases: [(String, SkinSize)] = [(#"Rectangle()"#, SkinSize(width: 10, height: 10)),
                                          (#"Rectangle().width(12)"#, SkinSize(width: 12, height: 10)),
                                          (#"Rectangle().height(8)"#, SkinSize(width: 10, height: 8)),
                                          (#"Rectangle().width(.fit).height(8)"#, SkinSize(width: 10, height: 8)),
                                          (#"Rectangle().width(.fill).height(8)"#, SkinSize(width: 10, height: 8)),
                                          (#"Rectangle().width(12, min: 8).height(8)"#, SkinSize(width: 12, height: 8)),
                                          (#"Rectangle().width(.fit, min: 20, max: 30).height(8)"#, SkinSize(width: 20, height: 8)),
                                          (#"Rectangle().width(.fill, max: 6).height(8)"#, SkinSize(width: 6, height: 8))]
        for (element, size) in cases {
            let program = try compileFixture(t, "widget { " + element + " }")
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }
            t.equal(scene.size, size)
            t.equal(scene.drawingItems, [.fill(SkinRect(width: size.width, height: size.height), Paint(color: SkinAppearance.light.labelColor))])
            // Preserve the whole original negative buffer as a positive now, including the preceding Text.
            let original = "widget { Column { Text(\"must not paint partially\"); " + element + " } }"
            var mixed = try ProgramRuntime(program: compileFixture(t, original))
            let full = try mixed.project(environment: compileEnvironment()) { _, _, _ in SkinSize(width: 2, height: 4) }
            t.equal(full.size, SkinSize(width: max(size.width, 2), height: size.height + 12))
            t.equal(full.drawingItems.count, 2)
        }
        for source in [#"widget { Text("A").width(.fill) }"#, #"widget { Text("A").width(20, min: 10) }"#] {
            var runtime = try ProgramRuntime(program: compileFixture(t, source))
            let scene = try runtime.project(environment: compileEnvironment()) { _, _, _ in SkinSize(width: 10, height: 8) }
            t.equal(scene.size.height, 8)
            t.equal(scene.size.width, source.contains("20") ? 20 : 10)
            t.equal(compiledDraws(scene).map(\.text), ["A"])
        }
        var catalog = DeskCatalog.current
        guard let index = catalog.components.firstIndex(where: { $0.name == "Rectangle" }) else { throw CompilationFixtureError.missingProgram }
        catalog.components[index].sizing = SizingDefaults(width: ".fit", height: ".fill", idealWhenUnspecified: IdealSize(width: 13, height: 7))
        let source = #"widget { Rectangle() }"#
        let result = Desk.compile(deskCheck(source, context: CheckContext(catalog: catalog)), catalog: catalog)
        guard let program = result.program else { throw CompilationFixtureError.missingProgram }
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }
        t.equal(scene.size, SkinSize(width: 13, height: 7), "no built-in 10 replaces the actual checking catalog")
        t.equal(scene.drawingItems, [.fill(SkinRect(width: 13, height: 7), Paint(color: SkinAppearance.light.labelColor))])
    }

    t.suite("Desk: flex layout: checked min max and nested flexibility reach the shared allocation") {
        let source = #"widget { Column(spacing: 4, align: .left) { Rectangle().height(.fill, min: 10, max: 15); Rectangle().height(.fill, min: 20, max: 30); Rectangle().height(.fill, min: 5) }.width(20).height(100) }"#
        var runtime = try ProgramRuntime(program: compileFixture(t, source))
        let scene = try runtime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }
        t.equal(scene.size, SkinSize(width: 20, height: 100))
        t.equal(scene.elements.dropFirst().map(\.frame), [SkinRect(width: 20, height: 15), SkinRect(y: 19, width: 20, height: 30),
                                                         SkinRect(y: 53, width: 20, height: 47)])
        let nested = #"widget { Column(spacing: 2) { Text("A"); Column(spacing: 3) { Text("B"); Rectangle() }; Rectangle().hidden() }.width(40).height(60) }"#
        var nestedRuntime = try ProgramRuntime(program: compileFixture(t, nested))
        let output = try nestedRuntime.project(environment: compileEnvironment()) { text, _, _ in
            text == "A" ? SkinSize(width: 10, height: 8) : SkinSize(width: 6, height: 5)
        }
        t.equal(output.elements.map(\.frame), [SkinRect(width: 40, height: 60), SkinRect(x: 15, width: 10, height: 8),
                                               SkinRect(y: 10, width: 40, height: 28), SkinRect(x: 17, y: 10, width: 6, height: 5),
                                               SkinRect(y: 18, width: 40, height: 20), SkinRect(y: 40, width: 40, height: 20)])
        t.equal(output.elements.last?.visibility, .hiddenKeepsSpace)
        t.equal(output.drawingItems.count, 3)
        let moved = try compileFixture(t, "// changed source version😀\n" + nested)
        t.equal(moved, nestedRuntime.program)
    }

    t.suite("Desk: flex layout: conditional geometry margin presets and invalid bounds remain explicit failures") {
        for source in [#"widget { Rectangle().width(.fill, if: true) }"#, #"widget { Rectangle().height(.fill, min: 5).margin(1) }"#,
                       #"info { size: .small }; widget { Rectangle() }"#, #"widget { Rectangle().height(.fill).rounded(2, topLeft: 0) }"#] {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            let result = Desk.compile(checked)
            t.check(result.program == nil && result.issues.first?.kind == .unsupported, source)
            t.equal(result.diagnostics.map(\.id), checked.diagnostics.map(\.id))
        }
        let source = #"widget { Rectangle().width(.fill, min: 20, max: 10) }"#
        let checked = deskCheck(source)
        let rejected = Desk.compile(checked)
        t.check(rejected.program == nil)
        t.check(!rejected.issues.isEmpty || rejected.diagnostics.contains { $0.severity == .error })
        t.equal(rejected.diagnostics.map(\.id), checked.diagnostics.map(\.id))
        let overflow = try compileFixture(t, #"widget { Column { Rectangle().height(.fill, min: 20) }.height(10) }"#)
        var runtime = try ProgramRuntime(program: overflow)
        t.throwsError { _ = try runtime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram } }
        t.equal(runtime.generation, 0, "minimum overflow is not squeezed or partially published; preset scaling is pending")
    }

    t.suite("Desk: flex precision: fractional checked rows reach exact shared budget guards") {
        let cases: [(source: String, width: Double, sizes: [Double], origins: [Double])] = [
            (#"widget { Row(spacing: 0) { Rectangle(); Rectangle(); Rectangle() }.width(0.9).height(1) }"#, 0.9, [0.3, 0.3, 0.3], [0, 0.3, 0.6]),
            (#"widget { Row(spacing: 0) { Rectangle(); Rectangle(); Rectangle() }.width(30.9).height(1) }"#, 30.9, [10.3, 10.3, 10.3], [0, 10.3, 20.6]),
            (#"widget { Row(spacing: 0.1) { Rectangle(); Rectangle(); Rectangle(); Rectangle(); Rectangle() }.width(1.4).height(1) }"#, 1.4, [0.2, 0.2, 0.2, 0.2, 0.2], [0, 0.3, 0.6, 0.9, 1.2]),
            (#"widget { Row(spacing: 0) { Rectangle().width(.fill, max: 0.1); Rectangle(); Rectangle() }.width(0.9).height(1) }"#, 0.9, [0.1, 0.4, 0.4], [0, 0.1, 0.5]),
            (#"widget { Row(spacing: 0) { Rectangle().width(.fill, min: 0.1, max: 0.1); Rectangle(); Rectangle() }.width(0.9).height(1) }"#, 0.9, [0.1, 0.4, 0.4], [0, 0.1, 0.5]),
            (#"widget { Row(spacing: 0) { Rectangle(); Rectangle().width(0.1); Rectangle(); Rectangle() }.width(0.4).height(1) }"#, 0.4, [0.1, 0.1, 0.1, 0.1], [0, 0.1, 0.2, 0.3])
        ]
        for value in cases {
            let program = try compileFixture(t, value.source)
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }
            t.equal(scene.size, SkinSize(width: value.width, height: 1))
            t.equal(scene.drawingItems.count, value.sizes.count)
            for (i, element) in scene.elements.dropFirst().enumerated() {
                t.close(element.frame.width, value.sizes[i]); t.close(element.frame.x, value.origins[i])
                t.check(element.frame.x >= 0 && element.frame.x + element.frame.width <= value.width)
            }
        }
        let program = try compileFixture(t, #"widget { Row(spacing: 0) { Rectangle().width(.fill, min: 0.3); Rectangle().width(.fill, min: 0.31); Rectangle().width(.fill, min: 0.3) }.width(0.9).height(1) }"#)
        var runtime = try ProgramRuntime(program: program)
        do {
            _ = try runtime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }
            t.check(false, "a genuine minimum larger than the exact budget must fail")
        } catch { t.equal(error as? ProgramRuntimeError, .layoutOverflow(program.root.id)) }
        t.equal(runtime.generation, 0)
    }

    t.suite("Desk: shapes: checked curve defaults and the original Circle literal become real shared content") {
        for (name, kind) in [("Circle", ProgramShapeKind.circle), ("Ellipse", .ellipse), ("Capsule", .capsule)] {
            let program = try compileFixture(t, "widget { " + name + "() }")
            t.equal(program.root.content, .shape(kind: kind, fill: .text))
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }
            t.equal(scene.size, SkinSize(width: 10, height: 10))
            guard let item = scene.drawingItems.first, case .shape(let draw) = item else { return t.check(false, "checked shape must reach the shared draw consumer") }
            t.equal(draw.shapes.first?.fill, .color(SkinAppearance.light.labelColor))
        }
        // These are the exact old unsupported leaf and its complete original mixed-buffer context.
        for source in [#"widget { Circle().size(12).fill(.accent) }"#,
                       #"widget { Column { Text("must not paint partially"); Circle().size(12).fill(.accent) } }"#] {
            let program = try compileFixture(t, source)
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: compileEnvironment()) { _, _, _ in SkinSize(width: 2, height: 4) }
            guard let item = scene.drawingItems.last, case .shape(let draw) = item else { return t.check(false, "the original Circle literal now paints") }
            t.equal(draw.shapes[0].fill, .color(SkinAppearance.light.accentColor))
            t.equal(draw.contentFrame, source.contains("Column") ? SkinRect(y: 12, width: 12, height: 12) : SkinRect(width: 12, height: 12))
            t.equal(scene.drawingItems.count, source.contains("Column") ? 2 : 1)
        }
        let source = #"widget { Row(spacing: 4) { Circle(); Ellipse(); Capsule().hidden() }.width(98).height(20).color(.dim) }"#
        let program = try compileFixture(t, source)
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: compileEnvironment(.dark)) { _, _, _ in throw CompilationFixtureError.missingProgram }
        t.equal(scene.size, SkinSize(width: 98, height: 20))
        t.equal(scene.elements.map(\.id.index), [0, 1, 2, 3])
        t.equal(scene.elements.dropFirst().map(\.frame), [SkinRect(width: 30, height: 20),
            SkinRect(x: 34, width: 30, height: 20), SkinRect(x: 68, width: 30, height: 20)])
        let shapes = scene.drawingItems.compactMap { item -> ShapeDraw? in if case .shape(let value) = item { return value }; return nil }
        t.equal(shapes.count, 2)
        t.check(shapes.allSatisfy { $0.shapes[0].fill == .color(SkinAppearance.dark.labelColor) }, "container text color is not a shape fill")
        t.equal(try compileFixture(t, "// moved😀\n" + source), program)
    }

    t.suite("Desk: shapes: actual curve catalog defaults ideals and missing-default diagnostics are consumed") {
        for name in ["Circle", "Ellipse", "Capsule"] {
            var catalog = DeskCatalog.current
            guard let index = catalog.components.firstIndex(where: { $0.name == name }) else { throw CompilationFixtureError.missingProgram }
            catalog.components[index].defaults["fill"] = ".accent"
            catalog.components[index].sizing = SizingDefaults(width: ".fit", height: ".fill", idealWhenUnspecified: IdealSize(width: 13, height: 7))
            let source = "widget { " + name + "() }"
            let checked = deskCheck(source, context: CheckContext(catalog: catalog))
            let result = Desk.compile(checked, catalog: catalog)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked)); t.check(result.issues.isEmpty, "\(result.issues)")
            guard let program = result.program else { throw CompilationFixtureError.missingProgram }
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: compileEnvironment(.dark)) { _, _, _ in throw CompilationFixtureError.missingProgram }
            t.equal(scene.size, SkinSize(width: 13, height: 7))
            guard let item = scene.drawingItems.first, case .shape(let draw) = item else { return t.check(false, "modified catalog really reaches native recipe") }
            t.equal(draw.shapes[0].fill, .color(SkinAppearance.dark.accentColor))
            catalog.components[index].defaults.removeValue(forKey: "fill")
            let absent = deskCheck(source, context: CheckContext(catalog: catalog))
            let missing = Desk.compile(absent, catalog: catalog)
            t.check(absent.diagnostics(.error).isEmpty, deskDescribe(absent))
            t.check(missing.program == nil); t.equal(missing.issues.first?.kind, .invalidCheckedModel)
            t.equal(missing.diagnostics.map(\.id), absent.diagnostics.map(\.id))
        }
    }

    t.suite("Desk: shapes: unimplemented curve facets and other primitives still reject the complete program") {
        for name in ["Circle", "Ellipse", "Capsule"] {
            for suffix in [".stroke(.accent, dash: [2, 3])", ".fill(gradient(.black, .white))", ".fill(.accent, if: true)", ".opacity(0.5)", ".margin(1)"] {
                let source = "widget { Column { Text(\"must not paint partially\"); " + name + "().size(12)" + suffix + " } }"
                let checked = deskCheck(source), result = Desk.compile(checked)
                t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
                t.check(result.program == nil); t.equal(result.issues.first?.kind, .unsupported)
                t.equal(result.diagnostics.map(\.id), checked.diagnostics.map(\.id))
            }
        }
        for primitive in [#"Line().size(12)"#, #"Arc(from: 0, to: 270).size(12)"#, #"Path("M0 0 L10 0 L10 10 Z").size(12)"#] {
            let checked = deskCheck("widget { " + primitive + " }"), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil); t.equal(result.issues.first?.kind, .unsupported)
        }
    }

    t.suite("Desk: shape style: original outlined and rounded literals become complete shared content") {
        // Keep the full original negative buffers as positive controls, including their preceding text.
        let elements = [#"Rectangle().size(12).rounded(2)"#, #"Rectangle().size(12).stroke(.accent)"#,
                        #"Rectangle().size(12).fill(.accent).stroke(.white)"#, #"Circle().size(12).fill(.accent).stroke(.white)"#,
                        #"Circle().size(12).stroke(.accent)"#, #"Ellipse().size(12).stroke(.accent)"#, #"Capsule().size(12).stroke(.accent)"#]
        for element in elements {
            let source = "widget { Column { Text(\"must not paint partially\"); " + element + " } }"
            let program = try compileFixture(t, source)
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: compileEnvironment(.dark)) { _, _, _ in SkinSize(width: 2, height: 4) }
            t.equal(scene.drawingItems.count, 2); t.equal(compiledDraws(scene).map(\.text), ["must not paint partially"])
            guard case .shape(let draw) = scene.drawingItems[1] else { return t.check(false, "actual shared shape lowering") }
            t.equal(draw.contentFrame, SkinRect(y: 12, width: 12, height: 12))
            let item = draw.shapes[0]
            if element.contains("stroke") {
                t.equal(item.strokePlan?.width, 1)
                t.equal(item.stroke, .color(element.contains(".white") ? .white : SkinAppearance.dark.accentColor))
                t.equal(item.fill.isVisible, element.contains("fill"))
            } else { t.check(item.fill.isVisible && item.strokePlan == nil) }
            t.equal(try compileFixture(t, "// moved😀\n" + source), program)
        }
        let original = #"widget { Rectangle().height(.fill).rounded(2) }"#
        var runtime = try ProgramRuntime(program: compileFixture(t, original))
        t.equal(try runtime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }.size,
                SkinSize(width: 10, height: 10))
    }

    t.suite("Desk: shape style: catalog stroke width and explicit uniform radii reach real geometry") {
        var catalog = DeskCatalog.current
        guard let index = catalog.modifiers.firstIndex(where: { $0.name == "stroke" }),
              let parameter = catalog.modifiers[index].signatures[0].params.firstIndex(where: { $0.name == "width" }) else {
            throw CompilationFixtureError.missingProgram
        }
        catalog.modifiers[index].signatures[0].params[parameter].defaultValue = .source("3.5")
        let source = #"widget { Rectangle().size(30, 18).stroke(.accent).rounded(.full) }"#
        let checked = deskCheck(source, context: CheckContext(catalog: catalog)), result = Desk.compile(checked, catalog: catalog)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked)); t.check(result.issues.isEmpty, "\(result.issues)")
        guard let program = result.program else { throw CompilationFixtureError.missingProgram }
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }
        guard case .shape(let draw)? = scene.drawingItems.first else { return t.check(false, "real catalog outline") }
        t.equal(draw.shapes[0].strokePlan?.width, 3.5); t.check(!draw.shapes[0].fill.isVisible)
        catalog.modifiers[index].signatures[0].params[parameter].defaultValue = nil
        let missing = Desk.compile(deskCheck(source, context: CheckContext(catalog: catalog)), catalog: catalog)
        t.check(missing.program == nil); t.equal(missing.issues.first?.kind, .invalidCheckedModel)
        for (rounding, radius) in [(".rounded(3)", 3.0), (".rounded(.full)", 9.0), (".rounded(100)", 9.0),
                                  (".rounded(3, topLeft: 3)", 3.0),
                                  (".rounded(topLeft: 3, topRight: 3, bottomLeft: 3, bottomRight: 3)", 3.0)] {
            var rounded = try ProgramRuntime(program: compileFixture(t, "widget { Rectangle().size(30, 18)" + rounding + " }"))
            let value = try rounded.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }
            guard case .shape(let drawing)? = value.drawingItems.first, case .path(let path) = drawing.shapes[0].geometry else {
                return t.check(false, "actual uniform corner path")
            }
            t.equal(path.subpaths[0].start, ShapePoint(radius, 0))
            t.equal(path.subpaths[0].segments[1].kind.end, ShapePoint(30, radius))
        }
        var zero = try ProgramRuntime(program: compileFixture(t, #"widget { Rectangle().size(12).rounded(0) }"#))
        t.equal(try zero.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }.drawingItems,
                [.fill(SkinRect(width: 12, height: 12), Paint(color: SkinAppearance.light.labelColor))])
    }

    t.suite("Desk: shape style: dash gradients unequal corners and conditional paint reject the whole document") {
        for suffix in [".stroke(.accent, dash: [2, 3])", ".stroke(gradient(.black, .white))", ".stroke(.accent, if: true)",
                       ".rounded(3, topLeft: 0)", ".rounded(3, if: true)"] {
            let source = "widget { Column { Text(\"must not paint partially\"); Rectangle().size(12)" + suffix + " } }"
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil); t.equal(result.issues.first?.kind, .unsupported)
            t.equal(result.diagnostics.map(\.id), checked.diagnostics.map(\.id))
        }
        let noRadius = deskCheck(#"widget { Column { Text("must not paint partially"); Rectangle().size(12).rounded() } }"#)
        let invalid = Desk.compile(noRadius)
        t.check(noRadius.diagnostics.contains { $0.id == .missingArgument && $0.severity == .error })
        t.check(invalid.program == nil && invalid.issues.isEmpty, "the original checker rejects absent radius, without inventing a default")
        t.equal(invalid.diagnostics.map(\.id), noRadius.diagnostics.map(\.id))
        let nonRectangle = deskCheck(#"widget { Circle().size(12).rounded(3) }"#)
        t.check(nonRectangle.diagnostics(.error).isEmpty, deskDescribe(nonRectangle))
        t.equal(Desk.compile(nonRectangle).issues.first?.kind, .unsupported)
    }

    t.suite("Desk: image compilation: literal sources defaults and four modes reach shared scenes") {
        for (suffix, mode, aspect, tile) in [("", ProgramImageMode.fit, 1, false), (".imageMode(.fill)", .fill, 2, false),
                                           (".imageMode(.stretch)", .stretch, 0, false), (".imageMode(.tile)", .tile, 0, true)] {
            let source = "widget { Image(\"photos/甲😀.png\")" + suffix + ".size(32, 24).padding(2).name(picture) }"
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(result.issues.isEmpty, "\(result.issues)")
            guard let program = result.program, case .image(let image) = program.root.content else { throw CompilationFixtureError.missingProgram }
            t.equal(image.source, "photos/甲😀.png"); t.equal(image.mode, mode)
            t.equal(result.imageSources, ["photos/甲😀.png"]); t.equal(checked.assets.images.map(\.path), ["photos/甲😀.png"])
            t.equal(program.root.id, ElementID(name: "picture", index: 0))
            var runtime = try ProgramRuntime(program: program)
            let input = ProgramImageResource(path: "/fixture/original.png", naturalSize: SkinSize(width: 20, height: 10),
                                             stamp: ImageStamp(seconds: 1, nanoseconds: 2, size: 3, inode: 4))
            let scene = try runtime.project(environment: compileEnvironment(), images: [image.source: input]) { _, _, _ in SkinSize() }
            guard case .image(let draw)? = scene.drawingItems.first else { throw CompilationFixtureError.missingProgram }
            t.equal(draw.contentFrame, SkinRect(x: 2, y: 2, width: 28, height: 20)); t.equal(draw.preserveAspectRatio, aspect)
            t.equal(draw.tile, tile); t.check(draw.options.useExifOrientation)
        }
    }

    t.suite("Desk: image compilation: missing asset demands preserve diagnostics until the actual recheck") {
        let file = DeskFileID(path: "Image.desk"), text = #"widget { Image("./New.png").width(.fill).height(16) }"#
        let service = DeskLanguageService(openFile: file, files: [file: text], resources: PackageResources(package: DeskPackage()))
        let beforeGeneration = service.snapshot.generation
        let missing = Desk.compile(service.snapshot.checked)
        t.check(missing.program == nil); t.check(missing.diagnostics.contains { $0.id == .fileNotFound })
        t.equal(missing.diagnostics, service.snapshot.checked.diagnostics); t.equal(missing.imageSources, ["./New.png"])
        let package = DeskPackage(files: [DeskPackageFile(path: "new.PNG", kind: .image, size: 10, pixelSize: DeskPixelSize(width: 8, height: 12))],
                                  texts: [file: text], isSingleFile: true)
        let checked = service.setPackage(package), ready = Desk.compile(checked.checked)
        t.check(ready.program != nil, "\(ready.diagnostics)"); t.check(!ready.diagnostics.contains { $0.id == .fileNotFound })
        t.equal(ready.imageSources, ["./New.png"]); t.check(checked.generation > beforeGeneration)
        for suffix in [".rounded(2)", ".tint(.accent)", ".margin(1)"] {
            let source = #"widget { Image("missing.png")"# + suffix + " }"
            let bad = Desk.compile(deskCheck(source, context: CheckContext(resources: PackageResources(package: DeskPackage()))))
            t.check(bad.program == nil); t.check(bad.imageSources.isEmpty, "unsupported semantics must not request asset reads")
            t.check(bad.diagnostics.contains { $0.id == .fileNotFound })
        }
    }

    t.suite("Desk: image compilation: unsupported sources facets and other checker errors request no assets") {
        for source in [#"widget { Image("../outside.png") }"#, #"widget { Image("/tmp/outside.png") }"#,
                       #"widget { Image("https://example.invalid/a.png") }"#, #"widget { Image(music.cover) }"#,
                       #"widget { Image("a.png").rounded(3) }"#, #"widget { Image("a.png").grayscale() }"#,
                       #"widget { Image("a.png").imageMode(.fill, if: true) }"#,
                       #"widget { Image("a.png").padding(-1) }"#] {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(result.program == nil, source); t.check(result.imageSources.isEmpty, source)
            t.equal(result.diagnostics, checked.diagnostics)
        }
    }

}

private func runDeskPointRadiusCompilationTests(_ t: TestRunner) {
    t.suite("Desk: shape style: explicit pt radii consume checked Length values and reach geometry") {
        for radius in [16, 0] {
            let checked = deskCheck("widget { Rectangle().size(40).rounded(\(radius)pt) }")
            let result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.issues.isEmpty, "\(result.issues)")
            guard let program = result.program, let ref = checked.elements.keys.first,
                  let value = checked.elements[ref]?.facets[FacetID("rounded.topLeft")]?.first?.value else {
                throw CompilationFixtureError.missingProgram
            }
            t.equal(checked.types[value]?.type, .length)
            t.equal(checked.canonicalNumericValues[value], Double(radius))
            t.equal(program.root.cornerRadius, .points(Double(radius)))
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: compileEnvironment()) { _, _, _ in throw CompilationFixtureError.missingProgram }
            if radius == 0 {
                t.equal(scene.drawingItems, [.fill(SkinRect(width: 40, height: 40), Paint(color: SkinAppearance.light.labelColor))])
            } else {
                guard case .shape(let drawing)? = scene.drawingItems.first, case .path(let path) = drawing.shapes[0].geometry else {
                    return t.check(false, "the explicit point radius reaches the actual rounded path")
                }
                t.equal(path.subpaths[0].start, ShapePoint(16, 0))
                t.equal(path.subpaths[0].segments[1].kind.end, ShapePoint(40, 16))
            }
        }
    }

    t.suite("Desk: shape style: explicit pt raw argument editing keeps comments and recompiles") {
        let source = "\u{FEFF}// 甲😀\r\nwidget { Rectangle().size(40).rounded( /* before */ 12pt /* after */ ).name(box) }\r\n"
        let checked = deskCheck(source), compiled = Desk.compile(checked)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        guard let program = compiled.program, let ref = compiled.elementRefs[program.root.id],
              let node = checked.tree.resolve(ref), let call = CallStmtSyntax(node),
              let argument = call.modifiers.first(where: { $0.name.token.text == "rounded" })?.arguments?.arguments.first else {
            throw CompilationFixtureError.missingProgram
        }
        let edited = Desk.apply(.setArgument(checked.tree.id(of: argument.node), newText: "16"), to: checked.tree)
        t.check(edited.failure == nil)
        t.equal(edited.tree.text, source.replacingOccurrences(of: "12pt", with: "16pt"))
        t.equal(edited.edits.count, 1)
        let rechecked = Desk.check(edited.tree), ready = Desk.compile(rechecked)
        t.check(rechecked.diagnostics(.error).isEmpty, deskDescribe(rechecked))
        t.check(ready.issues.isEmpty)
        t.equal(ready.program?.root.cornerRadius, .points(16))
    }

    t.suite("Desk: shape style: explicit pt support does not admit other units expressions or invalid receipts") {
        let sources = ["16ms", "16px", "16em", "16%", "16 pt", "-16pt", "(16pt)", "8pt + 8pt",
                       String(repeating: "9", count: 320) + "pt"].map { "widget { Rectangle().size(40).rounded(\($0)) }" }
            + [#"widget { computed radius = 16pt; Rectangle().size(40).rounded(radius) }"#,
               #"widget { Rectangle().size(40).rounded(16pt, topLeft: 0pt) }"#,
               #"widget { Rectangle().size(40).rounded(16pt, if: true) }"#,
               #"widget { Rectangle().size(40pt).rounded(16pt) }"#,
               #"widget { Rectangle().size(40).stroke(.accent, width: 1pt).rounded(16pt) }"#]
        for source in sources {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(result.program == nil && result.elementRefs.isEmpty, source)
            t.equal(result.diagnostics, checked.diagnostics, "original syntax/checker diagnostics are retained")
            if checked.diagnostics(.error).isEmpty {
                t.equal(result.issues.first?.kind, .unsupported, source)
            } else {
                t.check(result.issues.isEmpty, "checker failures are not replaced by guessed lowering errors")
            }
        }
        var noCanonical = deskCheck("widget { Rectangle().size(40).rounded(16pt) }")
        guard let value = noCanonical.elements.values.first?.facets[FacetID("rounded.topLeft")]?.first?.value else {
            throw CompilationFixtureError.missingProgram
        }
        noCanonical.canonicalNumericValues.removeValue(forKey: value)
        let missing = Desk.compile(noCanonical)
        t.check(missing.program == nil && missing.elementRefs.isEmpty)
        t.equal(missing.issues.first?.kind, .unsupported, "a unit spelling does not substitute for a checked value")
        noCanonical.canonicalNumericValues[value] = .infinity
        let nonfinite = Desk.compile(noCanonical)
        t.check(nonfinite.program == nil && nonfinite.elementRefs.isEmpty)
        t.equal(nonfinite.issues.first?.kind, .unsupported)
    }
}

private func runDeskCompilationReferenceTests(_ t: TestRunner) {
    t.suite("Desk: compilation references: nested and repeated calls map their actual scene IDs") {
        let source = "\u{FEFF}// source bytes 甲😀\r\nwidget { Column { Text(\"A\"); Row { Rectangle().size(8); Text(\"A\") } }.name(layout) }"
        let checked = deskCheck(source), result = Desk.compile(checked)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        t.check(result.issues.isEmpty, "\(result.issues)")
        guard let program = result.program else { throw CompilationFixtureError.missingProgram }
        let refs = checked.elements.keys.sorted { $0.utf8Start < $1.utf8Start }
        let ids = [ElementID(name: "layout", index: 0), ElementID(name: "Text#1", index: 1),
                   ElementID(name: "Row#2", index: 2), ElementID(name: "Rectangle#3", index: 3),
                   ElementID(name: "Text#4", index: 4)]
        t.equal(refs.count, ids.count)
        t.equal(result.elementRefs, Dictionary(uniqueKeysWithValues: zip(ids, refs)))
        for ref in result.elementRefs.values {
            t.equal(ref.treeVersion, checked.tree.version)
            t.equal(ref.kind, .callStmt)
            t.check(checked.tree.resolve(ref) != nil)
        }
        var runtime = try ProgramRuntime(program: program)
        let scene = try runtime.project(environment: compileEnvironment()) { _, _, _ in SkinSize(width: 6, height: 8) }
        t.equal(Set(result.elementRefs.keys), Set(scene.elements.map(\.id)))
        t.equal(compiledDraws(scene).map(\.text), ["A", "A"])
        t.equal(Set(result.elementRefs.values).count, ids.count, "repeated text content does not alias source calls")
    }

    t.suite("Desk: compilation references: synthetic root has no ref and an actionless rectangle remains editable") {
        let source = #"widget { Rectangle().width(12).height(8).fill(.accent); Text("A") }"#
        let checked = deskCheck(source), result = Desk.compile(checked)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        t.check(result.issues.isEmpty, "\(result.issues)")
        guard let program = result.program, case .column(_, _, let children) = program.root.content,
              children.count == 2, let rectangleRef = result.elementRefs[children[0].id] else {
            throw CompilationFixtureError.missingProgram
        }
        t.equal(program.root.id, ElementID(name: "widget", index: 0))
        t.check(result.elementRefs[program.root.id] == nil, "the generated widget container is not a source element")
        t.equal(Set(result.elementRefs.values), Set(checked.elements.keys))
        t.equal(result.elementRefs.count, 2)
        for child in children {
            t.check(child.onClick == nil && child.onClickActions == nil && child.onRightClickActions == nil)
            t.check(result.elementRefs[child.id] != nil, "source selection is independent of action handlers")
        }
        t.equal(checked.elements[rectangleRef]?.component, "Rectangle")
        let edited = Desk.apply(.setModifier(rectangleRef, name: "width", argumentsText: "18", condition: nil), to: checked)
        t.check(edited.failure == nil, "\(String(describing: edited.failure))")
        t.equal(edited.tree.text, #"widget { Rectangle().width(18).height(8).fill(.accent); Text("A") }"#)
        let rechecked = Desk.check(edited.tree), rebuilt = Desk.compile(rechecked)
        t.check(rechecked.diagnostics(.error).isEmpty, deskDescribe(rechecked))
        guard let next = rebuilt.program, case .column(_, _, let nextChildren) = next.root.content else {
            throw CompilationFixtureError.missingProgram
        }
        t.equal(nextChildren[0].width, .fixed(18))
        t.check(rebuilt.elementRefs[nextChildren[0].id] != rectangleRef, "the edit publishes references of its new tree")
    }

    t.suite("Desk: compilation references: checker and partial lowering failures publish no refs") {
        let duplicate = deskCheck(#"widget { Rectangle().name(repeated); Text("A").name(repeated) }"#)
        let duplicateResult = Desk.compile(duplicate)
        t.check(duplicate.diagnostics.contains { $0.id == .duplicateElementName && $0.severity == .error })
        t.check(duplicateResult.program == nil && duplicateResult.elementRefs.isEmpty)
        t.equal(duplicateResult.diagnostics, duplicate.diagnostics)
        t.check(duplicateResult.issues.isEmpty)

        let partial = deskCheck(#"widget { Column { Rectangle().size(8); Text("B"); Rectangle().size(4).margin(1) } }"#)
        let partialResult = Desk.compile(partial)
        t.check(partial.diagnostics(.error).isEmpty, deskDescribe(partial))
        t.equal(partial.elements.count, 4)
        t.check(partialResult.program == nil && partialResult.elementRefs.isEmpty,
                "already-lowered siblings are not published after a later unsupported facet")
        t.equal(partialResult.issues.first?.kind, .unsupported)
        t.equal(partialResult.diagnostics, partial.diagnostics)
        t.check(partialResult.imageSources.isEmpty)

        var catalog = DeskCatalog.current
        catalog.limits.maximumElementInstances = 2
        // Two real calls fit the checked limit; the generated root exhausts the shared budget after one child.
        let bounded = deskCheck(#"widget { Rectangle().size(8); Text("B") }"#, context: CheckContext(catalog: catalog))
        t.check(bounded.diagnostics(.error).isEmpty, deskDescribe(bounded))
        let limited = Desk.compile(bounded, catalog: catalog)
        t.check(limited.program == nil && limited.elementRefs.isEmpty)
        t.equal(limited.issues.first?.kind, .resourceLimit)
        t.equal(limited.diagnostics, bounded.diagnostics)
        let empty = Desk.compile(deskCheck("widget { Column { } }"))
        t.check(empty.program == nil && empty.elementRefs.isEmpty)
    }

    t.suite("Desk: compilation references: missing images retain demands but publish refs only after recheck") {
        let file = DeskFileID(path: "Mapped.desk")
        let source = #"widget { Rectangle().size(8); Image("New.png").size(12) }"#
        let empty = CheckContext(resources: PackageResources(package: DeskPackage()))
        let missing = deskCheck(source, file: file.path, context: empty), result = Desk.compile(missing)
        t.check(result.program == nil && result.elementRefs.isEmpty)
        t.check(result.issues.isEmpty)
        t.equal(result.diagnostics, missing.diagnostics)
        t.check(result.diagnostics.contains { $0.id == .fileNotFound && $0.severity == .error })
        t.equal(result.imageSources, ["New.png"])
        let package = DeskPackage(files: [DeskPackageFile(path: "New.png", kind: .image, size: 10,
            pixelSize: DeskPixelSize(width: 8, height: 12))], texts: [file: source], isSingleFile: true)
        let checked = deskCheck(source, file: file.path, context: CheckContext(resources: PackageResources(package: package)))
        let ready = Desk.compile(checked)
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        t.check(ready.program != nil && ready.issues.isEmpty)
        t.equal(ready.elementRefs.count, 2)
        t.equal(Set(ready.elementRefs.values), Set(checked.elements.keys))
        t.equal(ready.imageSources, result.imageSources)
        t.equal(ready.diagnostics, checked.diagnostics)
    }

    t.suite("Desk: compilation references: same-text reparse rejects the old ref even when program IDs match") {
        let source = #"widget { Rectangle().width(12).height(8).name(box) }"#
        let before = deskCheck(source), original = Desk.compile(before)
        guard let program = original.program, let oldRef = original.elementRefs[program.root.id] else {
            throw CompilationFixtureError.missingProgram
        }
        let (tree, _) = Desk.reparse(source, previous: before.tree)
        let checked = Desk.check(tree), compiled = Desk.compile(checked)
        guard let current = compiled.program, let newRef = compiled.elementRefs[current.root.id] else {
            throw CompilationFixtureError.missingProgram
        }
        t.check(tree.root === before.tree.root, "unchanged text shares the syntax nodes")
        t.check(tree.version != before.tree.version)
        t.equal(current.root.id, program.root.id, "this source happens to reuse the same current program ID")
        t.equal(newRef.utf8Start, oldRef.utf8Start)
        t.check(newRef != oldRef)
        t.check(tree.resolve(oldRef) == nil && tree.resolve(newRef) != nil)
        let refused = Desk.apply(.setModifier(oldRef, name: "width", argumentsText: "18", condition: nil), to: checked)
        t.equal(refused.failure, .staleReference)
        t.check(refused.edits.isEmpty)
        t.equal(refused.tree.text, source)
        let applied = Desk.apply(.setModifier(newRef, name: "width", argumentsText: "18", condition: nil), to: checked)
        t.check(applied.failure == nil)
        t.equal(applied.tree.text, #"widget { Rectangle().width(18).height(8).name(box) }"#)
    }
}

private func runDeskPaletteCompilationTests(_ t: TestRunner) {
    let names = ["accent", "text", "dim", "faint", "separator", "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray", "white", "black", "clear"]
    let paint = RGBA(r: 23, g: 47, b: 71, a: 127)
    let input = ProgramColorInput(colors: Dictionary(uniqueKeysWithValues: ProgramPaletteColor.allCases.map { ($0, paint) }))
    t.suite("Desk: palette: every actual catalog color lowers to shared text fill and stroke") {
        t.equal(Set(DeskCatalog.current.namedValues.filter { $0.type == "Color" }.map(\.name)), Set(names))
        for name in names {
            let source = "widget { Row(spacing: 0) { Text(\"色😀\").color(." + name + "); Rectangle().size(12).fill(." + name + "); Ellipse().size(12).stroke(." + name + ") } }"
            let program = try compileFixture(t, source)
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: compileEnvironment(), colorInput: input) { _, style, _ in
                t.equal(style.color, paint); return SkinSize(width: 8, height: 10)
            }
            guard scene.drawingItems.count == 3, case .fill(_, let fill) = scene.drawingItems[1],
                  case .shape(let outline) = scene.drawingItems[2] else { return t.check(false, "all palette consumers") }
            t.equal(compiledDraws(scene)[0].style.color, paint); t.equal(fill.color, paint)
            t.equal(outline.shapes[0].stroke, .color(paint)); t.equal(outline.shapes[0].fill, .color(.clear))
        }
        // These are the original negative literals, including the full mixed-content rejection context.
        for source in [#"widget { Text("A").color(.red) }"#,
                       #"widget { Column { Text("must not paint partially"); Rectangle().size(12).fill(.red) } }"#] {
            let program = try compileFixture(t, source)
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: compileEnvironment(), colorInput: input) { _, _, _ in SkinSize(width: 8, height: 10) }
            t.equal(compiledDraws(scene)[0].style.color, paint)
            if source.contains("must not") {
                // The sibling keeps its default text semantic color, also supplied by this input.
                guard case .fill(_, let fill)? = scene.drawingItems.last else { return t.check(false, "original red rectangle") }
                t.equal(fill.color, paint); t.equal(compiledDraws(scene)[0].text, "must not paint partially")
            } else { t.equal(compiledDraws(scene)[0].text, "A") }
        }
    }
    t.suite("Desk: palette: future catalog colors and unsupported color facets reject the whole source") {
        var catalog = DeskCatalog.current
        var future = catalog.namedValues.first { $0.type == "Color" && $0.name == "red" }!
        future.name = "futureHue"; catalog.namedValues.append(future)
        let source = #"widget { Text("must not paint partially"); Rectangle().size(12).fill(.futureHue) }"#
        let checked = deskCheck(source, context: CheckContext(catalog: catalog))
        t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
        let result = Desk.compile(checked, catalog: catalog)
        t.check(result.program == nil && result.issues.first?.kind == .unsupported)
        for source in [#"widget { Text("A").color(.red, if: true) }"#,
                       #"widget { Column { Text("must not paint partially"); Rectangle().size(12).fill(.red, if: true) } }"#,
                       ##"widget { Text("A").color(light: "#222222", dark: "#EEEEEE") }"##,
                       #"widget { Rectangle().size(12).fill(gradient(.red, .blue)) }"#] {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            let result = Desk.compile(checked)
            t.check(result.program == nil && result.issues.first?.kind == .unsupported, source)
            t.equal(result.diagnostics, checked.diagnostics)
        }
    }
}


private func runDeskFontSizeCompilationTests(_ t: TestRunner) {
    func measure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
        let points = TextStyle.pixelSize(points: style.fontSize)
        return SkinSize(width: points, height: points)
    }
    t.suite("Desk: font size: checked Length and Plain expressions drive current shared layouts") {
        let source = "\u{FEFF}" + #"widget { variable size = 20; Text("甲😀").font(size).onClick { size = size + 4 } }"# + "\r\n"
        let program = try compileFixture(t, source)
        t.equal(program.declarations[0].initial, .quantity(ProgramNumber(20, dimension: .length)))
        t.equal(program.root.onClick, [ProgramAssignment(declaration: 0, value: .add(.declaration(0), .quantity(ProgramNumber(4, dimension: .length))))])
        var runtime = try ProgramRuntime(program: program)
        let first = try runtime.project(environment: compileEnvironment(), measure: measure)
        t.equal(first.size, SkinSize(width: 20, height: 20))
        guard let changed = try runtime.click(at: SkinPoint(x: 6, y: 6), expectedGeneration: first.generation,
                                              environment: compileEnvironment(), measure: measure) else { throw CompilationFixtureError.missingProgram }
        t.equal(changed.size, SkinSize(width: 24, height: 24))
        t.equal(compiledDraws(changed).map(\.text), ["甲😀"])
        t.close(TextStyle.pixelSize(points: compiledDraws(changed)[0].style.fontSize), 24)
        t.equal(changed.elements[0].id, first.elements[0].id)
        t.check(try runtime.click(at: SkinPoint(x: 6, y: 6), expectedGeneration: first.generation,
                                 environment: compileEnvironment(), measure: measure) == nil)

        let plain = try compileFixture(t, #"widget { variable count = 1; computed size = count * 4 + 16; Text("{count}").font(size).onClick { count = count + 1 } }"#)
        t.equal(plain.declarations[0].initial, .number(1))
        var points = try ProgramRuntime(program: plain)
        let before = try points.project(environment: compileEnvironment(), measure: measure)
        guard let after = try points.click(at: SkinPoint(x: 6, y: 6), expectedGeneration: before.generation,
                                          environment: compileEnvironment(), measure: measure) else { throw CompilationFixtureError.missingProgram }
        t.equal(compiledDraws(before).map(\.text), ["1"]); t.equal(compiledDraws(after).map(\.text), ["2"])
        t.equal([before.size, after.size], [SkinSize(width: 20, height: 20), SkinSize(width: 24, height: 24)])
        t.equal(compiledDraws(after)[0].style.inlineSpans, [InlineSpan(location: 0, length: 1, setting: .typography(feature: "tnum", value: 1))])
        t.equal(points.clockPrecision, nil)
        let lengthText = try compileFixture(t, #"widget { variable size = 20; Text("{size}").font(size) }"#)
        var displayed = try ProgramRuntime(program: lengthText)
        t.equal(compiledDraws(try displayed.project(environment: compileEnvironment(), measure: measure)).map(\.text), ["20"])
    }
    t.suite("Desk: font size: inherited live values yield to literal and preset overrides") {
        let source = #"widget { computed size = system.dark ? 20 : 28; Column(spacing: 3, align: .left) { Text("A"); Text("B").font(13); Text("C").font(.caption) }.font(size) }"#
        var runtime = try ProgramRuntime(program: compileFixture(t, source))
        let dark = try runtime.project(environment: compileEnvironment(.dark), measure: measure)
        let light = try runtime.project(environment: compileEnvironment(.light), measure: measure)
        t.equal(compiledDraws(dark).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [20, 13, 11])
        t.equal(compiledDraws(light).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [28, 13, 11])
        t.equal(compiledDraws(light).map { $0.style.fontWeight }, [400, 400, 500])
        t.equal(dark.size, SkinSize(width: 20, height: 50)); t.equal(light.size, SkinSize(width: 28, height: 58))
        t.equal(dark.elements[2].frame.y, 23); t.equal(light.elements[2].frame.y, 31)
        t.equal(dark.elements[3].frame.y, 39); t.equal(light.elements[3].frame.y, 47)
        t.equal(dark.elements.map(\.id), light.elements.map(\.id))
        let literal = try compileFixture(t, #"widget { Text("A").font(20) }"#)
        if case .text(let text) = literal.root.content { t.check(text.fontSizeExpression == nil) }
        else { t.check(false) }
    }
    t.suite("Desk: font size: unsupported facets bad units and incomplete checked identities reject fully") {
        let sources = [#"widget { variable size = 20; Text("A").font(size).margin(1) }"#,
                       #"widget { variable size = 20; Text("A").font(size, if: system.dark) }"#,
                       #"widget { variable size = 20; Text("A").font(size).opacity(0.5) }"#]
        for source in sources {
            let checked = deskCheck(source), result = Desk.compile(checked)
            t.check(checked.diagnostics(.error).isEmpty, deskDescribe(checked))
            t.check(result.program == nil && !result.issues.isEmpty, source)
            t.equal(result.issues.first?.kind, .unsupported)
            t.equal(result.diagnostics.map(\.id), checked.diagnostics.map(\.id))
        }
        for value in ["20%", "20s", "20KB"] {
            let checked = deskCheck("widget { Text(\"A\").font(\(value)) }"), result = Desk.compile(checked)
            t.check(!checked.diagnostics(.error).isEmpty)
            t.check(result.program == nil && result.issues.isEmpty)
            t.equal(result.diagnostics, checked.diagnostics)
        }
        let source = #"widget { variable size = 20; Text("A").font(size) }"#
        let checked = deskCheck(source)
        guard let use = deskCompilationNode(checked, text: "size", kind: .identifierExpr),
              let font = checked.symbols.first(where: { $0.value == .builtIn(.modifier("font")) })?.key else {
            throw CompilationFixtureError.missingProgram
        }
        func withFacts(types: [NodeID: SemType], symbols: [NodeID: Symbol]) -> CheckedFile {
            var value = CheckedFile(tree: checked.tree, diagnostics: checked.diagnostics, symbols: symbols, types: types,
                                    elements: checked.elements, dataUses: checked.dataUses, dependencies: checked.dependencies,
                                    reactions: checked.reactions, freeformOrders: checked.freeformOrders, stringTable: checked.stringTable,
                                    requirements: checked.requirements, options: checked.options, styles: checked.styles,
                                    translations: checked.translations, root: checked.root)
            value.loopIdentities = checked.loopIdentities; value.assets = checked.assets
            value.declarationTypes = checked.declarationTypes
            value.canonicalNumericValues = checked.canonicalNumericValues; value.numericCoercions = checked.numericCoercions
            return value
        }
        var types = checked.types; types.removeValue(forKey: checked.tree.id(of: use))
        let missing = withFacts(types: types, symbols: checked.symbols)
        let absent = Desk.compile(missing)
        t.check(absent.program == nil); t.equal(absent.issues.first?.kind, .invalidCheckedModel)
        var symbols = checked.symbols; symbols[font] = .builtIn(.modifier("color"))
        let wrong = withFacts(types: checked.types, symbols: symbols)
        let identity = Desk.compile(wrong)
        t.check(identity.program == nil); t.equal(identity.issues.first?.kind, .unsupported)
    }
}

private func deskCompilationNode(_ checked: CheckedFile, text: String, kind: SyntaxKind) -> PositionedNode? {
    let bytes = Array(checked.tree.text.utf8)
    return DeskNodeTable(tree: checked.tree).entries.map(\.positioned).first {
        $0.kind == kind && String(decoding: bytes[$0.textRange], as: UTF8.self) == text
    }
}
