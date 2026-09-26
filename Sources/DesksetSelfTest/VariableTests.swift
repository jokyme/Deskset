import Foundation
@testable import DesksetCore

// Tests for the variables module. Every rule/example from these manual pages is covered:
//   /manual/variables/, /nesting-variables/, /built-in-variables/, /section-variables/, /character-variables/,
//   /mouse-variables/, /tips/setoption-guide/, /tips/dynamiccheatsheet/.

// MARK: - Fixtures

private struct VTMeasure {
    var string: String
    var number: Double
    var min: Double = 0
    var max: Double = 1
    var timestamp: Double? = nil
}

private struct VTMeter {
    var x: Int, y: Int, w: Int, h: Int
}

/// Section lookup that behaves like the engine will: measures answer string/number/keywords, meters only
/// answer X/Y/W/H/XW/YH, anything else → nil.
private func vtSectionLookup(measures: [String: VTMeasure], meters: [String: VTMeter] = [:])
    -> (String, SectionVariableParameter) -> String? {
    var ms: [String: VTMeasure] = [:]
    for (k, v) in measures { ms[k.lowercased()] = v }
    var mt: [String: VTMeter] = [:]
    for (k, v) in meters { mt[k.lowercased()] = v }
    return { name, param in
        let key = name.lowercased()
        if let m = ms[key] {
            switch param {
            case .none: return m.string
            case .number(let f): return f.format(value: m.number, minValue: m.min, maxValue: m.max)
            case .keyword:
                switch param.knownKeyword {
                case .maxValue?: return SectionNumberFormat().format(value: m.max, minValue: 0, maxValue: 1)
                case .minValue?: return SectionNumberFormat().format(value: m.min, minValue: 0, maxValue: 1)
                case .escapeRegExp?: return SectionVariables.escapeRegExp(m.string)
                case .encodeUrl?: return SectionVariables.encodeUrl(m.string)
                case .timestamp?: return m.timestamp.map { SectionNumberFormat().format(value: $0, minValue: 0, maxValue: 1) }
                default: return nil
                }
            }
        }
        if let r = mt[key] {
            switch param.knownKeyword {
            case .x?: return String(r.x)
            case .y?: return String(r.y)
            case .w?: return String(r.w)
            case .h?: return String(r.h)
            case .xw?: return String(r.x + r.w)
            case .yh?: return String(r.y + r.h)
            default: return nil   // "Section variables for meters have no value without a parameter."
            }
        }
        return nil
    }
}

private func vtVariables(_ vars: [String: String]) -> (String) -> String? {
    var table: [String: String] = [:]
    for (k, v) in vars { table[k.lowercased()] = v }
    return { table[$0.lowercased()] }
}

/// Resolver with section variables (a DynamicVariables=1 option or a bang).
private func vtDynamic(_ vars: [String: String], measures: [String: VTMeasure] = [:],
                       meters: [String: VTMeter] = [:]) -> VariableResolver {
    VariableResolver(variableLookup: vtVariables(vars), sectionLookup: vtSectionLookup(measures: measures, meters: meters))
}

/// Resolver without section variables (a non-dynamic option).
private func vtStatic(_ vars: [String: String]) -> VariableResolver {
    VariableResolver(variableLookup: vtVariables(vars))
}

/// Deterministic PRNG for the fuzz tests.
private struct VTRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

func runVariableTests(_ t: TestRunner) {
    variableBasicsTests(t)
    variableRecursionTests(t)
    variableEscapeTests(t)
    variableNestingTests(t)
    variableSectionTests(t)
    variableCharacterTests(t)
    variableEventTests(t)
    variableParameterTests(t)
    variableNumberFormatTests(t)
    variableKeywordHelperTests(t)
    variableDefinitionTests(t)
    variableBuiltInTests(t)
    variableStandardOnlyTests(t)
    variableRobustnessTests(t)
    variableReviewTests(t)
}

// MARK: - #Var#

private func variableBasicsTests(_ t: TestRunner) {
    t.suite("Variables: #Var# basics") {
        // Manual: [Variables] MyVar1=This is a string! … Text=The value of "MyVar1" is: #MyVar1#
        let vars = ["MyVar1": "This is a string!", "MyVar2": "So is this!",
                    "Red": "255", "Green": "150", "Blue": "0", "Alpha": "90"]
        let r = vtStatic(vars)
        t.equal(r.resolve("The value of \"MyVar1\" is: #MyVar1#"), "The value of \"MyVar1\" is: This is a string!")
        t.equal(r.resolve("#Red#,#Green#,#Blue#,#Alpha#"), "255,150,0,90")
        // Case-insensitive names.
        t.equal(r.resolve("#myvar2#|#MYVAR2#|#mYvAr2#"), "So is this!|So is this!|So is this!")
        // Mixed with text, adjacent references.
        t.equal(r.resolve("#Red##Green#"), "255150")
        t.equal(r.resolve("x#Red#y"), "x255y")
        // Undefined names are left as written.
        t.equal(r.resolve("#Undefined#"), "#Undefined#")
        t.equal(r.resolve("a #Nope# b #Red#"), "a #Nope# b 255")
        // A lone # or ## is plain text; the closing # of a failed candidate can open the next reference.
        t.equal(r.resolve("#"), "#")
        t.equal(r.resolve("##"), "##")
        t.equal(r.resolve("###"), "###")
        t.equal(r.resolve("#1 fan"), "#1 fan")
        t.equal(r.resolve("#1 and #Red#"), "#1 and 255")
        t.equal(r.resolve("#A#Red#"), "#A255")
        t.equal(r.resolve("##Red##"), "#255#")
        t.equal(r.resolve("Red#"), "Red#")
        t.equal(r.resolve("#Red"), "#Red")
        t.equal(r.resolve(""), "")
        t.equal(r.resolve("no syntax at all"), "no syntax at all")
        // Unicode around references is kept intact.
        t.equal(r.resolve("温度 #Red#°C ☃"), "温度 255°C ☃")
        let u = vtStatic(["名前": "値"])
        t.equal(u.resolve("[#名前] #名前#"), "値 値")
        // Empty value.
        t.equal(vtStatic(["E": ""]).resolve("<#E#>"), "<>")
    }

    t.suite("Variables: fast path makes no lookups") {
        var calls = 0
        let r = VariableResolver(variableLookup: { _ in calls += 1; return "x" },
                                 sectionLookup: { _, _ in calls += 1; return "y" })
        t.equal(r.resolve("plain text 100% $5"), "plain text 100% $5")
        t.equal(calls, 0)
        // Returned unchanged when a candidate does not resolve.
        let r2 = VariableResolver(variableLookup: { _ in nil }, sectionLookup: { _, _ in nil })
        t.equal(r2.resolve("[!SetOption A B C] #x# [y]"), "[!SetOption A B C] #x# [y]")
    }
}

// MARK: - Recursion

private func variableRecursionTests(_ t: TestRunner) {
    t.suite("Variables: values are resolved further") {
        // Manual: MyVar2=https://www.#MyVar1#.net/ (variables define other variables).
        let r = vtStatic(["MyVar1": "rainmeter", "MyVar2": "https://www.#MyVar1#.net/"])
        t.equal(r.resolve("#MyVar2#"), "https://www.rainmeter.net/")
        t.equal(r.resolve("[#MyVar2]"), "https://www.rainmeter.net/")
        // Chains.
        let chain = vtStatic(["A": "#B#-a", "B": "#C#-b", "C": "c"])
        t.equal(chain.resolve("#A#"), "c-b-a")
        // Nested syntax inside a value.
        let nested = vtStatic(["A": "[#B]!", "B": "b", "Idx": "2", "Color2": "red", "Pick": "[#Color[#Idx]]"])
        t.equal(nested.resolve("#A#"), "b!")
        t.equal(nested.resolve("#Pick#"), "red")
        // A value containing a section variable is resolved when section variables are on.
        let d = vtDynamic(["CpuText": "[MeasureCPU]%"], measures: ["MeasureCPU": VTMeasure(string: "42", number: 42)])
        t.equal(d.resolve("CPU #CpuText#"), "CPU 42%")
        t.equal(vtStatic(["CpuText": "[MeasureCPU]%"]).resolve("CPU #CpuText#"), "CPU [MeasureCPU]%")
        // #CURRENTSECTION# inside a variable value is answered by the lookup where the variable is used.
        let cs = vtStatic(["Name": "Meter-#CURRENTSECTION#", "CURRENTSECTION": "Clock"])
        t.equal(cs.resolve("#Name#"), "Meter-Clock")
    }

    t.suite("Variables: self-reference and cycles terminate") {
        let r = vtStatic(["A": "#A#", "B": "#C#", "C": "#B#", "D": "x#D#y", "E": "[#E]", "F": "#G#", "G": "[#F]"])
        t.equal(r.resolve("#A#"), "#A#")
        t.equal(r.resolve("[#A]"), "#A#")
        t.equal(r.resolve("#B#"), "#B#")
        t.equal(r.resolve("#C#"), "#C#")
        t.equal(r.resolve("#D#"), "x#D#y")
        t.equal(r.resolve("[#E]"), "[#E]")
        t.equal(r.resolve("#F#"), "[#F]")
        // The same variable may be used many times side by side (not a cycle).
        let s = vtStatic(["X": "x", "Y": "#X##X#"])
        t.equal(s.resolve("#Y##Y#[#Y]"), "xxxxxx")
        // With section lookup as well.
        let d = vtDynamic(["A": "#A#[#A]"])
        t.equal(d.resolve("#A#"), "#A#[#A]")
    }

    t.suite("Variables: exponential expansion is capped") {
        var vars: [String: String] = ["V30": "abcdefgh"]
        for i in 0..<30 { vars["V\(i)"] = "#V\(i + 1)##V\(i + 1)#" }
        // The lookup count is the real bound on the work; the time limit only tells "finishes" from "never
        // finishes" (a slow CI runner, debug build, may need seconds).
        var lookups = 0
        let lookup = vtVariables(vars)
        let r = VariableResolver(variableLookup: { lookups += 1; return lookup($0) },
                                 sectionLookup: vtSectionLookup(measures: [:], meters: [:]))
        let start = Date()
        let out = r.resolve("#V0#")
        let elapsed = Date().timeIntervalSince(start)
        t.check(out.utf8.count <= (1 << 20) + 1000, "output bounded: \(out.utf8.count)")
        t.check(lookups <= VarExpansion.maxLookups, "lookups: \(lookups)")
        t.check(elapsed < 60, "took \(elapsed)s")
        // Deep but legal chains of distinct variables resolve up to 32 levels.
        var deep: [String: String] = ["L20": "end"]
        for i in 0..<20 { deep["L\(i)"] = "#L\(i + 1)#" }
        t.equal(vtStatic(deep).resolve("#L0#"), "end")
        var tooDeep: [String: String] = ["M100": "end"]
        for i in 0..<100 { tooDeep["M\(i)"] = "#M\(i + 1)#" }
        let partial = vtStatic(tooDeep).resolve("#M0#")
        t.check(partial.hasPrefix("#M") && partial.hasSuffix("#"), "left as written past the limit: \(partial)")
    }
}

