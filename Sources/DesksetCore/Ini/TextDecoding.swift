import Foundation

/// The byte encoding of a skin text file, as detected by `TextDecoding.decodeDetectingEncoding`.
public enum TextFileEncoding: Equatable {
    case utf8(bom: Bool)
    case utf16LittleEndian(bom: Bool)
    case utf16BigEndian(bom: Bool)
    /// UTF-32 is only recognised with a BOM, and is written back with one.
    case utf32LittleEndian
    case utf32BigEndian
    /// Legacy Windows "ANSI" (code page 1252). Decoding is byte-transparent: the five bytes 1252 leaves undefined
    /// (0x81, 0x8D, 0x8F, 0x90, 0x9D) become U+0081… so that re-encoding reproduces the original bytes.
    case windows1252
    /// Another legacy Windows "ANSI" code page (e.g. 936 = GBK, 950 = Big5, 932 = Shift-JIS, 1251 = Cyrillic): used
    /// for a non-Unicode file when `TextDecoding.ansiCodePage` names it and the file decodes (and re-encodes)
    /// losslessly with it; otherwise such a file falls back to `.windows1252`.
    case windowsCodePage(Int)
}

/// Decodes skin text files. Rainmeter skins are commonly UTF-16 LE with BOM, UTF-8 (with or without BOM)
/// or legacy ANSI. Detection order:
/// UTF-32 BOM → UTF-8 BOM → UTF-16 BOM → BOM-less UTF-16 (zero-byte heuristic) → valid UTF-8 → the ANSI code page
/// (`ansiCodePage`, when it is not 1252 and decodes the file losslessly) → Windows-1252.
/// Decoding never fails: malformed UTF-16/UTF-32 units become U+FFFD instead of losing the whole file.
///
/// ANSI: the manual ("Unicode in Rainmeter", docs.rainmeter.net/tips/unicode-in-rainmeter/) says the extended
/// characters of an ANSI file are "based on the Windows Codepage (locale) active in your Windows system" —
/// Windows-1252 in the US / Western Europe, Windows-1251 with a Russian locale, and so on. The macOS equivalent of the
/// Windows locale is the user's preferred language (`defaultANSICodePage()`); once the app sets `ansiCodePage` from it,
/// e.g. a GBK-encoded skin from a Chinese author reads correctly for a Chinese user, exactly as it would in Rainmeter
/// on a Chinese Windows. Valid UTF-8 is still preferred (a leniency: Rainmeter itself cannot read UTF-8 without BOM,
/// but such files are common, and DBCS text is practically never valid UTF-8 by accident).
public enum TextDecoding {
    /// The Windows "ANSI" code page used for legacy (non-Unicode, non-UTF-8) files. The default, 1252, keeps the core
    /// deterministic (tests and tools behave the same on every Mac). The app should set it once at startup, before
    /// loading skins, to the code page of the user's language:
    ///
    ///     TextDecoding.ansiCodePage = TextDecoding.defaultANSICodePage()
    ///
    /// Not synchronised: set it before any concurrent decoding starts.
    public static var ansiCodePage: Int = 1252

    /// The Windows system ANSI code page for a language list (the first entry decides), e.g. `zh-Hans` → 936,
    /// `zh-Hant` → 950, `ja` → 932, `ko` → 949, `ru` → 1251, `pl` → 1250, `el` → 1253, `tr` → 1254, `he` → 1255,
    /// `ar` → 1256, `lt` → 1257, `vi` → 1258, `th` → 874; anything else → 1252.
    public static func defaultANSICodePage(preferredLanguages: [String] = Locale.preferredLanguages) -> Int {
        guard let first = preferredLanguages.first else { return 1252 }
        let parts = first.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let language = parts.first else { return 1252 }
        let subtags = Set(parts.dropFirst())
        switch language {
        case "zh":
            if subtags.contains("hant") { return 950 }
            if subtags.contains("hans") { return 936 }
            return subtags.contains("tw") || subtags.contains("hk") || subtags.contains("mo") ? 950 : 936
        case "ja": return 932
        case "ko": return 949
        case "th": return 874
        case "vi": return 1258
        case "sr": return subtags.contains("latn") ? 1250 : 1251 // Serbian defaults to Cyrillic script
        case "bs": return subtags.contains("cyrl") ? 1251 : 1250
        case "ru", "uk", "be", "bg", "mk", "kk", "ky", "mn", "tt", "tg", "ba": return 1251
        case "pl", "cs", "sk", "hu", "hr", "sl", "ro", "sq", "hsb", "dsb": return 1250
        case "el": return 1253
        case "tr", "az", "uz": return subtags.contains("cyrl") ? 1251 : 1254
        case "he", "yi": return 1255
        case "ar", "fa", "ur", "ps", "ug", "sd", "ckb": return 1256
        case "et", "lv", "lt": return 1257
        default: return 1252
        }
    }

    public static func decode(_ data: Data) -> String {
        decodeDetectingEncoding(data).text
    }

