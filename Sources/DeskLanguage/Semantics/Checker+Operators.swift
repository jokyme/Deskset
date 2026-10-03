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
        func asUse(_ x: Val) -> Val {
            var y = x
            if x.type == .record("Size") { y.type = .enumeration("SizePreset") }
            return y
        }
        if let slot = l.open { recordUse(slot, of: asUse(r), rightNode, description: comparedWith(r)) }
        if let slot = r.open { recordUse(slot, of: asUse(l), leftNode, description: comparedWith(l)) }
        if hasOpenDimension(l) || hasOpenDimension(r) { return v }
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
            if isComparison(leftNode) || isComparison(rightNode) { return v }
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

    func isComparison(_ node: PositionedNode) -> Bool {
        guard node.kind == .binaryExpr else { return false }
        return [.less, .lessEqual, .greater, .greaterEqual].contains(BinaryExprSyntax(unchecked: node).operator.kind)
    }

    func comparedWith(_ v: Val) -> LocalizedText {
        let name = catalog.displayName(for: v.type)
        return LocalizedText("compared with \(DiagnosticRenderer.shortName(name.en, .english))",
                             "和\(DiagnosticRenderer.shortName(name.zh, .simplifiedChinese))比较")
    }

    enum Operation { case compare, add, multiply }

    /// Plain literals adopt the other side's dimension (§4.5); DK4011 where the unit must be written; DK4013 for a
    /// plain literal above 1 compared with a fraction.
    func adoptPair(_ l: inout Val, _ leftNode: PositionedNode, _ r: inout Val, _ rightNode: PositionedNode,
                   operation: Operation) {
        defer {
            recordNumericAdoption(l, leftNode)
            recordNumericAdoption(r, rightNode)
        }
        func adopt(_ literal: inout Val, _ literalNode: PositionedNode, other: Val, otherNode: PositionedNode) {
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
            if mute == 0, d == .bytes || d == .bytesPerSecond {
                numericBaseSources[id(literalNode)] = [id(otherNode)]
            }
        }
        // A percentage literal compared with a plain value whose range is 0…1 means its fraction.
        if l.dimension == .plain, l.range == .fixed(0...1), r.dimension == .percent {
            recordPercentAsFraction(r, rightNode)
            r.type = .number(.plain); r.literalValue = r.literalValue.map { $0 / 100 }
            return
        }
        if r.dimension == .plain, r.range == .fixed(0...1), l.dimension == .percent {
            recordPercentAsFraction(l, leftNode)
            l.type = .number(.plain); l.literalValue = l.literalValue.map { $0 / 100 }
            return
        }
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
        adopt(&l, leftNode, other: r, otherNode: rightNode)
        adopt(&r, rightNode, other: l, otherNode: leftNode)
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

    /// "is 1 second", "is about 17 minutes" / "是 1 秒", "大约是 17 分钟" (the verb is part of the text so the Chinese
    /// can put 大约 before it, as the spec's example does). Fractions of a millisecond are shown as written; huge or
    /// non-finite values never reach an `Int` conversion.
    static func durationText(_ seconds: Double) -> LocalizedText {
        func plural(_ n: Double, _ unit: String) -> String { n == 1 ? "1 \(unit)" : "\(number(n)) \(unit)s" }
        func number(_ n: Double) -> String {
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            var text = String(format: "%.3f", n)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text
        }
        func phrase(_ exact: Bool, _ en: String, _ zh: String) -> LocalizedText {
            LocalizedText((exact ? "is " : "is about ") + en, (exact ? "是 " : "大约是 ") + zh)
        }
        guard seconds.isFinite, seconds >= 0, seconds < 1e15 else {
            return LocalizedText("is a very long time", "是很长的时间")
        }
        if seconds < 1 {
            let ms = seconds * 1000
            let shown = ms >= 1 ? ms.rounded() : ms
            let exact = ms < 1 || shown == ms
            return phrase(exact, plural(exact ? ms : shown, "millisecond"), "\(number(exact ? ms : shown)) 毫秒")
        }
        func unit(_ size: Double, _ en: String, _ zh: String) -> LocalizedText {
            let n = (seconds / size).rounded()
            let exact = seconds.truncatingRemainder(dividingBy: size) == 0
            return phrase(exact, plural(n, en), "\(number(n)) \(zh)")
        }
        if seconds < 60 { return unit(1, "second", "秒") }
        if seconds < 3600 { return unit(60, "minute", "分钟") }
        if seconds < 86_400 { return unit(3600, "hour", "小时") }
        return unit(86_400, "day", "天")
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
        if l.error || r.error {
            // `"CPU: " + cpu.usage + "%"`: the addition of text goes on, and the whole chain is rewritten at once.
            let leftRange = range(leftNode)
            if op.kind == .plus, l.error, !r.error, leftNode.kind == .binaryExpr, hasReported(.textPlus, at: leftRange) {
                diagnostics.removeAll { $0.id == .textPlus && $0.range == leftRange && $0.file == file }
                reportTextPlus(node)
            }
            return .error
        }
        let kind = op.kind
        // Text is never added (D25).
        if kind == .plus && (l.type.isStringLike || r.type.isStringLike) {
            reportTextPlus(node)
            return .error
        }
        if let slot = l.open { recordUse(slot, of: r, rightNode, description: comparedWith(r)) }
        if let slot = r.open { recordUse(slot, of: l, leftNode, description: comparedWith(l)) }
        if hasOpenDimension(l) && !hasOpenDimension(r) {
            var v = r
            v.open = (r.dimension == .plain && [.plus, .minus, .percent].contains(kind)) ? l.open : nil
            v.plainLiteral = nil
            return result(v)
        }
        if hasOpenDimension(r) && !hasOpenDimension(l) {
            var v = l
            v.open = (l.dimension == .plain && [.plus, .minus, .percent].contains(kind)) ? r.open : nil
            v.plainLiteral = nil
            return result(v)
        }
        if hasOpenDimension(l) && hasOpenDimension(r) { var v = l; v.open = l.open; return result(v) }
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
        // `t * 9 / 5 + 32`: the °F formula by hand (DK4044), not a temperature plus a number needing a unit.
        if kind == .plus, l.dimension == .temperature, r.plainLiteral == 32, reportManualConversion(node, dimension: .temperature) {
            return result(l)
        }
        // Temperatures (rows 3–5).
        if isAdd, kind != .percent {
            var ld = l.dimension, rd = r.dimension
            // A °C/°F literal that is a `+`/`-` operand of a temperature is a difference.
            if ld == .temperature, rd == .temperature {
                if r.literalValue != nil && l.literalValue == nil {
                    rd = .temperatureDelta
                    var delta = r; delta.type = .number(.temperatureDelta)
                    recordNumericAdoption(delta, rightNode)
                } else if l.literalValue != nil && r.literalValue == nil && kind == .plus {
                    ld = .temperatureDelta
                    var delta = l; delta.type = .number(.temperatureDelta)
                    recordNumericAdoption(delta, leftNode)
                }
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
            v.adoptsBase = (a == .bytes || a == .bytesPerSecond) && v.base == nil && (l.adoptsBase || r.adoptsBase)
            if let x = l.plainLiteral, let y = r.plainLiteral {
                v.plainLiteral = kind == .plus ? x + y : kind == .minus ? x - y
                    : (y == 0 ? nil : x.truncatingRemainder(dividingBy: y))
                if v.plainLiteral?.isFinite == false { v.plainLiteral = nil }
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
            else if a == .percent && b == .percent { return mismatch() }
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
        if v.dimension == .bytes || v.dimension == .bytesPerSecond {
            v.base = l.base ?? r.base
            v.adoptsBase = v.base == nil && (l.adoptsBase || r.adoptsBase)
        }
        if let x = l.plainLiteral, let y = r.plainLiteral {
            v.plainLiteral = kind == .star ? x * y : (y == 0 ? nil : x / y)
            if v.plainLiteral?.isFinite == false { v.plainLiteral = nil }
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
        guard let d = l.dimension, d != .plain, r.plainLiteral != nil else { return }
        _ = reportManualConversion(node, dimension: d)
    }

    /// DK4044 for the conversion that ends at `node`, written by hand: `x / 1024 / 1024`, `cpu.usage / 100`,
    /// `t * 9 / 5 + 32`. The whole chain is reported once (a longer chain replaces the report of its inner part),
    /// with the Desk way of writing it; the rewrite is offered only where it is Desk: the content of an
    /// interpolation, the value of `Text(…)` (which becomes `Text("{x, unit: …}")`), or a percentage anywhere.
    @discardableResult
    func reportManualConversion(_ node: PositionedNode, dimension d: Dimension) -> Bool {
        // The steps, outermost first, down the left spine: `* n`, `/ n` and a final `+ 32`.
        var steps: [(op: TokenKind, value: Double)] = []
        var current = node
        while current.kind == .binaryExpr {
            let binary = BinaryExprSyntax(unchecked: current)
            let op = binary.operator.token.kind
            guard op == .star || op == .slash || (op == .plus && steps.isEmpty),
                  let number = NumberLiteralSyntax(binary.right.node), number.unit == nil, let value = number.value else { break }
            steps.append((op, value))
            current = binary.left.node
        }
        guard !steps.isEmpty, current.range != node.range else { return false }
        let base = current
        let baseText = text(base)
        var unit: String?
        var plain = false
        let inner = Array(steps.reversed())   // innermost first
        switch d {
        case .bytes, .bytesPerSecond:
            guard !inner.contains(where: { $0.op == .plus }) else { return false }
            var factor = 1.0
            for step in inner { factor = step.op == .slash ? factor * step.value : factor / step.value }
            let powers: [Double] = [1000, 1024, 1_000_000, 1_048_576, 1e9, 1_073_741_824, 1e12, 1_099_511_627_776]
            if !powers.contains(factor) {
                // `x * 1024` and the like: still a conversion by hand, shown as the unit it is closest to.
                guard inner.allSatisfy({ [1000, 1024].contains($0.value) || [1_000_000, 1_048_576].contains($0.value) }) else { return false }
                factor = inner.reduce(1.0) { $0 * $1.value }
            }
            unit = factor >= 1e12 ? ".tb" : factor >= 1e9 ? ".gb" : factor >= 1e6 ? ".mb" : ".kb"
        case .percent:
            guard inner.count == 1, inner[0].value == 100, inner[0].op != .plus else { return false }
            plain = true
        case .temperature:
            let shape = inner.map { "\($0.op == .star ? "*" : $0.op == .slash ? "/" : "+")\(Checker.numberText($0.value))" }
            guard [["*9", "/5", "+32"], ["*9", "/5"], ["*1.8", "+32"], ["*1.8"], ["*9"]].contains(shape) else { return false }
            unit = ".fahrenheit"
        default:
            return false
        }
        let fixed = plain ? baseText : "{\(baseText), unit: \(unit!)}"
        // Where the rewrite is Desk.
        var fixIts: [FixIt] = []
        let ancestors = ancestorPath(of: node)
        if plain {
            fixIts.append(fix("rewrite", [edit(range(node), baseText)]))
        } else if let parent = ancestors.last, parent.kind == .interpolation,
                  InterpolationSyntax(unchecked: parent).value.node.range == node.range {
            let options = InterpolationSyntax(unchecked: parent).formatOptions
            if !options.contains(where: { $0.label.name == "unit" }) {
                var edits = [edit(range(node), "\(baseText), unit: \(unit!)")]
                // The unit written after it by hand (`{x / 1024 / 1024} MB`) is now part of the value's text.
                let end = range(parent).upperBound
                let after = text(end..<min(end + 4, tree.text.utf8.count))
                let symbol = unit == ".fahrenheit" ? "°F" : unit!.dropFirst().uppercased()
                for written in [" " + symbol, symbol] where after.uppercased().hasPrefix(written.uppercased()) {
                    let length = written.utf8.count
                    let next = text((end + length)..<min(end + length + 1, tree.text.utf8.count))
                    if next.isEmpty || !(next.first!.isLetter || next.first!.isNumber) {
                        edits.append(edit(end..<(end + length), ""))
                    }
                    break
                }
                fixIts.append(fix("rewrite", edits))
            }
        } else if ancestors.count >= 4, ancestors[ancestors.count - 1].kind == .argument,
                  ArgumentSyntax(unchecked: ancestors[ancestors.count - 1]).label == nil,
                  ancestors[ancestors.count - 2].kind == .argumentClause,
                  let call = ancestors[ancestors.count - 3] as PositionedNode?,
                  call.kind == .callStmt || call.kind == .callExpr,
                  text(call).hasPrefix("Text("),
                  ArgumentClauseSyntax(unchecked: ancestors[ancestors.count - 2]).arguments.first?.node.range == ancestors[ancestors.count - 1].range {
            fixIts.append(fix("rewrite", [edit(range(node), "\"{\(baseText), unit: \(unit!)}\"")]))
        }
        // A longer chain replaces the report of its inner part.
        let r = range(node)
        let replaced = diagnostics.filter { $0.id == .manualConversion && r.contains($0.range.lowerBound) && $0.range != r }
        if !replaced.isEmpty {
            diagnostics.removeAll { d in replaced.contains { $0.range == d.range && $0.id == d.id } }
            for d in replaced { reportedKeys.remove(diagnosticKey(d)) }
        }
        report(.manualConversion, r, ["fixed": .code(fixed)], fixIts: fixIts)
        manualConversionReported.append(r)
        return true
    }

    /// The nodes from the root down to `node`'s parent.
    func ancestorPath(of node: PositionedNode) -> [PositionedNode] {
        var path: [PositionedNode] = []
        var current = tree.rootNode
        while true {
            guard let next = current.childNodes.first(where: { $0.range.lowerBound <= node.range.lowerBound && node.range.upperBound <= $0.range.upperBound }) else { return path }
            path.append(current)
            if next.range == node.range && next.kind == node.kind { return path }
            current = next
        }
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
