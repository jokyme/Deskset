import Foundation
@testable import DeskLanguage

/// Every Desk example of the language's design documents (their code spans and code blocks, valid and invalid
/// alike), collected in TestSkins/Desk/Corpus/examples.json.
func deskExampleCorpus() -> [String] {
    let url = deskFixtures.appendingPathComponent("Corpus/examples.json")
    guard let data = try? Data(contentsOf: url),
          let examples = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return examples
}

/// The fixture files as texts (valid and invalid alike).
func deskFixtureTexts() -> [(String, String)] { deskFixtureFiles() }

/// The non-trivia tokens of a text, as (kind, text).
func deskTokens(_ text: String) -> [String] {
    Lexer.lex(Array(text.utf8), file: DeskFileID(path: "T.desk")).tokens.filter { !$0.isMissing && $0.kind != .eof }
        .map { "\($0.kind.rawValue):\($0.text)" }
}

/// Variants of a text for the round trip (§9.2): other line breaks, tabs, a byte order mark, no final line break,
/// comments moved to the ends of lines, `;` for line breaks and back.
func deskVariants(_ text: String) -> [String] {
    var variants: [String] = []
    let lf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    variants.append(lf.replacingOccurrences(of: "\n", with: "\r\n"))
    variants.append(lf.replacingOccurrences(of: "\n", with: "\r"))
    variants.append(lf.replacingOccurrences(of: "    ", with: "\t"))
    variants.append("\u{FEFF}" + text)
    var trimmed = text
    while trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") { trimmed.removeLast() }
    variants.append(trimmed)
    // Whole-line comments moved to the end of the line before them.
    var lines = lf.components(separatedBy: "\n")
    var k = 1
    while k < lines.count {
        let stripped = lines[k].trimmingCharacters(in: .whitespaces)
        if stripped.hasPrefix("//") && !lines[k - 1].contains("//") {
            lines[k - 1] += " " + stripped
            lines.remove(at: k)
        } else {
            k += 1
        }
    }
    variants.append(lines.joined(separator: "\n"))
    // Line breaks between statements written as `;`, and `;` written as line breaks.
    variants.append(lf.replacingOccurrences(of: ")\n    ", with: "); "))
    variants.append(lf.replacingOccurrences(of: "; ", with: "\n"))
    return variants
}

/// The fuzz invariants (§9.3) for one input, and how long its parse took: the tree invariants, sorted and
/// deterministic diagnostics, wrappers that read every slot, a formatter that keeps the tokens and is idempotent, and
/// the time bound (100 ms per input in a release build, ten times that in a debug build).
func deskFuzzProblems(_ text: String) -> (problems: [String], elapsed: Double) {
    func timedParse() -> (SyntaxTree, Double) {
        let start = ProcessInfo.processInfo.systemUptime
        let tree = deskParse(text)
        return (tree, ProcessInfo.processInfo.systemUptime - start)
    }
    #if DEBUG
    let budget = 1.0
    #else
    let budget = 0.1
    #endif
    let (tree, firstTime) = timedParse()
    // A parse over budget is timed again, so that a machine that paused the process is not taken for slow code.
    let elapsed = firstTime > budget ? min(firstTime, timedParse().1) : firstTime
    var problems = deskTreeProblems(tree) + deskDiagnosticProblems(tree) + deskWrapperProblems(tree)
    let offsets = tree.diagnostics.map(\.range.lowerBound)
    if offsets != offsets.sorted() { problems.append("diagnostics not sorted") }
    if deskParse(text).diagnostics != tree.diagnostics { problems.append("not deterministic") }
    // The formatter never breaks a file either (it may decline to format it).
    let formatted = Desk.formatted(tree)
    if deskSignificantTokens(deskParse(formatted)) != deskSignificantTokens(tree) {
        problems.append("formatting changed tokens")
    }
    if Desk.formatted(deskParse(formatted)) != formatted { problems.append("formatting not idempotent") }
    if elapsed > budget { problems.append("took \(elapsed) s") }
    return (problems, elapsed)
}

