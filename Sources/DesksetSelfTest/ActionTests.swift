import Foundation
@testable import DesksetCore

fileprivate func bang(_ name: String, _ args: String...) -> SkinAction {
    .bang(Bang(name: name, args: args))
}

fileprivate func run(_ target: String, _ args: String...) -> SkinAction {
    .execute(target: target, arguments: args)
}

func runActionTests(_ t: TestRunner) {
    t.suite("Action: manual Action option examples") {
        // https://docs.rainmeter.net/manual/skins/option-types/#Action
        t.equal(ActionParser.parse("!HideMeter SomeMeter"), [bang("hidemeter", "SomeMeter")])
        t.equal(ActionParser.parse("[!HideMeter SomeMeter]"), [bang("hidemeter", "SomeMeter")])
        t.equal(ActionParser.parse("[!HideMeter SomeMeter][!HideMeter SomeOtherMeter]"),
                [bang("hidemeter", "SomeMeter"), bang("hidemeter", "SomeOtherMeter")])
        // "These two lines are equivalent"
        t.equal(ActionParser.parse(#"[!HideMeter "SomeMeter"]"#), ActionParser.parse("[!HideMeter SomeMeter]"))
        // Unquoted spaces split the value into several arguments (the manual calls this an error)…
        t.equal(ActionParser.parse("[!SetVariable SomeVariable I think, therefore I am]"),
                [bang("setvariable", "SomeVariable", "I", "think,", "therefore", "I", "am")])
        // …quoted, it is one argument.
        t.equal(ActionParser.parse(#"[!SetVariable SomeVariable "I think, therefore I am"]"#),
                [bang("setvariable", "SomeVariable", "I think, therefore I am")])
        t.equal(ActionParser.parse(##"[!SetWallpaper "#ImageFile#"]"##), [bang("setwallpaper", "#ImageFile#")])
        t.equal(ActionParser.parse("[!SetWallpaper #ImageFile#]"), [bang("setwallpaper", "#ImageFile#")])
        // External commands
        t.equal(ActionParser.parse(#"["C:\Windows\Notepad.exe" MyFile.txt]"#),
                [run(#"C:\Windows\Notepad.exe"#, "MyFile.txt")])
        t.equal(ActionParser.parse(#"["https://forum.rainmeter.net"]"#), [run("https://forum.rainmeter.net")])
        // Magic quotes
        t.equal(ActionParser.parse(#"[!Log """Bob said "hello" to Susan"""]"#),
                [bang("log", #"Bob said "hello" to Susan"#)])
        // Escaped variables / measures are passed through untouched (resolution is the engine's job).
        t.equal(ActionParser.parse("!SetOption SomeMeter FontSize #*VarName*#"),
                [bang("setoption", "SomeMeter", "FontSize", "#*VarName*#")])
        t.equal(ActionParser.parse("!SetOption SomeMeter FontSize [MeasureName]"),
                [bang("setoption", "SomeMeter", "FontSize", "[MeasureName]")])
        t.equal(ActionParser.parse("!SetOption SomeMeter FontSize [*MeasureName*]"),
                [bang("setoption", "SomeMeter", "FontSize", "[*MeasureName*]")])
    }

    t.suite("Action: manual bang page examples") {
        // https://docs.rainmeter.net/manual/bangs/
        t.equal(ActionParser.parse("[!ShowMeter SomeMeter][!UpdateMeter SomeMeter][!Redraw]"),
                [bang("showmeter", "SomeMeter"), bang("updatemeter", "SomeMeter"), bang("redraw")])
        t.equal(ActionParser.parse(#"!SetClip "This is copied to the clipboard!""#),
                [bang("setclip", "This is copied to the clipboard!")])
        t.equal(ActionParser.parse(#"!SetWallpaper "Some Image.png" Center"#),
                [bang("setwallpaper", "Some Image.png", "Center")])
        t.equal(ActionParser.parse("!About Skins"), [bang("about", "Skins")])
        t.equal(ActionParser.parse(#"!Manage Skins "illustro\Clock" "Clock.ini""#),
                [bang("manage", "Skins", #"illustro\Clock"#, "Clock.ini")])
        t.equal(ActionParser.parse(#"!Log "There was an error!" Error"#),
                [bang("log", "There was an error!", "Error")])
        t.equal(ActionParser.parse(#"!LoadLayout "My Saved Layout""#), [bang("loadlayout", "My Saved Layout")])
        t.equal(ActionParser.parse(#"Play "SomeFile.wav""#), [bang("play", "SomeFile.wav")])
        t.equal(ActionParser.parse(#"PlayLoop "SomeFile.wav""#), [bang("playloop", "SomeFile.wav")])
        t.equal(ActionParser.parse("PlayStop"), [bang("playstop")])
        t.equal(ActionParser.parse(#"!SetOption SomeStringMeter Text "New Text""#),
                [bang("setoption", "SomeStringMeter", "Text", "New Text")])
        t.equal(ActionParser.parse(#"!SetVariable SomeVariable "New value!""#),
                [bang("setvariable", "SomeVariable", "New value!")])
        t.equal(ActionParser.parse(##"!WriteKeyValue Variables MyFontName Arial "#@#Variables.inc""##),
                [bang("writekeyvalue", "Variables", "MyFontName", "Arial", "#@#Variables.inc")])
        t.equal(ActionParser.parse(#"!SetOptionGroup StringGroup Text "New text!""#),
                [bang("setoptiongroup", "StringGroup", "Text", "New text!")])
        t.equal(ActionParser.parse(#"!SetVariableGroup MyFontName "Arial" ConfigGroup"#),
                [bang("setvariablegroup", "MyFontName", "Arial", "ConfigGroup")])
        t.equal(ActionParser.parse(#"!Toggle "illustro\Clock""#), [bang("toggle", #"illustro\Clock"#)])
        t.equal(ActionParser.parse(#"!Move "100" "100""#), [bang("move", "100", "100")])
        t.equal(ActionParser.parse(#"!SetWindowPosition "100" "100" "10" "50""#),
                [bang("setwindowposition", "100", "100", "10", "50")])
        t.equal(ActionParser.parse(#"!SetAnchor "100" "100""#), [bang("setanchor", "100", "100")])
        t.equal(ActionParser.parse(#"!ActivateConfig "illustro\Clock" "Clock.ini""#),
                [bang("activateconfig", #"illustro\Clock"#, "Clock.ini")])
        t.equal(ActionParser.parse(#"!DeactivateConfig "illustro\Clock""#),
                [bang("deactivateconfig", #"illustro\Clock"#)])
        t.equal(ActionParser.parse("LeftMouseUpAction=[!UpdateMeasure SomeMeasure][!UpdateMeter SomeMeter][!Redraw]"
                    .replacingOccurrences(of: "LeftMouseUpAction=", with: "")),
                [bang("updatemeasure", "SomeMeasure"), bang("updatemeter", "SomeMeter"), bang("redraw")])
        t.equal(ActionParser.parse("[!ShowMeter SomeMeter][!Delay 5000][!HideMeter SomeMeter]"),
                [bang("showmeter", "SomeMeter"), bang("delay", "5000"), bang("hidemeter", "SomeMeter")])
        t.equal(ActionParser.parse(#"!SetTransparency "128" "illustro\Clock""#),
                [bang("settransparency", "128", #"illustro\Clock"#)])
        t.equal(ActionParser.parse(#"!ZPos "2" "illustro\Clock""#), [bang("zpos", "2", #"illustro\Clock"#)])
        t.equal(ActionParser.parse(#"!EditSkin "illustro\Clock" "Clock.ini""#),
                [bang("editskin", #"illustro\Clock"#, "Clock.ini")])
        t.equal(ActionParser.parse(#"!ShowGroup "SomeGroup""#), [bang("showgroup", "SomeGroup")])
        t.equal(ActionParser.parse(#"!SetTransparencyGroup "128" "SuiteName""#),
                [bang("settransparencygroup", "128", "SuiteName")])
        t.equal(ActionParser.parse(#"!ToggleMeter "MyMeter""#), [bang("togglemeter", "MyMeter")])
        t.equal(ActionParser.parse(#"!MoveMeter 15 10 "MyMeter""#), [bang("movemeter", "15", "10", "MyMeter")])
        t.equal(ActionParser.parse(#"!TogglePauseMeasure "CPUMeasure""#),
                [bang("togglepausemeasure", "CPUMeasure")])
        t.equal(ActionParser.parse(#"!CommandMeasure "NowPlayingParent" "Previous""#),
                [bang("commandmeasure", "NowPlayingParent", "Previous")])
        t.equal(ActionParser.parse(#"!DisableMouseAction MyMeter "MouseOverAction|MouseLeaveAction""#),
                [bang("disablemouseaction", "MyMeter", "MouseOverAction|MouseLeaveAction")])
        t.equal(ActionParser.parse(#"!ToggleMouseAction MyMeter "*""#), [bang("togglemouseaction", "MyMeter", "*")])
        t.equal(ActionParser.parse(#"!DisableMouseActionGroup "LeftMouseUpAction" MyGroup"#),
                [bang("disablemouseactiongroup", "LeftMouseUpAction", "MyGroup")])
        t.equal(ActionParser.parse(#"!ToggleMouseActionSkinGroup "*" MySkinGroup"#),
                [bang("togglemouseactionskingroup", "*", "MySkinGroup")])
        // Other manual pages
        t.equal(ActionParser.parse(#"[!SetOption WebMeasure URL "https://SomeNewSite.com"][!CommandMeasure WebMeasure Update]"#),
                [bang("setoption", "WebMeasure", "URL", "https://SomeNewSite.com"),
                 bang("commandmeasure", "WebMeasure", "Update")])
        t.equal(ActionParser.parse(#"!CommandMeasure "MyScriptMeasure" "a = b; print(SKIN:ParseFormula('(2+2)'))""#),
                [bang("commandmeasure", "MyScriptMeasure", "a = b; print(SKIN:ParseFormula('(2+2)'))")])
        t.equal(ActionParser.parse(#"[!SetOption MeterDayofWeek Text "The date is [MeasureDate]#CRLF#It's a weekend"]"#),
                [bang("setoption", "MeterDayofWeek", "Text", "The date is [MeasureDate]#CRLF#It's a weekend")])
        t.equal(ActionParser.parse("[!SetOption MeterOne FontColor 0,255,0,255][!SetOption MeterOne StringStyle Bold]"),
                [bang("setoption", "MeterOne", "FontColor", "0,255,0,255"),
                 bang("setoption", "MeterOne", "StringStyle", "Bold")])
        t.equal(ActionParser.parse(#"[!SetOption MeterOne FontColor ""][!SetOption MeterOne StringStyle ""]"#),
                [bang("setoption", "MeterOne", "FontColor", ""), bang("setoption", "MeterOne", "StringStyle", "")])
        t.equal(ActionParser.parse(#"[!SetVariable Size "(Clamp(#Size#+5,8,60))"][!UpdateMeasureGroup Sizers]"#),
                [bang("setvariable", "Size", "(Clamp(#Size#+5,8,60))"), bang("updatemeasuregroup", "Sizers")])
        t.equal(ActionParser.parse(#"["[MeasureRSSItemLink]"]"#), [run("[MeasureRSSItemLink]")])
        t.equal(ActionParser.parse(#"["https://www.deviantart.com/rainmeter/gallery/45661692/system-monitoring"]"#),
                [run("https://www.deviantart.com/rainmeter/gallery/45661692/system-monitoring")])
    }

    t.suite("Action: bang names are canonical") {
        t.equal(ActionParser.parse("!RainmeterRefresh"), [bang("refresh")])
        t.equal(ActionParser.parse("[!RainmeterShowMeter M]"), [bang("showmeter", "M")])
        t.equal(ActionParser.parse("[!SETOPTION M Text x]"), [bang("setoption", "M", "Text", "x")])
        t.equal(ActionParser.parse("[!setoption M Text x]"), [bang("setoption", "M", "Text", "x")])
        t.equal(ActionParser.parse("[!rainmeterRedraw]"), [bang("redraw")])
        t.equal(ActionParser.parse("[!Rainmeter]"), [bang("rainmeter")])
        // Unknown bangs are still parsed (the engine reports them as unsupported).
        t.equal(ActionParser.parse("[!NoSuchBang a b]"), [bang("nosuchbang", "a", "b")])
        t.equal(BangCatalog.canonicalName("!RainmeterZPos"), "zpos")
        t.equal(BangCatalog.canonicalName("  !SetOption "), "setoption")
        t.equal(BangCatalog.canonicalName("Refresh"), "refresh")
        t.equal(BangCatalog.canonicalName("!Rainmeter"), "rainmeter")
        t.equal(BangCatalog.canonicalName("!RainmeterPluginBang"), "pluginbang")
        // A quote right after the name starts the first argument.
        t.equal(ActionParser.parse(#"[!Log"text here"]"#), [bang("log", "text here")])
    }

    t.suite("Action: quoting") {
        t.equal(ActionParser.parse(#"[!SetOption M Text "a b"  "c"]"#), [bang("setoption", "M", "Text", "a b", "c")])
        t.equal(ActionParser.parse(#"[!SetOption M Text ""]"#), [bang("setoption", "M", "Text", "")])
        t.equal(ActionParser.parse(#"[!SetOption M Text " padded "]"#), [bang("setoption", "M", "Text", " padded ")])
        // A quote in the middle of a word is literal.
        t.equal(ActionParser.parse(#"[!SetOption M Text 5"][!Redraw]"#),
                [bang("setoption", "M", "Text", #"5""#), bang("redraw")])
        t.equal(ActionParser.parse(#"[!SetOption M Text a"b"c]"#), [bang("setoption", "M", "Text", #"a"b"c"#)])
        // An unmatched quote is literal.
        t.equal(ActionParser.parse(#"[!SetOption M Text "abc]"#), [bang("setoption", "M", "Text", #""abc"#)])
        // Brackets inside double quotes do not end the bang.
        t.equal(ActionParser.parse(#"[!Log "a]b"][!Redraw]"#), [bang("log", "a]b"), bang("redraw")])
        t.equal(ActionParser.parse(#"[!Log "a[b"][!Redraw]"#), [bang("log", "a[b"), bang("redraw")])
        t.equal(ActionParser.parse(#"[!SetOption M InlinePattern "[^\]]+"][!Redraw]"#),
                [bang("setoption", "M", "InlinePattern", #"[^\]]+"#), bang("redraw")])
        // The manual's "will fail" example: quotes pair up left to right.
        t.equal(ActionParser.parse(#"[!Log "Bob said "hello" to Susan"]"#),
                [bang("log", "Bob said ", #"hello""#, "to", #"Susan""#)])
        // Single quotes are ordinary characters.
        t.equal(ActionParser.parse("[!SetOption M Text 'a b']"), [bang("setoption", "M", "Text", "'a", "b'")])
        // Tabs and newlines separate arguments too.
        t.equal(ActionParser.parse("[!SetOption\tM\tText\t\"x\"]\n[!Redraw]"),
                [bang("setoption", "M", "Text", "x"), bang("redraw")])
        // Non-ASCII content survives.
        t.equal(ActionParser.parse(#"[!SetOption M Text "日本語 ☺︎ München"]"#),
                [bang("setoption", "M", "Text", "日本語 ☺︎ München")])
    }

    t.suite("Action: magic quotes") {
        t.equal(ActionParser.parse(#"[!SetOption M Text """say "hi""""]"#), [bang("setoption", "M", "Text", #"say "hi""#)])
        t.equal(ActionParser.parse(#"[!SetOption M Text """He said "hi" """]"#),
                [bang("setoption", "M", "Text", #"He said "hi" "#)])
        t.equal(ActionParser.parse(#"[!SetOption M Text """"quoted""""]"#), [bang("setoption", "M", "Text", #""quoted""#)])
        t.equal(ActionParser.parse(#"[!SetOption M Text """"""]"#), [bang("setoption", "M", "Text", "")])
        // Magic quotes are strictly literal: brackets and parentheses inside do not matter.
        t.equal(ActionParser.parse(#"[!SetOption M Text """a ] [b ( c"""][!Redraw]"#),
                [bang("setoption", "M", "Text", "a ] [b ( c"), bang("redraw")])
        t.equal(ActionParser.parse(#"[!SetOption WebMeasure RegExp """(?siU)<a href="(.*)">(.*)</a>"""]"#),
                [bang("setoption", "WebMeasure", "RegExp", #"(?siU)<a href="(.*)">(.*)</a>"#)])
        t.equal(ActionParser.parse(#"[!CommandMeasure Script """Say("hello")""" "Config"]"#),
                [bang("commandmeasure", "Script", #"Say("hello")"#, "Config")])
        // Unterminated magic quotes fall back to ordinary quote handling without crashing.
        t.equal(ActionParser.parse(#"[!Log """abc"]"#), [bang("log", "", "abc")])
    }

    t.suite("Action: nested brackets in arguments") {
        t.equal(ActionParser.parse(#"[!SetOption M Text "[Measure]"]"#), [bang("setoption", "M", "Text", "[Measure]")])
        t.equal(ActionParser.parse("[!SetOption M Text [Measure]]"), [bang("setoption", "M", "Text", "[Measure]")])
        t.equal(ActionParser.parse("[!SetOption M Text [Measure]][!Redraw]"),
                [bang("setoption", "M", "Text", "[Measure]"), bang("redraw")])
        t.equal(ActionParser.parse("[!SetOption M Text [Measure:/1024,1]MB][!Redraw]"),
                [bang("setoption", "M", "Text", "[Measure:/1024,1]MB"), bang("redraw")])
        t.equal(ActionParser.parse("[!SetVariable X [#Color[#Index]]]"), [bang("setvariable", "X", "[#Color[#Index]]")])
        t.equal(ActionParser.parse("[!SetOption M Text [&Script:Func('a b', [&M2])]][!Redraw]"),
                [bang("setoption", "M", "Text", "[&Script:Func('a b', [&M2])]"), bang("redraw")])
        t.equal(ActionParser.parse("[!SetOption M Text [\\x263A]]"), [bang("setoption", "M", "Text", "[\\x263A]")])
        t.equal(ActionParser.parse("[!SetVariable X [A] [B]]"), [bang("setvariable", "X", "[A]", "[B]")])
        t.equal(ActionParser.parse("[!SetVariable X pre[A]post]"), [bang("setvariable", "X", "pre[A]post")])
        t.equal(ActionParser.parse("!SetOption M Text [*MeasureName*] extra"),
                [bang("setoption", "M", "Text", "[*MeasureName*]", "extra")])
        t.equal(ActionParser.parse(#"["[MeasureLink1]"][!Redraw]"#), [run("[MeasureLink1]"), bang("redraw")])
        // Review fix: the unquoted form of the manual's `["[MeasureRSSItemLink]"]` keeps the section variable.
        t.equal(ActionParser.parse("[[MeasureLink1]]"), [run("[MeasureLink1]")])
        // An unmatched "[" inside an argument is literal.
        t.equal(ActionParser.parse("[!SetOption M Text a[b"), [bang("setoption", "M", "Text", "a[b")])
        // Bare form: "]" is not special.
        t.equal(ActionParser.parse("!SetOption M Text a]b"), [bang("setoption", "M", "Text", "a]b")])
    }

    t.suite("Action: execute items") {
        t.equal(ActionParser.parse(#"["notepad.exe" "file.txt"]"#), [run("notepad.exe", "file.txt")])
        t.equal(ActionParser.parse(#"["C:\Program Files\App\app.exe" -a "b c"]"#),
                [run(#"C:\Program Files\App\app.exe"#, "-a", "b c")])
        t.equal(ActionParser.parse("[https://example.com]"), [run("https://example.com")])
        t.equal(ActionParser.parse("https://example.com"), [run("https://example.com")])
        t.equal(ActionParser.parse(##"["#@#Scripts\run.bat"]"##), [run(#"#@#Scripts\run.bat"#)])
        t.equal(ActionParser.parse(#"["explorer.exe" "shell:::{20D04FE0-3AEA-1069-A2D8-08002B30309D}"]"#),
                [run("explorer.exe", "shell:::{20D04FE0-3AEA-1069-A2D8-08002B30309D}")])
        t.equal(ActionParser.parse(#"["https://a.com"]["https://b.com"][!Redraw]"#),
                [run("https://a.com"), run("https://b.com"), bang("redraw")])
        // `[""]` does nothing (history: `!Execute [""]` results in no action).
        t.equal(ActionParser.parse(#"[""]"#), [])
        t.equal(ActionParser.parse(#"[""][!Redraw]"#), [bang("redraw")])
        // A quoted "!Name" is a path, not a bang.
        t.equal(ActionParser.parse(#"["!Refresh"]"#), [run("!Refresh")])
    }

    t.suite("Action: legacy !Execute and Play") {
        t.equal(ActionParser.parse("!Execute [!HideMeter A][!ShowMeter B]"),
                [bang("hidemeter", "A"), bang("showmeter", "B")])
        t.equal(ActionParser.parse("!RainmeterExecute [!RainmeterHideMeter A]"), [bang("hidemeter", "A")])
        t.equal(ActionParser.parse("!execute [!HideMeter A] [!ShowMeter B]"),
                [bang("hidemeter", "A"), bang("showmeter", "B")])
        t.equal(ActionParser.parse(#"!Execute ["notepad.exe" "a b.txt"]"#), [run("notepad.exe", "a b.txt")])
        t.equal(ActionParser.parse(#"!Execute [""]"#), [])
        t.equal(ActionParser.parse("!Execute"), [])
        t.equal(ActionParser.parse("[!Execute [!HideMeter A][!ShowMeter B]][!Redraw]"),
                [bang("hidemeter", "A"), bang("showmeter", "B"), bang("redraw")])
        t.equal(ActionParser.parse("[[!HideMeter A][!ShowMeter B]]"), [bang("hidemeter", "A"), bang("showmeter", "B")])
        // History: PLAY works like a bang, upper case, bare or inside !Execute.
        t.equal(ActionParser.parse(#"PLAY #SKINSPATH#Beeper\Sounds\beep.wav"#),
                [bang("play", #"#SKINSPATH#Beeper\Sounds\beep.wav"#)])
        t.equal(ActionParser.parse(##"!execute [PLAY "#SKINSPATH#Beeper\Sounds\beep.wav"]"##),
                [bang("play", #"#SKINSPATH#Beeper\Sounds\beep.wav"#)])
        t.equal(ActionParser.parse(#"[Play "a.wav"][PlayStop]"#), [bang("play", "a.wav"), bang("playstop")])
        t.equal(ActionParser.parse(#"["Play" "a.wav"]"#), [run("Play", "a.wav")])
        // Deeply nested !Execute is cut off instead of recursing forever.
        let deep = String(repeating: "[!Execute ", count: 200) + "[!Redraw]" + String(repeating: "]", count: 200)
        t.check(ActionParser.parse(deep).count <= 1)
    }

    t.suite("Action: whitespace, garbage and empty input") {
        t.equal(ActionParser.parse(""), [])
        t.equal(ActionParser.parse("   "), [])
        t.equal(ActionParser.parse("[]"), [])
        t.equal(ActionParser.parse("[ ]"), [])
        t.equal(ActionParser.parse("[!]"), [])
        t.equal(ActionParser.parse("[][!Redraw][]"), [bang("redraw")])
        t.equal(ActionParser.parse("  [!Redraw]   [!Update]  "), [bang("redraw"), bang("update")])
        t.equal(ActionParser.parse("[ !Redraw ]"), [bang("redraw")])
        // Stray text between items is ignored.
        t.equal(ActionParser.parse("[!Redraw] junk [!Update] #U#"), [bang("redraw"), bang("update")])
        // Missing final "]" is tolerated.
        t.equal(ActionParser.parse("[!SetOption M Text x][!Redraw"),
                [bang("setoption", "M", "Text", "x"), bang("redraw")])
        t.equal(ActionParser.parse("[!Redraw"), [bang("redraw")])
        t.equal(ActionParser.parse("]]]"), [run("]]]")])
        t.equal(ActionParser.parse("[[[["), [])
    }

    t.suite("Action: arguments()") {
        t.equal(ActionParser.arguments(#"M Text "a b""#), ["M", "Text", "a b"])
        t.equal(ActionParser.arguments(#"  """x "y" z"""  [A B] "#), [#"x "y" z"#, "[A B]"])
        t.equal(ActionParser.arguments(""), [])
    }

    t.suite("Action: malformed input never crashes") {
        let samples = [
            "[", "]", "\"", "\"\"\"", "\"\"\"\"", "[\"", "[\"\"\"", "[!", "!", "!\"", "[!A \"\"\"]", "[!A \"]\"",
            "[[[]]]", "[!A [[[", "[!A ]]]", "\"\"\"\"\"\"\"", "[\"\"\"\"\"\"\"]", "[!A \"\"\"\"\"]", "[\u{0}]",
            "[!A \u{1F600}]", "[!A \r\n]", "!Execute !Execute !Execute", "[!Execute [!Execute [!Execute",
        ]
        for sample in samples { _ = ActionParser.parse(sample) }
        // Random soup of the special characters.
        var generator = SplitMix64(seed: 42)
        let alphabet = Array("[]\"! ab!\\:#*&'")
        for _ in 0 ..< 3000 {
            let length = Int(generator.next() % 40)
            let text = String((0 ..< length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
            let actions = ActionParser.parse(text)
            t.check(actions.count <= text.count + 1, "too many actions for \(text.debugDescription)")
        }
        // Big inputs stay linear. Quadratic parsing of these 20k–100k-element inputs takes far longer than the limit,
        // which leaves room for a slow CI runner (debug build).
        let long = String(repeating: "[!SetOption M Text \"a b\"]", count: 20_000)
        let start = Date()
        t.equal(ActionParser.parse(long).count, 20_000)
        let unbalanced = String(repeating: "[", count: 50_000) + String(repeating: "\"", count: 50_001)
        _ = ActionParser.parse(unbalanced)
        _ = ActionParser.parse("!A " + String(repeating: "[x", count: 50_000))
        t.check(Date().timeIntervalSince(start) < 60, "parsing large inputs took \(Date().timeIntervalSince(start)) s")
    }

    t.suite("Action: review regressions") {
        // Section variable as the command. The manual's WebParser example is `["[MeasureRSSItemLink]"]`; quotes
        // are only needed for spaces, so the unquoted form must give the same target (brackets kept, so the engine
        // can still resolve the measure).
        t.equal(ActionParser.parse("[[MeasureRSSItemLink]]"), ActionParser.parse(#"["[MeasureRSSItemLink]"]"#))
        t.equal(ActionParser.parse("[[MeasureRSSItemLink]]"), [run("[MeasureRSSItemLink]")])
        t.equal(ActionParser.parse("[[MeasureLink1]][!Redraw]"), [run("[MeasureLink1]"), bang("redraw")])
        t.equal(ActionParser.parse("[[#URL]]"), [run("[#URL]")])
        t.equal(ActionParser.parse("[[&Script:GetUrl('a b')]]"), [run("[&Script:GetUrl('a b')]")])
        t.equal(ActionParser.parse("[[MeasureLink] --new-window]"), [run("[MeasureLink]", "--new-window")])
        t.equal(ActionParser.parse("!Execute [[MeasureLink]]"), [run("[MeasureLink]")])
        t.equal(ActionParser.parse("[[[MeasureLink]]]"), [run("[MeasureLink]")])
        // Nested action lists are still recognised.
        t.equal(ActionParser.parse("[[!HideMeter A][!ShowMeter B]]"), [bang("hidemeter", "A"), bang("showmeter", "B")])
        t.equal(ActionParser.parse("[[ !Redraw]]"), [bang("redraw")])
        t.equal(ActionParser.parse(#"[["https://a.com"]]"#), [run("https://a.com")])
        // Malformed brackets keep their old (harmless) reading.
        t.equal(ActionParser.parse("[[[["), [])
        t.equal(ActionParser.parse("[[abc"), [run("abc")])
        // History: "Fixed that Rainmeter crashes when [] is in bang. E.g. !SetVariable test "blaa[]"."
        t.equal(ActionParser.parse(#"!SetVariable test "blaa[]""#), [bang("setvariable", "test", "blaa[]")])
        t.equal(ActionParser.parse("[!SetVariable test blaa[]][!Redraw]"),
                [bang("setvariable", "test", "blaa[]"), bang("redraw")])
        // History: "Corrected improperly parsed bangs when a leading extra space was used following a !Delay bang."
        t.equal(ActionParser.parse("[!Delay 100][ !Redraw]"), [bang("delay", "100"), bang("redraw")])
        // parseDetailed: magic-quoted arguments are "treated strictly literal" (manual), so the engine must be able to
        // tell them apart from ordinary ones.
        let detailed = ActionParser.parseDetailed(
            #"[!SetVariable X """(1+1) [NotAMeasure]"""][!SetOption M Text "a b" [Measure]]["notepad.exe" f.txt]"#)
        t.equal(detailed.map(\.action), [bang("setvariable", "X", "(1+1) [NotAMeasure]"),
                                         bang("setoption", "M", "Text", "a b", "[Measure]"),
                                         run("notepad.exe", "f.txt")])
        t.equal(detailed.map(\.quoting), [[.none, .magic], [.none, .none, .quoted, .none], [.quoted, .none]])
        t.equal(ActionParser.parseDetailed(#"!Execute [Play "a.wav"][!Log """x"""]"#).map(\.quoting),
                [[.quoted], [.magic]])
        t.equal(ActionParser.parseDetailed("").count, 0)
        for sample in ["[!A \"\"\"x\"\"\" \"y\" z]", "[\"\"]", "[[!A][!B c]]", "!Execute [[M]]"] {
            let parsed = ActionParser.parseDetailed(sample)
            t.equal(parsed.map(\.action), ActionParser.parse(sample), sample)
            for item in parsed {
                switch item.action {
                case .bang(let b): t.equal(item.quoting.count, b.args.count, sample)
                case .execute(_, let arguments): t.equal(item.quoting.count, arguments.count + 1, sample)
                }
            }
        }
        // History: a config parameter with a leading or trailing slash names the same config.
        let refresh = BangCatalog.definition(for: "refresh")
        t.equal(refresh?.configArgument(in: [#"illustro\Clock\"#]), #"illustro\Clock"#)
        t.equal(refresh?.configArgument(in: [#"\illustro\Clock"#]), #"illustro\Clock"#)
        t.equal(refresh?.configArgument(in: ["illustro/Clock/"]), "illustro/Clock")
        t.equal(refresh?.configArgument(in: [#" \ "#]), nil)
        t.equal(refresh?.configArgument(in: ["*"]), "*")
    }

    t.suite("Action: BangCatalog") {
        t.equal(BangCatalog.definition(for: "!SetOption")?.parameters.map(\.name),
                ["Meter/Measure", "Option", "Value", "Config"])
        t.equal(BangCatalog.definition(for: "setoption")?.requiredArgumentCount, 3)
        t.equal(BangCatalog.definition(for: "setoption")?.maximumArgumentCount, 4)
        t.equal(BangCatalog.definition(for: "!RainmeterSetOption")?.name, "setoption")
        t.equal(BangCatalog.definition(for: "setoption")?.displayName, "!SetOption")
        t.equal(BangCatalog.definition(for: "setoption")?.category, .optionsAndVariables)
        t.check(BangCatalog.definition(for: "refresh")?.acceptsArgumentCount(0) == true)
        t.check(BangCatalog.definition(for: "refresh")?.acceptsArgumentCount(1) == true)
        t.check(BangCatalog.definition(for: "refresh")?.acceptsArgumentCount(2) == false)
        t.check(BangCatalog.definition(for: "setclip")?.acceptsArgumentCount(0) == false)
        t.check(BangCatalog.isKnown("!ToggleMouseActionSkinGroup"))
        t.check(BangCatalog.isKnown("Play"))
        t.check(BangCatalog.isKnown("playstop"))
        t.check(!BangCatalog.isKnown("!NoSuchBang"))
        t.equal(BangCatalog.definition(for: "pluginbang")?.isDeprecated, true)
        t.equal(BangCatalog.definition(for: "execute")?.isDeprecated, true)
        t.equal(BangCatalog.definition(for: "play")?.category, .command)

        // Every bang from the manual's list is present exactly once.
        let documented = """
            SetClip SetWallpaper SendKey Launch About Manage Debug TrayMenu Log ResetStats LoadLayout RefreshApp
            Restart Quit Play PlayLoop PlayStop
            SetOption SetVariable WriteKeyValue SetOptionGroup SetVariableGroup Show Hide Toggle ShowFade HideFade
            ToggleFade FadeDuration ShowBlur HideBlur ToggleBlur AddBlur RemoveBlur Move SetWindowPosition SetAnchor
            SetZoomFactor ActivateConfig DeactivateConfig ToggleConfig Update SetUpdate ForceEnableVisibleMode Redraw
            Refresh Delay SkinMenu SkinCustomMenu SetTransparency ZPos Draggable KeepOnScreen ClickThrough SnapEdges
            AutoSelectScreen EditSkin ShowGroup HideGroup ToggleGroup ShowFadeGroup HideFadeGroup ToggleFadeGroup
            FadeDurationGroup SetZoomFactorGroup DeactivateConfigGroup UpdateGroup RedrawGroup RefreshGroup
            SetTransparencyGroup DraggableGroup ZPosGroup KeepOnScreenGroup ClickThroughGroup SnapEdgesGroup
            AutoSelectScreenGroup ShowMeter HideMeter ToggleMeter UpdateMeter MoveMeter ShowMeterGroup HideMeterGroup
            ToggleMeterGroup UpdateMeterGroup EnableMeasure DisableMeasure ToggleMeasure PauseMeasure UnpauseMeasure
            TogglePauseMeasure UpdateMeasure CommandMeasure EnableMeasureGroup DisableMeasureGroup ToggleMeasureGroup
            PauseMeasureGroup UnpauseMeasureGroup TogglePauseMeasureGroup CommandMeasureGroup UpdateMeasureGroup
            DisableMouseAction ClearMouseAction EnableMouseAction ToggleMouseAction DisableMouseActionGroup
            ClearMouseActionGroup EnableMouseActionGroup ToggleMouseActionGroup DisableMouseActionSkinGroup
            ClearMouseActionSkinGroup EnableMouseActionSkinGroup ToggleMouseActionSkinGroup Execute PluginBang
            """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { $0.lowercased() }
        t.equal(Set(BangCatalog.all.map(\.name)), Set(documented))
        t.equal(BangCatalog.all.count, documented.count, "no duplicates")
        for definition in BangCatalog.all {
            // Optional parameters only ever trail required ones.
            let firstOptional = definition.parameters.firstIndex { $0.isOptional } ?? definition.parameters.count
            t.check(definition.parameters[firstOptional...].allSatisfy(\.isOptional), definition.name)
            t.equal(BangCatalog.definition(for: definition.displayName), definition)
        }

        // Rainmeter 5.0 colon-namespaced bangs
        t.check(BangCatalog.isKnown("!Skin:Refresh"))
        t.check(BangCatalog.isKnown("!Skin:SetZoomFactor"))
        t.check(BangCatalog.isKnown("!Loop:Reset"))
        t.check(BangCatalog.isKnown("!WebParser:Refetch"))
        t.check(BangCatalog.isKnown("!Audio:SetVolume"))
        t.check(BangCatalog.isKnown("!NowPlaying:PlayPause"))
        t.equal(ActionParser.parse("[!Loop:Reset MeasureLoop][!Skin:Update]"),
                [.bang(Bang(name: "loop:reset", args: ["MeasureLoop"])),
                 .bang(Bang(name: "skin:update", args: []))])

        // Config parameter
        let setOption = BangCatalog.definition(for: "setoption")
        t.equal(setOption?.configParameterIndex, 3)
        t.equal(setOption?.configArgument(in: ["M", "Text", "x"]), nil)
        t.equal(setOption?.configArgument(in: ["M", "Text", "x", #"illustro\Clock"#]), #"illustro\Clock"#)
        t.equal(setOption?.configArgument(in: ["M", "Text", "x", ""]), nil)
        t.equal(BangCatalog.definition(for: "refresh")?.configArgument(in: ["*"]), "*")
        t.equal(BangCatalog.definition(for: "activateconfig")?.configArgument(in: ["a\\b", "c.ini"]), "a\\b")
        t.equal(BangCatalog.definition(for: "manage")?.configParameterIndex, nil)
        t.equal(BangCatalog.definition(for: "setvariablegroup")?.configParameterIndex, nil)
        t.equal(BangCatalog.definition(for: "delay")?.configParameterIndex, nil)
        t.equal(BangCatalog.definition(for: "writekeyvalue")?.configParameterIndex, nil)
        let position = BangCatalog.definition(for: "setwindowposition")
        t.equal(position?.configArgument(in: ["100", "100"]), nil)
        t.equal(position?.configArgument(in: ["100", "100", "illustro\\Clock"]), "illustro\\Clock")
        t.equal(position?.configArgument(in: ["100", "100", "10", "50"]), nil)
        t.equal(position?.configArgument(in: ["100", "100", "10", "50", "cfg"]), "cfg")
        t.equal(BangCatalog.definition(for: "togglemouseactionskingroup")?.configParameterIndex, nil)
        t.equal(BangCatalog.definition(for: "togglemouseactiongroup")?.configParameterIndex, 2)

        t.equal(BangCatalog.mouseActions(in: "MouseOverAction|MouseLeaveAction"), ["MouseOverAction", "MouseLeaveAction"])
        t.equal(BangCatalog.mouseActions(in: " mousescrolldownaction | MouseScrollUpAction "),
                ["MouseScrollDownAction", "MouseScrollUpAction"])
        t.equal(BangCatalog.mouseActions(in: "*"), BangCatalog.mouseActionNames)
        t.equal(BangCatalog.mouseActions(in: "LeftMouseUpAction|Bogus|LeftMouseUpAction"), ["LeftMouseUpAction"])
        t.equal(BangCatalog.mouseActions(in: ""), [])
        t.equal(BangCatalog.mouseActionNames.count, 21)
        t.check(BangCatalog.mouseActionNames.contains("MouseScrollRightAction"))
    }

    t.suite("Actions: suspended host bang continuations") {
        final class SuspendingHost: SkinHost {
            let base = FakeHost()
            var pending: [(bang: Bang, complete: () -> Void)] = []
            var suspendNames: Set<String> = ["skincustommenu", "setclip"]

            func skinNeedsDisplay(_ skin: Skin) { base.skinNeedsDisplay(skin) }
            func skin(_ skin: Skin, handle bang: Bang) -> Bool { base.skin(skin, handle: bang) }
            func skin(_ skin: Skin, handle bang: Bang, completion: @escaping () -> Void) -> SkinHostBangOutcome {
                base.handled.append(bang)
                guard bang.name != "unknownbang" else { return .unsupported }
                if suspendNames.contains(bang.name) {
                    pending.append((bang, completion))
                    return .suspended
                }
                return .handled
            }
            func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {
                base.skin(skin, forward: bang, toConfig: config)
            }
            func skin(_ skin: Skin, execute target: String, arguments: [String]) {
                base.skin(skin, execute: target, arguments: arguments)
            }
            func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {
                base.skin(skin, log: message, level: level)
            }
            func textSize(_ text: String, style: TextStyle, wrapWidth: Double?,
                          for skin: Skin) -> (width: Double, height: Double) {
                base.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
            }
            func imageSize(atPath path: String) -> (width: Double, height: Double)? { base.imageSize(atPath: path) }
            func environment(for skin: Skin) -> SkinEnvironment { base.environment(for: skin) }
        }

        func makeSuspendedSkin(_ ini: String, files: [String: String] = [:]) throws -> (Skin, SuspendingHost) {
            let host = SuspendingHost()
            let skins = t.temporaryDirectory("suspended-engine").appendingPathComponent("Skins")
            let dir = skins.appendingPathComponent("Root/Sub")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: skins.appendingPathComponent("Root/@Resources"),
                                                    withIntermediateDirectories: true)
            try ini.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
            for (path, text) in files {
                let url = skins.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                            system: FakeSystem(), host: host)
            try skin.load()
            return (skin, host)
        }

        // Direct chain, mouse variable preservation, and chained suspended host bangs.
        do {
            let (skin, host) = try makeSuspendedSkin("""
                [Rainmeter]
                Update=-1
                [Variables]
                MenuKind=9
                MenuCell=0
                MouseSeen=none
                [MeterTile]
                Meter=String
                Text=Tile
                W=80
                H=40
                RightMouseUpAction=[!SetVariable MenuKind 1][!SetVariable MenuCell 4][!SkinCustomMenu][!SetClip "copied"][!SetVariable MouseSeen "$MouseX$,$MouseY$"][!SetVariable MenuKind 9][!SetVariable MenuCell 0]
                """)
            defer { skin.close(); withExtendedLifetime(host) {} }
            skin.update()
            t.equal(skin.mouseEvent(.rightUp, x: 25, y: 15), true)
            t.equal(host.pending.map(\.bang.name), ["skincustommenu"], "first host bang suspended the rest")
            t.equal(skin.variable("MenuKind"), "1", "MenuKind stays at the tile's value while suspended")
            t.equal(skin.variable("MenuCell"), "4", "MenuCell stays at the tile's value while suspended")
            t.equal(skin.variable("MouseSeen"), "none", "later bangs have not run yet")

            guard !host.pending.isEmpty else { return }
            let first = host.pending.removeFirst()
            first.complete()
            t.equal(host.pending.map(\.bang.name), ["setclip"], "second suspended bang in the chain paused again")
            t.equal(skin.variable("MenuKind"), "1", "still waiting for second suspended bang")

            guard !host.pending.isEmpty else { return }
            let second = host.pending.removeFirst()
            second.complete()
            t.equal(host.pending.count, 0)
            t.equal(skin.variable("MouseSeen"), "25,15", "$MouseX$,$MouseY$ preserved across continuations")
            t.equal(skin.variable("MenuKind"), "9", "reset ran after host bangs completed")
            t.equal(skin.variable("MenuCell"), "0")
        }

        // Nested execute (`!UpdateMeasure` -> `IfTrueAction`) unwinds outer action frames in order.
        do {
            let (skin, host) = try makeSuspendedSkin("""
                [Rainmeter]
                Update=-1
                [Variables]
                Triggered=0
                Trace=start
                [MeasureTrigger]
                Measure=Calc
                Formula=#Triggered#
                DynamicVariables=1
                UpdateDivider=-1
                IfConditionMode=1
                IfCondition=MeasureTrigger = 1
                IfTrueAction=[!SetVariable Trace "[#Trace]>inner1"][!SkinCustomMenu][!SetVariable Trace "[#Trace]>inner2"]
                """)
            defer { skin.close(); withExtendedLifetime(host) {} }
            skin.update()
            t.equal(host.pending.count, 0)
            skin.execute("[!SetVariable Triggered 1][!SetVariable Trace begin][!UpdateMeasure MeasureTrigger]"
                         + "[!SetVariable Trace \"[#Trace]>outer2\"]", from: nil)
            t.equal(skin.variable("Trace"), "begin>inner1", "both inner and outer tails wait for the host bang")
            t.equal(host.pending.count, 1)
            guard !host.pending.isEmpty else { return }
            host.pending.removeFirst().complete()
            t.equal(skin.variable("Trace"), "begin>inner1>inner2>outer2", "inner tail finishes before outer tail")
        }

        // Lua `SKIN:Bang` queue suspends remaining queued bangs until the host bang finishes.
        do {
            let script = """
                function Trigger()
                    SKIN:Bang('!SetVariable', 'LuaStep', 'tile')
                    SKIN:Bang('!SkinCustomMenu')
                    SKIN:Bang('!SetVariable', 'LuaStep', 'card')
                end
                """
            let (skin, host) = try makeSuspendedSkin("""
                [Rainmeter]
                Update=-1
                [Variables]
                LuaStep=idle
                [MeasureLua]
                Measure=Script
                ScriptFile=#@#Menu.lua
                """, files: ["Root/@Resources/Menu.lua": script])
            defer { skin.close(); withExtendedLifetime(host) {} }
            skin.update()
            skin.execute(#"[!CommandMeasure MeasureLua "Trigger()"]"#, from: nil)
            t.equal(skin.variable("LuaStep"), "tile", "queued SKIN:Bang after !SkinCustomMenu waits")
            t.equal(host.pending.count, 1)
            guard !host.pending.isEmpty else { return }
            host.pending.removeFirst().complete()
            t.equal(skin.variable("LuaStep"), "card", "remaining SKIN:Bang runs after completion")
        }

        // Independent update callbacks keep their place; an explicit !Update waits for both child actions.
        do {
            let (skin, host) = try makeSuspendedSkin("""
                [Rainmeter]
                Update=-1
                [Variables]
                Ready=0
                [First]
                Measure=Calc
                Formula=1
                OnUpdateAction=[!SkinCustomMenu][!SetVariable FirstDone 1]
                [Second]
                Measure=Calc
                Formula=2
                OnUpdateAction=[!SetVariable Ready 1][!SetClip test][!SetVariable SecondDone 1]
                [Consumer]
                Measure=Calc
                Formula=#Ready#
                DynamicVariables=1
                """)
            defer { skin.close(); withExtendedLifetime(host) {} }
            skin.execute("[!Update][!SetVariable ParentDone 1]", from: nil)
            t.equal(skin.measure(named: "Consumer")?.value, 1, "the next measure saw the producer in this update")
            t.equal(host.pending.map(\.bang.name), ["skincustommenu", "setclip"], "both independent actions started")
            if host.pending.count == 2 {
                host.pending.removeLast().complete()
                t.equal(skin.variable("SecondDone"), "1")
                t.equal(skin.variable("FirstDone"), nil)
                t.equal(skin.variable("ParentDone"), nil, "the caller still waits for the first child")
                host.pending.removeFirst().complete()
                t.equal(skin.variable("FirstDone"), "1")
                t.equal(skin.variable("ParentDone"), "1")
            }
        }

        // A finite chain of nested updates should stop at the same depth on both sides of a host callback.
        do {
            let count = Skin.maxActionDepth + 3
            let measures = (1...count).map { index in
                let next = index < count ? "[!UpdateMeasure Level\(index + 1)]" : ""
                return """
                    [Level\(index)]
                    Measure=Calc
                    Formula=1
                    OnUpdateAction=[!SetVariable Level \(index)][!SkinCustomMenu]\(next)
                    """
            }.joined(separator: "\n")
            func lastLevel(suspending: Bool) throws -> String? {
                let (skin, host) = try makeSuspendedSkin("[Rainmeter]\nUpdate=-1\n" + measures)
                defer { skin.close(); withExtendedLifetime(host) {} }
                if !suspending { host.suspendNames = [] }
                skin.execute("[!UpdateMeasure Level1]", from: nil)
                for _ in 0..<count where !host.pending.isEmpty { host.pending.removeFirst().complete() }
                t.check(host.base.logs.contains { $0.contains("nested too deeply") })
                return skin.variable("Level")
            }
            let synchronous = try lastLevel(suspending: false)
            let resumed = try lastLevel(suspending: true)
            t.check(synchronous != nil)
            t.equal(resumed, synchronous)
        }

        // An update resumed inside OnUpdateAction still counts toward the nested update limit.
        do {
            let (skin, host) = try makeSuspendedSkin("""
                [Rainmeter]
                Update=-1
                [Counter]
                Measure=Calc
                Formula=Counter
                IfConditionMode=1
                IfCondition=Counter < 5
                IfTrueAction=[!SkinCustomMenu][!Update]
                """)
            defer { skin.close(); withExtendedLifetime(host) {} }
            skin.update()
            for _ in 0..<5 where !host.pending.isEmpty { host.pending.removeFirst().complete() }
            t.equal(skin.updateCount, Skin.maxUpdateDepth)
            t.check(host.base.logs.contains { $0.contains("!Update inside an update") })
        }

        // Two pieces share one burst budget even when another input runs between them.
        do {
            let (skin, host) = try makeSuspendedSkin("[Rainmeter]\nUpdate=-1")
            defer { skin.close(); withExtendedLifetime(host) {} }
            let half = String(repeating: "[!ShowBlur]", count: Skin.maxBurstWork / 2)
            skin.execute(half + "[!SkinCustomMenu]" + half + "[!SetVariable OverBudget 1]", from: nil)
            skin.execute("[!SetVariable OtherInput 1]", from: nil)
            host.pending.first?.complete()
            t.equal(skin.variable("OtherInput"), "1")
            t.equal(skin.variable("OverBudget"), nil)
            t.check(host.base.logs.contains { $0.contains("the rest was skipped") })
        }

        // A nested Lua call appends behind already queued bangs. A separate call while the menu is open
        // can run on the same measure. Both suspensions in the click retain its coordinates.
        do {
            let script = """
                function Click()
                    SKIN:Bang('!SkinCustomMenu')
                    SKIN:Bang('!CommandMeasure', 'Script', 'Append()')
                    SKIN:Bang('!SetVariable', 'Order', 'outer')
                end
                function Append()
                    SKIN:Bang('!SetVariable', 'Order', 'inner')
                    SKIN:Bang('!SetClip', 'test')
                    SKIN:Bang('!SetVariable', 'Point', '$MouseX$,$MouseY$')
                end
                """
            let (skin, host) = try makeSuspendedSkin("""
                [Rainmeter]
                Update=-1
                [Script]
                Measure=Script
                ScriptFile=#@#Menu.lua
                [Tile]
                Meter=String
                Text=Tile
                W=80
                H=40
                RightMouseUpAction=[!CommandMeasure Script "Click()"]
                """, files: ["Root/@Resources/Menu.lua": script])
            defer { skin.close(); withExtendedLifetime(host) {} }
            skin.update()
            t.check(skin.mouseEvent(.rightUp, x: 25, y: 15))
            skin.execute(#"[!CommandMeasure Script "SKIN:Bang('!SetVariable', 'Separate', '1')"]"#, from: nil)
            t.equal(skin.variable("Separate"), "1")
            t.equal(skin.variable("Order"), nil)
            t.equal(host.pending.map(\.bang.name), ["skincustommenu"])
            if !host.pending.isEmpty { host.pending.removeFirst().complete() }
            t.equal(host.pending.map(\.bang.name), ["setclip"])
            if !host.pending.isEmpty { host.pending.removeFirst().complete() }
            t.equal(skin.variable("Order"), "inner", "the nested write was enqueued last")
            t.equal(skin.variable("Point"), "25,15")
        }

        // A deferred Lua bang still sees the submitted input and its match after the user edits the field.
        do {
            let (skin, host) = try makeSuspendedSkin("""
                [Rainmeter]
                Update=-1
                [Script]
                Measure=Script
                ScriptFile=#@#Input.lua
                [Input]
                Meter=TextEdit
                W=160
                H=24
                InitialText=Alpha 123
                InputRegExp=^([A-Za-z]+) ([0-9]+)$
                OnSubmitAction=[!CommandMeasure Script "Submit()"]
                """, files: ["Root/@Resources/Input.lua": """
                    function Submit()
                        SKIN:Bang('!SkinCustomMenu')
                        SKIN:Bang('!SetVariable', 'Submitted', '[$Input] / [$Input:Match2]')
                    end
                    """])
            defer { skin.close(); withExtendedLifetime(host) {} }
            skin.update()
            skin.execute("[!TextEdit:Focus Input][!TextEdit:Submit Input]", from: nil)
            t.equal(host.pending.count, 1)
            skin.execute(#"[!TextEdit:SetText Input "Beta 456"]"#, from: nil)
            host.pending.first?.complete()
            t.equal(skin.variable("Submitted"), "Alpha 123 / 123")
        }

        // One measure's actions run in their order across a host wait, as with a host that finishes at once: its
        // OnUpdateAction waits for an IfTrueAction's menu, while the measure after it in the update goes on, and an
        // action that updated the measure waits for the whole pass.
        do {
            let ini = """
                [Rainmeter]
                Update=-1
                [Variables]
                Trace=start
                Armed=0
                [Tile]
                Measure=Calc
                Formula=#Armed#
                DynamicVariables=1
                IfConditionMode=1
                IfCondition=Tile = 1
                IfTrueAction=[!SetVariable Trace "[#Trace]>menu"][!SkinCustomMenu][!SetVariable Trace "[#Trace]>reset"]
                IfMatch=^1$
                IfMatchAction=[!SetVariable Trace "[#Trace]>match"]
                OnUpdateAction=[!SetVariable Trace "[#Trace]>update"]
                [Next]
                Measure=Calc
                Formula=1
                OnUpdateAction=[!SetVariable NextSaw "[#Trace]"]
                """
            func traces(suspending: Bool) throws -> [String?] {
                let (skin, host) = try makeSuspendedSkin(ini)
                defer { skin.close(); withExtendedLifetime(host) {} }
                if !suspending { host.suspendNames = [] }
                skin.update()
                skin.execute("[!SetVariable Armed 1][!SetVariable Trace begin]", from: nil)
                skin.update()
                if suspending {
                    t.equal(skin.variable("Trace"), "begin>menu", "the measure's later actions wait for the menu")
                    t.equal(skin.variable("NextSaw"), "begin>menu", "the next measure did not wait")
                    t.equal(host.pending.map(\.bang.name), ["skincustommenu"])
                }
                while !host.pending.isEmpty { host.pending.removeFirst().complete() }
                let first = skin.variable("Trace")
                skin.execute("[!SetVariable Trace again][!UpdateMeasure Tile][!SetVariable Trace \"[#Trace]>after\"]",
                             from: nil)
                if suspending {
                    t.equal(skin.variable("Trace"), "again>menu", "the caller waits for the measure's whole pass")
                }
                while !host.pending.isEmpty { host.pending.removeFirst().complete() }
                return [first, skin.variable("Trace")]
            }
            let synchronous = try traces(suspending: false)
            t.equal(synchronous, ["begin>menu>reset>match>update", "again>menu>reset>update>after"])
            t.equal(try traces(suspending: true), synchronous, "the same order as a host that finishes at once")
        }

        // Resolving a filtered command can still start a host request in inline Lua.
        do {
            final class FilteringPolicy: SkinActionPolicy {
                func skin(_ skin: Skin, allows bang: Bang) -> Bool { bang.name != "hide" }
                func skin(_ skin: Skin, allowsExecuting target: String, arguments: [String]) -> Bool { false }
            }
            let (skin, host) = try makeSuspendedSkin("""
                [Rainmeter]
                Update=-1
                [Script]
                Measure=Script
                ScriptFile=#@#Argument.lua
                """, files: ["Root/@Resources/Argument.lua": """
                    function Argument()
                        SKIN:Bang('!SetClip', 'argument')
                        SKIN:Bang('!SetVariable', 'Step', 'between')
                        return 'unused'
                    end
                    """])
            defer { skin.close(); withExtendedLifetime(host) {} }
            skin.update()
            skin.actionPolicy = FilteringPolicy()
            for filtered in [#"[!Hide "[&Script:Argument()]"]"#, #"["unused" "[&Script:Argument()]"]"#] {
                skin.execute("[!SetVariable Step before]" + filtered
                             + #"[!SetClip "[#Step]"][!SetVariable Step done]"#, from: nil)
                t.equal(skin.variable("Step"), "before")
                t.equal(host.pending.map { $0.bang.args }, [["argument"]], "the next host request waits for the argument")
                if !host.pending.isEmpty { host.pending.removeFirst().complete() }
                t.equal(skin.variable("Step"), "between")
                t.equal(host.pending.map { $0.bang.args }, [["between"]])
                if !host.pending.isEmpty { host.pending.removeFirst().complete() }
                t.equal(skin.variable("Step"), "done")
            }
            t.check(!host.base.handled.contains { $0.name == "hide" })
            t.check(host.base.executed.isEmpty)
        }

        // Closing the skin cancels pending host continuations safely.
        do {
            let (skin, host) = try makeSuspendedSkin("""
                [Rainmeter]
                Update=-1
                [Variables]
                State=open
                """)
            defer { withExtendedLifetime(host) {} }
            skin.update()
            skin.execute("[!SkinCustomMenu][!SetVariable State afterClose]", from: nil)
            t.equal(host.pending.count, 1)
            skin.close()
            guard !host.pending.isEmpty else { return }
            host.pending.removeFirst().complete()
            t.equal(skin.variable("State"), "open", "closed skin ignores late continuation")
        }
    }
}

/// Deterministic PRNG for the fuzz tests.
fileprivate struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
