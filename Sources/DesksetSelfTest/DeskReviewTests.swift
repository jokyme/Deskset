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
}
