import Foundation
@testable import DeskLanguage

/// Applies the first fix-it that edits (skipping "Jump to line") of the first diagnostic with `id`; returns the new tree.
private func fixed(_ tree: SyntaxTree, _ id: String, fixIt index: Int = 0) -> SyntaxTree? {
    guard let d = tree.diagnostics.first(where: { $0.id.rawValue == id }) else { return nil }
    let editing = d.fixIts.filter { !$0.edits.isEmpty }
    guard index < editing.count else { return nil }
    return deskParse(TextEdit.apply(editing[index].edits, to: tree.text))
}

func runDeskRecoveryTests(_ t: TestRunner) {
    t.suite("Desk: recovery — missing and unexpected tokens") {
        // Each case: the text, the syntax diagnostics it gets, and (when its first fix-it is exact) that applying
        // it leaves no syntax error.
        let cases: [(String, [String], Bool)] = [
            ("widget {\n    Text(\"A\"\n}", ["DK2003"], true),
            ("widget {\n    Picker(\"D\", [.a, .b)\n}", ["DK2004"], true),
            ("info { name \"CPU\" }", ["DK2008"], true),
            ("widget {\n    Picker(\"Day\" [.sunday])\n}", ["DK2007"], true),
            ("widget {\n    variable x 0\n}", ["DK2005"], true),
            ("widget {\n    variable = 3\n}", ["DK2005"], false),
            ("widget {\n    Text(\"A\") )\n    Text(\"B\")\n}", ["DK2006"], true),
            ("widget {\n    Spacer\n}", ["DK2009"], true),
            ("widget {\n    Text(\"A\").bold\n}", ["DK2009"], true),
            ("widget CPU {\n    Text(\"A\")\n}", ["DK2022"], true),
            ("widget {\n    if 0 < x < 10 { }\n}", ["DK2025"], true),
            ("widget {\n    if page = 3 { }\n}", ["DK2026"], true),
            ("widget {\n    if cpu.usage > { }\n}", ["DK2027"], false),
            ("widget {\n    Text(a or b and c)\n}", ["DK2033"], true),
            ("widget {\n    if a && b { }\n}", ["DK9001"], true),
            ("widget {\n    if a || b { }\n}", ["DK9002"], true),
            ("widget {\n    Text(!battery.charging)\n}", ["DK9003"], true),
            ("widget {\n    Text(music.title ?? \"–\")\n}", ["DK9004"], true),
            ("widget {\n    Text(music?.title)\n}", ["DK9005"], true),
            ("widget {\n    Text(month.days[0])\n}", ["DK9006"], true),
            ("widget {\n    Text(x ** 2)\n}", ["DK9007"], true),
            ("widget {\n    for i in 0..<32 { }\n}", ["DK9009"], true),
            ("widget {\n    x.onClick { page += 1 }\n}", ["DK7004"], true),
            ("widget {\n    x.onClick { page++ }\n}", ["DK7005"], true),
            ("widget {\n    Toggle(\"A\", $on)\n}", ["DK9106"], true),
            ("widget {\n    x.every(2 s) { }\n}", ["DK1028"], true),
            ("widget {\n    x.padding(18 px)\n}", ["DK1021"], true),
            ("widget {\n    Text(\"CPU)\n}", ["DK1010"], true),
            ("widget {\n    Text(“CPU”)\n}", ["DK1001"], true),
            ("widget {\n    Text(\"A\")。font(.caption)\n}", ["DK1002"], true),
            ("widget {\n    If x { }\n}", ["DK3013"], true),
            ("widget {\n    x = #Color#\n}", ["DK9303"], false),
            ("widget {\n    Row { Icon(\"wifi\") Text(wifi.name) }\n}", ["DK2031"], true),
            ("widget {\n    Text(x => x * 2)\n}", ["DK9012"], false),
            // A `{` that nothing on its line can take is one DK2010, not also a missing separator.
            ("widget {\n    variable x = 5 { }\n}", ["DK2010"], false),
            // One missing piece per interpolation.
            ("widget {\n    Text(\"{,}\")\n}", ["DK2005"], false),
            ("widget {\n    Text(\"{x, decimals}\")\n}", ["DK2005"], false),
        ]
        for (text, ids, exact) in cases {
            let tree = deskParse(text)
            t.equal(deskIDs(tree), ids, text)
            t.equal(deskTreeProblems(tree) + deskDiagnosticProblems(tree), [], text)
            if exact {
                if let after = fixed(tree, ids[0]) {
                    t.equal(deskErrorIDs(after), [], "after the fix-it: \(after.text)")
                } else {
                    t.check(false, "\(text) has no fix-it")
                }
            }
        }
        // DK2003 names the line of the `(`; DK2001 the line of the `{`.
        let paren = deskParse("widget {\n    Text(\"A\",\n        \"B\"\n    Text(\"C\")\n}")
        t.equal(deskIDs(paren), ["DK2003"])
        t.equal(paren.diagnostics[0].arguments["line"], .number(2))
        t.equal(paren.root.allNodes(.callStmt).count, 2, "the next line is its own statement")
    }

    t.suite("Desk: recovery — braces") {
        // A forgotten `}`: indentation finds the block that was left open; the modifier after it stays with the
        // right element.
        let forgotten = """
        widget {
            Column {
                Row {
                    Text("A")
                Text("B")
            }
            .padding(14)
        }
        """
        let tree = deskParse(forgotten)
        t.equal(deskIDs(tree), ["DK2001"])
        t.equal(tree.diagnostics[0].arguments["opener"], .code("Row {"))
        t.equal(tree.diagnostics[0].arguments["line"], .number(3))
        t.equal(tree.diagnostics[0].fixIts.map(\.titleKey), ["jumpToLine", "insert"])
        t.equal(tree.diagnostics[0].fixIts[0].titleArguments["line"], .number(3))
        t.equal(tree.diagnostics[0].fixIts[0].edits, [], "a jump edits nothing")
        let column = tree.root.firstNode(.callStmt)!
        t.equal(column.children.last?.node?.kind, .modifierApp, "`.padding` stays on the Column")
        if let after = fixed(tree, "DK2001") {
            t.equal(deskIDs(after), [])
            t.equal(after.text, """
            widget {
                Column {
                    Row {
                        Text("A")
                    }
                    Text("B")
                }
                .padding(14)
            }
            """)
        }
        // Fix-its write the file's own line breaks.
        let crlf = deskParse("widget {\r\n    Row {\r\n        Text(\"A\") Text(\"B\")\r\n}\r\n")
        t.equal(deskIDs(crlf), ["DK2001", "DK2031"])
        let insertedBrace = crlf.diagnostics[0].fixIts.flatMap(\.edits).map(\.replacement)
        t.equal(insertedBrace, ["\r\n    }"], "the `}` of `Row {`, at its indentation")
        t.equal(crlf.diagnostics[1].fixIts[0].edits.map(\.replacement), ["\r\n        "])
        // A balanced file keeps the structure it was written with, however it is indented.
        let balanced = deskParse("widget {\nRow {\nText(\"A\")\n        }\n    Text(\"B\")\n}")
        t.equal(deskIDs(balanced), [])
        t.equal(balanced.root.firstNode(.block)?.children.compactMap(\.node).count, 2)
        // An extra `}`, indented deeper than the block it seems to close.
        let extra = deskParse("widget {\n    Row {\n        Text(\"A\")\n        }\n    }\n    Text(\"B\")\n}")
        t.equal(deskIDs(extra), ["DK2002"])
        t.equal(extra.location(of: extra.diagnostics[0].range.lowerBound).line, 4)
        if let after = fixed(extra, "DK2002") { t.equal(deskIDs(after), []) }
        // Unindented (pasted) code: the missing `}` goes at the end of its segment, before the next block word.
        let pasted = deskParse("widget {\nRow {\nText(\"A\")\nText(\"B\")\n}\nstyle s { .bold() }\n")
        t.equal(deskIDs(pasted), ["DK2001"])
        t.equal(pasted.diagnostics[0].arguments["opener"], .code("widget {"))
        t.check(pasted.root.children.contains { $0.node?.kind == .styleDecl }, "the style stays a top-level item")
        // A `}` too many at the top level.
        let top = deskParse("widget {\n    Text(\"A\")\n}\n}\n")
        t.equal(deskIDs(top), ["DK2002"])
        // Braces inside strings, interpolations and comments do not count.
        t.equal(deskIDs(deskParse("widget {\n    Text(\"{{ } x\") // }\n    /* { */\n}")), ["DK1013"])
        // 「 」 and ｛ ｝ count as braces.
        t.equal(deskIDs(deskParse("widget 「\n    Text(\"A\")\n」")), ["DK1002", "DK1002"])
        t.equal(deskIDs(deskParse("widget ｛\n    Text(\"A\")\n｝")), ["DK1002", "DK1002"])
    }

    t.suite("Desk: recovery — foreign code") {
        // A pasted SwiftUI view: one DK9105 and nothing else.
        let swiftUI = """
        import SwiftUI

        struct CPUView: View {
            @State private var page = 0
            var body: some View {
                VStack(alignment: .leading) {
                    Text("CPU \\(page)")
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        """
        let swiftTree = deskParse(swiftUI)
        t.equal(deskIDs(swiftTree), ["DK9105"])
        t.equal(deskTreeProblems(swiftTree) + deskDiagnosticProblems(swiftTree), [])
        // A pasted 300-line INI file: its lines merge, and one DK9015 stands for the rest.
        var ini = "[Rainmeter]\nUpdate=1000\nAccurateText=1\n\n[Variables]\nColor=255,255,255\n\n"
        var n = 0
        while ini.split(separator: "\n", omittingEmptySubsequences: false).count < 300 {
            ini += "[MeterCPU\(n)]\nMeter=String\nMeasureName=MeasureCPU\nX=10\nY=\(n * 20)R\nFontColor=#Color#\n"
                + "Text=CPU %1%\nLeftMouseUpAction=[!SetVariable Page 1][\"https://example.com\"]\n; a comment\n\n"
            n += 1
        }
        let iniTree = deskParse(ini)
        t.equal(deskIDs(iniTree), ["DK9302", "DK9015"])
        t.equal(iniTree.diagnostics.filter { $0.id == .foreignFile }.count, 1)
        t.equal(iniTree.location(of: iniTree.diagnostics[1].range.lowerBound).line, 21 + 3,
                "DK9015 at the first foreign line past the twentieth (blank lines do not count)")
        t.equal(deskTreeProblems(iniTree) + deskDiagnosticProblems(iniTree), [])
        // A foreign line that opens a block takes the block along, so its `}` is not left over.
        let function = deskParse("func total() -> Int {\n    let a = 1\n    return a\n}\nwidget {\n    Text(\"A\")\n}")
        t.equal(deskIDs(function), ["DK9012"])
        t.check(function.root.children.contains { $0.node?.kind == .widgetBlock }, "the widget still parses")
        // HTML, CSS, other languages' comments.
        t.equal(deskIDs(deskParse("<div class=\"x\">\n  <span>Hello</span>\n</div>")), ["DK9201"])
        t.equal(deskIDs(deskParse("widget {\n    flex-direction: row;\n    font-size: 13px;\n}")), ["DK9202"])
        t.equal(deskIDs(deskParse("#clock {\n    color: red;\n}")), ["DK9203"])
        let comments = deskParse("# note\nwidget {\n; old\n    Text(\"A\")\n}")
        t.equal(deskIDs(comments), ["DK9014", "DK9013"])
        t.check(comments.diagnostics.allSatisfy { $0.severity == .warning }, "comments still work: warnings")
        t.equal(TextEdit.apply(comments.diagnostics[0].fixIts[0].edits, to: comments.text).hasPrefix("// note"), true)
        // Swift declarations and property wrappers with their Desk form.
        let declarations = deskParse("widget {\n    let x = 1\n    var y: Int = 0\n    Text(\"A\")\n}")
        t.equal(deskIDs(declarations), ["DK9104"])
        var repaired = declarations.text
        for fixIt in declarations.diagnostics[0].fixIts.reversed() { repaired = TextEdit.apply(fixIt.edits, to: repaired) }
        t.equal(repaired, "widget {\n    computed x = 1\n    variable y = 0\n    Text(\"A\")\n}")
        t.equal(declarations.diagnostics[0].fixIts.map(\.group).compactMap { $0 }.count, 2, "one Fix-all group")
        let state = deskParse("widget {\n    @State var page = 0\n    Text(\"A\")\n}")
        t.equal(deskIDs(state), ["DK9103"])
        t.equal(fixed(state, "DK9103")?.text, "widget {\n    variable page = 0\n    Text(\"A\")\n}")
        // `if let` and closure parameters.
        let ifLet = deskParse("widget {\n    if let t = music.title { Text(t) }\n}")
        t.equal(deskIDs(ifLet), ["DK9110"])
        t.equal(fixed(ifLet, "DK9110")?.text, "widget {\n    if not music.title.isMissing { Text(music.title) }\n}")
        let closure = deskParse("widget {\n    Text(\"x\").onChange(of: music.title) { newValue in log(newValue) }\n}")
        t.equal(deskIDs(closure), ["DK9111"])
        t.equal(fixed(closure, "DK9111")?.text, "widget {\n    Text(\"x\").onChange(of: music.title) { log(music.title) }\n}")
        t.equal(closure.diagnostics.first?.fixIts.first?.titleArguments,
                ["name": .code("newValue"), "value": .code("music.title")], "the title names both")
        // Words from other languages are ordinary names outside those patterns (D72).
        t.equal(deskIDs(deskParse("widget {\n    variable state = 0\n    state = state + 1\n    let = 3\n}")), [])
        // An INI line that parses as Desk stays Desk (the checker reports it); in a run it joins.
        t.equal(deskIDs(deskParse("widget {\n    FontColor = 255\n}")), [])
        t.equal(deskIDs(deskParse("widget {\n    FontColor=255,255,255\n}")), ["DK9301"])
        // Options: a capitalised option with a Desk control is Desk (DK3016 by the checker), not Rainmeter.
        t.equal(deskIDs(deskParse("options {\n    FontColor = ColorPicker(\"Text color\")\n}")), [])
    }

    t.suite("Desk: recovery — isolation and depth") {
        // One error never loses the rest of the file.
        let text = """
        widget {
            Text("A" )) ]
            Row { Text("B") }
            Text("C").font(.caption)
        }
        style s { .bold() }
        """
        let tree = deskParse(text)
        t.equal(deskIDs(tree), ["DK2006"])
        t.equal(tree.root.allNodes(.callStmt).count, 4)
        t.check(tree.root.children.contains { $0.node?.kind == .styleDecl })
        // Appendix B.4: the syntax-level part of its diagnostics (the rest are the checker's).
        let b4 = """
        widget {
            VStack {                                   // DK9101: SwiftUI; write Column { … }
                Text(“CPU”).colour(.red)
                Text("{cpuu.usage}%")
                Progress(cpu.usage).color(.red).color(.blue)
                if cpu.usage > 80 && not battery.charging {
                    Text("Hot").padding("18px")
                }
            .padding(14)
        }
        """
        let b4Tree = deskParse(b4)
        t.equal(deskIDs(b4Tree), ["DK2001", "DK1001", "DK9001"])
        t.equal(b4Tree.diagnostics[0].arguments["opener"], .code("VStack {"))
        t.equal(b4Tree.diagnostics[0].arguments["line"], .number(2))
        // Depth limits: one DK2028 each, no crash, the text still round-trips.
        let blocks = "widget {\n" + String(repeating: "Row {\n", count: 80) + "Text(\"deep\")\n"
            + String(repeating: "}\n", count: 80) + "}\n"
        let deepBlocks = deskParse(blocks)
        t.equal(deskIDs(deepBlocks), ["DK2028"])
        t.equal(deskTreeProblems(deepBlocks) + deskDiagnosticProblems(deepBlocks), [])
        let parens = "widget {\n    Text(" + String(repeating: "(", count: 300) + "1" + String(repeating: ")", count: 300) + ")\n}\n"
        let deepParens = deskParse(parens)
        t.equal(deskIDs(deepParens), ["DK2028"])
        t.equal(deskTreeProblems(deepParens) + deskDiagnosticProblems(deepParens), [])
        let prefixes = deskParse("widget {\n    computed x = " + String(repeating: "- ", count: 5000) + "1\n}\n")
        t.equal(deskIDs(prefixes), ["DK2028"])
        t.equal(deskTreeProblems(prefixes) + deskDiagnosticProblems(prefixes), [])
        let elses = "widget {\n    if a { }" + String(repeating: " else if a { }", count: 2000) + "\n    Text(\"after\")\n}\n"
        let deepElses = deskParse(elses)
        t.equal(deskIDs(deepElses), ["DK2028"])
        t.equal(deskTreeProblems(deepElses) + deskDiagnosticProblems(deepElses), [])
        t.equal(deepElses.root.allNodes(.callStmt).count, 1, "the statement after the chain survives")
        let ternaries = deskParse("widget {\n    computed x = " + String(repeating: "a ? b : ", count: 400) + "c\n}\n")
        t.equal(deskIDs(ternaries), ["DK2028"])
        let strings = deskParse("widget {\n    Text(" + String(repeating: "\"{", count: 60) + "x" + String(repeating: "}\"", count: 60) + ")\n}\n")
        t.equal(deskTreeProblems(strings) + deskDiagnosticProblems(strings), [])
        // Diagnostics are sorted by position and the same on every parse.
        let noisy = deskParse("widget {\n    Text(“A”)。bold\n    x = a && b ||| c\n    #Name# ; ;\n}")
        let offsets = noisy.diagnostics.map(\.range.lowerBound)
        t.equal(offsets, offsets.sorted())
        t.equal(deskParse(noisy.text).diagnostics, noisy.diagnostics)
    }
}
