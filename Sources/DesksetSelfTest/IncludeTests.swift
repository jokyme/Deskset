import Foundation
@testable import DesksetCore

/// A skin folder layout in a temp directory: Skins/<Suite>/<Config>/Skin.ini with Skins/<Suite>/@Resources.
private struct IncludeFixture {
    let root: URL
    let suite: URL
    let skinFolder: URL
    let resources: URL

    init(_ t: TestRunner, _ label: String) {
        root = t.temporaryDirectory("include-\(label)")
        suite = root.appendingPathComponent("Skins/Suite", isDirectory: true)
        skinFolder = suite.appendingPathComponent("Config", isDirectory: true)
        resources = suite.appendingPathComponent("@Resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: skinFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    }

    /// Writes `text` at a path relative to the skin folder (may contain `..`).
    @discardableResult
    func write(_ relativePath: String, _ text: String, encoding: TextFileEncoding = .utf8(bom: false)) -> URL {
        let url = URL(fileURLWithPath: skinFolder.path + "/" + relativePath).standardizedFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (TextDecoding.encode(text, as: encoding) ?? Data(text.utf8)).write(to: url)
        return url
    }

    var mainURL: URL { skinFolder.appendingPathComponent("Skin.ini") }

    /// Stand-in for the engine's variable expansion: builtins + [Variables] read so far, simple `#Name#` replacement.
    func expander(extra: [String: String] = [:],
                  log: ((String, [String: String]) -> Void)? = nil) -> (String, [String: String]) -> String {
        let builtins: [String: String] = [
            "@": resources.path + "/",
            "currentpath": skinFolder.path + "/",
            "rootconfigpath": suite.path + "/",
        ].merging(extra) { $1 }
        return { raw, variables in
            log?(raw, variables)
            var out = raw
            for _ in 0..<5 {
                var changed = false
                for (name, value) in builtins.merging(variables, uniquingKeysWith: { b, _ in b }) {
                    let token = "#\(name)#"
                    if out.range(of: token, options: .caseInsensitive) != nil {
                        out = out.replacingOccurrences(of: token, with: value, options: .caseInsensitive)
                        changed = true
                    }
                }
                if !changed { break }
            }
            return out
        }
    }

    func load(extra: [String: String] = [:]) throws -> LoadedIniFile {
        try SkinFileLoader.load(url: mainURL, expandVariables: expander(extra: extra))
    }
}

private func names(_ file: LoadedIniFile) -> [String] { file.document.sections.map(\.name) }

private func value(_ file: LoadedIniFile, _ section: String, _ key: String) -> String? {
    file.document.section(named: section)?[key]
}

private func samePath(_ a: [URL], _ b: [URL]) -> Bool {
    a.map { $0.resolvingSymlinksInPath().path } == b.map { $0.resolvingSymlinksInPath().path }
}

func runIncludeTests(_ t: TestRunner) {
    // Legacy ANSI files decode with `TextDecoding.ansiCodePage` (the app sets it from the Mac's language, like
    // Rainmeter with the Windows locale); pin the Western default so these suites never depend on the machine or on
    // other suites. Suites below that test other code pages set them explicitly.
    let savedANSICodePage = TextDecoding.ansiCodePage
    TextDecoding.ansiCodePage = 1252
    defer { TextDecoding.ansiCodePage = savedANSICodePage }

    t.suite("Include: manual example") {
        // docs.rainmeter.net/manual/skins/include-option/ — Example
        let f = IncludeFixture(t, "manual")
        let inc = f.write("IncludeFile.inc", "[Variables]\nColor=255,255,255,255\n")
        f.write("Skin.ini", """
        [Variables]
        Font=Arial
        @Include=IncludeFile.inc

        [SomeMeter]
        FontFace=#Font#
        FontColor=#Color#
        """)
        let loaded = try f.load()
        t.equal(names(loaded), ["Variables", "SomeMeter"])
        t.equal(loaded.document.section(named: "Variables")?.entries,
                [IniEntry(key: "Font", value: "Arial"), IniEntry(key: "Color", value: "255,255,255,255")])
        t.equal(value(loaded, "SomeMeter", "FontColor"), "#Color#")
        t.check(samePath(loaded.includedFiles, [inc]))
        t.equal(loaded.warnings, [])
    }

    t.suite("Include: guide example (placement and existing sections)") {
        // docs.rainmeter.net/tips/include-guide/ — "Understanding @include"
        let f = IncludeFixture(t, "guide")
        f.write("SomeFile.inc", """
        [Background]
        Meter=Image
        H=30
        W=40

        [String]
        Text=This Won't Work
        """)
        f.write("Skin.ini", """
        [Variables]
        @include=SomeFile.inc

        [Foreground]
        Meter=Image
        H=20
        W=30
        X=5r

        [String]
        Meter=String
        Text=This line will remain.
        """)
        let loaded = try f.load()
        // Background is placed before Foreground; String keeps its own place in the skin.
        t.equal(names(loaded), ["Variables", "Background", "Foreground", "String"])
        t.equal(value(loaded, "String", "Text"), "This line will remain.")
        t.equal(value(loaded, "String", "Meter"), "String")
        t.equal(value(loaded, "Background", "W"), "40")
        // The consumed @include key is not an option of [Variables].
        t.equal(loaded.document.section(named: "Variables")?.entries, [])
    }

    t.suite("Include: new sections go right after the including section") {
        let f = IncludeFixture(t, "placement")
        f.write("a.inc", "[A1]\nK=a1\n[A2]\nK=a2\n")
        f.write("b.inc", "[B1]\nK=b1\n")
        f.write("c.inc", "[C1]\nK=c1\n")
        f.write("Skin.ini", """
        [Rainmeter]
        Update=1000
        @Include=a.inc
        @Include2=b.inc
        [MeterOne]
        Meter=String
        @IncludeMore=c.inc
        [MeterTwo]
        Meter=String
        """)
        let loaded = try f.load()
        t.equal(names(loaded), ["Rainmeter", "A1", "A2", "B1", "MeterOne", "C1", "MeterTwo"])
        t.equal(value(loaded, "Rainmeter", "Update"), "1000")
        t.equal(value(loaded, "C1", "K"), "c1")
        t.equal(loaded.document.section(named: "MeterOne")?.keys, ["Meter"])
        t.equal(loaded.includedFiles.map(\.lastPathComponent), ["a.inc", "b.inc", "c.inc"])
    }

    t.suite("Include: later wins conflicts") {
        let f = IncludeFixture(t, "precedence")
        f.write("Settings.inc", """
        [Rainmeter]
        Update=500
        [Variables]
        Before=from include
        After=from include
        OnlyInc=inc
        [MeterLater]
        X=from include
        Y=from include
        [MeterNew]
        X=new
        """)
        f.write("Skin.ini", """
        [Rainmeter]
        Update=1000
        [Variables]
        Before=from skin
        @Include=Settings.inc
        After=from skin
        [MeterLater]
        X=from skin
        """)
        let loaded = try f.load()
        // [Rainmeter] of the skin is earlier than the include → the include's value wins.
        t.equal(value(loaded, "Rainmeter", "Update"), "500")
        // Keys before the @Include line are overridden, keys after it override.
        t.equal(value(loaded, "Variables", "Before"), "from include")
        t.equal(value(loaded, "Variables", "After"), "from skin")
        t.equal(value(loaded, "Variables", "OnlyInc"), "inc")
        // A section written after the include keeps its values; keys it lacks come from the include.
        t.equal(value(loaded, "MeterLater", "X"), "from skin")
        t.equal(value(loaded, "MeterLater", "Y"), "from include")
        t.equal(names(loaded), ["Rainmeter", "Variables", "MeterNew", "MeterLater"])
        // Overridden keys keep their position, new keys are appended in reading order.
        t.equal(loaded.document.section(named: "Variables")?.keys, ["Before", "After", "OnlyInc"])
        t.equal(loaded.document.section(named: "MeterLater")?.keys, ["X", "Y"])
    }

    t.suite("Include: duplicates within one file are ignored") {
        let f = IncludeFixture(t, "dups")
        f.write("x.inc", "[Variables]\nFromX=1\n[S]\nK=first\n[S]\nK=second\nExtra=1\n")
        f.write("y.inc", "[Y]\nK=y\n")
        f.write("Skin.ini", """
        [Variables]
        A=1
        A=2
        @Include=x.inc
        [Variables]
        B=ignored
        @Include=y.inc
        """)
        let loaded = try f.load()
        t.equal(value(loaded, "Variables", "A"), "1")
        t.equal(value(loaded, "Variables", "B"), nil)
        t.equal(value(loaded, "Variables", "FromX"), "1")
        t.equal(value(loaded, "S", "K"), "first")
        t.equal(value(loaded, "S", "Extra"), nil)
        // The @Include inside the ignored duplicate [Variables] block is not processed.
        t.equal(loaded.document.section(named: "Y"), nil)
        t.equal(loaded.includedFiles.map(\.lastPathComponent), ["x.inc"])
        // Within-file first-wins vs. across-file later-wins.
        let g = IncludeFixture(t, "dups2")
        g.write("inc.inc", "[Variables]\nA=2\n")
        g.write("Skin.ini", "[Variables]\nA=1\n@Include=inc.inc\nA=3\n")
        t.equal(value(try g.load(), "Variables", "A"), "2")
    }

    t.suite("Include: nested includes") {
        let f = IncludeFixture(t, "nested")
        f.write("../@Resources/Styles.inc", """
        [StyleA]
        FontSize=10
        @Include=#@#Colors.inc
        [StyleB]
        FontSize=12
        """)
        f.write("../@Resources/Colors.inc", "[Variables]\nColor=1,2,3\n[StyleColor]\nFontColor=#Color#\n")
        f.write("Skin.ini", """
        [Rainmeter]
        @Include=#@#Styles.inc
        [Variables]
        Color=9,9,9
        [Meter]
        MeterStyle=StyleA | StyleB
        """)
        let loaded = try f.load()
        t.equal(names(loaded), ["Rainmeter", "StyleA", "StyleColor", "StyleB", "Variables", "Meter"])
        // [Variables] of the skin comes after the include → the skin's value wins.
        t.equal(value(loaded, "Variables", "Color"), "9,9,9")
        t.equal(loaded.includedFiles.map(\.lastPathComponent), ["Styles.inc", "Colors.inc"])
        t.equal(loaded.warnings, [])

        // "the new contents are added within its own sections, immediately after the section where the statement
        // is made" — new sections from a nested include follow the including section of the included file.
        let g = IncludeFixture(t, "nested2")
        g.write("one.inc", "[X]\nK=1\n@Include=two.inc\n[Y]\nK=1\n")
        g.write("two.inc", "[Z]\nK=2\n[Y]\nK=from two\nL=2\n")
        g.write("Skin.ini", "[Variables]\n@Include=one.inc\n[Last]\nK=0\n")
        let nested = try g.load()
        t.equal(names(nested), ["Variables", "X", "Z", "Y", "Last"])
        // [Y] of one.inc already exists when two.inc is read; two.inc's [Y] comes earlier in the text → one.inc wins.
        t.equal(value(nested, "Y", "K"), "1")
        t.equal(value(nested, "Y", "L"), "2")
    }

    t.suite("Include: key names") {
        let f = IncludeFixture(t, "keys")
        for name in ["a", "b", "c", "d", "e"] { f.write("\(name).inc", "[Sec\(name.uppercased())]\nK=\(name)\n") }
        f.write("Skin.ini", """
        [Variables]
        @include=a.inc
        @INCLUDE2=b.inc
        @IncludeVariables=c.inc
        @Include_Meters=d.inc
        Include=e.inc
        @Includ=e.inc
        """)
        let loaded = try f.load()
        t.equal(names(loaded), ["Variables", "SecA", "SecB", "SecC", "SecD"])
        t.equal(loaded.document.section(named: "Variables")?.keys, ["Include", "@Includ"])
    }

    t.suite("Include: variables in include paths") {
        // Guide: "[Variables] Theme=SomeTheme / @include=#Theme#/SomeFile.inc" and the Pages example.
        let f = IncludeFixture(t, "vars")
        f.write("Dark/SomeFile.inc", "[Themed]\nName=dark\n")
        f.write("Pages/PageNum2.inc", "[Page]\nNumber=2\n")
        f.write("../@Resources/Vars.inc", "[Variables]\nSub=Dark\n")
        f.write("Late.inc", "[Late]\nOK=1\n")
        f.write("Skin.ini", """
        [Rainmeter]
        @IncludeLate=#LateName#.inc
        [Variables]
        Theme=Dark
        Page=2
        @include=#Theme#/SomeFile.inc
        @include2=Pages\\PageNum#Page#.inc
        @include3=#@#Vars.inc
        @include4=#Sub#\\SomeFile.inc
        LateName=Late
        """)
        var calls: [(String, [String: String])] = []
        let loaded = try SkinFileLoader.load(url: f.mainURL, expandVariables: f.expander(log: { calls.append(($0, $1)) }))
        t.equal(value(loaded, "Themed", "Name"), "dark")
        t.equal(value(loaded, "Page", "Number"), "2")
        t.equal(value(loaded, "Late", "OK"), "1", "main-file variable defined after the include (leniency)")
        t.equal(loaded.warnings, [])
        t.equal(calls.map(\.0), ["#LateName#.inc", "#Theme#/SomeFile.inc", "Pages\\PageNum#Page#.inc",
                                 "#@#Vars.inc", "#Sub#\\SomeFile.inc"])
        // Keys are lowercased, values raw; variables from earlier includes are visible.
        if calls.count == 5 {
            t.equal(calls[1].1["theme"], "Dark")
            t.equal(calls[1].1["page"], "2")
            t.equal(calls[4].1["sub"], "Dark")
            t.equal(calls[1].1["Theme"], nil)
        }
        // The same file included twice is listed once.
        t.equal(loaded.includedFiles.map(\.lastPathComponent), ["Late.inc", "SomeFile.inc", "PageNum2.inc", "Vars.inc"])
    }

    t.suite("Include: variables read so far win over later definitions") {
        let f = IncludeFixture(t, "vars-order")
        f.write("A.inc", "[A]\nK=a\n")
        f.write("B.inc", "[B]\nK=b\n")
        f.write("set.inc", "[Variables]\nWhich=B\n")
        f.write("Skin.ini", """
        [Variables]
        Which=A
        @Include=#Which#.inc
        @Include2=set.inc
        @Include3=#Which#.inc
        """)
        let loaded = try f.load()
        t.equal(names(loaded), ["Variables", "A", "B"])
        t.equal(value(loaded, "Variables", "Which"), "B")
    }

    t.suite("Include: paths") {
        let f = IncludeFixture(t, "paths")
        f.write("Sub/Dir/deep.inc", "[Deep]\nK=1\n@Include=sibling.inc\n@Include2=Sub\\Dir\\fromskin.inc\n")
        f.write("Sub/Dir/sibling.inc", "[Sibling]\nK=1\n")
        f.write("Sub/Dir/fromskin.inc", "[FromSkin]\nK=1\n")
        f.write("../Shared.inc", "[Shared]\nK=1\n")
        let absolute = f.write("../../../Absolute.inc", "[Absolute]\nK=1\n")
        f.write("Quoted Name.inc", "[Quoted]\nK=1\n")
        f.write("Skin.ini", """
        [Variables]
        @Include=Sub\\Dir\\deep.inc
        @Include2=..\\Shared.inc
        @Include3=\(absolute.path)
        @Include4=  "Quoted Name.inc"
        @Include5=.\\Sub\\.\\Dir\\..\\Dir\\sibling.inc
        """)
        let loaded = try f.load()
        // sibling.inc is not next to the skin: found next to the including file (fallback).
        t.equal(names(loaded), ["Variables", "Deep", "Sibling", "FromSkin", "Shared", "Absolute", "Quoted"])
        t.equal(loaded.warnings, [])
        t.equal(loaded.includedFiles.count, 6)
    }

    t.suite("Include: unusable paths become warnings") {
        let f = IncludeFixture(t, "badpaths")
        f.write("dir.inc/placeholder.txt", "")
        f.write("Skin.ini", """
        [Variables]
        @Include=Missing.inc
        @Include2=C:\\Users\\Me\\Documents\\Rainmeter\\Skins\\x.inc
        @Include3=\\\\server\\share\\x.inc
        @Include4=#Undefined#.inc
        @Include5=dir.inc
        @Include6=
        @Include7=D:
        [Meter]
        Meter=String
        """)
        let loaded = try f.load()
        t.equal(names(loaded), ["Variables", "Meter"])
        t.equal(loaded.includedFiles, [])
        t.equal(loaded.warnings.count, 6)
        let all = loaded.warnings.joined(separator: "\n")
        t.check(all.contains("Missing.inc"), all)
        t.check(all.contains("Windows drive path"), all)
        t.check(all.contains("network path"), all)
        t.check(all.contains("#Undefined#") && all.contains("undefined"), all)
        t.check(all.contains("not a file"), all)
        t.check(all.contains("[Variables]") && all.contains("Skin.ini"), "warnings say where the include is")
    }

    t.suite("Include: cycles") {
        let f = IncludeFixture(t, "cycle")
        f.write("a.inc", "[A]\nK=a\n@Include=b.inc\n")
        f.write("b.inc", "[B]\nK=b\n@Include=A.INC\n@Include2=Skin.ini\n@Include3=self.inc\n")
        f.write("self.inc", "[Self]\nK=s\n@Include=self.inc\n")
        f.write("Skin.ini", "[Variables]\n@Include=a.inc\n[Meter]\nK=m\n")
        let loaded = try f.load()
        t.equal(names(loaded), ["Variables", "A", "B", "Self", "Meter"])
        t.equal(loaded.includedFiles.map(\.lastPathComponent), ["a.inc", "b.inc", "self.inc"])
        t.equal(loaded.warnings.count, 3)
        t.check(loaded.warnings.allSatisfy { $0.contains("cycle") }, loaded.warnings.joined(separator: "\n"))
    }

    t.suite("Include: depth limit") {
        let f = IncludeFixture(t, "depth")
        let chain = SkinFileLoader.maxIncludeDepth + 10
        for i in 1...chain { f.write("n\(i).inc", "[N\(i)]\nK=\(i)\n@Include=n\(i + 1).inc\n") }
        f.write("Skin.ini", "[Variables]\n@Include=n1.inc\n")
        let loaded = try f.load()
        t.equal(loaded.includedFiles.count, SkinFileLoader.maxIncludeDepth)
        t.equal(names(loaded).count, SkinFileLoader.maxIncludeDepth + 1)
        t.equal(loaded.warnings.count, 1)
        t.check(loaded.warnings.first?.contains("deeper") == true)
    }

    t.suite("Include: exponential include trees are capped") {
        let f = IncludeFixture(t, "explode")
        for i in 1...25 { f.write("e\(i).inc", "[E\(i)]\nK=\(i)\n@Include=e\(i + 1).inc\n@Include2=e\(i + 1).inc\n") }
        f.write("e26.inc", "[Leaf]\nK=1\n")
        f.write("Skin.ini", "[Variables]\n@Include=e1.inc\n")
        let start = Date()
        let loaded = try f.load()
        t.check(Date().timeIntervalSince(start) < 10, "finishes quickly")
        t.equal(loaded.includedFiles.count, 26)
        t.check(loaded.warnings.contains { $0.contains("more than \(SkinFileLoader.maxIncludeLoads)") })
        t.check(loaded.warnings.count <= 101)
    }

    t.suite("Include: warnings are capped") {
        let f = IncludeFixture(t, "manywarnings")
        var text = "[Variables]\n"
        for i in 0..<300 { text += "@Include\(i)=missing\(i).inc\n" }
        f.write("Skin.ini", text)
        let loaded = try f.load()
        t.equal(loaded.warnings.count, 101)
        t.check(loaded.warnings.last?.contains("200 more") == true, loaded.warnings.last ?? "")
    }

    t.suite("Include: includes outside a section") {
        let f = IncludeFixture(t, "orphan")
        f.write("Settings.inc", "Stray=1\n@Include=Other.inc\n[Variables]\nA=1\n")
        f.write("Other.inc", "[Other]\n")
        f.write("Skin.ini", "@Include=Settings.inc\n[Rainmeter]\n@Include=Settings.inc\n")
        let loaded = try f.load()
        t.equal(names(loaded), ["Rainmeter", "Variables"])
        t.equal(value(loaded, "Variables", "A"), "1")
        t.equal(loaded.warnings.count, 2)
        t.check(loaded.warnings.allSatisfy { $0.contains("inside a section") }, loaded.warnings.joined(separator: "\n"))
    }

    t.suite("Include: included [Variables] without one in the skin") {
        let f = IncludeFixture(t, "novars")
        f.write("v.inc", "[Variables]\nA=1\n")
        f.write("Skin.ini", "[Rainmeter]\nUpdate=1000\n[MeterA]\nMeter=String\n@Include=v.inc\n[MeterB]\nMeter=String\n")
        let loaded = try f.load()
        t.equal(names(loaded), ["Rainmeter", "MeterA", "Variables", "MeterB"])
        t.equal(value(loaded, "Variables", "A"), "1")
    }

    t.suite("Include: encodings and case-insensitive file names") {
        let f = IncludeFixture(t, "encodings")
        f.write("../@Resources/Variables.inc", "[Variables]\nName=Grüße 中文\n", encoding: .utf16LittleEndian(bom: true))
        f.write("ansi.inc", "[Ansi]\nText=café\n", encoding: .windows1252)
        f.write("Skin.ini", "[Variables]\n@Include=#@#variables.INC\n@Include2=ANSI.inc\n",
                encoding: .utf16LittleEndian(bom: true))
        let loaded = try f.load()
        t.equal(value(loaded, "Variables", "Name"), "Grüße 中文")
        t.equal(value(loaded, "Ansi", "Text"), "café")
        t.equal(loaded.warnings, [])
        t.equal(loaded.includedFiles.count, 2)
        // Case-insensitive lookup itself (independent of the volume's case sensitivity).
        let variables = f.resources.appendingPathComponent("Variables.inc").path
        let wrongCase = f.resources.path.uppercased() + "/VARIABLES.inc"
        if let found = IncludePaths.caseInsensitiveLookup(wrongCase) {
            t.check(FileManager.default.contentsEqual(atPath: found, andPath: variables), found)
        } else {
            t.check(false, "case-insensitive lookup failed")
        }
        t.equal(IncludePaths.caseInsensitiveLookup(f.resources.path + "/nothing.inc"), nil)
        t.equal(IncludePaths.normalize("/a/./b//c/../d/"), "/a/b/d")
        t.equal(IncludePaths.normalize("/../../x"), "/x")
        t.check(IncludePaths.identity(of: URL(fileURLWithPath: variables))
                    == IncludePaths.identity(of: URL(fileURLWithPath: f.skinFolder.path + "/../@Resources/Variables.inc")))
    }

    t.suite("Include: main file errors and odd input") {
        let f = IncludeFixture(t, "main")
        t.throwsError("missing main file") { _ = try f.load() }
        t.throwsError("directory as main file") {
            _ = try SkinFileLoader.load(url: f.skinFolder, expandVariables: { raw, _ in raw })
        }
        f.write("Skin.ini", "")
        let empty = try f.load()
        t.equal(empty.document.sections, [])
        t.equal(empty.warnings, [])
        // A skin without any include is the same as a plain parse (minus nothing).
        let text = "[Rainmeter]\nUpdate=1000\n[Rainmeter]\nX=1\n[M]\nMeter=String\nText=\"q\"\n"
        f.write("Skin.ini", text)
        t.equal(try f.load().document, IniDocument.parse(text))
        // Include of the main skin file itself is a cycle.
        f.write("Skin.ini", "[Variables]\n@Include=Skin.ini\n@Include2=#CURRENTPATH#Skin.ini\nA=1\n")
        let selfInclude = try f.load()
        t.equal(value(selfInclude, "Variables", "A"), "1")
        t.equal(selfInclude.warnings.count, 2)
        // The expandVariables closure may return anything.
        f.write("Skin.ini", "[Variables]\n@Include=x\n")
        let weird = try SkinFileLoader.load(url: f.mainURL, expandVariables: { _, _ in "\0\n\u{FFFD}//" })
        t.equal(weird.warnings.count, 1)
    }

    t.suite("Include: relative main URL") {
        let f = IncludeFixture(t, "relative")
        f.write("../@Resources/Variables.inc", "[Variables]\nA=1\n")
        f.write("Skin.ini", "[Variables]\n@Include=#@#Variables.inc\n@Include2=..\\@Resources\\Variables.inc\n")
        let relative = URL(fileURLWithPath: "Skin.ini", relativeTo: f.skinFolder)
        let loaded = try SkinFileLoader.load(url: relative, expandVariables: f.expander())
        t.equal(value(loaded, "Variables", "A"), "1")
        t.equal(loaded.warnings, [])
        t.equal(loaded.includedFiles.count, 1)
        let dotted = URL(fileURLWithPath: f.skinFolder.path + "/../Config/./Skin.ini")
        t.equal(value(try SkinFileLoader.load(url: dotted, expandVariables: f.expander()), "Variables", "A"), "1")
    }

    t.suite("Include: symlinked include") {
        let f = IncludeFixture(t, "symlink")
        let real = f.write("../@Resources/real.inc", "[Real]\nK=1\n@Include=#@#link.inc\n")
        try FileManager.default.createSymbolicLink(at: f.resources.appendingPathComponent("link.inc"),
                                                   withDestinationURL: real)
        f.write("Skin.ini", "[Variables]\n@Include=#@#link.inc\n")
        let loaded = try f.load()
        t.equal(names(loaded), ["Variables", "Real"])
        t.equal(loaded.warnings.count, 1, "link.inc → real.inc → link.inc is a cycle")
        t.check(loaded.warnings.first?.contains("cycle") == true)
    }
    // MARK: Review

    t.suite("Include: nested include inside a section that already exists") {
        // "when any file includes another file, the new contents are added within its own sections, immediately
        // after the section where the statement is made". The statement is in a.inc's [M] block, which merges into
        // the skin's own [M] — so b.inc's new section follows the skin's [M], not the place a.inc was pasted.
        let f = IncludeFixture(t, "nested-existing")
        f.write("a.inc", "[M]\nFromA=1\n@Include=b.inc\n[NewA]\nK=1\n")
        f.write("b.inc", "[NewB]\nK=1\n")
        f.write("Skin.ini", "[Variables]\n@Include=a.inc\n[Other]\nK=1\n[M]\nMeter=String\n[Last]\nK=1\n")
        let loaded = try f.load()
        t.equal(names(loaded), ["Variables", "NewA", "Other", "M", "NewB", "Last"])
        t.equal(loaded.document.section(named: "M")?.keys, ["FromA", "Meter"])

        // The existing section may also come before the including one.
        let g = IncludeFixture(t, "nested-existing2")
        g.write("a.inc", "[Variables]\nFromA=1\n@Include=b.inc\n[StyleA]\nK=1\n")
        g.write("b.inc", "[StyleB]\nK=1\n")
        g.write("Skin.ini", "[Variables]\nA=1\n[Rainmeter]\n@Include=a.inc\n[Meter]\nMeter=String\n")
        let loaded2 = try g.load()
        t.equal(names(loaded2), ["Variables", "StyleB", "Rainmeter", "StyleA", "Meter"])
        t.equal(value(loaded2, "Variables", "FromA"), "1")
        t.equal(value(loaded2, "Variables", "A"), "1")
    }

    t.suite("Include: several and nested includes keep reading order") {
        let f = IncludeFixture(t, "order")
        f.write("a.inc", "[A1]\nK=1\n@Include=c.inc\n[A2]\nK=1\n")
        f.write("b.inc", "[B1]\nK=1\n")
        f.write("c.inc", "[C1]\nK=1\n[C2]\nK=1\n@Include=d.inc\n")
        f.write("d.inc", "[D1]\nK=1\n")
        f.write("Skin.ini", "[First]\nK=0\n[S]\n@Include=a.inc\n@Include2=b.inc\n[Last]\nK=0\n")
        let loaded = try f.load()
        t.equal(names(loaded), ["First", "S", "A1", "C1", "C2", "D1", "A2", "B1", "Last"])
        t.equal(loaded.includedFiles.map(\.lastPathComponent), ["a.inc", "c.inc", "d.inc", "b.inc"])
        // Every section appears exactly once.
        t.equal(Set(names(loaded).map { $0.lowercased() }).count, names(loaded).count)
    }

    t.suite("Include: a repeated @Include key in one section") {
        // "All option names within a section must be unique": the first definition wins, like any other key.
        let f = IncludeFixture(t, "repeated-key")
        f.write("a.inc", "[A]\nK=1\n")
        f.write("b.inc", "[B]\nK=1\n")
        f.write("Skin.ini", "[Variables]\n@Include=a.inc\n@INCLUDE=b.inc\n@Include2=b.inc\n")
        let loaded = try f.load()
        t.equal(names(loaded), ["Variables", "A", "B"])
        t.equal(loaded.includedFiles.map(\.lastPathComponent), ["a.inc", "b.inc"])
        t.equal(loaded.warnings, [])
    }

    t.suite("Include: devices, pipes and directories are not include files") {
        let f = IncludeFixture(t, "devices")
        let fifo = f.skinFolder.appendingPathComponent("pipe.inc")
        t.equal(mkfifo(fifo.path, 0o644), 0)
        f.write("dir.inc/x.txt", "")
        f.write("Skin.ini", "[Variables]\n@Include=/dev/zero\n@Include2=pipe.inc\n@Include3=dir.inc\n@Include4=/dev/null\nA=1\n")
        let start = Date()
        let loaded = try f.load()
        t.check(Date().timeIntervalSince(start) < 5, "no blocking read")
        t.equal(value(loaded, "Variables", "A"), "1")
        t.equal(loaded.includedFiles, [])
        t.equal(loaded.warnings.count, 4)
        t.check(loaded.warnings.allSatisfy { $0.contains("not a file") }, loaded.warnings.joined(separator: "\n"))
    }

    t.suite("Include: hostile input is bounded") {
        // A 200 KB include value (x50): rejected cheaply, and warnings quote it only briefly.
        let f = IncludeFixture(t, "hostile")
        let huge = String(repeating: "ab/", count: 70_000)
        var text = "[Variables]\n"
        for i in 0..<50 { text += "@Include\(i)=\(huge)\(i).inc\n" }
        f.write("Skin.ini", text)
        var start = Date()
        let loaded = try f.load()
        t.check(Date().timeIntervalSince(start) < 5, "huge values: \(Date().timeIntervalSince(start)) s")
        t.equal(loaded.warnings.count, 50)
        t.check(loaded.warnings.allSatisfy { $0.contains("longer than") && $0.utf8.count < 1_000 },
                loaded.warnings.first ?? "")
        // A path just over PATH_MAX after expansion.
        let g = IncludeFixture(t, "hostile-path")
        g.write("Skin.ini", "[Variables]\n@Include=#Long#\n")
        let long = try SkinFileLoader.load(url: g.mainURL, expandVariables: { _, _ in String(repeating: "x", count: 1_100) })
        t.check(long.warnings.first?.contains("longer than \(SkinFileLoader.maxIncludePathLength)") == true,
                long.warnings.first ?? "")

        // A large include file included hundreds of times: stops at maxIncludedEntries.
        let h = IncludeFixture(t, "hostile-repeat")
        var big = "[Variables]\n"
        for i in 0..<300_000 { big += "V\(i)=\(i)\n" }
        h.write("big.inc", big)
        var skin = "[Variables]\n"
        for i in 0..<400 { skin += "@Include\(i)=big.inc\n" }
        h.write("Skin.ini", skin)
        start = Date()
        // (A trivial expander: the fixture's own expander is O(#variables) per call.)
        let repeated = try SkinFileLoader.load(url: h.mainURL, expandVariables: { raw, _ in raw })
        // Without the cap, 400 × 300 000 entries take minutes; with it, about 1.5 s on a fast Mac and several seconds
        // on a CI runner (Intel, debug build), so the limit is generous.
        t.check(Date().timeIntervalSince(start) < 60, "repeated big include: \(Date().timeIntervalSince(start)) s")
        t.equal(repeated.document.section(named: "Variables")?.entries.count, 300_000)
        t.equal(repeated.warnings.count, 1)
        t.check(repeated.warnings.first?.contains("more than \(SkinFileLoader.maxIncludedEntries)") == true,
                repeated.warnings.first ?? "")

        // Thousands of failing includes: the attempt limit stops the file-system work.
        let m = IncludeFixture(t, "hostile-missing")
        var missing = "[Variables]\n"
        for i in 0..<5_000 { missing += "@Include\(i)=Sub/Dir/missing\(i).inc\n" }
        m.write("Skin.ini", missing)
        start = Date()
        let manyMissing = try m.load()
        t.check(Date().timeIntervalSince(start) < 5, "missing includes: \(Date().timeIntervalSince(start)) s")
        // 100 warnings, the limit message (always kept) and the summary of the 400 suppressed ones.
        t.equal(manyMissing.warnings.count, 102)
        t.check(manyMissing.warnings.contains { $0.contains("more than \(SkinFileLoader.maxIncludeLoads)") })
        t.check(manyMissing.warnings.last?.contains("400 more") == true, manyMissing.warnings.last ?? "")
    }

    t.suite("Include: variables offered to expandVariables") {
        // Main-file [Variables] not read yet are offered (leniency); a value read so far — here from an include —
        // replaces it, and later reads keep updating what the next include sees.
        let f = IncludeFixture(t, "offered")
        f.write("set.inc", "[Variables]\nTheme=FromInclude\n")
        f.write("Skin.ini", """
        [Rainmeter]
        @Include=#Theme#.inc
        @Include2=set.inc
        @Include3=#Theme#.inc
        [Variables]
        Theme=FromSkin
        Other=x
        @Include4=#Theme#.inc
        """)
        var seen: [String?] = []
        var others: [String?] = []
        _ = try SkinFileLoader.load(url: f.mainURL, expandVariables: { raw, vars in
            if raw.contains("#Theme#") { seen.append(vars["theme"]); others.append(vars["other"]) }
            return raw
        })
        t.equal(seen, ["FromSkin", "FromInclude", "FromSkin"])
        t.equal(others, ["x", "x", "x"])
    }

    t.suite("Include: ANSI include files use the configured code page") {
        let saved = TextDecoding.ansiCodePage
        TextDecoding.ansiCodePage = 936
        defer { TextDecoding.ansiCodePage = saved }
        let f = IncludeFixture(t, "gbk")
        f.write("../@Resources/Variables.inc", "[Variables]\nFont=微软雅黑\n", encoding: .windowsCodePage(936))
        f.write("Skin.ini", "[Variables]\n@Include=#@#Variables.inc\n[M]\nText=中文\n", encoding: .windowsCodePage(936))
        let loaded = try f.load()
        t.equal(value(loaded, "Variables", "Font"), "微软雅黑")
        t.equal(value(loaded, "M", "Text"), "中文")
        t.equal(loaded.warnings, [])
    }
}
