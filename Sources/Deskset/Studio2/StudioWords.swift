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
            "Disk used": "磁盘用量", "Time": "时间", "Date": "日期", "Uptime": "开机时长",
            "Time since startup": "开机时长", "Computer name": "电脑名称", "Disk name": "磁盘名称", "User name": "用户名",
            "Memory free": "可用内存", "Swap free": "可用交换", "Total swap": "交换总量",
            "Total memory and swap": "内存和交换总量", "Memory and swap free": "可用内存和交换",
            "Battery level": "电量", "Battery status": "电池状态", "Battery time left": "电池剩余时间",
            "Charger connected": "已接电源", "Network use in total": "网络总用量", "Downloaded in total": "下载总量",
            "Uploaded in total": "上传总量", "Date and time": "日期和时间", "Time with seconds": "带秒的时间",
            "Hours and minutes": "时和分", "Minutes and seconds": "分和秒", "Now playing": "正在播放",
            "Song title": "歌名", "Song artist": "歌手", "Album": "专辑", "Album cover": "专辑封面",
            "Processor speed": "处理器速度", "Random number": "随机数", "Calculated number": "计算出的数",
            "Day of the month": "日", "Day of the year": "一年中的第几天", "Month name": "月份", "Weekday": "星期",
            "Week number": "周数", "Year": "年份", "Month and year": "年月", "Sound level": "音量电平",
            "Temperature": "温度", "Weather": "天气",
        ]
        if let t = table[name] { return t }
        if name.hasPrefix("Free space on ") { return String(name.dropFirst("Free space on ".count)) + " 的可用空间" }
        if name.hasPrefix("Size of ") { return String(name.dropFirst("Size of ".count)) + " 的容量" }
        return suffixed(name) ?? name
    }

    /// A data word with the kind of thing after it ("Uptime text" → "开机时长文字"), nil when it is not one.
    static func suffixed(_ title: String) -> String? {
        let suffixes: [(String, String)] = [(" text", "文字"), (" label", "标签"), (" bar", "进度条"), (" ring", "圆环"),
                                            (" graph", "曲线"), (" shape", "形状"), (" picture", "图片"),
                                            (" icon", "图标"), (" fill", "填充"), (" value", "数值")]
        for (suffix, zh) in suffixes where title.lowercased().hasSuffix(suffix) && title.count > suffix.count {
            let head = String(title.dropLast(suffix.count))
            let h = short(head) != head ? short(head) : data(head)
            guard h != head || head.uppercased() == head else { return nil }
            let ascii = h.unicodeScalars.allSatisfy(\.isASCII)
            return ascii ? "\(h) \(zh)" : h + zh
        }
        return nil
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
            "Panel": "面板", "Line": "线条", "Uptime": "开机时长", "CPU": "CPU", "GPU": "GPU",
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

    /// What a click does, in the Studio's language (the Core says it in English: "Opens Activity Monitor" → "打开
    /// Activity Monitor"). A sentence it does not know stays English.
    static func action(_ sentence: String) -> String {
        guard chinese else { return sentence }
        let fixed: [String: String] = [
            "Runs a command": "执行一个命令", "Opens Manage Widgets": "打开“管理小组件”", "Opens the widget's menu": "打开小组件的菜单",
            "Quits Deskset": "退出 Deskset", "Reloads every widget": "重新载入全部小组件", "Reloads the widget": "重新载入小组件",
            "Hides the widget": "隐藏小组件", "Shows the widget": "显示小组件", "Shows or hides the widget": "显示或隐藏小组件",
            "Moves the widget": "移动小组件", "Writes to the log": "写进日志", "Sends a command to live data": "给实时数据发一个命令",
            "Changes one of its settings": "更改它的一个设置",
        ]
        if let zh = fixed[sentence] { return zh }
        // An app opened: by the name the Mac gives it in Chinese, in Chinese quotes (打开“活动监视器”).
        if sentence.hasPrefix("Opens ") {
            let what = String(sentence.dropFirst("Opens ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "“”\""))
            let app = appName(what)
            if app != what || !what.contains("/") { return "打开“\(app)”" }
        }
        let patterns: [(String, String)] = [
            (#"^Runs (\d+) commands$"#, "执行 $1 个命令"),
            (#"^Shows or hides the widget (.+)$"#, "显示或隐藏小组件$1"),
            (#"^Shows the widget (.+)$"#, "显示小组件$1"),
            (#"^Hides the widget (.+)$"#, "隐藏小组件$1"),
            (#"^Shows or hides the layers in (.+)$"#, "显示或隐藏$1里的图层"),
            (#"^Shows the layers in (.+)$"#, "显示$1里的图层"),
            (#"^Hides the layers in (.+)$"#, "隐藏$1里的图层"),
            (#"^Shows or hides (.+)$"#, "显示或隐藏$1"),
            (#"^Shows (.+)$"#, "显示$1"),
            (#"^Hides (.+)$"#, "隐藏$1"),
            (#"^Changes a setting of (.+)$"#, "更改$1的一个设置"),
            (#"^Changes the shared value (.+)$"#, "更改共用值$1"),
            (#"^Writes an email to (.+)$"#, "给 $1 写邮件"),
            (#"^Opens (.+)$"#, "打开 $1"),
        ]
        for (pattern, template) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) else { continue }
            var out = template
            if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: sentence) {
                let value = String(sentence[r])
                // A space between Chinese and a Latin word or number that meets it.
                let before = out.components(separatedBy: "$1").first ?? ""
                let after = out.components(separatedBy: "$1").dropFirst().joined()
                var joined = before
                if let a = before.last, let b = value.first, StudioText.needsSpace(a, b), !before.hasSuffix(" ") { joined += " " }
                joined += value
                if let a = value.last, let b = after.first, StudioText.needsSpace(a, b) { joined += " " }
                out = joined + after
            }
            return out.replacingOccurrences(of: "  ", with: " ")
        }
        return sentence
    }

    /// Names in a list, as the language writes one (“Card and Rim”, “卡片和边框”, “A、B 和 C”).
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: StudioText.language == .chinese ? "zh_CN" : "en_US")
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }

    /// A layer's name the Core gives in English ("Uptime text" → "开机时长文字", "Background" → "背景"): the data names,
    /// the plain names of parts, and a data word with the kind of part after it. The widget's own names stay.
    static func layer(_ title: String) -> String {
        guard chinese else { return title }
        let named = data(title)
        if named != title { return named }
        let fixed: [String: String] = [
            "Background": "背景", "Color block": "色块", "Line graph": "折线图", "Bar graph": "柱状图", "Rectangle": "矩形",
            "Rounded rectangle": "圆角矩形", "Circle": "圆", "Ellipse": "椭圆", "Line": "线条", "Shape": "形状",
            "Picture": "图片", "Button": "按钮", "Fixed text": "固定文字", "Empty text": "空文字", "Clock face": "表盘",
            "Hour hand": "时针", "Dial": "刻度盘", "Moving block": "移动的方块", "Cover": "封面", "Text": "文字",
            "Bar": "进度条", "Gauge": "仪表", "Layer": "图层", "Formula shape": "算式形状", "Number picture": "数字图片",
            "Web picture": "网络图片",
        ]
        return fixed[title] ?? title
    }

    /// A shape's kind in the Studio's language ("Ellipse" / "椭圆").
    static func shapeKind(_ kind: ShapeSpec.Kind) -> String {
        guard chinese else { return kind.title }
        switch kind {
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .line: return "线条"
        case .arc: return "弧"
        case .curve: return "曲线"
        case .path: return "路径"
        case .path1: return "路径（填充内部）"
        case .combine: return "组合"
        }
    }

    /// An option's label: the words the design uses for the suite's settings ("Units", "单位"), else the widget's own
    /// words for it.
    static func option(_ o: StudioWidgetFacts.Option) -> String {
        let table: [String: (String, String)] = [
            "tempunit": ("Units", "单位"), "temperatureunit": ("Units", "单位"), "clockhours": ("Clock", "时钟"),
            "weekstart": ("Week Starts On", "每周第一天"), "netunit": ("Speeds In", "网速单位"),
            "location": ("City", "城市"), "language": ("Language", "语言"), "locale": ("Region", "地区"),
        ]
        if let v = o.variable?.lowercased(), let words = table[v] { return chinese ? words.1 : words.0 }
        if o.label == "Clock" { return StudioText[.clock] }
        return o.label
    }

    /// An app's name as the Mac shows it in the Studio's language ("Activity Monitor" → "活动监视器"), from the app's
    /// own localized names; the name as given when the app is not found.
    static func appName(_ name: String) -> String {
        guard chinese else { return name }
        if let cached = appNames[name] { return cached }
        var result = name
        let folders = ["/System/Applications", "/System/Applications/Utilities", "/Applications", "/Applications/Utilities"]
        if let url = folders.lazy.map({ URL(fileURLWithPath: $0).appendingPathComponent(name + ".app") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }), let bundle = Bundle(url: url) {
            if let table = bundle.url(forResource: "InfoPlist", withExtension: "loctable"),
               let all = NSDictionary(contentsOf: table) as? [String: Any],
               let zh = (all["zh_CN"] ?? all["zh-Hans"]) as? [String: Any],
               let n = (zh["CFBundleDisplayName"] ?? zh["CFBundleName"]) as? String, !n.isEmpty {
                result = n
            } else if let strings = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil,
                                                forLocalization: "zh_CN") ?? bundle.path(forResource: "InfoPlist",
                                                ofType: "strings", inDirectory: nil, forLocalization: "zh-Hans"),
                      let d = NSDictionary(contentsOfFile: strings) as? [String: String],
                      let n = d["CFBundleDisplayName"] ?? d["CFBundleName"], !n.isEmpty {
                result = n
            }
        }
        appNames[name] = result
        return result
    }

    private static var appNames: [String: String] = [:]

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
