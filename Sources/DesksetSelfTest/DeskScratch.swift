import Foundation
@testable import DeskLanguage

/// Temporary exploration harness: DESK_SCRATCH=path prints each snippet's outline and diagnostics (snippets are
/// separated by lines of `----`).
func runDeskScratch(_ t: TestRunner) {
    if ProcessInfo.processInfo.environment["DESK_FORMAT_PROFILE"] != nil {
        let widget = try! String(contentsOf: deskFixtures.appendingPathComponent("Acceptance/MonthView.desk"), encoding: .utf8)
        var text = ""
        var copies = 0
        while text.split(separator: "\n", omittingEmptySubsequences: false).count < 2000 {
            text += "// Copy \(copies)\n" + widget.replacingOccurrences(of: "widget {", with: "widget {\n    variable copy\(copies) = \(copies)") + "\n"
            copies += 1
        }
        if ProcessInfo.processInfo.environment["DESK_FORMAT_PROFILE"] == "messy" {
            text = text.replacingOccurrences(of: "    ", with: "  ").replacingOccurrences(of: ", ", with: ",")
        }
        let tree = deskParse(text)
        if let loops = Int(ProcessInfo.processInfo.environment["DESK_FORMAT_LOOP"] ?? "") {
            for _ in 0..<loops { _ = Desk.format(tree) }
            exit(0)
        }
        func time(_ name: String, _ runs: Int = 5, _ body: () -> Void) {
            var best = Double.infinity
            for _ in 0..<runs {
                let start = ProcessInfo.processInfo.systemUptime
                body()
                best = min(best, ProcessInfo.processInfo.systemUptime - start)
            }
            print(String(format: "%-28@ %8.2f ms", name as NSString, best * 1000))
        }
        time("Desk.format") { _ = Desk.format(tree) }
        time("nestingEstimate") { _ = StackGuard.nestingEstimate(Array(tree.text.utf8)) }
        time("init (annotate)") { _ = DeskFormatter(tree: tree, options: .canonical) }
        let f = DeskFormatter(tree: tree, options: .canonical)
        time("decideFromOriginal") { f.decideFromOriginal() }
        time("layout") { f.layout() }
        var output = f.render()
        time("render") { output = f.render() }
        time("breakOverflowingLines") { _ = f.breakOverflowingLines(output) }
        time("structure(tree)") { _ = DeskFormatter.structure(tree) }
        time("sameStructure") { _ = DeskFormatter.sameStructure(tree.root, tree.root) }
        time("verify") { _ = f.verify(output) }
        time("minimalEdits") { _ = f.minimalEdits(output) }
        time("parse") { _ = deskParse(text) }
        print("output == input: \(output.text == text), edits \(Desk.format(tree).count)")
        exit(0)
    }
    if ProcessInfo.processInfo.environment["DESK_ADVERSARIAL"] != nil {
        let cases: [(String, String)] = [
            ("unclosed braces", String(repeating: "Row {\n", count: 10_000)),
            ("extra braces", String(repeating: "}\n", count: 20_000)),
            ("corner quotes", "x = " + String(repeating: "「", count: 20_000)),
            ("optional chains", String(repeating: "a?.b ", count: 10_000)),
            ("named widgets", String(repeating: "widget CPU {\n}\n", count: 3_000)),
            ("parens", "x = " + String(repeating: "(", count: 30_000)),
            ("interpolations", "x = " + String(repeating: "\"{", count: 10_000)),
            ("single quotes", String(repeating: "'", count: 20_001)),
            ("ternaries", "x = " + String(repeating: "a ? b : ", count: 5_000)),
            ("ini", String(repeating: "[Meter]\nX=1\n", count: 5_000)),
            ("statements on a line", String(repeating: "Text(\"A\") ", count: 10_000)),
            ("else chain", String(repeating: "if a {} else ", count: 5_000)),
            ("comments", String(repeating: "/*", count: 10_000)),
            ("hashes", String(repeating: "#", count: 20_000)),
            ("bidi", String(repeating: "\u{202E}", count: 10_000)),
            ("brace lines", String(repeating: "{\n", count: 10_000) + String(repeating: "    }\n", count: 5_000)),
            ("indent repair", String(repeating: "Row {\n    Text(\"A\")\n", count: 3_000)),
            ("foreign blocks", String(repeating: "func f() {\n", count: 5_000)),
            ("dots", String(repeating: ".", count: 30_000)),
            ("minus", "x = " + String(repeating: "- ", count: 20_000) + "1"),
            ("not", "x = " + String(repeating: "not ", count: 10_000) + "a"),
            ("strings broken", String(repeating: "Text(\"a\n\"b\")\n", count: 4_000)),
            ("list", "x = [" + String(repeating: "1, ", count: 15_000) + "]"),
            ("args", "Text(" + String(repeating: "a: 1, ", count: 8_000) + ")"),
            ("modifiers", "Text(\"A\")" + String(repeating: ".font(.caption)", count: 4_000)),
        ]
        for (name, text) in cases {
            let start = ProcessInfo.processInfo.systemUptime
            let tree = deskParse(text)
            let parse = ProcessInfo.processInfo.systemUptime - start
            let formatStart = ProcessInfo.processInfo.systemUptime
            _ = Desk.format(tree)
            let format = ProcessInfo.processInfo.systemUptime - formatStart
            print(String(format: "%-22@ %6d KiB  parse %8.1f ms  format %8.1f ms  diagnostics %d", name as NSString,
                         text.utf8.count / 1024, parse * 1000, format * 1000, tree.diagnostics.count))
        }
        exit(0)
    }
    if ProcessInfo.processInfo.environment["DESK_CORPUS_TIMING"] != nil {
        let corpus = deskExampleCorpus()
        FileHandle.standardError.write(Data("corpus \(corpus.count)\n".utf8))
        for (n, example) in corpus.enumerated() {
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                let tree = deskParse(example)
                _ = Desk.format(tree)
                done.signal()
            }
            thread.stackSize = 64 << 20
            thread.start()
            if done.wait(timeout: .now() + 3) == .timedOut {
                FileHandle.standardError.write(Data("HANG \(n): \(example.debugDescription)\n".utf8))
                exit(3)
            }
        }
        FileHandle.standardError.write(Data("all done\n".utf8))
        exit(0)
    }
    if let folder = ProcessInfo.processInfo.environment["DESK_WRITE_FORMATTED"] {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".desk") && !name.hasSuffix(".formatted.desk") {
            let path = folder + "/" + name
            guard let data = fm.contents(atPath: path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let formatted = Desk.formatted(deskParse(text))
            let out = folder + "/" + name.replacingOccurrences(of: ".desk", with: ".formatted.desk")
            fm.createFile(atPath: out, contents: Data(formatted.utf8))
            print("wrote \(out)")
        }
    }
    guard let path = ProcessInfo.processInfo.environment["DESK_SCRATCH"],
          let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    t.suite("Desk: scratch") {
        for snippet in text.components(separatedBy: "\n----\n") {
            let parseStart = ProcessInfo.processInfo.systemUptime
            let tree = deskParse(snippet)
            print(String(format: "    (parse %.1f ms, %d lines)", (ProcessInfo.processInfo.systemUptime - parseStart) * 1000, snippet.split(separator: "\n").count))
            print("=== " + snippet.replacingOccurrences(of: "\n", with: "⏎"))
            print("    " + tree.root.outline)
            for d in tree.diagnostics {
                let loc = tree.location(of: d.range.lowerBound)
                let fixes = d.fixIts.map { f in "\(f.titleKey){" + f.edits.map { "\($0.range)→\($0.replacement.debugDescription)" }.joined(separator: ",") + "}" }
                print("    \(d.id.rawValue) \(d.severity) \(loc) \(d.arguments.keys.sorted().map { "\($0)=\(d.arguments[$0]!)" }.joined(separator: " ")) \(fixes.joined(separator: " "))")
            }
            let problems = deskTreeProblems(tree) + deskDiagnosticProblems(tree) + deskWrapperProblems(tree)
            if !problems.isEmpty { print("    PROBLEMS: \(problems)") }
            if ProcessInfo.processInfo.environment["DESK_FORMAT"] != nil {
                let formatted = Desk.formatted(tree)
                print("--- formatted:")
                print(formatted.replacingOccurrences(of: " ", with: "·"))
                let a = deskSignificantTokens(tree), b = deskSignificantTokens(deskParse(formatted))
                if a != b {
                    let d = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }
                    print("!!! TOKENS DIFFER at \(d?.offset ?? -1): \(d.map { "\($0.element.0) vs \($0.element.1)" } ?? "counts \(a.count) vs \(b.count)")")
                }
                let again = Desk.formatted(deskParse(formatted))
                if again != formatted { print("!!! NOT IDEMPOTENT:\n" + again.replacingOccurrences(of: " ", with: "·")) }
            }
        }
    }
}
