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
}
