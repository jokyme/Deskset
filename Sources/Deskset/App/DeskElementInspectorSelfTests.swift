import Foundation
import DeskLanguage
import DesksetCore

/// Property pages and planned language edits only: no windows, clipboard, opening or document writes.
enum DeskElementInspectorSelfTests {
    private enum Failure: Error { case fixture, fixtureDetail(String), number, operation }

    static func run(_ t: AppTestRunner) {
        literalTests(t)
        insertionTests(t)
        readOnlyTests(t)
        referenceTests(t)
        dimensionTests(t)
        squareTests(t)
        textTests(t)
        positionTests(t)
        independentSourceTests(t)
    }

    private static let file = DeskFileID(path: "Inspector.desk")

    private static func service(_ text: String) -> DeskLanguageService {
        DeskLanguageService(openFile: file, files: [file: text])
    }

    private static func inspector(_ snapshot: DeskSnapshot, component: String = "Rectangle") throws -> DeskElementInspector {
        guard let hit = snapshot.elements().first(where: { $0.component == component }),
              let inspector = DeskElementInspector(snapshot: snapshot, element: hit.element) else {
            throw Failure.fixtureDetail("inspector \(component): checked=\(snapshot.isChecked), elements=\(snapshot.elements().map(\.component)), source=\(snapshot.text)")
        }
        return inspector
    }

    private static func number(_ inspector: DeskElementInspector, item: String = "desk.corners") throws -> StudioPage.Number {
        guard case .row(let row)? = inspector.page.item(item)?.kind,
              case .number(let number) = row.control else { throw Failure.number }
        return number
    }

    private static func planned(_ t: AppTestRunner, _ inspector: DeskElementInspector,
                                _ change: StudioNumberChange) throws -> [DeskTextEditU16] {
        guard case .edit(let workspace, let name)? = inspector.operation(for: .number(item: "desk.corners", part: 0, change: change))
        else { throw Failure.operation }
        t.equal(workspace.changedFiles, [file])
        t.equal(name, StudioText[.rowCorners])
        return workspace.edits(for: file)
    }

    private static func literalTests(_ t: AppTestRunner) {
        t.suite("Desk: element inspector: literal radius edits preserve Unicode trivia and written units") {
            for unit in ["", "pt"] {
                let source = "\u{FEFF}info { name: \"圆角😀\" }\r\nwidget { Rectangle().size(90, 70).rounded(/* radius */ 16\(unit) /* keep */).name(box) }\r\n"
                let s = service(source).snapshot
                t.equal(s.checked.diagnostics.filter { $0.severity == .error }.map(\.id), [])
                let i = try inspector(s)
                guard let candidate = s.checked.elements[i.element]?.facets["rounded.topLeft"]?.first else { throw Failure.fixture }
                t.equal(s.checked.types[candidate.value]?.type, unit.isEmpty ? .plainNumber : .length,
                        "the checked union parameter retains bare numbers as Plain and written points as Length")
                t.equal(s.checked.canonicalNumericValues[candidate.value], 16)
                let field = try number(i)
                t.equal(field.value, 16)
                t.equal(field.defaultText, "0")
                t.equal(field.minimum, 0)
                t.equal(i.page.item("desk.corners").map { StudioPage.controls(in: $0.kind) }, 1)
                let edits = try planned(t, i, .typed("20 + 3"))
                t.equal(edits.count, 1)
                t.equal(edits.first?.nsRange, (source as NSString).range(of: "16" + unit))
                t.equal(edits.first?.newText, "23" + unit)
                let expected = source.replacingOccurrences(of: "16" + unit, with: "23" + unit)
                t.equal(DeskTextEditU16.apply(edits, to: source), expected,
                        "only the radius literal changes; BOM, CRLF, emoji and both comments stay byte-for-byte")
                t.equal(s.text, source, "planning never changes the bound snapshot")
                t.check(i.operation(for: .number(item: "desk.corners", part: 0, change: .typed("16"))) == nil)
                let reset = try planned(t, i, .reset)
                t.equal(DeskTextEditU16.apply(reset, to: source), source.replacingOccurrences(of: "16" + unit, with: "0" + unit))
                let divided = try planned(t, i, .typed("1 / 0"))
                t.equal(DeskTextEditU16.apply(divided, to: source), source.replacingOccurrences(of: "16" + unit, with: "0" + unit),
                        "the existing number control deliberately evaluates division by zero as zero, preserving the written unit")
                let step = try planned(t, i, .step(1))
                t.equal(DeskTextEditU16.apply(step, to: source), source.replacingOccurrences(of: "16" + unit, with: "17" + unit))
            }
        }
    }

