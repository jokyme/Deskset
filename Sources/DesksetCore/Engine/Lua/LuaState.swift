import CLua
import Foundation

/// A value crossing the Swift / Lua boundary.
enum LuaValue: Equatable {
    case none
    case boolean(Bool)
    case number(Double)
    /// `numeric`: the number the string converts to by Lua's own rules (`"10"`, `" 0x1F "`, `"1e3"`), or nil.
    case string(String, numeric: Double?)
    /// Arguments only: a Lua expression, evaluated in the script's global environment.
    case expression(String)
    /// A table, function, userdata or thread (the Lua type name).
    case other(String)

    static func text(_ s: String) -> LuaValue { .string(s, numeric: nil) }

    /// Lua's type name, for error messages.
    var typeName: String {
        switch self {
        case .none: return "nil"
        case .boolean: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .expression: return "expression"
        case .other(let name): return name
        }
    }

    /// `tostring`-like text: numbers in Lua's `%.14g` format, booleans as `true` / `false`.
    var luaText: String? {
        switch self {
        case .number(let n): return LuaState.format(n)
        case .string(let s, _): return s
        case .boolean(let b): return b ? "true" : "false"
        default: return nil
        }
    }
}

/// Result of one call into Lua.
enum LuaCallResult: Equatable {
    case ok([LuaValue])
    /// `call`: the global is not a function.
    case missing
    case failure(String)
}

/// An error a host function raises in Lua (the message gets the script's `file:line:` prepended).
struct LuaHostError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// One Lua 5.1 state (through the C shim `deskset_lua`): the libraries, the prelude, limits, and the calls the
/// Script measure makes. Not thread-safe; used on the thread that updates the skin.
///
/// Swift never calls a Lua function that can raise an error: every operation runs protected inside the shim,
/// and host functions (`hostHandler`) return values or throw `LuaHostError`, which the shim turns into a Lua
/// error after Swift has returned.
final class LuaState {
    /// Called for every `host(op, ...)` call of the prelude. Runs on the calling thread, possibly re-entrantly
    /// (a host function may resolve inline Lua on the same state).
    var hostHandler: (([LuaValue]) throws -> [LuaValue])?

    private var handle: OpaquePointer?
    /// Values (and their string bytes) returned by the last host call, kept alive until the shim has pushed them.
    private var hostResults: UnsafeMutablePointer<deskset_value>?
    private var hostResultStrings: [UnsafeMutableRawPointer] = []

