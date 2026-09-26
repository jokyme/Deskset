import Foundation

// Uptime measure formatting. Clean-room implementation from the public manual only:
//   https://docs.rainmeter.net/manual/measures/uptime/
// Every place where the manual is silent is marked "Judgment:".

public enum UptimeFormatting {
    /// The manual: "Format Default: %4!i!d %3!i!:%2!02i!".
    public static let defaultFormat = "%4!i!d %3!i!:%2!02i!"

    /// Formats an Uptime measure value. `format` uses Windows FormatMessage-style inserts:
    /// `%4` days, `%3` hours, `%2` minutes, `%1` seconds, each optionally with a printf spec `%3!02i!`.
    /// Default format: `%4!i!d %3!i!:%2!02i!`. `addDaysToHours` = the `AddDaysToHours` option.
    ///
    /// Manual rules: `!i!` shows the number without leading zeros, `!02i!` pads with zeros to the given total
    /// length. "AddDaysToHours Default: 1 — If set to 1 and if %4 (days) is not used in the Format option, %3
    /// (hours) is incremented by days * 24." (so with 0 and no `%4`, the whole days are simply not shown).
    ///
    /// Judgment calls (manual silent):
    /// - The parameter default is `true`, matching the manual's `AddDaysToHours` default of 1.
    /// - Other printf specs work as in C for an integer argument: flags `-+ #0`, width, `.precision`,
    ///   size prefixes (`l`, `ll`, `h`, `I64`, …) ignored, conversions `d i u` decimal, `x X o` radix,
    ///   `c` a character, `s` decimal text, `e f g a` (any case) the value as a floating-point number.
    ///   Width / precision are capped at 64. An insert without a spec prints like `!i!`. A malformed spec
    ///   (no closing `!` or an unknown conversion) is ignored and its text is output literally.
    /// - `%%` is a literal `%`; a `%` not followed by `1`…`4` or `%` is output as is (`100%`, `%5`).
    ///   Only one digit is read, so `%10` is `%1` followed by `0`.
    /// - `seconds` is floored; negative, NaN or infinite values count as 0; minutes and seconds are always
    ///   0…59 (only days are folded into hours).
    public static func format(seconds: Double, format: String = "%4!i!d %3!i!:%2!02i!", addDaysToHours: Bool = true) -> String {
        let total: Int64
        if seconds.isFinite, seconds > 0 {
            total = Int64(min(seconds, 1e15).rounded(.down))
        } else {
            total = 0
        }
        let tokens = parse(format)
        let usesDays = tokens.contains { if case .insert(4, _) = $0 { return true } else { return false } }
        let days = total / 86_400
        var hours = (total / 3_600) % 24
        if addDaysToHours && !usesDays { hours += days * 24 }
        let values: [Int64] = [total % 60, (total / 60) % 60, hours, days]   // %1 … %4

        var out = ""
        out.reserveCapacity(format.utf8.count + 8)
        for token in tokens {
            switch token {
            case .literal(let s): out += s
            case .insert(let n, let spec):
                let v = values[n - 1]
                if let spec { out += spec.render(v) } else { out += String(v) }
            }
        }
        return out
    }

    // MARK: - Parsing

    enum Token: Equatable {
        case literal(String)
        case insert(Int, PrintfSpec?)
    }

    static func parse(_ format: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        let chars = Array(format.unicodeScalars)
        var i = 0
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }
        while i < chars.count {
            let c = chars[i]
            guard c == "%", i + 1 < chars.count else {
                literal.unicodeScalars.append(c)
                i += 1
                continue
            }
            let next = chars[i + 1]
            if next == "%" {
                literal.append("%")
                i += 2
                continue
            }
            guard let n = Int(String(next)), (1...4).contains(n) else {
                literal.unicodeScalars.append(c)
                i += 1
                continue
            }
            i += 2
            var spec: PrintfSpec?
            if i < chars.count, chars[i] == "!" {
                // Find the closing '!' (bounded).
                var j = i + 1
                while j < chars.count, j - i <= 24, chars[j] != "!" { j += 1 }
                if j < chars.count, chars[j] == "!" {
                    var body = ""
                    body.unicodeScalars.append(contentsOf: chars[(i + 1)..<j])
                    if let parsed = PrintfSpec(body) {
                        spec = parsed
                        i = j + 1
                    }
                }
            }
            flush()
            tokens.append(.insert(n, spec))
        }
        flush()
        return tokens
    }

    /// A validated printf conversion spec for one integer argument (`02i`, `-5d`, `x`, …).
    struct PrintfSpec: Equatable {
        var flags: String
        var width: Int?
        var precision: Int?
        var conversion: Character

        init?(_ body: String) {
            var s = Substring(body)
            var flags = ""
            while let c = s.first, "-+ #0".contains(c) {
                if !flags.contains(c) { flags.append(c) }
                s.removeFirst()
            }
            var widthText = ""
            while let c = s.first, c.isASCII, c.isNumber { widthText.append(c); s.removeFirst() }
            var precision: Int?
            if s.first == "." {
                s.removeFirst()
                var p = ""
                while let c = s.first, c.isASCII, c.isNumber { p.append(c); s.removeFirst() }
                precision = min(Int(p) ?? 0, 64)
            }
            // Size prefixes are irrelevant here (the value is always formatted as a 64-bit integer).
            for prefix in ["I64", "I32", "ll", "hh", "l", "h", "I", "j", "z", "t", "L", "w"] where s.hasPrefix(prefix) {
                s.removeFirst(prefix.count)
                break
            }
            guard s.count == 1, let conv = s.first, "diuxXocsfFeEgGaA".contains(conv) else { return nil }
            self.flags = flags
            self.width = widthText.isEmpty ? nil : min(Int(widthText) ?? 0, 64)
            self.precision = precision
            self.conversion = conv
        }

        func render(_ value: Int64) -> String {
            switch conversion {
            case "c":
                let ch = UnicodeScalar(UInt32(clamping: value)).map { String(Character($0)) } ?? ""
                return pad(ch)
            case "s":
                var text = String(value)
                if let precision, precision < text.count { text = String(text.prefix(precision)) }
                return pad(text)
            default:
                break
            }
            var spec = "%" + flags
            if let width { spec += String(width) }
            if let precision { spec += "." + String(precision) }
            switch conversion {
            case "d", "i": return cFormat(spec + "lld", value)
            case "u": return cFormat(spec + "llu", value)
            case "x", "X", "o": return cFormat(spec + "ll" + String(conversion), value)
            default: return cFormat(spec + String(conversion), Double(value))
            }
        }

        private func pad(_ s: String) -> String {
            guard let width, s.count < width else { return s }
            let padding = String(repeating: " ", count: width - s.count)
            return flags.contains("-") ? s + padding : padding + s
        }

        /// `spec` is built from validated pieces only, so it always holds exactly one conversion for `arg`.
        private func cFormat(_ spec: String, _ arg: CVarArg) -> String {
            String(format: spec, arg)
        }
    }
}
