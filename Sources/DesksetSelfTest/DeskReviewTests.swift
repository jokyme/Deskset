import Foundation
@testable import DeskLanguage

// Regression tests for the findings of the checker and editing API review: one or more cases per finding, each
// naming what it guards. Robustness first (crashes, stack depth, corrupting edits), then conformance and novice
// findings, each with the spec's expected diagnostic and, where there is one, the fix-it applied and re-checked.

/// Runs `body` on a thread with the default secondary-thread stack (512 KiB), as a GCD worker would.
func deskOnSmallStack<T>(_ body: @escaping () -> T) -> T {
    var result: T?
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        result = body()
        done.signal()
    }
    thread.stackSize = 512 << 10
    thread.start()
    done.wait()
    return result!
}

/// The diagnostics of `text` as `id` strings, with `info { name: "T" }` put in front when `named`.
func deskReviewIDs(_ text: String, named: Bool = true, file: String = "Test.desk") -> [String] {
    deskCheck((named ? "info { name: \"T\" }\n" : "") + text, file: file).diagnostics.map(\.id.rawValue)
}

/// The file after applying the fix-it titled `title` (or the first one) of the first diagnostic with `id`.
func deskApplyFix(_ checked: CheckedFile, _ id: String, title: String? = nil) -> String? {
    guard let d = checked.diagnostics.first(where: { $0.id.rawValue == id }) else { return nil }
    let found: FixIt?
    if let title { found = d.fixIts.first { $0.title(in: .english).contains(title) } } else { found = d.fixIts.first }
    guard let f = found else { return nil }
    return TextEdit.apply(f.edits.filter { $0.file == checked.tree.file }, to: checked.tree.text)
}


/// The first statement (document order) whose trimmed text starts with `prefix`.
func deskReviewStatement(_ tree: SyntaxTree, _ prefix: String) -> PositionedNode? {
    var stack: [PositionedNode] = [tree.rootNode]
    while let node = stack.popLast() {
        if node.kind.isStatement, node.node.trimmedText.hasPrefix(prefix) { return node }
        stack.append(contentsOf: node.childNodes.reversed())
    }
    return nil
}

/// The `n`-th block of a statement found by prefix.
func deskReviewBlock(_ tree: SyntaxTree, _ prefix: String) -> PositionedNode? {
    deskReviewStatement(tree, prefix)?.childNodes.first { $0.kind == .block }
}

/// The syntax errors of a tree.
func deskReviewSyntaxErrors(_ tree: SyntaxTree) -> [String] {
    tree.diagnostics.filter { $0.severity == .error }.map(\.id.rawValue)
}