    private static func insertionTests(_ t: AppTestRunner) {
        t.suite("Desk: element inspector: absent radius inserts in catalog order only after a completed change") {
            let source = "info { name: \"T\" }\r\nwidget {\r\n    Rectangle()\r\n        .fill(.accent)\r\n        .size(90, 70)\r\n        .name(box)\r\n}\r\n"
            let i = try inspector(service(source).snapshot)
            t.equal(try number(i).value, 0)
            t.check(i.operation(for: .number(item: "desk.corners", part: 0, change: .drag(delta: 8, done: false))) == nil,
                    "a scrub preview does not write intermediate values")
            let edits = try planned(t, i, .drag(delta: 8, done: true))
            t.equal(edits.count, 1)
            t.equal(edits.first?.nsRange.length, 0)
            let expected = source.replacingOccurrences(of: ".name(box)", with: ".rounded(8)\r\n        .name(box)")
            t.equal(DeskTextEditU16.apply(edits, to: source), expected,
                    "rounding is after size and before name, preserving the established indentation and newline")
            t.check(i.operation(for: .number(item: "desk.corners", part: 0, change: .reset)) == nil,
                    "resetting an already square rectangle does not create an unnecessary modifier")
            t.equal(StudioNumberInput.evaluate("1 / 0"), 0, "the inherited numeric field contract is zero for division by zero")
            t.check(i.operation(for: .number(item: "desk.corners", part: 0, change: .typed("1 / 0"))) == nil,
                    "a zero result does not edit an already square rectangle")
            for change in [StudioNumberChange.typed("-1"), .typed("radius"), .typed("nan"),
                           .step(-1), .step(.infinity), .drag(delta: .nan, done: true)] {
                if case .rejected(let message)? = i.operation(for: .number(item: "desk.corners", part: 0, change: change)) {
                    t.equal(message, StudioText[.deskInspectorInvalidRadius])
                } else { t.check(false, "invalid radius must be explicitly rejected: \(change)") }
            }
            t.check(i.operation(for: .number(item: "desk.corners", part: 1, change: .typed("8"))) == nil)
            t.check(i.operation(for: .number(item: "other", part: 0, change: .typed("8"))) == nil)
            t.check(i.operation(for: .number(item: "desk.corners", part: 0, change: .textStep(1))) == nil)
            t.equal(i.snapshot.text, source)
        }
    }

