import Foundation

// Format options of `"{value, option: …}"`: how data shows in text. An option that does not apply to the value's
// type is DK4024. Defaults per type are in §4.11 of the language reference; data members carry their own
// (`MemberSpec.defaultFormat`).

extension CatalogData {
    /// The number dimensions whose values show a unit (`12.3 GB`, `52°`, `3.5 GHz`).
    static let dimensionsWithUnits: [DeskType] = [
        .bytes, .rate, .temperature, .number(.temperatureDelta), .frequency, .power, .voltage, .current, .angle, .rpm,
        .speed, .rainfall, .pressure,
    ]

    static let formatOptions: [FormatOptionSpec] = [
        FormatOptionSpec(label: "decimals", appliesTo: [.anyNumber], type: .plainNumber, range: 0...10,
                         doc: doc("A fixed number of decimals", "固定的小数位数", #"Text("{cpu.usage, decimals: 1}%")"#,
                                  [meter("String", "NumOfDecimals")],
                                  keywords: ["NumOfDecimals", "precision", "fractionDigits", "toFixed", "places", "小数位"],
                                  rank: 80)),
        FormatOptionSpec(label: "unit", appliesTo: [.bytes, .rate], type: e("ByteUnit"),
                         doc: doc("A fixed unit for an amount of data or a data speed; .kb… use the value's base, .kib… 1024",
                                  "数据量或网速的固定单位；.kb 等跟随数据的进制，.kib 等按 1024",
                                  #"Text("{memory.used, unit: .gb}")"#, [meter("String", "AutoScale")],
                                  keywords: ["AutoScale", "units", "scale", "单位"], rank: 70)),
        FormatOptionSpec(label: "unit", appliesTo: [.temperature, .number(.temperatureDelta)], type: e("TemperatureUnit"),
                         doc: doc("A fixed unit for a temperature", "温度的固定单位",
                                  #"Text("{sensors.cpuTemperature, unit: .fahrenheit}")"#, [plugin("MacSensors", "Scale")],
                                  keywords: ["Scale", "celsius", "fahrenheit", "温度单位"], rank: 50)),
        FormatOptionSpec(label: "unit", appliesTo: [.frequency], type: e("FrequencyUnit"),
                         doc: doc("A fixed unit for a frequency", "频率的固定单位", #"Text("{sensors.cpuClock, unit: .mhz}")"#,
                                  keywords: ["mhz", "ghz", "频率单位"], rank: 20)),
        FormatOptionSpec(label: "unitStyle", appliesTo: dimensionsWithUnits, type: e("UnitStyle"),
                         doc: doc("How much of the unit is shown: none, short (12.3 GB, 52°) or full (52 °C)",
                                  "单位显示多少：不显示、简短（12.3 GB、52°）或完整（52 °C）",
                                  #"Text("{sensors.cpuTemperature, unitStyle: .full}")"#,
                                  keywords: ["unit style", "suffix", "单位样式"], rank: 30)),
        FormatOptionSpec(label: "bits", appliesTo: [.rate], type: .bool,
                         doc: doc("Shows a data speed in bits per second (9.6 Mb/s)", "网速按比特每秒显示（9.6 Mb/s）",
                                  #"Text("{network.download, bits: true}")"#, [measure("NetIn", "UseBits")],
                                  keywords: ["UseBits", "bps", "Mbps", "比特"], rank: 30)),
        FormatOptionSpec(label: "format", appliesTo: [.date], type: .oneOf([.string, e("DatePreset")]),
                         doc: doc("A date pattern such as \"HH:mm\", or a preset such as .weekday",
                                  "日期格式，比如 \"HH:mm\"，或者 .weekday 这样的预设",
                                  #"Text("{time.now, format: "HH:mm"}")"#, [measure("Time", "Format")],
                                  keywords: ["Format", "date format", "dateFormat", "strftime", "pattern", "日期格式"], rank: 85)),
        FormatOptionSpec(label: "style", appliesTo: [.duration], type: e("DurationStyle"),
                         doc: doc("How a duration is written: full (3 days 4 hours), short (3d 4h) or clock (76:04:12)",
                                  "时长的写法：完整（3 天 4 小时）、简短（3d 4h）或时钟（76:04:12）",
                                  #"Text("{uptime, style: .short}")"#, [measure("Uptime", "Format")],
                                  keywords: ["Format", "duration style", "时长样式"], rank: 45)),
        FormatOptionSpec(label: "missing", appliesTo: [.any], type: .string,
                         doc: doc("Text shown instead of “–” while the value is missing", "取不到值时代替“–”显示的文字",
                                  #"Text("{music.title, missing: "Nothing playing"}")"#,
                                  [plugin("MacWeather", "UnavailableText").approx("the text a weather measure shows without data")],
                                  keywords: ["UnavailableText", "placeholder", "fallback", "default", "取不到"], rank: 40)),
    ]
}
