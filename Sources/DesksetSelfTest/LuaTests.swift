import Foundation
@testable import DesksetCore

// MARK: - Harness

private var retainedLuaHosts: [FakeHost] = []

/// A skin under a temporary Skins folder: `Root/Sub/Skin.ini` plus `files` (relative to Skins; text is written as
/// UTF-8, `data` as given).
private final class LuaHarness {
    let skin: Skin
    let host: FakeHost
    let skinsFolder: URL

    init(_ t: TestRunner, _ ini: String, files: [String: String] = [:], data: [String: Data] = [:]) throws {
        let skins = t.temporaryDirectory("lua").appendingPathComponent("Skins")
        skinsFolder = skins
        let dir = skins.appendingPathComponent("Root/Sub")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: skins.appendingPathComponent("Root/@Resources"), withIntermediateDirectories: true)
        try ini.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
        var all = data
        for (path, text) in files { all[path] = Data(text.utf8) }
        for (path, bytes) in all {
            let url = skins.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        host = FakeHost()
        retainedLuaHosts.append(host)
        skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                    system: FakeSystem(), host: host)
        try skin.load()
    }

    func script(_ name: String = "Script") -> ScriptMeasure? { skin.measure(named: name) as? ScriptMeasure }

    func update(_ times: Int = 1) {
        for _ in 0..<times { skin.update() }
    }

    func inline(_ call: String, _ measure: String = "Script") -> String? {
        script(measure)?.sectionVariableFunction(call)
    }

    /// `!CommandMeasure` through the skin.
    func command(_ code: String, _ measure: String = "Script") {
        skin.execute("[!CommandMeasure \(measure) \"\"\"\(code)\"\"\"]", from: nil)
    }

    func value(_ measure: String = "Script") -> Double { skin.measure(named: measure)?.value ?? .nan }
    func string(_ measure: String = "Script") -> String { skin.measure(named: measure)?.stringValue ?? "<none>" }
    func variable(_ name: String) -> String? { skin.variable(name) }
    func text(_ meter: String) -> String { (skin.meter(named: meter) as? StringMeter)?.text ?? "<no meter \(meter)>" }
    var errors: [String] { host.logs.filter { $0.hasPrefix("Error:") } }
    func logs(_ text: String) -> [String] { host.logs.filter { $0.contains(text) } }
}

/// `[Rainmeter]`, `[Variables]` and a `[Script]` measure running `Root/Sub/test.lua`, followed by `extra`.
private func luaSkin(_ extra: String = "", options: String = "", update: Int = 1000) -> String {
    """
    [Rainmeter]
    Update=\(update)

    [Variables]
    Color=10,20,30
    Name=World
    Count=2

    [Script]
    Measure=Script
    ScriptFile=test.lua
    \(options)

    \(extra)
    """
}

private func harness(_ t: TestRunner, _ lua: String, options: String = "", extra: String = "",
                     files: [String: String] = [:], ini: String? = nil) throws -> LuaHarness {
    var all = files
    all["Root/Sub/test.lua"] = lua
    return try LuaHarness(t, ini ?? luaSkin(extra, options: options), files: all)
}

func runLuaTests(_ t: TestRunner) {
    LuaSupport.register()

    t.suite("Lua: state, prelude and limits basics") {
        let state = LuaState(memoryLimit: 8 << 20, instructionLimit: 1_000_000, secondsLimit: 2)
        t.check(state != nil)
        guard let state else { return }
        t.equal(state.openFailure, nil)
        t.equal(state.run("x = 1 + 2", chunkName: "=t"), .ok([]))
        t.equal(state.global("x"), .ok([.number(3)]))
        t.equal(state.call("nope"), .missing)
        t.equal(state.evaluate("x * 2"), .ok([.number(6)]))
        t.equal(state.evaluate("'10'"), .ok([.string("10", numeric: 10)]))
        t.equal(state.evaluate("' 0x1F '"), .ok([.string(" 0x1F ", numeric: 31)]))
        t.equal(state.evaluate("{}"), .ok([.other("table")]))
        t.equal(state.evaluate("true"), .ok([.boolean(true)]))
        t.equal(state.evaluate("nil"), .ok([.none]))
        // Restricted functions (manual, "Restrictions").
        t.equal(state.evaluate("require"), .ok([.none]))
        t.equal(state.evaluate("collectgarbage"), .ok([.none]))
        t.equal(state.evaluate("os.exit"), .ok([.none]))
        t.equal(state.evaluate("os.setlocale"), .ok([.none]))
        t.equal(state.evaluate("io.popen"), .ok([.none]))
        t.equal(state.evaluate("package"), .ok([.none]))
        t.equal(state.evaluate("debug.sethook"), .ok([.none]))
        t.equal(state.evaluate("newproxy"), .ok([.none]))
        t.equal(state.evaluate("debug.getregistry"), .ok([.none]))
        t.equal(state.evaluate("getmetatable(io.stdout)"), .ok([.boolean(false)]))
        t.equal(state.evaluate("io.type(io.stdout)"), .ok([.string("file", numeric: nil)]))
        // Available libraries.
        for name in ["string.format", "table.concat", "math.floor", "io.open", "os.date", "os.time", "os.clock",
                     "coroutine.create", "debug.traceback", "setfenv", "getfenv", "loadstring", "dofile", "pcall",
                     "math.log10", "string.gmatch", "unpack", "select", "tolua.cast"] {
            if case .ok(let v) = state.evaluate("type(\(name))") {
                t.equal(v, [.string("function", numeric: nil)], name)
            } else {
                t.check(false, name)
            }
        }
        // Errors carry the chunk name and line.
        if case .failure(let message) = state.run("local a = 1\nerror('boom')", chunkName: "@Folder/file.lua") {
            t.equal(message, "Folder/file.lua:2: boom")
        } else {
            t.check(false, "error expected")
        }
        if case .failure(let message) = state.run("x = = 1", chunkName: "@bad.lua") {
            t.check(message.hasPrefix("bad.lua:1:"), message)
        } else {
            t.check(false, "syntax error expected")
        }
        t.equal(LuaState.format(3), "3")
        t.equal(LuaState.format(0.1), "0.1")
        t.equal(LuaState.format(1.0 / 3), "0.33333333333333")
        t.equal(LuaState.format(1e20), "1e+20")
    }

    t.suite("Lua: instruction limit stops endless loops") {
        guard let state = LuaState(memoryLimit: 8 << 20, instructionLimit: 2_000_000, secondsLimit: 30) else {
            t.check(false)
            return
        }
        let start = Date()
        if case .failure(let message) = state.run("while true do end", chunkName: "@loop.lua") {
            t.check(message.contains("loop.lua:1:") && message.contains("instructions"), message)
        } else {
            t.check(false, "loop not stopped")
        }
        t.check(state.timedOut)
        // pcall cannot swallow the limit.
        if case .failure(let message) = state.run("while true do pcall(function() while true do end end) end",
                                                   chunkName: "@loop2.lua") {
            t.check(message.contains("instructions"), message)
        } else {
            t.check(false, "pcall loop not stopped")
        }
        // Nor can coroutines, xpcall or load.
        let escapes = [
            "while true do coroutine.resume(coroutine.create(function() while true do end end)) end",
            "while true do xpcall(function() while true do end end, function(e) return e end) end",
            "while true do local f = coroutine.wrap(function() while true do end end); pcall(f) end",
            "local n = 0; while true do pcall(load, function() while true do end end) end",
        ]
        for code in escapes {
            if case .failure = state.run(code, chunkName: "=escape") {} else { t.check(false, code) }
            t.check(state.timedOut, code)
        }
        // The next call gets a fresh budget.
        t.equal(state.run("y = 0; for i = 1, 1000 do y = y + i end", chunkName: "=ok"), .ok([]))
        t.check(!state.timedOut)
        t.equal(state.global("y"), .ok([.number(500500)]))
        t.check(Date().timeIntervalSince(start) < 10, "limits took too long")
    }

    t.suite("Lua: time limit") {
        guard let state = LuaState(memoryLimit: 8 << 20, instructionLimit: 0, secondsLimit: 0.2) else {
            t.check(false)
            return
        }
        let start = Date()
        if case .failure(let message) = state.run("while true do end", chunkName: "@t.lua") {
            t.check(message.contains("seconds"), message)
        } else {
            t.check(false, "loop not stopped")
        }
        t.check(Date().timeIntervalSince(start) < 2)
    }

    t.suite("Lua: memory limit") {
        guard let state = LuaState(memoryLimit: 4 << 20, instructionLimit: 0, secondsLimit: 10) else {
            t.check(false)
            return
        }
        if case .failure(let message) = state.run("local t = {} for i = 1, 1e7 do t[i] = i end", chunkName: "=m") {
            t.check(message.contains("not enough memory"), message)
        } else {
            t.check(false, "memory limit not hit")
        }
        t.check(state.memoryUsed <= 4 << 20)
        if case .failure(let message) = state.run("s = string.rep('x', 1e8)", chunkName: "=m") {
            t.check(message.contains("not enough memory"), message)
        } else {
            t.check(false, "string.rep over the limit")
        }
        // The state still works afterwards.
        t.equal(state.evaluate("1 + 1"), .ok([.number(2)]))
        t.equal(state.evaluate("string.rep('', 2^31 - 1)"), .ok([.string("", numeric: nil)]))
    }

    runLuaMeasureTests(t)
    runLuaObjectTests(t)
    runLuaBangTests(t)
    runLuaInlineTests(t)
    runLuaRobustnessTests(t)
    runLuaLibraryTests(t)
    runLuaHardeningTests(t)
}

// MARK: - Script measure

