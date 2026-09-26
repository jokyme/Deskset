import Foundation
@testable import DesksetCore

// The built-in code editor's Core parts: the line tokenizer (IniHighlighter) and the file model (CodeDocument).

/// Tokens of one line as "text|kind" strings, for readable expectations.
private func highlight(_ line: String) -> [String] {
    let ns = line as NSString
    return IniHighlighter.tokens(inLine: line).map { "\(ns.substring(with: $0.range))|\($0.kind.rawValue)" }
}

func runCodeEditorTests(_ t: TestRunner) {
    let savedANSICodePage = TextDecoding.ansiCodePage
    TextDecoding.ansiCodePage = 1252
    defer { TextDecoding.ansiCodePage = savedANSICodePage }

    t.suite("Code editor: highlighting headers, keys and comments") {
        t.equal(highlight("[Rainmeter]"), ["[Rainmeter]|sectionHeader"])
        t.equal(highlight("  [MeterCPU]  ; ignored"), ["[MeterCPU]|sectionHeader", "; ignored|comment"],
                "text after the header is ignored by the reader")
        t.equal(highlight("[MeterCPU"), ["[MeterCPU|sectionHeader"], "unterminated header")
        t.equal(highlight("; a comment"), ["; a comment|comment"])
        t.equal(highlight("\t;x = 1"), [";x = 1|comment"])
        t.equal(highlight("Update=1000"), ["Update|key", "=|equals", "1000|number"])
        t.equal(highlight("\tX = 1"), ["X|key", "=|equals", "1|number"])
        t.equal(highlight("Text=Hello; world"), ["Text|key", "=|equals", "Hello; world|value"],
                "no inline comments")
        t.equal(highlight("Text="), ["Text|key", "=|equals"])
        t.equal(highlight("JustText"), [], "a line without = is ignored")
        t.equal(highlight("=value"), [], "an empty key is ignored")
        t.equal(highlight(""), [])
        t.equal(highlight("   "), [])
        t.equal(highlight("@Include=#@#Variables.inc"),
                ["@Include|includeKey", "=|equals", "#@#|variable", "Variables.inc|value"])
        t.equal(highlight("@include2 = Other.inc"), ["@include2|includeKey", "=|equals", "Other.inc|value"])
    }

    t.suite("Code editor: highlighting types, quotes and numbers") {
        t.equal(highlight("Meter=String"), ["Meter|key", "=|equals", "String|typeName"])
        t.equal(highlight("Measure = \"CPU\""), ["Measure|key", "=|equals", "\"|quote", "CPU|typeName", "\"|quote"])
        t.equal(highlight("Plugin=PowerPlugin"), ["Plugin|key", "=|equals", "PowerPlugin|typeName"])
        t.equal(highlight("MeterStyle=StyleA | StyleB"), ["MeterStyle|key", "=|equals", "StyleA | StyleB|value"])
        t.equal(highlight("SolidColor=255,0,0,128"),
                ["SolidColor|key", "=|equals", "255|number", ",|value", "0|number", ",|value", "0|number",
                 ",|value", "128|number"])
        t.equal(highlight("FontColor=FF8800"), ["FontColor|key", "=|equals", "FF8800|number"], "hex color")
        t.equal(highlight("FontColor=ff8800cc"), ["FontColor|key", "=|equals", "ff8800cc|number"])
        t.equal(highlight("X=10R"), ["X|key", "=|equals", "10|number", "R|value"])
        t.equal(highlight("X=-5"), ["X|key", "=|equals", "-5|number"])
        t.equal(highlight("MeasureName2=MeasureCPU2"), ["MeasureName2|key", "=|equals", "MeasureCPU2|value"],
                "digits glued to a name are not numbers")
        t.equal(highlight("Text=\"Hello\""), ["Text|key", "=|equals", "\"Hello\"|quote"])
        t.equal(highlight("Text='Hello'"), ["Text|key", "=|equals", "'|quote", "Hello|value", "'|quote"],
                "the reader strips a pair of single quotes")
        t.equal(highlight("Text=Don't"), ["Text|key", "=|equals", "Don't|value"])
        t.equal(highlight("Text=5\" tall"), ["Text|key", "=|equals", "5|number", "\" tall|value"], "a lone quote")
        t.equal(highlight("Substitute=\"a\":\"b\""), ["Substitute|key", "=|equals", "\"a\"|quote", ":|value", "\"b\"|quote"])
    }

    t.suite("Code editor: highlighting variables") {
        t.equal(highlight("FontColor=#Color#"), ["FontColor|key", "=|equals", "#Color#|variable"])
        t.equal(highlight("Text=#*Var*#"), ["Text|key", "=|equals", "#*Var*#|variable"], "escape")
        t.equal(highlight("Text=#1 and #Var#"), ["Text|key", "=|equals", "#|value", "1|number", " and |value", "#Var#|variable"],
                "the second # can open the next reference")
        t.equal(highlight("SolidColor=[#Color[#Index]]"), ["SolidColor|key", "=|equals", "[#Color[#Index]]|variable"])
        t.equal(highlight("Text=[#*Var*]"), ["Text|key", "=|equals", "[#*Var*]|variable"])
        t.equal(highlight("Text=[\\x263A] [\\9731]"),
                ["Text|key", "=|equals", "[\\x263A]|variable", " |value", "[\\9731]|variable"])
        t.equal(highlight("MaxValue=[MeasureSwapTotal:]"), ["MaxValue|key", "=|equals", "[MeasureSwapTotal:]|sectionVariable"])
        t.equal(highlight("Text=CPU [MeasureCPU:/1024,1] MB"),
                ["Text|key", "=|equals", "CPU |value", "[MeasureCPU:/1024,1]|sectionVariable", " MB|value"])
        t.equal(highlight("W=[MeterA:XW]"), ["W|key", "=|equals", "[MeterA:XW]|sectionVariable"])
        t.equal(highlight("Text=[MeasureCPU:%]%"), ["Text|key", "=|equals", "[MeasureCPU:%]|sectionVariable", "%|value"])
        t.equal(highlight("Text=[*MeasureCPU*]"), ["Text|key", "=|equals", "[*MeasureCPU*]|sectionVariable"])
        t.equal(highlight("Text=[&Script:Func('a b')]"), ["Text|key", "=|equals", "[&Script:Func('a b')]|sectionVariable"])
        t.equal(highlight("Text=[Hello World]"), ["Text|key", "=|equals", "[Hello World]|value"],
                "a name with blanks is not a section variable")
        t.equal(highlight("Text=\"[MeasureCPU]%\""),
                ["Text|key", "=|equals", "\"|quote", "[MeasureCPU]|sectionVariable", "%\"|quote"])
        t.equal(highlight("LeftMouseUpAction=[!SetVariable X $MouseX:%$]"),
                ["LeftMouseUpAction|key", "=|equals", "[!SetVariable|bang", " X |value", "$MouseX:%$|variable", "]|bang"])
        t.equal(highlight("Text=Price $5 and $6"), ["Text|key", "=|equals", "Price $|value", "5|number", " and $|value", "6|number"])
        // UTF-16 ranges: the emoji takes two units.
        t.equal(IniHighlighter.tokens(inLine: "Text=😀 #X#"),
                [.init(0, 4, .key), .init(4, 1, .equals), .init(5, 3, .value), .init(8, 3, .variable)])
    }

    t.suite("Code editor: highlighting bangs and formulas") {
        t.equal(highlight("LeftMouseUpAction=[!SetOption MeterText Text \"Hello World\"][!Redraw]"),
                ["LeftMouseUpAction|key", "=|equals", "[!SetOption|bang", " MeterText Text |value",
                 "\"Hello World\"|quote", "][!Redraw]|bang"])
        t.equal(highlight("IfTrueAction=[!SetOption MeterSwap Text [MeasureSwap]]"),
                ["IfTrueAction|key", "=|equals", "[!SetOption|bang", " MeterSwap Text |value",
                 "[MeasureSwap]|sectionVariable", "]|bang"])
        t.equal(highlight("OnRefreshAction=!Log \"hi\""),
                ["OnRefreshAction|key", "=|equals", "!Log|bang", " |value", "\"hi\"|quote"], "a bare bang")
        t.equal(highlight("Text=!Hello"), ["Text|key", "=|equals", "!Hello|value"], "only action options take bare bangs")
        t.equal(highlight("MouseOverAction2=[!Log \"a]b\"]"),
                ["MouseOverAction2|key", "=|equals", "[!Log|bang", " |value", "\"a]b\"|quote", "]|bang"],
                "brackets inside quotes do not close the bang")
        t.equal(highlight("LeftMouseUpAction=[!SetVariable X \"\"\"a [!b] c\"\"\"]"),
                ["LeftMouseUpAction|key", "=|equals", "[!SetVariable|bang", " X |value", "\"\"\"a [!b] c\"\"\"|quote",
                 "]|bang"], "magic quotes are literal")
        t.equal(highlight("ContextAction=[\"https://example.com\"]"),
                ["ContextAction|key", "=|equals", "[|value", "\"https://example.com\"|quote", "]|value"])
        t.equal(highlight("Act=[!Refresh]"), ["Act|key", "=|equals", "[!Refresh]|bang"], "bangs stored in variables")
        t.equal(highlight("Act=[!SetOption M Text"), ["Act|key", "=|equals", "[!SetOption|bang", " M Text|value"],
                "unterminated bang")
        t.equal(highlight("W=(#Size# * 2)"),
                ["W|key", "=|equals", "(|paren", "#Size#|variable", " * |value", "2|number", ")|paren"])
        t.equal(highlight("Formula=Max(MeasureA - MeasureB, 0.5)"),
                ["Formula|key", "=|equals", "Max|value", "(|paren", "MeasureA - MeasureB, |value", "0.5|number", ")|paren"])
        t.equal(highlight("IfCondition2=(MeasureCPU > 80) && (MeasureCPU < 90)"),
                ["IfCondition2|key", "=|equals", "(|paren", "MeasureCPU > |value", "80|number", ")|paren",
                 " && |value", "(|paren", "MeasureCPU < |value", "90|number", ")|paren"])
        t.equal(highlight("Text=Hello (world)"), ["Text|key", "=|equals", "Hello (world)|value"],
                "parentheses in text are not a formula")
    }

    t.suite("Code editor: highlighting ranges in a document") {
        let text = "[A]\r\nX=1\r\n; c\nY=#V#" as NSString
        t.equal(IniHighlighter.tokens(in: text, range: NSRange(location: 0, length: text.length)),
                [.init(0, 3, .sectionHeader), .init(5, 1, .key), .init(6, 1, .equals), .init(7, 1, .number),
                 .init(10, 3, .comment), .init(14, 1, .key), .init(15, 1, .equals), .init(16, 3, .variable)])
        t.equal(IniHighlighter.tokens(in: text, range: NSRange(location: 6, length: 0)),
                [.init(5, 1, .key), .init(6, 1, .equals), .init(7, 1, .number)], "one line")
        let lines = "ab\r\ncd\r\nef" as NSString
        t.equal(IniHighlighter.lineRange(in: lines, containing: NSRange(location: 1, length: 0)), NSRange(location: 0, length: 4))
        t.equal(IniHighlighter.lineRange(in: lines, containing: NSRange(location: 4, length: 1)), NSRange(location: 4, length: 4))
        t.equal(IniHighlighter.lineRange(in: lines, containing: NSRange(location: 9, length: 1)), NSRange(location: 8, length: 2))
        t.equal(IniHighlighter.lineRange(in: lines, containing: NSRange(location: 10, length: 0)), NSRange(location: 8, length: 2))
        t.equal(IniHighlighter.lineRange(in: lines, containing: NSRange(location: 0, length: 4)), NSRange(location: 0, length: 8),
                "an edit that ends with a line break touches the next line too")
        t.equal(IniHighlighter.lineRange(in: lines, containing: NSRange(location: 3, length: 0)), NSRange(location: 0, length: 8),
                "between CR and LF")
        t.equal(IniHighlighter.lineRange(in: "" as NSString, containing: NSRange(location: 0, length: 0)), NSRange(location: 0, length: 0))
    }

    t.suite("Code editor: every default skin line tokenizes cleanly") {
        let defaults = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("DefaultSkins")
        let files = FileManager.default.enumerator(at: defaults, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { ["ini", "inc"].contains($0.pathExtension.lowercased()) } ?? []
        t.check(!files.isEmpty, "found default skins")
        for file in files {
            let text = try TextDecoding.readFile(at: file) as NSString
            let tokens = IniHighlighter.tokens(in: text, range: NSRange(location: 0, length: text.length))
            var last = 0
            var ok = true
            for token in tokens {
                if token.range.location < last || token.range.length <= 0 || NSMaxRange(token.range) > text.length { ok = false }
                last = NSMaxRange(token.range)
            }
            t.check(ok, "\(file.lastPathComponent): sorted, non-overlapping, in bounds")
            t.check(tokens.contains { $0.kind == .sectionHeader }, "\(file.lastPathComponent) has headers")
        }
    }

    t.suite("Code editor: documents round-trip byte for byte") {
        func check(_ bytes: [UInt8], _ encoding: TextFileEncoding, _ ending: CodeDocument.LineEnding, _ label: String) {
            let doc = CodeDocument(data: Data(bytes))
            t.equal(doc.encoding, encoding, label)
            t.equal(doc.lineEnding, ending, label)
            t.equal(doc.data(for: doc.text), Data(bytes), "\(label): unchanged text gives the same bytes")
        }
        check(Array("[Rainmeter]\nUpdate=1000\n".utf8), .utf8(bom: false), .lf, "UTF-8 LF")
        check([0xEF, 0xBB, 0xBF] + Array("[A]\r\nText=Café ☂\r\n".utf8), .utf8(bom: true), .crlf, "UTF-8 BOM CRLF")
        var utf16: [UInt8] = [0xFF, 0xFE]
        for unit in "[A]\r\nText=日本 😀\r\nX=1".utf16 { utf16 += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        check(utf16, .utf16LittleEndian(bom: true), .crlf, "UTF-16LE BOM CRLF")
        let ansi: [UInt8] = Array("[A]\r\nText=Caf".utf8) + [0xE9, 0x20, 0x80] + Array("\r\n".utf8)
        check(ansi, .windows1252, .crlf, "ANSI 1252")
        check(Array("a\r\nb\nc\rd\r\ne".utf8), .utf8(bom: false), .crlf, "mixed endings")
        check(Array("a\nb\nc\r\n".utf8), .utf8(bom: false), .lf, "mostly LF")
        check([], .utf8(bom: false), .crlf, "empty file")

        // Editing keeps every other line ending exactly.
        var doc = CodeDocument(data: Data("a\r\nb\nc".utf8))
        let edited = doc.text.replacingOccurrences(of: "b", with: "b\r\nB")
        t.equal(doc.data(for: edited), Data("a\r\nb\r\nB\nc".utf8))
        doc.text = edited
        t.equal(doc.lineCount, 4)

        let cp1252 = CodeDocument(data: Data(ansi))
        t.check(cp1252.text.contains("Café €"), "decoded as 1252: \(cp1252.text)")
        t.check(cp1252.canEncode("Café €"), "1252 holds é and €")
        t.check(!cp1252.canEncode("日本"), "1252 cannot hold CJK")
        t.equal(cp1252.data(for: "日本"), nil)
        t.check(!cp1252.hasBOM && cp1252.isANSI)
        var converted = cp1252
        converted.convertToUnicode()
        t.equal(converted.encoding, .utf16LittleEndian(bom: true))
        t.equal(converted.data(for: "A"), Data([0xFF, 0xFE, 0x41, 0x00]))
        t.check(CodeDocument(data: Data(utf16)).canEncode("日本"))

        // write(_:to:) keeps the encoding, or converts an ANSI file that can no longer hold its text.
        let dir = t.temporaryDirectory("code-document")
        let url = dir.appendingPathComponent("Skin.ini")
        var bom = CodeDocument(data: Data([0xEF, 0xBB, 0xBF] + Array("[A]\r\n".utf8)))
        try bom.write("[A]\r\nX=1\r\n", to: url)
        t.equal(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF] + Array("[A]\r\nX=1\r\n".utf8)))
        var legacy = cp1252
        try legacy.write("Text=日本", to: url)
        t.equal(legacy.encoding, .utf16LittleEndian(bom: true))
        t.equal(try CodeDocument.load(url).text, "Text=日本")

        // A symlink is followed: the target gets the bytes and the link stays a link (an atomic write to the link
        // itself would replace it with a regular file and leave the target stale).
        let real = dir.appendingPathComponent("Real.ini")
        try Data("[A]\r\nX=1\r\n".utf8).write(to: real)
        let link = dir.appendingPathComponent("Link.ini")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        var linked = try CodeDocument.load(link)
        t.equal(linked.text, "[A]\r\nX=1\r\n")
        try linked.write("[A]\r\nX=2\r\n", to: link)
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        t.equal(type, .typeSymbolicLink, "the link is still a link")
        t.equal(try Data(contentsOf: real), Data("[A]\r\nX=2\r\n".utf8), "the target was updated")
        t.equal(CodeDocument.writeTarget(for: link).path, CodeDocument.writeTarget(for: real).path)
        t.equal(CodeDocument.writeTarget(for: dir.appendingPathComponent("sub/../Real.ini")).path,
                CodeDocument.writeTarget(for: real).path, "standardized")
    }

    t.suite("Code editor: dominant line ending") {
        t.equal(CodeDocument.dominantLineEnding(in: "a\r\nb\r\nc\nd"), .crlf)
        t.equal(CodeDocument.dominantLineEnding(in: "a\nb\nc\r\nd"), .lf)
        t.equal(CodeDocument.dominantLineEnding(in: "a\rb\rc\nd"), .cr)
        t.equal(CodeDocument.dominantLineEnding(in: "a\r\nb\n"), .crlf, "a tie prefers CRLF")
        t.equal(CodeDocument.dominantLineEnding(in: "one line"), .crlf, "no line break: the Windows convention")
        t.equal(CodeDocument.dominantLineEnding(in: "a\r"), .cr)
        t.equal(CodeDocument(text: "x", lineEnding: .lf).lineEnding, .lf)
    }

    t.suite("Code editor: line index") {
        let doc = CodeDocument(text: "a\r\nbc\nd\re\r\n")
        t.equal(doc.lineStarts, [0, 3, 6, 8, 11])
        t.equal(doc.lineCount, 5, "the empty line after the final break counts")
        t.equal(doc.line(containingOffset: 0), 1)
        t.equal(doc.line(containingOffset: 2), 1, "between CR and LF")
        t.equal(doc.line(containingOffset: 3), 2)
        t.equal(doc.line(containingOffset: 7), 3)
        t.equal(doc.line(containingOffset: 11), 5)
        t.equal(doc.line(containingOffset: 99), 5, "clamped")
        t.equal(doc.line(containingOffset: -4), 1, "clamped")
        t.equal(doc.offset(ofLine: 1), 0)
        t.equal(doc.offset(ofLine: 4), 8)
        t.equal(doc.offset(ofLine: 42), 11)
        t.equal(doc.range(ofLine: 1), NSRange(location: 0, length: 1))
        t.equal(doc.range(ofLine: 1, includingTerminator: true), NSRange(location: 0, length: 3))
        t.equal(doc.range(ofLine: 2), NSRange(location: 3, length: 2))
        t.equal(doc.range(ofLine: 3), NSRange(location: 6, length: 1))
        t.equal(doc.range(ofLine: 4), NSRange(location: 8, length: 1))
        t.equal(doc.range(ofLine: 5), NSRange(location: 11, length: 0))
        t.equal(doc.range(ofLines: 2..<4), NSRange(location: 3, length: 5))
        t.equal(doc.range(ofLines: 4..<9), NSRange(location: 8, length: 3))
        t.equal(CodeDocument(text: "").lineCount, 1)
        t.equal(CodeDocument(text: "x").range(ofLine: 1), NSRange(location: 0, length: 1))
        t.equal(CodeDocument(text: "😀\nx").offset(ofLine: 2), 3, "UTF-16 offsets")
    }

    t.suite("Code editor: sections") {
        let text = """
        ; about the skin
        [Rainmeter]
        Update=1000

        [MeterA]
        Meter="String"
        ; disabled

        ; about B
        [MeasureB]
        Measure=CPU
        [MeterA]
        X=5

        """
        let doc = CodeDocument(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
        t.equal(doc.sectionHeaders(), [
            .init(name: "Rainmeter", line: 2),
            .init(name: "MeterA", line: 5, meter: "String"),
            .init(name: "MeasureB", line: 10, measure: "CPU"),
            .init(name: "MeterA", line: 12),
        ])
        t.equal(doc.section(containingLine: 1), "Rainmeter", "a comment right above a header introduces it")
        t.equal(doc.section(containingLine: 3), "Rainmeter")
        t.equal(doc.section(containingLine: 4), "Rainmeter")
        t.equal(doc.section(containingLine: 5), "MeterA")
        t.equal(doc.section(containingLine: 7), "MeterA")
        t.equal(doc.section(containingLine: 8), "MeterA")
        t.equal(doc.section(containingLine: 9), "MeasureB")
        t.equal(doc.section(containingLine: 13), "MeterA")
        t.equal(doc.section(containingLine: 14), "MeterA", "the empty last line")
        t.equal(doc.section(containingLine: 99), "MeterA")
        t.equal(doc.lineRange(ofSection: "metera"), 5..<8, "the first block, without the next section's comment")
        t.equal(doc.lineRange(ofSection: "Rainmeter"), 2..<4, "without trailing blank lines")
        t.equal(doc.lineRange(ofSection: "MeasureB"), 10..<12)
        t.equal(doc.lineRange(ofSection: "Nope"), nil)
        let tail = CodeDocument(text: "[A]\nX=1\n\n")
        t.equal(tail.lineRange(ofSection: "A"), 1..<3)
        t.equal(CodeDocument(text: "X=1\n; nothing\n").section(containingLine: 1), nil, "before any header")
        t.equal(CodeDocument(text: "[A]\n[]\nX=1").section(containingLine: 3), nil, "inside a [] block")
        t.equal(CodeDocument(text: "").section(containingLine: 1), nil)
        t.equal(CodeDocument(text: "").sectionHeaders(), [])
    }
}