// MARK: - Escapes

private func variableEscapeTests(_ t: TestRunner) {
    t.suite("Variables: escapes") {
        let vars = ["MyColor": "255,255,255,255", "VarName": "v"]
        let measures = ["MeasureTime2": VTMeasure(string: "42", number: 42), "MeasureName": VTMeasure(string: "m", number: 1)]
        let d = vtDynamic(vars, measures: measures)
        let s = vtStatic(vars)
        // Manual: #*VarName*#, [*MeasureName*], [#*VarName*], [&*MeasureName*] → literal without the *.
        t.equal(d.resolve("#*VarName*#"), "#VarName#")
        t.equal(d.resolve("[*MeasureName*]"), "[MeasureName]")
        t.equal(d.resolve("[#*VarName*]"), "[#VarName]")
        t.equal(d.resolve("[&*MeasureName*]"), "[&MeasureName]")
        // SetOption guide examples (bang strings are resolved with section variables on).
        t.equal(d.resolve("!SetOption MeterOne FontColor #*MyColor*#"), "!SetOption MeterOne FontColor #MyColor#")
        t.equal(d.resolve("!SetOption MeterOne FontColor #MyColor#"), "!SetOption MeterOne FontColor 255,255,255,255")
        t.equal(d.resolve("!SetOption MeterOne Text [*MeasureTime2*]"), "!SetOption MeterOne Text [MeasureTime2]")
        t.equal(d.resolve("!SetOption MeterOne Text [MeasureTime2]"), "!SetOption MeterOne Text 42")
        t.equal(d.resolve("[!SetOption MeterOne Text [*MeasureTime2*]][!UpdateMeter MeterOne]"),
                "[!SetOption MeterOne Text [MeasureTime2]][!UpdateMeter MeterOne]")
        // Escapes work even for undefined names.
        t.equal(d.resolve("#*Nope*#"), "#Nope#")
        t.equal(d.resolve("[*Nope*]"), "[Nope]")
        // Escaped output is not resolved again in the same pass.
        t.equal(d.resolve("#*MyColor*##MyColor#"), "#MyColor#255,255,255,255")
        t.equal(d.resolve("[#*MyColor*][#MyColor]"), "[#MyColor]255,255,255,255")
        // Double escaping gives two levels of protection.
        t.equal(d.resolve("#**MyColor**#"), "#*MyColor*#")
        t.equal(d.resolve("[**MeasureTime2**]"), "[*MeasureTime2*]")
        // Section-variable escapes are only consumed where section variables are resolved.
        t.equal(s.resolve("[*MeasureName*]"), "[*MeasureName*]")
        t.equal(s.resolve("[&*MeasureName*]"), "[&*MeasureName*]")
        t.equal(s.resolve("#*VarName*#"), "#VarName#")
        t.equal(s.resolve("[#*VarName*]"), "[#VarName]")
        // Not escapes: too short.
        t.equal(d.resolve("#*#"), "#*#")
        t.equal(d.resolve("#**#"), "#**#")
        t.equal(d.resolve("[*]"), "[*]")
        t.equal(d.resolve("[**]"), "[**]")
        // An escape stored in a variable is unescaped when the variable is used.
        let viaVar = vtDynamic(["Esc": "#*MyColor*#", "MyColor": "1,2,3"])
        t.equal(viaVar.resolve("#Esc#"), "#MyColor#")
        // Resolving the result again resolves what the escape protected (why resolve() runs once per raw string).
        t.equal(d.resolve(d.resolve("#*MyColor*#")), "255,255,255,255")
    }
}

// MARK: - Nesting

private func variableNestingTests(_ t: TestRunner) {
    t.suite("Variables: nesting examples from the manual") {
        // Example 1: Text=[&MeasureString[#Var1]]#CRLF#[&MeasureString[#Var2]]
        let m1: [String: VTMeasure] = [
            "MeasureStringOne": VTMeasure(string: "I'm the first Measure", number: 0),
            "MeasureStringTwo": VTMeasure(string: "I'm the second Measure", number: 0),
            "MeasureNum3": VTMeasure(string: "3", number: 3),
            "MeasureNum4": VTMeasure(string: "4", number: 4),
            "MeasureString3": VTMeasure(string: "I'm the third Measure", number: 0),
            "MeasureString4": VTMeasure(string: "I'm the fourth Measure", number: 0),
        ]
        let r1 = vtDynamic(["Var1": "One", "Var2": "Two", "CRLF": "\n"], measures: m1)
        t.equal(r1.resolve("[&MeasureString[#Var1]]#CRLF#[&MeasureString[#Var2]]"),
                "I'm the first Measure\nI'm the second Measure")
        t.equal(r1.resolve("[&MeasureString[&MeasureNum3]]#CRLF#[&MeasureString[&MeasureNum4]]"),
                "I'm the third Measure\nI'm the fourth Measure")
        // Example 2: Text=[&Measure[&MeasureRandom]]
        var m2: [String: VTMeasure] = ["MeasureRandom": VTMeasure(string: "3", number: 3)]
        for (i, word) in ["One", "Two", "Three", "Four", "Five"].enumerated() {
            m2["Measure\(i + 1)"] = VTMeasure(string: "I'm \(word)", number: 0)
        }
        t.equal(vtDynamic([:], measures: m2).resolve("[&Measure[&MeasureRandom]]"), "I'm Three")
        // Example 3: X=[#XPos[&MeasureRandom]]
        let xpos = ["XPos1": "15", "XPos2": "10", "XPos3": "30", "XPos4": "100", "XPos5": "0"]
        t.equal(vtDynamic(xpos, measures: m2).resolve("[#XPos[&MeasureRandom]]"), "30")
        // The forms the page lists as replacements for the ambiguous ones.
        let vars = ["MyVar": "A", "MyOtherVar": "B", "MyVarB": "var-b", "MyVarM": "var-m"]
        let meas: [String: VTMeasure] = ["MyMeasure": VTMeasure(string: "M", number: 0),
                                         "MyOtherMeasure": VTMeasure(string: "X", number: 0),
                                         "MyMeasureA": VTMeasure(string: "meas-a", number: 0),
                                         "MyMeasureX": VTMeasure(string: "meas-x", number: 0)]
        let r = vtDynamic(vars, measures: meas)
        t.equal(r.resolve("[#MyVar[#MyOtherVar]]"), "var-b")
        t.equal(r.resolve("[#MyVar[&MyMeasure]]"), "var-m")
        t.equal(r.resolve("[&MyMeasure[#MyVar]]"), "meas-a")
        t.equal(r.resolve("[&MyMeasure[&MyOtherMeasure]]"), "meas-x")
        // Nested section variables take parameters: [&MeasureName:EncodeURL]
        let enc = vtDynamic([:], measures: ["MeasureName": VTMeasure(string: "I live in München", number: 5, max: 10)])
        t.equal(enc.resolve("[&MeasureName:EncodeURL]"), "I%20live%20in%20M%C3%BCnchen")
        t.equal(enc.resolve("[&MeasureName:%,0]"), "50")
        t.equal(enc.resolve("[&MeasureName:]"), "5")
    }

    t.suite("Variables: nesting rules") {
        let vars = ["Color1": "red", "Color2": "green", "Index": "2", "Idx": "1", "Deep1": "d1", "N": "1",
                    "Name": "MeasureA", "Foo": "Measure", "Bar": "A", "CURRENTSECTION": "MeterX"]
        let meas: [String: VTMeasure] = ["MeasureA": VTMeasure(string: "a-value", number: 0.25),
                                         "MeasureB": VTMeasure(string: "B", number: 0),
                                         "Item1": VTMeasure(string: "item-one", number: 0),
                                         "ValueMeterX": VTMeasure(string: "vx", number: 0)]
        let d = vtDynamic(vars, measures: meas)
        let s = vtStatic(vars)
        t.equal(s.resolve("[#Color[#Index]]"), "green")
        t.equal(s.resolve("[#Color[#Idx]]/[#Color[#Index]]"), "red/green")
        t.equal(s.resolve("[#Deep[#N]]"), "d1")
        t.equal(s.resolve("[#Color[#Color[#Index]]]"), "[#Colorgreen]")   // inner resolved, outer undefined
        // [#Var] works without DynamicVariables (it is a variable), [&Measure] does not.
        t.equal(s.resolve("[#Index]"), "2")
        t.equal(s.resolve("[&MeasureA]"), "[&MeasureA]")
        t.equal(s.resolve("[&Item[#Idx]]"), "[&Item1]")                   // inner still resolved
        t.equal(d.resolve("[&Item[#Idx]]"), "item-one")
        // Undefined / malformed stay as written.
        t.equal(s.resolve("[#Nope]"), "[#Nope]")
        t.equal(s.resolve("[#]"), "[#]")
        t.equal(d.resolve("[&]"), "[&]")
        t.equal(d.resolve("[&:2]"), "[&:2]")
        t.equal(s.resolve("[#Index"), "[#Index")
        t.equal(s.resolve("[#Color[#Index]"), "[#Color2")                 // unterminated outer, inner resolved
        t.equal(s.resolve("x[#Index]y[#Index"), "x2y[#Index")
        t.equal(s.resolve("[[#Index]]"), "[2]")
        t.equal(d.resolve("[&Nope:2]"), "[&Nope:2]")
        // A classic section variable can be built from a nested variable: the value is text.
        t.equal(d.resolve("[[#Name]]"), "a-value")
        t.equal(d.resolve("[Measure[#Bar]]"), "a-value")
        // Variables first: [#Foo#:#Bar#] style.
        t.equal(d.resolve("[#Foo#A:2]"), "0.25")
        t.equal(d.resolve("[&#Foo##Bar#]"), "a-value")
        // Frozen built-in values can still be part of a name.
        t.equal(d.resolve("[&Value#CURRENTSECTION#]"), "vx")
        t.equal(d.resolve("[#CURRENTSECTION]"), "MeterX")
        // Bang strings keep their brackets while nested parts resolve.
        t.equal(d.resolve("[!SetOption Meter Text \"[#Color[#Index]]\"][!UpdateMeter Meter]"),
                "[!SetOption Meter Text \"green\"][!UpdateMeter Meter]")
        t.equal(d.resolve("[!SetVariable Idx [&MeasureA:1]]"), "[!SetVariable Idx 0.3]")
    }
}

