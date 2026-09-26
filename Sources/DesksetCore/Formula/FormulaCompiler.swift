import Foundation

/// Stack-machine instruction. Formulas are compiled once into a flat instruction list, so evaluation is a
/// loop (no recursion, even for `1+1+1+…` with thousands of terms) with no heap allocation.
enum FormulaInstruction: Equatable {
    case push(Double)
    /// Push `lookup(names[index])`.
    case load(Int)
    case unary(FormulaUnary)
    case binary(FormulaBinary)
    case clamp
    /// Pop; jump to the absolute index when the value is false (0 or NaN).
    case jumpIfFalse(Int)
    case jump(Int)
}

struct FormulaProgram {
    var code: ContiguousArray<FormulaInstruction>
    /// Identifiers resolved through `lookup`, in order of first appearance (first spelling wins).
    var names: [String]
    var stackSize: Int
}

/// Built-in functions (case-insensitive) and their arities, from the "Functions" list of the manual.
private enum BuiltinFunction {
    case unary(FormulaUnary)
    case binary(FormulaBinary)
    case minMax(FormulaBinary)   // Min/Max: 2 arguments in the manual; more are accepted and folded pairwise.
    case clamp
    case round                   // Round(x) or Round(x, precision)

    static let table: [String: BuiltinFunction] = [
        "cos": .unary(.cos), "sin": .unary(.sin), "tan": .unary(.tan),
        "acos": .unary(.acos), "asin": .unary(.asin), "atan": .unary(.atan),
        "atan2": .binary(.atan2),
        "rad": .unary(.rad), "deg": .unary(.deg),
        "abs": .unary(.abs), "neg": .unary(.neg), "exp": .unary(.exp),
        "log": .unary(.log), "ln": .unary(.ln), "sqrt": .unary(.sqrt), "sgn": .unary(.sgn),
        "frac": .unary(.frac), "trunc": .unary(.trunc), "floor": .unary(.floor), "ceil": .unary(.ceil),
        "min": .minMax(.min), "max": .minMax(.max),
        "clamp": .clamp,
        "round": .round,
    ]
}

/// Built-in constants (case-insensitive). These take precedence over lookup names.
private let builtinConstants: [String: Double] = ["pi": Double.pi, "e": M_E]

/// Shunting-yard parser that emits `FormulaInstruction`s directly. It is fully iterative (an explicit
/// operator stack, no recursion), so no input — `((((…))))`, `------1`, `2**2**…`, long `?:` chains — can
/// overflow the thread stack, whatever the nesting depth. (A recursive-descent version used ~800 KB of stack
/// in debug builds for ~130 levels, too much for a 512 KB GCD worker thread.)
///
/// Precedence, lowest to highest (the manual gives no table; C/Python-like choices):
///
///     ?:            conditional, right-associative (`a ? b : c ? d : e`, `a ? b ? c : d : e`)
///     ||            logical OR
///     &&            logical AND
///     =  <>         equality (`==` accepted as `=`)
///     <  >  <=  >=  relational
///     |             bitwise OR
///     ^             bitwise XOR
///     &             bitwise AND
///     +  -          additive
///     *  /  %       multiplicative
///     -  +  ~       unary prefix (so `5+-1` = 4, as the version history requires)
///     **            power, right-associative, binds tighter than a unary minus on its left:
///                   `-2**2 = -4`, `2**-1 = 0.5`, `2**3**2 = 512`
///
/// All binary operators except `**` are left-associative. The manual says operands of `&&`/`||` "must" be
/// parenthesised; we don't require it — with this table `a = 5 || a = 10` means `(a = 5) || (a = 10)`, and
/// parenthesised formulas behave identically. `&&`/`||` evaluate both sides (no short-circuit); only the
/// chosen branch of `?:` is evaluated. The manual's limit of 30 nested conditionals is not enforced (deeper
/// nesting simply works).
struct FormulaCompiler {
    private enum StackItem {
        case binary(FormulaBinary, precedence: Int)
        case unary(FormulaUnary)
        case paren
        case function(BuiltinFunction, name: String, argc: Int)
        /// `?` seen: the conditional's `jumpIfFalse` is at `jumpIfFalse`; `base` is the value-stack depth
        /// before either branch.
        case question(jumpIfFalse: Int, base: Int)
        /// `:` seen: the true branch ends with the `jump` at `jump`.
        case colon(jump: Int)
    }

