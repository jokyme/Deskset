import Foundation

// Operators (§2.9, §4.3, §4.4): logic, equality, ordering and the unit algebra of arithmetic. A plain number literal
// next to a value with a dimension adopts it (§4.5) — except for time, temperature, frequency, speed, rainfall and
// pressure, where it must say its unit (DK4011). Values settled by use record the other side as a use.

extension Checker {
    func inferBinary(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let binary = BinaryExprSyntax(unchecked: node)
        let op = binary.operator
        let leftNode = binary.left.node, rightNode = binary.right.node
        var inner = context
        inner.display = false
        inner.param = nil
        switch op.kind {
        case .andKeyword, .orKeyword, .ampAmp, .pipePipe:
            let l = inferValue(leftNode, inner, expected: .bool)
            let r = inferValue(rightNode, inner, expected: .bool)
            requireBool(l, leftNode)
            requireBool(r, rightNode)
            var v = Val(.bool)
            v.deps = l.deps.union(r.deps)
            v.isConstant = l.isConstant && r.isConstant
            if l.error || r.error { v.error = l.error && r.error }
            return v
        case .equalEqual, .bangEqual, .equal:
            return inferComparison(leftNode, rightNode, node, inner, ordering: false)
        case .less, .lessEqual, .greater, .greaterEqual:
            return inferComparison(leftNode, rightNode, node, inner, ordering: true)
        case .plus, .minus, .star, .slash, .percent:
            return inferArithmetic(op, leftNode, rightNode, node, inner, expected: expected)
        case .amp, .pipe, .caret:
            let l = inferValue(leftNode, inner, expected: nil)
            let r = inferValue(rightNode, inner, expected: nil)
            if l.error || r.error { return .error }
            if l.isNumber && r.isNumber {
                let function = op.kind == .amp ? "bitAnd" : op.kind == .pipe ? "bitOr" : "bitXor"
                let a = text(leftNode), b = text(rightNode)
                report(.bitOperator, range(op), ["function": .code(function), "a": .code(a), "b": .code(b)],
                       fixIts: [fix("rewrite", [edit(range(node), "math.\(function)(\(a), \(b))")])])
            } else {
                report(.unexpected, range(op), ["text": .code(op.token.text)])
            }
            return .error
        case .questionQuestion:
            let l = inferValue(leftNode, inner, expected: expected)
            let r = inferValue(rightNode, inner, expected: l.error ? expected : l.type)
            var v = l.error ? r : l
            v.deps = l.deps.union(r.deps)
            return v
        default:
            _ = infer(leftNode, inner, expected: nil)
            _ = infer(rightNode, inner, expected: nil)
            return .error
        }
    }

    // MARK: - Comparison

    func isLiteralNode(_ node: PositionedNode) -> Bool {
        switch node.kind {
        case .numberLiteral, .implicitMemberExpr, .boolLiteral: return true
        case .stringLiteral: return StringLiteralSyntax(unchecked: node).literalValue != nil
        case .prefixExpr: return PrefixExprSyntax(unchecked: node).operand.node.kind == .numberLiteral
        case .parenExpr: return isLiteralNode(ParenExprSyntax(unchecked: node).value.node)
        default: return false
        }
    }

    /// Types two operands that must agree, the literal one second so it gets the other's type.
    func inferPair(_ leftNode: PositionedNode, _ rightNode: PositionedNode, _ context: ExprContext) -> (Val, Val) {
        if isLiteralNode(leftNode) && !isLiteralNode(rightNode) {
            let r = inferValue(rightNode, context, expected: nil)
            let l = inferValue(leftNode, context, expected: expectedFor(other: r))
            return (l, r)
        }
        let l = inferValue(leftNode, context, expected: nil)
        let r = inferValue(rightNode, context, expected: expectedFor(other: l))
        return (l, r)
    }

    /// The type an operand gives the other side: its own, or `SizePreset` for a `Size`.
    func expectedFor(other v: Val) -> DeskType? {
        if v.error { return nil }
        if v.type == .record("Size") { return .enumeration("SizePreset") }
        if v.open != nil, v.implicitName != nil { return nil }
        if case .any = v.type { return nil }
        if v.plainLiteral != nil { return nil }
        return v.type
    }