    private static func readOnlyTests(_ t: AppTestRunner) {
        t.suite("Desk: element inspector: expressions styles conditions and separate corners remain read-only") {
            let cases: [(String, StudioValueSource?)] = [
                ("widget { Rectangle().size(90, 70).rounded(.full) }", nil),
                ("widget { Rectangle().size(90, 70).rounded(8 + 8) }", nil),
                ("widget { variable radius = 16; Rectangle().size(90, 70).rounded(radius) }", .live),
                ("options { radius = Slider(\"Corners\", min: 0pt, max: 50pt) }\nwidget { Rectangle().size(90, 70).rounded(options.radius) }", .option),
                ("widget { Rectangle().size(90, 70).style(panel) }\nstyle panel { .rounded(16) }", .style),
                ("widget { Rectangle().size(90, 70).rounded(16, if: true) }", .rule),
                ("widget { Rectangle().size(90, 70).hover { .rounded(16) } }", .rule),
                ("widget { if true { Rectangle().size(90, 70).rounded(16) } }", .rule),
                ("widget { Column { for n in 1...2 { Rectangle().size(90, 70).rounded(16) } } }", .rule),
                ("widget { Rectangle().size(90, 70).rounded(16, topLeft: 8) }", nil),
                ("widget { Rectangle().size(90, 70).rounded(topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16) }", nil),
                ("widget { Rectangle().size(90, 70).rounded() }", nil),
                ("widget { Rectangle().size(90, 70).rounded(16px) }", nil),
                ("widget { Rectangle().size(90, 70).rounded(16).rounded(8) }", nil),
            ]
            for (body, expectedSource) in cases {
                let text = "info { name: \"T\" }\n" + body
                let i = try inspector(service(text).snapshot)
                t.equal(i.page.item("desk.corners").map { StudioPage.controls(in: $0.kind) }, 0, body)
                guard case .row(let row)? = i.page.item("desk.corners")?.kind,
                      case .text(let written) = row.control else { throw Failure.fixture }
                t.equal(row.source, expectedSource, body)
                t.check(!written.isEmpty && row.tooltip == written, "the written origin remains inspectable: \(body)")
                if expectedSource == .style { t.check(written.contains("panel") && written.contains(file.path)) }
                if case .rejected? = i.operation(for: .number(item: "desk.corners", part: 0, change: .typed("0"))) {
                    t.check(true)
                } else { t.check(false, "a forged numeric event must not overwrite read-only source: \(body)") }
                guard case .showInCode(let range)? = i.operation(for: .noteLink(item: "desk.corners.source")) else { throw Failure.operation }
                t.equal((text as NSString).substring(with: range.nsRange), "Rectangle()")
                t.equal(i.snapshot.text, text)
            }
            let circle = try inspector(service("info { name: \"T\" }\nwidget { Circle().size(12) }").snapshot, component: "Circle")
            t.equal(circle.page.item("desk.corners").map { StudioPage.controls(in: $0.kind) }, nil)
            t.check(circle.page.item("desk.corners") == nil, "other components do not offer Rectangle controls")
            if case .showInCode? = circle.operation(for: .link("show-in-code")) { t.check(true) }
            else { t.check(false, "unsupported component retains Show in Code") }
        }
    }

    private static func referenceTests(_ t: AppTestRunner) {
        t.suite("Desk: element inspector: snapshot references and bilingual pages keep code navigation safe") {
            let text = "info { name: \"T\" }\nwidget { Rectangle().size(90, 70).rounded(16) }"
            let s = service(text)
            let i = try inspector(s.snapshot)
            let newSnapshot = service(text).snapshot
            t.check(DeskElementInspector(snapshot: newSnapshot, element: i.element) == nil,
                    "identical bytes parsed in a different tree do not make the old reference current")
            let missing = ElementRef(kind: .callStmt, utf8Start: text.utf8.count, treeVersion: s.snapshot.tree.version)
            t.check(DeskElementInspector(snapshot: s.snapshot, element: missing) == nil, "an EOF location is not an element")
            let pending = s.beginUpdate(changes: [], version: 1).snapshot
            t.check(!pending.isChecked)
            t.check(DeskElementInspector(snapshot: pending, element: i.element) == nil, "pending carried facts do not authorize edits")
            let previousLanguage = StudioText.languageOverride
            defer { StudioText.languageOverride = previousLanguage }
            let keys: [StudioText.Key] = [.deskInspectorReadOnly, .deskInspectorExpression, .deskInspectorConditional,
                .deskInspectorMixedCorners, .deskInspectorFullRadius, .deskInspectorUnsupported,
                .deskInspectorInvalidRadius, .deskInspectorUnavailable, .deskInspectorSelectElement,
                .deskInspectorDiskChanged, .deskInspectorSourceUnavailable, .deskInspectorEditRejected,
                .deskInspectorWidth, .deskInspectorHeight, .deskInspectorSizing, .deskInspectorFixed, .deskInspectorFill,
                .deskInspectorInherited, .deskInspectorContainerAligned, .deskInspectorInvalidSize,
                .deskInspectorInvalidFontSize, .deskInspectorInvalidPosition, .deskInspectorInvalidText,
                .deskInspectorPresetSize, .deskInspectorFontPreset]
            for language in StudioLanguage.allCases {
                StudioText.languageOverride = language
                let page = i.page
                t.equal(page.footer.first?.title, StudioText[.showInCode])
                t.equal(page.footer.first?.detail, "", "the standalone inspector does not advertise an unbound shortcut")
                t.equal(page.subtitle, StudioText.format(.subtitleKind, StudioText[.kindShape]))
                t.equal(page.scope?.text, StudioText.format(.scopeOnly, StudioText[.nounShape]))
                t.check(page.scope?.link == nil, "this edit cannot silently widen its scope")
                t.equal(try number(i).unit, language == .chinese ? "点" : "pt")
                for key in keys { t.check(!StudioText[key].isEmpty, "localized inspector key \(key) in \(language)") }
                guard case .showInCode(let range)? = i.operation(for: .link("show-in-code")) else { throw Failure.operation }
                t.equal((text as NSString).substring(with: range.nsRange), "Rectangle()")
            }
        }
    }

