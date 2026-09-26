import Foundation
@testable import DesksetCore

private func iniBytes(_ data: Data) -> [UInt8] { [UInt8](data) }

private func iniWrite(_ text: String, to url: URL, encoding: TextFileEncoding = .utf8(bom: false)) {
    let data = TextDecoding.encode(text, as: encoding) ?? Data(text.utf8)
    try? data.write(to: url)
}

private func iniRead(_ url: URL) -> String {
    (try? TextDecoding.readFile(at: url)) ?? "<unreadable>"
}

func runIniTests(_ t: TestRunner) {
    // Legacy ANSI files decode with `TextDecoding.ansiCodePage` (the app sets it from the Mac's language, like
    // Rainmeter with the Windows locale); pin the Western default so these suites never depend on the machine or on
    // other suites. Suites below that test other code pages set them explicitly.
    let savedANSICodePage = TextDecoding.ansiCodePage
    TextDecoding.ansiCodePage = 1252
    defer { TextDecoding.ansiCodePage = savedANSICodePage }

    // MARK: Parsing

    t.suite("Ini: basic parsing") {
        let doc = IniDocument.parse("""
        ; comment
        [Rainmeter]
        Update=1000
          AccurateText = 1
        [MeterClock]
        Meter=String
        Text="  quoted  "
        Text=second definition ignored
        ; Hidden=1
        NoEqualsLine
        [rainmeter]
        DynamicWindowSize=1
        """)
        t.equal(doc.sections.map(\.name), ["Rainmeter", "MeterClock"])
        t.equal(doc.section(named: "RAINMETER")?["update"], "1000")
        t.equal(doc.section(named: "Rainmeter")?["AccurateText"], "1")
        t.equal(IniDocument.parse("[R]\n  AccurateText = 1  \t").section(named: "R")?["accuratetext"], "1")
        // Manual (@Include page): "If both are in the actual .ini file, the second one is entirely ignored."
        t.equal(doc.section(named: "Rainmeter")?["DynamicWindowSize"], nil)
        t.equal(doc.section(named: "MeterClock")?["text"], "  quoted  ")
        t.equal(doc.section(named: "MeterClock")?["Hidden"], nil)
        t.equal(doc.section(named: "MeterClock")?.keys, ["Meter", "Text"])
    }

    t.suite("Ini: manual skin example") {
        // docs.rainmeter.net/manual/getting-started/skin-anatomy/
        let doc = IniDocument.parse("""
        [Rainmeter]
        Update=1000

        [MeasureCPU]
        Measure=CPU

        [MeterCPU]
        Meter=String
        MeasureName=MeasureCPU
        """)
        t.equal(doc.sections.map(\.name), ["Rainmeter", "MeasureCPU", "MeterCPU"])
        t.equal(doc.section(named: "MeterCPU")?["MeasureName"], "MeasureCPU")
        let time = IniDocument.parse("[MeasureDateTime]\nMeasure=Time\nFormat=%A, %B %#d, %Y %#I:%M %p")
        t.equal(time.section(named: "MeasureDateTime")?["Format"], "%A, %B %#d, %Y %#I:%M %p")
    }

    t.suite("Ini: line endings and values with =") {
        let doc = IniDocument.parse("[A]\r\nKey=a=b\r\nK2=\r[B]\nX=1")
        t.equal(doc.section(named: "A")?["Key"], "a=b")
        t.equal(doc.section(named: "A")?["K2"], "")
        t.equal(doc.section(named: "B")?["X"], "1")
        // Mixed endings, blank lines made of CR/LF only, trailing terminator.
        let mixed = IniDocument.parse("\n\r\n\r[S]\r\n\rA=1\n\nB=2\r\n")
        t.equal(mixed.section(named: "S")?.entries, [IniEntry(key: "A", value: "1"), IniEntry(key: "B", value: "2")])
        // Unicode line/paragraph separators and NEL are not line breaks in an INI file.
        let seps = IniDocument.parse("[S]\nText=a\u{2028}b\u{85}c\u{2029}d")
        t.equal(seps.section(named: "S")?["Text"], "a\u{2028}b\u{85}c\u{2029}d")
    }

    t.suite("Ini: comments") {
        let doc = IniDocument.parse("""
        ;[Hidden]
        [S]
        ;Key=1
           ; Indented=2
        \t;Tab=3
        Text=a ; not a comment
        Color=255,255,255 ;trailing
        #NotAComment=4
        Path=C:\\a;b
        """)
        t.equal(doc.sections.map(\.name), ["S"])
        let s = doc.section(named: "S")
        t.equal(s?["Key"], nil)
        t.equal(s?["Indented"], nil)
        t.equal(s?["Tab"], nil)
        // "there are no inline comments"
        t.equal(s?["Text"], "a ; not a comment")
        t.equal(s?["Color"], "255,255,255 ;trailing")
        t.equal(s?["#NotAComment"], "4")
        t.equal(s?["Path"], "C:\\a;b")
    }

    t.suite("Ini: whitespace trimming") {
        let doc = IniDocument.parse("[S]\n\t Key \t=\t value with  inner   spaces \t\n Empty =   \nIdeo=\u{3000}\nNbsp=\u{00A0}x\u{00A0}")
        let s = doc.section(named: "S")
        t.equal(s?["Key"], "value with  inner   spaces")
        t.equal(s?["Empty"], "")
        // Only spaces/tabs are trimmed; other Unicode spaces are content.
        t.equal(s?["Ideo"], "\u{3000}")
        t.equal(s?["Nbsp"], "\u{00A0}x\u{00A0}")
        t.equal(s?.keys, ["Key", "Empty", "Ideo", "Nbsp"])
    }

    t.suite("Ini: quote stripping") {
        let doc = IniDocument.parse("""
        [S]
        A="Hello World"
        B='single'
        C="mixed'
        D="
        E=""
        F=''
        G=" padded "
        H="a":"b","c":"d"
        I='a':"b"
        J=\"""magic\"""
        K=say "hi" now
        L=  "spaced outside"
        M="unbalanced
        N=trailing"
        O="a" and "b"
        """)
        let s = doc.section(named: "S")
        t.equal(s?["A"], "Hello World")
        t.equal(s?["B"], "single")
        t.equal(s?["C"], "\"mixed'")
        t.equal(s?["D"], "\"")
        t.equal(s?["E"], "")
        t.equal(s?["F"], "")
        t.equal(s?["G"], " padded ")
        // One pair around the whole value is removed, even when it does not "belong together".
        t.equal(s?["H"], "a\":\"b\",\"c\":\"d")
        t.equal(s?["I"], "'a':\"b\"")
        t.equal(s?["J"], "\"\"magic\"\"")
        t.equal(s?["K"], "say \"hi\" now")
        t.equal(s?["L"], "spaced outside")
        t.equal(s?["M"], "\"unbalanced")
        t.equal(s?["N"], "trailing\"")
        t.equal(s?["O"], "a\" and \"b")
        t.equal(IniDocument.unquote("\"x\""), "x")
        // Quotes are recognised after trimming, and blanks inside them are kept.
        let padded = IniDocument.parse("[S]\nL=  \"spaced outside\"  \t\nP=\t' in '\t\n")
        t.equal(padded.section(named: "S")?["L"], "spaced outside")
        t.equal(padded.section(named: "S")?["P"], " in ")
    }

    t.suite("Ini: duplicate keys and sections") {
        let doc = IniDocument.parse("""
        [Variables]
        Color=1
        COLOR=2
        color=3
        Other=a
        [Meter]
        X=1
        [VARIABLES]
        Color=9
        NewKey=only in duplicate
        [meter]
        X=2
        [Variables]
        Third=3
        """)
        t.equal(doc.sections.map(\.name), ["Variables", "Meter"])
        t.equal(doc.section(named: "variables")?["Color"], "1")
        t.equal(doc.section(named: "variables")?["NewKey"], nil)
        t.equal(doc.section(named: "variables")?["Third"], nil)
        t.equal(doc.section(named: "variables")?.keys, ["Color", "Other"])
        t.equal(doc.section(named: "METER")?["x"], "1")
        t.equal(doc.indexOfSection(named: "meter"), 1)
        t.equal(doc.indexOfSection(named: "missing"), nil)
    }

    t.suite("Ini: keys before any section, odd lines") {
        let doc = IniDocument.parse("""
        Orphan=1
        @Include=x.inc
        [S]
        =no key
          = also no key
        JustText
        Key=v
        """)
        t.equal(doc.sections.map(\.name), ["S"])
        t.equal(doc.section(named: "S")?.entries, [IniEntry(key: "Key", value: "v")])
        let raw = IniSyntax.parseFile("Orphan=1\n@Include=x.inc\n[S]\nK=v")
        t.equal(raw.entriesBeforeFirstSection.map(\.key), ["Orphan", "@Include"])
    }

    t.suite("Ini: section headers") {
        let doc = IniDocument.parse("""
        [ Spaced ]
        A=1
          [Indented]
        B=2
        [Trailing] junk ; here
        C=3
        [Meter Clock]
        D=4
        [Unterminated
        E=5
        []
        Lost=1
        [   ]
        AlsoLost=1
        [Name]]
        F=6
        [Ünïcødé]
        G=7
        """)
        t.equal(doc.sections.map(\.name), ["Spaced", "Indented", "Trailing", "Meter Clock", "Unterminated", "Name", "Ünïcødé"])
        t.equal(doc.section(named: "spaced")?["A"], "1")
        t.equal(doc.section(named: "Indented")?["B"], "2")
        t.equal(doc.section(named: "Trailing")?["C"], "3")
        t.equal(doc.section(named: "meter clock")?["D"], "4")
        t.equal(doc.section(named: "Unterminated")?["E"], "5")
        t.equal(doc.section(named: "Unterminated")?["Lost"], nil)
        t.equal(doc.section(named: "Name")?["F"], "6")
        t.equal(doc.section(named: "ÜNÏCØDÉ")?["g"], "7")
    }

    t.suite("Ini: BOM and odd characters in text") {
        let doc = IniDocument.parse("\u{FEFF}[Rainmeter]\nUpdate=1000\n\u{FEFF}[Second]\nK=v")
        t.equal(doc.sections.map(\.name), ["Rainmeter", "Second"])
        t.equal(doc.section(named: "Rainmeter")?["Update"], "1000")
        // A combining mark right after "=" or "]" does not hide the separator.
        let combining = IniDocument.parse("[S]\u{301}\nKey=\u{301}x")
        t.equal(combining.sections.first?.name, "S")
        t.equal(combining.section(named: "S")?["Key"], "\u{301}x")
        // NUL padding and control characters do not break parsing.
        let nul = IniDocument.parse("[S]\nK=v\n\0\0\0")
        t.equal(nul.section(named: "S")?.entries, [IniEntry(key: "K", value: "v")])
        t.equal(IniDocument.parse("").sections, [])
        t.equal(IniDocument.parse("\n\n;\n[").sections, [])
    }

    t.suite("Ini: very long lines and many keys") {
        let long = String(repeating: "abc", count: 200_000)
        let doc = IniDocument.parse("[S]\nLong=\(long)\n" + "[" + String(repeating: "N", count: 10_000) + "]\nK=1")
        t.equal(doc.section(named: "S")?["Long"]?.count, 600_000)
        t.equal(doc.sections.count, 2)
        var text = "[Big]\n"
        for i in 0..<20_000 { text += "Key\(i)=\(i)\nkey\(i)=dup\n" }
        let start = Date()
        let big = IniDocument.parse(text)
        t.check(Date().timeIntervalSince(start) < 5, "20k keys parsed in reasonable time")
        t.equal(big.section(named: "Big")?.entries.count, 20_000)
        t.equal(big.section(named: "Big")?["KEY19999"], "19999")
    }

    t.suite("Ini: section API") {
        var s = IniSection(name: "S", entries: [IniEntry(key: "FontSize", value: "10")])
        t.equal(s.value(forKey: "fontsize"), "10")
        t.equal(s["FONTSIZE"], "10")
        s.setValue("12", forKey: "FONTSIZE")
        t.equal(s.entries, [IniEntry(key: "FontSize", value: "12")])
        s.setValue("Arial", forKey: "FontFace")
        t.equal(s.keys, ["FontSize", "FontFace"])
        s.removeValue(forKey: "fontsize")
        t.equal(s.keys, ["FontFace"])
        t.check(IniSyntax.namesEqual("MeterÄ", "meterä"))
        t.check(!IniSyntax.namesEqual("Meter1", "Meter2"))
        t.check(!IniSyntax.namesEqual("A", "AB"))
        t.check(!IniSyntax.namesEqual("@", "`"), "non-letters differing by 0x20 are different")
        t.check(!IniSyntax.namesEqual("[", "{"))
        t.check(IniSyntax.isIncludeKey("@Include"))
        t.check(IniSyntax.isIncludeKey("@include2"))
        t.check(IniSyntax.isIncludeKey("@INCLUDEVariables"))
        t.check(!IniSyntax.isIncludeKey("Include"))
        t.check(!IniSyntax.isIncludeKey("@Includ"))
        t.check(!IniSyntax.isIncludeKey(" @Include"))
    }

    // MARK: Decoding

    t.suite("Ini: text decoding") {
        let text = "[A]\nK=中文 ✓"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(text.data(using: .utf16LittleEndian)!)
        t.equal(TextDecoding.decode(utf16), text)
        var utf8bom = Data([0xEF, 0xBB, 0xBF])
        utf8bom.append(text.data(using: .utf8)!)
        t.equal(TextDecoding.decode(utf8bom), text)
        t.equal(TextDecoding.decode(text.data(using: .utf8)!), text)
        t.equal(TextDecoding.decode("[A]\nK=v".data(using: .utf16LittleEndian)!), "[A]\nK=v")
        t.equal(TextDecoding.decode(Data([0x63, 0x61, 0x66, 0xE9])), "café")
    }

    t.suite("Ini: encoding detection") {
        let text = "[Rainmeter]\r\nUpdate=1000\r\n[M]\r\nText=Grüße 中文 😀"
        let cases: [TextFileEncoding] = [
            .utf8(bom: true), .utf8(bom: false), .utf16LittleEndian(bom: true), .utf16BigEndian(bom: true),
            .utf16LittleEndian(bom: false), .utf16BigEndian(bom: false), .utf32LittleEndian, .utf32BigEndian,
        ]
        for encoding in cases {
            guard let data = TextDecoding.encode(text, as: encoding) else {
                t.check(false, "encode failed for \(encoding)")
                continue
            }
            let decoded = TextDecoding.decodeDetectingEncoding(data)
            t.equal(decoded.text, text, "\(encoding)")
            t.equal(decoded.encoding, encoding)
            t.equal(TextDecoding.encode(decoded.text, as: decoded.encoding), data, "round trip \(encoding)")
        }
        t.equal(iniBytes(TextDecoding.encode("A", as: .utf16LittleEndian(bom: true))!), [0xFF, 0xFE, 0x41, 0x00])
        t.equal(iniBytes(TextDecoding.encode("A", as: .utf16BigEndian(bom: true))!), [0xFE, 0xFF, 0x00, 0x41])
        t.equal(iniBytes(TextDecoding.encode("A", as: .utf8(bom: true))!), [0xEF, 0xBB, 0xBF, 0x41])
        t.equal(TextDecoding.decodeDetectingEncoding(Data()).encoding, .utf8(bom: false))
        t.equal(TextDecoding.decode(Data()), "")
        t.equal(TextDecoding.decode(Data([0xFF, 0xFE])), "")
        t.equal(TextDecoding.decode(Data([0xEF, 0xBB, 0xBF])), "")
    }

    t.suite("Ini: Windows-1252 decoding") {
        // é, €, curly quotes, and the undefined byte 0x81 all round-trip byte for byte.
        let bytes: [UInt8] = [0x5B, 0x53, 0x5D, 0x0A, 0x4B, 0x3D, 0xE9, 0x80, 0x93, 0x94, 0x81, 0x9D, 0xFF]
        let decoded = TextDecoding.decodeDetectingEncoding(Data(bytes))
        t.equal(decoded.encoding, .windows1252)
        t.equal(decoded.text, "[S]\nK=é€\u{201C}\u{201D}\u{81}\u{9D}ÿ")
        t.equal(TextDecoding.encode(decoded.text, as: .windows1252).map(iniBytes), bytes)
        t.equal(TextDecoding.encode("中", as: .windows1252), nil)
        t.equal(TextDecoding.encode("\u{80}", as: .windows1252), nil, "U+0080 is not a cp1252 character")
        t.equal(IniDocument.parse(decoded.text).section(named: "S")?["K"], "é€\u{201C}\u{201D}\u{81}\u{9D}ÿ")
    }

    t.suite("Ini: malformed encodings never lose the file") {
        // UTF-16 LE with a lone surrogate: Foundation's decoder would return nil for the whole file.
        var lone = Data([0xFF, 0xFE])
        lone.append("[S]\nK=".data(using: .utf16LittleEndian)!)
        lone.append(contentsOf: [0x00, 0xD8]) // lone high surrogate
        lone.append("x".data(using: .utf16LittleEndian)!)
        t.equal(TextDecoding.decode(lone), "[S]\nK=\u{FFFD}x")
        // Odd byte count: the dangling byte is dropped.
        var odd = Data([0xFF, 0xFE])
        odd.append("[S]".data(using: .utf16LittleEndian)!)
        odd.append(0x41)
        t.equal(TextDecoding.decode(odd), "[S]")
        // Invalid UTF-8 after a UTF-8 BOM is repaired, not dropped.
        t.equal(TextDecoding.decode(Data([0xEF, 0xBB, 0xBF, 0x41, 0xFF, 0x42])), "A\u{FFFD}B")
        // UTF-32 with an invalid scalar value.
        t.equal(TextDecoding.decode(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0, 0, 0, 0x00, 0xD8, 0, 0])), "A\u{FFFD}")
        // Random bytes never crash.
        var seed: UInt64 = 0x1234_5678
        for _ in 0..<200 {
            var bytes: [UInt8] = []
            for _ in 0..<(Int(seed % 64)) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bytes.append(UInt8(truncatingIfNeeded: seed >> 33))
            }
            let s = TextDecoding.decode(Data(bytes))
            _ = IniDocument.parse(s)
        }
        t.check(true)
    }

    t.suite("Ini: BOM-less UTF-16 heuristic") {
        // A BOM-less UTF-16 LE skin with some CJK text is still recognised.
        let text = "[Variables]\r\nName=中文字体\r\nSize=12\r\n"
        let le = TextDecoding.encode(text, as: .utf16LittleEndian(bom: false))!
        t.equal(TextDecoding.decodeDetectingEncoding(le).encoding, .utf16LittleEndian(bom: false))
        t.equal(TextDecoding.decode(le), text)
        // Plain ASCII/UTF-8 is not mistaken for UTF-16.
        t.equal(TextDecoding.decodeDetectingEncoding(Data("[A]\nK=v".utf8)).encoding, .utf8(bom: false))
        t.equal(TextDecoding.decodeDetectingEncoding(Data("ab".utf8)).encoding, .utf8(bom: false))
    }

    t.suite("Ini: reading files") {
        let dir = t.temporaryDirectory("ini-read")
        let url = dir.appendingPathComponent("Skin.ini")
        iniWrite("[S]\r\nK=Grüße", to: url, encoding: .utf16LittleEndian(bom: true))
        t.equal(iniRead(url), "[S]\r\nK=Grüße")
        let detected = try TextDecoding.readFileDetectingEncoding(at: url)
        t.equal(detected.encoding, .utf16LittleEndian(bom: true))
        t.throwsError("missing file") { _ = try TextDecoding.readFile(at: dir.appendingPathComponent("nope.ini")) }
        t.throwsError("directory") { _ = try TextDecoding.readFile(at: dir) }
    }

    // MARK: Writing (!WriteKeyValue)

    t.suite("Ini: writer updates an existing key") {
        let text = "; header comment\r\n[Variables]\r\n  FontSize = 12 \r\nfontsize=99\r\nColor=1\r\n\r\n[Other]\r\nFontSize=5\r\n"
        let out = try IniWriter.updating(text, value: "14", key: "FONTSIZE", section: "variables")
        t.equal(out, "; header comment\r\n[Variables]\r\n  FontSize = 14\r\nfontsize=99\r\nColor=1\r\n\r\n[Other]\r\nFontSize=5\r\n")
        t.equal(IniDocument.parse(out).section(named: "Variables")?["FontSize"], "14")
        // Commented-out keys are not matched.
        let commented = try IniWriter.updating("[S]\n;Key=old\nKey=cur\n", value: "new", key: "Key", section: "S")
        t.equal(commented, "[S]\n;Key=old\nKey=new\n")
        // The key only in a duplicate (ignored) section block is not the one a reader sees → added to the first block.
        let dup = try IniWriter.updating("[S]\nA=1\n[T]\n[S]\nB=2\n", value: "3", key: "B", section: "S")
        t.equal(dup, "[S]\nA=1\nB=3\n[T]\n[S]\nB=2\n")
        t.equal(IniDocument.parse(dup).section(named: "S")?["B"], "3")
        // Keys before the first section are not part of any section.
        let orphan = try IniWriter.updating("K=0\n[S]\nA=1\n", value: "1", key: "K", section: "S")
        t.equal(orphan, "K=0\n[S]\nA=1\nK=1\n")
        // Section headers with odd spacing match like the reader.
        let spaced = try IniWriter.updating("[ S ] junk\nA=1\n", value: "2", key: " A ", section: " s ")
        t.equal(spaced, "[ S ] junk\nA=2\n")
        // Empty value.
        t.equal(try IniWriter.updating("[S]\nA=1\n", value: "", key: "A", section: "S"), "[S]\nA=\n")
    }

    t.suite("Ini: writer appends keys and sections") {
        // New key goes after the last key of the section, before trailing blank lines/comments.
        let text = "[Variables]\nA=1\nB=2\n\n; --- meters ---\n[Meter]\nX=1\n"
        let out = try IniWriter.updating(text, value: "3", key: "C", section: "Variables")
        t.equal(out, "[Variables]\nA=1\nB=2\nC=3\n\n; --- meters ---\n[Meter]\nX=1\n")
        // Empty section: right after the header.
        t.equal(try IniWriter.updating("[S]\n\n[T]\n", value: "1", key: "K", section: "S"), "[S]\nK=1\n\n[T]\n")
        // Last section, file without final line break: stays without one.
        t.equal(try IniWriter.updating("[S]\nA=1", value: "2", key: "B", section: "S"), "[S]\nA=1\nB=2")
        t.equal(try IniWriter.updating("[S]\r\nA=1\r\n", value: "2", key: "B", section: "S"), "[S]\r\nA=1\r\nB=2\r\n")
        // Missing section: appended at the end of the file, separated by a blank line, same line endings.
        t.equal(try IniWriter.updating("[S]\r\nA=1\r\n", value: "v", key: "K", section: "New"),
                "[S]\r\nA=1\r\n\r\n[New]\r\nK=v\r\n")
        t.equal(try IniWriter.updating("[S]\nA=1", value: "v", key: "K", section: "New"), "[S]\nA=1\n\n[New]\nK=v\n")
        t.equal(try IniWriter.updating("[S]\nA=1\n\n", value: "v", key: "K", section: "New"), "[S]\nA=1\n\n[New]\nK=v\n")
        t.equal(try IniWriter.updating("", value: "v", key: "K", section: "New"), "[New]\r\nK=v\r\n")
        t.equal(try IniWriter.updating("[S]\rA=1\r", value: "2", key: "B", section: "S"), "[S]\rA=1\rB=2\r")
    }

    t.suite("Ini: writer value and name handling") {
        // Line breaks cannot be stored in a value.
        let nl = try IniWriter.updating("[S]\n", value: "a\nb\r\nc\rd", key: "K", section: "S")
        t.equal(nl, "[S]\nK=a b c d\n")
        // Leading/trailing blanks survive via quotes; the reader gets the exact value back.
        let padded = try IniWriter.updating("[S]\n", value: " - ", key: "Sep", section: "S")
        t.equal(padded, "[S]\nSep=\" - \"\n")
        t.equal(IniDocument.parse(padded).section(named: "S")?["Sep"], " - ")
        // Other values are written as given.
        t.equal(try IniWriter.updating("[S]\n", value: "\"a\":\"b\"", key: "Substitute", section: "S"),
                "[S]\nSubstitute=\"a\":\"b\"\n")
        t.throwsError("empty key") { _ = try IniWriter.updating("[S]\n", value: "1", key: "  ", section: "S") }
        t.throwsError("key with =") { _ = try IniWriter.updating("[S]\n", value: "1", key: "a=b", section: "S") }
        t.throwsError("key with newline") { _ = try IniWriter.updating("[S]\n", value: "1", key: "a\nb", section: "S") }
        t.throwsError("comment key") { _ = try IniWriter.updating("[S]\n", value: "1", key: ";a", section: "S") }
        t.throwsError("bracket key") { _ = try IniWriter.updating("[S]\n", value: "1", key: "[a", section: "S") }
        t.throwsError("empty section") { _ = try IniWriter.updating("[S]\n", value: "1", key: "K", section: "") }
        t.throwsError("section with ]") { _ = try IniWriter.updating("[S]\n", value: "1", key: "K", section: "a]b") }
        t.throwsError("section with newline") { _ = try IniWriter.updating("[S]\n", value: "1", key: "K", section: "a\rb") }
    }

    t.suite("Ini: writer preserves file encoding") {
        let dir = t.temporaryDirectory("ini-write")
        let encodings: [TextFileEncoding] = [
            .utf16LittleEndian(bom: true), .utf16BigEndian(bom: true), .utf8(bom: true), .utf8(bom: false),
            .utf16LittleEndian(bom: false), .utf32LittleEndian,
        ]
        for (n, encoding) in encodings.enumerated() {
            let url = dir.appendingPathComponent("f\(n).inc")
            iniWrite("; Grüße\r\n[Variables]\r\nName=old\r\n", to: url, encoding: encoding)
            try IniWriter.writeValue("中文 ✓", key: "Name", section: "Variables", fileURL: url)
            let data = try Data(contentsOf: url)
            let decoded = TextDecoding.decodeDetectingEncoding(data)
            t.equal(decoded.encoding, encoding, "encoding kept for \(encoding)")
            t.equal(decoded.text, "; Grüße\r\n[Variables]\r\nName=中文 ✓\r\n")
        }
        // Exact UTF-16 LE bytes.
        let utf16 = dir.appendingPathComponent("utf16.ini")
        iniWrite("[S]\r\nA=1\r\n", to: utf16, encoding: .utf16LittleEndian(bom: true))
        try IniWriter.writeValue("2", key: "A", section: "S", fileURL: utf16)
        t.equal(try Data(contentsOf: utf16), TextDecoding.encode("[S]\r\nA=2\r\n", as: .utf16LittleEndian(bom: true)))
        // Windows-1252 stays 1252 when possible (including the undefined byte 0x81)… (the ANSI code page is pinned to
        // 1252 for this suite; E9 81 would be a valid GBK character.)
        let ansi = dir.appendingPathComponent("ansi.ini")
        try Data([0x5B, 0x53, 0x5D, 0x0D, 0x0A, 0x41, 0x3D, 0xE9, 0x81, 0x0D, 0x0A]).write(to: ansi)
        try IniWriter.writeValue("€", key: "B", section: "S", fileURL: ansi)
        t.equal(iniBytes(try Data(contentsOf: ansi)),
                [0x5B, 0x53, 0x5D, 0x0D, 0x0A, 0x41, 0x3D, 0xE9, 0x81, 0x0D, 0x0A, 0x42, 0x3D, 0x80, 0x0D, 0x0A])
        // …and becomes UTF-16 LE with BOM when the new value needs it.
        try IniWriter.writeValue("中", key: "B", section: "S", fileURL: ansi)
        let upgraded = TextDecoding.decodeDetectingEncoding(try Data(contentsOf: ansi))
        t.equal(upgraded.encoding, .utf16LittleEndian(bom: true))
        t.equal(upgraded.text, "[S]\r\nA=é\u{81}\r\nB=中\r\n")
    }

    t.suite("Ini: writer file handling") {
        let dir = t.temporaryDirectory("ini-write-files")
        t.throwsError("missing file") {
            try IniWriter.writeValue("1", key: "K", section: "S", fileURL: dir.appendingPathComponent("missing.ini"))
        }
        t.throwsError("directory") { try IniWriter.writeValue("1", key: "K", section: "S", fileURL: dir) }
        do {
            try IniWriter.writeValue("1", key: "K", section: "S", fileURL: dir.appendingPathComponent("missing.ini"))
        } catch let error as IniWriterError {
            t.check(error.description.contains("missing.ini"))
        }
        // Unchanged content: the file is not rewritten.
        let same = dir.appendingPathComponent("same.ini")
        iniWrite("[S]\nK=1\n", to: same)
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: same.path)
        try IniWriter.writeValue("1", key: "K", section: "S", fileURL: same)
        let mtime = try FileManager.default.attributesOfItem(atPath: same.path)[.modificationDate] as? Date
        t.equal(mtime, old)
        // A symlink is followed: the target changes, the link stays a link.
        let real = dir.appendingPathComponent("real.inc")
        let link = dir.appendingPathComponent("link.inc")
        iniWrite("[Variables]\nA=1\n", to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try IniWriter.writeValue("2", key: "A", section: "Variables", fileURL: link)
        t.equal(iniRead(real), "[Variables]\nA=2\n")
        t.equal(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        // Round trip through the reader.
        try IniWriter.writeValue("  spaced  ", key: "Pad", section: "New Section", fileURL: real)
        let doc = IniDocument.parse(iniRead(real))
        t.equal(doc.section(named: "new section")?["pad"], "  spaced  ")
        t.equal(doc.section(named: "Variables")?["A"], "2")
    }

    t.suite("Ini: writer path allowance") {
        let dir = t.temporaryDirectory("ini-allowed")
        let skins = dir.appendingPathComponent("Skins", isDirectory: true)
        let settings = dir.appendingPathComponent("Settings", isDirectory: true)
        try FileManager.default.createDirectory(at: skins.appendingPathComponent("Suite"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let inside = skins.appendingPathComponent("Suite/Skin.ini")
        iniWrite("[S]\n", to: inside)
        t.check(IniWriter.isPathAllowed(inside, roots: [skins, settings]))
        t.check(IniWriter.isPathAllowed(settings.appendingPathComponent("x.ini"), roots: [skins, settings]))
        t.check(!IniWriter.isPathAllowed(dir.appendingPathComponent("outside.ini"), roots: [skins, settings]))
        t.check(!IniWriter.isPathAllowed(skins.appendingPathComponent("../outside.ini"), roots: [skins]))
        t.check(!IniWriter.isPathAllowed(dir.appendingPathComponent("SkinsEvil/x.ini"), roots: [skins]))
        t.check(!IniWriter.isPathAllowed(inside, roots: []))
        // A symlink inside the skins folder that points outside is not allowed.
        let outside = dir.appendingPathComponent("outside.ini")
        iniWrite("[S]\n", to: outside)
        let sneaky = skins.appendingPathComponent("Suite/sneaky.ini")
        try FileManager.default.createSymbolicLink(at: sneaky, withDestinationURL: outside)
        t.check(!IniWriter.isPathAllowed(sneaky, roots: [skins]))
    }
    // MARK: Review: manual examples, encodings, writer hardening

    t.suite("Ini: manual examples (Skins, Option Types, String, Variables, Substitute pages)") {
        // docs.rainmeter.net/manual/skins/option-types/ — the example lines, as a skin author writes them.
        let doc = IniDocument.parse("""
        [S]
        ; The following lines are equivalent:
        FontSize=(40 + 2)
        FontSize2=(2 > 1 ? 42 : 666)
        ImageName=..\\lolcat.png
        ImageName2=#@#Images\\lolcat.png
        SolidColor=255,0,0,255
        SolidColor2=(200 + 55),(2 - 2),0
        LeftMouseUpAction=[!SetVariable SomeVariable "I think, therefore I am"]
        LeftMouseUpAction2=[!Log \"""Bob said "hello" to Susan\"""]
        LeftMouseUpAction3=["C:\\Windows\\Notepad.exe" MyFile.txt]
        LeftMouseUpAction4=!SetOption SomeMeter FontSize #*VarName*#
        """)
        let s = doc.section(named: "S")
        t.equal(s?["FontSize"], "(40 + 2)")
        t.equal(s?["FontSize2"], "(2 > 1 ? 42 : 666)")
        t.equal(s?["ImageName"], "..\\lolcat.png")
        t.equal(s?["ImageName2"], "#@#Images\\lolcat.png")
        t.equal(s?["SolidColor2"], "(200 + 55),(2 - 2),0")
        t.equal(s?["LeftMouseUpAction"], "[!SetVariable SomeVariable \"I think, therefore I am\"]")
        t.equal(s?["LeftMouseUpAction2"], "[!Log \"\"\"Bob said \"hello\" to Susan\"\"\"]")
        t.equal(s?["LeftMouseUpAction3"], "[\"C:\\Windows\\Notepad.exe\" MyFile.txt]")
        t.equal(s?["LeftMouseUpAction4"], "!SetOption SomeMeter FontSize #*VarName*#")
        t.equal(s?.keys.count, 10)
        // Skins page: "Quotes" are not needed … "Rainmeter will ignore quotes around option values." (Windows'
        // GetPrivateProfileString, whose semantics skins grew up with, documents the same for single quotes.)
        let quotes = IniDocument.parse("[S]\nA=\"Hello World\"\nB=Hello World\nC='Hello World'\n")
        t.equal(quotes.section(named: "S")?["A"], "Hello World")
        t.equal(quotes.section(named: "S")?["B"], "Hello World")
        t.equal(quotes.section(named: "S")?["C"], "Hello World")
        // String meter, TrailingSpaces: Text="        This has leading and trailing spaces        "
        let padded = IniDocument.parse("[M]\nText=\"        This has leading and trailing spaces        \"\n")
        t.equal(padded.section(named: "M")?["Text"], "        This has leading and trailing spaces        ")
        // Substitute page: mismatched quote styles survive (the outer characters differ, so nothing is stripped).
        let sub = IniDocument.parse("[M]\nSubstitute='\"':\"double quote\"\nSubstitute2=\"None\":'\"'\n")
        t.equal(sub.section(named: "M")?["Substitute"], "'\"':\"double quote\"")
        t.equal(sub.section(named: "M")?["Substitute2"], "\"None\":'\"'")
        // Variables page.
        let vars = IniDocument.parse("[Variables]\nMyVar1=rainmeter\nMyVar2=https://www.#MyVar1#.net/\nRed=255\n")
        t.equal(vars.section(named: "Variables")?["MyVar2"], "https://www.#MyVar1#.net/")
        // Skin anatomy: measure names may use Unicode letters and non-math punctuation.
        let names = IniDocument.parse("[Mesure_Température!]\nMeasure=CPU\n[测量]\nMeasure=Time\n")
        t.equal(names.sections.map(\.name), ["Mesure_Température!", "测量"])
        t.equal(names.section(named: "MESURE_TEMPÉRATURE!")?["measure"], "CPU")
    }

    t.suite("Ini: ANSI files use the code page of the language (like the Windows locale)") {
        // "Unicode in Rainmeter": ANSI extended characters depend on the Windows code page of the locale.
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["zh-Hans-SG"]), 936)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["zh-Hans-CN", "en-US"]), 936)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["zh-Hant-TW"]), 950)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["zh-HK"]), 950)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["zh"]), 936)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["ja-JP"]), 932)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["ko"]), 949)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["ru-RU"]), 1251)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["sr"]), 1251)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["sr-Latn"]), 1250)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["pl"]), 1250)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["el"]), 1253)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["tr"]), 1254)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["he"]), 1255)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["ar"]), 1256)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["lt"]), 1257)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["vi"]), 1258)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["th"]), 874)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["en-US"]), 1252)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["de_DE"]), 1252)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: []), 1252)
        t.equal(TextDecoding.defaultANSICodePage(preferredLanguages: ["", "-"]), 1252)

        // GBK (cp936): "FontFace=微软雅黑" / "Text=中文 路径\x.png".
        let gbk: [UInt8] = [0x5B, 0x4D, 0x5D, 0x0D, 0x0A,
                            0x46, 0x6F, 0x6E, 0x74, 0x46, 0x61, 0x63, 0x65, 0x3D, 0xCE, 0xA2, 0xC8, 0xED, 0xD1, 0xC5,
                            0xBA, 0xDA, 0x0D, 0x0A, 0x54, 0x65, 0x78, 0x74, 0x3D, 0xD6, 0xD0, 0xCE, 0xC4, 0x20, 0xC2,
                            0xB7, 0xBE, 0xB6, 0x5C, 0x78, 0x2E, 0x70, 0x6E, 0x67]
        let zh = TextDecoding.decodeDetectingEncoding(Data(gbk), ansiCodePage: 936)
        t.equal(zh.encoding, .windowsCodePage(936))
        t.equal(zh.text, "[M]\r\nFontFace=微软雅黑\r\nText=中文 路径\\x.png")
        t.equal(TextDecoding.encode(zh.text, as: zh.encoding).map(iniBytes), gbk, "lossless round trip")
        t.equal(IniDocument.parse(zh.text).section(named: "M")?["FontFace"], "微软雅黑")
        // The same bytes with a Western locale: Windows-1252, as Rainmeter on a US Windows would read them.
        t.equal(TextDecoding.decodeDetectingEncoding(Data(gbk), ansiCodePage: 1252).encoding, .windows1252)
        // Not valid in the code page → lossless Windows-1252 fallback (never an empty or truncated file).
        let invalid: [UInt8] = [0x5B, 0x53, 0x5D, 0x0A, 0x4B, 0x3D, 0x63, 0x61, 0x66, 0xE9, 0x0A, 0xFF]
        let fallback = TextDecoding.decodeDetectingEncoding(Data(invalid), ansiCodePage: 936)
        t.equal(fallback.encoding, .windows1252)
        t.equal(fallback.text, "[S]\nK=café\nÿ")
        // Shift-JIS keeps 0x5C as a backslash (paths!), also as the second byte of a character ("表" = 95 5C).
        let sjis: [UInt8] = [0x5B, 0x53, 0x5D, 0x0A, 0x50, 0x3D, 0x95, 0x5C, 0x5C, 0x61, 0x2E, 0x70, 0x6E, 0x67]
        let ja = TextDecoding.decodeDetectingEncoding(Data(sjis), ansiCodePage: 932)
        t.equal(ja.encoding, .windowsCodePage(932))
        t.equal(ja.text, "[S]\nP=表\\a.png")
        // Big5 and Cyrillic.
        let big5 = TextDecoding.decodeDetectingEncoding(Data([0x4B, 0x3D, 0xA4, 0xA4, 0xA4, 0xE5]), ansiCodePage: 950)
        t.equal(big5.text, "K=中文")
        let cyr = TextDecoding.decodeDetectingEncoding(Data([0x4B, 0x3D, 0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]),
                                                       ansiCodePage: 1251)
        t.equal(cyr.text, "K=Привет")
        t.equal(cyr.encoding, .windowsCodePage(1251))
        // Unicode files are unaffected by the code page.
        let utf16 = TextDecoding.encode("[S]\nK=Grüße", as: .utf16LittleEndian(bom: true))!
        t.equal(TextDecoding.decodeDetectingEncoding(utf16, ansiCodePage: 936).text, "[S]\nK=Grüße")
        t.equal(TextDecoding.decodeDetectingEncoding(Data("K=中文".utf8), ansiCodePage: 936).encoding, .utf8(bom: false))
        // Unknown code pages never crash.
        t.equal(TextDecoding.decodeDetectingEncoding(Data([0x41, 0xE9]), ansiCodePage: -5).text, "Aé")
        t.equal(TextDecoding.decodeDetectingEncoding(Data([0x41, 0xE9]), ansiCodePage: 99_999_999_999).text, "Aé")
        t.equal(TextDecoding.encode("x", as: .windowsCodePage(-1)), nil)
        // Code pages that do not keep ASCII as ASCII cannot hold INI syntax: refused, Windows-1252 is used.
        for codePage in [1200, 1201, 37, 500, 65001, 12000] {
            let r = TextDecoding.decodeDetectingEncoding(Data([0x5B, 0x53, 0x5D, 0x0A, 0x4B, 0x3D, 0xE9]), ansiCodePage: codePage)
            t.equal(r.encoding, .windows1252, "code page \(codePage)")
            t.equal(r.text, "[S]\nK=é", "code page \(codePage)")
            t.equal(TextDecoding.encode("K", as: .windowsCodePage(codePage)), nil, "code page \(codePage)")
        }
        t.equal(TextDecoding.encode("😀", as: .windowsCodePage(936)), nil)
        t.equal(TextDecoding.encode("é", as: .windowsCodePage(1252)).map(iniBytes), [0xE9])
        // The process-wide setting is what readFile/decode use (the core default is the deterministic 1252; the app
        // sets it from the language).
        let saved = TextDecoding.ansiCodePage
        TextDecoding.ansiCodePage = 936
        t.equal(TextDecoding.decode(Data(gbk)), zh.text)
        TextDecoding.ansiCodePage = saved
    }

    t.suite("Ini: writer keeps a GBK file GBK") {
        let saved = TextDecoding.ansiCodePage
        TextDecoding.ansiCodePage = 936
        defer { TextDecoding.ansiCodePage = saved }
        let dir = t.temporaryDirectory("ini-write-gbk")
        let url = dir.appendingPathComponent("Variables.inc")
        let original = TextDecoding.encode("; 设置\r\n[Variables]\r\nFont=宋体\r\n", as: .windowsCodePage(936))!
        try original.write(to: url)
        try IniWriter.writeValue("微软雅黑", key: "Font", section: "Variables", fileURL: url)
        let after = TextDecoding.decodeDetectingEncoding(try Data(contentsOf: url))
        t.equal(after.encoding, .windowsCodePage(936))
        t.equal(after.text, "; 设置\r\n[Variables]\r\nFont=微软雅黑\r\n")
        // A value GBK cannot hold converts the file to UTF-16 LE with BOM (nothing is lost).
        try IniWriter.writeValue("😀", key: "Icon", section: "Variables", fileURL: url)
        let upgraded = TextDecoding.decodeDetectingEncoding(try Data(contentsOf: url))
        t.equal(upgraded.encoding, .utf16LittleEndian(bom: true))
        t.equal(upgraded.text, "; 设置\r\n[Variables]\r\nFont=微软雅黑\r\nIcon=😀\r\n")
    }

    t.suite("Ini: writer validates names per Unicode scalar") {
        // A combining mark after "=", "]", "[" or ";" forms one Character with it but not one scalar; the reader
        // splits by scalar, so such names would be read back as a different key/section, a header or a comment.
        t.throwsError("= + combining mark") { _ = try IniWriter.updating("[S]\n", value: "v", key: "a=\u{301}", section: "S") }
        t.throwsError("[ + combining mark") { _ = try IniWriter.updating("[S]\n", value: "v", key: "[\u{301}x", section: "S") }
        t.throwsError("; + combining mark") { _ = try IniWriter.updating("[S]\n", value: "v", key: ";\u{301}x", section: "S") }
        t.throwsError("] + combining mark") { _ = try IniWriter.updating("[S]\n", value: "v", key: "K", section: "A]\u{301}") }
        // Combining marks elsewhere are fine and round-trip.
        let ok = try IniWriter.updating("[S]\n", value: "v", key: "Cafe\u{301}", section: "Se\u{301}")
        t.equal(IniDocument.parse(ok).section(named: "Se\u{301}")?["Cafe\u{301}"], "v")
    }

    t.suite("Ini: writer writes changes String == would miss") {
        // String equality is canonical equivalence: "é" == "e\u{301}". The writer compares bytes instead.
        let dir = t.temporaryDirectory("ini-write-nfd")
        let url = dir.appendingPathComponent("x.inc")
        iniWrite("[S]\nK=\u{E9}\n", to: url)
        try IniWriter.writeValue("e\u{301}", key: "K", section: "S", fileURL: url)
        t.equal(iniBytes(try Data(contentsOf: url)), iniBytes(Data("[S]\nK=e\u{301}\n".utf8)))
    }

    t.suite("Ini: writer value quoting") {
        // A value wrapped in quotes is written as given, so the reader strips them like a hand-written Key="x"
        // (Rainmeter's own behaviour; skins store Text="  padded  " this way).
        let quoted = try IniWriter.updating("[S]\n", value: "\"  padded  \"", key: "Text", section: "S")
        t.equal(quoted, "[S]\nText=\"  padded  \"\n")
        t.equal(IniDocument.parse(quoted).section(named: "S")?["Text"], "  padded  ")
        // Blank-edged values are protected by quotes; quotes inside survive.
        let inner = try IniWriter.updating("[S]\n", value: " say \"hi\" ", key: "T", section: "S")
        t.equal(IniDocument.parse(inner).section(named: "S")?["T"], " say \"hi\" ")
        // Tabs count as blanks too.
        let tab = try IniWriter.updating("[S]\n", value: "\tx", key: "T", section: "S")
        t.equal(IniDocument.parse(tab).section(named: "S")?["T"], "\tx")
    }

    t.suite("Ini: !WriteKeyValue manual and guide examples") {
        // Bangs page: !WriteKeyValue Variables MyFontName Arial "#@#Variables.inc"
        let dir = t.temporaryDirectory("ini-wkv")
        let resources = dir.appendingPathComponent("Skins/Suite/@Resources", isDirectory: true)
        let config = dir.appendingPathComponent("Skins/Suite/Config", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.appendingPathComponent("Pages"), withIntermediateDirectories: true)
        let variables = resources.appendingPathComponent("Variables.inc")
        iniWrite("[Variables]\r\nMyFontName=Segoe UI\r\n", to: variables, encoding: .utf16LittleEndian(bom: true))
        try IniWriter.writeValue("Arial", key: "MyFontName", section: "Variables", fileURL: variables)
        t.equal(iniRead(variables), "[Variables]\r\nMyFontName=Arial\r\n")
        // @Include Guide, pages: [!WriteKeyValue Variables Page 2][!Refresh] with @include=Pages\PageNum#Page#.inc
        let skin = config.appendingPathComponent("Skin.ini")
        iniWrite("[Variables]\nPage=1\n@include=Pages\\PageNum#Page#.inc\n", to: skin)
        iniWrite("[PageMeter]\nText=one\n", to: config.appendingPathComponent("Pages/PageNum1.inc"))
        iniWrite("[PageMeter]\nText=two\n", to: config.appendingPathComponent("Pages/PageNum2.inc"))
        let expand: (String, [String: String]) -> String = { raw, vars in
            raw.replacingOccurrences(of: "#Page#", with: vars["page"] ?? "#Page#")
        }
        t.equal(try SkinFileLoader.load(url: skin, expandVariables: expand).document.section(named: "PageMeter")?["Text"], "one")
        try IniWriter.writeValue("2", key: "Page", section: "Variables", fileURL: skin)
        t.equal(try SkinFileLoader.load(url: skin, expandVariables: expand).document.section(named: "PageMeter")?["Text"], "two")
        t.check(IniWriter.isPathAllowed(variables, roots: [dir.appendingPathComponent("Skins")]))
    }

    t.suite("Ini: writer round trip (randomised)") {
        // Property: after updating(), the reader sees exactly the new value and nothing else changed.
        var seed: UInt64 = 42
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let tokens = ["[", "]", "=", ";", "\n", "\r", "\r\n", " ", "\t", "a", "B", "S", "K", "\"", "'", "é", "e\u{301}",
                      "\u{301}", "\u{FEFF}", "[S]\n", "[s]\r\n", "K=1\n", "k = 2\r\n", ";K=3\n", "[T]\n", "\n\n"]
        let names = ["S", "s", " S ", "K", "k", "T", "a", "B", "é", "e\u{301}", "[x", "x;y", "@Include"]
        let values = ["", "v", " v ", "\"q\"", "'q'", "a\nb", "=", ";", "[x]", "\t", "\"", "é"]
        var failures = 0
        var written = 0
        for _ in 0..<20_000 {
            var text = ""
            for _ in 0..<rnd(30) { text += tokens[rnd(tokens.count)] }
            let key = names[rnd(names.count)], section = names[rnd(names.count)], value = values[rnd(values.count)]
            guard let out = try? IniWriter.updating(text, value: value, key: key, section: section) else { continue }
            written += 1
            var expected = value.replacingOccurrences(of: "\n", with: " ")
            if let f = expected.unicodeScalars.first, let l = expected.unicodeScalars.last,
               f == " " || f == "\t" || l == " " || l == "\t" {
                // written in protective quotes → read back unchanged
            } else {
                expected = String(IniSyntax.unquote(Substring(expected)))
            }
            var expectedDoc = IniDocument.parse(text)
            let s = IniSyntax.trim(section), k = IniSyntax.trim(key)
            if let i = expectedDoc.indexOfSection(named: s) {
                expectedDoc.sections[i].setValue(expected, forKey: k)
            } else {
                expectedDoc.sections.append(IniSection(name: s, entries: [IniEntry(key: k, value: expected)]))
            }
            if IniDocument.parse(out) != expectedDoc {
                failures += 1
                if failures <= 3 { t.check(false, "text \(text.debugDescription) key \(key) section \(section) → \(out.debugDescription)") }
            }
        }
        t.equal(failures, 0)
        t.check(written > 10_000, "most random cases are valid writes (\(written))")
    }

    t.suite("Ini: parsing stays linear") {
        // One huge section followed by many small ones (the per-section duplicate-key set is reset each time).
        var text = "[Big]\n"
        for i in 0..<200_000 { text += "K\(i)=1\n" }
        for i in 0..<100_000 { text += "[S\(i)]\nA=1\n" }
        // Quadratic behaviour on 400k lines takes hours; linear takes under a second on a fast Mac and a few seconds
        // on a CI runner (Intel, debug build). The limits only tell the two apart.
        let limit: TimeInterval = 60
        let start = Date()
        let doc = IniDocument.parse(text)
        t.check(Date().timeIntervalSince(start) < limit, "parsed in \(Date().timeIntervalSince(start)) s")
        t.equal(doc.sections.count, 100_001)
        t.equal(doc.sections.first?.entries.count, 200_000)
        // A 300k-key file: the writer is linear too.
        let writeStart = Date()
        let out = try IniWriter.updating(text, value: "x", key: "New", section: "S99999")
        t.check(Date().timeIntervalSince(writeStart) < limit, "written in \(Date().timeIntervalSince(writeStart)) s")
        t.check(out.hasSuffix("[S99999]\nA=1\nNew=x\n"))
    }
}