    func inferComparison(_ leftNode: PositionedNode, _ rightNode: PositionedNode, _ node: PositionedNode,
                         _ context: ExprContext, ordering: Bool) -> Val {
        var (l, r) = inferPair(leftNode, rightNode, context)
        var v = Val(.bool)
        v.deps = l.deps.union(r.deps)
        v.isConstant = l.isConstant && r.isConstant
        if l.error || r.error { return v }
        // Settling by use.
        if let slot = l.open { recordUse(slot, of: r, rightNode, description: comparedWith(r)) }
        if let slot = r.open { recordUse(slot, of: l, leftNode, description: comparedWith(l)) }
        if l.open != nil || r.open != nil { return v }
        if l.isJson || r.isJson { return v }
        if l.type == .record("Size") && r.type == .enumeration("SizePreset") { return v }
        if r.type == .record("Size") && l.type == .enumeration("SizePreset") { return v }
        // Numbers: dimensions must agree after literal adoption.
        if l.isNumber && r.isNumber {
            adoptPair(&l, leftNode, &r, rightNode, operation: .compare)
            if let a = l.dimension, let b = r.dimension, a != b, !l.error, !r.error {
                if !(a == .percent && b == .plain && r.range == .fixed(0...1)) && !(b == .percent && a == .plain && l.range == .fixed(0...1)) {
                    report(.unitMismatch, range(node), ["op": .text(LocalizedText("compare", "比较")),
                                                        "a": .type(l.type), "b": .type(r.type)])
                }
            }
            return v
        }
        if ordering {
            for (val, side) in [(l, leftNode), (r, rightNode)] where !(val.isNumber || val.type == .date) {
                report(.notOrdered, range(side), ["text": .code(text(side)), "type": .type(val.type)])
                return v
            }
            if l.type != r.type {
                report(.unitMismatch, range(node), ["op": .text(LocalizedText("compare", "比较")), "a": .type(l.type), "b": .type(r.type)])
            }
            return v
        }
        if !compatible(l, r.type) && !compatible(r, l.type) {
            report(.typeMismatch, range(rightNode), ["what": .text(LocalizedText("The comparison", "这个比较")),
                                                     "expected": .type(l.type), "actual": .type(r.type)])
        }
        return v
    }

    func comparedWith(_ v: Val) -> LocalizedText {
        let name = catalog.displayName(for: v.type)
        return LocalizedText("compared with \(name.en)", "和\(name.zh)比较")
    }

    enum Operation { case compare, add, multiply }

    /// Plain literals adopt the other side's dimension (§4.5); DK4011 where the unit must be written; DK4013 for a
    /// plain literal above 1 compared with a fraction.
    func adoptPair(_ l: inout Val, _ leftNode: PositionedNode, _ r: inout Val, _ rightNode: PositionedNode,
                   operation: Operation) {
        func adopt(_ literal: inout Val, _ literalNode: PositionedNode, other: Val) {
            guard literal.plainLiteral != nil, let d = other.dimension, d != .plain, other.plainLiteral == nil else { return }
            if other.range == .fixed(0...1) && d == .plain { return }
            if d.needsWrittenUnit {
                reportUnitNeeded(literalNode, dimension: d)
                literal.error = true
                return
            }
            literal.type = .number(d)
            literal.base = other.base
            literal.plainLiteral = nil
        }
        // A percentage literal compared with a plain value whose range is 0…1 means its fraction.
        if l.dimension == .plain, l.range == .fixed(0...1), r.dimension == .percent { r.type = .number(.plain); return }
        if r.dimension == .plain, r.range == .fixed(0...1), l.dimension == .percent { l.type = .number(.plain); return }
        if l.dimension == .plain, l.range == .fixed(0...1), let value = r.plainLiteral, value > 1 {
            reportFractionOver1(rightNode, what: .code(text(leftNode)), value: value)
            return
        }
        if r.dimension == .plain, r.range == .fixed(0...1), let value = l.plainLiteral, value > 1 {
            reportFractionOver1(leftNode, what: .code(text(rightNode)), value: value)
            return
        }
        // °C / °F literals next to a difference of temperatures are differences.
        if l.dimension == .temperature, l.literalValue != nil, r.dimension == .temperatureDelta { l.type = .number(.temperatureDelta) }
        if r.dimension == .temperature, r.literalValue != nil, l.dimension == .temperatureDelta { r.type = .number(.temperatureDelta) }
        adopt(&l, leftNode, other: r)
        adopt(&r, rightNode, other: l)
        // Byte literals take the base of the data they meet.
        if l.adoptsBase, let b = r.base { l.base = b }
        if r.adoptsBase, let b = l.base { r.base = b }
    }