func runDeskReviewTests(_ t: TestRunner) {
    t.suite("Desk: review — robustness of the checker") {
        // A `for` over a range far outside Int's range (finding 38).
        for source in ["1...99999999999999999999", "99999999999999999999...1", "0..<9223372036854775807", "-99999999999999999999...99999999999999999999"] {
            let ids = deskReviewIDs("widget {\n    Column {\n        for i in \(source) {\n            Text(\"x\")\n        }\n    }\n}")
            t.check(!ids.contains("DK0000"), "for \(source): \(ids)")
        }
        // A huge plain time (finding 39) and the readings below a second and at one (finding 67).
        let huge = deskCheck("info { name: \"T\" }\nwidget {\n    Text(\"x\").every(1000000000000000000000000) { }\n}")
        t.check(huge.diagnostics.contains { $0.id.rawValue == "DK4011" }, deskDescribe(huge))
        t.equal(Checker.durationText(0.0005).en, "is 0.5 milliseconds")
        t.equal(Checker.durationText(0.001).en, "is 1 millisecond")
        t.equal(Checker.durationText(1).en, "is 1 second")
        t.equal(Checker.durationText(500).en, "is about 8 minutes")
        t.equal(Checker.durationText(500).zh, "大约是 8 分钟")
        t.equal(Checker.durationText(1000).zh, "大约是 17 分钟")
        t.equal(Checker.durationText(.infinity).en, "is a very long time")
        let half = deskCheck("info { name: \"T\" }\nwidget {\n    Text(\"x\").every(0.5) { }\n}")
        t.equal(half.diagnostics.first?.message(in: .english), "`0.5` needs a unit here: `0.5ms` is 0.5 milliseconds, `0.5s` is 500 milliseconds.")
        let one = deskCheck("info { name: \"T\" }\nwidget {\n    Text(\"x\").every(1) { }\n}")
        t.equal(one.diagnostics.first?.message(in: .english), "`1` needs a unit here: `1ms` is 1 millisecond, `1s` is 1 second.")
        let fiveHundred = deskCheck("info { name: \"T\" }\nwidget {\n    Text(\"x\").every(500) { }\n}")
        t.equal(fiveHundred.diagnostics.first?.message(in: .simplifiedChinese), "`500` 这里要写单位：`500ms` 是 500 毫秒，`500s` 大约是 8 分钟。")
        // Nested `for` loops whose product overflows Int (finding 40).
        var seven = "Text(\"x\")"
        for n in 1...7 { seven = "for i\(n) in 1...1000 {\n\(seven)\n}" }
        t.check(deskReviewIDs("widget {\n Column {\n\(seven)\n}\n}").contains("DK8501"), "seven nested loops: DK8501")
        var six = String(repeating: "Text(\"x\")\n", count: 10)
        for n in 1...6 { six = "for i\(n) in 1...1000 {\n\(six)}" }
        t.check(deskReviewIDs("widget {\n Column {\n\(six)\n}\n}").contains("DK8501"), "six nested loops: DK8501")
    }

    t.suite("Desk: review — robustness of the parser") {
        // An opaque `script {` running to the end of the file after a stray token (finding 41).
        for text in ["1 script {\n", ". script {\n", "/script{\n\n", "widget { Text(\"a\") }\n) script {\n", "1 script {\r\n"] {
            let tree = Desk.parse(text, fileName: "F.desk")
            t.equal(tree.text, text, "round trip of \(text.debugDescription)")
        }
        // An index literal of Int.max: the fix-it cannot add one (finding 42).
        let index = deskCheck("info { name: \"T\" }\nwidget {\n    computed l = [1, 2]\n    computed y = l[9223372036854775807]\n    Text(\"{y}\")\n}")
        t.check(index.diagnostics.contains { $0.id.rawValue == "DK9006" && $0.message(in: .english).contains("9223372036854775807 + 1") },
                deskDescribe(index))
    }

    t.suite("Desk: review — long chains on a small stack") {
        // Long left-nested chains are cut at the nesting limit (DK2028) and checked and formatted on any thread
        // (finding 43).
        let chains: [(String, String)] = [
            ("sum", "computed x = " + Array(repeating: "1", count: 5_000).joined(separator: " + ")),
            ("and", "computed x = " + Array(repeating: "true", count: 5_000).joined(separator: " and ")),
            ("members", "computed x = cpu" + String(repeating: ".usage", count: 5_000)),
            ("calls", "computed x = f" + String(repeating: "()", count: 5_000)),
            ("products", "computed x = " + Array(repeating: "2", count: 5_000).joined(separator: " * ")),
        ]
        for (name, line) in chains {
            let text = "info { name: \"T\" }\nwidget {\n    \(line)\n    Text(\"{x}\")\n}\n"
            let (ids, formatted) = deskOnSmallStack { () -> ([String], String) in
                let tree = Desk.parse(text, fileName: "F.desk")
                return (Desk.check(tree).diagnostics.map(\.id.rawValue), Desk.formatted(tree))
            }
            t.check(ids.contains("DK2028"), "\(name): \(ids.prefix(5))")
            t.check(!formatted.isEmpty, "\(name): formatted")
        }
        // Chains under the limit are unchanged.
        let short = "computed x = " + Array(repeating: "1", count: 100).joined(separator: " + ")
        t.equal(deskReviewIDs("widget {\n    \(short)\n    Text(\"{x}\")\n}"), [])
        // A long `else if` chain nests the tree too.
        let elses = "widget {\n    variable a = 0\n    Column {\n        " + Array(repeating: "if a == 1 { Text(\"x\") }", count: 3_000).joined(separator: " else ") + "\n    }\n}"
        let elseIDs = deskOnSmallStack { deskReviewIDs(elses) }
        t.check(!elseIDs.contains("DK0000"), "else chain")
    }

    t.suite("Desk: review — editing API") {
        // A multi-line block comment after a statement (finding 44).
        let spanning = "widget {\n    Column {\n        Text(\"a\") /* spans\n        lines */ Text(\"b\")\n    }\n    Row {\n    }\n}\n"
        let tree = deskParse(spanning)
        let a = deskReviewStatement(tree, "Text(\"a\")")!
        let row = deskReviewBlock(tree, "Row")!
        let moved = Desk.apply(.moveStatement(tree.id(of: a), to: tree.id(of: row), index: 0), to: tree)
        t.equal(deskReviewSyntaxErrors(moved.tree), [], moved.tree.text)
        t.check(moved.tree.text.contains("/* spans\n        lines */ Text(\"b\")"), moved.tree.text)
        let removed = Desk.apply(.removeStatement(tree.id(of: a)), to: tree)
        t.equal(deskReviewSyntaxErrors(removed.tree), [], removed.tree.text)
        t.check(removed.tree.text.contains("lines */ Text(\"b\")") && !removed.tree.text.contains("Text(\"a\")"), removed.tree.text)
        let tail = deskParse("widget {\n    Column {\n        Text(\"a\")\n        Text(\"b\") /* tail\n         b */\n        Text(\"c\")\n    }\n}\n")
        let wrapped = Desk.apply(.wrap([tail.id(of: deskReviewStatement(tail, "Text(\"a\")")!), tail.id(of: deskReviewStatement(tail, "Text(\"b\")")!)],
                                       container: "Row"), to: tail)
        t.equal(deskReviewSyntaxErrors(wrapped.tree), [], wrapped.tree.text)
        t.check(wrapped.tree.text.contains("b */\n        }\n        Text(\"c\")"), wrapped.tree.text)

        // A trailing `/* … */` before `;` (finding 45).
        let semicolon = deskParse("widget {\n    Column {\n        Text(\"a\") /* x */ ; Text(\"b\")\n    }\n    Row {\n    }\n}\n")
        let first = deskReviewStatement(semicolon, "Text(\"a\")")!
        let removedFirst = Desk.apply(.removeStatement(semicolon.id(of: first)), to: semicolon)
        t.check(removedFirst.tree.text.contains("Text(\"b\")") && !removedFirst.tree.text.contains("Text(\"a\")"), removedFirst.tree.text)
        let movedFirst = Desk.apply(.moveStatement(semicolon.id(of: first), to: semicolon.id(of: deskReviewBlock(semicolon, "Row")!), index: 0), to: semicolon)
        t.check(movedFirst.tree.text.contains("Column {\n        Text(\"b\")") && movedFirst.tree.text.contains("Row {\n        Text(\"a\")\n    }"),
                movedFirst.tree.text)
        let pair = deskParse("widget {\n    Row {\n        Text(\"a\") /* x */ ; Text(\"b\")\n    }\n}\n")
        let unwrappedPair = Desk.apply(.unwrap(pair.id(of: deskReviewStatement(pair, "Row")!)), to: pair)
        t.equal(unwrappedPair.tree.text.components(separatedBy: "Text(\"b\")").count, 2, unwrappedPair.tree.text)

        // unwrap keeps the container's comments (finding 49).
        let commented = deskParse("""
        widget {
            Column {
                Row { // the pair
                    Text("a")
                    // before b
                    Text("b")
                    /* x
                     */ Text("c")
                    // last words
                } // after row
            }
        }

        """)
        let unwrapped = Desk.apply(.unwrap(commented.id(of: deskReviewStatement(commented, "Row")!)), to: commented)
        t.equal(unwrapped.tree.text, """
        widget {
            Column {
                // the pair
                Text("a")
                // before b
                Text("b")
                /* x
                 */ Text("c")
                // last words
                // after row
            }
        }

        """)
        t.equal(unwrapped.moves.count, 3)
        for move in unwrapped.moves {
            let text = String(decoding: Array(unwrapped.tree.text.utf8)[move.to], as: UTF8.self)
            t.check(text.hasPrefix("Text("), text)
        }

        // rename refuses names that clash or that the checker rejects (finding 50).
        let source = "info { name: \"T\" }\nwidget {\n    variable page = 0\n    variable other = 1\n    Text(\"{page}\").onClick { page = page + other }\n}"
        let file = deskCheck(source)
        let page = file.symbols.values.compactMap { symbol -> NodeID? in
            if case .declaration(let id) = symbol, file.tree.resolve(id).map({ DeclarationSyntax(unchecked: $0).name.token.text }) == "page" { return id }
            return nil
        }.first!
        for name in ["other", "widget", "info", "options", "style", "script", "component", String(repeating: "a", count: 201), "cpu"] {
            let result = Desk.apply(.rename(page, to: name), to: file)
            if name == "cpu" {
                t.equal(result.failure, nil, "cpu is not used in the file")
            } else {
                t.check(result.failure != nil, "rename to \(name.prefix(20)) is refused")
            }
        }
        let usesCPU = deskCheck("info { name: \"T\" }\nwidget {\n    variable page = 0\n    Text(\"{page} {cpu.usage}\")\n}")
        let page2 = usesCPU.symbols.values.compactMap { symbol -> NodeID? in
            if case .declaration(let id) = symbol { return id }
            return nil
        }.first!
        t.check(Desk.apply(.rename(page2, to: "cpu"), to: usesCPU).failure != nil, "renaming to a built-in the file reads")

        // sortBlocks in a CRLF file, with the first block's comment (finding 51).
        let crlf = "// the widget\r\nwidget {\r\n    Text(\"a\")\r\n}\r\n\r\n// info\r\ninfo { name: \"X\" }\r\n"
        t.equal(TextEdit.apply(Desk.sortBlocks(deskParse(crlf)), to: crlf),
                "// info\r\ninfo { name: \"X\" }\r\n\r\n// the widget\r\nwidget {\r\n    Text(\"a\")\r\n}\r\n")
        let lf = "// the widget\nwidget {\n    Text(\"a\")\n}\n\n// info\ninfo { name: \"X\" }\n"
        t.equal(TextEdit.apply(Desk.sortBlocks(deskParse(lf)), to: lf),
                "// info\ninfo { name: \"X\" }\n\n// the widget\nwidget {\n    Text(\"a\")\n}\n")

        // offsetText past 1e15 stays a number (finding 54).
        let big = deskParse("widget {\n    Text(\"a\").padding(999999999999999pt)\n}\n")
        var argument: PositionedNode?
        var stack = [big.rootNode]
        while let node = stack.popLast() {
            if node.kind == .argument { argument = node; break }
            stack += node.childNodes
        }
        let offset = Desk.offsetText(of: ArgumentSyntax(unchecked: argument!).value, by: 8)
        t.equal(offset, "1000000000000007pt")
        t.equal(OffsetText.number(1e20 + 0.5, unit: ""), "100000000000000000000")

        // setArgument, setField and setModifier refuse text that is not what it stands for (finding 55).
        let frame = deskCheck("info { name: \"T\" }\nwidget {\n    Text(\"a\").frame(width: 10, height: 5)\n}\n")
        var width: PositionedNode?
        stack = [frame.tree.rootNode]
        while let node = stack.popLast() {
            if node.kind == .argument, ArgumentSyntax(unchecked: node).label?.name == "width" { width = node; break }
            stack += node.childNodes
        }
        let widthID = frame.tree.id(of: width!)
        for bad in ["1) } widget { Text(\"evil\"", "", "a: 5", "1, 2"] {
            t.check(Desk.apply(.setArgument(widthID, newText: bad), to: frame.tree).failure != nil, "setArgument \(bad.debugDescription)")
        }
        t.equal(Desk.apply(.setArgument(widthID, newText: "cpu.usage * 2"), to: frame.tree).failure, nil)
        let element = frame.elements.first { $0.value.component == "Text" }!.key
        t.check(Desk.apply(.setModifier(element, name: "color", argumentsText: ".red", condition: "cpu.usage > 80) }\nText(\"x\""), to: frame).failure != nil)
        t.check(Desk.apply(.setModifier(element, name: "color", argumentsText: ".red) }", condition: nil), to: frame).failure != nil)
        t.equal(Desk.apply(.setModifier(element, name: "color", argumentsText: ".red", condition: "cpu.usage > 80"), to: frame).failure, nil)
        let info = deskParse("info { name: \"T\" }\nwidget { Text(\"a\") }\n")
        var field: PositionedNode?
        stack = [info.rootNode]
        while let node = stack.popLast() {
            if node.kind == .field { field = node; break }
            stack += node.childNodes
        }
        t.check(Desk.apply(.setField(info.id(of: field!), newText: "\"X\" }\nwidget {"), to: info).failure != nil)
        t.equal(Desk.apply(.setField(info.id(of: field!), newText: "\"X\""), to: info).tree.text, "info { name: \"X\" }\nwidget { Text(\"a\") }\n")

        // insertStatement keeps a tab-indented block's tabs (finding 56).
        let tabs = deskParse("widget {\n\tColumn {\n\t\tText(\"a\")\n\t}\n}\n")
        let inserted = Desk.apply(.insertStatement(tabs.id(of: deskReviewBlock(tabs, "Column")!), index: 1, text: "Text(\"x\")"), to: tabs)
        t.equal(inserted.tree.text, "widget {\n\tColumn {\n\t\tText(\"a\")\n\t\tText(\"x\")\n\t}\n}\n")
    }

    t.suite("Desk: review — formatter on many blank lines") {
        // Blank lines after `{` are dropped in linear time (finding 52).
        let text = "widget {" + String(repeating: "\n", count: 200_000) + "    Text(\"b\")\n}\n"
        let start = ProcessInfo.processInfo.systemUptime
        let formatted = Desk.formatted(deskParse(text))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        t.equal(formatted, "widget {\n    Text(\"b\")\n}\n")
        t.check(elapsed < 5, "formatting 200,000 blank lines took \(elapsed) s")
        print(String(format: "    formatter: 200,000 blank lines after `{` in %.0f ms", elapsed * 1000))
    }

    t.suite("Desk: review — stray top-level statements (DK2034)") {
        // Wrapping keeps styles, info blocks and comments between the strays (finding 46).
        let scattered = deskCheck("Text(\"a\").style(s)\n\n// Styles\nstyle s { .bold() }\n\ninfo { name: \"Demo\" }\n\n// the second label\nText(\"b\")\n")
        let wrapped = deskApplyFix(scattered, "DK2034")
        t.equal(wrapped, "widget {\n    Text(\"a\").style(s)\n    // the second label\n    Text(\"b\")\n}\n\n// Styles\nstyle s { .bold() }\n\ninfo { name: \"Demo\" }\n")
        t.equal(wrapped.map { deskCheck($0).diagnostics.map(\.id.rawValue) }, ["DK2021"], "two roots, nothing else")
        // Moving in keeps comments, starts a line of its own, and is not offered without the widget's `}` (48).
        let comment = deskCheck("info { name: \"T\" }\nwidget {\n    Text(\"a\")\n}\n\n// explain b\nText(\"b\") // tail\n")
        t.equal(deskApplyFix(comment, "DK2034"), "info { name: \"T\" }\nwidget {\n    Text(\"a\")\n    // explain b\n    Text(\"b\") // tail\n}\n")
        let oneLine = deskCheck("info { name: \"T\" }\nwidget { Text(\"a\") }\nText(\"b\")\n")
        let movedIn = deskApplyFix(oneLine, "DK2034")
        t.equal(movedIn, "info { name: \"T\" }\nwidget {\n    Text(\"a\")\n    Text(\"b\")\n}\n")
        t.equal(movedIn.map { deskCheck($0).diagnostics.map(\.id.rawValue) }, ["DK2021"], "two roots, nothing else")
        let declaration = deskCheck("info { name: \"T\" }\nvariable page = 0\nwidget {\n    Text(\"{page}\")\n}\n")
        t.equal(deskApplyFix(declaration, "DK2034"), "info { name: \"T\" }\nwidget {\n    variable page = 0\n    Text(\"{page}\")\n}\n")
        let unclosed = deskCheck("info { name: \"T\" }\nwidget {\n    Text(\"a\")\nText(\"b\")\n")
        t.check(unclosed.diagnostics.first { $0.id.rawValue == "DK2034" }?.fixIts.isEmpty ?? true, deskDescribe(unclosed))
        // A block word with parentheses at the top level is not an element to move in, nor a block to move out (57).
        t.equal(deskReviewIDs("widget {\n    Text(\"a\")\n}\ninfo ({ name: \"T\" }\n", named: false), ["DK8003", "DK2003"])
        // Many strays: the fix-it is built once (finding 47).
        let many = String(repeating: "Text(\"CPU\").font(.caption)\n", count: 2_000)
        let start = ProcessInfo.processInfo.systemUptime
        let checked = deskCheck("info { name: \"T\" }\n" + many)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        t.equal(checked.diagnostics.filter { $0.id.rawValue == "DK2034" }.count, 500)
        t.check(elapsed < 3, "2,000 stray lines took \(elapsed) s")
        print(String(format: "    2,000 stray top-level lines: parse + check %.0f ms", elapsed * 1000))
    }

    t.suite("Desk: review — cycles") {
        // Printed as the cycle (finding 28).
        let computed = deskCheck("info { name: \"T\" }\nwidget {\n    computed a = b + 1\n    computed b = a\n    Text(\"{a}\")\n}")
        t.equal(computed.diagnostics.first { $0.id.rawValue == "DK4040" }?.message(in: .english),
                "These values depend on each other: `a` → `b` → `a`.")
        let styles = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").style(a) }\nstyle a { .style(b) }\nstyle b { .style(a) }")
        t.equal(styles.diagnostics.first { $0.id.rawValue == "DK5006" }?.message(in: .english),
                "These styles use each other: `a` → `b` → `a`.")
        let freeform = deskCheck("info { name: \"T\" }\nwidget {\n    Freeform {\n        Text(\"A\").name(a).position(x: b.right, y: 0)\n        Text(\"B\").name(b).position(x: a.right, y: 0)\n    }\n}")
        t.equal(freeform.diagnostics.first { $0.id.rawValue == "DK6004" }?.message(in: .simplifiedChinese),
                "这些位置互相依赖：`a` → `b` → `a`。")
        // Long chains are linear and need no deep recursion (finding 53).
        let n = 4_000
        let chain = "info { name: \"T\" }\nwidget {\n    computed v0 = 1\n" + (1..<n).map { "    computed v\($0) = v\($0 - 1) + 1" }.joined(separator: "\n")
            + "\n    Text(\"{v\(n - 1)}\")\n}\n"
        var start = ProcessInfo.processInfo.systemUptime
        let chainIDs = deskOnSmallStack { deskCheck(chain).diagnostics.map(\.id.rawValue) }
        let chainTime = ProcessInfo.processInfo.systemUptime - start
        t.equal(chainIDs, [])
        var positions = "info { name: \"T\" }\nwidget {\n    Freeform {\n        Text(\"0\").name(t0).position(x: 0, y: 0)\n"
        for i in 1..<n { positions += "        Text(\"\(i)\").name(t\(i)).position(x: t\(i - 1).right + 4, y: 0)\n" }
        positions += "    }\n}\n"
        start = ProcessInfo.processInfo.systemUptime
        let positionIDs = deskOnSmallStack { deskCheck(positions).diagnostics.map(\.id.rawValue) }
        let positionTime = ProcessInfo.processInfo.systemUptime - start
        t.check(!positionIDs.contains("DK6004"), "\(Set(positionIDs))")
        print(String(format: "    %d chained computed values: %.0f ms; %d chained Freeform positions: %.0f ms", n, chainTime * 1000, n, positionTime * 1000))
        t.check(chainTime < 5 && positionTime < 5, "chains took \(chainTime) s and \(positionTime) s")
        // The cycle helper: one cycle per component, starting where asked.
        t.equal(Checker.cycles(in: ["a": ["b"], "b": ["c"], "c": ["b"], "d": ["d"]], order: ["a", "b", "c", "d"]), [["b", "c"], ["d"]])
        t.equal(Checker.cycles(in: ["a": ["b"], "b": ["a"]], order: ["a", "b"], startingAt: { $0 == "b" }), [["b", "a"]])
    }

    t.suite("Desk: review — foreign code: ForEach, closure parameters, Swift declarations") {
        // ForEach is rewritten to `for`, its parameter is the loop variable, and no message is empty (finding 61).
        let forEach = deskCheck("info { name: \"T\" }\nwidget {\n    ForEach(cpu.cores) { core in\n        Progress(core.usage)\n    }\n}")
        t.equal(forEach.diagnostics.map(\.id.rawValue), ["DK9101"])
        t.equal(forEach.diagnostics.first?.message(in: .english), "This is SwiftUI; in Desk write `for core in cpu.cores { … }`.")
        let rewritten = deskApplyFix(forEach, "DK9101")
        t.equal(rewritten, "info { name: \"T\" }\nwidget {\n    for core in cpu.cores {\n        Progress(core.usage)\n    }\n}")
        t.equal(rewritten.map { deskCheck($0).diagnostics.map(\.id.rawValue) }, [])
        let parameter = deskCheck("info { name: \"T\" }\nwidget {\n    Column {\n        name in month.weekdays {\n            Text(\"a\")\n        }\n    }\n}")
        let closure = parameter.diagnostics.first { $0.id.rawValue == "DK9111" }
        t.equal(closure?.message(in: .english), "Desk blocks take no parameters; remove `name in`.")
        t.equal(closure?.message(in: .simplifiedChinese), "Desk 的花括号里不写参数；去掉 `name in`。")
        let onChange = deskCheck("info { name: \"T\" }\nwidget {\n    variable x = 0\n    Text(\"{x}\").onChange(of: x) { newValue in log(\"{newValue}\") }\n}")
        t.equal(onChange.diagnostics.first { $0.id.rawValue == "DK9111" }?.message(in: .english),
                "Desk blocks take no parameters; use the value itself, `x`, inside the block.")
        // `var` found by the foreign table (not the parser's line match) names the word it replaces.
        let declaration = deskCheck("info { name: \"T\" }\nwidget {\n    var(able x = 0\n    Text(\"a\")\n}")
        t.equal(declaration.diagnostics.first { $0.id.rawValue == "DK9104" }?.message(in: .english), "`var` is not Desk; write `variable`.")
        for d in forEach.diagnostics + parameter.diagnostics + onChange.diagnostics + declaration.diagnostics {
            t.check(!d.message(in: .english).isEmpty && !d.message(in: .simplifiedChinese).isEmpty, "\(d.id.rawValue) has a message")
        }
    }

    t.suite("Desk: review — modifiers in action blocks and options (findings 1, 9, 31, 33, 64)") {
        func ids(_ code: String) -> [String] { deskReviewIDs(code) }
        // Modifiers on action calls, after a `for` in actions, on a Section (finding 1).
        t.equal(ids("widget { Text(\"A\").onClick { open(\"x\").color(.red) } }"), ["DK7016"])
        t.equal(ids("widget { Text(\"A\").onClick { open(\"x\").foo(1) } }"), ["DK3001"])
        t.equal(deskCheck("info { name: \"T\", permissions: [.music] }\nwidget { Text(\"A\").onClick { music.next().bold() } }").diagnostics.map(\.id.rawValue), ["DK7016"])
        t.equal(ids("widget { Text(\"A\").onClick { after(1s) { }.padding(3) } }"), ["DK7016"])
        t.equal(ids("widget { Text(\"A\").onClick {\n for n in [\"a\"] { hide(n) }\n .bold()\n} }"), ["DK2032"])
        t.equal(ids("options { Section(\"S\") { a = Toggle(\"A\") }.foo(1) }\nwidget { Text(\"{options.a}\") }"), ["DK3001"])
        t.equal(ids("options { Section(\"S\") { a = Toggle(\"A\") }.bold() }\nwidget { Text(\"{options.a}\") }"), ["DK5003"])
        let attached = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").onClick { open(\"x\").color(.red) } }")
        let attachedFix = deskApplyFix(attached, "DK7016")
        t.equal(attachedFix, "info { name: \"T\" }\nwidget {\n    variable alert = false\n    Text(\"A\").onClick { open(\"x\"); alert = true }.color(.red, if: alert) }")
        t.equal(attachedFix.map { deskCheck($0).diagnostics.map(\.id.rawValue) }, [])
        // A modifier on the line after an assignment whose value is not a bare name (finding 9).
        let sum = deskCheck("info { name: \"T\" }\nwidget {\n    variable page = 0\n    Text(\"{page}\").onClick {\n        page = page + 1\n        .color(.red)\n    }\n}")
        t.equal(sum.diagnostics.map(\.id.rawValue), ["DK7016"])
        let sumFix = deskApplyFix(sum, "DK7016")
        t.equal(sumFix, "info { name: \"T\" }\nwidget {\n    variable alert = false\n    variable page = 0\n    Text(\"{page}\").onClick {\n        page = page + 1\n        alert = true\n    }.color(.red, if: alert)\n}")
        t.equal(sumFix.map { deskCheck($0).diagnostics.map(\.id.rawValue) }, [])
        t.equal(ids("widget {\n    variable page = 0\n    Text(\"{page}\").onClick {\n        page = 1\n        .color(.red)\n    }\n}"), ["DK7016"])
        // DK2032 wraps only among elements, at the construct's indentation (finding 31).
        let inAction = deskCheck("info { name: \"T\" }\nwidget {\n    variable a = false\n    Text(\"A\").onClick {\n        if a { a = false }\n        .color(.red)\n    }\n}")
        t.equal(inAction.diagnostics.map(\.id.rawValue), ["DK2032"])
        t.equal(inAction.diagnostics.first?.fixIts.count, 0)
        let inMenu = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").menu { if true { Item(\"X\").onClick { } }.bold() } }")
        t.equal(inMenu.diagnostics.first { $0.id.rawValue == "DK2032" }?.fixIts.count, 0)
        let inViews = deskCheck("info { name: \"T\" }\nwidget {\n    variable a = false\n    Column {\n        if a {\n            Text(\"x\")\n        }\n        .bold()\n    }\n}")
        t.equal(deskApplyFix(inViews, "DK2032", title: "Wrap"),
                "info { name: \"T\" }\nwidget {\n    variable a = false\n    Column {\n        Column {\n            if a {\n                Text(\"x\")\n            }\n        }.bold()\n    }\n}")
        // A modifier of elements on an option is DK5003, not "there's no" (finding 33).
        let option = deskCheck("info { name: \"T\" }\noptions { a = Toggle(\"A\").bold() }\nwidget { Text(\"{options.a}\") }")
        t.equal(option.diagnostics.map(\.id.rawValue), ["DK5003"])
        t.equal(option.diagnostics.first?.message(in: .english), "`.bold` doesn't apply to an option. An option takes `.hidden` and `.help`.")
        t.equal(ids("options { a = Toggle(\"A\").onClick { } }\nwidget { Text(\"{options.a}\") }"), ["DK5003"])
        t.equal(ids("options { a = Toggle(\"A\").boldd() }\nwidget { Text(\"{options.a}\") }"), ["DK3001"])
        // DK7016 with an argument-less modifier and a name in use (finding 64).
        let bold = deskCheck("info { name: \"T\" }\nwidget {\n    variable alert = 0\n    Text(\"{alert}\").onClick { alert = alert + 1; .bold() }\n}")
        let boldMessage = bold.diagnostics.first { $0.id.rawValue == "DK7016" }?.message(in: .english) ?? ""
        t.check(boldMessage.contains("`.bold(if: alert2)`") && boldMessage.contains("`alert2 = true`"), boldMessage)
        let boldFix = deskApplyFix(bold, "DK7016")
        t.equal(boldFix, "info { name: \"T\" }\nwidget {\n    variable alert2 = false\n    variable alert = 0\n    Text(\"{alert}\").onClick { alert = alert + 1; alert2 = true }.bold(if: alert2)\n}")
        t.equal(boldFix.map { deskCheck($0).diagnostics.map(\.id.rawValue) }, [])
        let two = deskCheck("info { name: \"T\" }\nwidget {\n    Column {\n        Text(\"A\").onClick { .bold() }\n        Text(\"B\").onClick { .italic() }\n    }\n}")
        let variables = two.diagnostics.filter { $0.id.rawValue == "DK7016" }.map { $0.arguments["variable"].map { "\($0)" } ?? "" }
        t.equal(Set(variables).count, 2, "each fix-it declares its own variable")
    }

    t.suite("Desk: review — Picker choices (finding 2)") {
        let lines = deskCheck("info { name: \"T\" }\noptions {\n    weekStart = Picker(\"Day\", [\n        .sunday\n        .monday\n    ], default: .sunday)\n}\nwidget { Text(\"{options.weekStart}\") }")
        t.equal(lines.diagnostics.map(\.id.rawValue), ["DK2007"])
        let fixed = deskApplyFix(lines, "DK2007")
        t.equal(fixed, "info { name: \"T\" }\noptions {\n    weekStart = Picker(\"Day\", [\n        .sunday,\n        .monday\n    ], default: .sunday)\n}\nwidget { Text(\"{options.weekStart}\") }")
        t.equal(fixed.map { deskCheck($0).diagnostics.map(\.id.rawValue) }, [])
        t.equal(lines.options["weekStart"]?.choices, ["sunday", "monday"])
        t.equal(deskReviewIDs("options {\n    d = Picker(\"Day\", [\n        .sunday\n        .monday\n        .tuesday\n    ])\n}\nwidget { Text(\"{options.d}\") }"), ["DK2007", "DK2007"])
        t.equal(deskReviewIDs("options { d = Picker(\"Day\", [.sunday.foo]) }\nwidget { Text(\"{options.d}\") }"), ["DK3003"])
        t.equal(deskReviewIDs("options { d = Picker(\"Flag\", [true, false]) }\nwidget { Text(\"{options.d}\") }"), ["DK4001", "DK4001"])
        t.equal(deskReviewIDs("options { d = Picker(\"A\", [Choice(.a, \"A\", \"B\"), Choice()]) }\nwidget { Text(\"{options.d}\") }"), ["DK4003", "DK4002"])
        let data = deskCheck("info { name: \"T\" }\noptions { d = Picker(\"Flag\", [cpu.usage]) }\nwidget { Text(\"{options.d}\") }")
        t.equal(data.diagnostics.map(\.id.rawValue), ["DK4001"])
        t.check(data.diagnostics.first?.message(in: .english).hasPrefix("A Picker's choice needs a case such as `.sunday`") == true,
                data.diagnostics.first?.message(in: .english) ?? "")
        // The usual forms stay clean.
        t.equal(deskReviewIDs("options { d = Picker(\"Day\", [.sunday, .monday]) }\nwidget { Text(\"{options.d}\") }"), [])
        t.equal(deskReviewIDs("options { d = Picker(\"Day\", [Weekday.sunday, .monday]) }\nwidget { Text(\"{options.d}\") }"), [])
        t.equal(deskReviewIDs("options { d = Picker(\"Look\", [Choice(.mono, \"One color\"), Choice(.full, \"Full color\")]) }\nwidget { Text(\"{options.d}\") }"), [])
        t.equal(deskReviewIDs("options { d = Picker(\"N\", [1, 2, -3]) }\nwidget { Text(\"{options.d}\") }"), [])
    }

    t.suite("Desk: review — keyword case variants used as values (finding 3)") {
        t.equal(deskReviewIDs("widget { Text(\"A\").hidden(if: Or) }"), ["DK3002"])
        t.equal(deskReviewIDs("widget { Text(\"{If}\") }"), ["DK3002"])
        t.equal(deskReviewIDs("widget { Text(Else) }"), ["DK3034"])
        t.equal(deskReviewIDs("widget {\n    variable x = Event\n    Text(\"{x}\")\n}"), ["DK3002"])
        let event = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").onClick { log(\"{Event.x}\") } }")
        t.equal(event.diagnostics.map(\.id.rawValue), ["DK3013"])
        t.equal(deskApplyFix(event, "DK3013").map { deskCheck($0).diagnostics.map(\.id.rawValue) }, [])
        let yes = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").hidden(if: True) }")
        t.equal(yes.diagnostics.map(\.id.rawValue), ["DK3013"])
        t.equal(deskApplyFix(yes, "DK3013"), "info { name: \"T\" }\nwidget { Text(\"A\").hidden(if: true) }")
        t.equal(deskReviewIDs("widget { Text(\"A\").hidden(if: Computed) }"), ["DK3002"])
    }

    t.suite("Desk: review — folder checks (finding 4)") {
        func folder(_ packageText: String, _ widgetText: String) -> (package: [String], widget: [String]) {
            let package = Desk.parse(packageText, file: DeskFileID(path: "package.desk"))
            let widget = Desk.parse(widgetText, file: DeskFileID(path: "A.desk"))
            let results = Desk.checkFolder(package: package, widgets: [widget])
            return (results[package.file]?.diagnostics.map(\.id.rawValue) ?? ["missing"], results[widget.file]?.diagnostics.map(\.id.rawValue) ?? ["missing"])
        }
        // A package translation used by a widget's text.
        let used = folder("package { name: \"P\" }\ntranslations {\n    \"zh-Hans\" { \"Hello\": \"你好\" }\n}\n", "info { name: \"A\" }\nwidget { Text(\"Hello\") }\n")
        t.equal(used.package, [])
        t.equal(used.widget, [])
        let unused = folder("package { name: \"P\" }\ntranslations {\n    \"zh-Hans\" { \"Bye\": \"再见\" }\n}\n", "info { name: \"A\" }\nwidget { Text(\"Hello\") }\n")
        t.equal(unused.package, ["DK8403"])
        // Styles and options reached through a package style.
        let chained = folder("package { name: \"P\" }\noptions { accent = ColorPicker(\"Accent\") }\nstyle base { .color(options.accent) }\nstyle card { .style(base).padding(4) }\n",
                             "info { name: \"A\" }\nwidget { Text(\"A\").style(card) }\n")
        t.equal(chained.package, [])
        t.equal(chained.widget, [])
        // A widget style that replaces a package style a used package style includes (D99).
        let replaced = folder("package { name: \"P\" }\nstyle base { .bold() }\nstyle card { .style(base).padding(4) }\n",
                              "info { name: \"A\" }\nwidget { Text(\"A\").style(card) }\nstyle base { .italic() }\n")
        t.equal(replaced.package, [])
        t.equal(replaced.widget, ["DK3027"])
        // The package checked alone knows nothing of the widgets: nothing is reported unused there.
        let alone = Desk.check(Desk.parse("package { name: \"P\" }\ntranslations {\n    \"zh-Hans\" { \"Hello\": \"你好\" }\n}\nstyle card { .bold() }\n",
                                          file: DeskFileID(path: "package.desk")))
        t.equal(alone.diagnostics.map(\.id.rawValue), [])
    }

    t.suite("Desk: review — settling by local enums (finding 5)") {
        let theme = "options { theme = Picker(\"Theme\", [.light, .dark, .sepia]) }\nwidget {\n    saved lastTheme = .light\n"
        for use in ["Text(\"{options.theme}\").onClick { lastTheme = Theme.dark }",
                    "Text(\"{options.theme}\").hidden(if: lastTheme == options.theme)",
                    "Text(\"{options.theme}\").onClick { options.theme = lastTheme }"] {
            let checked = deskCheck("info { name: \"T\" }\n" + theme + "    " + use + "\n}")
            t.equal(checked.diagnostics.map(\.id.rawValue), [], use)
            t.equal(checked.options["theme"]?.localEnum, "Theme", use)
        }
        // Still ambiguous when nothing decides.
        t.equal(deskReviewIDs(theme + "    Text(\"{lastTheme} {options.theme}\")\n}"), ["DK3018"])
    }

    t.suite("Desk: review — backslashes and Windows paths (findings 6, 58, 59, 83)") {
        // Correct escapes are not reported (finding 58).
        for text in [#"Text("\\")"#, #"Text("\\n starts a new line")"#, #"Text("C:\\")"#, #"Text("C:\\Users\\me")"#] {
            t.equal(deskReviewIDs("widget { \(text) }"), [], text)
        }
        // A Windows path in display text: one DK1012 whose fix-it converges (58, 83).
        for (text, fixed) in [(#"Text("C:\Users\me")"#, #"Text("C:\\Users\\me")"#), (#"Text("Path C:\Users\me")"#, #"Text("Path C:\\Users\\me")"#),
                              (#"Text("C:\\Users\me")"#, #"Text("C:\\Users\\me")"#)] {
            let checked = deskCheck("info { name: \"T\" }\nwidget { \(text) }")
            t.equal(checked.diagnostics.map(\.id.rawValue), ["DK1012"], text)
            let applied = deskApplyFix(checked, "DK1012")
            t.equal(applied, "info { name: \"T\" }\nwidget { \(fixed) }", text)
            t.equal(applied.map { deskCheck($0).diagnostics.map(\.id.rawValue) }, [], "\(text) after the fix")
        }
        // DK9307 names the app and the file from the path as written (findings 6, 59).
        let steam = deskCheck("info { name: \"T\" }\n" + #"widget { Text("A").onClick { open("C:\Program Files\Steam\steam.exe") } }"#)
        t.equal(steam.diagnostics.first?.message(in: .english), #"Windows paths don't exist on a Mac. Open the app by name: `open("Steam")`."#)
        t.equal(deskApplyFix(steam, "DK9307"), "info { name: \"T\" }\n" + #"widget { Text("A").onClick { open("Steam") } }"#)
        let image = deskCheck("info { name: \"T\" }\n" + #"widget { Image("C:\Skins\bg.png") }"#)
        t.equal(image.diagnostics.first?.message(in: .english), #"Windows paths don't exist on a Mac. Put it in the widget's folder and write `"bg.png"`."#)
        let appData = deskCheck("info { name: \"T\" }\n" + #"widget { Text("A").onClick { open("%APPDATA%\foo.exe") } }"#)
        t.equal(appData.diagnostics.first?.message(in: .english), #"Windows paths don't exist on a Mac. Open the app by name: `open("Foo")`."#)
        let doubled = deskCheck("info { name: \"T\" }\n" + #"widget { Text("A").onClick { open("C:\\Program Files\\Steam\\steam.exe") } }"#)
        t.check(!doubled.diagnostics.contains { $0.message(in: .english).contains("C:Program") }, deskDescribe(doubled))
    }
}