    private static let unaryPrecedence = 10
    private static let powerPrecedence = 11

    private let tokens: [FormulaToken]
    private var ops: [StackItem] = []
    private var code = ContiguousArray<FormulaInstruction>()
    private var names: [String] = []
    private var nameIndex: [String: Int] = [:]
    private var depth = 0
    private var maxDepth = 0
    /// Instructions before this index may not take part in constant folding (they precede a jump target).
    private var foldBarrier = 0

    private init(tokens: [FormulaToken]) {
        self.tokens = tokens
    }

    static func compile(_ source: String) throws -> FormulaProgram {
        var c = FormulaCompiler(tokens: try FormulaLexer.tokenize(source))
        try c.run()
        return FormulaProgram(code: c.code, names: c.names, stackSize: max(c.maxDepth, 1))
    }

    // MARK: - Main loop

    private mutating func run() throws {
        if case .end = tokens[0].kind { throw FormulaError("empty formula") }
        var expectOperand = true
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            switch token.kind {
            case .number(let v):
                guard expectOperand else { throw unexpected(token) }
                emitPush(v)
                expectOperand = false

            case .identifier(let name):
                guard expectOperand else { throw unexpected(token) }
                let key = name.lowercased()
                if case .leftParen = tokens[i + 1].kind {
                    guard let fn = BuiltinFunction.table[key] else {
                        throw FormulaError("unknown function '\(name)' at position \(token.offset)")
                    }
                    i += 1 // consume "("
                    if case .rightParen = tokens[i + 1].kind { throw FormulaError("\(name)() needs arguments") }
                    ops.append(.function(fn, name: name, argc: 0))
                    // still expecting an operand (the first argument)
                } else if let c = builtinConstants[key] {
                    emitPush(c)
                    expectOperand = false
                } else {
                    // Anything else — including a function name used without parentheses — is a lookup name.
                    let index: Int
                    if let existing = nameIndex[key] {
                        index = existing
                    } else {
                        index = names.count
                        names.append(name)
                        nameIndex[key] = index
                    }
                    emit(.load(index), stackEffect: 1)
                    expectOperand = false
                }

            case .leftParen:
                guard expectOperand else { throw unexpected(token) }
                ops.append(.paren)

            case .rightParen:
                guard !expectOperand else { throw unexpected(token) }
                try reduceToMarker(at: token)
                guard let top = ops.popLast() else { throw unexpected(token) } // unbalanced ")"
                switch top {
                case .paren:
                    break
                case .function(let fn, let name, let argc):
                    try finishCall(fn, name: name, argc: argc + 1)
                default:
                    throw unexpected(token)
                }

            case .comma:
                guard !expectOperand else { throw unexpected(token) }
                try reduceToMarker(at: token)
                guard case .function(let fn, let name, let argc)? = ops.last else { throw unexpected(token) }
                ops[ops.count - 1] = .function(fn, name: name, argc: argc + 1)
                if case .minMax(let op) = fn, argc + 1 >= 2 { emitBinary(op) }
                expectOperand = true

            case .op(let o):
                if expectOperand {
                    switch o {
                    case .minus: ops.append(.unary(.negate))
                    case .tilde: ops.append(.unary(.bitNot))
                    case .plus: break // unary plus is a no-op
                    default: throw unexpected(token)
                    }
                } else {
                    guard let (precedence, op) = FormulaCompiler.binaryInfo(o) else { throw unexpected(token) }
                    let rightAssociative = op == .power
                    while let top = ops.last {
                        let topPrecedence: Int
                        switch top {
                        case .binary(_, let p): topPrecedence = p
                        case .unary: topPrecedence = FormulaCompiler.unaryPrecedence
                        default: topPrecedence = -1 // markers stop the scan
                        }
                        guard topPrecedence > precedence || (topPrecedence == precedence && !rightAssociative) else { break }
                        popAndEmitOperator()
                    }
                    ops.append(.binary(op, precedence: precedence))
                    expectOperand = true
                }

            case .question:
                guard !expectOperand else { throw unexpected(token) }
                // Close every operator of the condition; stop at any marker (an enclosing `:` stays open:
                // `a ? b : c ? d : e` nests the second conditional inside the first one's false branch).
                while let top = ops.last, isOperator(top) { popAndEmitOperator() }
                let jf = code.count
                emit(.jumpIfFalse(0), stackEffect: -1)
                ops.append(.question(jumpIfFalse: jf, base: depth))
                expectOperand = true

            case .colon:
                guard !expectOperand else { throw unexpected(token) }
                while let top = ops.last, isOperator(top) { popAndEmitOperator() }
                // Conditionals nested in this true branch (`a ? b ? c : d : e`) end here.
                while case .colon(let j)? = ops.last { ops.removeLast(); closeConditional(jump: j) }
                guard case .question(let jf, let base)? = ops.last else { throw unexpected(token) }
                let jump = code.count
                emit(.jump(0), stackEffect: 0)
                code[jf] = .jumpIfFalse(code.count)
                foldBarrier = code.count
                depth = base
                ops[ops.count - 1] = .colon(jump: jump)
                expectOperand = true

            case .end:
                guard !expectOperand else { throw unexpected(token) }
                while let top = ops.popLast() {
                    switch top {
                    case .binary(let op, _):
                        emitBinary(op)
                    case .unary(let op):
                        emitUnary(op)
                    case .colon(let j):
                        closeConditional(jump: j)
                    case .question:
                        throw FormulaError("'?' without ':'")
                    case .paren, .function:
                        throw FormulaError("missing ')'")
                    }
                }
            }
            i += 1
        }
    }

    // MARK: - Helpers

    private func unexpected(_ t: FormulaToken) -> FormulaError {
        let what: String
        switch t.kind {
        case .end: what = "end of formula"
        case .number(let v): what = "number \(v)"
        case .identifier(let s): what = "'\(s)'"
        case .op(let o): what = "operator \(o)"
        case .question: what = "'?'"
        case .colon: what = "':'"
        case .leftParen: what = "'('"
        case .rightParen: what = "')'"
        case .comma: what = "','"
        }
        return FormulaError("unexpected \(what) at position \(t.offset)")
    }

    private func isOperator(_ item: StackItem) -> Bool {
        switch item {
        case .binary, .unary: return true
        default: return false
        }
    }

    /// Binary operators; nil for `~`, which is only valid in operand position.
    private static func binaryInfo(_ op: FormulaOperator) -> (precedence: Int, op: FormulaBinary)? {
        switch op {
        case .logicalOr: return (1, .logicalOr)
        case .logicalAnd: return (2, .logicalAnd)
        case .equal: return (3, .equal)
        case .notEqual: return (3, .notEqual)
        case .less: return (4, .less)
        case .greater: return (4, .greater)
        case .lessEqual: return (4, .lessEqual)
        case .greaterEqual: return (4, .greaterEqual)
        case .bitOr: return (5, .bitOr)
        case .bitXor: return (6, .bitXor)
        case .bitAnd: return (7, .bitAnd)
        case .plus: return (8, .add)
        case .minus: return (8, .subtract)
        case .star: return (9, .multiply)
        case .slash: return (9, .divide)
        case .percent: return (9, .remainder)
        case .power: return (powerPrecedence, .power)
        case .tilde: return nil
        }
    }

    /// Pops operators until the innermost `(` / function marker, closing finished conditionals on the way.
    private mutating func reduceToMarker(at token: FormulaToken) throws {
        while let top = ops.last {
            switch top {
            case .binary, .unary:
                popAndEmitOperator()
            case .colon(let j):
                ops.removeLast()
                closeConditional(jump: j)
            case .question:
                throw FormulaError("'?' without ':' before position \(token.offset)")
            case .paren, .function:
                return
            }
        }
    }

    private mutating func popAndEmitOperator() {
        guard let top = ops.popLast() else { return }
        switch top {
        case .binary(let op, _): emitBinary(op)
        case .unary(let op): emitUnary(op)
        default: ops.append(top) // not an operator; callers never do this
        }
    }

    private mutating func closeConditional(jump: Int) {
        code[jump] = .jump(code.count)
        foldBarrier = code.count
    }

    private mutating func finishCall(_ fn: BuiltinFunction, name: String, argc: Int) throws {
        func arity(_ ok: Bool, _ expected: String) throws {
            if !ok { throw FormulaError("\(name) takes \(expected), got \(argc)") }
        }
        switch fn {
        case .unary(let op):
            try arity(argc == 1, "1 argument")
            emitUnary(op)
        case .binary(let op):
            try arity(argc == 2, "2 arguments")
            emitBinary(op)
        case .minMax(let op):
            try arity(argc >= 2, "2 arguments")
            emitBinary(op) // combines the last argument with the running result
        case .clamp:
            try arity(argc == 3, "3 arguments")
            emitClamp()
        case .round:
            try arity(argc == 1 || argc == 2, "1 or 2 arguments")
            if argc == 1 { emitUnary(.round) } else { emitBinary(.round) }
        }
    }

    // MARK: - Emission (with constant folding)

    private mutating func emit(_ ins: FormulaInstruction, stackEffect: Int) {
        code.append(ins)
        depth += stackEffect
        if depth > maxDepth { maxDepth = depth }
    }

    private mutating func emitPush(_ v: Double) { emit(.push(v), stackEffect: 1) }

    /// Constant operand `k` places from the end, if it may be folded.
    private func constant(fromEnd k: Int) -> Double? {
        let i = code.count - k
        guard i >= foldBarrier, i >= 0, case .push(let v) = code[i] else { return nil }
        return v
    }

    private mutating func emitUnary(_ op: FormulaUnary) {
        if let x = constant(fromEnd: 1) {
            code[code.count - 1] = .push(FormulaMath.apply(op, x))
        } else {
            emit(.unary(op), stackEffect: 0)
        }
    }

    private mutating func emitBinary(_ op: FormulaBinary) {
        if let b = constant(fromEnd: 1), let a = constant(fromEnd: 2) {
            code.removeLast()
            code[code.count - 1] = .push(FormulaMath.apply(op, a, b))
            depth -= 1
        } else {
            emit(.binary(op), stackEffect: -1)
        }
    }

    private mutating func emitClamp() {
        if let h = constant(fromEnd: 1), let l = constant(fromEnd: 2), let x = constant(fromEnd: 3) {
            code.removeLast(2)
            code[code.count - 1] = .push(FormulaMath.clamp(x, l, h))
            depth -= 2
        } else {
            emit(.clamp, stackEffect: -2)
        }
    }
}