    func reportFractionOver1(_ node: PositionedNode, what: DiagnosticArgument, value: Double) {
        let n = Checker.numberText(value)
        let r = range(node)
        report(.fractionOver1, r, ["what": what, "number": .code(n)],
               fixIts: [fix("insert", [edit(r.upperBound..<r.upperBound, "%")], ["text": .code("%")])])
    }

    static func numberText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var s = String(value)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    /// DK4011: a plain number where the unit must be written (§4.5, D20), with both readings as fix-its.
    func reportUnitNeeded(_ node: PositionedNode, dimension d: Dimension) {
        let r = range(node)
        let n = text(r)
        let value = Double(n) ?? 0
        var readings: DiagnosticArgument = .text(LocalizedText("", ""))
        var fixIts: [FixIt] = []
        var arguments: [String: DiagnosticArgument] = ["number": .code(n)]
        func units(_ first: String, _ second: String) {
            fixIts = [fix("writeUnit", [edit(r, n + first)], ["text": .code(n + first)]),
                      fix("writeUnit", [edit(r, n + second)], ["text": .code(n + second)])]
        }
        switch d {
        case .time:
            readings = hintText(.unitNeeded, "time")
            arguments["milliseconds"] = .text(Checker.durationText(value / 1000))
            arguments["seconds"] = .text(Checker.durationText(value))
            if value >= 100 { units("ms", "s") } else { units("s", "ms") }
        case .temperature, .temperatureDelta:
            readings = hintText(.unitNeeded, "temperature")
            if context.usesFahrenheit { units("°F", "°C") } else { units("°C", "°F") }
        case .speed:
            readings = hintText(.unitNeeded, "speed")
            if context.usesMetric { units("km/h", "mph") } else { units("mph", "km/h") }
        case .rainfall:
            readings = hintText(.unitNeeded, "rainfall")
            if context.usesMetric { units("mm", "inch") } else { units("inch", "mm") }
        case .pressure:
            readings = hintText(.unitNeeded, "pressure")
            if context.usesMetric { units("hPa", "inHg") } else { units("inHg", "hPa") }
        case .frequency:
            readings = hintText(.unitNeeded, "frequency")
            units("MHz", "GHz")
        case .angle:
            readings = hintText(.unitNeeded, "angle")
            fixIts = [fix("writeUnit", [edit(r.upperBound..<r.upperBound, " * 1°")], ["text": .code("\(n) * 1°")]),
                      fix("writeUnit", [edit(r.upperBound..<r.upperBound, " * 1rad")], ["text": .code("\(n) * 1rad")])]
        default:
            return
        }
        arguments["readings"] = readings
        report(.unitNeeded, r, arguments, fixIts: fixIts)
    }

    /// "1 second", "about 17 minutes" / "1 秒", "大约 17 分钟".
    static func durationText(_ seconds: Double) -> LocalizedText {
        func plural(_ n: Int, _ unit: String) -> String { n == 1 ? "1 \(unit)" : "\(n) \(unit)s" }
        if seconds < 1 {
            let ms = Int((seconds * 1000).rounded())
            return LocalizedText("\(ms) milliseconds", "\(ms) 毫秒")
        }
        if seconds < 60 {
            let s = Int(seconds.rounded())
            let exact = seconds == seconds.rounded()
            return LocalizedText((exact ? "" : "about ") + plural(s, "second"), (exact ? "" : "大约 ") + "\(s) 秒")
        }
        if seconds < 3600 {
            let m = Int((seconds / 60).rounded())
            let exact = seconds.truncatingRemainder(dividingBy: 60) == 0
            return LocalizedText((exact ? "" : "about ") + plural(m, "minute"), (exact ? "" : "大约 ") + "\(m) 分钟")
        }
        if seconds < 86_400 {
            let h = Int((seconds / 3600).rounded())
            let exact = seconds.truncatingRemainder(dividingBy: 3600) == 0
            return LocalizedText((exact ? "" : "about ") + plural(h, "hour"), (exact ? "" : "大约 ") + "\(h) 小时")
        }
        let d = Int((seconds / 86_400).rounded())
        let exact = seconds.truncatingRemainder(dividingBy: 86_400) == 0
        return LocalizedText((exact ? "" : "about ") + plural(d, "day"), (exact ? "" : "大约 ") + "\(d) 天")
    }