// MARK: - Section variables

private func variableSectionTests(_ t: TestRunner) {
    t.suite("Variables: section variables") {
        let meas: [String: VTMeasure] = [
            "MeasureCPU": VTMeasure(string: "23.5", number: 23.456789, min: 0, max: 100),
            "MeasureDisk": VTMeasure(string: "big", number: 1536, min: 0, max: 2048),
            "MeasureText": VTMeasure(string: "a.b*c", number: 0),
            "MeasureTime": VTMeasure(string: "12:30", number: 0, timestamp: 13_300_000_000),
            "MeasureTricky": VTMeasure(string: "#MyVar# [MeasureCPU] [#MyVar] [\\x41]", number: 0),
        ]
        let meters = ["MeterA": VTMeter(x: 10, y: 20, w: 30, h: 40)]
        let d = vtDynamic(["MyVar": "v", "Foo": "MeasureDisk", "Bar": "/1024,2"], measures: meas, meters: meters)
        // [MeasureName] → string; [MeasureName:] → number with up to 10 decimals.
        t.equal(d.resolve("[MeasureCPU]"), "23.5")
        t.equal(d.resolve("[MeasureCPU:]"), "23.456789")
        t.equal(d.resolve("[MeasureCPU:4]"), "23.4568")
        t.equal(d.resolve("[MeasureCPU:0]"), "23")
        t.equal(d.resolve("[MeasureDisk:/1024]"), "1.5")
        t.equal(d.resolve("[MeasureDisk:/1024,4]"), "1.5000")
        t.equal(d.resolve("[MeasureDisk:%]"), "75")
        t.equal(d.resolve("[MeasureDisk:%,4]"), "75.0000")
        t.equal(d.resolve("[MeasureDisk:/1024,%]"), "0.0732421875")
        t.equal(d.resolve("[MeasureDisk:/1024,4,%]"), "0.0732")
        t.equal(d.resolve("[MeasureDisk:MaxValue]"), "2048")
        t.equal(d.resolve("[MeasureDisk:MinValue]"), "0")
        t.equal(d.resolve("[MeasureText:EscapeRegExp]"), "a\\.b\\*c")
        t.equal(d.resolve("[MeasureTime:Timestamp]"), "13300000000")
        t.equal(d.resolve("[MeasureCPU:Timestamp]"), "[MeasureCPU:Timestamp]")
        // Case-insensitive section names and keywords.
        t.equal(d.resolve("[measurecpu]/[MEASUREDISK:maxvalue]"), "23.5/2048")
        // Meter parameters; a meter has no value without a parameter.
        t.equal(d.resolve("[MeterA:X],[MeterA:Y],[MeterA:W],[MeterA:H],[MeterA:XW],[MeterA:YH]"),
                "10,20,30,40,40,60")
        t.equal(d.resolve("[MeterA]"), "[MeterA]")
        // Formula usage from the manual: X=([Measure] < 6 ? 0 : 10)
        t.equal(d.resolve("([MeasureDisk:/1024] < 6 ? 0 : 10)"), "(1.5 < 6 ? 0 : 10)")
        // Normal variables first: [#Foo#:#Bar#] works…
        t.equal(d.resolve("[#Foo#:#Bar#]"), "1.50")
        // …the reverse #[Foo][Bar]# is not valid (the section values are not re-read as a variable name)…
        let rev = vtDynamic(["AB": "x"], measures: ["Foo": VTMeasure(string: "A", number: 0),
                                                    "Bar": VTMeasure(string: "B", number: 0)])
        t.equal(rev.resolve("#[Foo][Bar]#"), "#AB#")
        // …and the nesting form [#[&Foo][&Bar]] is the fix.
        t.equal(rev.resolve("[#[&Foo][&Bar]]"), "x")
        // Values are literal: text inside a measure value is not resolved again.
        t.equal(d.resolve("[MeasureTricky]"), "#MyVar# [MeasureCPU] [#MyVar] [\\x41]")
        t.equal(d.resolve("[&MeasureTricky]"), "#MyVar# [MeasureCPU] [#MyVar] [\\x41]")
        // Unknown sections, bangs and literal brackets survive untouched.
        t.equal(d.resolve("[Rainmeter]"), "[Rainmeter]")
        t.equal(d.resolve("[!SetOption A B C]"), "[!SetOption A B C]")
        t.equal(d.resolve("[!SetOption Meter Text [MeasureCPU]][!Redraw]"), "[!SetOption Meter Text 23.5][!Redraw]")
        t.equal(d.resolve("[\"https://example.com/?q=[MeasureCPU]\"]"), "[\"https://example.com/?q=23.5\"]")
        t.equal(d.resolve("Array[0] [] [ ] [[ ]] ]["), "Array[0] [] [ ] [[ ]] ][")
        t.equal(d.resolve("[[MeasureCPU]]"), "[23.5]")
        t.equal(d.resolve("[MeasureCPU"), "[MeasureCPU")
        t.equal(d.resolve("MeasureCPU]"), "MeasureCPU]")
        t.equal(d.resolve("[MeasureCPU:NotAKeyword]"), "[MeasureCPU:NotAKeyword]")
        t.equal(d.resolve("[MeasureCPU:/0]"), "[MeasureCPU:/0]")
        t.equal(d.resolve("[:2]"), "[:2]")
        // Without section lookup nothing bracketed changes (non-dynamic option).
        let s = vtStatic(["MyVar": "v"])
        t.equal(s.resolve("[MeasureCPU] [MeasureCPU:2] #MyVar#"), "[MeasureCPU] [MeasureCPU:2] v")
    }

    t.suite("Variables: section lookup receives parsed parameters") {
        var names: [String] = []
        var params: [SectionVariableParameter] = []
        let r = VariableResolver(variableLookup: { _ in nil }, sectionLookup: { name, param in
            names.append(name)
            params.append(param)
            return nil
        })
        _ = r.resolve("[M] [M:] [M:2] [M:MaxValue] [M:a:b] [&N:%,1] [Sp ace:/8]")
        // Nesting forms are resolved (stage 2) before classic section variables (stage 3).
        t.equal(names, ["N", "M", "M", "M", "M", "M", "Sp ace"])
        t.equal(params, [.number(SectionNumberFormat(percent: true, decimals: 1)),
                         .none, .number(SectionNumberFormat()), .number(SectionNumberFormat(decimals: 2)),
                         .keyword("MaxValue"), .keyword("a:b"),
                         .number(SectionNumberFormat(divisor: 8))])
        // Bangs, leftovers of nesting syntax and empty brackets never reach the lookup.
        names = []
        _ = r.resolve("[!Refresh][] [#Undefined] [&Undefined] [\\x] [$X]")
        t.equal(names, ["Undefined"])   // only the nested [&Undefined] asks
    }
}

// MARK: - Character variables

private func variableCharacterTests(_ t: TestRunner) {
    t.suite("Variables: character variables") {
        let s = vtStatic(["VariableName": "9731", "fa-Raindrop": "[\\xf043]", "u-Degree": "[\\x00B0]", "Hex": "x263A"])
        // Manual: [\x2622] and [\9762] both give ☢; works without DynamicVariables.
        t.equal(s.resolve("Caution, radioactivity [\\x2622] ahead!"), "Caution, radioactivity ☢ ahead!")
        t.equal(s.resolve("[\\9762]"), "☢")
        t.equal(s.resolve("[\\x263A][\\9731]"), "☺☃")
        t.equal(s.resolve("[\\X263a]"), "☺")
        t.equal(s.resolve("[\\x0]"), "\u{0}")
        t.equal(s.resolve("[\\0]"), "\u{0}")
        t.equal(s.resolve("[\\xFFFE]"), "\u{FFFE}")
        t.equal(s.resolve("[\\65536]"), "\u{10000}")
        // [\13][\10] → CR LF (built-in variables page).
        t.equal(s.resolve("a[\\13][\\10]b"), "a\r\nb")
        // Through variables (manual example: fa-Raindrop=[\xf043], used as #fa-Raindrop#).
        t.equal(s.resolve("#fa-Raindrop# #u-Degree#"), "\u{F043} °")
        t.equal(s.resolve("[\\xf0e7]|#fa-Raindrop#|[\\xf241]"), "\u{F0E7}|\u{F043}|\u{F241}")
        // Nested: [\[#VariableName]] and [\[&MeasureName]].
        t.equal(s.resolve("[\\[#VariableName]]"), "☃")
        t.equal(s.resolve("[\\[#Hex]]"), "☺")
        let d = vtDynamic([:], measures: ["MeasureName": VTMeasure(string: "9762", number: 9762)])
        t.equal(d.resolve("[\\[&MeasureName]]"), "☢")
        t.equal(s.resolve("[\\[&MeasureName]]"), "[\\[&MeasureName]]")
        // Beyond the BMP (superset of the manual's range).
        t.equal(s.resolve("[\\x1F600]"), "😀")
        // Output is literal: [ and # produced by character variables are not syntax.
        let v = vtDynamic(["A": "value"], measures: ["M": VTMeasure(string: "m", number: 0)])
        t.equal(v.resolve("[\\x5B]M[\\x5D]"), "[M]")
        t.equal(v.resolve("[\\x23]A[\\x23]"), "#A#")
        t.equal(v.resolve("[\\91]#A#[\\93]"), "[value]")
        // Invalid bodies stay as written.
        t.equal(s.resolve("[\\]"), "[\\]")
        t.equal(s.resolve("[\\x]"), "[\\x]")
        t.equal(s.resolve("[\\xZZ]"), "[\\xZZ]")
        t.equal(s.resolve("[\\12a]"), "[\\12a]")
        t.equal(s.resolve("[\\x 263A]"), "[\\x 263A]")
        t.equal(s.resolve("[\\x110000]"), "[\\x110000]")
        t.equal(s.resolve("[\\xD800]"), "[\\xD800]")
        t.equal(s.resolve("[\\99999999999]"), "[\\99999999999]")
        t.equal(s.resolve("[\\x123456789]"), "[\\x123456789]")
        t.equal(s.resolve("[\\-1]"), "[\\-1]")
        // Windows paths are not character variables.
        t.equal(s.resolve("[\\\\server\\share]"), "[\\\\server\\share]")
        t.equal(s.resolve("[\"C:\\x.exe\"]"), "[\"C:\\x.exe\"]")
    }
}