/// Runs a compiled program. Memory-safe even if the compiler's stack accounting were wrong: every push and
/// pop is bounds-checked and reported as an error instead of trapping.
enum FormulaVM {
    static func run(_ p: FormulaProgram, lookup: (String) -> Double?) throws -> Double {
        let code = p.code
        return try withUnsafeTemporaryAllocation(of: Double.self, capacity: p.stackSize) { stack in
            let cap = stack.count
            var sp = 0
            var pc = 0
            let n = code.count
            let corrupt = FormulaError("internal error: formula stack mismatch")
            while pc < n {
                switch code[pc] {
                case .push(let v):
                    guard sp < cap else { throw corrupt }
                    stack[sp] = v
                    sp += 1
                case .load(let i):
                    guard sp < cap, i < p.names.count else { throw corrupt }
                    let name = p.names[i]
                    guard let v = lookup(name) else { throw FormulaError("unknown name '\(name)'") }
                    stack[sp] = v
                    sp += 1
                case .unary(let op):
                    guard sp >= 1 else { throw corrupt }
                    stack[sp - 1] = FormulaMath.apply(op, stack[sp - 1])
                case .binary(let op):
                    guard sp >= 2 else { throw corrupt }
                    stack[sp - 2] = FormulaMath.apply(op, stack[sp - 2], stack[sp - 1])
                    sp -= 1
                case .clamp:
                    guard sp >= 3 else { throw corrupt }
                    stack[sp - 3] = FormulaMath.clamp(stack[sp - 3], stack[sp - 2], stack[sp - 1])
                    sp -= 2
                case .jumpIfFalse(let target):
                    guard sp >= 1 else { throw corrupt }
                    sp -= 1
                    if !FormulaMath.truthy(stack[sp]) {
                        guard target > pc else { throw corrupt }
                        pc = target
                        continue
                    }
                case .jump(let target):
                    guard target > pc else { throw corrupt }
                    pc = target
                    continue
                }
                pc += 1
            }
            guard sp == 1 else { throw corrupt }
            return stack[0]
        }
    }
}
