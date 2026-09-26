import Foundation

/// The inspector's Number and Format menus (docs/editor-friendly.md §8.2): each choice is shown as the live value
/// rendered with it ("48 · 48.2 · 48.24 · 0.05 k", "3 GB · 3.2 GB · 3,221,225,472", "14:05 · 2:05 PM"), never as the
/// options it writes. Rendering uses the engine's own formatting (`NumberFormatting`, `TimeFormatting`), so the menu
/// shows exactly what the text will show.
public enum FormatPresets {
    /// What a number stands for, which decides the examples.
    public enum Unit: Equatable {
        case plain
        /// An amount of bytes (memory, disk): "3 GB".
        case bytes
        /// Bytes per second (network): "2.4 MB/s".
        case bytesPerSecond
    }

    /// One choice of the Number menu.
    public struct NumberPreset: Equatable {
        /// The live value rendered with it ("13.3 k").
        public var title: String
        /// The String meter's number options it writes (`NumberPresets.keys`); nil removes the option.
        public var options: [String: String?]

        public init(title: String, options: [String: String?]) {
            self.title = title
            self.options = options
        }
    }

    /// The String meter options a Number choice writes.
    public static let numberKeys = ["NumOfDecimals", "AutoScale", "Scale", "Percentual"]

    /// How a number is shortened into k, M, G: by 1000s, or by 1024s (the text's `AutoScale=1`, common for memory).
    public enum Base: Equatable {
        case thousands
        case binary
    }

    /// The base a text already shortens its numbers in (`AutoScale` as written; not set or off: thousands), so the
    /// Number menu offers its current format among the choices instead of switching base.
    public static func base(ofAutoScale raw: String?) -> Base {
        if case .binary = AutoScale.parse(raw ?? "") { return .binary }
        return .thousands
    }

    /// The Number menu for `value`. `range`: the live data's lowest and highest value, for "Percent of range" (left
    /// out when the range is empty). `base`: shortened by 1000s or 1024s ("17.9 GB" of memory reads "19.2 GB" in
    /// 1000s): the base the text uses now, so a choice never changes the base.
    public static func numberPresets(for value: Double, unit: Unit = .plain, range: (min: Double, max: Double)? = nil,
                                     base: Base = .thousands) -> [NumberPreset] {
        func options(decimals: String?, autoScale: String? = nil, percent: Bool = false) -> [String: String?] {
            ["NumOfDecimals": decimals, "AutoScale": autoScale, "Scale": nil, "Percentual": percent ? "1" : nil]
        }
        func render(_ o: [String: String?], suffix: String = "") -> String {
            let parsed = parse(o)
            let text = NumberFormatting.format(value, minValue: range?.min ?? 0, maxValue: range?.max ?? 1, options: parsed)
            return text.trimmingCharacters(in: .whitespaces) + suffix
        }
        var presets: [NumberPreset] = []
        switch unit {
        case .plain:
            for decimals in [nil, "1", "2"] as [String?] {
                let o = options(decimals: decimals)
                presets.append(NumberPreset(title: render(o), options: o))
            }
            // Thousands: at least "k", with enough decimals to show something.
            let scaled = abs(value) / (base == .binary ? 1024 : 1000)
            let o = options(decimals: scaled >= 1 || scaled == 0 ? "1" : "2", autoScale: base == .binary ? "1k" : "2k")
            presets.append(NumberPreset(title: render(o), options: o))
        case .bytes, .bytesPerSecond:
            let suffix = unit == .bytes ? "B" : "B/s"
            for decimals in ["0", "1"] {
                let o = options(decimals: decimals, autoScale: base == .binary ? "1" : "2")
                presets.append(NumberPreset(title: render(o, suffix: suffix), options: o))
            }
            let o = options(decimals: nil)
            presets.append(NumberPreset(title: grouped(value), options: o))
        }
        if let range, range.max > range.min {
            let o = options(decimals: nil, percent: true)
            presets.append(NumberPreset(title: "Percent of range — \(render(o))%", options: o))
        }
        // Two choices that look the same are one choice (0 and 0.0 are not: they write differently).
        var seen: Set<String> = []
        return presets.filter { seen.insert($0.title).inserted }
    }

    /// The preset among `presets` that `current` (the meter's number options as written) renders like: the same
    /// options in effect. nil: a custom combination.
    public static func index(of current: [String: String], in presets: [NumberPreset]) -> Int? {
        let written = effective(parse(numberKeys.reduce(into: [String: String?]()) { $0[$1] = current[$1] }))
        return presets.firstIndex { effective(parse($0.options)) == written }
    }

    /// Number options from option texts (nil or empty: not set).
    static func parse(_ o: [String: String?]) -> NumberFormatOptions {
        func value(_ key: String) -> String? {
            guard let v = o[key] ?? nil else { return nil }
            let t = v.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return NumberFormatOptions.parse(autoScale: value("AutoScale"), scale: value("Scale"),
                                         numOfDecimals: value("NumOfDecimals"), percentual: value("Percentual"))
    }

    /// Options with the defaults the engine applies filled in, for comparing.
    static func effective(_ o: NumberFormatOptions) -> NumberFormatOptions {
        var e = o
        if e.numOfDecimals == nil {
            switch e.autoScale {
            case .off: e.numOfDecimals = e.scaleHasDecimalPoint ? 1 : 0
            default: e.numOfDecimals = 1
            }
        }
        if e.autoScale != .off { e.scale = 1; e.scaleHasDecimalPoint = false }
        return e
    }

    /// 3221225472 → "3,221,225,472" (for reading only: the text itself has no separators).
    static func grouped(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value.rounded())) ?? NumberFormatting.fixed(value, decimals: 0)
    }

    /// What a measure type's number stands for (memory and disk: bytes; network: bytes per second).
    public static func unit(forMeasureType type: String, plugin: String? = nil) -> Unit {
        switch EditorSchema.measureType(type: type, plugin: plugin)?.name {
        case "Memory"?, "PhysicalMemory"?, "SwapMemory"?, "FreeDiskSpace"?, "FolderInfo"?: return .bytes
        case "NetIn"?, "NetOut"?, "NetTotal"?: return .bytesPerSecond
        default: return .plain
        }
    }

    // MARK: Time

    /// One choice of a time's Format menu.
    public struct TimePreset: Equatable {
        /// The moment rendered with it ("14:05", "Wed 24 Sep").
        public var title: String
        /// The `Format=` it writes.
        public var format: String
    }

    /// The Format examples of §8.2: 14:05 · 2:05 PM · 14:05:09 · Wed 24 Sep · September 24, 2026.
    public static let timeFormats = ["%H:%M", "%#I:%M %p", "%H:%M:%S", "%a %#d %b", "%B %#d, %Y"]

    /// The Format menu at `date` (a clock shows the current time).
    public static func timePresets(at date: Date, timeZone: TimeZone = .current,
                                   locale: Locale = Locale(identifier: "en_US_POSIX")) -> [TimePreset] {
        timeFormats.map { TimePreset(title: TimeFormatting.format(date, format: $0, timeZone: timeZone, locale: locale),
                                     format: $0) }
    }
}