// MARK: - Event (mouse) variables

private func variableEventTests(_ t: TestRunner) {
    t.suite("Variables: event variables") {
        let events: [String: String] = ["MouseX": "12", "MouseY": "34", "MouseX:%": "50", "MouseY:%": "75"]
        let r = VariableResolver(variableLookup: vtVariables(["V": "v"]),
                                 sectionLookup: vtSectionLookup(measures: [:]),
                                 eventLookup: { events[$0] })
        // Manual examples.
        t.equal(r.resolve("[!SetOption SomeMeter X $MouseX$][!UpdateMeter *][!Redraw]"),
                "[!SetOption SomeMeter X 12][!UpdateMeter *][!Redraw]")
        t.equal(r.resolve("!CommandMeasure ScriptMeasure GetRGB($MouseX$,$MouseY$)"),
                "!CommandMeasure ScriptMeasure GetRGB(12,34)")
        t.equal(r.resolve("[!SetOption CoordinateB Text \"X = $MouseX:%$%, Y = $MouseY:%$%\"]"),
                "[!SetOption CoordinateB Text \"X = 50%, Y = 75%\"]")
        t.equal(r.resolve("[!SetOption CoordinateA Text \"($MouseX$, $MouseY$)\"]"),
                "[!SetOption CoordinateA Text \"(12, 34)\"]")
        // Nesting form [$MouseX].
        t.equal(r.resolve("[$MouseX],[$MouseY:%]"), "12,75")
        // Unknown names and plain dollars stay.
        t.equal(r.resolve("$5 and $10 $UserInput$ #V#"), "$5 and $10 $UserInput$ v")
        t.equal(r.resolve("[$Nope]"), "[$Nope]")
        t.equal(r.resolve("$"), "$")
        // Without an event lookup nothing with $ changes.
        let plain = vtDynamic(["V": "v"])
        t.equal(plain.resolve("$MouseX$ [$MouseX] #V#"), "$MouseX$ [$MouseX] v")
    }
}

// MARK: - Parameters

private func variableParameterTests(_ t: TestRunner) {
    t.suite("Variables: section variable parameter parsing") {
        typealias P = SectionVariableParameter
        typealias F = SectionNumberFormat
        t.equal(P.parse(nil), .none)
        t.equal(P.parse(""), .number(F()))
        t.equal(P.parse("%"), .number(F(percent: true)))
        t.equal(P.parse("/1024"), .number(F(divisor: 1024)))
        t.equal(P.parse("2"), .number(F(decimals: 2)))
        t.equal(P.parse("0"), .number(F(decimals: 0)))
        t.equal(P.parse("/1024,2"), .number(F(divisor: 1024, decimals: 2)))
        t.equal(P.parse("%,1"), .number(F(percent: true, decimals: 1)))
        // Combinations in any order (manual: /1024,4,% and /1024,%).
        t.equal(P.parse("/1024,4,%"), .number(F(percent: true, divisor: 1024, decimals: 4)))
        t.equal(P.parse("/1024,%"), .number(F(percent: true, divisor: 1024)))
        t.equal(P.parse("4,/1000"), .number(F(divisor: 1000, decimals: 4)))
        // Lenient whitespace / empty parts / repeats.
        t.equal(P.parse(" 2 "), .number(F(decimals: 2)))
        t.equal(P.parse("/ 1024 , 2"), .number(F(divisor: 1024, decimals: 2)))
        t.equal(P.parse("2,"), .number(F(decimals: 2)))
        t.equal(P.parse(" "), .number(F()))
        t.equal(P.parse("1,3"), .number(F(decimals: 3)))
        t.equal(P.parse("/1000.5"), .number(F(divisor: 1000.5)))
        // Keywords keep their spelling.
        for k in ["MaxValue", "maxvalue", "MinValue", "X", "Y", "W", "H", "XW", "YH", "EscapeRegExp", "EncodeURL",
                  "EncodeUrl", "TimeStamp", "Timestamp"] {
            t.equal(P.parse(k), .keyword(k))
        }
        t.equal(P.parse(" MaxValue "), .keyword("MaxValue"))
        // Malformed number forms are keywords (which the engine does not know).
        t.equal(P.parse("/0"), .keyword("/0"))
        t.equal(P.parse("/"), .keyword("/"))
        t.equal(P.parse("/abc"), .keyword("/abc"))
        t.equal(P.parse("/inf"), .keyword("/inf"))
        t.equal(P.parse("/1e3"), .keyword("/1e3"))
        t.equal(P.parse("-1"), .keyword("-1"))
        t.equal(P.parse("2.5"), .keyword("2.5"))
        t.equal(P.parse("%%"), .keyword("%%"))
        t.equal(P.parse("2,MaxValue"), .keyword("2,MaxValue"))
        t.equal(P.parse("1234"), .keyword("1234"))
        // Known keywords.
        t.equal(P.parse("maxVALUE").knownKeyword, .maxValue)
        t.equal(P.parse("minvalue").knownKeyword, .minValue)
        t.equal(P.parse("xw").knownKeyword, .xw)
        t.equal(P.parse("yh").knownKeyword, .yh)
        t.equal(P.parse("x").knownKeyword, .x)
        t.equal(P.parse("escaperegexp").knownKeyword, .escapeRegExp)
        t.equal(P.parse("ENCODEURL").knownKeyword, .encodeUrl)
        t.equal(P.parse("TimeStamp").knownKeyword, .timestamp)
        t.equal(P.parse("Bogus").knownKeyword, nil)
        t.equal(P.parse("2").knownKeyword, nil)
        t.equal(P.parse(nil).knownKeyword, nil)
        t.equal(SectionVariableKeyword("  W "), .w)
        t.equal(SectionVariableKeyword.allCases.count, 11)
    }
}

// MARK: - Number format

private func variableNumberFormatTests(_ t: TestRunner) {
    t.suite("Variables: section number format") {
        func f(_ value: Double, _ format: SectionNumberFormat, min: Double = 0, max: Double = 1) -> String {
            format.format(value: value, minValue: min, maxValue: max)
        }
        let plain = SectionNumberFormat()
        // [M:] — up to ten decimals, trailing zeros removed.
        t.equal(f(42, plain), "42")
        t.equal(f(0, plain), "0")
        t.equal(f(-0.0, plain), "0")
        t.equal(f(1.0 / 3.0, plain), "0.3333333333")
        t.equal(f(2.0 / 3.0, plain), "0.6666666667")
        t.equal(f(0.1 + 0.2, plain), "0.3")
        t.equal(f(-2.5, plain), "-2.5")
        t.equal(f(1e-5, plain), "0.00001")
        t.equal(f(1e-11, plain), "0")
        t.equal(f(-1e-11, plain), "0")
        t.equal(f(5e-11, plain), "0.0000000001")
        t.equal(f(123456789.125, plain), "123456789.125")
        t.equal(f(1e20, plain), "100000000000000000000")
        t.equal(f(13_300_000_000, plain), "13300000000")
        t.equal(f(0.99999999999, plain), "1")
        // [M:n] — exactly n decimals, half away from zero on the decimal form.
        t.equal(f(3.14159265, SectionNumberFormat(decimals: 4)), "3.1416")
        t.equal(f(2.5, SectionNumberFormat(decimals: 0)), "3")
        t.equal(f(3.5, SectionNumberFormat(decimals: 0)), "4")
        t.equal(f(-2.5, SectionNumberFormat(decimals: 0)), "-3")
        t.equal(f(0.5, SectionNumberFormat(decimals: 0)), "1")
        t.equal(f(0.4, SectionNumberFormat(decimals: 0)), "0")
        t.equal(f(-0.4, SectionNumberFormat(decimals: 0)), "0")
        t.equal(f(1.005, SectionNumberFormat(decimals: 2)), "1.01")
        t.equal(f(0.125, SectionNumberFormat(decimals: 2)), "0.13")
        t.equal(f(0.05, SectionNumberFormat(decimals: 1)), "0.1")
        t.equal(f(0.04, SectionNumberFormat(decimals: 1)), "0.0")
        t.equal(f(9.999, SectionNumberFormat(decimals: 2)), "10.00")
        t.equal(f(99.5, SectionNumberFormat(decimals: 0)), "100")
        t.equal(f(2.5, SectionNumberFormat(decimals: 2)), "2.50")
        t.equal(f(42, SectionNumberFormat(decimals: 3)), "42.000")
        t.equal(f(1e-5, SectionNumberFormat(decimals: 3)), "0.000")
        t.equal(f(1.5, SectionNumberFormat(decimals: 12)), "1.500000000000")
        t.equal(f(1.5, SectionNumberFormat(decimals: 999)).count, 2 + SectionNumberFormat.maxDecimals)
        t.equal(f(1.5, SectionNumberFormat(decimals: -3)), "2")
        // [M:%] — percentage of MinValue…MaxValue.
        t.equal(f(50, SectionNumberFormat(percent: true), min: 0, max: 200), "25")
        t.equal(f(0.25, SectionNumberFormat(percent: true)), "25")
        t.equal(f(15, SectionNumberFormat(percent: true), min: 10, max: 20), "50")
        t.equal(f(1, SectionNumberFormat(percent: true, decimals: 2), min: 0, max: 3), "33.33")
        t.equal(f(5, SectionNumberFormat(percent: true), min: 5, max: 5), "0")          // zero range
        t.equal(f(300, SectionNumberFormat(percent: true), min: 0, max: 200), "100")    // clamped
        t.equal(f(-5, SectionNumberFormat(percent: true), min: 0, max: 200), "0")
        t.equal(f(.nan, SectionNumberFormat(percent: true)), "0")
        // [M:/n]
        t.equal(f(2048, SectionNumberFormat(divisor: 1024)), "2")
        t.equal(f(1536, SectionNumberFormat(divisor: 1024, decimals: 2)), "1.50")
        t.equal(f(1000, SectionNumberFormat(divisor: 3)), "333.3333333333")
        t.equal(f(10, SectionNumberFormat(divisor: 0)), "10")                          // ignored
        // % then /n.
        t.equal(f(50, SectionNumberFormat(percent: true, divisor: 10, decimals: 1), min: 0, max: 100), "5.0")
        // Non-finite values.
        t.equal(f(.nan, plain), "nan")
        t.equal(f(.infinity, plain), "inf")
        t.equal(f(-.infinity, SectionNumberFormat(decimals: 2)), "-inf")
        t.equal(f(.greatestFiniteMagnitude, plain).count, 309)
        t.equal(f(.leastNonzeroMagnitude, plain), "0")
    }
}

