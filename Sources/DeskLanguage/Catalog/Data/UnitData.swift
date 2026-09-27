import Foundation

// Units written right after a number (`2s`, `50%`, `2GB`), and the spellings Desk recognises only to report them
// (`px`, `em`, `sec`, `Mbps`). The lexer keeps its own list of spellings (it needs no catalog); this table adds what
// each unit means: its dimension, and how a value in it converts to the dimension's canonical unit.

extension CatalogData {
    static func unit(_ spelling: String, _ dimension: Dimension, _ factor: Double, offset: Double = 0) -> UnitSpec {
        UnitSpec(spelling: spelling, dimension: dimension, factor: factor, offset: offset)
    }

    /// `KB`…`TB` (and their `/s` forms): the factor is for a base of 1000; the base settled for the expression
    /// decides (1000 or 1024).
    static func baseUnit(_ spelling: String, _ dimension: Dimension, power: Int) -> UnitSpec {
        UnitSpec(spelling: spelling, dimension: dimension, factor: pow(1000, Double(power)), adoptsBase: true,
                 basePower: power)
    }

    /// Units in the order messages list them (DK1024) and the reference shows them.
    static let units: [UnitSpec] = [
        unit("pt", .length, 1),
        unit("ms", .time, 0.001), unit("s", .time, 1), unit("min", .time, 60), unit("h", .time, 3_600),
        unit("d", .time, 86_400),
        unit("%", .percent, 1),
        unit("deg", .angle, 1), unit("°", .angle, 1), unit("rad", .angle, 180 / Double.pi),
        // As a temperature, °F converts (x − 32) × 5/9. As a difference (a `+`/`-` operand of a temperature) it
        // converts × 5/9 with no offset; the checker drops the offset there (§4.4.2).
        unit("°C", .temperature, 1), unit("°F", .temperature, 5.0 / 9.0, offset: -160.0 / 9.0),
        unit("B", .bytes, 1),
        baseUnit("KB", .bytes, power: 1), baseUnit("MB", .bytes, power: 2), baseUnit("GB", .bytes, power: 3),
        baseUnit("TB", .bytes, power: 4),
        unit("KiB", .bytes, 1_024), unit("MiB", .bytes, 1_048_576), unit("GiB", .bytes, 1_073_741_824),
        unit("TiB", .bytes, 1_099_511_627_776),
        unit("B/s", .bytesPerSecond, 1),
        baseUnit("KB/s", .bytesPerSecond, power: 1), baseUnit("MB/s", .bytesPerSecond, power: 2),
        baseUnit("GB/s", .bytesPerSecond, power: 3),
        unit("KiB/s", .bytesPerSecond, 1_024), unit("MiB/s", .bytesPerSecond, 1_048_576),
        unit("GiB/s", .bytesPerSecond, 1_073_741_824),
        unit("Hz", .frequency, 1), unit("kHz", .frequency, 1e3), unit("MHz", .frequency, 1e6), unit("GHz", .frequency, 1e9),
        unit("W", .power, 1), unit("mW", .power, 0.001),
        unit("V", .voltage, 1), unit("mV", .voltage, 0.001),
        unit("A", .current, 1), unit("mA", .current, 0.001),
        unit("rpm", .rpm, 1),
        unit("km/h", .speed, 1 / 3.6), unit("mph", .speed, 0.447_04), unit("m/s", .speed, 1),
        unit("kn", .speed, 1_852.0 / 3_600.0),
        unit("mm", .rainfall, 1), unit("inch", .rainfall, 25.4),
        unit("hPa", .pressure, 1), unit("mbar", .pressure, 1), unit("inHg", .pressure, 33.863_886_666_7),
    ]

    static func misspelled(_ spellings: [String], _ id: DiagnosticID, _ suggestions: [String], _ dimension: Dimension?,
                           note: LocalizedText? = nil) -> [UnitMisspellingSpec] {
        spellings.map {
            UnitMisspellingSpec(spelling: $0, diagnostic: id, suggestions: suggestions, dimension: dimension, note: note)
        }
    }

    static let bitsNote = L("8 bits are a byte, so the number is divided by 8; to show bits, write {x, bits: true}",
                            "8 比特是 1 字节，所以数字要除以 8；想显示比特，写 {x, bits: true}")

    /// Spellings that are reported. The number and the unit stay one token, so recovery keeps the value (in the
    /// dimension given here: `18px` is still 18 points).
    static let unitMisspellings: [UnitMisspellingSpec] =
        misspelled(["px"], .pxUnit, [], .length)
        + misspelled(["em", "rem", "vw", "vh", "vmin", "vmax", "fr", "cm"], .cssUnit, [], nil)
        + misspelled(["in"], .cssUnit, ["inch"], nil,
                     note: L("`inch` is rainfall; lengths are plain numbers in points", "`inch` 是降水量的单位；长度直接写数字，单位是点"))
        + misspelled(["kb", "Kb"], .unitSpelling, ["KB"], .bytes)
        + misspelled(["mb"], .unitSpelling, ["MB", "mbar"], .bytes,
                     note: L("`mbar` next to a pressure", "和气压一起用时是 `mbar`"))
        + misspelled(["gb", "Gb"], .unitSpelling, ["GB"], .bytes)
        + misspelled(["tb"], .unitSpelling, ["TB"], .bytes)
        + misspelled(["Ms"], .unitSpelling, ["ms"], .time)
        + misspelled(["S", "sec", "secs", "second", "seconds"], .unitSpelling, ["s"], .time)
        + misspelled(["m", "mins", "minute", "minutes"], .unitSpelling, ["min"], .time)
        + misspelled(["H", "hr", "hrs", "hour", "hours"], .unitSpelling, ["h"], .time)
        + misspelled(["day", "days"], .unitSpelling, ["d"], .time)
        + misspelled(["c", "C"], .unitSpelling, ["°C"], .temperature)
        + misspelled(["f", "F"], .unitSpelling, ["°F"], .temperature)
        + misspelled(["kmh", "kph", "km/hr"], .unitSpelling, ["km/h"], .speed)
        + misspelled(["knots"], .unitSpelling, ["kn"], .speed)
        + misspelled(["millibar"], .unitSpelling, ["mbar"], .pressure)
        + misspelled(["hpa"], .unitSpelling, ["hPa"], .pressure)
        + misspelled(["Mb"], .bitsUnit, ["MB"], .bytes, note: bitsNote)
        + misspelled(["Kbps"], .bitsUnit, ["KB/s"], .bytesPerSecond, note: bitsNote)
        + misspelled(["Mbps"], .bitsUnit, ["MB/s"], .bytesPerSecond, note: bitsNote)
        + misspelled(["Gbps"], .bitsUnit, ["GB/s"], .bytesPerSecond, note: bitsNote)
        + misspelled(["bit", "bits", "b"], .bitsUnit, ["B"], .bytes, note: bitsNote)
        // `4R`, `2r` in the x: / y: of `.position` or `.offset`: Rainmeter's relative position (DK9309); anywhere
        // else they are unknown units (DK1024), never suggested.
        + misspelled(["R", "r"], .rainmeterRelativePosition, [], .length,
                     note: L("In .position and .offset only; elsewhere it is an unknown unit",
                             "只在 .position 和 .offset 里这样处理；在别处是不认识的单位"))
}