    private static func edits(_ inspector: DeskElementInspector, _ event: StudioPageEvent) throws -> [DeskTextEditU16] {
        guard case .edit(let workspace, _)? = inspector.operation(for: event), workspace.changedFiles == [file] else { throw Failure.operation }
        return workspace.edits(for: file)
    }

    private static func checkedText(_ t: AppTestRunner, _ text: String) -> DeskSnapshot {
        let snapshot = service(text).snapshot
        t.equal(snapshot.checked.diagnostics.filter { $0.severity == .error }.map(\.id), [], text)
        return snapshot
    }

    private static func readOnly(_ inspector: DeskElementInspector, item: String) throws -> StudioPage.Row {
        guard case .row(let row)? = inspector.page.item(item)?.kind, case .text = row.control else {
            let facts = inspector.snapshot.checked.elements[inspector.element]
            throw Failure.fixtureDetail("expected read-only \(item): item=\(String(describing: inspector.page.item(item)?.kind)), isRoot=\(String(describing: facts?.isRoot)), parent=\(String(describing: facts?.parent)), source=\(inspector.snapshot.text)")
        }
        return row
    }

    private static func dimensionTests(_ t: AppTestRunner) {
        t.suite("Desk: element inspector layout: checked sizes switch fixed fit fill without losing limits") {
            let source = "\u{FEFF}info { name: \"尺寸😀\" }\r\nwidget { Rectangle().width(/*w*/ 80pt, min: 10pt, max: 120pt /*limit*/).height(40).rounded(8) }\r\n"
            let i = try inspector(checkedText(t, source))
            t.equal(try number(i, item: "desk.width").value, 80)
            t.equal(try number(i, item: "desk.height").value, 40)
            let changed = try edits(i, .number(item: "desk.width", part: 0, change: .typed("90")))
            let expected = source.replacingOccurrences(of: "80pt", with: "90pt")
            t.equal(DeskTextEditU16.apply(changed, to: source), expected)
            t.equal(changed.count, 1)
            _ = checkedText(t, expected)
            for (index, mode) in [(1, ".fit"), (2, ".fill")] {
                let modeEdits = try edits(i, .choose(item: "desk.width.mode", index: index))
                let modeText = DeskTextEditU16.apply(modeEdits, to: source)
                t.equal(modeText, source.replacingOccurrences(of: "80pt", with: mode),
                        "changing the spec changes only the value, never its min/max or trivia")
                let modeInspector = try inspector(checkedText(t, modeText))
                t.equal(try number(modeInspector, item: "desk.width").value, nil)
                guard case .row(let row)? = modeInspector.page.item("desk.width.mode")?.kind,
                      case .popup(let popup) = row.control else {
                    let item = modeInspector.page.item("desk.width.mode")?.kind
                    throw Failure.fixtureDetail("expected width mode popup after \(mode): item=\(String(describing: item)), source=\(modeText)")
                }
                t.equal(popup.selected, index)
                t.check(!popup.items[0].enabled, "a fixed width is entered, never guessed from a rendered frame")
                t.check(modeInspector.operation(for: .choose(item: "desk.width.mode", index: index)) == nil)
                let fixed = try edits(modeInspector, .number(item: "desk.width", part: 0, change: .typed("100")))
                t.equal(DeskTextEditU16.apply(fixed, to: modeText), source.replacingOccurrences(of: "80pt", with: "100"))
            }
            t.check(i.operation(for: .number(item: "desk.width", part: 0, change: .drag(delta: 5, done: false))) == nil)
            t.check(i.operation(for: .number(item: "desk.width", part: 0, change: .typed("80"))) == nil)
            for value in ["-1", "nan", "size"] {
                if case .rejected(let message)? = i.operation(for: .number(item: "desk.width", part: 0, change: .typed(value))) {
                    t.equal(message, StudioText[.deskInspectorInvalidSize])
                } else { t.check(false, "invalid size must be refused: \(value)") }
            }
            let absentSource = "info { name: \"T\" }\nwidget { Text(\"Hello\").font(13).name(title) }"
            let absent = try inspector(checkedText(t, absentSource), component: "Text")
            let inserted = try edits(absent, .number(item: "desk.height", part: 0, change: .typed("40")))
            t.equal(DeskTextEditU16.apply(inserted, to: absentSource), absentSource.replacingOccurrences(of: ".name(title)", with: ".height(40).name(title)"))
            let preset = try inspector(checkedText(t, "info { name: \"T\"; size: .small }\nwidget { Rectangle().rounded(8) }"))
            t.equal(try readOnly(preset, item: "desk.width").detail, StudioText[.deskInspectorPresetSize])
            if case .rejected? = preset.operation(for: .number(item: "desk.width", part: 0, change: .typed("40"))) { t.check(true) }
            else { t.check(false, "an ignored root dimension must not offer a false edit") }
        }
    }

