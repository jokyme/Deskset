import Foundation

/// `Measure=Script`: runs a Lua 5.1 script (manual: /manual/measures/script/, /manual/lua-scripting/ and
/// /manual/lua-scripting/inline-lua/). Each Script measure has its own Lua state ("Global variables are not
/// shared between instances").
///
/// Lifecycle:
/// - Skin load / refresh: `ScriptFile` is read (UTF-8 with or without BOM, UTF-16, or ANSI — decoded like .ini
///   files) and its main chunk runs, so globals set outside functions exist during the "initialization phase"
///   (inline Lua page). Deprecated `PROPERTIES` tables are then filled from the measure's options.
/// - `Initialize()` runs once "during the first update cycle of the skin", at this measure's turn in the first
///   update — "even if the script measure is disabled" — or earlier when a `!CommandMeasure` reaches the script
///   first. When `!SetOption` changes `ScriptFile`, the new script is loaded and its `Initialize()` runs at once.
/// - `Update()` runs whenever the measure updates (Disabled, Paused, UpdateDivider and the measure bangs work as
///   for any measure). Its return values set the measure's values: a number → the number (formatted by meters
///   with NumOfDecimals / AutoScale…), a string → the string (number value = the string converted, else 0), both
///   in any order → both; nothing / nil → 0 and "". On an error the values are reset to 0 and "" (history:
///   "the value of the Script measure is … reset when an error occurs"). The deprecated global `GetStringValue()`
///   / `GetValue()` functions supply the values when `Update()` returns none.
/// - `!CommandMeasure Script "Lua code"` runs the code in the script's global environment.
/// - Inline Lua `[&Script:Function(args)]` / `[&Script:variable]` (`SectionVariableFunctions`).
///
/// `SKIN:Bang()` bangs run "when control is returned from the script": they are queued and executed, in order,
/// after the outermost Lua call of this script returns (after `Update()`'s values are set). Bangs queued before
/// `Initialize()` has run (by the main chunk or inline Lua while the skin loads) wait until then.
///
/// Errors are logged with the script's `file:line:` like Rainmeter's log (each distinct message once); runaway
/// scripts are stopped by the limits in `LuaSupport` and never crash or hang the app.
public final class ScriptMeasure: Measure, SectionVariableFunctions {
    private enum Phase { case created, awaitingInitialize, running }
    private enum PendingAction {
        case action(String)
        case bang(Bang)
        /// `SKIN:FadeWindow(from, to)`, alpha 0…255.
        case fadeWindow(from: Int, to: Int)
    }

    private var phase = Phase.created
    private(set) var lua: LuaState?
    /// `ScriptFile` as last read (resolved); nil before the first read.
    private var scriptFileOption: String?
    /// Absolute path of the loaded script ("" when none).
    private(set) var scriptPath = ""
    /// Name used in chunk names and messages: the path relative to the Skins folder.
    private var scriptDisplayName = ""
    private var pendingActions: [PendingAction] = []
    /// Index of the next action to run in `pendingActions` (a queue drained from the front).
    private var pendingHead = 0
    /// UTF-8 bytes of the queued bang text (bounded by `LuaSupport.maxPendingBangBytes`).
    private var pendingBytes = 0
    private var droppedBangs = false
    private var callDepth = 0
    private var reloadPending = false
    /// Stopped after repeated limit hits (until the skin is refreshed).
    private(set) var suspended = false
    /// Calls in a row stopped by a limit, per entry point (`Update`, `Initialize`, `!CommandMeasure`, each inline
    /// function…), so successful calls elsewhere do not hide an `Update()` that never finishes.
    private var consecutiveTimeouts: [String: Int] = [:]
    /// `Update()`'s last number before AverageSize / InvertMeasure (returned again while suspended).
    private var lastNumber = 0.0
    private var reportedMessages: Set<String> = []
    private var printWindowStart = -1.0
    private var printsInWindow = 0
    private var printThrottled = false
    private var loggedExecute = false

