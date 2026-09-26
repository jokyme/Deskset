import Foundation

// Text handling for the WebParser measure (manual: https://docs.rainmeter.net/manual/measures/webparser/,
// options CodePage, DecodeCharacterReference, DecodeCodePoints). Pure functions, safe on any thread.

enum WebParserText {
    // MARK: - CodePage

    /// Decodes a downloaded resource.
    ///
    /// Manual (CodePage, "Unicode in Rainmeter"): UTF-8 is the default for web pages and files; `CodePage=1200` reads
    /// UTF-16 LE, `1252` Western, `1251` Cyrillic, `28605` ISO 8859-15, `65001` UTF-8 and so on (Windows code page
    /// identifiers).
    ///
    /// Judgment calls:
    /// - `CodePage=0` (default) is more forgiving than "always UTF-8": a byte-order mark wins, then valid UTF-8, then —
    ///   only for bytes that are not valid UTF-8 — the `charset` of the HTTP `Content-Type` header, then the skin text
    ///   decoder's ANSI fallback (`TextDecoding`). A page that is valid UTF-8 always decodes as UTF-8.
    /// - An explicit code page that Foundation does not know, or bytes that are invalid in it, fall back to the
    ///   automatic detection instead of producing nothing. A leading byte-order mark is never part of the text.
    static func decode(_ data: Data, codePage: Int, charset: String? = nil) -> String {
        switch codePage {
        case 0:
            break
        case 1200:
            return stripBOM(utf16(data, bigEndian: false))
        case 1201:
            return stripBOM(utf16(data, bigEndian: true))
        case 65001:
            return stripBOM(String(decoding: data, as: UTF8.self))
        case 12000, 12001:
            if let s = String(data: data, encoding: codePage == 12000 ? .utf32LittleEndian : .utf32BigEndian) {
                return stripBOM(s)
            }
        default:
            if let encoding = encoding(forCodePage: codePage), let s = String(data: data, encoding: encoding) {
                return stripBOM(s)
            }
        }
        let detected = TextDecoding.decodeDetectingEncoding(data)
        switch detected.encoding {
        case .windows1252, .windowsCodePage:
            if let charset, let encoding = encoding(forCharset: charset), encoding != .utf8,
               let s = String(data: data, encoding: encoding) {
                return stripBOM(s)
            }
        default:
            break
        }
        return stripBOM(detected.text)
    }

