import Foundation
@testable import DesksetCore
@testable import DeskLanguage

private enum StyleCompilationFixtureError: Error { case program(String), receipt(String) }

private struct StyleCompilationFixture {
    let checked: CheckedFile
    let package: CheckedFile?
    let result: DeskCompilationResult
    let program: WidgetProgram
}

private func styleCompilation(_ t: TestRunner, _ source: String, package sourcePackage: String? = nil,
                              catalog: DeskCatalog = .current) throws -> StyleCompilationFixture {
    let checked: CheckedFile
    let package: CheckedFile?
    if let sourcePackage {
        let folder = CheckedDeskPackage(package: deskMemoryPackage([
            "package.desk": sourcePackage, "Styles.desk": source
        ]), context: CheckContext(catalog: catalog))
        guard let shared = folder.files[DeskFileID("package.desk")],
              let widget = folder.files[DeskFileID("Styles.desk")] else {
            throw StyleCompilationFixtureError.receipt("checked folder")
        }
        checked = widget; package = shared
        t.check(shared.diagnostics(.error).isEmpty, deskDescribe(shared))
    } else {
        checked = deskCheck(source, file: "Styles.desk", context: CheckContext(catalog: catalog))
        package = nil
    }
    let result = Desk.compile(checked, catalog: catalog, package: package)
    t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
    t.check(result.issues.isEmpty, "\(source)\n\(result.issues)")
    t.equal(result.diagnostics, checked.diagnostics + (package?.diagnostics ?? []))
    guard let program = result.program else { throw StyleCompilationFixtureError.program(source) }
    return StyleCompilationFixture(checked: checked, package: package, result: result, program: program)
}

private func styleEnvironment(_ dark: Bool = false) -> EnvironmentStamp {
    EnvironmentStamp(scale: 1, fontGeneration: 1,
        appearance: AppearanceStamp(value: dark ? .dark : .light, name: "styles"), imageGeneration: 0)
}

private func styleMeasure(_ text: String, _ style: TextStyle, _ width: Double?) -> SkinSize {
    SkinSize(width: Double(text.utf16.count) * 5, height: TextStyle.pixelSize(points: style.fontSize))
}

private func styleMeasureIcon(_ request: IconRequest) -> SkinSize? {
    let size = TextStyle.pixelSize(points: request.style.fontSize)
    return SkinSize(width: size * 2, height: size)
}

private func styleScene(_ program: WidgetProgram, dark: Bool = false, language: String? = nil) throws -> WidgetScene {
    var runtime = try ProgramRuntime(program: program, language: language)
    return try runtime.project(environment: styleEnvironment(dark), measureIcon: styleMeasureIcon, measure: styleMeasure)
}

private func styleTexts(_ scene: WidgetScene) -> [TextDraw] {
    scene.drawingItems.compactMap { if case .text(let draw) = $0 { return draw }; return nil }
}

private func styleIcons(_ scene: WidgetScene) -> [IconDraw] {
    scene.drawingItems.compactMap { if case .icon(let draw) = $0 { return draw }; return nil }
}

private func styleFacts(_ value: CheckedFile, symbols: [NodeID: Symbol]? = nil, types: [NodeID: SemType]? = nil,
                        elements: [NodeID: ElementFacts]? = nil, styles: [String: NodeID]? = nil,
                        strings: [StringEntry]? = nil) -> CheckedFile {
    var copy = CheckedFile(tree: value.tree, diagnostics: value.diagnostics,
        symbols: symbols ?? value.symbols, types: types ?? value.types, elements: elements ?? value.elements,
        dataUses: value.dataUses, dependencies: value.dependencies, reactions: value.reactions,
        freeformOrders: value.freeformOrders, stringTable: strings ?? value.stringTable,
        requirements: value.requirements, options: value.options, styles: styles ?? value.styles,
        translations: value.translations, root: value.root)
    copy.loopIdentities = value.loopIdentities; copy.assets = value.assets
    copy.declarationTypes = value.declarationTypes; copy.canonicalNumericValues = value.canonicalNumericValues
    copy.numericCoercions = value.numericCoercions
    return copy
}

private func styleRejected(_ t: TestRunner, _ checked: CheckedFile, package: CheckedFile? = nil,
                           catalog: DeskCatalog = .current, kind: DeskCompilationIssue.Kind? = nil,
                           because reason: String) {
    let result = Desk.compile(checked, catalog: catalog, package: package)
    t.check(result.program == nil && result.elementRefs.isEmpty && result.imageSources.isEmpty, reason)
    t.check(!result.issues.isEmpty, "\(reason): \(result.issues)")
    if let kind { t.equal(result.issues.first?.kind, kind, reason) }
    t.equal(result.diagnostics, checked.diagnostics + (package?.diagnostics ?? []), reason)
}

