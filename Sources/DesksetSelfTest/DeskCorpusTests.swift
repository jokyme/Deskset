import Foundation
@testable import DeskLanguage

/// Every example of the language specification and DESK-DESIGN §4–8 (code spans and code blocks), extracted into
/// TestSkins/Desk/Corpus/examples.json.
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

func runDeskCorpusTests(_ t: TestRunner) {
    t.suite("Desk: round trip") {
        var inputs: [(String, String)] = deskFixtureTexts()
        for (n, example) in deskExampleCorpus().enumerated() { inputs.append(("example \(n)", example)) }
        t.check(inputs.count > 4000, "the corpus holds the specification's examples (\(inputs.count))")
        var checked = 0
        for (name, text) in inputs {
            for variant in [text] + (name.hasPrefix("example") ? [] : deskVariants(text)) {
                let tree = deskParse(variant)
                let problems = deskTreeProblems(tree)
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
            let before = deskTokens(text).filter { !$0.hasPrefix("semicolon:") && !$0.hasPrefix("comma:") && !$0.hasPrefix("colon:") && !$0.hasPrefix("equal:") }
            let after = deskTokens(once).filter { !$0.hasPrefix("semicolon:") && !$0.hasPrefix("comma:") && !$0.hasPrefix("colon:") && !$0.hasPrefix("equal:") }
            if before != after { t.check(false, "\(name): tokens changed") }
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
            var problems = deskTreeProblems(tree)
            if !tree.diagnostics.isEmpty { problems.append("diagnostics \(tree.diagnostics.map(\.description))") }
            let once = Desk.formatted(tree)
            let onceTree = deskParse(once)
            if !onceTree.diagnostics.isEmpty { problems.append("formatted diagnostics \(onceTree.diagnostics.map(\.description))") }
            if Desk.formatted(onceTree) != once { problems.append("not idempotent") }
            let tokens = { (s: String) in deskTokens(s).filter { !$0.hasPrefix("semicolon:") } }
            if tokens(text) != tokens(once) { problems.append("tokens changed") }
            if !problems.isEmpty {
                failures += 1
                if failures <= 3 { t.check(false, "seed \(seed) file \(n): \(problems)\n\(text)") }
            }
        }
        t.equal(failures, 0, "generated files with problems (seed \(seed))")
    }

    t.suite("Desk: fuzz") {
        let seed = UInt64(ProcessInfo.processInfo.environment["DESK_FUZZ_SEED"] ?? "") ?? 1
        let count = Int(ProcessInfo.processInfo.environment["DESK_FUZZ_COUNT"] ?? "") ?? 3000
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
        var slowest = 0.0
        var failures = 0
        for n in 0..<count {
            var text: String
            switch random.int(4) {
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
            let start = ProcessInfo.processInfo.systemUptime
            let tree = deskParse(text)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            slowest = max(slowest, elapsed)
            var problems = deskTreeProblems(tree)
            let offsets = tree.diagnostics.map(\.range.lowerBound)
            if offsets != offsets.sorted() { problems.append("diagnostics not sorted") }
            if deskParse(text).diagnostics != tree.diagnostics { problems.append("not deterministic") }
            // The formatter never breaks a file either (it may decline to format it).
            let formatted = Desk.formatted(tree)
            if deskTokens(formatted).filter({ !$0.hasPrefix("semicolon:") && !$0.hasPrefix("comma:") && !$0.hasPrefix("colon:") && !$0.hasPrefix("equal:") })
                != deskTokens(text).filter({ !$0.hasPrefix("semicolon:") && !$0.hasPrefix("comma:") && !$0.hasPrefix("colon:") && !$0.hasPrefix("equal:") }) {
                problems.append("formatting changed tokens")
            }
            if Desk.formatted(deskParse(formatted)) != formatted { problems.append("formatting not idempotent") }
            // 100 ms per input in a release build, ten times that in a debug build (§9.3).
            if elapsed > 1.0 { problems.append("took \(elapsed) s") }
            if !problems.isEmpty {
                failures += 1
                if failures <= 3 { t.check(false, "seed \(seed) input \(n): \(problems)\n\(text.debugDescription.prefix(600))") }
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
            t.equal(deskTreeProblems(tree), [], "\(size) bytes")
            t.check(ProcessInfo.processInfo.systemUptime - start < 10, "\(size) bytes within 10 s")
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