    // MARK: - Arithmetic

    func inferArithmetic(_ op: PositionedToken, _ leftNode: PositionedNode, _ rightNode: PositionedNode,
                         _ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        var (l, r) = inferPair(leftNode, rightNode, context)
        var deps = l.deps.union(r.deps)
        func result(_ v: Val) -> Val {
            var out = v
            out.deps = deps
            out.isConstant = l.isConstant && r.isConstant
            out.canBeMissing = l.canBeMissing || r.canBeMissing
            out.bind = nil
            out.dataPath = nil
            out.optionName = nil
            out.stringLiteral = nil
            out.secret = l.secret || r.secret
            return out
        }
        if l.error || r.error { return .error }
        let kind = op.kind
        // Text is never added (D25).
        if kind == .plus && (l.type.isStringLike || r.type.isStringLike) {
            reportTextPlus(node)
            return .error
        }
        if let slot = l.open { recordUse(slot, of: r, rightNode, description: comparedWith(r)) }
        if let slot = r.open { recordUse(slot, of: l, leftNode, description: comparedWith(l)) }
        if l.open != nil && r.open == nil { var v = r; v.open = nil; v.plainLiteral = nil; return result(v) }
        if r.open != nil && l.open == nil { var v = l; v.open = nil; v.plainLiteral = nil; return result(v) }
        if l.open != nil && r.open != nil { var v = l; v.open = nil; return result(v) }
        if l.isJson || r.isJson {
            var v = l.isJson ? r : l
            if l.isJson && r.isJson { v = Val(.number(.plain)) }
            if v.plainLiteral != nil { v = Val(.number(.plain)) }
            return result(v)
        }
        guard (l.isNumber || l.type == .date), (r.isNumber || r.type == .date) else {
            let bad = (l.isNumber || l.type == .date) ? rightNode : leftNode
            let badVal = (l.isNumber || l.type == .date) ? r : l
            report(.typeMismatch, range(bad), ["what": .text(LocalizedText("Arithmetic", "计算")),
                                               "expected": .type(.anyNumber), "actual": .type(badVal.type)])
            return .error
        }
        let opName: LocalizedText
        switch kind {
        case .plus: opName = LocalizedText("add", "相加")
        case .minus: opName = LocalizedText("subtract", "相减")
        case .star: opName = LocalizedText("multiply", "相乘")
        case .slash: opName = LocalizedText("divide", "相除")
        default: opName = LocalizedText("take the remainder of", "取余数")
        }
        func mismatch() -> Val {
            report(.unitMismatch, range(node), ["op": .text(opName), "a": .type(l.type), "b": .type(r.type)])
            return .error
        }
        let isAdd = kind == .plus || kind == .minus || kind == .percent
        // Dates.
        if l.type == .date || r.type == .date {
            if l.type == .date && r.type == .date && kind == .minus { return result(Val(.number(.time))) }
            let other = l.type == .date ? r : l
            let otherNode = l.type == .date ? rightNode : leftNode
            if other.plainLiteral != nil { reportUnitNeeded(otherNode, dimension: .time); return .error }
            if other.dimension == .time && (kind == .plus || (kind == .minus && l.type == .date)) {
                return result(Val(.date))
            }
            return mismatch()
        }
        // Temperatures (rows 3–5).
        if isAdd, kind != .percent {
            var ld = l.dimension, rd = r.dimension
            // A °C/°F literal that is a `+`/`-` operand of a temperature is a difference.
            if ld == .temperature, rd == .temperature {
                if r.literalValue != nil && l.literalValue == nil { rd = .temperatureDelta }
                else if l.literalValue != nil && r.literalValue == nil && kind == .plus { ld = .temperatureDelta }
            }
            if ld == .temperature || rd == .temperature {
                if ld == .temperature && rd == .temperature {
                    if kind == .minus { return result(Val(.number(.temperatureDelta))) }
                    return mismatch()
                }
                if (ld == .temperature && rd == .temperatureDelta) || (ld == .temperatureDelta && rd == .temperature && kind == .plus) {
                    return result(Val(.number(.temperature)))
                }
                if l.plainLiteral != nil { reportUnitNeeded(leftNode, dimension: .temperature); return .error }
                if r.plainLiteral != nil { reportUnitNeeded(rightNode, dimension: .temperature); return .error }
                return mismatch()
            }
        }
        if isAdd {
            // Row 6: the same dimension; a plain literal adopts the other side's.
            adoptPair(&l, leftNode, &r, rightNode, operation: .add)
            if l.error || r.error { return .error }
            guard let a = l.dimension ?? (l.type == .anyNumber ? r.dimension : nil),
                  let b = r.dimension ?? (r.type == .anyNumber ? l.dimension : nil) else { return result(l) }
            if a != b { return mismatch() }
            var v = Val(.number(a))
            v.base = l.base ?? r.base
            v.adoptsBase = l.adoptsBase && r.adoptsBase
            if let x = l.plainLiteral, let y = r.plainLiteral {
                v.plainLiteral = kind == .plus ? x + y : kind == .minus ? x - y : x
                v.literalValue = v.plainLiteral
            }
            deps = l.deps.union(r.deps)
            return result(v)
        }
        // Products and quotients (rows 7–12).
        let a = l.dimension ?? .plain, b = r.dimension ?? .plain
        checkManualConversion(kind, l, leftNode, r, rightNode, node)
        var v: Val
        if kind == .star {
            if a == .percent && b == .plain || a == .plain && b == .percent { v = Val(.number(.percent)) }
            else if a == .percent && b != .plain { v = Val(.number(b)) }
            else if b == .percent && a != .plain { v = Val(.number(a)) }
            else if b == .plain { v = Val(.number(a)); v.base = l.base }
            else if a == .plain { v = Val(.number(b)); v.base = r.base }
            else if a == .bytesPerSecond && b == .time || a == .time && b == .bytesPerSecond {
                v = Val(.number(.bytes)); v.base = l.base ?? r.base
            } else { return mismatch() }
        } else {
            if a == .percent && b == .plain { v = Val(.number(.percent)) }
            else if b == .plain { v = Val(.number(a)); v.base = l.base }
            else if a == b { v = Val(.number(.plain)) }
            else if a == .bytes && b == .time { v = Val(.number(.bytesPerSecond)); v.base = l.base }
            else if a == .bytes && b == .bytesPerSecond { v = Val(.number(.time)) }
            else { return mismatch() }
        }
        if let x = l.plainLiteral, let y = r.plainLiteral {
            v.plainLiteral = kind == .star ? x * y : (y == 0 ? nil : x / y)
            v.literalValue = v.plainLiteral
        }
        if l.plainLiteral != nil && r.plainLiteral == nil && a == .plain && b == .plain { v.plainLiteral = nil }
        if (a == .angle || b == .angle) && v.dimension == .angle { v.literalValue = nil }
        return result(v)
    }

