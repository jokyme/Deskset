import Foundation

/// Operators recognised in formulas (docs.rainmeter.net/manual/formulas, "Operators" / "Logical Operators").
enum FormulaOperator: Equatable {
    case plus, minus, star, slash, percent, power
    case bitAnd, bitOr, bitXor, tilde
    case equal, notEqual, less, greater, lessEqual, greaterEqual
    case logicalAnd, logicalOr
}

struct FormulaToken: Equatable {
    enum Kind: Equatable {
        case number(Double)
        case identifier(String)
        case op(FormulaOperator)
        case question, colon, leftParen, rightParen, comma
        case end
    }

    var kind: Kind
    /// Offset in Unicode scalars from the start of the source (for error messages).
    var offset: Int
}

/// Splits formula source into tokens.
///
/// Identifier rule: the Rainmeter version history says measure names "can safely start with or contain any
/// printable letter, number or non-math punctuation or symbol ... and any Unicode letter/word character".
/// So an identifier (or number) is any maximal run of characters that are neither whitespace nor one of the
/// formula's structural characters `+ - * / % & | ^ ~ = < > ? : ( ) ,`. A run that is exactly a numeric literal
/// is a number; anything else (including names that start with a digit, like `1stMeasure`) is an identifier.
/// Consequences (judgment calls, the manual is silent):
/// - `!` is an ordinary name character; there is no logical-NOT operator (the manual lists none) and no `!=`.
/// - `==` is accepted as a synonym of `=` (it would otherwise be a syntax error, so no valid formula changes).
/// - `.` belongs to names/numbers, so `Measure.1` is one name.
enum FormulaLexer {
    @inline(__always) static func isStructural(_ v: UInt32) -> Bool {
        switch v {
        case 0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x26, 0x7C, 0x5E, 0x7E, // + - * / % & | ^ ~
             0x3D, 0x3C, 0x3E, 0x3F, 0x3A, 0x28, 0x29, 0x2C:          // = < > ? : ( ) ,
            return true
        default:
            return false
        }
    }

    static func tokenize(_ source: String) throws -> [FormulaToken] {
        let sc = Array(source.unicodeScalars)
        let n = sc.count
        var tokens: [FormulaToken] = []
        tokens.reserveCapacity(n / 2 + 1)
        var i = 0

        @inline(__always) func isWordChar(_ s: Unicode.Scalar) -> Bool {
            !OptionText.isSpace(s) && !isStructural(s.value)
        }

        while i < n {
            let c = sc[i]
            if OptionText.isSpace(c) { i += 1; continue }
            let start = i
            let next: UInt32 = i + 1 < n ? sc[i + 1].value : 0
            func add(_ k: FormulaToken.Kind, _ len: Int) {
                tokens.append(FormulaToken(kind: k, offset: start))
                i += len
            }
            switch c.value {
            case 0x2B: add(.op(.plus), 1)
            case 0x2D: add(.op(.minus), 1)
            case 0x2A: next == 0x2A ? add(.op(.power), 2) : add(.op(.star), 1)
            case 0x2F: add(.op(.slash), 1)
            case 0x25: add(.op(.percent), 1)
            case 0x26: next == 0x26 ? add(.op(.logicalAnd), 2) : add(.op(.bitAnd), 1)
            case 0x7C: next == 0x7C ? add(.op(.logicalOr), 2) : add(.op(.bitOr), 1)
            case 0x5E: add(.op(.bitXor), 1)
            case 0x7E: add(.op(.tilde), 1)
            case 0x3D: next == 0x3D ? add(.op(.equal), 2) : add(.op(.equal), 1)
            case 0x3C:
                if next == 0x3E { add(.op(.notEqual), 2) } else if next == 0x3D { add(.op(.lessEqual), 2) } else { add(.op(.less), 1) }
            case 0x3E: next == 0x3D ? add(.op(.greaterEqual), 2) : add(.op(.greater), 1)
            case 0x3F: add(.question, 1)
            case 0x3A: add(.colon, 1)
            case 0x28: add(.leftParen, 1)
            case 0x29: add(.rightParen, 1)
            case 0x2C: add(.comma, 1)
            default:
                var j = i
                while j < n, isWordChar(sc[j]) { j += 1 }
                var kind = classify(sc[i..<j])
                // Exponent with a sign, e.g. `2.5e-3`: the word run stopped at the sign.
                if case .identifier = kind, j + 1 < n,
                   sc[j].value == 0x2D || sc[j].value == 0x2B,
                   sc[j + 1].value >= 0x30 && sc[j + 1].value <= 0x39,
                   sc[j - 1].value == 0x65 || sc[j - 1].value == 0x45,
                   isPlainDecimal(sc[i..<(j - 1)]) {
                    var k = j + 1
                    while k < n, isWordChar(sc[k]) { k += 1 }
                    let extended = classify(sc[i..<k])
                    if case .number = extended { kind = extended; j = k }
                }
                tokens.append(FormulaToken(kind: kind, offset: i))
                i = j
            }
        }
        tokens.append(FormulaToken(kind: .end, offset: n))
        return tokens
    }

    /// A word run is a number when it is exactly one numeric literal, otherwise an identifier.
    private static func classify(_ run: ArraySlice<Unicode.Scalar>) -> FormulaToken.Kind {
        if let bytes = asciiBytes(run), let first = bytes.first,
           NumericLiteral.isDigit(first) || first == 0x2E,
           let v = NumericLiteral.exact(bytes) {
            return .number(v)
        }
        var s = String.UnicodeScalarView()
        s.append(contentsOf: run)
        return .identifier(String(s))
    }

    /// True for `123`, `1.5`, `.5` (no exponent, no base prefix) — the mantissa of a signed exponent.
    private static func isPlainDecimal(_ run: ArraySlice<Unicode.Scalar>) -> Bool {
        guard !run.isEmpty else { return false }
        var digits = 0
        var dots = 0
        for s in run {
            if s.value >= 0x30 && s.value <= 0x39 { digits += 1 } else if s.value == 0x2E { dots += 1 } else { return false }
        }
        return digits > 0 && dots <= 1
    }

    private static func asciiBytes(_ run: ArraySlice<Unicode.Scalar>) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(run.count)
        for s in run {
            guard s.value < 0x80 else { return nil }
            out.append(UInt8(s.value))
        }
        return out
    }
}