private func runLuaMeasureTests(_ t: TestRunner) {
    t.suite("Lua: Measure=Script is created through the registry") {
        let h = try harness(t, "function Update() return 1 end")
        t.check(h.script() != nil, "ScriptMeasure expected")
        t.check(!h.skin.issues.contains { $0.contains("Script") }, "\(h.skin.issues)")
    }

    t.suite("Lua: Update() return values") {
        func run(_ body: String) throws -> (Double, String, String?) {
            let h = try harness(t, "function Update() \(body) end")
            h.update()
            return (h.value(), h.string(), h.script()?.rawString)
        }
        // "return 99 / return '99': 99 as the number value, and '99' as the string value".
        var r = try run("return 99")
        t.equal(r.0, 99); t.equal(r.1, "99"); t.equal(r.2, nil)
        r = try run("return '99'")
        t.equal(r.0, 99); t.equal(r.1, "99")
        // "return 'Ninety-Nine': 0 as the number value".
        r = try run("return 'Ninety-Nine'")
        t.equal(r.0, 0); t.equal(r.1, "Ninety-Nine")
        // "return 99, 'Ninety-Nine'" in either order.
        r = try run("return 99, 'Ninety-Nine'")
        t.equal(r.0, 99); t.equal(r.1, "Ninety-Nine")
        r = try run("return 'Twenty-Five', 25")
        t.equal(r.0, 25); t.equal(r.1, "Twenty-Five")
        // "return: 0 as the number value, and '' as the string value. The same is true if no return is stated."
        r = try run("return")
        t.equal(r.0, 0); t.equal(r.1, "")
        r = try run("local x = 1")
        t.equal(r.0, 0); t.equal(r.1, "")
        r = try run("return nil")
        t.equal(r.0, 0); t.equal(r.1, "")
        r = try run("return true")
        t.equal(r.0, 1)
        r = try run("return 0x10")
        t.equal(r.0, 16)
        r = try run("return ' 1e3 '")
        t.equal(r.0, 1000); t.equal(r.1, " 1e3 ")
        r = try run("return 1/3")
        t.close(r.0, 1.0 / 3)
        r = try run("return {}")
        t.equal(r.0, 0); t.equal(r.1, "")
        r = try run("return 0/0")
        t.equal(r.0, 0)
        r = try run("return 'naïve 中文'")
        t.equal(r.1, "naïve 中文")
    }

    t.suite("Lua: number values are formatted by the String meter") {
        // History: "Fixed that AutoScale/Scale/Percentual/NumOfDecimals were not applied for MeasureName=Script".
        let h = try harness(t, "function Update() return 1536 end", extra: """
            [Plain]
            Meter=String
            MeasureName=Script
            [Decimals]
            Meter=String
            MeasureName=Script
            NumOfDecimals=2
            [Scaled]
            Meter=String
            MeasureName=Script
            AutoScale=1
            NumOfDecimals=1
            [Section]
            Meter=String
            Text=[Script]|[Script:]|[Script:1]
            DynamicVariables=1
            """)
        h.update()
        t.equal(h.text("Plain"), "1536")
        t.equal(h.text("Decimals"), "1536.00")
        t.equal(h.text("Scaled"), "1.5 k")
        t.equal(h.text("Section"), "1536|1536|1536.0")
    }

    t.suite("Lua: string values are shown as they are") {
        let h = try harness(t, "function Update() return 'Hello', 42 end", extra: """
            [Text]
            Meter=String
            MeasureName=Script
            NumOfDecimals=2
            [Both]
            Meter=String
            Text=Num = [Script:] | Str = [Script]
            DynamicVariables=1
            """)
        h.update()
        t.equal(h.text("Text"), "Hello")
        t.equal(h.text("Both"), "Num = 42 | Str = Hello")
    }

    t.suite("Lua: main chunk at load, Initialize() once in the first update") {
        let lua = """
            loaded = (loaded or 0) + 1
            inits = 0
            updates = 0
            function Initialize() inits = inits + 1 end
            function Update() updates = updates + 1; return inits * 100 + updates end
            """
        let h = try harness(t, lua)
        // Global scope ran while loading; Initialize has not run yet.
        t.equal(h.inline("loaded"), "1")
        t.equal(h.inline("inits"), "0")
        h.update()
        t.equal(h.inline("inits"), "1")
        t.equal(h.value(), 101)
        h.update(2)
        t.equal(h.inline("inits"), "1")
        t.equal(h.value(), 103)
    }

    t.suite("Lua: Initialize() runs even when the measure is disabled or paused") {
        for option in ["Disabled=1", "Paused=1", "UpdateDivider=-1", "UpdateDivider=5"] {
            let h = try harness(t, """
                inits = 0
                updates = 0
                function Initialize() inits = inits + 1 end
                function Update() updates = updates + 1 end
                """, options: option)
            h.update(3)
            t.equal(h.inline("inits"), "1", option)
            let expectedUpdates = option.hasPrefix("UpdateDivider") ? "1" : "0"
            t.equal(h.inline("updates"), expectedUpdates, option)
        }
    }

    t.suite("Lua: UpdateDivider, !UpdateMeasure and measure bangs") {
        let h = try harness(t, "n = 0\nfunction Update() n = n + 1; return n end", options: "UpdateDivider=2")
        h.update(5)
        t.equal(h.value(), 3)
        h.skin.execute("[!UpdateMeasure Script]", from: nil)
        t.equal(h.value(), 4)
        h.skin.execute("[!DisableMeasure Script]", from: nil)
        h.update(4)
        t.equal(h.inline("n"), "4")
        t.equal(h.value(), 0)
        h.skin.execute("[!EnableMeasure Script]", from: nil)
        h.skin.execute("[!PauseMeasure Script]", from: nil)
        h.update(4)
        t.equal(h.inline("n"), "4")
    }

    t.suite("Lua: an error resets the value and is logged once with file and line") {
        let h = try harness(t, """
            n = 0
            function Update()
              n = n + 1
              if n > 1 then error('broken') end
              return 5, 'five'
            end
            """)
        h.update()
        t.equal(h.value(), 5)
        h.update(3)
        t.equal(h.value(), 0)
        t.equal(h.string(), "")
        let errors = h.logs("broken")
        t.equal(errors.count, 1, "\(h.host.logs)")
        t.check(errors.first?.contains("Root/Sub/test.lua:4: broken") == true, "\(errors)")
        t.check(errors.first?.hasPrefix("Error: [Script] Script:") == true, "\(errors)")
    }

    t.suite("Lua: syntax errors and missing files") {
        let h = try harness(t, "function Update() return 1 +* 2 end")
        h.update()
        t.equal(h.value(), 0)
        t.check(h.errors.contains { $0.contains("Root/Sub/test.lua:1:") }, "\(h.host.logs)")
        let missing = try LuaHarness(t, luaSkin().replacingOccurrences(of: "test.lua", with: "missing.lua"))
        missing.update()
        t.equal(missing.value(), 0)
        t.equal(missing.string(), "")
        t.check(missing.skin.issues.contains { $0.contains("missing.lua") }, "\(missing.skin.issues)")
        missing.command("x = 1")
        t.check(!missing.logs("!CommandMeasure").isEmpty, "\(missing.host.logs)")
        let empty = try LuaHarness(t, luaSkin().replacingOccurrences(of: "ScriptFile=test.lua", with: ""))
        empty.update()
        t.check(!empty.logs("ScriptFile is not set").isEmpty)
    }

    t.suite("Lua: ScriptFile paths") {
        let files = [
            "Root/@Resources/Scripts/Lib.lua": "function Update() return 'resources' end",
            "Root/Sub/Scripts/Local.lua": "function Update() return 'local' end",
            "Root/Sub/space dir/My Script.lua": "function Update() return 'spaces' end",
        ]
        for (option, expected) in [("#@#Scripts\\Lib.lua", "resources"), ("Scripts\\Local.lua", "local"),
                                   ("\"space dir\\My Script.lua\"", "spaces"), ("#CURRENTPATH#Scripts/local.LUA", "local"),
                                   ("SCRIPTS\\LOCAL.LUA", "local")] {
            let ini = luaSkin().replacingOccurrences(of: "ScriptFile=test.lua", with: "ScriptFile=\(option)")
            let h = try LuaHarness(t, ini, files: files)
            h.update()
            t.equal(h.string(), expected, option)
        }
    }

    t.suite("Lua: script file encodings") {
        let source = "function Update() return 'Grüße ✓' end"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(source.data(using: .utf16LittleEndian)!)
        var utf16be = Data([0xFE, 0xFF])
        utf16be.append(source.data(using: .utf16BigEndian)!)
        var utf8bom = Data([0xEF, 0xBB, 0xBF])
        utf8bom.append(Data(source.utf8))
        let ansi = source.replacingOccurrences(of: " ✓", with: "").data(using: .windowsCP1252)!
        let shebang = Data(("#!/usr/bin/lua\n" + source).utf8)
        for (label, data, expected) in [("UTF-16 LE", utf16, "Grüße ✓"), ("UTF-16 BE", utf16be, "Grüße ✓"),
                                        ("UTF-8 BOM", utf8bom, "Grüße ✓"), ("ANSI", ansi, "Grüße"),
                                        ("shebang", shebang, "Grüße ✓")] {
            let h = try LuaHarness(t, luaSkin(), data: ["Root/Sub/test.lua": data])
            h.update()
            t.equal(h.string(), expected, label)
            t.equal(h.errors, [], label)
        }
    }

    t.suite("Lua: each Script measure has its own state") {
        let lua = "counter = 0\nfunction Update() counter = counter + 1; return SELF:GetName() .. counter end"
        let ini = luaSkin("""
            [Second]
            Measure=Script
            ScriptFile=test.lua
            """)
        let h = try LuaHarness(t, ini, files: ["Root/Sub/test.lua": lua])
        h.update(2)
        h.skin.execute("[!UpdateMeasure Second]", from: nil)
        t.equal(h.string("Script"), "Script2")
        t.equal(h.string("Second"), "Second3")
    }

    t.suite("Lua: the range follows the values unless MinValue / MaxValue are set") {
        let h = try harness(t, "v = 0\nfunction Update() v = v + 50; return v end", extra: """
            [Fixed]
            Measure=Script
            ScriptFile=test.lua
            MaxValue=400
            """)
        h.update(2)
        let s = h.skin.measure(named: "Script")!
        t.equal(s.maxValue, 100)
        t.equal(s.relativeValue, 1)
        let fixed = h.skin.measure(named: "Fixed")!
        t.equal(fixed.maxValue, 400)
        t.equal(fixed.relativeValue, 0.25)
    }

    t.suite("Lua: !SetOption ScriptFile loads the new script and runs its Initialize()") {
        let h = try harness(t, "function Update() return 'first' end", files: [
            "Root/Sub/second.lua": "function Initialize() started = 'yes' end\nfunction Update() return 'second ' .. started end",
        ])
        h.update()
        t.equal(h.string(), "first")
        h.skin.execute("[!SetOption Script ScriptFile second.lua]", from: nil)
        h.update()
        t.equal(h.string(), "second yes")
        t.equal(h.script()?.scriptPath.hasSuffix("second.lua"), true)
    }

    t.suite("Lua: deprecated GetStringValue() / GetValue() and PROPERTIES") {
        let h = try harness(t, """
            PROPERTIES = { Greeting = 'default', Count = 0, Missing = 'kept' }
            function Update() end
            function GetStringValue() return PROPERTIES.Greeting .. ' ' .. type(PROPERTIES.Count) .. ' ' .. PROPERTIES.Missing end
            function GetValue() return PROPERTIES.Count * 2 end
            """, options: "Greeting=Hello #Name#\nCount=(#Count# + 1)")
        h.update()
        t.equal(h.string(), "Hello World number kept")
        t.equal(h.value(), 6)
    }
}