    public static func readFile(at url: URL) throws -> String {
        decode(try Data(contentsOf: url))
    }

    /// Reads a file and reports the encoding it was decoded from (used to write it back unchanged).
    public static func readFileDetectingEncoding(at url: URL) throws -> (text: String, encoding: TextFileEncoding) {
        decodeDetectingEncoding(try Data(contentsOf: url))
    }

    public static func decodeDetectingEncoding(_ data: Data) -> (text: String, encoding: TextFileEncoding) {
        decodeDetectingEncoding(data, ansiCodePage: ansiCodePage)
    }

    /// Like `decodeDetectingEncoding(_:)` with an explicit ANSI code page for legacy files.
    public static func decodeDetectingEncoding(_ data: Data, ansiCodePage: Int) -> (text: String, encoding: TextFileEncoding) {
        let bytes = [UInt8](data)
        let n = bytes.count
        if n >= 4, bytes[0] == 0xFF, bytes[1] == 0xFE, bytes[2] == 0x00, bytes[3] == 0x00 {
            return (decodeUTF32(bytes, from: 4, bigEndian: false), .utf32LittleEndian)
        }
        if n >= 4, bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0xFE, bytes[3] == 0xFF {
            return (decodeUTF32(bytes, from: 4, bigEndian: true), .utf32BigEndian)
        }
        if n >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return (String(decoding: bytes[3...], as: UTF8.self), .utf8(bom: true))
        }
        if n >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return (decodeUTF16(bytes, from: 2, bigEndian: false), .utf16LittleEndian(bom: true))
        }
        if n >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return (decodeUTF16(bytes, from: 2, bigEndian: true), .utf16BigEndian(bom: true))
        }
        switch bomlessUTF16Guess(bytes) {
        case .some(false): return (decodeUTF16(bytes, from: 0, bigEndian: false), .utf16LittleEndian(bom: false))
        case .some(true): return (decodeUTF16(bytes, from: 0, bigEndian: true), .utf16BigEndian(bom: false))
        case .none: break
        }
        if let s = String(bytes: bytes, encoding: .utf8) {
            return (s, .utf8(bom: false))
        }
        if ansiCodePage != 1252, let s = decodeCodePage(bytes, codePage: ansiCodePage) {
            return (s, .windowsCodePage(ansiCodePage))
        }
        return (decodeWindows1252(bytes), .windows1252)
    }

    /// The bytes to save an edited file with: its own encoding, else (an ANSI file that cannot hold the new text)
    /// UTF-16 LE with BOM, the Unicode encoding Rainmeter skins conventionally use and read back correctly on Windows.
    public static func encodeForWriting(_ text: String, preferring encoding: TextFileEncoding) -> Data {
        encode(text, as: encoding) ?? encode(text, as: .utf16LittleEndian(bom: true)) ?? Data(text.utf8)
    }

    /// Encodes `text` in `encoding` (adding the BOM the encoding calls for). Returns nil only for `.windows1252` and
    /// `.windowsCodePage` when the text contains a character that code page cannot represent (or the code page is
    /// unknown).
    public static func encode(_ text: String, as encoding: TextFileEncoding) -> Data? {
        switch encoding {
        case .utf8(let bom):
            var out = bom ? Data([0xEF, 0xBB, 0xBF]) : Data()
            out.append(contentsOf: Array(text.utf8))
            return out
        case .utf16LittleEndian(let bom): return encodeUTF16(text, bigEndian: false, bom: bom)
        case .utf16BigEndian(let bom): return encodeUTF16(text, bigEndian: true, bom: bom)
        case .utf32LittleEndian: return encodeUTF32(text, bigEndian: false)
        case .utf32BigEndian: return encodeUTF32(text, bigEndian: true)
        case .windows1252: return encodeWindows1252(text)
        case .windowsCodePage(let codePage):
            if codePage == 1252 { return encodeWindows1252(text) }
            guard let encoding = stringEncoding(forCodePage: codePage) else { return nil }
            return text.data(using: encoding, allowLossyConversion: false)
        }
    }

    // MARK: - Other Windows code pages

    /// Foundation's converter for a Windows code page, or nil when unknown or not an "ANSI" code page. INI syntax
    /// needs ASCII to map to itself, so code pages like 1200 (UTF-16), 65001 (UTF-8) or 37 (EBCDIC) are refused.
    private static func stringEncoding(forCodePage codePage: Int) -> String.Encoding? {
        guard codePage > 0, codePage <= Int(UInt32.max), codePage != 65001 else { return nil }
        let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
        guard cf != kCFStringEncodingInvalidId else { return nil }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        guard let ascii = String(bytes: asciiProbe, encoding: encoding), ascii.utf8.elementsEqual(asciiProbe) else {
            return nil
        }
        return encoding
    }

    /// Tab, LF, CR and printable ASCII.
    private static let asciiProbe: [UInt8] = [0x09, 0x0A, 0x0D] + Array(0x20...0x7E)

    /// Decodes with a Windows code page, accepting the result only if it is exact: Foundation's converters are strict
    /// (nil on an invalid sequence) and must reproduce the original bytes, so writing the file back never changes
    /// anything else in it. Otherwise nil (the caller falls back to the lossless Windows-1252 table).
    private static func decodeCodePage(_ bytes: [UInt8], codePage: Int) -> String? {
        guard let encoding = stringEncoding(forCodePage: codePage),
              let text = String(bytes: bytes, encoding: encoding),
              let back = text.data(using: encoding, allowLossyConversion: false),
              back.elementsEqual(bytes) else { return nil }
        return text
    }

    // MARK: - UTF-16 / UTF-32

    private static func decodeUTF16(_ bytes: [UInt8], from start: Int, bigEndian: Bool) -> String {
        let count = (bytes.count - start) / 2 // a dangling odd byte is dropped
        guard count > 0 else { return "" }
        var units = [UInt16](repeating: 0, count: count)
        for k in 0..<count {
            let a = UInt16(bytes[start + 2 * k]), b = UInt16(bytes[start + 2 * k + 1])
            units[k] = bigEndian ? (a << 8 | b) : (b << 8 | a)
        }
        return String(decoding: units, as: UTF16.self) // repairs lone surrogates with U+FFFD
    }

    private static func decodeUTF32(_ bytes: [UInt8], from start: Int, bigEndian: Bool) -> String {
        let count = (bytes.count - start) / 4
        var scalars = String.UnicodeScalarView()
        for k in 0..<max(count, 0) {
            let p = start + 4 * k
            let b0 = UInt32(bytes[p]), b1 = UInt32(bytes[p + 1]), b2 = UInt32(bytes[p + 2]), b3 = UInt32(bytes[p + 3])
            let value = bigEndian ? (b0 << 24 | b1 << 16 | b2 << 8 | b3) : (b3 << 24 | b2 << 16 | b1 << 8 | b0)
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return String(scalars)
    }

    private static func encodeUTF16(_ text: String, bigEndian: Bool, bom: Bool) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(text.utf16.count * 2 + 2)
        func put(_ u: UInt16) {
            if bigEndian { out.append(UInt8(u >> 8)); out.append(UInt8(u & 0xFF)) }
            else { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
        }
        if bom { put(0xFEFF) }
        for u in text.utf16 { put(u) }
        return Data(out)
    }

    private static func encodeUTF32(_ text: String, bigEndian: Bool) -> Data {
        var out = [UInt8]()
        func put(_ v: UInt32) {
            let b = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            out.append(contentsOf: bigEndian ? b : b.reversed())
        }
        put(0xFEFF)
        for s in text.unicodeScalars { put(s.value) }
        return Data(out)
    }

    /// BOM-less UTF-16: ASCII-heavy text has a zero byte in the high half of most code units. Returns false for
    /// little endian, true for big endian, nil when the data does not look like UTF-16. UTF-8 / ANSI INI text never
    /// contains zero bytes, so a clear majority on one side is decisive.
    private static func bomlessUTF16Guess(_ bytes: [UInt8]) -> Bool? {
        let sampleCount = min(bytes.count, 1024) & ~1
        guard sampleCount >= 4 else { return nil }
        var oddZeros = 0, evenZeros = 0
        for i in 0..<sampleCount where bytes[i] == 0 {
            if i & 1 == 1 { oddZeros += 1 } else { evenZeros += 1 }
        }
        let threshold = sampleCount / 8 // at least a quarter of the code units are ASCII
        if oddZeros > threshold, evenZeros * 4 < oddZeros { return false }
        if evenZeros > threshold, oddZeros * 4 < evenZeros { return true }
        return nil
    }

    // MARK: - Windows-1252

    /// 0x80…0x9F of code page 1252 (0 = undefined; mapped to U+0080 + n for a lossless round trip).
    private static let cp1252High: [UInt32] = [
        0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    ]

    private static let cp1252Reverse: [UInt32: UInt8] = {
        var map: [UInt32: UInt8] = [:]
        for (i, v) in cp1252High.enumerated() {
            map[v == 0 ? 0x80 + UInt32(i) : v] = UInt8(0x80 + i)
        }
        return map
    }()

    private static func decodeWindows1252(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for b in bytes {
            var v = UInt32(b)
            if b >= 0x80, b < 0xA0 {
                let mapped = cp1252High[Int(b) - 0x80]
                v = mapped == 0 ? v : mapped
            }
            scalars.append(Unicode.Scalar(v) ?? "\u{FFFD}")
        }
        return String(scalars)
    }

    private static func encodeWindows1252(_ text: String) -> Data? {
        var out = [UInt8]()
        out.reserveCapacity(text.utf8.count)
        for s in text.unicodeScalars {
            let v = s.value
            if v < 0x80 || (v >= 0xA0 && v <= 0xFF) {
                out.append(UInt8(v))
            } else if let b = cp1252Reverse[v] {
                out.append(b)
            } else {
                return nil
            }
        }
        return Data(out)
    }
}