    private static func squareTests(_ t: AppTestRunner) {
        t.suite("Desk: element inspector layout: resizing one square axis preserves the other value comments and trailing comma") {
            let clauses = ["/*大小😀*/24pt /*keep*/", "/*大小😀*/24pt, /*tail*/", "\r\n /*大小😀*/24pt //line\r\n", "\r\n /*大小😀*/24pt, //line\r\n"]
            for clause in clauses {
                let source = "\u{FEFF}info { name: \"T\" }\r\nwidget { Rectangle().size(\(clause)).rounded(8).name(box) }\r\n"
                let original = try inspector(checkedText(t, source))
                for axis in ["width", "height"] {
                    let event = StudioPageEvent.number(item: "desk." + axis, part: 0, change: .typed("40"))
                    let changes = try edits(original, event)
                    let text = DeskTextEditU16.apply(changes, to: source)
                    let next = try inspector(checkedText(t, text))
                    t.equal(try number(next, item: "desk." + axis).value, 40)
                    t.equal(try number(next, item: "desk." + (axis == "width" ? "height" : "width")).value, 24,
                            "the unedited axis retains the original square side")
                    let call = "Rectangle().size("
                    guard let oldStart = source.range(of: call), let oldEnd = source.range(of: ").rounded(8)"),
                          let newStart = text.range(of: call), let newEnd = text.range(of: ").rounded(8)") else { throw Failure.fixture }
                    let before = String(source[..<oldStart.upperBound]), after = String(source[oldEnd.lowerBound...])
                    t.equal(String(text[..<newStart.upperBound]), before)
                    t.equal(String(text[newEnd.lowerBound...]), after)
                    t.check(text.contains("/*大小😀*/24pt"), "the untouched value retains its unit and leading comment")
                    t.equal(text.components(separatedBy: "/*大小😀*/").count, 2, "no comment is duplicated")
                    t.check(text.contains(clause.contains("//line") ? "//line\r\n" : clause.contains("/*tail*/") ? "/*tail*/" : "/*keep*/"))
                    t.equal(changes.count, 1, "the clause expansion is one editor transaction")
                }
            }
            let source = "info { name: \"T\" }\nwidget { Rectangle().size(/*W*/ 24pt, /*H*/ 32pt /*tail*/).rounded(8) }"
            let i = try inspector(checkedText(t, source))
            let changes = try edits(i, .number(item: "desk.height", part: 0, change: .typed("48")))
            t.equal(DeskTextEditU16.apply(changes, to: source), source.replacingOccurrences(of: "32pt", with: "48pt"),
                    "a two-argument size keeps the existing smallest literal replacement")
        }
    }