func runDeskStyleCompilationTests(_ t: TestRunner) {
    t.suite("Desk: styles: nested repeated applications preserve source order and hard soft own precedence") {
        let definitions = #"""
            style base { .font(12).color(.dim) }
            style accent { .color(.accent) }
            style card { .color(.text).style(base) }
            style hard { .bold() }
            style soft { .font(.headline) }
            style ownPreset { .font(.headline).bold() }
            """#
        let cases: [(String, String, Double, Int, ProgramColor)] = [
            (".style(base).style(accent)", ".font(12).color(.accent)", 12, 400, .accent),
            (".style(accent).style(base)", ".font(12).color(.dim)", 12, 400, .dim),
            (".style(base).style(accent).style(base)", ".font(12).color(.dim)", 12, 400, .dim),
            (".style(card)", ".font(12).color(.text)", 12, 400, .text),
            (".style(hard).style(soft)", ".font(.headline).bold()", 15, 700, .text),
            (".style(soft).style(hard)", ".font(.headline).bold()", 15, 700, .text),
            (".style(hard).font(.headline)", ".font(.headline)", 15, 600, .text),
            (".style(ownPreset)", ".font(.headline).bold()", 15, 700, .text),
            (".color(.dim).style(accent).font(18)", ".font(18).color(.dim)", 18, 400, .dim)
        ]
        for (application, explicit, size, weight, color) in cases {
            let source = definitions + "\nwidget { Text(\"A\")\(application).name(label) }"
            let styled = try styleCompilation(t, source)
            let literal = try styleCompilation(t, "widget { Text(\"A\")\(explicit).name(label) }")
            t.equal(styled.program, literal.program, application)
            for dark in [false, true] {
                let scene = try styleScene(styled.program, dark: dark)
                t.equal(scene, try styleScene(literal.program, dark: dark), application)
                guard let draw = styleTexts(scene).first else { throw StyleCompilationFixtureError.receipt(application) }
                t.close(TextStyle.pixelSize(points: draw.style.fontSize), size)
                t.equal(draw.style.fontWeight, weight)
                t.equal(draw.style.color, try color.resolved(in: dark ? .dark : .light, colorInput: nil))
            }
            t.equal(styled.program.root.id, ElementID(name: "label", index: 0))
            t.equal(styled.result.elementRefs.count, 1)
            t.check(styled.result.elementRefs.values.allSatisfy { $0.treeVersion == styled.checked.tree.version })
        }
        let wrappedFonts: [(String, String, FacetID)] = [
            (".font((12))", ".font(12)", "font.size"),
            (".font((.headline)).bold()", ".font(.headline).bold()", "font.size"),
            (#".font(("System"))"#, #".font("System")"#, "font.family")
        ]
        for (wrapped, plain, facet) in wrappedFonts {
            let fixture = try styleCompilation(t, "style wrapped { \(wrapped) }\nwidget { Text(\"A\").style(wrapped) }")
            let literal = try styleCompilation(t, "widget { Text(\"A\")\(plain) }")
            t.equal(fixture.program, literal.program, wrapped)
            let scene = try styleScene(fixture.program)
            t.equal(scene, try styleScene(literal.program), wrapped)
            let checked = fixture.checked
            guard let root = checked.root, let candidate = checked.elements[root]?.facets[facet]?.first,
                  let node = checked.tree.resolve(candidate.value), let paren = ParenExprSyntax(node),
                  case .style(_, let origin, _) = candidate.origin,
                  let modifierNode = checked.tree.resolve(origin), let modifier = ModifierAppSyntax(modifierNode),
                  let argument = modifier.arguments?.arguments.first?.value.node else {
                throw StyleCompilationFixtureError.receipt("parenthesized font \(wrapped)")
            }
            let inner = checked.tree.id(of: paren.value.node)
            t.equal(candidate.value, checked.tree.id(of: argument), "the receipt retains the outer argument identity")
            t.check(candidate.value != inner); t.equal(checked.symbols[candidate.value], nil)
            t.equal(checked.numericCoercions[candidate.value], nil)
            if plain == ".font(12)" {
                t.equal(checked.types[candidate.value]?.type, .length)
                t.equal(checked.types[inner]?.type, .plainNumber, "Length adoption belongs to the argument wrapper")
                t.equal(checked.canonicalNumericValues[candidate.value], 12)
                t.equal(checked.canonicalNumericValues[inner], 12)
                t.equal(styleTexts(scene).first.map { TextStyle.pixelSize(points: $0.style.fontSize) }, 12)
            } else if facet == "font.size" {
                t.equal(checked.types[candidate.value]?.type, .enumeration("FontPreset"))
                t.equal(checked.types[inner]?.type, .enumeration("FontPreset"))
                t.equal(checked.symbols[inner], .enumCase(type: "FontPreset", case: "headline"))
                t.equal(styleTexts(scene).first?.style.fontWeight, 700, "hard bold still overrides the soft preset")
                t.equal(styleTexts(scene).first.map { TextStyle.pixelSize(points: $0.style.fontSize) }, 15)
            } else {
                t.equal(checked.types[candidate.value]?.type, .string); t.equal(checked.types[inner]?.type, .string)
                t.equal(StringLiteralSyntax(paren.value.node)?.literalValue, "System")
                t.equal(styleTexts(scene).first?.style.fontFace, "System")
            }
            var types = checked.types; types[candidate.value] = SemType(type: .bool)
            styleRejected(t, styleFacts(checked, types: types), because: "font wrapper has a forged type: \(wrapped)")
        }
    }

    t.suite("Desk: styles: inherited facets applicability and dynamic own overrides retain their existing meaning") {
        let source = #"""
            style inherited { .font(20, .rounded).color(.dim).digits(.equalWidth).align(.left) }
            style child { .font(11).color(.accent) }
            style invisible { .hidden().size(34, 24).padding(2) }
            style textOnly { .uppercase() }
            widget { Column(spacing: 0, align: .left) {
                Text(12).name(inherited)
                Text(34).style(child).color(.white, if: system.dark).name(own)
                Text("Hidden").style(invisible).name(hidden)
                Rectangle().size(10, 4).style(textOnly).name(shape)
            }.style(inherited) }
            """#
        let styled = try styleCompilation(t, source)
        t.check(styled.checked.diagnostics.contains { $0.id == .styleHasNoEffect }, "an inapplicable style keeps the catalog warning")
        let explicit = try styleCompilation(t, #"""
            widget { Column(spacing: 0, align: .left) {
                Text(12).name(inherited)
                Text(34).font(11).color(.accent).color(.white, if: system.dark).name(own)
                Text("Hidden").hidden().size(34, 24).padding(2).name(hidden)
                Rectangle().size(10, 4).name(shape)
            }.font(20, .rounded).color(.dim).digits(.equalWidth).align(.left) }
            """#)
        t.equal(styled.program, explicit.program)
        for dark in [false, true, false] {
            let scene = try styleScene(styled.program, dark: dark)
            t.equal(scene, try styleScene(explicit.program, dark: dark))
            let draws = styleTexts(scene)
            t.equal(draws.map(\.text), ["12", "34"])
            t.equal(draws.map { TextStyle.pixelSize(points: $0.style.fontSize) }, [20, 11])
            t.check(draws.allSatisfy { $0.style.fontFace == "System Rounded" && $0.style.horizontalAlign == .left })
            t.check(draws.allSatisfy { $0.style.inlineSpans.contains(InlineSpan(location: 0, length: 2,
                setting: .typography(feature: "tnum", value: 1))) })
            t.equal(scene.elements.first { $0.id.name == "hidden" }?.visibility, .hiddenKeepsSpace)
            // Hidden content still measures with the inherited 20-point font: 30×20 plus two points per edge.
            t.equal(scene.elements.first { $0.id.name == "hidden" }?.frame.width, 34)
            t.equal(scene.elements.first { $0.id.name == "hidden" }?.frame.height, 24)
            guard let shape = scene.elements.first(where: { $0.id.name == "shape" }) else {
                throw StyleCompilationFixtureError.receipt("shape")
            }
            t.equal(shape.items, [.fill(shape.frame, Paint(color: dark ? SkinAppearance.dark.labelColor : SkinAppearance.light.labelColor))])
        }
        let dynamic = try styleCompilation(t, #"""
            style base { .color(.dim).font(11) }
            widget { Text("A").style(base).font(system.dark ? 18 : 12).hidden(if: system.dark) }
            """#).program
        t.equal(styleTexts(try styleScene(dynamic)).map { TextStyle.pixelSize(points: $0.style.fontSize) }, [12])
        t.check(try styleScene(dynamic, dark: true).drawingItems.isEmpty)
    }

    t.suite("Desk: styles: Icon style fonts disable fitting while inherited and bold italic styles keep fitting") {
        let source = #"""
            style parent { .font(40).color(.dim) }
            style font { .font(12).iconColors(.hierarchical) }
            style weight { .bold().italic() }
            widget { Row(spacing: 0) {
                Icon("wifi").size(20).style(font).name(explicit)
                Icon("wifi").size(20).style(weight).name(weight)
                Icon("wifi").size(20).name(inherited)
            }.style(parent) }
            """#
        let styled = try styleCompilation(t, source).program
        let explicit = try styleCompilation(t, #"""
            widget { Row(spacing: 0) {
                Icon("wifi").size(20).font(12).iconColors(.hierarchical).name(explicit)
                Icon("wifi").size(20).bold().italic().name(weight)
                Icon("wifi").size(20).name(inherited)
            }.font(40).color(.dim) }
            """#).program
        t.equal(styled, explicit)
        guard case .row(_, _, let children) = styled.root.content else { throw StyleCompilationFixtureError.receipt("Icon row") }
        let icons = try children.map { child -> ProgramIcon in
            guard case .icon(let value) = child.content else { throw StyleCompilationFixtureError.receipt("Icon child") }
            return value
        }
        t.equal(icons.map(\.hasOwnFont), [true, false, false])
        t.equal(icons.map(\.fontSize), [12, 40, 40]); t.equal(icons.map(\.fontWeight), [400, 700, 400])
        t.equal(icons.map(\.italic), [false, true, false])
        let scene = try styleScene(styled)
        t.equal(scene, try styleScene(explicit))
        t.equal(styleIcons(scene).map(\.contentFrame), [SkinRect(x: -2, y: 4, width: 24, height: 12),
            SkinRect(x: 20, y: 5, width: 20, height: 10), SkinRect(x: 40, y: 5, width: 20, height: 10)])
        t.equal(styleIcons(scene).map(\.request.colors), [.hierarchical, .monochrome, .monochrome])
    }

    t.suite("Desk: styles: Gauge and shape boxes retain independent fills strokes glass and uniform rounding") {
        let source = ##"""
            style box { .size(40).padding(2).background(.glass, tint: .accent).rounded(7) }
            style meter { .color("#123456").track("#ABCDEF").font(30) }
            style shape { .fill("#CC2200").stroke("#00CC22", width: 2).rounded(3) }
            widget { Column(spacing: 0, align: .left) {
                Gauge(25%).style(box).style(meter).name(gauge)
                Rectangle().style(box).style(shape).name(rect)
                Circle().size(20).style(shape).name(circle)
            } }
            """##
        let styled = try styleCompilation(t, source).program
        let explicit = try styleCompilation(t, ##"""
            widget { Column(spacing: 0, align: .left) {
                Gauge(25%).size(40).padding(2).background(.glass, tint: .accent).rounded(7)
                    .color("#123456").track("#ABCDEF").name(gauge)
                Rectangle().size(40).padding(2).background(.glass, tint: .accent).rounded(3)
                    .fill("#CC2200").stroke("#00CC22", width: 2).name(rect)
                Circle().size(20).fill("#CC2200").stroke("#00CC22", width: 2).rounded(3).name(circle)
            } }
            """##).program
        t.equal(styled, explicit)
        for dark in [false, true] {
            let scene = try styleScene(styled, dark: dark)
            let literal = try styleScene(explicit, dark: dark)
            t.equal(scene.elements.map(\.frame), literal.elements.map(\.frame))
            t.equal(scene.elements.map(\.id), literal.elements.map(\.id))
            t.equal(scene.elements.map(\.glass), literal.elements.map(\.glass))
            t.equal(scene.elements.map(\.backing), literal.elements.map(\.backing))
            t.equal(scene.drawingItems.count, literal.drawingItems.count)
            for (actual, expected) in zip(scene.drawingItems, literal.drawingItems) {
                if case .shape(let actual) = actual, case .shape(let expected) = expected {
                    // Independent projections intentionally create different renderer cache identities.
                    t.equal(actual.shapes, expected.shapes); t.equal(actual.contentFrame, expected.contentFrame)
                } else { t.equal(actual, expected) }
            }
            t.equal(scene.size, SkinSize(width: 40, height: 100))
            let glass = scene.elements.compactMap(\.glass)
            t.equal(glass.map(\.cornerRadius), [7, 3])
            t.equal(glass.map(\.rect), [SkinRect(width: 40, height: 40), SkinRect(y: 40, width: 40, height: 40)])
            t.check(glass.allSatisfy { $0.tint == (dark ? SkinAppearance.dark.accentColor : SkinAppearance.light.accentColor) })
            guard let gauge = scene.elements.first(where: { $0.id.name == "gauge" }) else {
                throw StyleCompilationFixtureError.receipt("Gauge")
            }
            let rounds = gauge.items.compactMap { if case .roundline(let draw) = $0 { return draw }; return nil }
            t.equal(rounds.count, 2); t.check(rounds.allSatisfy(\.roundCaps))
            t.equal(rounds.map(\.color), [RGBA(r: 171, g: 205, b: 239), RGBA(r: 18, g: 52, b: 86)])
        }
        for arguments in ["14, horizontal: 8, top: 4", "14, top: 4, horizontal: 8"] {
            let styled = try styleCompilation(t,
                "style box { .padding(\(arguments)).size(50, 40) }\nwidget { Text(\"A\").style(box) }").program
            let literal = try styleCompilation(t,
                #"widget { Text("A").padding(left: 8, right: 8, top: 4, bottom: 14).size(50, 40) }"#).program
            t.equal(styled.root.padding, SkinInsets(left: 8, top: 4, right: 8, bottom: 14))
            t.equal(styled, literal, "specific labels win regardless of their written order")
            t.equal(try styleScene(styled), try styleScene(literal))
        }
        let wrapped = try styleCompilation(t,
            #"style box { .rounded((.full)) }"# + "\n" + #"widget { Rectangle().size(30, 18).stroke(.accent).style(box) }"#).program
        let literal = try styleCompilation(t, #"widget { Rectangle().size(30, 18).stroke(.accent).rounded(.full) }"#).program
        t.equal(wrapped, literal); t.equal(wrapped.root.cornerRadius, .full)
        let rounded = try styleScene(wrapped), reference = try styleScene(literal)
        guard case .shape(let drawing)? = rounded.drawingItems.first,
              case .shape(let expected)? = reference.drawingItems.first,
              let geometry = drawing.shapes.first?.geometry, case .path(let path) = geometry,
              let subpath = path.subpaths.first, subpath.segments.count >= 2 else {
            throw StyleCompilationFixtureError.receipt("parenthesized full radius")
        }
        t.equal(drawing.shapes, expected.shapes); t.equal(drawing.contentFrame, expected.contentFrame)
        t.equal(subpath.start, ShapePoint(9, 0))
        t.equal(subpath.segments[1].kind.end, ShapePoint(30, 9))
    }

    t.suite("Desk: styles: widget overrides inside package includes retain the actual defining tree identities") {
        let package = #"""
            package { name: "Shared" }
            style base { .font(10).color(.dim) }
            style card { .style(base).padding(3).background(.glass).rounded(4) }
            """#
        let source = #"""
            style base { .font(18).color(.accent) }
            widget { Text("A").style(card).name(label) }
            """#
        let fixture = try styleCompilation(t, source, package: package)
        t.check(fixture.checked.diagnostics.contains { $0.id == .styleReplacesPackage })
        let explicit = try styleCompilation(t,
            #"widget { Text("A").font(18).color(.accent).padding(3).background(.glass).rounded(4).name(label) }"#)
        t.equal(fixture.program, explicit.program)
        t.equal(try styleScene(fixture.program), try styleScene(explicit.program))
        guard let package = fixture.package, let root = fixture.checked.root,
              let facts = fixture.checked.elements[root] else { throw StyleCompilationFixtureError.receipt("package root") }
        t.check(package.tree.version != fixture.checked.tree.version)
        var localCount = 0, sharedCount = 0
        for candidate in facts.facets.values.flatMap({ $0 }) {
            guard case .style(let name, let modifier, let file) = candidate.origin else { continue }
            let definition = name == "base" ? fixture.checked : package
            if name == "base" { localCount += 1 } else { sharedCount += 1 }
            t.equal(file, definition.tree.file)
            t.equal(modifier.treeVersion, definition.tree.version)
            t.equal(candidate.value.treeVersion, definition.tree.version)
            t.check(definition.tree.resolve(modifier) != nil && definition.tree.resolve(candidate.value) != nil)
        }
        t.check(localCount > 0 && sharedCount > 0, "one expansion contains two real source trees")
        t.equal(fixture.result.elementRefs[ElementID(name: "label", index: 0)], root)
        let moved = try styleCompilation(t, "// widget bytes moved 😀\n" + source,
            package: "// package bytes moved independently\n" + package.tree.text)
        t.equal(moved.program, fixture.program)
        t.check(moved.result.elementRefs.values.allSatisfy { $0.treeVersion == moved.checked.tree.version })
        styleRejected(t, fixture.checked, because: "package candidates require the actual checked package")
    }

    t.suite("Desk: styles: local tooltip and VoiceOver literals use source fallback and checked translations") {
        let source = #"""
            style discarded { .tooltip("Old body", title: "Old title").voiceOver("Old label") }
            style note { .tooltip("Body", title: "Heading").voiceOver("Label") }
            widget { Text("A").size(60, 20).style(discarded).style(note) }
            translations {
                "zh-Hans" { "Body": "说明"; "Heading": "标题"; "Label": "标签" }
                "ja" { "Body": "本文" }
            }
            """#
        let fixture = try styleCompilation(t, source)
        for (language, text, title, label) in [
            (Optional<String>.none, "Body", "Heading", "Label"),
            ("zh-Hans", "说明", "标题", "标签"), ("ja", "本文", "Heading", "Label"),
            ("de", "Body", "Heading", "Label")
        ] {
            let scene = try styleScene(fixture.program, language: language)
            t.equal(styleTexts(scene).map(\.text), ["A"])
            t.equal(scene.elements.first?.accessibilityLabel, label)
            t.equal(scene.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: text, title: title))
        }
        t.check(fixture.checked.stringTable.contains { $0.key == "Old body" && $0.translatable },
                "the unused candidate still owns a checked display receipt")
        t.equal(fixture.program.translations.source["Body"], [.text("Body")])
    }

    t.suite("Desk: styles: package tooltip facets can mix with own text and widget translation overrides") {
        let package = #"""
            package { name: "Shared" }
            style note { .tooltip("Shared body", title: "Shared title").voiceOver("Shared label") }
            translations { "zh-Hans" {
                "Shared body": "包正文"; "Shared title": "包标题"; "Shared label": "包标签"
            }; "ja" { "Shared body": "共有本文" } }
            """#
        let source = #"""
            widget { Column(spacing: 0, align: .left) {
                Text("A").size(80, 20).style(note).tooltip("Own body").name(mixed)
                Text("B").size(80, 20).style(note).name(shared)
            } }
            translations { "zh-Hans" {
                "Own body": "自己的正文"; "Shared body": "组件正文"; "Shared title": "组件标题"; "Shared label": "组件标签"
            } }
            """#
        let fixture = try styleCompilation(t, source, package: package)
        for (language, ownText, sharedText, title, label) in [
            (Optional<String>.none, "Own body", "Shared body", "Shared title", "Shared label"),
            ("zh-Hans", "自己的正文", "组件正文", "组件标题", "组件标签"),
            ("ja", "Own body", "共有本文", "Shared title", "Shared label")
        ] {
            let scene = try styleScene(fixture.program, language: language)
            t.equal(scene.hitMap.toolTipInfo(at: 1, 1, images: nil), ToolTipInfo(text: ownText, title: title))
            t.equal(scene.hitMap.toolTipInfo(at: 1, 21, images: nil), ToolTipInfo(text: sharedText, title: title))
            for name in ["mixed", "shared"] {
                guard let element = scene.elements.first(where: { $0.id.name == name }) else {
                    throw StyleCompilationFixtureError.receipt("translated element \(name)")
                }
                t.equal(element.accessibilityLabel, label)
            }
            guard let root = scene.elements.first(where: { $0.id == fixture.program.root.id }) else {
                throw StyleCompilationFixtureError.receipt("unlabelled root")
            }
            t.equal(root.accessibilityLabel, nil, "a structural root does not inherit a child's explicit label")
        }
        guard let package = fixture.package,
              let facts = fixture.checked.elements.values.first(where: { $0.name == "mixed" }),
              let text = facts.facets["tooltip"]?.first,
              let title = facts.facets["tooltip.title"]?.first else { throw StyleCompilationFixtureError.receipt("mixed tooltip") }
        t.equal(text.value.treeVersion, fixture.checked.tree.version)
        t.equal(title.value.treeVersion, package.tree.version)
        t.check(fixture.checked.stringTable.allSatisfy { $0.node.treeVersion == fixture.checked.tree.version })
        t.check(package.stringTable.contains { $0.node == title.value && $0.key == "Shared title" })
    }

    t.suite("Desk: styles: every overridden candidate still requires exact value origin precedence and type receipts") {
        let fixture = try styleCompilation(t, #"""
            style low { .font(10).color(.dim).padding(1).background(.glass).rounded(2) }
            style high { .font(14).color(.accent).padding(3).background(.clearGlass).rounded(4) }
            widget { Text("A").style(low).style(high).font(18).color(.text).padding(5).background(.dim).rounded(6) }
            """#)
        let checked = fixture.checked
        guard let root = checked.root, let facts = checked.elements[root] else {
            throw StyleCompilationFixtureError.receipt("loser root")
        }
        var checkedLosers = 0
        for (facet, candidates) in facts.facets.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for index in candidates.indices.dropFirst() {
                let original = candidates[index]
                guard case .style(let name, let origin, let file) = original.origin else { continue }
                checkedLosers += 1
                let context = "\(facet.rawValue) candidate \(index) from \(name)"
                let changes: [(String, (inout Candidate) -> Void)] = [
                    ("value", { $0.value = candidates[0].value }),
                    ("fixed", { $0.fixedValue = "999" }), ("condition", { $0.condition = .hover }),
                    ("level", { $0.level = 3 }), ("hard", { $0.hard.toggle() }),
                    ("position", { $0.position = 0 }),
                    ("style name", { $0.origin = .style("absent", origin, file: file) }),
                    ("origin node", { $0.origin = .style(name, original.value, file: file) }),
                    ("origin file", { $0.origin = .style(name, origin, file: DeskFileID("Other.desk")) })
                ]
                for (damage, change) in changes {
                    var elements = checked.elements, bad = original
                    change(&bad); elements[root]?.facets[facet]?[index] = bad
                    styleRejected(t, styleFacts(checked, elements: elements), because: "\(context): \(damage)")
                }
                var elements = checked.elements
                elements[root]?.facets[facet]?.remove(at: index)
                styleRejected(t, styleFacts(checked, elements: elements), because: "\(context): removed loser")
                var symbols = checked.symbols; symbols.removeValue(forKey: origin)
                styleRejected(t, styleFacts(checked, symbols: symbols), because: "\(context): missing modifier symbol")
                if checked.symbols[original.value] != nil {
                    symbols = checked.symbols; symbols.removeValue(forKey: original.value)
                    styleRejected(t, styleFacts(checked, symbols: symbols), because: "\(context): missing value symbol")
                }
                if checked.types[original.value] != nil {
                    var types = checked.types; types.removeValue(forKey: original.value)
                    styleRejected(t, styleFacts(checked, types: types), because: "\(context): missing type")
                    types = checked.types; types[original.value] = SemType(type: .bool)
                    styleRejected(t, styleFacts(checked, types: types), because: "\(context): wrong type")
                }
                if checked.canonicalNumericValues[original.value] != nil {
                    var numeric = checked; numeric.canonicalNumericValues.removeValue(forKey: original.value)
                    styleRejected(t, numeric, because: "\(context): missing numeric receipt")
                }
            }
        }
        t.check(checkedLosers >= 16, "font, color, four padding and four rounding facets all have overridden style values")
        guard let colors = facts.facets["color"], colors.count == 3 else {
            throw StyleCompilationFixtureError.receipt("color precedence")
        }
        var elements = checked.elements
        elements[root]?.facets["color"]?.swapAt(1, 2)
        styleRejected(t, styleFacts(checked, elements: elements), because: "loser order")
        elements = checked.elements
        elements[root]?.facets["color"]?[1].position = colors[2].position
        elements[root]?.facets["color"]?[2].position = colors[1].position
        styleRejected(t, styleFacts(checked, elements: elements), because: "position swap preserves the complete position set")
        elements = checked.elements; elements[root]?.facets["color"]?.append(colors[2])
        styleRejected(t, styleFacts(checked, elements: elements), because: "duplicated loser")

        // Repeated style origins are valid; two distinct own modifiers must each consume their own receipt.
        let ownCases = [("hidden", ".hidden(if: system.dark).hidden(if: battery.charging)"),
                        ("color", ".color(.dim, if: system.dark).color(.white, if: battery.charging)")]
        for (key, suffix) in ownCases {
            let fixture = try styleCompilation(t, "widget { Text(\"A\")\(suffix) }")
            let checked = fixture.checked, facet = FacetID(key)
            guard let root = checked.root, let candidates = checked.elements[root]?.facets[facet], candidates.count == 2,
                  case .own = candidates[0].origin, case .own = candidates[1].origin else {
                throw StyleCompilationFixtureError.receipt("two independent own \(key) modifiers")
            }
            t.check(candidates[0].origin != candidates[1].origin)
            var runtime = try ProgramRuntime(program: fixture.program)
            let original = try runtime.project(environment: styleEnvironment(),
                systemInput: ProgramSystemInput(batteryCharging: true), measure: styleMeasure)
            if key == "hidden" { t.check(original.drawingItems.isEmpty, "charging hides while system.dark is false") }
            else { t.equal(styleTexts(original).first?.style.color, .white, "the second condition owns the selected color") }
            for target in candidates.indices {
                var duplicate = candidates[1 - target]
                duplicate.position = candidates[target].position
                var elements = checked.elements; elements[root]?.facets[facet]?[target] = duplicate
                t.equal(elements[root]?.facets[facet]?.map(\.position), candidates.map(\.position),
                        "the forged receipts deliberately preserve count, complete positions and precedence order")
                styleRejected(t, styleFacts(checked, elements: elements), kind: .invalidCheckedModel,
                              because: "\(key) own origin reused at a different expansion position")
            }
        }
        for suffix in ["", #".tooltip("Own")"#] {
            let fixture = try styleCompilation(t,
                "style number { .tooltip((12)) }\nwidget { Text(\"A\").style(number)\(suffix) }")
            let checked = fixture.checked
            guard let root = checked.root,
                  let candidate = checked.elements[root]?.facets["tooltip"]?.first(where: {
                      if case .style = $0.origin { return true }; return false
                  }), let node = checked.tree.resolve(candidate.value), let paren = ParenExprSyntax(node) else {
                throw StyleCompilationFixtureError.receipt("parenthesized numeric tooltip \(suffix)")
            }
            let inner = checked.tree.id(of: paren.value.node)
            t.equal(checked.canonicalNumericValues[candidate.value], 12)
            t.equal(checked.canonicalNumericValues[inner], 12)
            t.equal(checked.numericCoercions[candidate.value], nil)
            t.equal(try styleScene(fixture.program).hitMap.toolTipInfo(at: 1, 1, images: nil)?.text,
                    suffix.isEmpty ? "12" : "Own")
            var forged = checked; forged.canonicalNumericValues[candidate.value] = 999
            styleRejected(t, forged, kind: .invalidCheckedModel,
                          because: "numeric tooltip wrapper must retain its leaf value, including an overridden style")
            forged = checked; forged.numericCoercions[candidate.value] = .percentAsFraction
            styleRejected(t, forged, kind: .invalidCheckedModel,
                          because: "numeric tooltip wrapper cannot introduce a percent coercion, including an overridden style")
        }
    }

    t.suite("Desk: styles: style maps application contracts and package identities reject stale checked trees") {
        let packageSource = "package { name: \"Shared\" }\nstyle shared { .font(12).color(.dim) }"
        let source = "style own { .bold() }\nwidget { Text(\"A\").style(shared).style(own).font(18) }"
        let fixture = try styleCompilation(t, source, package: packageSource)
        guard let package = fixture.package, let shared = package.styles["shared"],
              let own = fixture.checked.styles["own"], let root = fixture.checked.root,
              let facts = fixture.checked.elements[root],
              let sizes = facts.facets["font.size"], sizes.count == 2 else { throw StyleCompilationFixtureError.receipt("package loser") }
        let loser = sizes[1]
        let refreshed = try styleCompilation(t, source, package: packageSource)
        styleRejected(t, fixture.checked, package: refreshed.package, because: "same text is a different supplied tree")
        styleRejected(t, styleFacts(fixture.checked, styles: [:]), package: package, because: "missing own style map")
        styleRejected(t, styleFacts(fixture.checked, styles: ["own": shared]), package: package, because: "style map refers to the other tree")
        styleRejected(t, fixture.checked, package: styleFacts(package, styles: [:]), because: "missing package style map")
        styleRejected(t, fixture.checked, package: styleFacts(package, styles: ["shared": own]), because: "package map points into widget")
        var elements = fixture.checked.elements
        if case .style(let name, var identity, let file) = loser.origin {
            identity.treeVersion = fixture.checked.tree.version
            let facet = FacetID("font.size")
            elements[root]?.facets[facet]?[1].origin = .style(name, identity, file: file)
            styleRejected(t, styleFacts(fixture.checked, elements: elements), package: package,
                          because: "package offset cannot be interpreted as a widget NodeID")
        } else { throw StyleCompilationFixtureError.receipt("package style origin") }
        for (identity, symbol) in fixture.checked.symbols where symbol == .builtIn(.modifier("style")) {
            var symbols = fixture.checked.symbols; symbols.removeValue(forKey: identity)
            styleRejected(t, styleFacts(fixture.checked, symbols: symbols), package: package,
                          because: "style application needs its own checked modifier identity")
        }
        guard let styleIndex = DeskCatalog.current.modifiers.firstIndex(where: { $0.name == "style" }) else {
            throw StyleCompilationFixtureError.receipt("style catalog")
        }
        let changes: [(inout ModifierSpec) -> Void] = [
            { $0.allowedInStyle = false }, { $0.repeatable = .no },
            { $0.signatures[0].params[0].role = .plain }, { $0.signatures[0].params[0].type = .string }
        ]
        for change in changes {
            var catalog = DeskCatalog.current; change(&catalog.modifiers[styleIndex])
            styleRejected(t, fixture.checked, package: package, catalog: catalog, because: "changed style catalog contract")
        }
    }

    t.suite("Desk: styles: stale and nontranslatable display receipts reject winners and overridden literals") {
        let source = #"""
            style old { .tooltip("Old", title: "Old title").voiceOver("Old label") }
            style current { .tooltip("Body", title: "Title").voiceOver("Label") }
            widget { Text("A").style(old).style(current) }
            translations { "zh-Hans" { "Body": "说明"; "Title": "标题"; "Label": "标签" } }
            """#
        let fixture = try styleCompilation(t, source)
        let checked = fixture.checked
        for key in ["Old", "Old title", "Old label", "Body", "Title", "Label"] {
            guard let index = checked.stringTable.firstIndex(where: { $0.key == key }) else {
                throw StyleCompilationFixtureError.receipt("string \(key)")
            }
            var strings = checked.stringTable; strings.remove(at: index)
            styleRejected(t, styleFacts(checked, strings: strings), because: "missing display receipt: \(key)")
            strings = checked.stringTable; strings[index].translatable = false
            styleRejected(t, styleFacts(checked, strings: strings), because: "false display receipt: \(key)")
            strings = checked.stringTable; strings[index].range = 0..<0
            styleRejected(t, styleFacts(checked, strings: strings), because: "incorrect display range: \(key)")
        }
        let fresh = deskCheck(source, file: "Styles.desk")
        styleRejected(t, styleFacts(fresh, strings: checked.stringTable), because: "stale local string tree")
        let mixed = try styleCompilation(t, #"widget { Text("A").style(note).tooltip("Own") }"#,
            package: #"""
                package { name: "Shared" }
                style note { .tooltip("Shared", title: "Heading").voiceOver("Label") }
                translations { "zh-Hans" { "Heading": "标题"; "Label": "标签" } }
                """#)
        guard let package = mixed.package,
              let titleIndex = package.stringTable.firstIndex(where: { $0.key == "Heading" }) else {
            throw StyleCompilationFixtureError.receipt("package title receipt")
        }
        var strings = package.stringTable; strings[titleIndex].translatable = false
        styleRejected(t, mixed.checked, package: styleFacts(package, strings: strings), because: "package title false receipt")
        strings = package.stringTable; strings[titleIndex].node.treeVersion = mixed.checked.tree.version
        styleRejected(t, mixed.checked, package: styleFacts(package, strings: strings), because: "package title stale tree")
    }

    t.suite("Desk: styles: local dynamic slots preserve the original sources and explicit projection behavior") {
        let cases = [
            (".color(.accent, if: false)", ".style(base).color(.text)", ".color(.accent, if: false).color(.text)"),
            (".hidden(if: system.dark)", ".style(base)", ".hidden(if: system.dark)"),
            (".font(system.dark ? 18 : 12)", ".style(base).font(12)", ".font(12)"),
            (".tooltip(\"{cpu.usage}\")", ".style(base).tooltip(\"Own\")", ".tooltip(\"Own\")"),
            (".voiceOver(battery.charging)", ".style(base).voiceOver(\"Own\")", ".voiceOver(\"Own\")")
        ]
        for (definition, application, explicit) in cases {
            let source = "style base { \(definition) }\nwidget { Text(\"A\")\(application) }"
            let styled = try styleCompilation(t, source)
            let literal = try styleCompilation(t, "widget { Text(\"A\")\(explicit) }")
            t.equal(styled.program, literal.program, source)
            for dark in [false, true] {
                t.equal(try styleScene(styled.program, dark: dark), try styleScene(literal.program, dark: dark), source)
            }
        }
    }

    t.suite("Desk: styles: inactive color applications match explicit conditional modifiers") {
        let styled = try styleCompilation(t, "style base { .color(.accent) }\nwidget { Text(\"A\").style(base, if: false) }")
        let explicit = try styleCompilation(t, "widget { Text(\"A\").color(.accent, if: false) }")
        t.equal(styled.program, explicit.program)
        for dark in [false, true] {
            t.equal(try styleScene(styled.program, dark: dark), try styleScene(explicit.program, dark: dark))
        }
    }

    t.suite("Desk: styles: unsupported conditional facets other dynamic facets states and losers still reject the whole program") {
        let sources = [
            "style base { .font(12) }\nwidget { Text(\"A\").style(base, if: false) }",
            "style base { .color(system.accentColor) }\nwidget { Text(\"A\").style(base).color(.text) }",
            "style base { .hover { .color(.accent) } }\nwidget { Text(\"A\").style(base) }",
            "style base { .pressed { .bold() } }\nwidget { Text(\"A\").style(base) }",
            "style base { .margin(2) }\nwidget { Text(\"A\").style(base) }",
            "style base { .uppercase() }\nwidget { Text(\"A\").style(base) }",
            "style base { .background(.glass, if: false) }\nwidget { Text(\"A\").style(base).background(.dim) }",
            "style base { .fill(gradient(.black, .white)) }\nwidget { Rectangle().style(base).fill(.accent) }"
        ]
        for source in sources {
            let checked = deskCheck(source)
            t.check(checked.diagnostics(.error).isEmpty, "\(source)\n\(deskDescribe(checked))")
            styleRejected(t, checked, kind: .unsupported, because: source)
        }
    }

    t.suite("Desk: styles: expansion depth repeated losers and display bytes share bounded compiler budgets") {
        let small = try styleCompilation(t, "style base { .font(12).color(.dim) }\nwidget { Text(\"A\").style(base) }")
        var catalog = DeskCatalog.current; catalog.limits.maximumTokens = 32
        let control = Desk.compile(small.checked, catalog: catalog)
        t.check(control.program != nil && control.issues.isEmpty, "a small real style fits the same reduced budget")
        let repeated = deskCheck("style base { .font(12).color(.dim) }\nwidget { Text(\"A\")" +
            String(repeating: ".style(base)", count: 48) + ".font(18).color(.text) }")
        t.check(repeated.diagnostics(.error).isEmpty, deskDescribe(repeated))
        styleRejected(t, repeated, catalog: catalog, kind: .resourceLimit, because: "repeated overridden expansions")
        let inapplicable = deskCheck("style textOnly { .bold() }\nwidget { Rectangle().size(10)" +
            String(repeating: ".style(textOnly)", count: 48) + " }")
        t.check(inapplicable.diagnostics(.error).isEmpty, deskDescribe(inapplicable))
        styleRejected(t, inapplicable, catalog: catalog, kind: .resourceLimit,
                      because: "inapplicable expansions still consume the global traversal budget")
        let includes = (0..<8).map { index in
            "style depth\(index) { " + (index == 7 ? ".bold()" : ".style(depth\(index + 1))") + " }"
        }.joined(separator: "\n")
        let deep = deskCheck(includes + "\nwidget { Text(\"A\").style(depth0) }")
        t.check(deep.diagnostics(.error).isEmpty, deskDescribe(deep))
        catalog = .current; catalog.limits.maximumBlockNesting = 4
        styleRejected(t, deep, catalog: catalog, kind: .resourceLimit, because: "style include depth")
        let loser = deskCheck("style base { .tooltip(\"far too long for this budget\") }\nwidget { Text(\"A\").style(base).tooltip(\"Own\") }")
        t.check(loser.diagnostics(.error).isEmpty, deskDescribe(loser))
        catalog = .current; catalog.limits.maximumTextLength = 8
        styleRejected(t, loser, catalog: catalog, kind: .resourceLimit, because: "overridden literal still consumes its text limit")
    }
}