// MARK: - SKIN, SELF, Measure and Meter objects

private func runLuaObjectTests(_ t: TestRunner) {
    t.suite("Lua: SELF:GetOption / GetNumberOption / GetName") {
        let h = try harness(t, #"""
            function Update()
              return table.concat({
                SELF:GetName(),
                SELF:GetOption('MyString'),
                SELF:GetOption('Missing'),
                SELF:GetOption('Missing', 'fallback'),
                tostring(SELF:GetNumberOption('MyNumber')),
                tostring(SELF:GetNumberOption('MyFormula')),
                tostring(SELF:GetNumberOption('Missing')),
                tostring(SELF:GetNumberOption('Missing', 7)),
                tostring(SELF:GetNumberOption('Missing', nil)),
                tostring(SELF:GetNumberOption('MyString', 3)),
                SELF:GetOption('WithMeasure'),
                SELF:GetOption('WithMeasure', '', false),
                SELF:GetOption('MEASURE'),
                SELF:GetOption('Empty', 'x'),
              }, '|')
            end
            """#, options: """
            MyString=Hello #Name#
            MyNumber=27
            MyFormula=(#Count# * 10 + 0.5)
            WithMeasure=[Other]!
            Empty=
            """, extra: """
            [Other]
            Measure=String
            String=other value
            """)
        h.update(2)
        t.equal(h.string(), "Script|Hello World||fallback|27|20.5|0|7|0|3|other value!|[Other]!|Script|")
    }

    t.suite("Lua: user options follow !SetOption") {
        let h = try harness(t, "function Update() return SELF:GetOption('Mode') end", options: "Mode=one")
        h.update()
        t.equal(h.string(), "one")
        h.skin.execute("[!SetOption Script Mode two]", from: nil)
        h.update()
        t.equal(h.string(), "two")
    }

    t.suite("Lua: SKIN:GetMeasure and measure objects") {
        let h = try harness(t, #"""
            function Update()
              local m = SKIN:GetMeasure('value')
              local out = {
                m:GetName(), m:GetValue(), m:GetStringValue(), m:GetMinValue(), m:GetMaxValue(),
                m:GetRelativeValue(), m:GetValueRange(), m:GetOption('Formula'), m:GetNumberOption('MaxValue'),
                tostring(SKIN:GetMeasure('Nope')), tostring(m), SELF:GetValue(),
              }
              for i = 1, #out do out[i] = tostring(out[i]) end
              return table.concat(out, '|')
            end
            """#, extra: """
            [Value]
            Measure=Calc
            Formula=25
            MinValue=0
            MaxValue=200
            """)
        // [Value] comes after [Script]: its value from the previous update is seen.
        h.update(2)
        t.equal(h.string(), "Value|25|25|0|200|0.125|200|25|200|nil|Measure: Value|0")
    }

    t.suite("Lua: Measure:Disable() / Enable()") {
        let h = try harness(t, #"""
            function Off() SKIN:GetMeasure('Counter'):Disable() end
            function On() SKIN:GetMeasure('Counter'):Enable() end
            function Update() end
            """#, extra: """
            [Counter]
            Measure=Calc
            Formula=Counter
            """)
        h.update(2)
        t.equal(h.value("Counter"), 1)
        h.command("Off()")
        t.equal(h.value("Counter"), 0)
        t.equal(h.skin.measure(named: "Counter")?.disabled, true)
        h.update()
        t.equal(h.value("Counter"), 0)
        h.command("On()")
        h.update()
        t.equal(h.value("Counter"), 3)
    }

    t.suite("Lua: SKIN:GetMeter and meter objects") {
        let h = try harness(t, #"""
            function Report()
              local m = SKIN:GetMeter('Box')
              local c = SKIN:GetMeter('Inner')
              result = table.concat({
                m:GetName(), m:GetX(), m:GetY(), m:GetW(), m:GetH(), m:GetOption('SolidColor'),
                m:GetOption('FontSize', '9'), m:GetOption('Nope', 'd'), c:GetX(), c:GetX(true), c:GetY(true),
                tostring(SKIN:GetMeter('Nope')), tostring(m),
              }, '|')
            end
            function Update() end
            """#, extra: """
            [Style]
            SolidColor=1,2,3
            [Box]
            Meter=Image
            MeterStyle=Style
            X=10
            Y=20
            W=100
            H=50
            Padding=5,5,5,5
            [Inner]
            Meter=Image
            Container=Box
            X=7
            Y=3
            W=10
            H=10
            """)
        h.update()
        h.command("Report()")
        t.equal(h.inline("result"), "Box|10|20|110|60|1,2,3|9|d|7|17|23|nil|Meter: Box")
    }

    t.suite("Lua: Meter:SetX/SetY/SetW/SetH, Hide/Show, SetText") {
        let h = try harness(t, #"""
            function Move()
              local m = SKIN:GetMeter('Box')
              m:SetX(40); m:SetY(30); m:SetW(80); m:SetH(25)
              moved = table.concat({ m:GetX(), m:GetY(), m:GetW(), m:GetH() }, ',')
              m:Hide()
              hidden = table.concat({ m:GetW(), m:GetH() }, ',')
            end
            function Unhide() SKIN:GetMeter('Box'):Show() end
            function Label() SKIN:GetMeter('Label'):SetText('Set by Lua') end
            function Update() end
            """#, extra: """
            [Box]
            Meter=Image
            X=1
            Y=2
            W=3
            H=4
            SolidColor=255,0,0
            [Label]
            Meter=String
            Text=Before
            """)
        h.update()
        h.command("Move()")
        t.equal(h.inline("moved"), "40,30,80,25")
        t.equal(h.inline("hidden"), "0,0")
        let box = h.skin.meter(named: "Box")!
        t.equal(box.hidden, true)
        h.command("Unhide()")
        h.update()
        t.equal(box.hidden, false)
        t.equal(box.frame, SkinRect(x: 40, y: 30, width: 80, height: 25))
        h.command("Label()")
        h.update()
        t.equal(h.text("Label"), "Set by Lua")
    }

    t.suite("Lua: SKIN:GetVariable") {
        let h = try harness(t, #"""
            function Update()
              return table.concat({
                SKIN:GetVariable('Name'), SKIN:GetVariable('name'), tostring(SKIN:GetVariable('Nope')),
                SKIN:GetVariable('Nope', 'n/a'), SKIN:GetVariable('CURRENTCONFIG'), SKIN:GetVariable('ROOTCONFIG'),
                SKIN:GetVariable('CURRENTSECTION'), SKIN:GetVariable('CURRENTFILE'),
              }, '|')
            end
            """#)
        h.update()
        t.equal(h.string(), "World|World|nil|n/a|Root\\Sub|Root|Script|Skin.ini")
        // Paths use Windows separators, as scripts expect (see docs/compat/lua.md).
        h.command("at = SKIN:GetVariable('@'); cur = SKIN:GetVariable('CURRENTPATH')")
        let at = h.inline("at") ?? ""
        t.check(at.hasSuffix("\\Root\\@Resources\\") && !at.contains("/"), at)
        t.check((h.inline("cur") ?? "").hasSuffix("\\Root\\Sub\\"), h.inline("cur") ?? "")
    }

    t.suite("Lua: SKIN:ReplaceVariables and ParseFormula") {
        let h = try harness(t, #"""
            function Update()
              local out = {
                SKIN:ReplaceVariables('Hello #Name#, [Other] #*Name*#'),
                SKIN:ParseFormula('(2+3)*2'), SKIN:ParseFormula('(Round(239.78))'), SKIN:ParseFormula('42'),
                SKIN:ParseFormula('(#Count# * 3)'), SKIN:ParseFormula('(Other + 1)'), SKIN:ParseFormula('(1 = 1)'),
                SKIN:ParseFormula('(2+'), SKIN:ParseFormula('hello'), SKIN:ParseFormula(''),
              }
              for i = 1, 10 do out[i] = tostring(out[i]) end
              return table.concat(out, '|')
            end
            """#, extra: """
            [Other]
            Measure=Calc
            Formula=9
            """)
        h.update(2)
        t.equal(h.string(), "Hello World, 9 #Name#|10|240|42|6|10|1|nil|nil|nil")
    }

    t.suite("Lua: SKIN:MakePathAbsolute and skin geometry") {
        let h = try harness(t, #"""
            function Update()
              return table.concat({
                SKIN:MakePathAbsolute('Images\\a.png'), SKIN:MakePathAbsolute('../x/'), SKIN:MakePathAbsolute(''),
                SKIN:MakePathAbsolute('/tmp/abs.txt'), SKIN:GetX(), SKIN:GetY(), SKIN:GetW(), SKIN:GetH(),
              }, '|')
            end
            """#, extra: """
            [Box]
            Meter=Image
            W=120
            H=45
            """)
        h.update(2)
        let parts = h.string().components(separatedBy: "|")
        t.equal(parts.count, 8)
        guard parts.count == 8 else { return }
        t.check(parts[0].hasSuffix("\\Root\\Sub\\Images\\a.png"), parts[0])
        t.check(parts[1].hasSuffix("\\Root\\x\\"), parts[1])
        t.check(parts[2].hasSuffix("\\Root\\Sub\\"), parts[2])
        t.equal(parts[3], "\\tmp\\abs.txt")
        t.equal(Array(parts[4...]), ["0", "0", "120", "45"])
    }

    t.suite("Lua: calling methods with '.' instead of ':' is a clear error") {
        let h = try harness(t, "function Update() local v = SKIN.GetVariable('Name'); return v end")
        h.update()
        t.check(h.errors.contains { $0.contains("SKIN:GetVariable() must be called with ':'") && $0.contains("test.lua:1:") },
                "\(h.host.logs)")
        let m = try harness(t, "function Update() local m = SKIN:GetMeasure('Script'); local v = m.GetValue(); return v end")
        m.update()
        t.check(m.errors.contains { $0.contains("Measure:GetValue() must be called with ':'") }, "\(m.host.logs)")
        let a = try harness(t, "function Update() local v = SKIN:GetMeasure({}); return v end")
        a.update()
        t.check(a.errors.contains { $0.contains("test.lua:1: bad argument #1 to 'GetMeasure' (string expected, got table)") },
                "\(a.host.logs)")
    }
}

// MARK: - SKIN:Bang and !CommandMeasure

private func runLuaBangTests(_ t: TestRunner) {
    t.suite("Lua: SKIN:Bang with separate parameters") {
        let h = try harness(t, #"""
            function Update()
              SKIN:Bang('!SetOption', 'Label', 'Text', 'Hello, world! [x] "quoted"')
              SKIN:Bang('!SetOption', 'Label', 'FontSize', 12)
              SKIN:Bang('SetVariable', 'Plain', 'no bang mark')
              SKIN:Bang('!RainmeterSetVariable', 'Legacy', 'legacy name')
              SKIN:Bang('!SetVariable', 'FromVar', '#Name#!')
              SKIN:Bang('!SetVariable', 'Formula', '(2 * 21)')
              SKIN:Bang('!SetVariable', 'Flag', true)
              SKIN:Bang('!UpdateMeter', 'Label')
            end
            """#, extra: """
            [Label]
            Meter=String
            Text=Before
            """)
        h.update()
        t.equal(h.text("Label"), "Hello, world! [x] \"quoted\"")
        t.equal(h.skin.meter(named: "Label")?.rawOption("FontSize"), "12")
        t.equal(h.variable("Plain"), "no bang mark")
        t.equal(h.variable("Legacy"), "legacy name")
        t.equal(h.variable("FromVar"), "World!")
        t.equal(h.variable("Formula"), "42")
        t.equal(h.variable("Flag"), "1")
    }

    t.suite("Lua: SKIN:Bang arguments stay whole") {
        let h = try harness(t, #"""
            function Update()
              SKIN:Bang('!SetOption', 'Label', 'Text', '')
              SKIN:Bang('!SetVariable', 'Spaces', '  padded  ')
              SKIN:Bang('!SetVariable', 'Brackets', 'a ] b [ c')
              SKIN:Bang('!SetVariable', 'Quote', '"quoted" at the start')
              SKIN:Bang('!SetVariable', 'Magic', 'say """hi"""')
              SKIN:Bang('!SetVariable', 'Lines', 'one\ntwo')
              SKIN:Bang('!SetOption Label', 'FontColor', '1,2,3')
            end
            """#, extra: """
            [Style]
            Text=from style
            [Label]
            Meter=String
            MeterStyle=Style
            Text=own text
            """)
        h.update(2)
        // "!SetOption Section Option \"\"" removes the option: the MeterStyle value applies again.
        t.equal(h.text("Label"), "from style")
        t.equal(h.variable("Spaces"), "  padded  ")
        t.equal(h.variable("Brackets"), "a ] b [ c")
        t.equal(h.variable("Quote"), "\"quoted\" at the start")
        t.equal(h.variable("Lines"), "one\ntwo")
        t.equal(h.skin.meter(named: "Label")?.rawOption("FontColor"), "1,2,3")
        t.equal(h.variable("Magic"), "say \"\"\"hi\"\"\"")
    }

    t.suite("Lua: SKIN:Bang with one action string") {
        let h = try harness(t, #"""
            function Update()
              SKIN:Bang('!SetVariable A "one two"')
              SKIN:Bang('[!SetVariable B 2][!SetVariable C "[#A]"]')
              SKIN:Bang('"https://example.com/page"')
              SKIN:Bang('["https://example.com/other"]')
              SKIN:Bang('')
            end
            """#)
        h.update()
        t.equal(h.variable("A"), "one two")
        t.equal(h.variable("B"), "2")
        t.equal(h.variable("C"), "one two")
        t.equal(h.host.executed, ["https://example.com/page", "https://example.com/other"])
    }

    t.suite("Lua: bangs run when control returns from the script") {
        // Manual: "The bang will be executed by Rainmeter when control is returned from the script."
        let h = try harness(t, #"""
            function Update()
              SKIN:Bang('!SetVariable', 'Seen', 'new')
              during = SKIN:GetVariable('Seen')
              return 7
            end
            """#, ini: """
            [Rainmeter]
            Update=1000
            [Variables]
            Seen=old
            [Script]
            Measure=Script
            ScriptFile=test.lua
            [Echo]
            Meter=String
            Text=#Seen#
            DynamicVariables=1
            """)
        h.update()
        t.equal(h.inline("during"), "old")
        t.equal(h.variable("Seen"), "new")
        t.equal(h.text("Echo"), "new")
    }

    t.suite("Lua: bangs from Update() see the new value") {
        let h = try harness(t, #"""
            n = 0
            function Update()
              n = n + 1
              SKIN:Bang('!SetVariable', 'Copy', '[Script]')
              return n * 10
            end
            """#)
        h.update(2)
        t.equal(h.variable("Copy"), "20")
    }

    t.suite("Lua: window and app bangs reach the host") {
        let h = try harness(t, #"""
            function Go()
              SKIN:MoveWindow(200.7, 100)
              SKIN:FadeWindow(255, 100)
              SKIN:Bang('!Refresh')
              SKIN:Bang('!ActivateConfig', 'Other\\Config', 'Skin.ini')
              SKIN:Bang('!Delay', 1000)
            end
            function Update() end
            """#)
        h.update()
        h.host.handled = []
        h.command("Go()")
        t.equal(h.host.handled.map(\.name), ["move", "settransparency", "refresh", "activateconfig"])
        t.equal(h.host.handled.first?.args, ["200", "100"])
        t.equal(h.host.handled[1].args, ["100"])
        t.equal(h.host.handled.last?.args, ["Other\\Config", "Skin.ini"])
    }

    t.suite("Lua: !CommandMeasure runs Lua code") {
        let h = try harness(t, #"""
            total = 0
            function Add(n) total = total + n end
            function Update() return total end
            """#, extra: """
            [Button]
            Meter=String
            Text=Add
            LeftMouseUpAction=[!CommandMeasure Script "Add(5); Add(2)"][!UpdateMeasure Script]
            """)
        h.update()
        h.command("Add(1)")
        t.equal(h.inline("total"), "1")
        // "Multiple statements may be separated by semicolons (;). All statements are global."
        h.command("a = 2; b = a * 3; print(SKIN:ParseFormula('(2+2)'))")
        t.equal(h.inline("b"), "6")
        t.check(!h.logs("[Script] 4").isEmpty, "\(h.host.logs)")
        let box = h.skin.meter(named: "Button")!
        h.skin.mouseEvent(.leftUp, x: box.frame.x + 1, y: box.frame.y + 1)
        t.equal(h.inline("total"), "8")
        t.equal(h.value(), 8)
        // Errors in commands are logged with the chunk name.
        h.command("Nope()")
        t.check(h.errors.contains { $0.contains("!CommandMeasure:1:") && $0.contains("Nope") }, "\(h.host.logs)")
        // Empty commands do nothing.
        let before = h.host.logs.count
        h.command("   ")
        t.equal(h.host.logs.count, before)
    }

    t.suite("Lua: !CommandMeasure before the first update runs Initialize() first") {
        let h = try harness(t, #"""
            function Initialize() suffix = ' k' end
            function Format(v) SKIN:Bang('!SetVariable', 'Out', v .. suffix) end
            """#, ini: """
            [Rainmeter]
            Update=1000
            [Trigger]
            Measure=Calc
            Formula=1
            IfCondition=Trigger = 1
            IfTrueAction=[!CommandMeasure Script "Format(12)"]
            [Script]
            Measure=Script
            ScriptFile=test.lua
            """)
        h.update()
        t.equal(h.variable("Out"), "12 k")
        t.equal(h.errors, [])
    }

    t.suite("Lua: one script commanding another") {
        let ini = """
            [Rainmeter]
            Update=1000
            [First]
            Measure=Script
            ScriptFile=first.lua
            [Second]
            Measure=Script
            ScriptFile=second.lua
            """
        let h = try LuaHarness(t, ini, files: [
            "Root/Sub/first.lua": "function Update() SKIN:Bang('!CommandMeasure', 'Second', 'Mark(\\'from first\\')') end",
            "Root/Sub/second.lua": "mark = 'none'\nfunction Mark(s) mark = s end",
        ])
        h.update()
        t.equal(h.inline("mark", "Second"), "from first")
    }

    t.suite("Lua: bangs that update the script itself stay bounded") {
        let h = try harness(t, #"""
            n = 0
            function Update()
              n = n + 1
              SKIN:Bang('!UpdateMeasure', SELF:GetName())
              return n
            end
            """#)
        h.update()
        let n = Double(h.inline("n") ?? "") ?? 0
        t.check(n > 1 && n < 100, "\(n)")
        t.check(!h.logs("nested too deeply").isEmpty, "\(h.host.logs)")
    }

    t.suite("Lua: Initialize() bangs and the main chunk's bangs wait for the first update") {
        let h = try harness(t, #"""
            SKIN:Bang('!SetVariable', 'FromChunk', 'chunk')
            function Initialize()
              SKIN:Bang('!SetOption', SELF:GetName(), 'UpdateDivider', -1)
              SKIN:Bang('!HideMeterGroup', 'Hidden')
            end
            n = 0
            function Update() n = n + 1 end
            """#, extra: """
            [A]
            Meter=String
            Text=a
            Group=Hidden
            """)
        t.equal(h.variable("FromChunk"), nil)
        h.update(4)
        t.equal(h.variable("FromChunk"), "chunk")
        t.equal(h.skin.meter(named: "A")?.hidden, true)
        t.equal(h.inline("n"), "1")
    }
}

// MARK: - Inline Lua

private func runLuaInlineTests(_ t: TestRunner) {
    t.suite("Lua: inline call parsing") {
        typealias C = InlineLuaCall
        t.equal(C.parse("myVariable"), .variable("myVariable"))
        t.equal(C.parse(" _x1 "), .variable("_x1"))
        t.equal(C.parse("F()"), .call("F", []))
        t.equal(C.parse("F( )"), .call("F", []))
        t.equal(C.parse("GetCharacterInString('Rainmeter', 5)"), .call("GetCharacterInString", [.text("Rainmeter"), .number(5)]))
        t.equal(C.parse("F(\"double\", -2.5, 0x10, 1e3)"), .call("F", [.text("double"), .number(-2.5), .number(16), .number(1000)]))
        // true / false / nil are case-insensitive in the skin (history notes).
        t.equal(C.parse("F(true, FALSE, Nil, nil)"), .call("F", [.boolean(true), .boolean(false), .none, .none]))
        // Formulas go through the Rainmeter math parser.
        t.equal(C.parse("F((2 + 3) * 2, (Round(2.6)), (1 = 1))"), .call("F", [.number(10), .number(3), .number(1)]))
        t.equal(C.parse("F((Max(1, 7)), 'a, b')"), .call("F", [.number(7), .text("a, b")]))
        // Apostrophes and the other quote inside strings.
        t.equal(C.parse("F('It's here', \"say \"hi\"\")"), .call("F", [.text("It's here"), .text("say \"hi\"")]))
        t.equal(C.parse(#"F('a\'b', 'C:\Users\x', 'line\nnext')"#), .call("F", [.text("a'b"), .text(#"C:\Users\x"#), .text("line\nnext")]))
        t.equal(C.parse("F('')"), .call("F", [.text("")]))
        // Unquoted words are Lua names; other expressions are evaluated by Lua.
        t.equal(C.parse("F(someVar, t.x)"), .call("F", [.expression("someVar"), .expression("t.x")]))
        t.equal(C.parse("t.x"), .expression("t.x"))
        t.equal(C.parse("F(1)(2)"), .expression("F(1)(2)"))
        t.equal(C.parse("F('unclosed)"), .expression("F('unclosed)"))
        t.equal(C.parse(""), nil)
    }

    t.suite("Lua: inline calls and variables") {
        let h = try harness(t, #"""
            greeting = 'Hi'
            count = 3
            flag = true
            t = { x = 'field' }
            function Add(a, b) return a + b end
            function Join(...) local out = {} for i = 1, select('#', ...) do out[i] = tostring((select(i, ...))) end return table.concat(out, ',') end
            function Nothing() end
            function Table() return {} end
            function Fail() error('inline failure') end
            function Greet(name) return greeting .. ', ' .. name end
            """#)
        h.update()
        t.equal(h.inline("greeting"), "Hi")
        t.equal(h.inline("count"), "3")
        t.equal(h.inline("flag"), "1")
        t.equal(h.inline("Add(2, 3.5)"), "5.5")
        t.equal(h.inline("Add((2*3), 1)"), "7")
        t.equal(h.inline("Join('a', 1, true, nil, count)"), "a,1,true,nil,3")
        t.equal(h.inline("Greet('Bob')"), "Hi, Bob")
        t.equal(h.inline("t.x"), "field")
        t.equal(h.inline("Add(1, 2) * 10"), "30")
        t.equal(h.inline("Nothing()"), "")
        t.equal(h.inline("undefinedVariable"), "")
        t.equal(h.inline("Table()"), nil)
        t.equal(h.inline("Fail()"), nil)
        t.equal(h.inline("NoSuchFunction(1)"), nil)
        t.check(h.errors.contains { $0.contains("test.lua:9: inline failure") }, "\(h.host.logs)")
        t.check(h.errors.contains { $0.contains("NoSuchFunction") }, "\(h.host.logs)")
    }

    t.suite("Lua: inline Lua in meter options and bangs") {
        let h = try harness(t, #"""
            function Initialize()
              translate = { english = 'Today is', french = "Aujourd'hui, c'est" }
              days = { english = { 'Sunday', 'Monday' }, french = { 'dimanche', 'lundi' } }
            end
            function Header(lang) return translate[string.lower(lang)] end
            function Day(n, lang) return days[string.lower(lang)][n + 1] end
            function Width(n) return n * 20 end
            function Echo(s) return s end
            """#, ini: """
            [Rainmeter]
            Update=1000
            [Variables]
            Lang=English
            [Script]
            Measure=Script
            ScriptFile=test.lua
            Disabled=1
            [Day]
            Measure=Calc
            Formula=1
            [Title]
            Measure=String
            String=It's "quoted"
            [Header]
            Meter=String
            Text=[&Script:Header('[#Lang]')]
            DynamicVariables=1
            [DayName]
            Meter=String
            Text=[#Lang]: [&Script:Day([&Day], '[#Lang]')] / French: [&Script:Day([&Day], 'French')]
            DynamicVariables=1
            [Sized]
            Meter=Image
            W=[&Script:Width(3)]
            H=10
            DynamicVariables=1
            [Classic]
            Meter=String
            Text=[Script:Width(1)]
            DynamicVariables=1
            [Quoted]
            Meter=String
            Text=[&Script:Echo('[&Title]')]
            DynamicVariables=1
            [Static]
            Meter=String
            Text=[&Script:Width(1)]
            """)
        h.update()
        t.equal(h.text("Header"), "Today is")
        t.equal(h.text("DayName"), "English: Monday / French: lundi")
        t.equal(h.skin.meter(named: "Sized")?.frame.width, 60)
        t.equal(h.text("Classic"), "20")
        t.equal(h.text("Quoted"), "It's \"quoted\"")
        // Without DynamicVariables=1 section variables are resolved once when the option is read (engine rule,
        // docs/compat/engine.md), inline Lua included.
        t.equal(h.text("Static"), "20")
        // In bangs they are always resolved.
        h.skin.execute("[!SetVariable Result \"[&Script:Width(5)]\"]", from: nil)
        t.equal(h.variable("Result"), "100")
        // Errors before Initialize() (the skin's load) are expected by the manual: debug level only.
        t.equal(h.errors, [])
    }

    t.suite("Lua: inline Lua can call back into the same script") {
        let h = try harness(t, #"""
            function Inner() return 'inner' end
            function Update() return SKIN:ReplaceVariables('<[&Script:Inner()]>') end
            """#)
        h.update()
        t.equal(h.string(), "<inner>")
    }

    t.suite("Lua: FlipCoin-style command and inline variables") {
        let h = try harness(t, #"""
            flipText = 'None'
            total = 0
            function Flip() total = total + 1; flipText = (total % 2 == 1) and 'Heads' or 'Tails' end
            """#, options: "Disabled=1", extra: """
            [Coin]
            Meter=String
            Text=It's [&Script:flipText] after [&Script:total]
            DynamicVariables=1
            LeftMouseUpAction=[!CommandMeasure Script "Flip()"][!UpdateMeter Coin][!Redraw]
            """)
        h.update()
        t.equal(h.text("Coin"), "It's None after 0")
        let coin = h.skin.meter(named: "Coin")!
        h.skin.mouseEvent(.leftUp, x: coin.frame.x + 1, y: coin.frame.y + 1)
        t.equal(h.text("Coin"), "It's Heads after 1")
    }
}

// MARK: - Robustness

/// Runs `body` with smaller limits (restored afterwards).
private func withLimits(instructions: UInt64, seconds: Double, memory: Int = 64 << 20, _ body: () throws -> Void) rethrows {
    let saved = (LuaSupport.instructionLimit, LuaSupport.secondsLimit, LuaSupport.memoryLimit)
    LuaSupport.instructionLimit = instructions
    LuaSupport.secondsLimit = seconds
    LuaSupport.memoryLimit = memory
    defer { (LuaSupport.instructionLimit, LuaSupport.secondsLimit, LuaSupport.memoryLimit) = saved }
    try body()
}

private func runLuaRobustnessTests(_ t: TestRunner) {
    t.suite("Lua: an endless Update() is stopped, then the script is suspended") {
        try withLimits(instructions: 1_000_000, seconds: 5) {
            let h = try harness(t, "n = 0\nfunction Update() n = n + 1; while true do end end\nfunction Get() return n end")
            let start = Date()
            h.update(5)
            t.check(Date().timeIntervalSince(start) < 5)
            t.equal(h.script()?.suspended, true)
            t.equal(h.inline("n"), nil)   // a suspended script answers nothing
            t.check(h.errors.contains { $0.contains("test.lua:2:") && $0.contains("instructions") }, "\(h.host.logs)")
            t.check(h.errors.contains { $0.contains("stopped after 3 calls of Update") }, "\(h.host.logs)")
            t.check(h.skin.issues.contains { $0.contains("endless loop") }, "\(h.skin.issues)")
            t.equal(h.value(), 0)
        }
    }

    t.suite("Lua: successful inline calls do not hide an endless Update()") {
        try withLimits(instructions: 1_000_000, seconds: 5) {
            let h = try harness(t, "function Update() while true do end end\nfunction Label() return 'ok' end", extra: """
                [Text]
                Meter=String
                Text=[&Script:Label()]
                DynamicVariables=1
                """)
            h.update(4)
            t.equal(h.script()?.suspended, true)
        }
    }

    t.suite("Lua: a suspended script keeps its value") {
        try withLimits(instructions: 1_000_000, seconds: 5) {
            let h = try harness(t, "n = 0\nfunction Update() n = n + 1; if n > 2 then while true do end end; return 10 end",
                                options: "InvertMeasure=1\nMaxValue=100")
            h.update(2)
            t.equal(h.value(), 90)
            // The failed calls reset the value to 0 (inverted: 100); it no longer changes once suspended.
            h.update(6)
            t.equal(h.script()?.suspended, true)
            t.equal(h.value(), 100)
            h.update(2)
            t.equal(h.value(), 100)
        }
    }

    t.suite("Lua: occasional limit hits do not suspend") {
        try withLimits(instructions: 1_000_000, seconds: 5) {
            let h = try harness(t, """
                n = 0
                function Update()
                  n = n + 1
                  if n % 2 == 0 then while true do end end
                  return n
                end
                """)
            h.update(7)
            t.equal(h.script()?.suspended, false)
            t.equal(h.value(), 7)
        }
    }

    t.suite("Lua: endless loops in the main chunk, Initialize, commands and inline calls") {
        try withLimits(instructions: 500_000, seconds: 5) {
            let h = try harness(t, """
                while true do end
                """)
            h.update()
            t.check(h.errors.contains { $0.contains("instructions") }, "\(h.host.logs)")
            let i = try harness(t, "function Initialize() while true do end end\nfunction Update() return 1 end")
            i.update(2)
            t.equal(i.value(), 1)
            let c = try harness(t, "function Spin() while true do end end\nfunction Get() return 'ok' end")
            c.update()
            c.command("Spin()")
            t.equal(c.inline("Get()"), "ok")
            t.equal(c.inline("Spin()"), nil)
        }
    }

    t.suite("Lua: the memory limit stops a script without crashing") {
        try withLimits(instructions: 0, seconds: 10, memory: 4 << 20) {
            let h = try harness(t, """
                function Update()
                  local t = {}
                  for i = 1, 1e7 do t[i] = tostring(i) end
                  return #t
                end
                """)
            h.update()
            t.check(h.errors.contains { $0.contains("not enough memory") }, "\(h.host.logs)")
            t.check((h.script()?.lua?.memoryUsed ?? .max) <= 4 << 20)
            t.equal(h.value(), 0)
        }
    }

    t.suite("Lua: states are released with the skin") {
        weak var state: LuaState?
        do {
            let h = try harness(t, "function Update() return 1 end")
            h.update()
            state = h.script()?.lua
            t.check(state != nil)
            h.skin.close()
        }
        t.check(state == nil, "the Lua state outlived its skin")
    }

    t.suite("Lua: errors are logged once per message") {
        let h = try harness(t, "function Update() error('same') end")
        h.update(20)
        t.equal(h.logs("same").count, 1)
        let many = try harness(t, "n = 0\nfunction Update() n = n + 1; error('message ' .. n) end")
        many.update(150)
        t.check(many.logs("message ").count <= ScriptMeasure.maxReportedMessages + 1)
        t.equal(many.logs("too many different errors").count, 1)
    }

    t.suite("Lua: print() goes to the log, throttled") {
        let h = try harness(t, "function Update() print('value', 42, nil, true) end")
        h.update()
        t.equal(h.logs("[Script] value\t42\tnil\ttrue").count, 1, "\(h.host.logs)")
        let flood = try harness(t, "function Update() for i = 1, 1000 do print('line', i) end end")
        flood.update()
        t.equal(flood.logs("[Script] line").count, LuaSupport.maxPrintsPerSecond)
        t.equal(flood.logs("lines are dropped").count, 1)
    }

    t.suite("Lua: SKIN:Bang floods are bounded") {
        let h = try harness(t, "function Update() for i = 1, 20000 do SKIN:Bang('!SetVariable', 'N', i) end end")
        h.update()
        t.equal(h.logs("too many SKIN:Bang() calls").count, 1)
        t.check(h.variable("N") != nil)
    }

    t.suite("Lua: ScriptFile changed while the script runs") {
        let h = try harness(t, #"""
            function Update()
              SKIN:Bang('!SetOption', SELF:GetName(), 'ScriptFile', 'other.lua')
              SKIN:Bang('!UpdateMeasure', SELF:GetName())
              return 'first'
            end
            """#, files: ["Root/Sub/other.lua": "function Update() return 'other' end"])
        h.update()
        t.equal(h.string(), "other")
        t.equal(h.errors, [])
    }

    t.suite("Lua: hostile scripts") {
        try withLimits(instructions: 2_000_000, seconds: 5) {
            let scripts = [
                "function Update() return string.rep('x', 1e9) end",
                "function Update() local s = 'x' for i = 1, 40 do s = s .. s end return s end",
                "function Update() setmetatable(_G, { __index = function(t, k) error('strict: ' .. k) end }) end",
                "function f() return f() + 1 end function Update() return f() end",
                "function Update() return coroutine.wrap(function() while true do coroutine.yield(1) end end)() end",
                "function Update() debug.sethook() end",
                "function Update() os.exit(1) end",
                "function Update() return io.read('*a') end",
                "function Update() return dofile() end",
                "function Update() return loadfile('/dev/zero') end",
                "function Update() SKIN = nil; SELF = nil; return 1 end",
                "function Update() error(setmetatable({}, { __tostring = function() while true do end end })) end",
                "function Update() error() end",
                "function Update() error(42) end",
                "function Update() local t = newproxy(true); getmetatable(t).__gc = function() while true do end end end",
                "function Update() getmetatable(io.stdout).__gc = function() while true do end end end",
                "function Update() debug.getmetatable(io.stdout).__gc = function() while true do end end end",
                "function Update() debug.getregistry()['FILE*'].__gc = function() while true do end end end",
            ]
            for code in scripts {
                let h = try harness(t, code)
                h.update(2)
                h.skin.close()
                t.check(true, code)
            }
        }
        let h = try harness(t, "function Update() error(42) end")
        h.update()
        t.check(h.errors.contains { $0.hasSuffix("test.lua:1: 42") }, "\(h.host.logs)")
    }
}

// MARK: - Standard library on macOS

private func runLuaLibraryTests(_ t: TestRunner) {
    t.suite("Lua: io with Windows paths relative to the skin folder") {
        let h = try harness(t, #"""
            function Update()
              local f = assert(io.open('Data\\notes.txt'))
              local text = f:read('*all')
              f:close()
              local lines = {}
              for line in io.lines(SKIN:MakePathAbsolute('Data\\notes.txt')) do lines[#lines + 1] = line end
              local out = assert(io.open(SKIN:MakePathAbsolute('Data\\out.txt'), 'w'))
              out:write('written')
              out:close()
              local input = io.input(SKIN:GetVariable('@') .. 'Config\\Run.cfg', 'r')
              local cfg = io.read('*l')
              io.close(input)
              assert(os.rename('Data\\out.txt', 'Data\\moved.txt'))
              local check = io.open('Data/moved.txt'):read('*a')
              assert(os.remove('Data\\moved.txt'))
              return table.concat({ text:gsub('\n', '/'), #lines, cfg, check }, '|')
            end
            """#, files: [
                "Root/Sub/Data/notes.txt": "one\ntwo",
                "Root/@Resources/Config/Run.cfg": "first line\nsecond",
            ])
        h.update()
        t.equal(h.string(), "one/two|2|first line|written")
        t.equal(h.errors, [])
        t.check(!FileManager.default.fileExists(atPath: h.skinsFolder.appendingPathComponent("Root/Sub/Data/moved.txt").path))
    }

    t.suite("Lua: files are read in text mode like on Windows") {
        let h = try harness(t, #"""
            function Update()
              local out = {}
              for line in io.lines('crlf.txt') do out[#out + 1] = '<' .. line .. '>' end
              local f = io.open('crlf.txt')
              local first, second = f:read('*l', '*l')
              local rest = f:read('*a')
              f:close()
              local lines = {}
              for line in io.open('crlf.txt'):lines() do lines[#lines + 1] = #line end
              local b = io.open('crlf.txt', 'rb')
              local raw = b:read('*a')
              b:close()
              io.input('crlf.txt')
              local viaInput = io.read('*l')
              return table.concat(out) .. '|' .. first .. second .. '|' .. rest:gsub('\n', '/') .. '|' ..
                table.concat(lines, ',') .. '|' .. #raw .. '|' .. viaInput
            end
            """#, files: ["Root/Sub/crlf.txt": "one\r\ntwo\r\nthree\r\n"])
        h.update()
        t.equal(h.string(), "<one><two><three>|onetwo|three/|3,3,5|17|one")
        t.equal(h.errors, [])
    }

    t.suite("Lua: os.clock counts wall-clock time") {
        // Windows' clock() is wall-clock time; the Mac C library's is CPU time, which does not move while idle.
        let h = try harness(t, "function Update() end")
        h.update()
        let before = Double(h.inline("os.clock()") ?? "") ?? -1
        Thread.sleep(forTimeInterval: 0.3)
        let after = Double(h.inline("os.clock()") ?? "") ?? -1
        t.check(after - before >= 0.25 && after - before < 2, "\(before) \(after)")
    }

    t.suite("Lua: dofile and loadfile") {
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("function Wide() return 'wide ✓' end".data(using: .utf16LittleEndian)!)
        let h = try LuaHarness(t, luaSkin(), files: [
            "Root/Sub/test.lua": #"""
                function Initialize()
                  dofile(SKIN:GetVariable('@') .. 'Lib\\toolkit.lua')
                  dofile(SKIN:MakePathAbsolute('local.lua'))
                  dofile('relative.lua')
                  local chunk = loadfile(SKIN:GetVariable('@') .. 'Lib\\wide.lua')
                  chunk()
                  missing, message = loadfile('nope.lua')
                  ok, err = pcall(dofile, 'nope.lua')
                  ok2, err2 = pcall(dofile, SKIN:GetVariable('@') .. 'Lib\\broken.lua')
                end
                function Update() return Toolkit() .. Local() .. Relative() .. Wide() end
                """#,
            "Root/@Resources/Lib/toolkit.lua": "function Toolkit() return 'T' end",
            "Root/@Resources/Lib/broken.lua": "x = 1\nerror('in library')",
            "Root/Sub/local.lua": "function Local() return 'L' end",
            "Root/Sub/relative.lua": "function Relative() return 'R' end",
        ], data: ["Root/@Resources/Lib/wide.lua": utf16])
        h.update()
        t.equal(h.string(), "TLRwide ✓")
        t.equal(h.inline("missing"), "")
        t.check((h.inline("message") ?? "").contains("cannot open"), h.inline("message") ?? "")
        t.check((h.inline("err") ?? "").contains("cannot open"), h.inline("err") ?? "")
        // Errors in a library point at the library file and line.
        t.equal(h.inline("err2"), "Root/@Resources/Lib/broken.lua:2: in library")
    }

    t.suite("Lua: os.date with the Windows '#' flag, os.time, os.clock") {
        let h = try harness(t, #"""
            function Update()
              local t = os.time({ year = 2026, month = 3, day = 5, hour = 7, min = 4, sec = 9 })
              return table.concat({
                os.date('%d.%m %H:%M', t), os.date('%#d.%#m %#H:%#M:%#S', t), os.date('%%#d %#d', t),
                os.date('!%Y', 0), type(os.date('*t').year), type(os.clock()), os.date('%#j', t),
              }, '|')
            end
            """#)
        h.update()
        t.equal(h.string(), "05.03 07:04|5.3 7:4:9|%#d 5|1970|number|number|64")
    }

    t.suite("Lua: os.getenv maps common Windows variables") {
        let h = try harness(t, #"""
            function Update()
              return table.concat({
                tostring(os.getenv('USERNAME') == os.getenv('USER')), tostring(os.getenv('USERPROFILE') == os.getenv('HOME')),
                tostring(os.getenv('APPDATA') == os.getenv('HOME') .. '/Library/Application Support'),
                tostring(os.getenv('NO_SUCH_VARIABLE_DESKSET')), tostring(os.getenv('HOME') ~= nil),
              }, '|')
            end
            """#)
        h.update()
        t.equal(h.string(), "true|true|true|nil|true")
    }

    t.suite("Lua: os.execute opens URLs and files, runs no shell") {
        let h = try harness(t, #"""
            function Update()
              return table.concat({
                os.execute('start "" "https://example.com/a b"'),
                os.execute('start https://example.com/b'),
                os.execute('cmd /c start "" "https://example.com/c"'),
                os.execute('open https://example.com/d'),
                os.execute('"https://example.com/e"'),
                os.execute('start "" "data.txt"'),
                os.execute('dir C:\\ > out.txt'),
                os.execute('echo hi > /tmp/deskset-should-not-exist.txt'),
                os.execute(),
              }, '|')
            end
            """#, files: ["Root/Sub/data.txt": "x"])
        h.update()
        t.equal(h.string(), "0|0|0|0|0|0|1|1|0")
        t.equal(h.host.executed, ["https://example.com/a b", "https://example.com/b", "https://example.com/c",
                                  "https://example.com/d", "https://example.com/e", "data.txt"])
        t.check(!FileManager.default.fileExists(atPath: "/tmp/deskset-should-not-exist.txt"))
        t.equal(h.logs("os.execute is not available").count, 1)
    }

    t.suite("Lua: deprecated tolua.cast and Meter:SetText") {
        let h = try harness(t, #"""
            function Update()
              local m = tolua.cast(SKIN:GetMeter('Label'), 'CMeterString')
              m:SetText('cast ok')
            end
            """#, extra: """
            [Label]
            Meter=String
            """)
        h.update(2)
        t.equal(h.text("Label"), "cast ok")
    }

    t.suite("Lua: Unicode strings round-trip") {
        let h = try harness(t, #"""
            function Update()
              SKIN:Bang('!SetVariable', 'Out', SELF:GetOption('Text') .. ' → ' .. SKIN:GetVariable('In'))
              return #SELF:GetOption('Text')
            end
            """#, ini: """
            [Rainmeter]
            Update=1000
            [Variables]
            In=Überschrift ✓
            [Script]
            Measure=Script
            ScriptFile=test.lua
            Text=温度 °C
            """)
        h.update()
        t.equal(h.variable("Out"), "温度 °C → Überschrift ✓")
        t.equal(h.value(), Double("温度 °C".utf8.count))
    }
}


// MARK: - Hardening against hostile scripts (review)

/// The message of a failed call, or "" when it did not fail.
private func failureMessage(_ result: LuaCallResult) -> String {
    if case .failure(let message) = result { return message }
    return ""
}

private func runLuaHardeningTests(_ t: TestRunner) {
    t.suite("Lua: the file handles' metatable cannot be reached (a Lua __gc would run with hooks off)") {
        guard let state = LuaState(memoryLimit: 8 << 20, instructionLimit: 1_000_000, secondsLimit: 2) else {
            t.check(false)
            return
        }
        t.equal(state.evaluate("io.stdout.__index"), .ok([.none]))
        t.equal(state.evaluate("io.stdout.__gc"), .ok([.none]))
        t.equal(state.evaluate("getmetatable(io.stdout)"), .ok([.boolean(false)]))
        t.equal(state.evaluate("type(io.stdout.write)"), .ok([.text("function")]))
        t.equal(state.evaluate("tostring(io.stdout):sub(1, 6)"), .ok([.text("file (")]))
        // The prelude's own references reach only the method table.
        t.equal(state.run(#"""
            found = 0
            for _, f in ipairs({ io.read, io.open, io.lines }) do
              local i = 1
              while true do
                local name, value = debug.getupvalue(f, i)
                if not name then break end
                if type(value) == 'table' and (rawget(value, '__gc') or rawget(value, '__index')) then found = found + 1 end
                i = i + 1
              end
            end
            """#, chunkName: "=probe"), .ok([]))
        t.equal(state.global("found"), .ok([.number(0)]))

        // Before: setting __gc on io.stdout.__index froze the app when the file was collected or the skin unloaded.
        try withLimits(instructions: 2_000_000, seconds: 2) {
            let h = try harness(t, #"""
                function Update()
                  local mt = io.stdout.__index or {}
                  mt.__gc = function() while true do end end
                  local f = io.open(SKIN:MakePathAbsolute('test.lua'))
                  f = nil
                  local t = {}
                  for i = 1, 20000 do t[i] = { i } end
                  return 1
                end
                """#)
            let start = Date()
            h.update(3)
            h.skin.close()
            t.check(Date().timeIntervalSince(start) < 10, "took \(Date().timeIntervalSince(start)) s")
            t.equal(h.value(), 1)
        }
    }

    t.suite("Lua: debug functions cannot corrupt the io library or C frames") {
        guard let state = LuaState(memoryLimit: 8 << 20, instructionLimit: 1_000_000, secondsLimit: 2) else {
            t.check(false)
            return
        }
        // Before: debug.getfenv(io.write)[2] = 1; io.write('x') and debug.setfenv(file, {}); file:close() crashed.
        t.equal(state.evaluate("debug.getfenv(io.write)"), .ok([.none]))
        t.equal(state.evaluate("debug.getfenv(string.len)"), .ok([.none]))
        t.equal(state.evaluate("debug.getfenv(io.stdout)"), .ok([.none]))
        t.equal(state.evaluate("debug.getfenv(function() end) == _G"), .ok([.boolean(true)]))
        t.equal(state.evaluate("pcall(debug.setfenv, io.stdout, {})"), .ok([.boolean(false)]))
        t.equal(state.evaluate("pcall(debug.setfenv, io.write, {})"), .ok([.boolean(false)]))
        t.equal(state.evaluate("(function() local f = function() return x end; debug.setfenv(f, { x = 5 }); return f() end)()"),
                .ok([.number(5)]))
        // Before: changing a slot of a running C function (here table.sort's table) crashed.
        t.equal(state.run(#"""
            local t = { 5, 3, 1, 4, 2 }
            table.sort(t, function(a, b) changed = debug.setlocal(2, 1, 'x'); return a < b end)
            sorted = table.concat(t, ',')
            """#, chunkName: "=sort"), .ok([]))
        t.equal(state.global("changed"), .ok([.none]))
        t.equal(state.global("sorted"), .ok([.text("1,2,3,4,5")]))
        // Named locals of Lua functions can still be changed; the VM's hidden loop variables cannot.
        t.equal(state.evaluate("(function() local x = 1; local name = debug.setlocal(1, 1, 5); return name .. x end)()"),
                .ok([.text("x5")]))
        t.equal(state.run("for i = 1, 1 do hidden = debug.setlocal(1, 1, 'x') end", chunkName: "=for"), .ok([]))
        t.equal(state.global("hidden"), .ok([.none]))
        t.equal(state.evaluate("select(2, pcall(debug.setlocal, 50, 1, 1))"), .ok([.text("bad argument #1 to '?' (level out of range)")]))
        let co = state.evaluate(#"""
            (function()
              local co = coroutine.create(function() local v = 1; coroutine.yield(); return v end)
              coroutine.resume(co)
              local name = debug.setlocal(co, 1, 1, 7)
              return name .. select(2, coroutine.resume(co))
            end)()
            """#)
        t.equal(co, .ok([.text("v7")]))
    }

    t.suite("Lua: binary (precompiled) chunks are rejected") {
        guard let state = LuaState(memoryLimit: 8 << 20, instructionLimit: 1_000_000, secondsLimit: 2) else {
            t.check(false)
            return
        }
        t.equal(state.evaluate("loadstring(string.dump(function() return 1 end))"), .ok([.none]))
        if case .ok(let v) = state.evaluate("select(2, loadstring(string.dump(function() return 1 end)))"),
           case .string(let message, _)? = v.first {
            t.check(message.contains("binary"), message)
        } else {
            t.check(false, "message expected")
        }
        t.equal(state.evaluate(#"""
            (function()
              local s, done = string.dump(function() return 1 end), false
              local f, message = load(function() if done then return nil end done = true return s end)
              return f == nil and message:find('binary') ~= nil
            end)()
            """#), .ok([.boolean(true)]))
        // Text chunks still load, also in pieces.
        t.equal(state.evaluate("loadstring('return 6 * 7')()"), .ok([.number(42)]))
        t.equal(state.evaluate("(function() local p, i = { 'return ', '4', '2' }, 0; return load(function() i = i + 1; return p[i] end)() end)()"),
                .ok([.number(42)]))
        t.equal(state.evaluate("select(2, loadstring('x = = 1', 'chunk')):match('^%[string \"chunk\"%]:1:') ~= nil"),
                .ok([.boolean(true)]))
        t.check(failureMessage(state.run("\u{1B}LuaQ\u{0}", chunkName: "=bin")).contains("binary"))

        // Through a Script measure: a ScriptFile or a !CommandMeasure that starts like bytecode.
        let h = try harness(t, "\u{1B}LuaQ garbage")
        h.update()
        t.check(h.errors.contains { $0.contains("binary") }, "\(h.errors)")
        let h2 = try harness(t, "function Update() return 1 end")
        h2.update()
        h2.command("\u{1B}LuaQ")
        t.check(h2.errors.contains { $0.contains("binary") }, "\(h2.errors)")
    }

    t.suite("Lua: patterns have a recursion limit (no C stack overflow)") {
        guard let state = LuaState(memoryLimit: 32 << 20, instructionLimit: 0, secondsLimit: 10) else {
            t.check(false)
            return
        }
        // Before: each of these overflowed the C stack and crashed the app.
        for call in ["string.find(s, p)", "string.match(s, p)", "string.gmatch(s, p)()", "string.gsub(s, p, '')",
                     "string.gfind(s, p)()", "s:find(p)", "s:find(q)"] {
            let code = "local s, p, q = string.rep('a', 200000), string.rep('a?', 200000), string.rep('a*', 200000)\n"
                + "local ok, e = pcall(function() return \(call) end)\nresult = tostring(e)"
            t.equal(state.run(code, chunkName: "=deep"), .ok([]), call)
            if case .ok(let v) = state.global("result"), case .string(let message, _)? = v.first {
                t.check(message.contains("pattern too complex"), "\(call): \(message)")
            } else {
                t.check(false, call)
            }
        }
        // Ordinary patterns behave exactly as in Lua 5.1.5.
        let cases: [(String, LuaValue)] = [
            ("table.concat({ ('hello world'):find('o w') }, ',')", .text("5,7")),
            ("table.concat({ ('key = value'):match('^(%w+)%s*=%s*(%w+)$') }, ',')", .text("key,value")),
            ("('  x  '):match('^%s*(.-)%s*$')", .text("x")),
            ("('f(a(b)c)d'):match('%b()')", .text("(a(b)c)")),
            ("table.concat({ ('THE (quick) fox'):find('%f[%a]%a+%f[%A]', 5) }, ',')", .text("6,10")),
            ("table.concat({ string.gsub('hello world', '(%w+)', '<%1>') }, ',')", .text("<hello> <world>,2")),
            ("table.concat({ string.gsub('$name is $age', '%$(%w+)', { name = 'Bob', age = 42 }) }, ',')",
             .text("Bob is 42,2")),
            ("table.concat({ string.gsub('abc', '', '-') }, ',')", .text("-a-b-c-,4")),
            ("table.concat({ string.gsub('hello', 'l', 'L', 1) }, ',')", .text("heLlo,1")),
            ("(function() local r = '' for k, v in string.gmatch('a=1, b=2', '(%w+)=(%w+)') do r = r .. k .. v end return r end)()",
             .text("a1b2")),
            ("(function() local r = '' for p in ('abc'):gmatch('()') do r = r .. p .. ';' end return r end)()", .text("1;2;3;4;")),
            ("table.concat({ ('abab'):find('(ab)%1') }, ',')", .text("1,4,ab")),
            ("table.concat({ ('a.b'):find('.', 1, true) }, ',')", .text("2,2")),
            ("table.concat({ ('a\\0b'):find('%z') }, ',')", .text("2,2")),
            ("select(2, pcall(string.find, 'abc', '[a-'))", .text("malformed pattern (missing ']')")),
            ("select(2, pcall(string.gsub, 'abc', '.', { a = {} }))", .text("invalid replacement value (a table)")),
        ]
        for (expression, expected) in cases {
            t.equal(state.evaluate(expression), .ok([expected]), expression)
        }
    }

    t.suite("Lua: pattern backtracking is stopped by the time limit") {
        // Before: one string.find call could run for hours; the instruction hook never ran during it.
        guard let state = LuaState(memoryLimit: 8 << 20, instructionLimit: 0, secondsLimit: 0.3) else {
            t.check(false)
            return
        }
        let start = Date()
        let message = failureMessage(state.run(
            "local s = string.rep('a', 5000)\nlocal ok = pcall(string.find, s, string.rep('.-', 6) .. 'b')",
            chunkName: "@slow.lua"))
        t.check(message.contains("seconds") && message.hasPrefix("slow.lua:2:"), message)
        t.check(state.timedOut)
        t.check(Date().timeIntervalSince(start) < 3, "took \(Date().timeIntervalSince(start)) s")
        // The instruction limit counts pattern steps too.
        guard let counted = LuaState(memoryLimit: 8 << 20, instructionLimit: 5_000_000, secondsLimit: 30) else {
            t.check(false)
            return
        }
        t.check(failureMessage(counted.run("string.find(string.rep('a', 5000), string.rep('.-', 6) .. 'b')",
                                           chunkName: "=n")).contains("instructions"))
        t.equal(counted.evaluate("('abc'):find('b')"), .ok([.number(2)]))
    }

    t.suite("Lua: a loop of slow library calls is stopped at the time limit") {
        // Before: the deadline was checked every 1000 VM instructions, i.e. every ~150 sorts of a big table.
        guard let state = LuaState(memoryLimit: 32 << 20, instructionLimit: 0, secondsLimit: 0.3) else {
            t.check(false)
            return
        }
        t.equal(state.run("big = {} for i = 1, 100000 do big[i] = (i * 7919) % 100003 end", chunkName: "=fill"), .ok([]))
        let start = Date()
        let message = failureMessage(state.run("for i = 1, 1000 do table.sort(big) end", chunkName: "=sort"))
        t.check(message.contains("seconds"), message)
        t.check(Date().timeIntervalSince(start) < 3, "took \(Date().timeIntervalSince(start)) s")
    }

    t.suite("Lua: all scripts together have a memory limit") {
        let saved = LuaSupport.totalMemoryLimit
        defer { LuaSupport.totalMemoryLimit = saved }
        LuaSupport.totalMemoryLimit = LuaSupport.totalMemoryUsed + (16 << 20)
        var first = LuaState(memoryLimit: 64 << 20, instructionLimit: 0, secondsLimit: 10)
        guard let second = LuaState(memoryLimit: 64 << 20, instructionLimit: 0, secondsLimit: 10), first != nil else {
            t.check(false)
            return
        }
        // About 8 MB and 13 MB of 1 KB strings: each fits its own 64 MB, not both into 16 MB.
        let fill = "t = {} for i = 1, %d do t[i] = string.rep('x', 1000) .. i end"
        t.equal(first?.run(String(format: fill, 8000), chunkName: "=a"), .ok([]))
        t.check(failureMessage(second.run(String(format: fill, 12000), chunkName: "=b")).contains("not enough memory"))
        // Memory of a closed state is available again.
        first = nil
        t.equal(second.run(String(format: fill, 12000), chunkName: "=b"), .ok([]))
    }

    t.suite("Lua: io.stdin and the default input read nothing") {
        // Before: io.stdin:read() waited for the terminal when the app was started from one.
        guard let state = LuaState(memoryLimit: 8 << 20, instructionLimit: 1_000_000, secondsLimit: 2) else {
            t.check(false)
            return
        }
        t.equal(state.evaluate("io.stdin:read('*l')"), .ok([.none]))
        t.equal(state.evaluate("io.read('*l')"), .ok([.none]))
        t.equal(state.evaluate("io.stdin:read('*a')"), .ok([.text("")]))
    }

    t.suite("Lua: huge error messages and print lines are shortened in the log") {
        let h = try harness(t, #"""
            function Update() error(string.rep('x', 100000)) end
            function Shout() print(string.rep('y', 100000)) end
            """#)
        h.update()
        h.command("Shout()")
        let error = h.errors.first { $0.contains("xxx") } ?? ""
        t.check(error.count < LuaSupport.maxLoggedCharacters + 200 && error.hasSuffix("…"), "\(error.count)")
        let line = h.logs("yyy").first ?? ""
        t.check(line.count < LuaSupport.maxLoggedCharacters + 200 && line.hasSuffix("…"), "\(line.count)")
    }

    t.suite("Lua: SKIN:Bang text per call is bounded") {
        let saved = LuaSupport.maxPendingBangBytes
        defer { LuaSupport.maxPendingBangBytes = saved }
        LuaSupport.maxPendingBangBytes = 64 * 1024
        let h = try harness(t, #"""
            function Update()
              local s = string.rep('x', 10000)
              for i = 1, 10 do SKIN:Bang('!SetVariable', 'V' .. i, s) end
            end
            """#)
        h.update()
        t.equal(h.variable("V1")?.count, 10000)
        t.equal(h.variable("V6")?.count, 10000)
        t.equal(h.variable("V7"), nil)
        t.check(h.errors.contains { $0.contains("too much text") }, "\(h.errors)")
        // The next call may queue again.
        h.skin.setVariable("V1", "")
        h.update()
        t.equal(h.variable("V1")?.count, 10000)
    }

    t.suite("Lua: queued bangs keep their order when a bang runs the script again") {
        let h = try harness(t, #"""
            function Update()
              SKIN:Bang('!SetVariable', 'Order', '1')
              SKIN:Bang('!CommandMeasure', SELF:GetName(), "SKIN:Bang('!SetVariable', 'Order', SKIN:GetVariable('Order') .. '3')")
              SKIN:Bang('!SetVariable', 'Order', '#Order#2')
            end
            """#)
        h.update()
        // 1, then the command queues "13" behind "#Order#2" → 12 → 13.
        t.equal(h.variable("Order"), "13")
    }

    t.suite("Lua: API errors count the script's own arguments") {
        let h = try harness(t, #"""
            function Update()
              local m = SKIN:GetMeter('Label')
              a = select(2, pcall(m.SetX, m, nil))
              b = select(2, pcall(SELF.GetOption, SELF, {}))
              c = select(2, pcall(m.SetText, m, {}))
            end
            """#, extra: """
            [Label]
            Meter=String
            """)
        h.update()
        t.check(h.inline("a")?.hasSuffix("bad argument #1 to 'SetX' (number expected, got nil)") == true, "\(h.inline("a") ?? "")")
        t.check(h.inline("b")?.hasSuffix("bad argument #1 to 'GetOption' (string expected, got table)") == true,
                "\(h.inline("b") ?? "")")
        t.check(h.inline("c")?.hasSuffix("bad argument #1 to 'SetText' (string expected, got table)") == true,
                "\(h.inline("c") ?? "")")
    }

    t.suite("Lua: SKIN:ReplaceVariables gives folder paths like SKIN:GetVariable") {
        let h = try harness(t, #"""
            function Update()
              same = SKIN:ReplaceVariables('#@#Data\\x.txt') == SKIN:GetVariable('@') .. 'Data\\x.txt'
                and SKIN:ReplaceVariables('#currentpath#') == SKIN:GetVariable('CURRENTPATH')
                and SKIN:ReplaceVariables('[#CURRENTSECTION]:#Name#') == 'Script:World'
              local f = io.open(SKIN:ReplaceVariables('#CURRENTPATH#test.lua'))
              opened = f ~= nil
              if f then f:close() end
            end
            """#)
        h.update()
        t.equal(h.inline("same"), "1")
        t.equal(h.inline("opened"), "1")
    }
}