    /// Foundation encoding for a Windows code page identifier, or nil.
    static func encoding(forCodePage codePage: Int) -> String.Encoding? {
        guard codePage > 0, codePage <= 65535 else { return nil }
        let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Foundation encoding for an IANA charset name (`Content-Type: text/html; charset=…`), or nil.
    static func encoding(forCharset charset: String) -> String.Encoding? {
        let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        guard !name.isEmpty, name.count < 64 else { return nil }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static func utf16(_ data: Data, bigEndian: Bool) -> String {
        let count = data.count / 2
        guard count > 0 else { return "" }
        var units = [UInt16](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for k in 0..<count {
                let a = UInt16(raw[2 * k]), b = UInt16(raw[2 * k + 1])
                units[k] = bigEndian ? (a << 8 | b) : (b << 8 | a)
            }
        }
        return String(decoding: units, as: UTF16.self)  // lone surrogates become U+FFFD
    }

    private static func stripBOM(_ s: String) -> String {
        guard s.unicodeScalars.first == "\u{FEFF}" else { return s }
        return String(s.unicodeScalars.dropFirst())
    }

    // MARK: - DecodeCharacterReference

    /// `DecodeCharacterReference`: 0 nothing, 1 numeric and entity references, 2 numeric only, 3 entities only.
    ///
    /// Manual: decodes references "like &quot;, &amp;, &lt;, and &gt;". Judgment calls: one left-to-right pass (so
    /// `&amp;lt;` becomes `&lt;`, not `<`); a reference must end with `;`; entity names are the HTML 4 set plus
    /// `&apos;`, case-sensitive as in HTML; numeric references are `&#NNN;` and `&#xHHH;` — 0, surrogates and values
    /// above U+10FFFF are left as written, and 128…159 are read as Windows-1252 (as browsers do, so `&#146;` is ’).
    static func decodeCharacterReferences(_ text: String, mode: Int) -> String {
        guard mode >= 1, mode <= 3, text.contains("&") else { return text }
        let numeric = mode != 3, named = mode != 2
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "&" {
                var j = i + 1
                while j < s.count, j - i <= 34, s[j] != ";", s[j] != "&" { j += 1 }
                if j < s.count, s[j] == ";", j > i + 1 {
                    let body = s[(i + 1)..<j]
                    if body.first == "#" {
                        if numeric, let scalar = numericReference(body.dropFirst()) {
                            out.append(scalar)
                            i = j + 1
                            continue
                        }
                    } else if named, let scalar = WebParserEntities.table[String(String.UnicodeScalarView(body))] {
                        out.append(scalar)
                        i = j + 1
                        continue
                    }
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    private static func numericReference(_ digits: ArraySlice<Unicode.Scalar>) -> Unicode.Scalar? {
        var body = digits
        var radix: UInt32 = 10
        if let first = body.first, first == "x" || first == "X" {
            radix = 16
            body = body.dropFirst()
        }
        guard !body.isEmpty, body.count <= 8 else { return nil }
        var value: UInt32 = 0
        for c in body {
            guard let d = hexValue(c), d < radix else { return nil }
            value = value * radix + d
        }
        if value >= 0x80, value <= 0x9F, let mapped = cp1252Controls[Int(value - 0x80)] {
            return Unicode.Scalar(mapped)
        }
        guard value != 0, value <= 0x10FFFF else { return nil }
        return Unicode.Scalar(value)  // nil for surrogates
    }

    /// Windows-1252 characters for 0x80…0x9F (nil where 1252 is undefined).
    private static let cp1252Controls: [UInt32?] = [
        0x20AC, nil, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, nil,
        0x017D, nil, nil, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
        0x0153, nil, 0x017E, 0x0178,
    ]

    private static func hexValue(_ c: Unicode.Scalar) -> UInt32? {
        switch c.value {
        case 0x30...0x39: return c.value - 0x30
        case 0x41...0x46: return c.value - 0x41 + 10
        case 0x61...0x66: return c.value - 0x61 + 10
        default: return nil
        }
    }

    // MARK: - DecodeCodePoints

    /// `DecodeCodePoints=1`: `\uXXXX` (exactly four hex digits) and `\UXXXXXXXX` (eight) become the character.
    ///
    /// Manual: "Codes from \u0000 to ￿ are supported". Judgment calls: a UTF-16 surrogate pair written as two
    /// escapes (`😀`, as JSON does) becomes one character; a lone surrogate, `\u0000` and anything that is
    /// not a valid scalar stay as written; `\U` also accepts code points above U+FFFF.
    static func decodeCodePoints(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func hex(at start: Int, count: Int) -> UInt32? {
            guard start + count <= s.count else { return nil }
            var v: UInt32 = 0
            for k in start..<(start + count) {
                guard let d = hexValue(s[k]) else { return nil }
                v = v << 4 | d
            }
            return v
        }
        while i < s.count {
            if s[i] == "\\", i + 1 < s.count {
                let kind = s[i + 1]
                if kind == "u", let v = hex(at: i + 2, count: 4) {
                    if v >= 0xD800, v <= 0xDBFF, i + 12 <= s.count, s[i + 6] == "\\", s[i + 7] == "u",
                       let low = hex(at: i + 8, count: 4), low >= 0xDC00, low <= 0xDFFF,
                       let scalar = Unicode.Scalar(0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)) {
                        out.append(scalar)
                        i += 12
                        continue
                    }
                    if v != 0, let scalar = Unicode.Scalar(v) {
                        out.append(scalar)
                        i += 6
                        continue
                    }
                } else if kind == "U", let v = hex(at: i + 2, count: 8), v != 0, let scalar = Unicode.Scalar(v) {
                    out.append(scalar)
                    i += 10
                    continue
                }
            }
            out.append(s[i])
            i += 1
        }
        return String(out)
    }

    // MARK: - Number value

    /// The number value of a WebParser string: its leading decimal number (`"23"` → 23, `" -4.5°C"` → -4.5,
    /// `"1e3 m"` → 1000), or 0 when it does not start with one.
    ///
    /// Judgment call: the manual does not say how a WebParser string becomes a number; reading the leading number
    /// (like C's `strtod`) makes values such as `23°` usable in formulas and bars. Hex, `inf` and `nan` are not read.
    static func leadingNumber(_ text: String) -> Double {
        var bytes: [UInt8] = []
        var it = text.utf8.makeIterator()
        var c = it.next()
        while let b = c, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { c = it.next() }
        if let b = c, b == 0x2B || b == 0x2D {  // + -
            bytes.append(b)
            c = it.next()
        }
        var digits = 0
        func isDigit(_ b: UInt8?) -> Bool { b.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
        while isDigit(c), bytes.count < 400, let b = c {
            bytes.append(b)
            digits += 1
            c = it.next()
        }
        if c == 0x2E {  // .
            var fraction: [UInt8] = [0x2E]
            c = it.next()
            while isDigit(c), bytes.count + fraction.count < 400, let b = c {
                fraction.append(b)
                digits += 1
                c = it.next()
            }
            if fraction.count > 1 || digits > 0 { bytes += fraction }
        }
        guard digits > 0 else { return 0 }
        if let e = c, e == 0x65 || e == 0x45 {  // e E
            var exponent: [UInt8] = [e]
            c = it.next()
            if let b = c, b == 0x2B || b == 0x2D {
                exponent.append(b)
                c = it.next()
            }
            var expDigits = 0
            while isDigit(c), expDigits < 5, let b = c {
                exponent.append(b)
                expDigits += 1
                c = it.next()
            }
            if expDigits > 0 { bytes += exponent }
        }
        guard let v = Double(String(decoding: bytes, as: UTF8.self)), v.isFinite else { return 0 }
        return v
    }
}