// MARK: - Keyword helpers

private func variableKeywordHelperTests(_ t: TestRunner) {
    t.suite("Variables: EscapeRegExp and EncodeURL") {
        // Manual: reserved characters are .^$*+?()[{\|
        t.equal(SectionVariables.escapeRegExp(".^$*+?()[{\\|"), "\\.\\^\\$\\*\\+\\?\\(\\)\\[\\{\\\\\\|")
        t.equal(SectionVariables.escapeRegExp("]}-/#abc München"), "]}-/#abc München")
        t.equal(SectionVariables.escapeRegExp("C:\\Temp (1).txt"), "C:\\\\Temp \\(1\\)\\.txt")
        t.equal(SectionVariables.escapeRegExp(""), "")
        // Manual: "I live in München" → I%20live%20in%20M%C3%BCnchen
        t.equal(SectionVariables.encodeUrl("I live in München"), "I%20live%20in%20M%C3%BCnchen")
        t.equal(SectionVariables.encodeUrl("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"),
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        t.equal(SectionVariables.encodeUrl(":/?#[]@!$&'()*+,;="),
                "%3A%2F%3F%23%5B%5D%40%21%24%26%27%28%29%2A%2B%2C%3B%3D")
        t.equal(SectionVariables.encodeUrl("%"), "%25")
        t.equal(SectionVariables.encodeUrl("😀"), "%F0%9F%98%80")
        t.equal(SectionVariables.encodeUrl(""), "")
    }
}

// MARK: - [Variables] definitions

private func variableDefinitionTests(_ t: TestRunner) {
    func entries(_ pairs: [(String, String)]) -> [IniEntry] { pairs.map { IniEntry(key: $0.0, value: $0.1) } }

    t.suite("Variables: resolveDefinitions") {
        // Manual: MyVar2=https://www.#MyVar1#.net/
        let basic = VariableResolver.resolveDefinitions(
            entries([("MyVar1", "rainmeter"), ("MyVar2", "https://www.#MyVar1#.net/")]), builtins: [:])
        t.equal(basic, ["myvar1": "rainmeter", "myvar2": "https://www.rainmeter.net/"])
        // Keys lowercased, references case-insensitive, forward references and chains.
        let fwd = VariableResolver.resolveDefinitions(
            entries([("Url", "#Scheme#://#HOST#/"), ("Scheme", "https"), ("Host", "#Sub#.example.com"), ("Sub", "www")]),
            builtins: [:])
        t.equal(fwd["url"], "https://www.example.com/")
        t.equal(fwd["host"], "www.example.com")
        // Built-ins are available and win over definitions with the same name.
        let bi = VariableResolver.resolveDefinitions(
            entries([("Img", "#@#Images/"), ("CURRENTPATH", "/evil/"), ("Here", "#CurrentPath#x")]),
            builtins: ["@": "/Skins/Suite/@Resources/", "currentpath": "/Skins/Suite/Clock/"])
        t.equal(bi["img"], "/Skins/Suite/@Resources/Images/")
        t.equal(bi["currentpath"], "/Skins/Suite/Clock/")
        t.equal(bi["here"], "/Skins/Suite/Clock/x")
        t.equal(bi["@"], "/Skins/Suite/@Resources/")
        // Upper-case builtin keys are normalized too.
        let biUpper = VariableResolver.resolveDefinitions(entries([("P", "#SKINSPATH#")]), builtins: ["SKINSPATH": "/S/"])
        t.equal(biUpper["p"], "/S/")
        t.equal(biUpper["skinspath"], "/S/")
        // Later duplicates win (as with @Include merges); @Include keys are not variables.
        let dup = VariableResolver.resolveDefinitions(
            entries([("Color", "1"), ("@Include", "#@#vars.inc"), ("@IncludeMore", "x"), ("color", "2"), ("Use", "#Color#")]),
            builtins: [:])
        t.equal(dup["color"], "2")
        t.equal(dup["use"], "2")
        t.equal(dup["@include"], nil)
        t.equal(dup["@includemore"], nil)
        t.equal(dup.count, 2)
        // Formulas are not evaluated in [Variables].
        let formula = VariableResolver.resolveDefinitions(entries([("A", "5"), ("MyVar", "(#A# * 2)")]), builtins: [:])
        t.equal(formula["myvar"], "(5 * 2)")
        // Undefined references, cycles and self references stay as written.
        let bad = VariableResolver.resolveDefinitions(
            entries([("U", "#Nope#"), ("S", "x#S#"), ("A", "#B#"), ("B", "#A#")]), builtins: [:])
        t.equal(bad["u"], "#Nope#")
        t.equal(bad["s"], "x#S#")
        t.check(bad["a"] == "#A#" || bad["a"] == "#B#", "cycle A: \(bad["a"] ?? "nil")")
        t.check(bad["b"] == "#A#" || bad["b"] == "#B#", "cycle B: \(bad["b"] ?? "nil")")
        // Escapes, character and section variables are kept for the place of use; nested [#Var] is resolved like
        // #Var# (review fix: the nested form "functions exactly as" the normal one outside bangs).
        let kept = VariableResolver.resolveDefinitions(
            entries([("Esc", "#*Color*#"), ("Nest", "[#Color[#Idx]]"), ("Char", "[\\xf043]"),
                     ("Sec", "[MeasureCPU:0]%"), ("Mixed", "#Idx#[&M#Idx#]"), ("Idx", "2"), ("Color2", "red")]),
            builtins: [:])
        t.equal(kept["esc"], "#*Color*#")
        t.equal(kept["nest"], "red")
        t.equal(kept["char"], "[\\xf043]")
        t.equal(kept["sec"], "[MeasureCPU:0]%")
        t.equal(kept["mixed"], "2[&M2]")
        // …and resolve correctly when used.
        let use = vtStatic(kept)
        t.equal(use.resolve("#Esc#"), "#Color#")
        t.equal(use.resolve("#Nest#"), "red")
        t.equal(use.resolve("#Char#"), "\u{F043}")
        // Built-in values are literal inside definitions too (no re-scan of a path containing #).
        let hashPath = VariableResolver.resolveDefinitions(entries([("P", "#@#img"), ("X", "1")]),
                                                           builtins: ["@": "/a#X#b/"])
        t.equal(hashPath["p"], "/a#X#b/img")
        // Empty input.
        t.equal(VariableResolver.resolveDefinitions([], builtins: [:]), [:])
        t.equal(VariableResolver.resolveDefinitions([], builtins: ["crlf": "\n"]), ["crlf": "\n"])
        // Empty keys are ignored; empty values kept.
        let empties = VariableResolver.resolveDefinitions(entries([(" ", "x"), ("E", "")]), builtins: [:])
        t.equal(empties, ["e": ""])
    }

    t.suite("Variables: resolveDefinitions long chains") {
        // The time limits only tell "finishes" from "never finishes": the exponential block alone fills the total-size
        // budget, the same work that takes about 5 s on a CI runner (Intel, debug build).
        let limit: TimeInterval = 60
        // Backward chain of 5000 (each refers to the previous one): resolved completely, no deep recursion.
        var back: [(String, String)] = [("V0", "x")]
        for i in 1..<5000 { back.append(("V\(i)", "#V\(i - 1)#")) }
        let b = VariableResolver.resolveDefinitions(entries(back), builtins: [:])
        t.equal(b["v4999"], "x")
        // Forward chain of 5000 (each refers to the next one): resolved completely without deep recursion.
        var fwd: [(String, String)] = []
        for i in 0..<5000 { fwd.append(("W\(i)", "#W\(i + 1)#")) }
        fwd.append(("W5000", "y"))
        let fStart = Date()
        let f = VariableResolver.resolveDefinitions(entries(fwd), builtins: [:])
        let fElapsed = Date().timeIntervalSince(fStart)
        t.check(fElapsed < limit, "forward chain bounded: \(fElapsed)s")
        t.equal(f["w0"], "y")
        t.equal(f["w63"], "y")
        t.equal(f["w64"], "y")
        t.equal(f["w4990"], "y")
        t.equal(f.count, 5001)
        // A cycle longer than the recursion cap terminates, leaving one reference as written.
        var ring: [(String, String)] = []
        for i in 0..<300 { ring.append(("R\(i)", "r\(i)#R\((i + 1) % 300)#")) }
        let rStart = Date()
        let rt = VariableResolver.resolveDefinitions(entries(ring), builtins: [:])
        let rElapsed = Date().timeIntervalSince(rStart)
        t.check(rElapsed < limit, "long cycle bounded: \(rElapsed)s")
        t.equal(rt.count, 300)
        t.check(rt.values.allSatisfy { $0.contains("#R") }, "each ring value keeps one reference")
        t.check(rt["r0"]?.hasPrefix("r0r1r2") == true, "ring resolved forward: \(rt["r0"]?.prefix(20) ?? "")")
        // Exponential definitions stay bounded.
        var exp: [(String, String)] = [("E40", "abcdefghij")]
        for i in 0..<40 { exp.append(("E\(i)", "#E\(i + 1)##E\(i + 1)#")) }
        let start = Date()
        let e = VariableResolver.resolveDefinitions(entries(exp), builtins: [:])
        let eElapsed = Date().timeIntervalSince(start)
        t.check(eElapsed < limit, "exponential definitions bounded: \(eElapsed)s")
        t.check((e["e0"]?.utf8.count ?? 0) <= 2 << 20, "value size bounded")
    }
}

// MARK: - Built-in names

private func variableBuiltInTests(_ t: TestRunner) {
    t.suite("Variables: built-in variable names") {
        let expected = ["PROGRAMDRIVE", "PROGRAMPATH", "SETTINGSPATH", "SKINSPATH", "PLUGINSPATH", "ADDONSPATH",
                        "@", "CURRENTPATH", "CURRENTFILE", "ROOTCONFIGPATH", "ROOTCONFIG", "CURRENTCONFIG",
                        "CURRENTCONFIGX", "CURRENTCONFIGY", "CURRENTCONFIGWIDTH", "CURRENTCONFIGHEIGHT",
                        "CURRENTCONFIGZPOS", "CRLF", "CURRENTSECTION", "CONFIGEDITOR",
                        "WORKAREAX", "WORKAREAY", "WORKAREAWIDTH", "WORKAREAHEIGHT",
                        "SCREENAREAX", "SCREENAREAY", "SCREENAREAWIDTH", "SCREENAREAHEIGHT",
                        "PWORKAREAX", "PWORKAREAY", "PWORKAREAWIDTH", "PWORKAREAHEIGHT",
                        "PSCREENAREAX", "PSCREENAREAY", "PSCREENAREAWIDTH", "PSCREENAREAHEIGHT",
                        "VSCREENAREAX", "VSCREENAREAY", "VSCREENAREAWIDTH", "VSCREENAREAHEIGHT"]
        t.equal(Set(BuiltInVariables.names), Set(expected))
        t.equal(BuiltInVariables.names.count, expected.count)
        for name in expected {
            t.check(BuiltInVariables.isBuiltIn(name), name)
            t.check(BuiltInVariables.isBuiltIn(name.lowercased()), name)
        }
        t.check(BuiltInVariables.isBuiltIn("WorkAreaWidth@2"))
        t.check(BuiltInVariables.isBuiltIn("SCREENAREAX@10"))
        t.check(!BuiltInVariables.isBuiltIn("VSCREENAREAX@2"))
        t.check(!BuiltInVariables.isBuiltIn("WORKAREAX@"))
        t.check(!BuiltInVariables.isBuiltIn("WORKAREAX@x"))
        t.check(!BuiltInVariables.isBuiltIn("MyVar"))
        t.check(!BuiltInVariables.isBuiltIn("@@"))
        t.check(!BuiltInVariables.isBuiltIn(""))
        t.check(BuiltInVariables.monitorVariable("ScreenAreaWidth@2")! == ("SCREENAREAWIDTH", 2))
        t.check(BuiltInVariables.monitorVariable("CURRENTPATH@2") == nil)
        t.check(BuiltInVariables.monitorVariable("@2") == nil)
        t.check(BuiltInVariables.isDynamic("CurrentConfigX"))
        t.check(BuiltInVariables.isDynamic("CONFIGEDITOR"))
        t.check(BuiltInVariables.isDynamic("WORKAREAWIDTH"))
        t.check(BuiltInVariables.isDynamic("VSCREENAREAHEIGHT"))
        t.check(BuiltInVariables.isDynamic("SCREENAREAX@3"))
        t.check(!BuiltInVariables.isDynamic("CURRENTPATH"))
        t.check(!BuiltInVariables.isDynamic("@"))
        t.equal(BuiltInVariables.crlfValue, "\n")
        t.equal(BuiltInVariables.monitorIndexedNames.count, 8)
    }

    t.suite("Variables: built-in values are literal") {
        let r = vtDynamic(["@": "/Skins/C#[x]/@Resources/", "X": "no", "CURRENTSECTION": "Meter#X#",
                           "CRLF": "\n", "WORKAREAWIDTH@2": "1920"],
                          measures: ["x": VTMeasure(string: "measure", number: 0)])
        t.equal(r.resolve("#@#Images/bg.png"), "/Skins/C#[x]/@Resources/Images/bg.png")
        t.equal(r.resolve("[#@]"), "/Skins/C#[x]/@Resources/")
        t.equal(r.resolve("#CURRENTSECTION#"), "Meter#X#")
        t.equal(r.resolve("Line1#CRLF#Line2"), "Line1\nLine2")
        t.equal(r.resolve("#WORKAREAWIDTH@2#"), "1920")
    }
}

// MARK: - Standard-only resolution

private func variableStandardOnlyTests(_ t: TestRunner) {
    t.suite("Variables: resolveStandardVariables") {
        let r = vtDynamic(["A": "1", "B": "#A#2", "Idx": "1", "Color1": "red"],
                          measures: ["M": VTMeasure(string: "m", number: 0)])
        t.equal(r.resolveStandardVariables("#A# #B#"), "1 12")
        t.equal(r.resolveStandardVariables("#*A*# [#A] [&M] [M] [\\x41] $MouseX$"), "#*A*# [#A] [&M] [M] [\\x41] $MouseX$")
        t.equal(r.resolveStandardVariables("[!SetOption M Text \"#*A*#\"][!SetOption M X [#Color[#Idx]]]"),
                "[!SetOption M Text \"#*A*#\"][!SetOption M X [#Color[#Idx]]]")
        // Then the execution-time resolve consumes the escape once.
        t.equal(r.resolve(r.resolveStandardVariables("[!SetOption M Text \"#*A*#\"][!Log #A#]")),
                "[!SetOption M Text \"#A#\"][!Log 1]")
        t.equal(r.resolveStandardVariables("no hash [M]"), "no hash [M]")
        t.equal(r.resolveStandardVariables("#Nope# #"), "#Nope# #")
        let cyc = vtStatic(["A": "#A#"])
        t.equal(cyc.resolveStandardVariables("#A#"), "#A#")
    }
}

// MARK: - Robustness

private func variableRobustnessTests(_ t: TestRunner) {
    t.suite("Variables: fuzz never crashes or hangs") {
        let pieces = ["#", "[", "]", "*", "&", "\\", "$", ":", "!", " ", "%", "/", ",", "A", "B", "M", "x", "2", "9",
                      "#A#", "[#A]", "[&M]", "[M:2]", "[\\x41]", "#*A*#", "[*M*]", "$MouseX$", "é", "☃", "\"", "\n"]
        let vars: [String: String] = ["A": "#B#[#A]", "B": "[&M[#A]]#C#", "C": "[\\x5B]#A#]", "2": "#2#"]
        let events: [String: String] = ["MouseX": "1"]
        let r = VariableResolver(variableLookup: vtVariables(vars),
                                 sectionLookup: vtSectionLookup(measures: ["M": VTMeasure(string: "[#A]#B#", number: 1),
                                                                           "MA": VTMeasure(string: "ma", number: 2)]),
                                 eventLookup: { events[$0] })
        let s = vtStatic(vars)
        var rng = VTRandom(state: 42)
        let start = Date()
        var total = 0
        for _ in 0..<4000 {
            var text = ""
            for _ in 0..<rng.int(40) { text += pieces[rng.int(pieces.count)] }
            total += r.resolve(text).utf8.count
            total += s.resolve(text).utf8.count
            total += s.resolveStandardVariables(text).utf8.count
        }
        let elapsed = Date().timeIntervalSince(start)
        t.check(total > 0)
        t.check(elapsed < 30, "fuzz took \(elapsed)s")
        // Definitions fuzz.
        var defs: [IniEntry] = []
        for i in 0..<200 {
            var v = ""
            for _ in 0..<rng.int(12) { v += ["#D\(rng.int(200))#", "[#D\(rng.int(200))]", "x", "#", "[", "]"][rng.int(6)] }
            defs.append(IniEntry(key: "D\(i)", value: v))
        }
        let table = VariableResolver.resolveDefinitions(defs, builtins: [:])
        t.equal(table.count, 200)
    }

    t.suite("Variables: pathological input stays bounded") {
        let r = vtDynamic(["A": "a"], measures: ["M": VTMeasure(string: "m", number: 0)])
        let start = Date()
        let deepOpen = String(repeating: "[#", count: 20_000) + "A" + String(repeating: "]", count: 20_000)
        t.check(r.resolve(deepOpen).utf8.count > 0)
        let unterminated = String(repeating: "[#[&[\\", count: 10_000)
        t.equal(r.resolve(unterminated), unterminated)
        let brackets = String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000)
        t.equal(r.resolve(brackets), brackets)
        let hashes = String(repeating: "#", count: 100_000)
        t.equal(r.resolve(hashes), hashes)
        let many = String(repeating: "#A#[M][#A]", count: 5_000)
        t.equal(r.resolve(many), String(repeating: "ama", count: 5_000))
        let escapes = String(repeating: "[*M*]#*A*#", count: 5_000)
        t.equal(r.resolve(escapes), String(repeating: "[M]#A#", count: 5_000))
        let elapsed = Date().timeIntervalSince(start)
        t.check(elapsed < 20, "pathological inputs took \(elapsed)s")
        // Long chains of nested-form variables stay bounded (stack and bracket limits).
        var chain: [String: String] = ["N60": "end"]
        for i in 0..<60 { chain["N\(i)"] = "[#N\(i + 1)]" }
        let chained = vtDynamic(chain).resolve("[#N0]")
        t.check(chained.hasPrefix("[#N") && chained.hasSuffix("]"), "left as written past the limit: \(chained)")
        var shortChain: [String: String] = ["K10": "end"]
        for i in 0..<10 { shortChain["K\(i)"] = "[#K\(i + 1)]#K\(i + 1)#" }
        t.equal(vtDynamic(shortChain).resolve("[#K9]"), "endend")
        // Invalid UTF-8 cannot occur in String, but lone surrogates from char vars are refused (checked above);
        // a lookup returning weird text is fine.
        let weird = VariableResolver(variableLookup: { _ in "\u{0}]#[" }, sectionLookup: { _, _ in "]]]" })
        t.equal(weird.resolve("#X#[M]"), "\u{0}]#[]]]")
    }

    t.suite("Variables: performance of typical options") {
        let vars = ["FontColor": "255,255,255,200", "Size": "12", "Accent": "#FontColor#", "Idx": "1", "Color1": "1,2,3"]
        let r = vtDynamic(vars, measures: ["MeasureCPU": VTMeasure(string: "12.5", number: 12.5, max: 100)])
        let options = ["#Accent#", "(#Size# * 2)", "CPU [MeasureCPU:1]%", "[#Color[#Idx]]", "Plain text value",
                       "[!SetOption Meter Text \"[MeasureCPU:%,0]%\"][!UpdateMeter Meter][!Redraw]", "#@#Images/bg.png"]
        let start = Date()
        var sink = 0
        for _ in 0..<5_000 {
            for o in options { sink &+= r.resolve(o).utf8.count }
        }
        let elapsed = Date().timeIntervalSince(start)
        print("    (35 000 resolves in \(String(format: "%.3f", elapsed))s)")
        t.check(sink > 0)
        t.check(elapsed < 20, "performance: \(elapsed)s")
    }
}