    /// DK4019: `"CPU " + cpu.usage`.
    func reportTextPlus(_ node: PositionedNode) {
        var parts: [PositionedNode] = []
        func collect(_ n: PositionedNode) {
            if n.kind == .binaryExpr, BinaryExprSyntax(unchecked: n).operator.kind == .plus {
                let b = BinaryExprSyntax(unchecked: n)
                collect(b.left.node)
                collect(b.right.node)
            } else {
                parts.append(n)
            }
        }
        collect(node)
        var fixed = ""
        for part in parts {
            if part.kind == .stringLiteral, let s = StringLiteralSyntax(unchecked: part).literalValue {
                fixed += s.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
            } else if part.kind == .stringLiteral {
                let t = text(part)
                fixed += String(t.dropFirst().dropLast())
            } else {
                fixed += "{" + text(part) + "}"
            }
        }
        report(.textPlus, range(node), ["fixed": .code(fixed)],
               fixIts: [fix("rewrite", [edit(range(node), "\"" + fixed + "\"")])])
    }

    /// DK4044 (info): dividing or multiplying a value with a unit by 100, 1000, 1024 or their powers.
    func checkManualConversion(_ kind: TokenKind, _ l: Val, _ leftNode: PositionedNode, _ r: Val,
                               _ rightNode: PositionedNode, _ node: PositionedNode) {
        guard let d = l.dimension, d != .plain, let factor = r.plainLiteral else { return }
        if manualConversionReported.contains(where: { leftNode.range.lowerBound <= $0.lowerBound && $0.upperBound <= leftNode.range.upperBound }) {
            manualConversionReported.append(range(node))
            return
        }
        let powers: [Double] = [100, 1000, 1024, 1_000_000, 1_048_576, 1e9, 1_073_741_824]
        let leftText = text(leftNode)
        var fixed: String?
        if powers.contains(factor) && (kind == .slash || kind == .star) {
            switch d {
            case .bytes, .bytesPerSecond:
                let unit = factor >= 1e9 || factor == 1_073_741_824 ? ".gb" : factor >= 1_000_000 ? ".mb" : ".kb"
                fixed = "{\(leftText), unit: \(unit)}"
            case .percent:
                fixed = leftText
            default:
                fixed = nil
            }
        }
        if d == .temperature, kind == .star, factor == 1.8 || factor == 9 { fixed = "{\(leftText), unit: .fahrenheit}" }
        guard let fixed else { return }
        manualConversionReported.append(range(node))
        report(.manualConversion, range(node), ["fixed": .code(fixed)],
               fixIts: [fix("rewrite", [edit(range(node), fixed)])])
    }

