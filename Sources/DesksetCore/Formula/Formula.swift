import Foundation

// Formula engine — clean-room implementation of docs.rainmeter.net/manual/formulas/ (plus the "Additional
// Formula Syntax" of /manual/measures/calc/ and the formula notes of /manual/skins/option-types/).
// Syntax, precedence and every judgment call are documented in FormulaCompiler.swift, FormulaLexer.swift,
// FormulaMath.swift and NumericLiteral.swift.

public struct FormulaError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A formula parsed once and evaluated many times (Calc measures run every update).
///
/// Immutable after `init`, so one instance can be evaluated from any thread.
public final class CompiledFormula {
    public let source: String

    /// Names the formula resolves through `lookup` (everything that is not a number, a built-in function or
    /// the constants `PI` / `E`), without duplicates, in order of first appearance and first spelling
    /// (duplicates are detected case-insensitively). In a Calc measure these are measure names, plus the
    /// Calc-only `Random` and `Counter`, which the caller must also answer (case-insensitively).
    public let identifiers: [String]

    /// True when the formula needs no lookups; `evaluate` then returns a precomputed value.
    public var isConstant: Bool { constantValue != nil }

    private let program: FormulaProgram
    private let constantValue: Double?

    /// Throws on syntax errors (and on an empty formula).
    public init(_ source: String) throws {
        self.source = source
        var program = try FormulaCompiler.compile(source)
        if program.names.isEmpty {
            // Everything is pure, so a formula without lookups is folded to a single value up front.
            let v = FormulaMath.finite(try FormulaVM.run(program, lookup: { _ in nil }))
            program = FormulaProgram(code: [.push(v)], names: [], stackSize: 1)
            constantValue = v
        } else {
            constantValue = nil
        }
        self.program = program
        self.identifiers = program.names
    }

    /// Evaluates the formula. `lookup` resolves identifiers that are not built-in functions/constants
    /// (in Calc measures: other measures' number values), case-insensitively; returning nil makes it an error.
    /// Division by zero and similar domain problems follow the manual (never crash).
    ///
    /// `lookup` receives the name exactly as spelled in the formula; matching case-insensitively is the
    /// caller's job. It is called once per occurrence that is actually evaluated (only the chosen branch of
    /// `?:` runs). The result is always finite: `x/0` and `x%0` are 0, a NaN/±∞ result becomes 0, and a -0
    /// result becomes +0 (so it never displays as "-0").
    public func evaluate(_ lookup: (String) -> Double? = { _ in nil }) throws -> Double {
        if let c = constantValue { return c }
        return FormulaMath.finite(try FormulaVM.run(program, lookup: lookup))
    }

    /// Convenience: resolves identifiers from a dictionary whose keys are compared case-insensitively.
    public func evaluate(variables: [String: Double]) throws -> Double {
        if let c = constantValue { return c }
        var lowered: [String: Double] = [:]
        for (k, v) in variables { lowered[k.lowercased()] = v }
        return try evaluate { lowered[$0.lowercased()] }
    }
}

extension CompiledFormula: @unchecked Sendable {}

public enum Formula {
    /// One-shot compile + evaluate. Compiled formulas are cached by source text, so calling this every update
    /// with the same formula does not re-parse it.
    public static func evaluate(_ source: String, lookup: (String) -> Double? = { _ in nil }) throws -> Double {
        try compile(source).evaluate(lookup)
    }

    /// Compiles `source`, reusing a cached `CompiledFormula` for the same text (the cache is bounded and
    /// thread-safe). Syntax errors are cached too.
    public static func compile(_ source: String) throws -> CompiledFormula {
        try compiledCache.value(for: source) {
            Result { try CompiledFormula(source) }.mapError { $0 as? FormulaError ?? FormulaError("\($0)") }
        }.get()
    }

    /// Reads a numeric option value: a plain number (`10`, `-3.5`, …) or a formula wrapped in parentheses
    /// (`(#A# * 2)` after variable substitution). Returns nil when the value is neither (callers then use the default).
    ///
    /// Rules (manual: "Number options require either a number or a formula"; "formulas must be entirely
    /// enclosed in (parentheses)"). Where the manual is silent:
    /// - Surrounding whitespace is ignored.
    /// - A value starting with `(` is evaluated as a formula. If the whole value is not a valid formula
    ///   (e.g. `(5+5) junk`), the first balanced `( … )` group is used, like a plain number's prefix below.
    ///   `(1)+(2)` is accepted as a whole (= 3).
    /// - Otherwise the value is read strtod-style: optional sign, then the longest numeric literal prefix;
    ///   trailing text is ignored (`12px` → 12, `12 ;comment` → 12). No digits → nil. `.5`, `1e3`, `0x1F`
    ///   are accepted; `inf`/`nan` are not.
    /// - Formulas here have no names to look up (outside Calc/IfCondition, measures must be written as
    ///   `[Measure]` section variables, which are substituted beforehand), so a leftover name → nil.
    /// - The result is always finite (NaN/±∞ → nil for plain numbers, → 0 for formulas, see `evaluate`) and
    ///   never -0.
    public static func number(_ optionValue: String) -> Double? {
        number(trimmed: OptionText.trim(optionValue))
    }

    /// `number` for an already-trimmed value.
    static func number(trimmed: Substring) -> Double? {
        guard let first = trimmed.utf8.first else { return nil }
        if first == 0x28 { // "("
            return numberCache.value(for: String(trimmed)) { formulaNumber(trimmed) }
        }
        guard let r = NumericLiteral.signedPrefix(trimmed.utf8), r.value.isFinite else { return nil }
        return r.value == 0 ? 0 : r.value // "-0" → +0, like formula results (see FormulaMath.finite)
    }

    private static func formulaNumber(_ t: Substring) -> Double? {
        if let v = try? CompiledFormula(String(t)).evaluate() { return v }
        guard let end = OptionText.matchingParenEnd(t, open: t.startIndex), end < t.endIndex else { return nil }
        return try? CompiledFormula(String(t[t.startIndex..<end])).evaluate()
    }

    private static let compiledCache = BoundedCache<Result<CompiledFormula, FormulaError>>(limit: 1024)
    private static let numberCache = BoundedCache<Double?>(limit: 2048)
}

/// A small thread-safe memo table. When full it is simply cleared: formulas whose text keeps changing
/// (dynamic values substituted in) must not grow memory without bound, and re-parsing is cheap.
final class BoundedCache<Value> {
    private var storage: [String: Value] = [:]
    private let lock = NSLock()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func value(for key: String, compute: () -> Value) -> Value {
        lock.lock()
        if let v = storage[key] {
            lock.unlock()
            return v
        }
        lock.unlock()
        let v = compute()
        lock.lock()
        if storage.count >= limit { storage.removeAll(keepingCapacity: true) }
        storage[key] = v
        lock.unlock()
        return v
    }
}

extension BoundedCache: @unchecked Sendable {}