    private static func textTests(_ t: AppTestRunner) {
        t.suite("Desk: element inspector text: literal words and own font size preserve meaning and independent arguments") {
            let source = "\u{FEFF}info { name: \"文字😀\" }\r\nwidget { Text(/*words*/ \"Before\" /*keep*/).font(/*font*/ 13pt, .semibold).size(240, 80).name(title) }\r\n"
            let i = try inspector(checkedText(t, source), component: "Text")
            t.check(try number(i, item: "desk.text.content").isText)
            t.equal(try number(i, item: "desk.text.size").value, 13)
            let words = "引号\"、反斜杠\\、{cpu.usage}、{{}}😀\n第二行\r\n\tTab"
            let changes = try edits(i, .number(item: "desk.text.content", part: 0, change: .typed(words)))
            let text = DeskTextEditU16.apply(changes, to: source)
            let next = try inspector(checkedText(t, text), component: "Text")
            t.equal(try number(next, item: "desk.text.content").text, words,
                    "braces stay literal words and cannot silently become live interpolation")
            t.equal(changes.count, 1)
            t.equal(changes.first?.nsRange, (source as NSString).range(of: "\"Before\""))
            t.check(text.hasPrefix("\u{FEFF}") && text.hasSuffix("\r\n"))
            t.check(text.contains("/*words*/") && text.contains("/*keep*/"))
            t.check(next.operation(for: .number(item: "desk.text.content", part: 0, change: .typed(words))) == nil)
            let empty = try edits(i, .number(item: "desk.text.content", part: 0, change: .typed("")))
            t.equal(DeskTextEditU16.apply(empty, to: source), source.replacingOccurrences(of: "\"Before\"", with: "\"\""))
            let font = try edits(i, .number(item: "desk.text.size", part: 0, change: .typed("16")))
            t.equal(DeskTextEditU16.apply(font, to: source), source.replacingOccurrences(of: "13pt", with: "16pt"))
            let familySource = "info { name: \"T\" }\nwidget { Text(\"words\").font(\"System\", /*size*/ 13pt, .bold) }"
            let family = try inspector(checkedText(t, familySource), component: "Text")
            let familyEdits = try edits(family, .number(item: "desk.text.size", part: 0, change: .step(1)))
            t.equal(DeskTextEditU16.apply(familyEdits, to: familySource), familySource.replacingOccurrences(of: "13pt", with: "14pt"),
                    "editing the size cannot replace the named family or weight")
            for value in ["0", "-1", "nan"] {
                if case .rejected(let message)? = i.operation(for: .number(item: "desk.text.size", part: 0, change: .typed(value))) {
                    t.equal(message, StudioText[.deskInspectorInvalidFontSize])
                } else { t.check(false, "font size must remain finite and positive") }
            }
            if case .rejected? = i.operation(for: .number(item: "desk.text.content", part: 0,
                change: .typed(String(repeating: "x", count: ProgramLimits.maximumTextLength + 1)))) { t.check(true) }
            else { t.check(false, "text cannot exceed the executable program's limit") }
        }
    }