    // MARK: - Prefix

    func inferPrefix(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let prefix = PrefixExprSyntax(unchecked: node)
        let operandNode = prefix.operand.node
        switch prefix.operator.kind {
        case .minus:
            var v = inferValue(operandNode, context, expected: expected)
            if v.error { return v }
            if v.open != nil { return v }
            guard v.isNumber || v.isJson else {
                report(.typeMismatch, range(operandNode), ["what": .text(LocalizedText("`-`", "`-`")),
                                                           "expected": .type(.anyNumber), "actual": .type(v.type)])
                return .error
            }
            if let p = v.plainLiteral { v.plainLiteral = -p; v.literalValue = -p }
            else if operandNode.kind == .numberLiteral, let unit = NumberLiteralSyntax(unchecked: operandNode).unit,
                    let spec = catalog.unit(spelling: unit.text), let value = NumberLiteralSyntax(unchecked: operandNode).value {
                // The sign folds into the literal before it converts: -40°F is −40 °F.
                v.literalValue = -value * spec.factor + spec.offset
            } else if let lv = v.literalValue { v.literalValue = -lv }
            v.bind = nil
            v.dataPath = nil
            return v
        case .notKeyword, .bang:
            var inner = context
            inner.display = false
            inner.param = nil
            let v = inferValue(operandNode, inner, expected: .bool)
            requireBool(v, operandNode)
            var out = Val(.bool)
            out.deps = v.deps
            out.isConstant = v.isConstant
            out.error = v.error
            return out
        case .tilde:
            let v = inferValue(operandNode, context, expected: nil)
            if v.isNumber {
                let a = text(operandNode)
                report(.bitOperator, range(node), ["function": .code("bitNot"), "a": .code(a), "b": .code("")],
                       fixIts: [fix("rewrite", [edit(range(node), "math.bitNot(\(a))")])])
            }
            return .error
        default:
            _ = infer(operandNode, context, expected: expected)
            return .error
        }
    }

    /// DK4043 (info): `not (a == b)` where `a` can be missing.
    func checkNotWithMissing(_ node: PositionedNode) {
        guard node.kind == .prefixExpr else { return }
        let prefix = PrefixExprSyntax(unchecked: node)
        guard prefix.operator.kind == .notKeyword else { return }
        var operand = prefix.operand.node
        while operand.kind == .parenExpr { operand = ParenExprSyntax(unchecked: operand).value.node }
        guard operand.kind == .binaryExpr else { return }
        let binary = BinaryExprSyntax(unchecked: operand)
        guard [.equalEqual, .bangEqual, .less, .lessEqual, .greater, .greaterEqual].contains(binary.operator.kind) else { return }
        let left = binary.left.node
        let leftVal = speculate { infer(left, ExprContext(), expected: nil) }
        guard leftVal.canBeMissing, !leftVal.error else { return }
        let leftText = text(left)
        let fixed = "\(leftText).isMissing or \(text(operand).replacingOccurrences(of: "==", with: "!="))"
        report(.notWithMissing, range(node), ["text": .code(leftText), "fixed": .code(fixed)],
               fixIts: [fix("rewrite", [edit(range(node), fixed)])])
    }
}
