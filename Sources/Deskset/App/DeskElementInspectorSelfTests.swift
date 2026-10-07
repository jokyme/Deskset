import Foundation
import DeskLanguage

/// Property pages and planned language edits only: no windows, clipboard, opening or document writes.
enum DeskElementInspectorSelfTests {
    private enum Failure: Error { case fixture, number, operation }

    static func run(_ t: AppTestRunner) {
        literalTests(t)
        insertionTests(t)
        readOnlyTests(t)
        referenceTests(t)
    }

    private static let file = DeskFileID(path: "Inspector.desk")

    private static func service(_ text: String) -> DeskLanguageService {
        DeskLanguageService(openFile: file, files: [file: text])
    }

    private static func inspector(_ snapshot: DeskSnapshot, component: String = "Rectangle") throws -> DeskElementInspector {
        guard let hit = snapshot.elements().first(where: { $0.component == component }),
              let inspector = DeskElementInspector(snapshot: snapshot, element: hit.element) else { throw Failure.fixture }
        return inspector
    }

    private static func number(_ inspector: DeskElementInspector) throws -> StudioPage.Number {
        guard case .row(let row)? = inspector.page.item("desk.corners")?.kind,
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
                t.equal(i.page.controlCount, 1)
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
                t.equal(i.page.controlCount, 0, body)
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
            t.equal(circle.page.controlCount, 0)
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
                .deskInspectorDiskChanged, .deskInspectorSourceUnavailable, .deskInspectorEditRejected]
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
}