    private static func positionTests(_ t: AppTestRunner) {
        t.suite("Desk: element inspector position: direct Freeform fixed coordinates keep signed units anchor and missing-axis defaults") {
            let source = "\u{FEFF}info { name: \"T\" }\r\nwidget { Freeform { Rectangle().size(24, 32).position(x: /*x*/ -3pt, y: 8pt, anchor: .bottomRight /*anchor*/).rounded(8) } }\r\n"
            let i = try inspector(checkedText(t, source))
            t.equal(try number(i, item: "desk.position.x").value, -3)
            t.equal(try number(i, item: "desk.position.x").minimum, nil)
            let changes = try edits(i, .number(item: "desk.position.x", part: 0, change: .typed("-5")))
            t.equal(DeskTextEditU16.apply(changes, to: source), source.replacingOccurrences(of: "-3pt", with: "-5pt"))
            _ = checkedText(t, DeskTextEditU16.apply(changes, to: source))
            let missing = "info { name: \"T\" }\r\nwidget { Freeform { Rectangle().size(24).position(y: 8pt, anchor: .topRight, //keep\r\n).rounded(8) } }"
            let absent = try inspector(checkedText(t, missing))
            t.equal(try number(absent, item: "desk.position.x").value, 0)
            let inserted = try edits(absent, .number(item: "desk.position.x", part: 0, change: .typed("-10")))
            let result = DeskTextEditU16.apply(inserted, to: missing)
            t.equal(result, missing.replacingOccurrences(of: ".position(", with: ".position(x: -10, "))
            let next = try inspector(checkedText(t, result))
            t.equal(try number(next, item: "desk.position.y").value, 8)
            t.check(result.contains("anchor: .topRight, //keep\r\n"))
            let centered = try inspector(checkedText(t, "info { name: \"T\" }\nwidget { Freeform { Rectangle().size(24) } }"))
            let row = try readOnly(centered, item: "desk.position.x")
            t.equal(row.tooltip, StudioText[.deskInspectorContainerAligned])
            if case .rejected? = centered.operation(for: .number(item: "desk.position.x", part: 0, change: .typed("20"))) { t.check(true) }
            else { t.check(false, "an aligned child must not silently become positioned at topLeft") }
            let stacked = try inspector(checkedText(t, "info { name: \"T\" }\nwidget { Column { Rectangle().size(24) } }"))
            t.check(stacked.page.item("desk.position.x") == nil)
            t.check(stacked.operation(for: .number(item: "desk.position.x", part: 0, change: .typed("20"))) == nil)
        }
    }

    private static func independentSourceTests(_ t: AppTestRunner) {
        t.suite("Desk: element inspector sources: dynamic facets stay read-only without locking independent fixed properties") {
            let source = "info { name: \"T\" }\nwidget { variable width = 80pt; Rectangle().width(width).height(40pt).rounded(8) }"
            let i = try inspector(checkedText(t, source))
            t.equal(try readOnly(i, item: "desk.width").source, .live)
            t.equal(try number(i, item: "desk.height").value, 40)
            let height = try edits(i, .number(item: "desk.height", part: 0, change: .typed("48")))
            t.equal(DeskTextEditU16.apply(height, to: source), source.replacingOccurrences(of: "40pt", with: "48pt"))
            for body in [
                "widget { Text(\"{cpu.usage}\").font(13) }",
                "widget { Text(\"words\").font(8 + 8) }",
                "widget { Text(\"words\").font(.headline) }",
                "widget { Column { Text(\"words\") }.font(13) }",
                "widget { Text(#\"raw {cpu.usage}\"#).font(13) }",
            ] {
                let text = "info { name: \"T\" }\n" + body
                let textInspector = try inspector(checkedText(t, text), component: "Text")
                let item = body.contains("cpu.usage") ? "desk.text.content" : "desk.text.size"
                _ = try readOnly(textInspector, item: item)
                if case .rejected? = textInspector.operation(for: .number(item: item, part: 0, change: .typed("20"))) { t.check(true) }
                else { t.check(false, "a fixed edit cannot replace an expression, preset or inherited source") }
                guard case .showInCode? = textInspector.operation(for: .noteLink(item: item + ".source")) else { throw Failure.operation }
                if item == "desk.text.content" { t.equal(try number(textInspector, item: "desk.text.size").value, 13) }
                else { t.check(try number(textInspector, item: "desk.text.content").isText) }
            }
            let style = "info { name: \"T\" }\nwidget { Rectangle().style(layout).rounded(8) }\nstyle layout { .width(80) }"
            let styled = try inspector(checkedText(t, style))
            t.equal(try readOnly(styled, item: "desk.width").source, .style)
            t.equal(try number(styled).value, 8)
            let invalid = try inspector(service("info { name: \"T\" }\nwidget { Rectangle().width(16px).rounded(8) }").snapshot)
            _ = try readOnly(invalid, item: "desk.width")
            if case .rejected? = invalid.operation(for: .number(item: "desk.width", part: 0, change: .typed("20"))) { t.check(true) }
            else { t.check(false, "a diagnosed unit never becomes an editable length") }
        }
    }
}
