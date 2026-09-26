import Foundation
@testable import DesksetCore

// Tests for DesksetCore/Formula (docs.rainmeter.net/manual/formulas/, /manual/measures/calc/,
// /manual/measures/general-options/ifconditions/, /manual/skins/option-types/ and the Rainmeter version history).

private func ev(_ s: String, _ vars: [String: Double] = [:]) throws -> Double {
    try CompiledFormula(s).evaluate(variables: vars)
}

func runFormulaTests(_ t: TestRunner) {
    t.suite("Formula: manual examples") {
        // Formulas page, intro
        t.equal(try Formula.evaluate("(2.5 + 100) * 2"), 205)                                  // Calc Formula=
        t.equal(try ev("MeasureName > (2.5 + 100) * 2", ["MeasureName": 300]), 1)             // IfCondition=
        t.equal(try ev("MeasureName > (2.5 + 100) * 2", ["MeasureName": 205]), 0)
        t.equal(try Formula.evaluate("((2.5 + 100) * 2)"), 205)                                // W=
        t.equal(Formula.number("((2.5 + 100) * 2)"), 205)
        t.equal(try Formula.evaluate("(255 * 0.5)"), 127.5)                                    // FontColor part
        // Logical operators example
        for (v, expected) in [(5.0, 1.0), (10, 1), (7, 0)] {
            t.equal(try ev("(MyMeasure = 5) || (MyMeasure = 10)", ["MyMeasure": v]), expected)
        }
        // Conditional operations: X=([Measure] < 6 ? 0 : 10) with [Measure] = 5 substituted
        t.equal(Formula.number("(5 < 6 ? 0 : 10)"), 0)
        // Nested: X=([Measure] < 1 ? 99 : ([Measure] < 2 ? 98 : ([Measure] < 3 ? 97 : 96))) with [Measure] = 2
        t.equal(Formula.number("(2 < 1 ? 99 : (2 < 2 ? 98 : (2 < 3 ? 97 : 96)))"), 97)
        let nested = "Measure < 1 ? 99 : (Measure < 2 ? 98 : (Measure < 3 ? 97 : 96))"
        t.equal(try ev(nested, ["Measure": 0]), 99)
        t.equal(try ev(nested, ["Measure": 1]), 98)
        t.equal(try ev(nested, ["Measure": 2]), 97)
        t.equal(try ev(nested, ["Measure": 3]), 96)
        // Calc page: Formula=MeasureOne < 6 ? 0 : 10 with MeasureOne = 5
        t.equal(try ev("MeasureOne < 6 ? 0 : 10", ["MeasureOne": 5]), 0)
        // Option Types page: FontSize=42 / (40 + 2) / (2 > 1 ? 42 : 666)
        t.equal(Formula.number("42"), 42)
        t.equal(Formula.number("(40 + 2)"), 42)
        t.equal(Formula.number("(2 > 1 ? 42 : 666)"), 42)
        // IfConditions page examples
        t.equal(try ev("MeasureName >= 10", ["MeasureName": 10]), 1)
        t.equal(try ev("MeasureName >= 10", ["MeasureName": 9.99]), 0)
        t.equal(try ev("MeasureOne = (MeasureTwo + 4) / 2", ["MeasureOne": 3, "MeasureTwo": 2]), 1)
        t.equal(try ev("(MeasureName > 5) && (MeasureName < 10)", ["MeasureName": 7]), 1)
        t.equal(try ev("(MeasureName > 5) && (MeasureName < 10)", ["MeasureName": 10]), 0)
        let three = "(MeasureName = 25) || (MeasureName = 50) || (MeasureName = 75)"
        t.equal(try ev(three, ["MeasureName": 50]), 1)
        t.equal(try ev(three, ["MeasureName": 51]), 0)
        t.equal(try ev("MeasureCPU < 10", ["MeasureCPU": 3]), 1)
        t.equal(try ev("(MeasureCPU >= 10) && (MeasureCPU <= 90)", ["MeasureCPU": 90]), 1)
        t.equal(try ev("MeasureCPU > 90", ["MeasureCPU": 90]), 0)
        // Version history: "5+-1" is valid and equal to "5+(-1)"
        t.equal(try Formula.evaluate("5+-1"), 4)
    }

    t.suite("Formula: arithmetic operators") {
        t.equal(try Formula.evaluate("1+2*3"), 7)
        t.equal(try Formula.evaluate("(1+2)*3"), 9)
        t.equal(try Formula.evaluate("10-4-3"), 3)          // left-associative
        t.equal(try Formula.evaluate("100/10/5"), 2)
        t.equal(try Formula.evaluate("7/2"), 3.5)
        t.equal(try Formula.evaluate("2**10"), 1024)
        t.equal(try Formula.evaluate("2**3**2"), 512)       // right-associative
        t.equal(try Formula.evaluate("2*3**2"), 18)         // ** binds tighter than *
        t.equal(try Formula.evaluate("7%3"), 1)
        t.equal(try Formula.evaluate("-7%3"), -1)           // fmod: sign of the dividend
        t.equal(try Formula.evaluate("7%-3"), 1)
        t.equal(try Formula.evaluate("5.5%2"), 1.5)
        t.equal(try Formula.evaluate("10 - 2 * 3 % 4"), 8)  // * and % same level, left to right: (2*3)%4 = 2
        t.equal(try Formula.evaluate("  1   +\t2 "), 3)
        t.equal(try Formula.evaluate("1+2\n*3"), 7)         // any whitespace
    }

    t.suite("Formula: unary operators") {
        t.equal(try Formula.evaluate("-5"), -5)
        t.equal(try Formula.evaluate("+5"), 5)
        t.equal(try Formula.evaluate("--5"), 5)
        t.equal(try Formula.evaluate("5--1"), 6)
        t.equal(try Formula.evaluate("5 - -1"), 6)
        t.equal(try Formula.evaluate("3*-2"), -6)
        t.equal(try Formula.evaluate("-2**2"), -4)          // unary minus applies to the power
        t.equal(try Formula.evaluate("(-2)**2"), 4)
        t.equal(try Formula.evaluate("2**-1"), 0.5)
        t.equal(try Formula.evaluate("-(3+4)"), -7)
        t.equal(try Formula.evaluate("-x", lookup: { _ in 3 }), -3)
        t.equal(try Formula.evaluate("~5"), -6)
        t.equal(try Formula.evaluate("~0"), -1)
        t.equal(try Formula.evaluate("~~7"), 7)
        t.equal(try Formula.evaluate("~2**2"), -5)          // ~(2**2)
    }

    t.suite("Formula: bitwise operators") {
        t.equal(try Formula.evaluate("6&3"), 2)
        t.equal(try Formula.evaluate("6|3"), 7)
        t.equal(try Formula.evaluate("6^3"), 5)             // ^ is XOR, not power
        t.equal(try Formula.evaluate("5.7&3"), 1)           // truncated toward zero
        t.equal(try Formula.evaluate("-1&255"), 255)
        t.equal(try Formula.evaluate("-5.9|0"), -5)
        t.equal(try Formula.evaluate("1|2^3"), 1)           // ^ binds tighter than |
        t.equal(try Formula.evaluate("6&3|8"), 10)          // & binds tighter than |
        t.equal(try Formula.evaluate("12^10&6"), 14)        // & binds tighter than ^: 12 ^ (10&6=2)
        t.equal(try Formula.evaluate("1+2&3"), 3)           // arithmetic binds tighter than bitwise
        t.equal(try Formula.evaluate("6&3=2"), 1)           // bitwise binds tighter than comparison
        t.equal(try Formula.evaluate("0xFF & 0x0F"), 15)
        t.equal(try Formula.evaluate("1e30 & 1"), 1)        // saturates to Int64.max (odd), no trap
        t.equal(try Formula.evaluate("Sqrt(-1) | 4"), 4)    // NaN → 0
    }

    t.suite("Formula: comparison and logical operators") {
        t.equal(try Formula.evaluate("1<2"), 1)
        t.equal(try Formula.evaluate("2<1"), 0)
        t.equal(try Formula.evaluate("2<=2"), 1)
        t.equal(try Formula.evaluate("2>=3"), 0)
        t.equal(try Formula.evaluate("3>2"), 1)
        t.equal(try Formula.evaluate("1=1"), 1)
        t.equal(try Formula.evaluate("1=2"), 0)
        t.equal(try Formula.evaluate("1<>1"), 0)
        t.equal(try Formula.evaluate("1<>2"), 1)
        t.equal(try Formula.evaluate("1==1"), 1)            // lenient synonym
        t.equal(try Formula.evaluate("1 < 2 = 1"), 1)       // relational binds tighter than equality
        t.equal(try Formula.evaluate("1+1=2"), 1)
        t.equal(try Formula.evaluate("(1)&&(0)"), 0)
        t.equal(try Formula.evaluate("(1)||(0)"), 1)
        t.equal(try Formula.evaluate("(2)&&(3)"), 1)        // any non-zero is true, result is 1
        t.equal(try Formula.evaluate("(0)||(0)"), 0)
        t.equal(try Formula.evaluate("1 || 0 && 0"), 1)     // && binds tighter than ||
        t.equal(try Formula.evaluate("0 && 1 || 1"), 1)
        // Unparenthesized comparisons around && / || (the manual requires parentheses; we don't)
        t.equal(try ev("a = 5 || a = 10", ["a": 10]), 1)
        t.equal(try ev("a > 5 && a < 10", ["a": 12]), 0)
        t.equal(try Formula.evaluate("(-1)&&(1)"), 1)
        t.equal(try Formula.evaluate("Sqrt(-1) && 1"), 0)   // NaN is false
    }

    t.suite("Formula: conditional operator") {
        t.equal(try Formula.evaluate("1 ? 2 : 3"), 2)
        t.equal(try Formula.evaluate("0 ? 2 : 3"), 3)
        t.equal(try Formula.evaluate("0.5 ? 2 : 3"), 2)
        t.equal(try Formula.evaluate("0 ? 1 : 0 ? 2 : 3"), 3)       // right-associative chain
        t.equal(try Formula.evaluate("0 ? 1 : 1 ? 2 : 3"), 2)
        t.equal(try Formula.evaluate("1 ? 0 ? 5 : 6 : 7"), 6)       // nested in the true branch
        t.equal(try Formula.evaluate("0 || 1 ? 10 : 20"), 10)      // ?: has the lowest precedence
        t.equal(try Formula.evaluate("1 + 1 ? 3 : 4"), 3)
        t.equal(try Formula.evaluate("(1 ? 2 : 3) + 10"), 12)
        t.equal(try Formula.evaluate("10 + (0 ? 2 : 3)"), 13)
        t.equal(try Formula.evaluate("1 ? -1 : -2"), -1)
        t.equal(try Formula.evaluate("Sqrt(-1) ? 1 : 2"), 2)        // NaN condition is false
        t.equal(try Formula.evaluate("Min(1 ? 7 : 8, 9)"), 7)
        // Only the chosen branch is evaluated (the other may reference unknown names).
        t.equal(try Formula.evaluate("1 ? 5 : Unknown", lookup: { _ in nil }), 5)
        t.equal(try Formula.evaluate("0 ? Unknown : 6", lookup: { _ in nil }), 6)
        var calls: [String] = []
        _ = try Formula.evaluate("c ? A : B", lookup: { calls.append($0); return $0 == "c" ? 1 : 2 })
        t.equal(calls, ["c", "A"])
    }

    t.suite("Formula: conditional nesting (manual: up to 30)") {
        func chain(_ n: Int) -> String {
            // (x < 1 ? 1 : (x < 2 ? 2 : ( … (x < n ? n : 999) … )))
            var s = ""
            for i in 1...n { s += "(x < \(i) ? \(i) : " }
            s += "999" + String(repeating: ")", count: n)
            return s
        }
        for n in [1, 10, 30] {
            let f = try CompiledFormula(chain(n))
            t.equal(try f.evaluate { _ in 0 }, 1, "n=\(n)")
            t.equal(try f.evaluate { _ in Double(n) - 1 }, Double(n), "n=\(n)")
            t.equal(try f.evaluate { _ in Double(n) + 5 }, 999, "n=\(n)")
        }
        // Deeper nesting than the manual's limit is accepted (lenient) …
        t.equal(try Formula.evaluate(chain(40), lookup: { _ in 39 }), 40)
        // … and the unparenthesized form works too.
        var flat = ""
        for i in 1...30 { flat += "x < \(i) ? \(i) : " }
        flat += "999"
        t.equal(try Formula.evaluate(flat, lookup: { _ in 17.5 }), 18)
        // Constant chains are folded.
        t.equal(Formula.number("(" + chain(30).replacingOccurrences(of: "x", with: "12") + ")"), 13)
    }

    t.suite("Formula: functions") {
        let pi = Double.pi
        t.close(try Formula.evaluate("Cos(0)"), 1)
        t.close(try Formula.evaluate("Cos(PI)"), -1)
        t.close(try Formula.evaluate("Sin(PI/2)"), 1)
        t.close(try Formula.evaluate("Tan(0)"), 0)
        t.close(try Formula.evaluate("Tan(PI/4)"), 1)
        t.close(try Formula.evaluate("Acos(1)"), 0)
        t.close(try Formula.evaluate("Acos(-1)"), pi)
        t.close(try Formula.evaluate("Asin(1)"), pi / 2)
        t.close(try Formula.evaluate("Asin(-1)"), -pi / 2)
        t.close(try Formula.evaluate("Atan(1)"), pi / 4)
        t.close(try Formula.evaluate("Atan2(1, 1)"), pi / 4)        // Atan2(y, x)
        t.close(try Formula.evaluate("Atan2(1, -1)"), 3 * pi / 4)
        t.close(try Formula.evaluate("Atan2(-1, -1)"), -3 * pi / 4)
        t.close(try Formula.evaluate("Atan2(0, -1)"), pi)
        t.close(try Formula.evaluate("Atan2(1, 0)"), pi / 2)
        t.close(try Formula.evaluate("Rad(180)"), pi)
        t.close(try Formula.evaluate("Deg(PI)"), 180)
        t.close(try Formula.evaluate("Deg(Rad(45))"), 45)
        t.equal(try Formula.evaluate("Abs(-3)"), 3)
        t.equal(try Formula.evaluate("Abs(3)"), 3)
        t.equal(try Formula.evaluate("Neg(3)"), -3)
        t.equal(try Formula.evaluate("Neg(-3)"), 3)
        t.close(try Formula.evaluate("Exp(1)"), M_E)
        t.close(try Formula.evaluate("Exp(0)"), 1)
        t.close(try Formula.evaluate("Log(1000)"), 3)                 // base 10
        t.close(try Formula.evaluate("Ln(E)"), 1)                     // natural
        t.close(try Formula.evaluate("Ln(Exp(2.5))"), 2.5)
        t.equal(try Formula.evaluate("Sqrt(16)"), 4)
        t.equal(try Formula.evaluate("Sgn(5)"), 1)
        t.equal(try Formula.evaluate("Sgn(-2)"), -1)
        t.equal(try Formula.evaluate("Sgn(0)"), 0)
        t.close(try Formula.evaluate("Frac(1.234)"), 0.234)          // manual: frac(1.234) = 0.234
        t.close(try Formula.evaluate("Frac(-1.5)"), -0.5)
        t.equal(try Formula.evaluate("Trunc(1.234)"), 1)              // manual: trunc(1.234) = 1
        t.equal(try Formula.evaluate("Trunc(-1.7)"), -1)
        t.equal(try Formula.evaluate("Floor(1.5)"), 1)
        t.equal(try Formula.evaluate("Floor(-1.5)"), -2)
        t.equal(try Formula.evaluate("Ceil(1.2)"), 2)
        t.equal(try Formula.evaluate("Ceil(-1.2)"), -1)
        t.equal(try Formula.evaluate("Min(1, 2)"), 1)
        t.equal(try Formula.evaluate("Min(2, -1)"), -1)
        t.equal(try Formula.evaluate("Max(1, 2)"), 2)
        t.equal(try Formula.evaluate("Min(3, 1, 2)"), 1)              // lenient: more than 2 arguments
        t.equal(try Formula.evaluate("Max(3, 1, 7, 2)"), 7)
        t.equal(try Formula.evaluate("Clamp(5, 0, 10)"), 5)
        t.equal(try Formula.evaluate("Clamp(-5, 0, 10)"), 0)
        t.equal(try Formula.evaluate("Clamp(15, 0, 10)"), 10)
        t.equal(try Formula.evaluate("Round(1.4)"), 1)
        t.equal(try Formula.evaluate("Round(1.5)"), 2)
        t.equal(try Formula.evaluate("Round(2.5)"), 3)                // half away from zero
        t.equal(try Formula.evaluate("Round(-1.5)"), -2)
        t.close(try Formula.evaluate("Round(1.234, 2)"), 1.23)
        t.close(try Formula.evaluate("Round(3.14159, 3)"), 3.142)
        t.equal(try Formula.evaluate("Round(1.5, 0)"), 2)
        t.equal(try Formula.evaluate("Round(1234.5678, -2)"), 1200)
        t.close(try Formula.evaluate("Round(1.23456, 20)"), 1.23456)
        t.close(try Formula.evaluate("Round(1.26, 1.9)"), 1.3)        // precision truncated to 1
        t.equal(try Formula.evaluate("Round(5, -400)"), 0)
        // Nesting and whitespace
        t.equal(try Formula.evaluate("Max(Min(5, 3), 2)"), 3)
        t.equal(try Formula.evaluate("Clamp(Max(1,2)*100, 0, 150)"), 150)
        t.equal(try Formula.evaluate(" Min ( 1 , 2 ) "), 1)
        t.equal(try Formula.evaluate("Min((1),(2))"), 1)
        t.equal(try Formula.evaluate("Round(x * 100, 1)", lookup: { _ in 0.12345 }), 12.3)
        t.equal(try Formula.evaluate("Clamp(x, lo, hi)", lookup: { ["x": 7, "lo": 0, "hi": 5][$0] }), 5)
        t.equal(try Formula.evaluate("Min(x, 1, 2)", lookup: { _ in 0.5 }), 0.5)
    }

    t.suite("Formula: case-insensitive names and constants") {
        t.equal(try Formula.evaluate("COS(0)"), 1)
        t.equal(try Formula.evaluate("cos(0)"), 1)
        t.equal(try Formula.evaluate("MiN(1,2)"), 1)
        t.equal(try Formula.evaluate("ROUND(1.4)"), 1)
        t.equal(try Formula.evaluate("sQrT(9)"), 3)
        t.close(try Formula.evaluate("PI"), Double.pi)
        t.close(try Formula.evaluate("pi"), Double.pi)
        t.close(try Formula.evaluate("Pi"), Double.pi)
        t.close(try Formula.evaluate("E"), M_E)
        t.close(try Formula.evaluate("e"), M_E)
        t.close(try Formula.evaluate("2*PI"), 2 * Double.pi)
        t.close(try Formula.evaluate("-PI"), -Double.pi)
        // Constants win over lookup names.
        t.close(try Formula.evaluate("PI", lookup: { _ in 100 }), Double.pi)
        // Lookup names are case-insensitive through evaluate(variables:)
        t.equal(try ev("measurecpu + MEASURECPU", ["MeasureCPU": 21]), 42)
        let f = try CompiledFormula("A + b + a + C + B")
        t.equal(f.identifiers, ["A", "b", "C"])            // first spelling, deduplicated case-insensitively
        t.equal(try f.evaluate(variables: ["a": 1, "B": 10, "c": 100]), 122)
        // Lookup receives the name as spelled.
        var seen: [String] = []
        _ = try Formula.evaluate("MyMeasure", lookup: { seen.append($0); return 1 })
        t.equal(seen, ["MyMeasure"])
    }

    t.suite("Formula: number literals") {
        t.equal(try Formula.evaluate("0.5"), 0.5)
        t.equal(try Formula.evaluate("0.25 * 4"), 1)
        t.equal(try Formula.evaluate(".5"), 0.5)           // manual says error; accepted leniently
        t.equal(try Formula.evaluate(".25+.25"), 0.5)
        t.equal(try Formula.evaluate("5."), 5)
        t.equal(try Formula.evaluate("007"), 7)
        t.equal(try Formula.evaluate("1e3"), 1000)
        t.equal(try Formula.evaluate("1.5e-3 * 1000"), 1.5)
        t.equal(try Formula.evaluate("2E+2"), 200)
        t.equal(try Formula.evaluate("1e3+1"), 1001)
        t.equal(try Formula.evaluate("2e-1"), 0.2)
        t.equal(try Formula.evaluate("1e3-1"), 999)
        // Other bases (Calc page): lower-case prefix, as in the manual's examples
        t.equal(try Formula.evaluate("0b110110"), 54)
        t.equal(try Formula.evaluate("0o123"), 83)
        t.equal(try Formula.evaluate("0xF1"), 241)
        t.equal(try Formula.evaluate("0xf1"), 241)
        t.equal(try Formula.evaluate("0xFF + 1"), 256)
        t.equal(try Formula.evaluate("-0x10"), -16)
        t.equal(try Formula.evaluate("0x1e-5"), 25)        // hex has no exponent: 0x1e - 5
        t.equal(try Formula.evaluate("0xFFFFFFFF"), 4294967295)
        t.equal(try Formula.evaluate("0b0"), 0)
        // Upper-case prefixes and bad digits are not numbers (→ unknown name)
        t.throwsError { _ = try Formula.evaluate("0XF1") }
        t.throwsError { _ = try Formula.evaluate("0B1") }
        t.throwsError { _ = try Formula.evaluate("0b102") }
        t.throwsError { _ = try Formula.evaluate("0o8") }
        t.throwsError { _ = try Formula.evaluate("0x") }
        t.throwsError { _ = try Formula.evaluate("1.2.3") }
        t.throwsError { _ = try Formula.evaluate("2PI") }   // no implicit multiplication
        t.throwsError { _ = try Formula.evaluate("2e") }
    }

    t.suite("Formula: identifiers and lookup") {
        // Names may contain digits, _, ., non-math punctuation and Unicode letters, and may start with a digit.
        let vars: [String: Double] = [
            "Measure_1": 1, "Measure.2": 2, "1stMeasure": 4, "Mesure_é": 8, "测量": 16, "Name!": 32, "@Var$": 64,
        ]
        t.equal(try ev("Measure_1 + Measure.2 + 1stMeasure + Mesure_é + 测量 + Name! + @Var$", vars), 127)
        t.equal(try ev("Measure_1*2", vars), 2)
        t.equal(try ev("(Measure_1)", vars), 1)
        // Calc-only Random / Counter are ordinary names answered by the caller.
        t.equal(try ev("Random * 2", ["random": 21]), 42)
        t.equal(try ev("Counter % 2", ["Counter": 7]), 1)
        // A function name without parentheses is looked up like any name (lenient).
        t.equal(try ev("Round + 1", ["round": 5]), 6)
        // Unknown names are errors.
        t.throwsError { _ = try Formula.evaluate("Missing + 1") }
        t.throwsError { _ = try ev("A + Missing", ["A": 1]) }
        // Unknown function / constant called like a function
        t.throwsError { _ = try CompiledFormula("Foo(1)") }
        t.throwsError { _ = try CompiledFormula("PI(1)") }
        t.throwsError { _ = try CompiledFormula("Measure (1)") }
        // isConstant / identifiers
        t.check(try CompiledFormula("(2.5 + 100) * 2").isConstant)
        t.check(try CompiledFormula("1 ? 2 : 3").isConstant)
        t.check(try !CompiledFormula("x + 1").isConstant)
        t.equal(try CompiledFormula("Sin(PI) + 1").identifiers, [])
        t.equal(try CompiledFormula("Min(A, B) ? C : A").identifiers, ["A", "B", "C"])
        // Compile once, evaluate many times with changing values
        let f = try CompiledFormula("MeasureCPU * 2 + Offset")
        for i in 0..<10 {
            t.equal(try f.evaluate { $0 == "MeasureCPU" ? Double(i) : 1 }, Double(i * 2 + 1))
        }
        t.equal(f.source, "MeasureCPU * 2 + Offset")
    }

    t.suite("Formula: domain problems never crash") {
        t.equal(try Formula.evaluate("1/0"), 0)
        t.equal(try Formula.evaluate("0/0"), 0)
        t.equal(try Formula.evaluate("-1/0"), 0)
        t.equal(try Formula.evaluate("5%0"), 0)
        t.equal(try Formula.evaluate("1/0 + 5"), 5)
        t.equal(try Formula.evaluate("x / y", lookup: { $0 == "x" ? 3 : 0 }), 0)
        // Non-finite final results become 0.
        t.equal(try Formula.evaluate("Exp(1000)"), 0)
        t.equal(try Formula.evaluate("Sqrt(-1)"), 0)
        t.equal(try Formula.evaluate("Log(0)"), 0)
        t.equal(try Formula.evaluate("Ln(-1)"), 0)
        t.equal(try Formula.evaluate("Acos(2)"), 0)
        t.equal(try Formula.evaluate("10**400"), 0)
        t.equal(try Formula.evaluate("x * 2", lookup: { _ in .nan }), 0)
        t.equal(try Formula.evaluate("x", lookup: { _ in .infinity }), 0)
        t.equal(try Formula.evaluate("x & 1", lookup: { _ in .infinity }), 1)
        t.close(try Formula.evaluate("Round(x, 2)", lookup: { _ in 1e300 }), 1e300, accuracy: 1e286)
        t.equal(try Formula.evaluate("Frac(1e300)"), 0)
        t.equal(try Formula.evaluate("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF * 0"), 0)
    }

    t.suite("Formula: syntax errors") {
        let bad = [
            "", "   ", "1 +", "(1", "1)", "* 2", "1 2", "1 ? 2", "1 ? 2 :", "? 1 : 2", "1 : 2",
            "Min(", "Min(1,", "Min(,1)", "Min(1,)", "Min()", "1 ~ 2", "1 +* 2", "a b", "1 **", "1, 2", "()",
            "Min(1)", "Clamp(1,2)", "Clamp(1,2,3,4)", "Atan2(1)", "Cos()", "Cos(1,2)", "Round(1,2,3)",
            "1 ? 2 : 3 : 4", "((1)", "(1))", "&& 1", "1 ||", "=1", "1 <", "1 = = 1", "(,)",
        ]
        for s in bad {
            t.throwsError("\(String(reflecting: s))") { _ = try CompiledFormula(s) }
            t.throwsError("\(String(reflecting: s))") { _ = try Formula.evaluate(s) }
        }
        // Errors carry a message
        do {
            _ = try CompiledFormula("1 +")
            t.check(false, "expected an error")
        } catch let e as FormulaError {
            t.check(!e.message.isEmpty)
            t.check(e.description == e.message)
        }
        // Not operators in Rainmeter formulas: '!' is a name character, so these are unknown names at run time
        t.throwsError { _ = try Formula.evaluate("!1") }
        t.throwsError { _ = try Formula.evaluate("1 != 2") }
    }

    t.suite("Formula: pathological input") {
        // The parser is iterative: any nesting depth works, even on a thread with a small stack.
        var deepResults: [Double?] = []
        let deep: [(String, (String) -> Double?)] = [
            (String(repeating: "(", count: 10_000) + "7" + String(repeating: ")", count: 10_000), { _ in nil }),
            (String(repeating: "-", count: 100_000) + "7", { _ in nil }),
            (String(repeating: "~", count: 10_000) + "7", { _ in nil }),
            (String(repeating: "x**", count: 5_000) + "7", { _ in 1 }),     // 1**(1**(…**7)) = 1
            (String(repeating: "Abs(", count: 5_000) + "-7" + String(repeating: ")", count: 5_000), { _ in nil }),
            (String(repeating: "Min(x, ", count: 5_000) + "7" + String(repeating: ")", count: 5_000), { _ in 9 }),
            (String(repeating: "x ? ", count: 5_000) + "7" + String(repeating: " : 0", count: 5_000), { _ in 1 }),
            (String(repeating: "0 ? 1 : ", count: 5_000) + "7", { _ in nil }),
            (String(repeating: "(x < 0 ? 1 : ", count: 5_000) + "7" + String(repeating: ")", count: 5_000), { _ in 1 }),
            (String(repeating: "1 || 1 && 1 = 1 < 1 | 1 ^ 1 & 1 + 1 * (", count: 2_000) + "x" + String(repeating: ")", count: 2_000), { _ in 7 }),
        ]
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            deepResults = deep.map { src, look in try? CompiledFormula(src).evaluate(look) }
            done.signal()
        }
        thread.stackSize = 256 * 1024
        thread.start()
        done.wait()
        t.equal(deepResults.count, deep.count)
        for (i, r) in deepResults.enumerated() where i != 9 { t.equal(r, i == 3 ? 1 : 7, "deep case \(i)") }
        t.check(deepResults.last.flatMap { $0 } != nil, "deep mixed-operator case evaluates")
        t.equal(try Formula.evaluate(String(repeating: "(", count: 50) + "7" + String(repeating: ")", count: 50)), 7)
        t.equal(try Formula.evaluate(String(repeating: "-", count: 50) + "7"), 7)
        t.equal(try Formula.evaluate(String(repeating: "2**", count: 5_000) + "1"), 0)   // overflows to ∞ → 0
        // Very long flat expressions are fine (evaluation is iterative).
        t.equal(try Formula.evaluate(Array(repeating: "1", count: 20_000).joined(separator: "+")), 20_000)
        let longVar = Array(repeating: "x", count: 20_000).joined(separator: "+")
        t.equal(try Formula.evaluate(longVar, lookup: { _ in 1 }), 20_000)
        t.equal(try Formula.evaluate(Array(repeating: "x", count: 5_000).joined(separator: " - "), lookup: { _ in 1 }), -4_998)
        // Garbage never crashes.
        let junk = [
            "\u{0}", "\u{0}1+1", "1+\u{7}", "💥", "1+💥", "(((", ")))", ",,,", "???", ":::", "#Var#", "[Measure]",
            "\"1\"", "'1'", "1;2", "1\u{00A0}+\u{00A0}2", "\u{FEFF}1", "e", "E+", "1e+", "1e-", ".", "..", "0x.",
            "(1)(2)", "Min(1)(2)", "~", "-", "**", "&&", "||", "<>", "Round(", String(repeating: "?", count: 1000),
        ]
        for s in junk { _ = try? Formula.evaluate(s, lookup: { _ in 1 }) }
        t.equal(try Formula.evaluate("1\u{00A0}+\u{00A0}2"), 3)      // NBSP is whitespace
        // Deterministic fuzz over the formula alphabet.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let alphabet = Array("0123456789.xX+-*/%&|^~=<>?:(),e PIMinaxRoundClamp!#[]é")
        var evaluated = 0
        for _ in 0..<3_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let len = Int(seed >> 58) + 1
            var s = ""
            for _ in 0..<len {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                s.append(alphabet[Int(seed >> 33) % alphabet.count])
            }
            if let v = try? Formula.evaluate(s, lookup: { _ in 2 }) {
                evaluated += 1
                t.check(v.isFinite, "fuzz result must be finite: \(s)")
            }
            _ = Formula.number("(" + s + ")")
            _ = OptionValue.color(s)
            _ = OptionValue.position(s)
            _ = OptionValue.numbers(s)
        }
        t.check(evaluated > 0)
    }

    t.suite("Formula: constant folding matches evaluation") {
        // Folding must respect jump targets: the operands below straddle a conditional.
        for c in [0.0, 1.0] {
            let look: (String) -> Double? = { _ in c }
            let pick = c != 0
            t.equal(try Formula.evaluate("(c ? 1 : 2) + 3", lookup: look), pick ? 4 : 5)
            t.equal(try Formula.evaluate("3 + (c ? 1 : 2)", lookup: look), pick ? 4 : 5)
            t.equal(try Formula.evaluate("-(c ? 1 : 2)", lookup: look), pick ? -1 : -2)
            t.equal(try Formula.evaluate("2 * (c ? 3 : 4) * 5", lookup: look), pick ? 30 : 40)
            t.equal(try Formula.evaluate("Min(c ? 1 : 5, 3)", lookup: look), pick ? 1 : 3)
            t.equal(try Formula.evaluate("Clamp(c ? 100 : -100, 0, 50)", lookup: look), pick ? 50 : 0)
            t.equal(try Formula.evaluate("c ? 2 + 3 : 4 * 5", lookup: look), pick ? 5 : 20)
            t.equal(try Formula.evaluate("(c ? 1 : 2) ? 7 : 8", lookup: look), 7)
            t.equal(try Formula.evaluate("c ? (c ? 1 : 2) + 10 : (c ? 3 : 4) + 20", lookup: look), pick ? 11 : 24)
            t.close(try Formula.evaluate("Round(c ? 1.26 : 2.34, 1) * 10", lookup: look), pick ? 13 : 23, accuracy: 1e-9)
        }
        // Fully constant formulas give the same value as their runtime evaluation.
        let exprs = ["1+2*3-4/5", "2**3**2 % 7", "Min(3, Max(1, 2)) + Clamp(9, 0, 5)", "~5 & 0xFF | 0b1010 ^ 3",
                     "Round(PI * 100) / 100", "(1 < 2) + (2 <> 2) * 10", "-Sqrt(16) + Abs(-2)"]
        for s in exprs {
            let folded = try Formula.evaluate(s)
            let dynamic = try Formula.evaluate(s + " + zero", lookup: { _ in 0 })
            t.equal(folded, dynamic, s)
        }
    }

    t.suite("Formula: number(optionValue)") {
        t.equal(Formula.number("10"), 10)
        t.equal(Formula.number(" -3.5 "), -3.5)
        t.equal(Formula.number("+4"), 4)
        t.equal(Formula.number("\t7\n"), 7)
        t.equal(Formula.number("0"), 0)
        t.equal(Formula.number("-0"), 0)
        t.equal(Formula.number("(21*2)"), 42)                  // (#A#*2) after substitution
        t.equal(Formula.number("( 21 * 2 )"), 42)
        t.equal(Formula.number("  (1+1)  "), 2)
        t.equal(Formula.number("(1/0)"), 0)
        t.equal(Formula.number("(0x10)"), 16)
        t.equal(Formula.number("(1)+(2)"), 3)                  // lenient: starts and ends with a group
        t.equal(Formula.number("(5+5) junk"), 10)              // trailing text after the formula is ignored
        t.equal(Formula.number("(5+5)R"), 10)
        t.equal(Formula.number("12px"), 12)                    // strtod-like prefix
        t.equal(Formula.number("12 ; comment"), 12)
        t.equal(Formula.number("1,5"), 1)
        t.equal(Formula.number("5+5"), 5)                      // not a formula without parentheses
        t.equal(Formula.number(".5"), 0.5)
        t.equal(Formula.number("-.5"), -0.5)
        t.equal(Formula.number("5."), 5)
        t.equal(Formula.number("1e3"), 1000)
        t.equal(Formula.number("1e"), 1)
        t.equal(Formula.number("0x1F"), 31)
        t.equal(Formula.number("0b11"), 3)
        t.equal(Formula.number("0x"), 0)
        t.equal(Formula.number("1.5.3"), 1.5)
        t.equal(Formula.number(""), nil)
        t.equal(Formula.number("   "), nil)
        t.equal(Formula.number("abc"), nil)
        t.equal(Formula.number("-"), nil)
        t.equal(Formula.number("."), nil)
        t.equal(Formula.number("inf"), nil)
        t.equal(Formula.number("nan"), nil)
        t.equal(Formula.number("infinity"), nil)
        t.equal(Formula.number("1e999"), nil)
        t.equal(Formula.number("-(5)"), nil)
        t.equal(Formula.number("("), nil)
        t.equal(Formula.number("(1"), nil)
        t.equal(Formula.number("()"), nil)
        t.equal(Formula.number("(Foo)"), nil)                  // no lookups outside Calc / IfCondition
        t.equal(Formula.number("(Foo) + 1"), nil)
        t.equal(Formula.number("(1 +)"), nil)
        t.equal(Formula.number("#Var#"), nil)
        // Cached results are stable.
        for _ in 0..<3 { t.equal(Formula.number("(6*7)"), 42) }
        for _ in 0..<3 { t.equal(Formula.number("(nope)"), nil) }
    }

    t.suite("Formula: compile cache and threads") {
        let a = try Formula.compile("MeasureA * 3")
        let b = try Formula.compile("MeasureA * 3")
        t.check(a === b, "same source → same compiled instance")
        t.throwsError { _ = try Formula.compile("1 +") }
        t.throwsError { _ = try Formula.compile("1 +") }
        t.equal(try Formula.evaluate("MeasureA * 3", lookup: { _ in 2 }), 6)
        // Many distinct formulas (cache overflow path).
        for i in 0..<3_000 { t.equal(Formula.number("(\(i) + 1)"), Double(i + 1)) }
        // Concurrent use of the caches and of one compiled formula.
        let shared = try CompiledFormula("x * 2 + (x > 5 ? 1 : 0)")
        let lock = NSLock()
        var mismatches = 0
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<2_000 {
                let x = Double((i + worker) % 10)
                let expected = x * 2 + (x > 5 ? 1 : 0)
                let r1 = try? shared.evaluate { _ in x }
                let r2 = try? Formula.evaluate("x * 2 + (x > 5 ? 1 : 0)", lookup: { _ in x })
                let r3 = Formula.number("(\(i % 50) * 2)")
                if r1 != expected || r2 != expected || r3 != Double((i % 50) * 2) {
                    lock.lock(); mismatches += 1; lock.unlock()
                }
            }
        }
        t.equal(mismatches, 0)
    }

    t.suite("Formula: performance smoke test") {
        let f = try CompiledFormula("(MeasureCPU > 50 ? Round(MeasureCPU * 1.5, 1) : Clamp(MeasureCPU, 0, 100)) / 100 + Sin(PI/4)")
        let start = Date()
        var sum = 0.0
        for i in 0..<200_000 { sum += try f.evaluate { _ in Double(i % 100) } }
        let elapsed = Date().timeIntervalSince(start)
        t.check(sum.isFinite)
        t.check(elapsed < 5, "200k evaluations took \(elapsed)s")
        let start2 = Date()
        for _ in 0..<100_000 { _ = Formula.number("(1920 / 2 - 30)") }
        t.check(Date().timeIntervalSince(start2) < 5, "cached Formula.number too slow")
    }

    // ---------------------------------------------------------------------------------------------------------
    // Adversarial review (core/formula-review): regressions for confirmed defects plus corner cases pinned down.

    t.suite("Formula: review — no negative zero results") {
        // IEEE produces -0 here; a String meter would then show "-0". The manual has only one zero.
        for s in ["-0", "Round(-0.4)", "Neg(0)", "0*-1", "Trunc(-0.5)", "Ceil(-0.5)", "Round(-0.0001, 2)", "-0.0 * 5",
                  "(-0)", "Min(-0, 0)", "Clamp(-0.3, 0, 1) * -1", "Frac(-2)", "-(1-1)", "-0 ? 1 : -0"] {
            let v = try Formula.evaluate(s)
            t.equal(v, 0, s)
            t.equal(v.sign, .plus, s)
        }
        for x in [0.0, -0.0] {
            let v = try Formula.evaluate("-x", lookup: { _ in x })
            t.equal(v.sign, .plus, "-x with x = \(x)")
            t.equal(try Formula.evaluate("x * -3", lookup: { _ in x }).sign, .plus)
            t.equal(try Formula.evaluate("x", lookup: { _ in x }).sign, .plus)
        }
        t.equal(try CompiledFormula("Round(-0.4)").evaluate().sign, .plus)     // constant-folded path
        t.equal(try CompiledFormula("Round(x)").evaluate { _ in -0.4 }.sign, .plus)
        for s in ["-0", "-0.0", "-.0", "-0e5", "-0x0", "(-0)", "(0*-1)", "(Round(-0.4))"] {
            t.equal(Formula.number(s)?.sign, .plus, s)
            t.equal(Formula.number(s), 0, s)
        }
        t.equal(Formula.number("-0.5"), -0.5)                                   // real negatives untouched
        t.equal(try Formula.evaluate("Round(-0.6)"), -1)
    }

    t.suite("Formula: review — zero-width characters are whitespace") {
        // U+200B / U+2060 / U+FEFF come in with text copied from web pages; they must not break a formula.
        t.equal(try Formula.evaluate("\u{200B}1 +\u{200B}2\u{FEFF}"), 3)
        t.equal(try Formula.evaluate("\u{FEFF}(2.5 + 100) * 2"), 205)
        t.equal(try Formula.evaluate("Min(\u{2060}1,\u{2060}2)"), 1)
        var seen: [String] = []
        t.equal(try Formula.evaluate("MeasureA\u{200B} * 2", lookup: { seen.append($0); return 21 }), 42)
        t.equal(seen, ["MeasureA"])                                               // not "MeasureA\u{200B}"
        t.equal(Formula.number("\u{FEFF}5"), 5)
        t.equal(Formula.number("5\u{200B}"), 5)
        t.equal(Formula.number("\u{200B}(40 + 2)\u{200B}"), 42)
        t.equal(Formula.number("\u{200B}"), nil)
        // Zero-width joiners stay name characters (they are meaningful inside words of some scripts).
        t.equal(try ev("a\u{200D}b + 1", ["a\u{200D}b": 1]), 2)
        t.throwsError { _ = try CompiledFormula("\u{200B}\u{FEFF}") }            // still an empty formula
    }

    t.suite("Formula: review — operator corner cases") {
        // Precedence / associativity pinned by the judgment-call table in FormulaCompiler.swift.
        t.equal(try Formula.evaluate("2**-2**2"), 0.0625)          // 2 ** (-(2 ** 2))
        t.equal(try Formula.evaluate("-2**-2"), -0.25)             // -(2 ** -2)
        t.equal(try Formula.evaluate("~-1"), 0)
        t.equal(try Formula.evaluate("-~1"), 2)
        t.equal(try Formula.evaluate("1+++1"), 2)
        t.equal(try Formula.evaluate("1 - - - 1"), 0)
        t.equal(try Formula.evaluate("1 < 2 < 3"), 1)              // (1 < 2) < 3
        t.equal(try Formula.evaluate("3 > 2 > 1"), 0)              // (3 > 2) > 1 → 1 > 1
        t.equal(try Formula.evaluate("10 % 3 * 2"), 2)             // left to right
        t.equal(try Formula.evaluate("2 * 10 % 3"), 2)
        t.equal(try Formula.evaluate("0 ? 1 : 2 + 3"), 5)          // the false branch extends to the right
        t.equal(try Formula.evaluate("1 ? 2 : 3 ? 4 : 5"), 2)
        t.equal(try Formula.evaluate("1 | 2 = 3"), 1)              // (1 | 2) = 3
        t.equal(try Formula.evaluate("x--1", lookup: { _ in 1 }), 2)
        t.equal(try Formula.evaluate("x<-1", lookup: { _ in -2 }), 1)
        t.equal(try Formula.evaluate("x<>-1", lookup: { _ in -2 }), 1)
        t.equal(try Formula.evaluate("x**-1", lookup: { _ in 4 }), 0.25)
        t.equal(try Formula.evaluate("x&&-1", lookup: { _ in 1 }), 1)
        // Names vs numbers
        t.equal(try ev("Measure-1", ["Measure": 5]), 4)             // '-' is an operator, not a name character
        t.close(try Formula.evaluate("e-1"), M_E - 1)              // constant E, not an exponent
        t.close(try Formula.evaluate("E**2"), M_E * M_E)
        t.equal(try Formula.evaluate("1.e5"), 100_000)
        t.equal(try Formula.evaluate("1.5E+3"), 1500)
        t.equal(try ev("5.x", ["5.x": 9]), 9)                       // a word that is not exactly a number is a name
        t.throwsError { _ = try Formula.evaluate("0x1.5") }         // unknown name, hex has no fraction
        t.throwsError { _ = try Formula.evaluate("1.5e+3x") }
        t.throwsError { _ = try CompiledFormula("1 => 2") }         // only <= and >= exist
        t.throwsError { _ = try CompiledFormula("1 =< 2") }
        t.throwsError { _ = try CompiledFormula("Min(1,2,)") }
        t.throwsError { _ = try CompiledFormula("(1)(2)") }
        t.throwsError { _ = try Formula.evaluate("5;") }            // no inline comments: "5;" is an unknown name
        // Domain corner cases
        t.equal(try Formula.evaluate("(-8)**(1/3)"), 0)            // NaN → 0
        t.equal(try Formula.evaluate("0**0"), 1)
        t.equal(try Formula.evaluate("0**-1"), 0)                  // ∞ → 0
        t.equal(try Formula.evaluate("5 % 2.5"), 0)
        t.equal(try Formula.evaluate("Atan2(0, 0)"), 0)
        t.equal(try Formula.evaluate("Clamp(5, 10, 0)"), 0)        // low > high: high wins
        t.equal(try Formula.evaluate("Max(0/0, 1)"), 1)            // 0/0 is 0 here
        t.equal(try Formula.evaluate("1e19 | 0"), Double(Int64.max))   // saturates
        t.equal(try Formula.evaluate("-1e19 & -1"), Double(Int64.min))
        t.equal(try Formula.evaluate("Round(123.456, -1)"), 120)
        t.equal(try Formula.evaluate("Round(-123.456, 1)"), -123.5)
        t.equal(try Formula.evaluate("Exp(1000) > 5"), 1)          // ∞ only becomes 0 at the very end
    }

    t.suite("Formula: review — huge operand stacks on a small thread") {
        // The operand stack of `x+(x+(x+(…)))` is as deep as the nesting; it must not overflow a GCD-sized thread
        // stack (the VM's temporary buffer falls back to the heap).
        let n = 100_000
        let right = String(repeating: "x+(", count: n) + "x" + String(repeating: ")", count: n)
        let left = String(repeating: "(", count: n) + "1" + String(repeating: "+x)", count: n)
        var results: [Double?] = []
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            results = [right, left].map { src in try? CompiledFormula(src).evaluate { _ in 1 } }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        t.equal(results, [Double(n + 1), Double(n + 1)])
    }

    t.suite("Formula: review — differential fuzz against expression trees") {
        // Random expression trees are evaluated directly and compared with the compiled formula, rendered both with
        // minimal parentheses (per the precedence table in FormulaCompiler.swift) and fully parenthesized, with and
        // without spaces. Catches precedence, associativity, lexing and constant-folding bugs.
        indirect enum Node {
            case num(Double, String), name(String)
            case unary(FormulaUnary, String, Node)
            case binary(FormulaBinary, String, Int, Node, Node)
            case cond(Node, Node, Node)
            case call(String, [Node])
        }
        let binaries: [(FormulaBinary, String, Int)] = [
            (.logicalOr, "||", 1), (.logicalAnd, "&&", 2), (.equal, "=", 3), (.notEqual, "<>", 3),
            (.less, "<", 4), (.greater, ">", 4), (.lessEqual, "<=", 4), (.greaterEqual, ">=", 4),
            (.bitOr, "|", 5), (.bitXor, "^", 6), (.bitAnd, "&", 7), (.add, "+", 8), (.subtract, "-", 8),
            (.multiply, "*", 9), (.divide, "/", 9), (.remainder, "%", 9), (.power, "**", 11),
        ]
        let arities: [(String, Int)] = [("Min", 2), ("Min", 3), ("Max", 2), ("Clamp", 3), ("Round", 1), ("Round", 2),
                                        ("Abs", 1), ("Sgn", 1), ("Floor", 1), ("Frac", 1), ("Atan2", 2), ("Neg", 1)]
        let vars: [String: Double] = ["x": 3, "y": -2.5, "z": 0]
        var seed: UInt64 = 0x5EED_F00D
        func rnd(_ k: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(k))
        }
        func gen(_ depth: Int) -> Node {
            if depth <= 0 || rnd(4) == 0 {
                switch rnd(4) {
                case 0: return .name(["x", "y", "z"][rnd(3)])
                case 1: return .num(Double.pi, ["PI", "pi"][rnd(2)])
                default:
                    let v = Double(rnd(20)) / Double([1, 2, 4][rnd(3)])
                    return .num(v, "\(v)")
                }
            }
            switch rnd(10) {
            case 0: return rnd(2) == 0 ? .unary(.negate, "-", gen(depth - 1)) : .unary(.bitNot, "~", gen(depth - 1))
            case 1: return .cond(gen(depth - 1), gen(depth - 1), gen(depth - 1))
            case 2:
                let (fn, argc) = arities[rnd(arities.count)]
                return .call(fn, (0..<argc).map { _ in gen(depth - 1) })
            default:
                let (op, sym, p) = binaries[rnd(binaries.count)]
                return .binary(op, sym, p, gen(depth - 1), gen(depth - 1))
            }
        }
        func precedence(_ n: Node) -> Int {
            switch n {
            case .binary(_, _, let p, _, _): return p
            case .unary: return 10
            case .cond: return 0
            default: return 100
            }
        }
        func render(_ n: Node, full: Bool) -> String {
            func sub(_ c: Node, _ needParens: Bool) -> String {
                let s = render(c, full: full)
                return needParens || full ? "(" + s + ")" : s
            }
            switch n {
            case .num(_, let s), .name(let s): return s
            case .unary(_, let sym, let a): return sym + sub(a, precedence(a) < 10)
            case .binary(let op, let sym, let p, let a, let b):
                if op == .power { // right-associative; a unary operand on the right needs no parentheses
                    return sub(a, precedence(a) <= p) + " " + sym + " " + sub(b, precedence(b) < p && precedence(b) != 10)
                }
                return sub(a, precedence(a) < p) + " " + sym + " " + sub(b, precedence(b) <= p)
            case .cond(let c, let a, let b): return sub(c, precedence(c) <= 0) + " ? " + sub(a, false) + " : " + sub(b, false)
            case .call(let fn, let args): return fn + "(" + args.map { render($0, full: full) }.joined(separator: ", ") + ")"
            }
        }
        func value(_ n: Node) -> Double {
            switch n {
            case .num(let v, _): return v
            case .name(let s): return vars[s] ?? .nan
            case .unary(let op, _, let a): return FormulaMath.apply(op, value(a))
            case .binary(let op, _, _, let a, let b): return FormulaMath.apply(op, value(a), value(b))
            case .cond(let c, let a, let b): return FormulaMath.truthy(value(c)) ? value(a) : value(b)
            case .call(let fn, let args):
                let v = args.map(value)
                switch (fn, v.count) {
                case ("Min", _): return v.dropFirst().reduce(v[0]) { FormulaMath.apply(.min, $0, $1) }
                case ("Max", _): return FormulaMath.apply(.max, v[0], v[1])
                case ("Clamp", _): return FormulaMath.clamp(v[0], v[1], v[2])
                case ("Round", 1): return FormulaMath.apply(.round, v[0])
                case ("Round", _): return FormulaMath.apply(.round, v[0], v[1])
                case ("Abs", _): return FormulaMath.apply(.abs, v[0])
                case ("Sgn", _): return FormulaMath.apply(.sgn, v[0])
                case ("Floor", _): return FormulaMath.apply(.floor, v[0])
                case ("Frac", _): return FormulaMath.apply(.frac, v[0])
                case ("Neg", _): return FormulaMath.apply(.neg, v[0])
                default: return FormulaMath.apply(.atan2, v[0], v[1])
                }
            }
        }
        var mismatches = 0
        for _ in 0..<8_000 {
            let tree = gen(1 + rnd(6))
            let expected = FormulaMath.finite(value(tree))
            for full in [false, true] {
                var src = render(tree, full: full)
                if rnd(2) == 0 { src = src.replacingOccurrences(of: " ", with: "") }
                let got = try? Formula.evaluate(src, lookup: { vars[$0] })
                if got != expected {
                    mismatches += 1
                    if mismatches <= 5 { t.check(false, "\(src): got \(String(describing: got)), expected \(expected)") }
                }
            }
        }
        t.equal(mismatches, 0)
    }

    t.suite("Formula: review — Round(x, n) is correctly rounded") {
        // The naive (x * 10^n).rounded() / 10^n got these wrong.
        t.equal(try Formula.evaluate("Round(4281.6, 12)"), 4281.6)                       // was 4281.600000000001
        t.equal(try Formula.evaluate("Round(-4281.6, 12)"), -4281.6)
        t.equal(try Formula.evaluate("Round(484624701830849.06, 4)"), 484624701830849.06) // was …849.0
        t.equal(try Formula.evaluate("Round(484624701830849.06, 1)"), 484624701830849.1)
        t.equal(try Formula.evaluate("Round(206860.1367234787, 11)"), 206860.1367234787)  // was …873
        t.equal(try Formula.evaluate("Round(1.23456789e-10, 16)"), 1.234568e-10)          // was unchanged (n > 15)
        t.equal(try Formula.evaluate("Round(x, 6)", lookup: { _ in 13_385_402_096.123456 }), 13_385_402_096.123456)
        // Half away from zero on exact ties, both directions and signs.
        t.equal(try Formula.evaluate("Round(0.125, 2)"), 0.13)
        t.equal(try Formula.evaluate("Round(-0.125, 2)"), -0.13)
        t.equal(try Formula.evaluate("Round(1250, -2)"), 1300)
        t.equal(try Formula.evaluate("Round(-1250, -2)"), -1300)
        t.equal(try Formula.evaluate("Round(1249.999, -2)"), 1200)
        t.equal(try Formula.evaluate("Round(2.5)"), 3)
        // Decimal-looking ties follow the binary value (like C/Python): 1.005 is 1.00499999999999989…
        t.equal(try Formula.evaluate("Round(1.005, 2)"), 1)
        t.equal(try Formula.evaluate("Round(7288733010700.795, 2)"), 7_288_733_010_700.79)
        // Extremes never trap or produce non-finite values.
        t.equal(try Formula.evaluate("Round(123.456, 400)"), 123.456)
        t.equal(try Formula.evaluate("Round(123.456, -400)"), 0)
        t.equal(try Formula.evaluate("Round(1e300, -2)"), 1e300)
        t.equal(FormulaMath.round(1.7976931348623157e308, decimals: -308), 1.7976931348623157e308) // 2e308 overflows
        t.equal(FormulaMath.round(-1.7976931348623157e308, decimals: -307), -1.7976931348623157e308) // -1.8e308 too
        t.equal(FormulaMath.round(1.7976931348623157e308, decimals: -306), 1.7976931348623157e308) // 180e306 too
        t.equal(try Formula.evaluate("Round(1e-300, 305)"), 1e-300)
        t.equal(try Formula.evaluate("Round(x, 1/0)", lookup: { _ in 2.5 }), 3)            // 1/0 is 0 here
        t.equal(try Formula.evaluate("Round(x, y)", lookup: { $0 == "x" ? 2.25 : .infinity }), 2.25)
        t.equal(try Formula.evaluate("Round(x, y)", lookup: { $0 == "x" ? 2.25 : -.infinity }), 0)
        t.equal(try Formula.evaluate("Round(x, y)", lookup: { $0 == "x" ? 2.25 : .nan }), 2)

        // Property check against references computed from exact decimal expansions.
        var seed: UInt64 = 0xC0FFEE
        func bits() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 11 // high bits only: an LCG's low bits have tiny periods
        }
        func randomValue() -> Double {
            let exponent = Double(Int(bits() % 26)) - 6
            var x = Double(bits()) / 9_007_199_254_740_992 * Foundation.pow(10, exponent)
            if bits() % 2 == 0 { let d = Foundation.pow(10, Double(bits() % 6)); x = (x * d).rounded() / d }
            if bits() % 8 == 0 { x = Double(bits() % 4096) / 64 }        // exact binary ties such as 0.125
            return bits() % 2 == 0 ? x : -x
        }
        /// Decimal digits of |x| (exact: every binary fraction has a terminating decimal expansion).
        func exactDigits(_ x: Double) -> (int: [UInt8], frac: [UInt8]) {
            let s = String(format: "%.100f", Swift.abs(x))
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            return (Array(parts[0].utf8).map { $0 - 48 }, parts.count > 1 ? Array(parts[1].utf8).map { $0 - 48 } : [])
        }
        /// Reference: round the exact decimal expansion half away from zero to n decimals (n may be negative).
        func reference(_ x: Double, _ n: Int) -> Double {
            let (ip, fp) = exactDigits(x)
            var digits = ip + fp                          // all digits, the decimal point after ip.count
            let keep = ip.count + n                       // digits kept
            if keep < 0 { return 0 }
            let roundUp = keep < digits.count && digits[keep] >= 5
            digits = Array(digits.prefix(keep))
            if digits.isEmpty { digits = [0] }
            if roundUp {
                var i = digits.count - 1
                while i >= 0 { if digits[i] == 9 { digits[i] = 0; i -= 1 } else { digits[i] += 1; break } }
                if i < 0 { digits.insert(1, at: 0) }
            }
            var text = String(decoding: digits.map { $0 + 48 }, as: UTF8.self)
            if n < 0 {
                text += String(repeating: "0", count: -n)
            } else {
                let intCount = text.count - n             // the carry may have added a leading digit
                text = String(text.prefix(intCount)) + "." + String(text.suffix(n))
            }
            let value = Double(text) ?? .nan               // decimal → Double conversion is correctly rounded
            return x < 0 ? -value : value
        }
        var wrong = 0
        for _ in 0..<20_000 {
            let x = randomValue()
            let n = Int(bits() % 27) - 11             // -11 … 15
            guard Swift.abs(x) < 1e18, n != 0 else { continue }
            let got = FormulaMath.round(x, decimals: Double(n))
            let want = reference(x, n)
            if got != want && !(got == 0 && want == 0) {
                wrong += 1
                if wrong <= 5 { t.check(false, "Round(\(x), \(n)) = \(got), expected \(want)") }
            }
        }
        t.equal(wrong, 0)
    }
}
