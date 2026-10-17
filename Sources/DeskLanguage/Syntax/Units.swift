import Foundation

/// The unit spellings the lexer knows. Dimensions, factors and display bases belong to the catalog; the lexer only
/// needs to tell known units from diagnosed and unknown spellings.
enum UnitTable {
    /// Every unit, canonical spellings only.
    static let known: Set<String> = [
        "pt",
        "ms", "s", "min", "h", "d",
        "%",
        "deg", "°", "rad",
        "°C", "°F",
        "B", "KB", "MB", "GB", "TB", "KiB", "MiB", "GiB", "TiB",
        "B/s", "KB/s", "MB/s", "GB/s", "KiB/s", "MiB/s", "GiB/s",
        "Hz", "kHz", "MHz", "GHz",
        "W", "mW",
        "V", "mV",
        "A", "mA",
        "rpm",
        "km/h", "mph", "m/s", "kn",
        "mm", "inch",
        "hPa", "mbar", "inHg",
    ]

    /// Known units in the order a message lists them.
    static let listed: [String] = [
        "pt", "ms", "s", "min", "h", "d", "%", "deg", "°", "rad", "°C", "°F", "B", "KB", "MB", "GB", "TB", "KiB",
        "MiB", "GiB", "TiB", "B/s", "KB/s", "MB/s", "GB/s", "KiB/s", "MiB/s", "GiB/s", "Hz", "kHz", "MHz", "GHz",
        "W", "mW", "V", "mV", "A", "mA", "rpm", "km/h", "mph", "m/s", "kn", "mm", "inch", "hPa", "mbar", "inHg",
    ]

    /// CSS units: DK1022.
    static let css: Set<String> = ["em", "rem", "vw", "vh", "vmin", "vmax", "fr", "cm", "in"]

    /// Misspelled units and the spelling Desk uses: DK1023.
    static let misspelled: [String: String] = [
        "kb": "KB", "Kb": "KB", "mb": "MB", "gb": "GB", "Gb": "GB", "tb": "TB",
        "Ms": "ms", "S": "s", "H": "h",
        "sec": "s", "secs": "s", "second": "s", "seconds": "s",
        "m": "min", "mins": "min", "minute": "min", "minutes": "min",
        "hr": "h", "hrs": "h", "hour": "h", "hours": "h",
        "day": "d", "days": "d",
        "c": "°C", "C": "°C", "f": "°F", "F": "°F",
        "kmh": "km/h", "kph": "km/h", "km/hr": "km/h", "knots": "kn",
        "millibar": "mbar", "hpa": "hPa",
    ]

    /// Units that count bits: DK1027, with the byte unit to use (the number is divided by 8).
    static let bits: [String: String] = [
        "Mb": "MB", "Kbps": "KB/s", "Mbps": "MB/s", "Gbps": "GB/s", "bit": "B", "bits": "B", "b": "B",
    ]

    /// Classifies a unit spelling (full-width characters already mapped).
    static func spelling(_ text: String) -> UnitSpelling {
        if known.contains(text) { return UnitSpelling(text: text, status: .known) }
        if text == "px" { return UnitSpelling(text: text, status: .diagnosed(.pxUnit)) }
        if css.contains(text) {
            return UnitSpelling(text: text, status: .diagnosed(.cssUnit), suggestion: text == "in" ? "inch" : nil)
        }
        if let fixed = misspelled[text] { return UnitSpelling(text: text, status: .diagnosed(.unitSpelling), suggestion: fixed) }
        if let fixed = bits[text] { return UnitSpelling(text: text, status: .diagnosed(.bitsUnit), suggestion: fixed) }
        if text == "R" || text == "r" { return UnitSpelling(text: text, status: .relativePosition) }
        return UnitSpelling(text: text, status: .unknown, suggestion: closestKnown(to: text))
    }

    /// A known unit close to `text` (edit distance 1, or 2 for longer spellings), when exactly one is closest.
    static func closestKnown(to text: String) -> String? {
        let limit = text.count <= 4 ? 1 : 2
        var best: [String] = []
        var bestDistance = Int.max
        for candidate in listed {
            let d = editDistance(text.lowercased(), candidate.lowercased())
            if d <= limit {
                if d < bestDistance { bestDistance = d; best = [candidate] } else if d == bestDistance { best.append(candidate) }
            }
        }
        return best.count == 1 ? best[0] : nil
    }
}

/// Optimal string alignment distance (Damerau–Levenshtein without repeated edits of one substring).
func editDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a.unicodeScalars)
    let y = Array(b.unicodeScalars)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var previous2 = [Int](repeating: 0, count: y.count + 1)
    var previous = Array(0...y.count)
    var current = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        current[0] = i
        for j in 1...y.count {
            let cost = x[i - 1] == y[j - 1] ? 0 : 1
            var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                value = min(value, previous2[j - 2] + 1)
            }
            current[j] = value
        }
        (previous2, previous, current) = (previous, current, previous2)
    }
    return previous[y.count]
}
