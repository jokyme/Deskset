import AppKit
import DesksetCore

/// Everyday words for what the Core names in English — data, the kinds of parts, colors — in the Studio's language.
/// The Core's words are the widget's own (its data, its parts); the Chinese here follows the design's vocabulary.
enum StudioWords {
    static var chinese: Bool { StudioText.language == .chinese }

    /// A data item's name ("CPU usage" → "CPU 占用率").
    static func data(_ name: String) -> String {
        guard chinese else { return name }
        let table: [String: String] = [
            "CPU usage": "CPU 占用率", "Memory used": "内存用量", "Memory and swap used": "内存和交换用量",
            "GPU usage": "GPU 占用率", "GPU temperature": "GPU 温度", "CPU temperature": "CPU 温度",
            "Fan speed": "风扇转速", "Power": "功率", "Battery": "电池", "Download speed": "下载速度",
            "Upload speed": "上传速度", "Network speed": "网速", "Total memory": "内存总量", "Swap used": "交换用量",
            "Disk used": "磁盘用量", "Time": "时间", "Date": "日期", "Uptime": "开机时间",
        ]
        if let t = table[name] { return t }
        if name.hasPrefix("Free space on ") { return String(name.dropFirst("Free space on ".count)) + " 的可用空间" }
        if name.hasPrefix("Size of ") { return String(name.dropFirst("Size of ".count)) + " 的容量" }
        return name
    }

    /// A short name of data or of what a color paints ("Memory" → "内存"; the long "Precipitation" is "Rain").
    static func short(_ word: String) -> String {
        let everyday: [String: String] = ["Precipitation": "Rain", "Precipitation text": "Rain"]
        let word = everyday[word] ?? word
        guard chinese else { return word }
        let table: [String: String] = [
            "Memory": "内存", "Disk": "磁盘", "Network": "网络", "Download": "下载", "Upload": "上传", "Battery": "电池",
            "Temperature": "温度", "Fan": "风扇", "Power": "功率", "Swap": "交换", "Memory + swap": "内存和交换",
            "Precipitation": "降水", "Rain": "降水", "Sun": "太阳", "Bars": "进度条", "Graphs": "曲线", "Rings": "圆环",
            "Tracks": "轨道", "Outline": "描边", "Accent": "强调色", "Text": "文字", "Ink": "文字", "Glass": "玻璃",
            "Panel": "面板", "Line": "线条", "Uptime": "开机时间",
        ]
        return table[word] ?? word
    }

    /// The kind of a part ("ring" → "Ring" / "圆环").
    static func kind(_ noun: String) -> String {
        switch noun {
        case "ring": return StudioText[.showsRing]
        case "bar": return StudioText[.showsBar]
        case "graph": return StudioText[.showsGraph]
        case "gauge": return StudioText[.showsGauge]
        default: return StudioText[.showsShape]
        }
    }

    /// What a color paints, as a title ("Memory ring" / "内存环").
    static func title(short word: String, kind noun: String?) -> String {
        guard let noun, !noun.isEmpty, noun != "text", noun != "picture" else {
            // A title of several words ("Bar tracks") is the widget's own; one word is looked up.
            return word.contains(" ") && !chinese ? word : short(word)
        }
        guard chinese else { return "\(word) \(noun)" }
        let s = short(word)
        let ascii = s.unicodeScalars.allSatisfy(\.isASCII)
        let k = noun == "ring" ? (ascii ? "圆环" : "环") : kind(noun)
        return ascii ? "\(s) \(k)" : s + k
    }

    /// A color in words ("Mint" / "薄荷绿").
    static func color(_ english: String) -> String {
        let lower = english.lowercased()
        guard chinese else { return lower.prefix(1).uppercased() + lower.dropFirst() }
        let table: [String: String] = [
            "red": "红色", "orange": "橙色", "yellow": "黄色", "green": "绿色", "mint": "薄荷绿", "teal": "蓝绿色",
            "cyan": "青色", "blue": "蓝色", "indigo": "靛蓝色", "purple": "紫色", "pink": "粉色", "brown": "棕色",
            "gray": "灰色", "light gray": "浅灰色", "dark gray": "深灰色", "white": "白色", "black": "黑色",
            "clear": "透明", "accent": "强调色",
        ]
        return table[lower] ?? english
    }

    /// "1 part", "4 parts".
    static func parts(_ n: Int) -> String {
        n == 1 ? StudioText[.partsOne] : StudioText.format(.partsMany, n)
    }

    /// A value of a choice as the page shows it ("C" of a temperature unit → "°C", "Auto" → "自动").
    static func choice(_ value: String, of variable: String) -> String {
        let v = variable.lowercased()
        if v.contains("temp"), ["c", "f"].contains(value.lowercased()) { return "°" + value.uppercased() }
        if value.caseInsensitiveCompare("Auto") == .orderedSame { return StudioText[.unitsAuto] }
        return value
    }

    /// The symbol of a data item, from what it reads.
    static func symbol(_ measure: Measure) -> String {
        switch measure.type {
        case "cpu", "advancedcpu", "coretemp": return "cpu"
        case "memory", "physicalmemory", "swapmemory": return "memorychip"
        case "freediskspace": return "internaldrive"
        case "netin": return "arrow.down.circle"
        case "netout": return "arrow.up.circle"
        case "nettotal": return "network"
        case "powerplugin": return "battery.75percent"
        case "time": return "clock"
        case "uptime": return "timer"
        case "macsensors", "usagemonitor":
            let s = measure.string(measure.type == "macsensors" ? "Sensor" : "Alias").lowercased()
            if s.hasPrefix("gpu") { return "cube.transparent" }
            if s.hasPrefix("fan") { return "fan" }
            return "thermometer.medium"
        default: return "waveform.path.ecg"
        }
    }
}