// MARK: - Adversarial review regressions

private func variableReviewTests(_ t: TestRunner) {
    func entries(_ pairs: [(String, String)]) -> [IniEntry] { pairs.map { IniEntry(key: $0.0, value: $0.1) } }

    t.suite("Variables: review — [Variables] resolves [#Var] like #Var#") {
        // Nesting page: the nested forms "function exactly as their normal counterparts do"; the one difference
        // (dynamic resolution) "only applies to use in bangs". [Variables] cannot be dynamic, so B=[#A] must take
        // A's value at load exactly like B=#A#, instead of staying "[#A]" and following later !SetVariable changes.
        let defs = VariableResolver.resolveDefinitions(
            entries([("A", "1"), ("ByHash", "#A#"), ("ByNest", "[#A]"), ("Url", "https://www.[#Site].net/"),
                     ("Site", "rainmeter"), ("Idx", "2"), ("Color1", "red"), ("Color2", "blue"),
                     ("Current", "[#Color[#Idx]]"), ("Deep", "[#Color[#Color[#Idx]]]"), ("Undef", "[#Nope]"),
                     ("Half", "[#Undef2[#Idx]]"), ("Esc", "[#*A*]"), ("EscHash", "#*A*#"),
                     ("Meas", "[&Measure[#Idx]]"), ("Char", "[\\[#Hex]]"), ("Hex", "x263A"),
                     ("Classic", "[Measure[#Idx]]"), ("Event", "[$MouseX[#Idx]]"), ("Built", "[#@]img/"),
                     ("CycA", "[#CycB]"), ("CycB", "[#CycA]"), ("Self", "x[#Self]")]),
            builtins: ["@": "/R/"])
        t.equal(defs["bynest"], "1")
        t.equal(defs["byhash"], defs["bynest"])
        t.equal(defs["url"], "https://www.rainmeter.net/")            // manual example, nested form, forward ref
        t.equal(defs["current"], "blue")
        t.equal(defs["deep"], "[#Colorblue]")                          // inner parts resolved, undefined outer kept
        t.equal(defs["undef"], "[#Nope]")
        t.equal(defs["half"], "[#Undef22]")
        t.equal(defs["built"], "/R/img/")
        // Escapes are kept for the place of use (consumed exactly once, there).
        t.equal(defs["esc"], "[#*A*]")
        t.equal(defs["eschash"], "#*A*#")
        // Section, character and event variables stay as written, with their inner variables replaced, exactly as
        // "[&Measure#Idx#]" already did.
        t.equal(defs["meas"], "[&Measure2]")
        t.equal(defs["char"], "[\\x263A]")
        t.equal(defs["classic"], "[Measure2]")
        t.equal(defs["event"], "[$MouseX2]")
        // Cycles terminate.
        t.check(defs["cyca"] == "[#CycA]" || defs["cyca"] == "[#CycB]", "cycle: \(defs["cyca"] ?? "nil")")
        t.equal(defs["self"], "x[#Self]")
        // Observable effect: after !SetVariable A 2, a use of #ByNest# still shows the load-time value, like #ByHash#.
        var table = defs
        table["a"] = "2"
        let use = VariableResolver(variableLookup: { table[$0.lowercased()] })
        t.equal(use.resolve("#ByNest#|#ByHash#"), "1|1")
        t.equal(use.resolve("#Esc#|#EscHash#|#Char#"), "[#A]|#A#|☺")
        // resolveStandardVariables (action strings read before execution) still keeps [#Var] for the bang.
        t.equal(use.resolveStandardVariables("[!SetVariable X [#A]]#A#"), "[!SetVariable X [#A]]2")
        // Long forward chains through the nested form resolve too (worklist, no deep recursion).
        var fwd: [(String, String)] = []
        for i in 0..<3000 { fwd.append(("N\(i)", "[#N\(i + 1)]")) }
        fwd.append(("N3000", "end"))
        let chain = VariableResolver.resolveDefinitions(entries(fwd), builtins: [:])
        t.equal(chain["n0"], "end")
        t.equal(chain["n2999"], "end")
    }

    t.suite("Variables: review — [Variables] chains past the recursion cap do not explode") {
        // Pre-review: 65 lines of W_i=#W_i+1##W_i+1# hung forever (60 lines took 2 ms): after hitting the 64-link
        // cap nothing was memoized, so both references were re-explored at every level (2^64 work). The time limit
        // only has to tell "finishes" from "never finishes": a CI runner (Intel, debug build) takes about 5 s.
        let limit: TimeInterval = 60
        for form in ["#W%d##W%d#", "[#W%d][#W%d]", "#W%d#[#W%d]"] {
            func chain(_ n: Int, end: String) -> [(String, String)] {
                var c: [(String, String)] = []
                for i in 0..<n { c.append(("W\(i)", form.replacingOccurrences(of: "%d", with: String(i + 1)))) }
                c.append(("W\(n)", end))
                return c
            }
            // Empty values: nothing grows, only the number of lookups could explode.
            var start = Date()
            let empty = VariableResolver.resolveDefinitions(entries(chain(3000, end: "")), builtins: [:])
            t.check(Date().timeIntervalSince(start) < limit, "\(form): took \(Date().timeIntervalSince(start))s")
            t.equal(empty["w0"], "", form)
            t.equal(empty.count, 3001, form)
            // Non-empty values double per line; correct where small, bounded by the budget further up.
            guard form.hasPrefix("#") && form.hasSuffix("#") else { continue }
            start = Date()
            let w = VariableResolver.resolveDefinitions(entries(chain(80, end: "y")), builtins: [:])
            t.check(Date().timeIntervalSince(start) < limit, "\(form): took \(Date().timeIntervalSince(start))s")
            t.equal(w["w79"], "yy", form)
            t.equal(w["w70"]?.utf8.count, 1024, form)
            t.equal(w.count, 81, form)
        }
        // A long chain whose values also use other (later) variables still resolves completely: the aborted
        // attempt's gaps are not memoized.
        var side: [(String, String)] = []
        for i in 0..<300 { side.append(("V\(i)", "#V\(i + 1)#-[#Side]#Other#")) }
        side.append(("V300", "end"))
        side.append(("Side", "s"))
        side.append(("Other", "#Side#o"))
        let v = VariableResolver.resolveDefinitions(entries(side), builtins: [:])
        t.check(v.values.allSatisfy { !$0.contains("#") && !$0.contains("[") }, "all resolved")
        t.equal(v["v299"], "end-sso")
        t.check(v["v0"]?.hasSuffix("end" + String(repeating: "-sso", count: 300)) == true, "v0")
    }

    t.suite("Variables: review — [Variables] total size is bounded") {
        // Before the review each definition was capped at 1 MiB separately, so 400 lines of E_i=#E_i-1##E_i-1#
        // built ~250 MB of values (29 s in a debug build) and 20 000 lines of L_i=#L_i-1#x built 200 MB
        // (the sum of 1…n: 8 000 lines are already 32 MB). The size checks catch that on any machine; the time limit
        // only tells "finishes" from "never finishes" (each block fills the budget: about 5 s on a CI runner, Intel,
        // debug build).
        let limit: TimeInterval = 60
        var exp: [(String, String)] = [("E0", "abcdefghij")]
        for i in 1..<400 { exp.append(("E\(i)", "#E\(i - 1)##E\(i - 1)#")) }
        var start = Date()
        let e = VariableResolver.resolveDefinitions(entries(exp), builtins: [:])
        var elapsed = Date().timeIntervalSince(start)
        let eTotal = e.values.reduce(0) { $0 + $1.utf8.count }
        t.check(eTotal <= VarDefinitionTable.maxTotalSubstitutedBytes + 64 * 1024, "exp total \(eTotal)")
        t.check(elapsed < limit, "exp took \(elapsed)s")
        t.equal(e.count, 400)
        t.equal(e["e1"], "abcdefghijabcdefghij")                       // small values still resolve normally
        t.check(e["e399"]?.contains("#E398#") == true, "past the budget a reference stays as written")

        var lin: [(String, String)] = [("L0", "x")]
        for i in 1..<8_000 { lin.append(("L\(i)", "#L\(i - 1)#x")) }
        start = Date()
        let l = VariableResolver.resolveDefinitions(entries(lin), builtins: [:])
        elapsed = Date().timeIntervalSince(start)
        let lTotal = l.values.reduce(0) { $0 + $1.utf8.count }
        t.check(lTotal <= VarDefinitionTable.maxTotalSubstitutedBytes + 8_000 * 16, "linear total \(lTotal)")
        t.check(elapsed < limit, "linear took \(elapsed)s")
        t.equal(l["l3"], "xxxx")
        t.equal(l.count, 8_000)
        // Resolving the capped values later is still bounded per call.
        let r = VariableResolver(variableLookup: { l[$0.lowercased()] })
        t.check(r.resolve("#L7999#").utf8.count <= (1 << 20) + 64 * 1024)

        // A realistic large skin is far below the budget and resolves completely.
        var big: [(String, String)] = [("Base", String(repeating: "0123456789", count: 10))]
        for i in 0..<2000 { big.append(("V\(i)", "#Base#-\(i)-[#Base]")) }
        let b = VariableResolver.resolveDefinitions(entries(big), builtins: [:])
        t.check(b.values.allSatisfy { !$0.contains("#") }, "all 2000 definitions resolved")
    }

    t.suite("Variables: review — nothing defined leaves text unchanged (fuzz)") {
        // Property: with every lookup answering nil, any text without an escape ("*") or a character variable
        // ("[\") comes back byte-for-byte, from both entry points.
        let alphabet: [String] = ["#", "[", "]", "&", "\\", "$", ":", "!", " ", "%", "/", ",", "A", "x", "1", "é", "☃",
                                  "\"", "\n", "\r\n", "\u{0}", "😀", "@", "(", ")", "#A#", "[#A]", "[&A:2]", "$A$"]
        let none = VariableResolver(variableLookup: { _ in nil }, sectionLookup: { _, _ in nil },
                                    eventLookup: { _ in nil })
        var rng = VTRandom(state: 7)
        var mismatches: [String] = []
        for _ in 0..<20_000 {
            var x = ""
            for _ in 0..<rng.int(30) { x += alphabet[rng.int(alphabet.count)] }
            if x.contains("[\\") { continue }
            if none.resolve(x) != x || none.resolveStandardVariables(x) != x { mismatches.append(x) }
        }
        t.equal(mismatches.count, 0, "first: \(mismatches.first.map { String(reflecting: $0) } ?? "")")
    }

    t.suite("Variables: review — random variable tables never crash or hang") {
        let alphabet: [String] = ["#", "[", "]", "&", "\\", "$", ":", "*", " ", "A", "é", "😀", "[\\x5B]", "[\\x23]",
                                  "#*V1*#", "[*M*]", "[&M]", "[M:2]", "[&M:%]", "$MouseX$", "[$MouseX]"]
        var rng = VTRandom(state: 99)
        let start = Date()
        var produced = 0
        for _ in 0..<300 {
            var vars: [String: String] = [:]
            for k in 0..<6 {
                var v = ""
                for _ in 0..<rng.int(12) {
                    let pick = rng.int(alphabet.count + 2)
                    v += pick < alphabet.count ? alphabet[pick] : (pick == alphabet.count ? "#V\(rng.int(6))#" : "[#V\(rng.int(6))]")
                }
                vars["V\(k)"] = v
            }
            let r = VariableResolver(variableLookup: vtVariables(vars),
                                     sectionLookup: vtSectionLookup(measures: ["M": VTMeasure(string: "[#V1]#V2#", number: 2)]),
                                     eventLookup: { $0 == "MouseX" ? "$MouseX$" : nil })
            for _ in 0..<20 {
                var x = ""
                for _ in 0..<rng.int(20) {
                    let pick = rng.int(alphabet.count + 1)
                    x += pick < alphabet.count ? alphabet[pick] : "#V\(rng.int(6))#"
                }
                produced += r.resolve(x).utf8.count + r.resolveStandardVariables(x).utf8.count
            }
            let defs = (0..<6).map { IniEntry(key: "V\($0)", value: vars["V\($0)"] ?? "") }
            let table = VariableResolver.resolveDefinitions(defs, builtins: ["@": "/a#V1#[M]/"])
            t.check(table.count == 7, "table size \(table.count)")
        }
        t.check(produced > 0)
        let elapsed = Date().timeIntervalSince(start)
        t.check(elapsed < 30, "random tables took \(elapsed)s")
    }

    t.suite("Variables: review — deep recursion fits a 512 KB thread") {
        // Skins may load on a background thread (512 KB stack): the depth guards must keep recursion shallow.
        func onThread(_ body: @escaping () -> Void) -> Bool {
            let done = DispatchSemaphore(value: 0)
            let thread = Thread { body(); done.signal() }
            thread.stackSize = 512 * 1024
            thread.start()
            return done.wait(timeout: .now() + 60) == .success
        }
        var ok = onThread {
            var fwd: [IniEntry] = []
            for i in 0..<3000 { fwd.append(IniEntry(key: "W\(i)", value: "[#W\(i + 1)]#W\(i + 1)#")) }
            fwd.append(IniEntry(key: "W3000", value: ""))
            _ = VariableResolver.resolveDefinitions(fwd, builtins: [:])
        }
        t.check(ok, "definitions")
        ok = onThread {
            var vars: [String: String] = ["N100": "end"]
            for i in 0..<100 { vars["N\(i)"] = "[#[#[#Z]]][#N\(i + 1)]#N\(i + 1)#[&M[#N\(i + 1)]]" }
            let r = VariableResolver(variableLookup: vtVariables(vars),
                                     sectionLookup: vtSectionLookup(measures: ["M": VTMeasure(string: "m", number: 0)]))
            _ = r.resolve(String(repeating: "[#", count: 40) + "N0" + String(repeating: "]", count: 40))
            _ = r.resolve("#N0#")
        }
        t.check(ok, "resolve")
    }

    t.suite("Variables: review — amplifying values stay cheap per resolve()") {
        // Pre-review: failed lookups were not limited, and every nesting level re-parsed the unresolved constructs
        // of all the copies below it, so this 100-variable table made ~2.5 million lookups for ONE resolve()
        // (0.77 s in a release build, 6 s in debug) — on the hot path, every update of a dynamic option.
        var vars: [String: String] = ["N100": "end"]
        for i in 0..<100 { vars["N\(i)"] = "[#[#[#Z]]][#N\(i + 1)]#N\(i + 1)#[&M[#N\(i + 1)]]" }
        var table: [String: String] = [:]
        for (k, v) in vars { table[k.lowercased()] = v }
        var lookups = 0
        let r = VariableResolver(variableLookup: { lookups += 1; return table[$0.lowercased()] },
                                 sectionLookup: { name, _ in lookups += 1; return name == "M" ? "m" : nil })
        let start = Date()
        let out = r.resolve("#N0#")
        let elapsed = Date().timeIntervalSince(start)
        t.check(lookups <= VarExpansion.maxLookups, "lookups: \(lookups)")
        t.check(out.utf8.count <= (1 << 20) + 64 * 1024, "output \(out.utf8.count)")
        // The lookup count above is the regression guard; the time only tells "finishes" from "never finishes" (about
        // 4 s on a CI runner, Intel debug build).
        t.check(elapsed < 60, "took \(elapsed)s")
        t.check(out.hasPrefix("[#[#[#Z]]]"), String(out.prefix(40)))
        // Same with only #Var# references (two per level).
        var plain: [String: String] = ["p100": "end"]
        for i in 0..<100 { plain["p\(i)"] = "#P\(i + 1)##P\(i + 1)#" }
        lookups = 0
        let r2 = VariableResolver(variableLookup: { lookups += 1; return plain[$0.lowercased()] })
        t.check(r2.resolve("#P0#").utf8.count <= (1 << 20) + 64 * 1024)
        t.check(lookups <= VarExpansion.maxLookups, "lookups: \(lookups)")
        // Failed candidates count as well: 60 000 undefined references stop costing lookups at the cap and
        // stay as written.
        lookups = 0
        let many = String(repeating: "#Nope# [#Nope] ", count: 30_000)
        t.equal(r2.resolve(many), many)
        t.check(lookups <= VarExpansion.maxLookups, "lookups: \(lookups)")
        // Ordinary large options are unaffected by the caps.
        let big = String(repeating: "#P99#[#P99] ", count: 2_000)
        t.equal(r2.resolve(big), String(repeating: "endendendend ", count: 2_000))   // 12 000 substitutions
    }

    t.suite("Variables: review — real-world option strings") {
        let meas: [String: VTMeasure] = ["M": VTMeasure(string: "mval", number: 1.5, max: 3),
                                         "Script": VTMeasure(string: "s", number: 0)]
        let d = vtDynamic(["Idx": "1", "Color1": "red", "Key": "abc", "City": "Paris"], measures: meas)
        // PCRE options (WebParser RegExp, Substitute, InlinePattern) in dynamic sections keep their brackets.
        let regex = "(?siU)<a href=\"(.*)\">[\\s\\S]*[^\\]][0-9]{2}[#0-9][a-z:]+\\[(.*)\\]"
        t.equal(d.resolve(regex), regex)
        t.equal(d.resolve("\"[\":\"\",\"]\":\"\""), "\"[\":\"\",\"]\":\"\"")
        t.equal(d.resolve("[\\[]|[\\]]|[\\d]+"), "[\\[]|[\\]]|[\\d]+")
        // URLs with variables and encoded measure input.
        t.equal(d.resolve("https://api.example.com/?q=#City#&appid=#Key#&x=[&M:EncodeURL]#top"),
                "https://api.example.com/?q=Paris&appid=abc&x=mval#top")
        // Inline Lua style parameters reach the lookup with inner variables resolved.
        var seen: [String] = []
        let spy = VariableResolver(variableLookup: vtVariables(["Idx": "1"]), sectionLookup: { name, param in
            if case .keyword(let k) = param { seen.append("\(name)|\(k)") }
            return nil
        })
        t.equal(spy.resolve("[&Script:Func('[#Idx]', 'a:b')]"), "[&Script:Func('1', 'a:b')]")
        t.equal(seen, ["Script|Func('1', 'a:b')"])
        // Bangs nested in magic quotes are resolved when the outer bang runs (escape them to keep them literal).
        t.equal(d.resolve("[!SetOption M LeftMouseUpAction \"\"\"[!SetVariable A [#Idx]][!Log [M]]\"\"\"]"),
                "[!SetOption M LeftMouseUpAction \"\"\"[!SetVariable A 1][!Log mval]\"\"\"]")
        t.equal(d.resolve("[!SetOption M LeftMouseUpAction \"\"\"[!SetVariable A [#*Idx*]][!Log [*M*]]\"\"\"]"),
                "[!SetOption M LeftMouseUpAction \"\"\"[!SetVariable A [#Idx]][!Log [M]]\"\"\"]")
        // Windows-style paths and external commands.
        t.equal(d.resolve("[\"#Key#\\Rainmeter.exe\" !Manage][\"C:\\x\\#Idx#.txt\"]"),
                "[\"abc\\Rainmeter.exe\" !Manage][\"C:\\x\\1.txt\"]")
        // Text that merely looks like syntax.
        t.equal(d.resolve("Track #[M] of #2 — C# [ M ] [M :2] 100% $5"), "Track #mval of #2 — C# [ M ] [M :2] 100% $5")
        t.equal(d.resolve("#[#Idx]#"), "#1#")                         // not re-read as #1#
        t.equal(d.resolve("[#Idx]]]"), "1]]")
        t.equal(d.resolve("[[[M]]]"), "[[mval]]")
        // Shape meter syntax.
        t.equal(d.resolve("Rectangle 0,0,([M:]*10),#Idx#,5 | Fill Color [#Color[#Idx]] | StrokeWidth 0"),
                "Rectangle 0,0,(1.5*10),1,5 | Fill Color red | StrokeWidth 0")
    }
}