    static let maxReportedMessages = 100

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
        // "the value of all measures will be set to an initial numeric value of 0, and if applicable, a string
        // value of ''".
        rawString = ""
    }

    deinit {
        lua?.hostHandler = nil
    }

    /// Scripts cannot know their range: like Calc, Net and WebParser (manual, Measures → Percentage), the range
    /// follows the values seen unless MinValue / MaxValue are set.
    override var tracksValueRange: Bool { true }

    // MARK: Options and loading

    public override func readOptions() {
        // The first read after the skin has loaded is this measure's turn in the first update cycle.
        if phase == .awaitingInitialize { runInitialize() }
        super.readOptions()
        // Read even while disabled: Initialize, !CommandMeasure and inline Lua work on disabled script measures.
        let file = string("ScriptFile").trimmingCharacters(in: .whitespaces)
        if file != scriptFileOption {
            scriptFileOption = file
            if callDepth > 0 { reloadPending = true } else { loadScript() }
        }
        // Come back for Initialize at the first update, even when disabled / paused / not dynamic.
        if phase == .awaitingInitialize { needsOptionRead = true }
    }

    private func loadScript() {
        reloadPending = false
        closeScript()
        let initializeNow = phase != .created
        phase = initializeNow ? .running : .awaitingInitialize
        guard let file = scriptFileOption, !file.isEmpty else {
            report("ScriptFile is not set", level: .warning)
            return
        }
        let path = resolvedPath(file)
        scriptPath = path
        scriptDisplayName = displayName(ofPath: path)
        guard let source = readScriptSource(atPath: path) else {
            report("cannot open script file \(path)", level: .error)
            skin.addIssue("Script file \(scriptDisplayName) of [\(name)] not found")
            return
        }
        guard let state = LuaState(memoryLimit: LuaSupport.memoryLimit, instructionLimit: LuaSupport.instructionLimit,
                                   secondsLimit: LuaSupport.secondsLimit) else {
            report("not enough memory to start Lua", level: .error)
            return
        }
        if let failure = state.openFailure {
            report("Lua could not start: \(failure)", level: .error)
            return
        }
        state.hostHandler = { [weak self] args in
            guard let self else { throw LuaHostError("the script measure no longer exists") }
            return try self.host(args)
        }
        lua = state
        if case .failure(let message) = invoke("start", flush: false, { state.callInternal("start", [.text(name)]) }) {
            report(message, level: .error)
        }
        if case .failure(let message) = invoke("chunk", flush: false, {
            state.run(source, chunkName: "@" + scriptDisplayName)
        }) {
            report(message, level: .error)
        }
        if case .failure(let message) = invoke("properties", flush: false, {
            state.callInternal("properties", [.text(name)])
        }) {
            report(message, level: .error)
        }
        if initializeNow { runInitialize() }
    }

    private func closeScript() {
        lua?.hostHandler = nil
        lua = nil
        suspended = false
        consecutiveTimeouts = [:]
    }

    private func runInitialize() {
        phase = .running
        guard let lua, !suspended else {
            flushPendingActions()
            return
        }
        if case .failure(let message) = invoke("Initialize", { lua.call("Initialize") }) { report(message, level: .error) }
    }

    /// Absolute path of `ScriptFile` (relative to the skin folder, `\` → `/`).
    private func resolvedPath(_ file: String) -> String {
        let path = skin.absolutePath(file)
        if FileManager.default.fileExists(atPath: path) { return path }
        return IncludePaths.caseInsensitiveLookup(path) ?? path
    }

    func displayName(ofPath path: String) -> String {
        for root in [skin.skinsDirectory.path, (skin.skinsDirectory.path as NSString).standardizingPath,
                     skin.skinsDirectory.resolvingSymlinksInPath().path] {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return (path as NSString).lastPathComponent
    }

    /// Script text of a file: decoded like skin files (UTF-8 / UTF-16 with or without BOM, ANSI), BOM removed, a
    /// first line starting with `#` blanked (as `luaL_loadfile` skips it). Nil for missing, non-regular or huge
    /// files.
    func readScriptSource(atPath path: String) -> String? {
        var p = path
        if !FileManager.default.fileExists(atPath: p), let found = IncludePaths.caseInsensitiveLookup(p) { p = found }
        guard IncludePaths.isRegularFile(p) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int ?? 0
        guard size <= LuaSupport.maxScriptFileSize, let data = FileManager.default.contents(atPath: p) else { return nil }
        var text = TextDecoding.decode(data)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.hasPrefix("#") {
            let end = text.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) ?? text.endIndex
            text.replaceSubrange(text.startIndex..<end, with: "")
        }
        return text
    }

    // MARK: Update

    public override func computeValue() -> Double {
        if phase == .awaitingInitialize { runInitialize() }
        if suspended { return lastNumber }
        guard let lua else {
            rawString = ""
            return 0
        }
        var values: [LuaValue] = []
        var failed = false
        switch invoke("Update", flush: false, { lua.call("Update") }) {
        case .ok(let v): values = v
        case .missing: break
        case .failure(let message):
            report(message, level: .error)
            failed = true
        }
        if !failed && values.allSatisfy({ $0 == .none }) { values = deprecatedValues(lua) }
        let result = failed ? (number: 0.0, text: "") : ScriptMeasure.interpret(values)
        rawString = result.text
        lastNumber = result.number.isFinite ? result.number : 0
        value = lastNumber
        if callDepth == 0 { finishOutermostCall() }
        return lastNumber
    }

    /// Old scripts provided the values with global `GetStringValue()` / `GetValue()` functions (deprecated, still
    /// supported per the manual). Errors in them are only logged at debug level.
    private func deprecatedValues(_ lua: LuaState) -> [LuaValue] {
        var values: [LuaValue] = []
        for function in ["GetValue", "GetStringValue"] {
            switch invoke(function, flush: false, { lua.call(function) }) {
            case .ok(let v): if let first = v.first, first != .none { values.append(first) }
            case .missing: break
            case .failure(let message): report(message, level: .debug)
            }
        }
        return values
    }

    /// Measure values from `Update()`'s return values (the first two; "Order of values doesn't matter").
    /// `text` nil means "no string value": meters format the number.
    static func interpret(_ values: [LuaValue]) -> (number: Double, text: String?) {
        var number: Double?
        var text: String?
        var textNumber: Double?
        for v in values.prefix(2) {
            switch v {
            case .number(let n):
                if number == nil { number = n }
            case .boolean(let b):
                if number == nil { number = b ? 1 : 0 }
            case .string(let s, let numeric):
                if text == nil {
                    text = s
                    textNumber = numeric
                }
            default:
                break
            }
        }
        if let number { return (number, text) }
        if let text { return (textNumber ?? 0, text) }
        return (0, "")
    }

    // MARK: !CommandMeasure

    /// `!CommandMeasure Script "Lua code"`: "Multiple statements may be separated by semicolons (;). All statements
    /// are global."
    public override func execute(command: String) {
        if phase == .awaitingInitialize { runInitialize() }
        let code = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        guard let lua, !suspended else {
            report("!CommandMeasure: the script is not running", level: .warning)
            return
        }
        if case .failure(let message) = invoke("!CommandMeasure", { lua.run(code, chunkName: "=!CommandMeasure") }) {
            report(message, level: .error)
        }
    }

    // MARK: Inline Lua

    public func sectionVariableFunction(_ call: String) -> String? {
        guard let lua, !suspended else { return nil }
        guard let request = InlineLuaCall.parse(call, formula: { [unowned self] text in
            try? Formula.evaluate(text, lookup: { self.skin.formulaValue(of: $0, from: self) })
        }) else { return nil }
        // Before Initialize() the manual expects "single initial error messages" (nil globals): debug level.
        let level: SkinLogLevel = phase == .running ? .error : .debug
        let result: LuaCallResult
        switch request {
        case .variable(let variable): result = invoke("inline " + variable) { lua.global(variable) }
        case .call(let function, let args): result = invoke("inline " + function) { lua.call(function, args) }
        case .expression(let expression): result = invoke("inline") { lua.evaluate(expression) }
        }
        switch result {
        case .ok(let values):
            let first = values.first ?? .none
            if first == .none { report("inline Lua [&\(name):\(call)] returned nil", level: level) }
            guard let text = InlineLuaCall.text(first) else {
                report("inline Lua [&\(name):\(call)] returned a \(first.typeName); only numbers, strings and booleans "
                       + "can be used", level: level)
                return nil
            }
            return text
        case .missing:
            if case .call(let function, _) = request {
                report("inline Lua [&\(name):\(call)]: '\(function)' is not a function in \(scriptDisplayName)",
                       level: level)
            }
            return nil
        case .failure(let message):
            report(message, level: level)
            return nil
        }
    }

    // MARK: Calls and bangs

    /// Runs one call into Lua (`entry` names it for the limit bookkeeping); after the outermost call: the limit
    /// bookkeeping, queued bangs (when `flush`), and a ScriptFile change that arrived during the call.
    @discardableResult
    private func invoke(_ entry: String, flush: Bool = true, _ body: () -> LuaCallResult) -> LuaCallResult {
        callDepth += 1
        let result = withExtendedLifetime(self) { body() }
        callDepth -= 1
        if callDepth == 0 {
            if let lua {
                if lua.timedOut {
                    let count = (consecutiveTimeouts[entry] ?? 0) + 1
                    consecutiveTimeouts[entry] = count
                    if count >= LuaSupport.maxConsecutiveTimeouts && !suspended {
                        suspended = true
                        skin.log("[\(name)] Script: stopped after \(count) calls of \(entry) in a row hit the time or "
                                 + "instruction limit; refresh the skin to run it again", level: .error)
                        skin.addIssue("Script [\(name)] was stopped (endless loop?)")
                    }
                } else if consecutiveTimeouts[entry] != nil {
                    consecutiveTimeouts[entry] = nil
                }
            }
            if flush { finishOutermostCall() }
        }
        return result
    }

    private func finishOutermostCall() {
        if phase == .running { flushPendingActions() }
        if reloadPending && callDepth == 0 { loadScript() }
    }

    private func enqueue(_ action: PendingAction) {
        let bytes: Int
        switch action {
        case .action(let text): bytes = text.utf8.count
        case .bang(let bang): bytes = bang.args.reduce(bang.name.utf8.count) { $0 + $1.utf8.count }
        case .fadeWindow: bytes = 16
        }
        guard pendingActions.count - pendingHead < LuaSupport.maxPendingBangs,
              pendingBytes + bytes <= LuaSupport.maxPendingBangBytes else {
            if !droppedBangs {
                droppedBangs = true
                skin.log("[\(name)] Script: too many SKIN:Bang() calls (or too much text) in one call; the rest were "
                         + "dropped", level: .error)
            }
            return
        }
        pendingBytes += bytes
        pendingActions.append(action)
    }

    /// Executes the queued bangs in order (a bang may run Lua again, which queues and flushes more; a nested flush
    /// continues with the same queue, so the order stays first in, first out).
    private func flushPendingActions() {
        while pendingHead < pendingActions.count {
            let action = pendingActions[pendingHead]
            pendingHead += 1
            if pendingHead == pendingActions.count {
                // Drained: the queue starts again from an empty array (bangs run below may queue more).
                pendingActions.removeAll()
                pendingHead = 0
                pendingBytes = 0
            }
            switch action {
            case .action(let text):
                skin.execute(text, from: self)
            case .bang(let bang):
                if bang.args.contains(where: { $0.contains("\"\"\"") }) {
                    // Not expressible in action syntax: performed directly, arguments resolved here.
                    let args = bang.args.map { skin.resolve($0, in: self, sectionVariables: true) }
                    skin.perform(Bang(name: bang.name, args: args), from: self)
                } else {
                    skin.execute(actionText(bang), from: self)
                }
            case .fadeWindow(let from, let to):
                // The host animates the window; one that cannot gets the end value as !SetTransparency.
                if skin.host?.skin(skin, fadeWindowFrom: from, to: to) != true {
                    skin.perform(Bang(name: "settransparency", args: [String(to)]), from: self)
                }
            }
        }
        droppedBangs = false
    }

    /// `[!Name "arg" …]` for a bang whose arguments were given separately. Each argument stays one argument and is
    /// resolved when the action runs, like the arguments of any action (variables, section variables, formulas for
    /// `!SetVariable`…). An argument containing `"` is resolved now and passed in magic quotes (literally).
    /// Going through `Skin.execute` keeps the engine's limits on actions that trigger themselves.
    func actionText(_ bang: Bang) -> String {
        var text = "[!" + bang.name
        for arg in bang.args {
            if arg.contains("\"") {
                text += " \"\"\"" + skin.resolve(arg, in: self, sectionVariables: true) + "\"\"\""
            } else {
                text += " \"" + arg + "\""
            }
        }
        return text + "]"
    }

    // MARK: Logging

    /// Logs a script message once per distinct text (a failing `Update()` would otherwise log on every update).
    /// Long messages (a script can raise an error with a huge string) are shortened.
    func report(_ fullMessage: String, level: SkinLogLevel) {
        let message = ScriptMeasure.shortened(fullMessage)
        guard reportedMessages.count <= ScriptMeasure.maxReportedMessages else { return }
        guard reportedMessages.insert(message).inserted else { return }
        if reportedMessages.count > ScriptMeasure.maxReportedMessages {
            skin.log("[\(name)] Script: too many different errors; no more are logged", level: .warning)
            return
        }
        skin.log("[\(name)] Script: \(message)", level: level)
    }

    /// `print()`: to the skin log, at most `LuaSupport.maxPrintsPerSecond` lines per second.
    private func printLine(_ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if printWindowStart < 0 || now - printWindowStart >= 1 {
            printWindowStart = now
            printsInWindow = 0
        }
        printsInWindow += 1
        if printsInWindow > LuaSupport.maxPrintsPerSecond {
            if !printThrottled {
                printThrottled = true
                skin.log("[\(name)] print: more than \(LuaSupport.maxPrintsPerSecond) lines per second; lines are "
                         + "dropped", level: .warning)
            }
            return
        }
        skin.log("[\(name)] \(ScriptMeasure.shortened(text))", level: .notice)
    }

    /// `text`, cut to `LuaSupport.maxLoggedCharacters` characters (with "…").
    static func shortened(_ text: String) -> String {
        let limit = LuaSupport.maxLoggedCharacters
        // utf8.count bounds the character count from above and is O(1) for native strings.
        guard text.utf8.count > limit, let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex),
              end < text.endIndex else { return text }
        return String(text[..<end]) + "…"
    }

    // MARK: Host functions (the prelude's `host(op, ...)`)

    private struct Arguments {
        let values: [LuaValue]
        let function: String
        /// Leading values the prelude adds (section kind, name…): error messages count the script's own arguments.
        var hidden = 0

        subscript(_ i: Int) -> LuaValue { i < values.count ? values[i] : .none }

        func string(_ i: Int) throws -> String {
            switch self[i] {
            case .string(let s, _): return s
            case .number(let n): return LuaState.format(n)
            default:
                throw LuaHostError("bad argument #\(i + 1 - hidden) to '\(function)' (string expected, got \(self[i].typeName))")
            }
        }

        func number(_ i: Int) throws -> Double {
            switch self[i] {
            case .number(let n): return n
            case .string(_, let numeric?): return numeric
            default:
                throw LuaHostError("bad argument #\(i + 1 - hidden) to '\(function)' (number expected, got \(self[i].typeName))")
            }
        }

        func bool(_ i: Int) -> Bool {
            switch self[i] {
            case .none: return false
            case .boolean(let b): return b
            default: return true
            }
        }
    }

    private func host(_ raw: [LuaValue]) throws -> [LuaValue] {
        guard case .number(let code)? = raw.first, let op = LuaHostOp(rawValue: Int(code)) else {
            throw LuaHostError("invalid call")
        }
        let values = Array(raw.dropFirst())
        func args(_ function: String, hidden: Int = 0) -> Arguments {
            Arguments(values: values, function: function, hidden: hidden)
        }
        switch op {
        case .getMeasure:
            let a = args("GetMeasure")
            return [measure(named: try a.string(0)).map { .text($0.name) } ?? .none]
        case .getMeter:
            let a = args("GetMeter")
            return [skin.meter(named: try a.string(0)).map { .text($0.name) } ?? .none]
        case .getVariable:
            let key = try args("GetVariable").string(0).trimmingCharacters(in: .whitespaces)
            let lower = key.lowercased()
            if lower == "currentsection" { return [.text(name)] }
            guard let v = skin.variable(key) else { return [.none] }
            return [.text(ScriptMeasure.pathVariables.contains(lower) ? ScriptMeasure.windowsPath(v) : v)]
        case .skinGeometry:
            let frame = skin.currentEnvironment().windowFrame
            switch try args("GetX").string(0) {
            case "x": return [.number(frame.x)]
            case "y": return [.number(frame.y)]
            case "w": return [.number(skin.width)]
            default: return [.number(skin.height)]
            }
        case .moveWindow:
            let a = args("MoveWindow")
            let x = try a.number(0), y = try a.number(1)
            enqueue(.bang(Bang(name: "move", args: [ScriptMeasure.integerText(x), ScriptMeasure.integerText(y)])))
            return []
        case .fadeWindow:
            // Queued like SKIN:Bang() so it keeps its place among the script's bangs (see `flushPendingActions`).
            let a = args("FadeWindow")
            let from = Int(try a.number(0).clamped(0, 255).rounded(.towardZero))
            let to = Int(try a.number(1).clamped(0, 255).rounded(.towardZero))
            enqueue(.fadeWindow(from: from, to: to))
            return []
        case .bang:
            try queueBang(values)
            return []
        case .makePathAbsolute:
            return [.text(ScriptMeasure.windowsPath(absolutePath(try args("MakePathAbsolute").string(0))))]
        case .replaceVariables:
            let text = windowsPathVariables(in: try args("ReplaceVariables").string(0))
            return [.text(skin.resolve(text, in: self, sectionVariables: true))]
        case .parseFormula:
            return [parseFormula(try args("ParseFormula").string(0)).map { .number($0) } ?? .none]
        case .getOption:
            let a = args("GetOption", hidden: 2)
            let section = try self.section(kind: try a.number(0), name: try a.string(1))
            guard let raw = section.rawOption(try a.string(2)) else { return [.none] }
            return [.text(skin.resolve(raw, in: section, sectionVariables: a.bool(3)))]
        case .getNumberOption:
            let a = args("GetNumberOption", hidden: 2)
            let section = try self.section(kind: try a.number(0), name: try a.string(1))
            guard let raw = section.rawOption(try a.string(2)) else { return [.none] }
            let resolved = skin.resolve(raw, in: section, sectionVariables: true)
            return [OptionValue.number(resolved).map { .number($0) } ?? .none]
        case .measureValue:
            let a = args("GetValue")
            guard let m = measure(named: try a.string(0)) else { throw LuaHostError("measure no longer exists") }
            switch try a.string(1) {
            case "string": return [.text(m.stringValue)]
            case "relative": return [.number(m.relativeValue)]
            case "range": return [.number(m.maxValue - m.minValue)]
            case "min": return [.number(m.minValue)]
            case "max": return [.number(m.maxValue)]
            default: return [.number(m.value)]
            }
        case .measureEnable:
            let a = args("Enable")
            guard let m = measure(named: try a.string(0)) else { throw LuaHostError("measure no longer exists") }
            m.setDisabled(!a.bool(1))
            return []
        case .meterGeometry:
            let a = args("GetX")
            guard let m = skin.meter(named: try a.string(0)) else { throw LuaHostError("meter no longer exists") }
            return [.number(meterGeometry(m, try a.string(1), absolute: a.bool(2)))]
        case .meterSet:
            let a = args("SetX")
            guard let m = skin.meter(named: try a.string(0)) else { throw LuaHostError("meter no longer exists") }
            let which = try a.string(1)
            setMeterGeometry(m, which, try args("Set" + which.uppercased(), hidden: 2).number(2))
            return []
        case .meterVisible:
            let a = args("Show")
            guard let m = skin.meter(named: try a.string(0)) else { throw LuaHostError("meter no longer exists") }
            let visible = a.bool(1)
            m.setHidden(!visible)
            if !visible {
                m.frame.width = 0
                m.frame.height = 0
            }
            return []
        case .meterSetText:
            let a = args("SetText", hidden: 1)
            guard let m = skin.meter(named: try a.string(0)) else { throw LuaHostError("meter no longer exists") }
            m.overrides["text"] = a[1] == .none ? "" : try a.string(1)
            m.needsOptionRead = true
            return []
        case .print:
            printLine(try args("print").string(0))
            return []
        case .readScript:
            let path = fixPath(try args("dofile").string(0))
            guard let source = readScriptSource(atPath: path) else { return [.none, .text("cannot open \(path)")] }
            return [.text(source), .text("@" + displayName(ofPath: path))]
        case .fixPath:
            return [.text(fixPath(try args("open").string(0)))]
        case .execute:
            return [.number(osExecute(try args("execute").string(0)))]
        }
    }

    /// The measure named `name` (this script itself included, even before the skin knows it).
    private func measure(named name: String) -> Measure? {
        if name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(self.name) == .orderedSame { return self }
        return skin.measure(named: name)
    }

    private func section(kind: Double, name: String) throws -> SkinSection {
        if Int(kind) == LuaSectionKind.meter.rawValue {
            guard let m = skin.meter(named: name) else { throw LuaHostError("meter [\(name)] no longer exists") }
            return m
        }
        guard let m = measure(named: name) else { throw LuaHostError("measure [\(name)] no longer exists") }
        return m
    }

    static func integerText(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        return String(Int(v.rounded(.towardZero).clamped(-1e9, 1e9)))
    }

    /// `SKIN:Bang()`: one string is an action (`'!Refresh'`, `'[!A][!B]'`, `'"https://…"'`); several strings are one
    /// bang and its arguments, each passed whole (`'!SetOption', 'Meter', 'Text', 'a b'`).
    private func queueBang(_ values: [LuaValue]) throws {
        guard !values.isEmpty else { throw LuaHostError("bad argument #1 to 'Bang' (string expected, got no value)") }
        var parts: [String] = []
        for (i, v) in values.enumerated() {
            switch v {
            case .string(let s, _): parts.append(s)
            case .number(let n): parts.append(LuaState.format(n))
            case .boolean(let b): parts.append(b ? "1" : "0")
            case .none: parts.append("")
            default: throw LuaHostError("bad argument #\(i + 1) to 'Bang' (string expected, got \(v.typeName))")
            }
        }
        let first = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if parts.count == 1 {
            guard !first.isEmpty else { return }
            enqueue(.action(first.hasPrefix("[") || first.hasPrefix("!") ? first : "[\(first)]"))
            return
        }
        let head = first.hasPrefix("!") ? first : "!" + first
        if case .bang(let bang)? = ActionParser.parse("[\(head)]").first {
            enqueue(.bang(Bang(name: bang.name, args: bang.args + parts.dropFirst())))
        } else {
            let quotedArgs = parts.dropFirst().map { "\"\($0)\"" }.joined(separator: " ")
            enqueue(.action("[\(first) \(quotedArgs)]"))
        }
    }

    /// Built-in variables holding folder paths (their values end with a separator).
    static let pathVariables: Set<String> = [
        "@", "currentpath", "rootconfigpath", "skinspath", "settingspath", "programpath", "addonspath", "pluginspath",
    ]

    /// `#@#`, `#CURRENTPATH#`… in text given to `SKIN:ReplaceVariables()` become the same Windows-style path
    /// `SKIN:GetVariable()` returns, so both ways of reading a folder variable agree.
    func windowsPathVariables(in text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "#")) else { return text }
        var result = text
        for name in ScriptMeasure.pathVariables {
            let token = "#" + name + "#"
            guard result.range(of: token, options: .caseInsensitive) != nil, let value = skin.variable(name) else {
                continue
            }
            result = result.replacingOccurrences(of: token, with: ScriptMeasure.windowsPath(value),
                                                 options: .caseInsensitive)
        }
        return result
    }

    /// Paths handed to scripts use Windows separators, as in Rainmeter: scripts split them with patterns such as
    /// `path:match('([^\\]-)%.([^%.]+)$')`. Every path a script gives back (io, dofile, bangs, options) accepts
    /// either separator.
    static func windowsPath(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "\\")
    }

    /// `SKIN:MakePathAbsolute()`: relative to the skin folder; `\` becomes `/`; a trailing separator is kept.
    func absolutePath(_ raw: String) -> String {
        let p = raw.replacingOccurrences(of: "\\", with: "/")
        let trimmed = p.trimmingCharacters(in: .whitespaces)
        var result = skin.absolutePath(p)
        if (trimmed.isEmpty || trimmed.hasSuffix("/")) && !result.hasSuffix("/") { result += "/" }
        return result
    }

    /// Paths given to io.open, io.lines, io.input, io.output, os.remove, os.rename, dofile and loadfile: Windows
    /// separators converted, relative paths resolved against the skin folder, an existing file found
    /// case-insensitively.
    func fixPath(_ raw: String) -> String {
        let path = absolutePath(raw)
        if path.hasSuffix("/") || FileManager.default.fileExists(atPath: path) { return path }
        return IncludePaths.caseInsensitiveLookup(path) ?? path
    }

    /// `SKIN:ParseFormula()`: a number or a formula ("formulas in Rainmeter must be entirely enclosed in
    /// (parentheses)"; plain numbers are allowed since the history notes). Variables are replaced first; measure
    /// names may be used. Nil when the text is not a valid formula.
    private func parseFormula(_ raw: String) -> Double? {
        let text = skin.resolve(raw, in: self, sectionVariables: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let n = try? Formula.evaluate(text, lookup: { self.skin.formulaValue(of: $0, from: self) }),
              n.isFinite else { return nil }
        return n
    }

    /// Meter:GetX()/GetY(): relative to the meter's container (the skin for most meters); with `absolute` the
    /// position in the skin. GetW()/GetH(): the real size (padding included, 0 when hidden). Before the first update
    /// has laid the meters out (main chunk, Initialize(), first Update()) the skin lays them out provisionally from
    /// their options (`Skin.ensureMeterGeometry`).
    private func meterGeometry(_ m: Meter, _ which: String, absolute: Bool) -> Double {
        skin.ensureMeterGeometry()
        let f = m.frame
        switch which {
        case "x": return absolute ? f.x : f.x - (m.container?.frame.x ?? 0)
        case "y": return absolute ? f.y : f.y - (m.container?.frame.y ?? 0)
        case "w": return f.width
        default: return f.height
        }
    }

    /// Meter:SetX/SetY/SetW/SetH(): like `!SetOption Meter X value` (so later layouts keep it), and the meter's
    /// frame is moved / resized at once so Get* calls in the same script see the new value.
    private func setMeterGeometry(_ m: Meter, _ which: String, _ v: Double) {
        guard v.isFinite else { return }
        // Move / resize a laid-out frame (a provisional layout later would redo it from the options anyway).
        skin.ensureMeterGeometry()
        let text = NumberFormatting.plain(v, maxDecimals: 10)
        switch which {
        case "x":
            m.overrides["x"] = text
            m.xPosition = PositionValue(value: v)
            if !m.hidden {
                m.frame.x = (m.container?.frame.x ?? 0) + v + m.anchorOffset(width: m.frame.width, height: m.frame.height).dx
            }
        case "y":
            m.overrides["y"] = text
            m.yPosition = PositionValue(value: v)
            if !m.hidden {
                m.frame.y = (m.container?.frame.y ?? 0) + v + m.anchorOffset(width: m.frame.width, height: m.frame.height).dy
            }
        case "w":
            let w = v.clamped(0, 1e7)
            m.overrides["w"] = NumberFormatting.plain(w, maxDecimals: 10)
            m.widthOption = w
            if !m.hidden { m.frame.width = w + m.padding.left + m.padding.right }
        default:
            let h = v.clamped(0, 1e7)
            m.overrides["h"] = NumberFormatting.plain(h, maxDecimals: 10)
            m.heightOption = h
            if !m.hidden { m.frame.height = h + m.padding.top + m.padding.bottom }
        }
        m.needsOptionRead = true
    }

    /// `os.execute`: macOS has no Windows command interpreter, and a shell command could block the skin. Commands
    /// that open something — `start ["title"] target [args]`, `open target`, or a bare URL / existing file — open
    /// it like a `["target"]` action (status 0); anything else is not run (status 1, logged once).
    private func osExecute(_ command: String) -> Double {
        var tokens = ScriptMeasure.commandTokens(command)
        if let first = tokens.first?.text.lowercased(), first == "cmd" || first == "cmd.exe" {
            tokens.removeFirst()
            if let flag = tokens.first?.text.lowercased(), flag == "/c" || flag == "/k" { tokens.removeFirst() }
        }
        if let first = tokens.first, !first.quoted, ["start", "open"].contains(first.text.lowercased()) {
            let isStart = first.text.lowercased() == "start"
            tokens.removeFirst()
            // `start "title" target`: the first quoted argument is the window title.
            if isStart, tokens.count > 1, tokens[0].quoted { tokens.removeFirst() }
            // Windows `start /b /min …` flags.
            while isStart, let t = tokens.first, !t.quoted, t.text.hasPrefix("/"), t.text.count <= 9,
                  !t.text.dropFirst().contains("/") {
                tokens.removeFirst()
            }
        }
        if let target = tokens.first?.text, !target.isEmpty, isOpenable(target) {
            skin.host?.skin(skin, execute: target, arguments: tokens.dropFirst().map(\.text))
            return 0
        }
        if !loggedExecute {
            loggedExecute = true
            report("os.execute is not available on macOS: \(command)", level: .warning)
        }
        return 1
    }

    private func isOpenable(_ target: String) -> Bool {
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1 { return true }
        return FileManager.default.fileExists(atPath: fixPath(target))
    }

    /// Whitespace-separated tokens; `"quoted text"` is one token.
    static func commandTokens(_ command: String) -> [(text: String, quoted: Bool)] {
        var tokens: [(String, Bool)] = []
        var current = ""
        var inQuotes = false
        var wasQuoted = false
        for c in command {
            if c == "\"" {
                if inQuotes {
                    inQuotes = false
                } else {
                    inQuotes = true
                    wasQuoted = true
                }
            } else if c.isWhitespace && !inQuotes {
                if !current.isEmpty || wasQuoted { tokens.append((current, wasQuoted)) }
                current = ""
                wasQuoted = false
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty || wasQuoted { tokens.append((current, wasQuoted)) }
        return tokens
    }
}