    /// Opens a state; nil when out of memory. `openFailure` tells whether the libraries and the prelude loaded.
    init?(memoryLimit: Int, instructionLimit: UInt64, secondsLimit: Double) {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        deskset_lua_set_total_memory_limit(max(LuaSupport.totalMemoryLimit, 0))
        let prelude = Array(LuaPrelude.source.utf8)
        let opened: OpaquePointer? = prelude.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { code in
                deskset_lua_open(max(memoryLimit, 0), luaHostCallback, context, code, buffer.count,
                                LuaPrelude.chunkName)
            }
        }
        guard let opened else { return nil }
        handle = opened
        deskset_lua_set_limits(opened, instructionLimit, secondsLimit)
    }

    deinit {
        if let handle {
            deskset_lua_detach(handle)
            deskset_lua_close(handle)
        }
        releaseHostResults()
    }

    /// Nil when the state opened correctly, otherwise why it did not.
    var openFailure: String? {
        guard let handle else { return "no Lua state" }
        return deskset_lua_status(handle) == Int32(DESKSET_OK) ? nil : String(cString: deskset_lua_error_message(handle))
    }

    /// True when the last outermost call was stopped by the instruction or time limit.
    var timedOut: Bool { handle.map { deskset_lua_timed_out($0) != 0 } ?? false }
    var memoryUsed: Int { handle.map { Int(deskset_lua_memory_used($0)) } ?? 0 }
    /// Calls currently running on this state.
    var depth: Int { handle.map { Int(deskset_lua_depth($0)) } ?? 0 }

    // MARK: Calls

    /// Runs `code` as a chunk (`chunkName`: `@file` for a file, `=name` for other text).
    func run(_ code: String, chunkName: String) -> LuaCallResult {
        guard let handle else { return .failure("no Lua state") }
        var bytes = Array(code.utf8)
        bytes.append(0)
        let status = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                deskset_lua_run(handle, $0, buffer.count - 1, chunkName)
            }
        }
        return result(status)
    }

    /// Calls the global function `name`; `.missing` when it is not a function.
    func call(_ name: String, _ args: [LuaValue] = []) -> LuaCallResult {
        guard let handle else { return .failure("no Lua state") }
        let status = withCValues(args) { pointer, count in deskset_lua_call(handle, name, pointer, count) }
        return result(status)
    }

    /// The value of the global variable `name`.
    func global(_ name: String) -> LuaCallResult {
        guard let handle else { return .failure("no Lua state") }
        return result(deskset_lua_get_global(handle, name))
    }

    /// Evaluates the Lua expression.
    func evaluate(_ expression: String) -> LuaCallResult {
        guard let handle else { return .failure("no Lua state") }
        let bytes = Array(expression.utf8)
        let status = bytes.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return deskset_lua_eval(handle, "", 0) }
            return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                deskset_lua_eval(handle, $0, buffer.count)
            }
        }
        return result(status)
    }

    /// Calls a function of the prelude's internal table.
    func callInternal(_ name: String, _ args: [LuaValue] = []) -> LuaCallResult {
        guard let handle else { return .failure("no Lua state") }
        let status = withCValues(args) { pointer, count in deskset_lua_call_internal(handle, name, pointer, count) }
        return result(status)
    }

    private func result(_ status: Int32) -> LuaCallResult {
        guard let handle else { return .failure("no Lua state") }
        switch Int(status) {
        case Int(DESKSET_OK):
            let count = Int(deskset_lua_result_count(handle))
            return .ok((0..<count).map { LuaState.value(deskset_lua_result(handle, Int32($0))) })
        case Int(DESKSET_MISSING):
            return .missing
        default:
            return .failure(String(cString: deskset_lua_error_message(handle)))
        }
    }

    // MARK: Value conversion

    /// Lua's number format (`%.14g`, like `tostring`).
    static func format(_ number: Double) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        _ = deskset_lua_format_number(number, &buffer, buffer.count)
        return String(cString: buffer)
    }

    /// Text of Lua string bytes: UTF-8 (what Lua uses for text in Rainmeter); bytes that are not valid UTF-8 (e.g.
    /// read from an ANSI file) are read as Windows-1252 instead of being replaced.
    static func text(_ pointer: UnsafePointer<CChar>?, _ length: Int) -> String {
        guard let pointer, length > 0 else { return "" }
        let data = Data(UnsafeRawBufferPointer(start: pointer, count: length))
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    static func value(_ v: deskset_value) -> LuaValue {
        switch Int(v.kind) {
        case Int(DESKSET_BOOLEAN): return .boolean(v.boolean != 0)
        case Int(DESKSET_NUMBER): return .number(v.number)
        case Int(DESKSET_STRING): return .string(text(v.string, v.length), numeric: v.numeric != 0 ? v.number : nil)
        case Int(DESKSET_OTHER): return .other(text(v.string, v.length))
        default: return .none
        }
    }

    /// Converts `values` to C values whose strings live until `body` returns.
    private func withCValues<R>(_ values: [LuaValue], _ body: (UnsafePointer<deskset_value>?, Int32) -> R) -> R {
        if values.isEmpty { return body(nil, 0) }
        var strings: [UnsafeMutableRawPointer] = []
        defer { strings.forEach { free($0) } }
        let converted = values.map { LuaState.cValue($0, keeping: &strings) }
        return converted.withUnsafeBufferPointer { body($0.baseAddress, Int32($0.count)) }
    }

    /// C value for `value`; string bytes are malloc'ed and appended to `strings` (the caller frees them).
    private static func cValue(_ value: LuaValue, keeping strings: inout [UnsafeMutableRawPointer]) -> deskset_value {
        var v = deskset_value()
        func store(_ s: String) {
            let bytes = Array(s.utf8)
            let memory = malloc(max(bytes.count, 1))!
            bytes.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            strings.append(memory)
            v.string = UnsafePointer(memory.assumingMemoryBound(to: CChar.self))
            v.length = bytes.count
        }
        switch value {
        case .none:
            v.kind = Int32(DESKSET_NIL)
        case .boolean(let b):
            v.kind = Int32(DESKSET_BOOLEAN)
            v.boolean = b ? 1 : 0
        case .number(let n):
            v.kind = Int32(DESKSET_NUMBER)
            v.number = n
        case .string(let s, _):
            v.kind = Int32(DESKSET_STRING)
            store(s)
        case .expression(let e):
            v.kind = Int32(DESKSET_EXPRESSION)
            store(e)
        case .other:
            v.kind = Int32(DESKSET_NIL)
        }
        return v
    }

    // MARK: Host callback

    fileprivate func handleHostCall(_ args: UnsafePointer<deskset_value>?, _ count: Int32,
                                    _ results: UnsafeMutablePointer<UnsafePointer<deskset_value>?>?,
                                    _ resultCount: UnsafeMutablePointer<Int32>?) -> Int32 {
        var values: [LuaValue] = []
        if let args, count > 0 {
            values.reserveCapacity(Int(count))
            for i in 0..<Int(count) { values.append(LuaState.value(args[i])) }
        }
        var output: [LuaValue]
        var status = Int32(DESKSET_OK)
        if let hostHandler {
            do {
                output = try hostHandler(values)
            } catch let error as LuaHostError {
                output = [.text(error.message)]
                status = Int32(DESKSET_ERROR)
            } catch {
                output = [.text("\(error)")]
                status = Int32(DESKSET_ERROR)
            }
        } else {
            output = [.text("the script is not attached to a skin")]
            status = Int32(DESKSET_ERROR)
        }
        // Stored only now: a nested host call made while computing `output` has already been pushed by the shim.
        releaseHostResults()
        var strings: [UnsafeMutableRawPointer] = []
        let buffer = UnsafeMutablePointer<deskset_value>.allocate(capacity: max(output.count, 1))
        for (i, value) in output.enumerated() {
            buffer.advanced(by: i).initialize(to: LuaState.cValue(value, keeping: &strings))
        }
        hostResults = buffer
        hostResultStrings = strings
        results?.pointee = UnsafePointer(buffer)
        resultCount?.pointee = Int32(output.count)
        return status
    }

    private func releaseHostResults() {
        hostResultStrings.forEach { free($0) }
        hostResultStrings = []
        hostResults?.deallocate()
        hostResults = nil
    }
}

private let luaHostCallback: deskset_host_fn = { context, args, count, results, resultCount in
    guard let context else { return Int32(DESKSET_ERROR) }
    let state = Unmanaged<LuaState>.fromOpaque(context).takeUnretainedValue()
    return state.handleHostCall(args, count, results, resultCount)
}