func runDeskCorpusTests(_ t: TestRunner) {
    t.suite("Desk: round trip") {
        var inputs: [(String, String)] = deskFixtureTexts()
        for (n, example) in deskExampleCorpus().enumerated() { inputs.append(("example \(n)", example)) }
        t.check(inputs.count > 4000, "the corpus holds the specification's examples (\(inputs.count))")
        var checked = 0
        for (name, text) in inputs {
            for variant in [text] + (name.hasPrefix("example") ? [] : deskVariants(text)) {
                let tree = deskParse(variant)
                let problems = deskTreeProblems(tree) + deskDiagnosticProblems(tree) + deskWrapperProblems(tree)
                if !problems.isEmpty { t.check(false, "\(name): \(problems) for \(variant.debugDescription.prefix(200))") }
                checked += 1
                // Loading the bytes gives the same text back, a byte order mark included.
                if case .text(let loaded, _) = Desk.load(Data(variant.utf8), fileName: "T.desk") {
                    if loaded != variant { t.check(false, "\(name): load changed the text") }
                } else {
                    t.check(false, "\(name): valid UTF-8 was rejected")
                }
            }
        }
        t.check(checked > 4000)
        // Invalid UTF-8 is rejected as a whole (DK1008).
        if case .rejected(let d) = Desk.load(Data([0x77, 0x69, 0xFF, 0x67]), fileName: "Bad.desk") {
            t.equal(d.id, .invalidEncoding)
            t.equal(d.range, 2..<3)
        } else {
            t.check(false, "invalid UTF-8 accepted")
        }
        for bad: [UInt8] in [[0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]] {
            if case .text = Desk.load(Data(bad), fileName: "Bad.desk") { t.check(false, "accepted \(bad)") }
        }
        if case .text(let text, _) = Desk.load(Data([0xEF, 0xBB, 0xBF, 0x78]), fileName: "Bom.desk") {
            t.equal(text.utf8.count, 4, "the byte order mark is kept")
        }
    }

    t.suite("Desk: formatter") {
        let folder = deskFixtures.appendingPathComponent("Format")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".desk") && !$0.hasSuffix(".formatted.desk") }.sorted()
        t.check(names.count >= 13, "one fixture per rule F1–F13")
        for name in names {
            let input = String(decoding: try Data(contentsOf: folder.appendingPathComponent(name)), as: UTF8.self)
            let expectedURL = folder.appendingPathComponent(name.replacingOccurrences(of: ".desk", with: ".formatted.desk"))
            let expected = String(decoding: try Data(contentsOf: expectedURL), as: UTF8.self)
            let tree = deskParse(input)
            let edits = Desk.format(tree)
            let output = TextEdit.apply(edits, to: input)
            t.equal(output, expected, name)
            t.equal(Desk.format(deskParse(expected)), [], "\(name): the formatted text is stable")
            // Edits are sorted and do not overlap.
            for (a, b) in zip(edits, edits.dropFirst()) where a.range.upperBound > b.range.lowerBound {
                t.check(false, "\(name): overlapping edits")
            }
        }
        // Code left as written keeps its line breaks, which can tip the most frequent one once blank lines go: the
        // formatter writes the line break that is the most frequent in its output (F10, found by fuzzing).
        for tipping in [")\n)\nx = 1\r\r\r", ")\n)\n)\nx = 1\r\n\r\n\r\n\r\n", "x = 1\r)\n)\n\n\n"] {
            let once = Desk.formatted(deskParse(tipping))
            t.equal(Desk.formatted(deskParse(once)), once, tipping.debugDescription)
        }
        t.equal(Desk.formatted(deskParse(")\n)\nx = 1\r\r\r")), ")\n)\rx = 1\r")
        // On the whole corpus: idempotent, and the non-trivia tokens stay (apart from the separators turned into
        // line breaks and the normalised alternates), so translation keys never change.
        var inputs: [(String, String)] = deskFixtureTexts()
        for (n, example) in deskExampleCorpus().enumerated() { inputs.append(("example \(n)", example)) }
        var formattedCount = 0
        for (name, text) in inputs {
            let once = Desk.formatted(deskParse(text))
            let twice = Desk.formatted(deskParse(once))
            if once != twice {
                t.check(false, "\(name): not idempotent:\n\(once)\n----\n\(twice)")
                continue
            }
            if once != text { formattedCount += 1 }
            if deskSignificantTokens(deskParse(text)) != deskSignificantTokens(deskParse(once)) {
                t.check(false, "\(name): tokens changed")
            }
            let strings = deskTokens(text).filter { $0.hasPrefix("stringText:") || $0.hasPrefix("rawString:") }
            if strings != deskTokens(once).filter({ $0.hasPrefix("stringText:") || $0.hasPrefix("rawString:") }) {
                t.check(false, "\(name): text changed")
            }
        }
        t.check(formattedCount > 100, "the corpus exercises the formatter (\(formattedCount) texts changed)")
    }

    t.suite("Desk: generated corpus") {
        let seed = UInt64(ProcessInfo.processInfo.environment["DESK_FUZZ_SEED"] ?? "") ?? 20260927
        let count = Int(ProcessInfo.processInfo.environment["DESK_GENERATED_COUNT"] ?? "") ?? 400
        var generator = DeskGenerator(seed: seed)
        var failures = 0
        for n in 0..<count {
            let text = generator.file()
            let tree = deskParse(text)
            var problems = deskTreeProblems(tree) + deskDiagnosticProblems(tree) + deskWrapperProblems(tree)
            if !tree.diagnostics.isEmpty { problems.append("diagnostics \(tree.diagnostics.map(\.description))") }
            let once = Desk.formatted(tree)
            let onceTree = deskParse(once)
            if !onceTree.diagnostics.isEmpty { problems.append("formatted diagnostics \(onceTree.diagnostics.map(\.description))") }
            if Desk.formatted(onceTree) != once { problems.append("not idempotent") }
            if deskSignificantTokens(tree) != deskSignificantTokens(onceTree) { problems.append("tokens changed") }
            if !problems.isEmpty {
                failures += 1
                if failures <= 3 { t.check(false, "seed \(seed) file \(n): \(problems)\n\(text)") }
            }
        }
        t.equal(failures, 0, "generated files with problems (seed \(seed))")
    }

    t.suite("Desk: fuzz") {
        // 10,000 inputs per run, seeded by the CI run number (or DESK_FUZZ_SEED); DESK_FUZZ_COUNT for longer runs.
        // DESK_FUZZ_DUMP=folder keeps the failing inputs (and, with DESK_FUZZ_TRACE, the one being checked);
        // DESK_FUZZ_REPLAY=folder checks the inputs kept there instead.
        let environment = ProcessInfo.processInfo.environment
        if let replay = environment["DESK_FUZZ_REPLAY"] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: replay)) ?? []).filter { $0.hasSuffix(".txt") }
            for name in names.sorted() {
                guard let data = FileManager.default.contents(atPath: replay + "/" + name) else { continue }
                let (problems, elapsed) = deskFuzzProblems(String(decoding: data, as: UTF8.self))
                print(String(format: "    %@: %.1f ms %@", name as NSString, elapsed * 1000, problems.description as NSString))
                t.equal(problems, [], name)
            }
            return
        }
        let seed = UInt64(environment["DESK_FUZZ_SEED"] ?? environment["GITHUB_RUN_NUMBER"] ?? "") ?? 1
        let count = Int(environment["DESK_FUZZ_COUNT"] ?? "") ?? 10_000
        var random = DeskRandom(seed: seed)
        let corpus = deskFixtureTexts().map(\.1) + deskExampleCorpus().filter { $0.count > 40 }
        let pieces = ["{", "}", "(", ")", "[", "]", "\"", "“", "”", "「", "」", "（", "）", "｛", "：", "，", "。", ".", ",",
                      ";", ":", "=", "==", "if", "else", "for", "in", "Text", "variable", "widget", "style", "\n", " ",
                      "\t", "/*", "*/", "//", "#", "#\"", "\"#", "{{", "}}", "\\", "\\(", "'", "`", "😀", "页", "\u{202E}",
                      "\u{200B}", "\u{3000}", "&&", "!", "?", "?.", "...", "..<", "->", "@State", "<div>", "[Meter]",
                      "Key=1", "12px", "2 s", "0x1", "#FF00FF", "\r\n", "\r", "else if", ".font(", "}\n}", "\"{"]
        let scalars: [Unicode.Scalar] = Array("abcXYZ019_ {}()[]\"'.,;:=+-*/%!?<>#@$\\`~&|^\n\t".unicodeScalars)
            + ["“", "”", "「", "」", "（", "）", "：", "，", "。", "页", "é", "😀", "\u{0301}", "\u{202E}", "\u{200B}",
               "\u{3000}", "\u{00A0}", "\u{FEFF}", "\u{0007}", "\u{2028}", "\r"]
        // One spelling of every token kind the lexer knows.
        let tokenTexts = ["name", "Text", "if", "else", "for", "in", "and", "or", "not", "true", "false", "variable",
                          "saved", "computed", "event", "12", "50%", "2s", "\"a\"", "\"{x}\"", "#\"r\"#", "(", ")", "{", "}", "[",
                          "]", ",", ":", ";", ".", "...", "=", "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%",
                          "?", "&&", "||", "!", "+=", "-=", "*=", "/=", "++", "--", "**", "&", "|", "^", "~", "??", "..",
                          "..<", "->", "=>", "::", "@", "$", "\\", "`x`", "'x'", "</", "<!-- c -->", "#Name#", "#FFF",
                          "0xFF6B00", "\"\"\"t\"\"\"", "\n# c", "\n; c", "页", "§", "（", "「"]
        var slowest = 0.0
        var failures = 0
        for n in 0..<count {
            var text: String
            switch random.int(5) {
            case 4:
                // Token-level mutations (§9.3): delete, duplicate or swap tokens, insert a token of any kind, flip
                // braces. Edits are made from the end so earlier offsets stay valid.
                let base = random.pick(corpus)
                let lexed = Lexer.lex(Array(base.utf8), file: DeskFileID(path: "M.desk"))
                var ranges: [Range<Int>] = []
                for (k, token) in lexed.tokens.enumerated() where !token.isMissing && token.kind != .eof {
                    ranges.append(lexed.starts[k]..<(lexed.starts[k] + token.text.utf8.count))
                }
                guard !ranges.isEmpty else { continue }
                var edits: [TextEdit] = []
                var used = Set<Int>()
                for _ in 0..<(1 + random.int(5)) {
                    let k = random.int(ranges.count)
                    guard !used.contains(k), !used.contains(k + 1) else { continue }
                    used.insert(k)
                    let range = ranges[k]
                    let piece = String(decoding: Array(base.utf8)[range], as: UTF8.self)
                    switch random.int(5) {
                    case 0: edits.append(TextEdit(file: DeskFileID(path: "M.desk"), range: range, replacement: ""))
                    case 1: edits.append(TextEdit(file: DeskFileID(path: "M.desk"), range: range, replacement: piece + piece))
                    case 2 where k + 1 < ranges.count:
                        used.insert(k + 1)
                        let next = ranges[k + 1]
                        let nextPiece = String(decoding: Array(base.utf8)[next], as: UTF8.self)
                        edits.append(TextEdit(file: DeskFileID(path: "M.desk"), range: range, replacement: nextPiece))
                        edits.append(TextEdit(file: DeskFileID(path: "M.desk"), range: next, replacement: piece))
                    case 3:
                        let kind = random.pick(tokenTexts)
                        edits.append(TextEdit(file: DeskFileID(path: "M.desk"), range: range.lowerBound..<range.lowerBound,
                                              replacement: kind + " "))
                    default:
                        let flipped = piece == "{" ? "}" : piece == "}" ? "{" : piece == "(" ? ")" : piece == ")" ? "(" : "{"
                        edits.append(TextEdit(file: DeskFileID(path: "M.desk"), range: range, replacement: flipped))
                    }
                }
                text = TextEdit.apply(edits, to: base)
            case 0:
                // Random Unicode.
                var s = String.UnicodeScalarView()
                for _ in 0..<(1 + random.int(400)) { s.append(random.pick(scalars)) }
                text = String(s)
            case 1:
                // Random bytes, when they are UTF-8.
                var bytes: [UInt8] = []
                for _ in 0..<(1 + random.int(300)) { bytes.append(UInt8(random.int(256))) }
                guard case .text(let loaded, _) = Desk.load(Data(bytes), fileName: "F.desk") else { continue }
                text = loaded
            default:
                // Mutations of corpus files: delete, duplicate, swap or insert pieces; flip braces.
                text = random.pick(corpus)
                var chars = Array(text.unicodeScalars)
                for _ in 0..<(1 + random.int(6)) where !chars.isEmpty {
                    let at = random.int(chars.count)
                    switch random.int(5) {
                    case 0: chars.removeSubrange(at..<min(chars.count, at + 1 + random.int(8)))
                    case 1: chars.insert(contentsOf: Array(random.pick(pieces).unicodeScalars), at: at)
                    case 2:
                        let end = min(chars.count, at + 1 + random.int(20))
                        chars.insert(contentsOf: chars[at..<end], at: at)
                    case 3:
                        let other = random.int(chars.count)
                        chars.swapAt(at, other)
                    default:
                        if chars[at] == "{" { chars[at] = "}" } else if chars[at] == "}" { chars[at] = "{" }
                        else if chars[at] == "(" { chars[at] = ")" } else { chars[at] = "{" }
                    }
                }
                text = String(String.UnicodeScalarView(chars))
            }
            if let dump = environment["DESK_FUZZ_DUMP"], environment["DESK_FUZZ_TRACE"] != nil {
                // The input being checked, so that a crash leaves it behind.
                FileManager.default.createFile(atPath: dump + "/current.txt", contents: Data(text.utf8))
            }
            let (problems, elapsed) = deskFuzzProblems(text)
            slowest = max(slowest, elapsed)
            if !problems.isEmpty {
                failures += 1
                if failures <= 3 { t.check(false, "seed \(seed) input \(n): \(problems)\n\(text.debugDescription.prefix(600))") }
                if let dump = environment["DESK_FUZZ_DUMP"] {
                    FileManager.default.createFile(atPath: dump + "/input-\(n).txt", contents: Data(text.utf8))
                    FileHandle.standardError.write(Data("input \(n): \(problems)\n".utf8))
                }
            }
        }
        t.equal(failures, 0, "fuzz failures (seed \(seed))")
        print(String(format: "    fuzz: %d inputs, slowest parse %.1f ms (seed %llu)", count, slowest * 1000, seed))
        // Oversized inputs: up to and past the 1 MiB limit, for the round trip and termination only.
        let block = "widget {\n    Text(\"{cpu.usage}%\").font(.caption)\n    Row { Spacer() }\n}\n"
        for size in [(1 << 20) - 100, (1 << 20) + 5000] {
            var big = ""
            while big.utf8.count < size { big += block }
            let start = ProcessInfo.processInfo.systemUptime
            let tree = deskParse(big)
            t.equal(deskTreeProblems(tree) + deskDiagnosticProblems(tree), [], "\(size) bytes")
            t.check(ProcessInfo.processInfo.systemUptime - start < 10, "\(size) bytes within 10 s")
        }
    }

    t.suite("Desk: fuzz — pathological input") {
        // Inputs that once made a pass quadratic or exponential: each must stay within a bounded time (these are
        // debug-build bounds; the parse of each takes well under half a second on the reference machine).
        let cases: [(String, String)] = [
            ("unclosed braces", String(repeating: "Row {\n", count: 10_000)),
            ("extra braces", String(repeating: "}\n", count: 20_000)),
            ("corner quotes", "x = " + String(repeating: "「", count: 20_000)),
            ("optional chains", String(repeating: "a?.b ", count: 10_000)),
            ("named widgets", String(repeating: "widget CPU {\n}\n", count: 3_000)),
            ("parentheses", "x = " + String(repeating: "(", count: 30_000)),
            ("nested interpolations", "x = " + String(repeating: "\"{", count: 10_000)),
            ("single quotes", String(repeating: "'", count: 20_001)),
            ("ternaries", "x = " + String(repeating: "a ? b : ", count: 5_000)),
            ("statements on a line", String(repeating: "Text(\"A\") ", count: 6_000)),
            ("else chain", String(repeating: "if a {} else ", count: 5_000)),
            ("brace lines", String(repeating: "{\n", count: 10_000) + String(repeating: "    }\n", count: 5_000)),
            ("indent repair", String(repeating: "Row {\n    Text(\"A\")\n", count: 3_000)),
            ("foreign blocks", String(repeating: "func f() {\n", count: 5_000)),
            ("broken strings", String(repeating: "Text(\"a\n\"b\")\n", count: 4_000)),
            ("prefix operators", "x = " + String(repeating: "- not ", count: 8_000) + "1"),
        ]
        for (name, text) in cases {
            let start = ProcessInfo.processInfo.systemUptime
            let tree = deskParse(text)
            let parse = ProcessInfo.processInfo.systemUptime - start
            let formatStart = ProcessInfo.processInfo.systemUptime
            let formatted = Desk.formatted(tree)
            let format = ProcessInfo.processInfo.systemUptime - formatStart
            t.equal(deskTreeProblems(tree) + deskDiagnosticProblems(tree) + deskWrapperProblems(tree), [], name)
            // Bounds that only tell "finishes" from "runs away": CI's Intel runner is several times slower.
            t.check(parse < 30, "\(name): parse took \(parse) s")
            t.check(format < 60, "\(name): format took \(format) s")
            t.equal(Desk.formatted(deskParse(formatted)), formatted, "\(name): formatting is idempotent")
        }
    }

    t.suite("Desk: performance") {
        // A 2,000-line file of realistic widget code (the editor re-parses 0.3 s after typing stops, §0.4).
        let widget = try String(contentsOf: deskFixtures.appendingPathComponent("Acceptance/MonthView.desk"), encoding: .utf8)
        var text = ""
        var copies = 0
        while text.split(separator: "\n", omittingEmptySubsequences: false).count < 2000 {
            text += "// Copy \(copies)\n" + widget.replacingOccurrences(of: "widget {", with: "widget {\n    variable copy\(copies) = \(copies)") + "\n"
            copies += 1
        }
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        func measure(_ runs: Int, _ body: () -> Void) -> Double {
            var best = Double.infinity
            for _ in 0..<runs {
                let start = ProcessInfo.processInfo.systemUptime
                body()
                best = min(best, ProcessInfo.processInfo.systemUptime - start)
            }
            return best * 1000
        }
        var tree = deskParse(text)
        let lexMs = measure(5) { _ = Lexer.lex(Array(text.utf8), file: DeskFileID(path: "P.desk")) }
        let parseMs = measure(5) { tree = deskParse(text) }
        let formatMs = measure(3) { _ = Desk.format(tree) }
        // The editor's case: a one-character edit of a 300-line widget, parsed again.
        let small = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(300).joined(separator: "\n")
        let edited = small.replacingOccurrences(of: "spacing: 12", with: "spacing: 13")
        let reparseMs = measure(5) { _ = deskParse(edited) }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print(String(format: "    %d lines, %d KiB (%@ build): lex %.1f ms, lex + parse %.1f ms, format %.1f ms; "
                     + "300-line re-parse %.1f ms", lineCount, text.utf8.count / 1024, build, lexMs, parseMs, formatMs, reparseMs))
        // The budgets of a 1,000-line file in a release build (lex + parse 5 ms, format 5 ms), next to the editor's
        // 0.3 s pause after typing.
        let perThousand = 1000 / Double(lineCount)
        print(String(format: "    per 1,000 lines: lex + parse %.1f ms, format %.1f ms (release-build budgets: 5 ms each); "
                     + "the whole file parses in %.1f%% of the editor's 300 ms pause", parseMs * perThousand,
                     formatMs * perThousand, parseMs / 300 * 100))
        t.check(lineCount >= 2000)
        t.equal(tree.diagnostics.count, 0)
        // Recorded, not asserted tightly: CI machines vary. A generous bound still catches accidental quadratic work.
        t.check(parseMs < 3000, "lex + parse of \(lineCount) lines: \(parseMs) ms")
        t.check(formatMs < 6000, "format of \(lineCount) lines: \(formatMs) ms")
    }

    t.suite("Desk: layering") {
        // Syntax/ imports only Foundation (D69); DeskLanguage never imports AppKit or IOKit.
        let sources = deskRepositoryRoot.appendingPathComponent("Sources/DeskLanguage")
        guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            t.check(false, "no sources")
            return
        }
        var syntaxFiles = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") || $0.hasPrefix("@testable import ")
                || $0.hasPrefix("@_exported import ") }
            let inSyntax = url.path.contains("/Syntax/")
            if inSyntax { syntaxFiles += 1 }
            for line in imports {
                if inSyntax && line != "import Foundation" { t.check(false, "\(url.lastPathComponent): \(line)") }
                if line.contains("AppKit") || line.contains("IOKit") || line.contains("Cocoa") || line.contains("SwiftUI") {
                    t.check(false, "\(url.lastPathComponent): \(line)")
                }
            }
        }
        t.check(syntaxFiles >= 10, "Syntax/ sources found (\(syntaxFiles))")
    }
}
