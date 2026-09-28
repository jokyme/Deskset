import Foundation

/// A small index of SF Symbols in everyday words, English and Chinese — how the Studio names a symbol part ("Laptop",
/// not `laptopcomputer`) and what the Add page's Symbols search finds ("umbrella", "雨伞", "rain"). The code name is
/// kept for tooltips. Names follow Apple's own words where it has them.
public enum StudioSymbolIndex {
    public struct Entry: Equatable {
        public var symbol: String
        public var english: String
        public var chinese: String
        /// More words search finds it by.
        public var keywords: [String]

        public func name(chinese: Bool) -> String { chinese ? self.chinese : english }
    }

    static func e(_ symbol: String, _ en: String, _ zh: String, _ keywords: String = "") -> Entry {
        Entry(symbol: symbol, english: en, chinese: zh,
              keywords: keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// The symbols, grouped roughly by what widgets show (this Mac, weather, time, media, everything else).
    public static let all: [Entry] = [
        e("cpu", "Chip", "芯片", "processor, CPU, 处理器"),
        e("memorychip", "Memory chip", "内存", "RAM, memory"),
        e("internaldrive", "Drive", "硬盘", "disk, storage, 磁盘, 存储"),
        e("laptopcomputer", "Laptop", "笔记本电脑", "MacBook, computer, 电脑"),
        e("desktopcomputer", "Desktop computer", "台式电脑", "iMac, computer, 电脑"),
        e("display", "Display", "显示器", "screen, monitor, 屏幕"),
        e("keyboard", "Keyboard", "键盘"),
        e("headphones", "Headphones", "耳机", "audio, 音频"),
        e("speaker.wave.2", "Speaker", "扬声器", "sound, volume, 声音, 音量"),
        e("battery.100", "Battery", "电池", "power, charge, 电量"),
        e("wifi", "Wi-Fi", "无线局域网", "wireless, network, 网络"),
        e("network", "Network", "网络", "internet, 互联网"),
        e("antenna.radiowaves.left.and.right", "Antenna", "天线", "signal, 信号"),
        e("cube.transparent", "Cube", "立方体", "GPU, graphics, 图形"),
        e("fan", "Fan", "风扇", "cooling, 散热"),
        e("thermometer.medium", "Thermometer", "温度计", "temperature, 温度"),
        e("gauge.with.dots.needle.33percent", "Gauge", "仪表", "speed, dial, 速度"),
        e("power", "Power", "电源", "on, off, 开关"),
        e("bolt.fill", "Lightning", "闪电", "power, energy, 能量, 电"),
        e("sun.max.fill", "Sun", "太阳", "sunny, clear, weather, 晴, 天气"),
        e("moon.fill", "Moon", "月亮", "night, 夜晚"),
        e("cloud.fill", "Cloud", "云", "cloudy, 多云"),
        e("cloud.sun.fill", "Sun and cloud", "晴间多云", "partly cloudy, weather, 天气"),
        e("cloud.rain.fill", "Rain", "雨云", "rainy, shower, 雨, 下雨"),
        e("cloud.snow.fill", "Snow", "雪云", "snowy, 雪, 下雪"),
        e("cloud.bolt.rain.fill", "Thunderstorm", "雷雨", "storm, 雷, 暴风雨"),
        e("umbrella.fill", "Umbrella", "雨伞", "rain, 雨"),
        e("wind", "Wind", "风", "windy, 刮风"),
        e("drop.fill", "Drop", "水滴", "humidity, water, 湿度, 水"),
        e("snowflake", "Snowflake", "雪花", "cold, 冷"),
        e("sunrise.fill", "Sunrise", "日出", "morning, 早晨"),
        e("sunset.fill", "Sunset", "日落", "evening, 傍晚"),
        e("clock", "Clock", "时钟", "time, 时间"),
        e("alarm", "Alarm", "闹钟", "wake, 起床"),
        e("timer", "Timer", "计时器", "countdown, 倒计时"),
        e("stopwatch", "Stopwatch", "秒表"),
        e("calendar", "Calendar", "日历", "date, 日期"),
        e("hourglass", "Hourglass", "沙漏", "wait, 等待"),
        e("music.note", "Music note", "音符", "song, music, 音乐, 歌"),
        e("play.fill", "Play", "播放", "start, 开始"),
        e("pause.fill", "Pause", "暂停"),
        e("forward.fill", "Next", "下一首", "skip, forward, 快进"),
        e("backward.fill", "Previous", "上一首", "back, rewind, 快退"),
        e("mic.fill", "Microphone", "麦克风", "record, 录音"),
        e("envelope.fill", "Envelope", "信封", "mail, email, 邮件"),
        e("bell.fill", "Bell", "铃铛", "notification, 通知"),
        e("message.fill", "Message", "信息", "chat, 聊天"),
        e("phone.fill", "Phone", "电话", "call, 通话"),
        e("star.fill", "Star", "星星", "favorite, 收藏"),
        e("heart.fill", "Heart", "心", "love, like, 喜欢"),
        e("flame.fill", "Flame", "火焰", "hot, fire, 热"),
        e("leaf.fill", "Leaf", "叶子", "nature, 自然"),
        e("house.fill", "House", "房子", "home, 家"),
        e("gearshape.fill", "Gear", "齿轮", "settings, 设置"),
        e("magnifyingglass", "Magnifying glass", "放大镜", "search, 搜索"),
        e("folder.fill", "Folder", "文件夹", "files, 文件"),
        e("doc.fill", "Document", "文稿", "file, 文件"),
        e("trash.fill", "Trash", "废纸篓", "delete, 删除"),
        e("lock.fill", "Lock", "锁", "secure, 安全"),
        e("person.fill", "Person", "人", "user, account, 用户"),
        e("globe", "Globe", "地球", "world, web, 世界, 网页"),
        e("location.fill", "Location", "位置", "place, 地点"),
        e("map.fill", "Map", "地图"),
        e("cart.fill", "Cart", "购物车", "shopping, 购物"),
        e("gamecontroller.fill", "Game controller", "游戏手柄", "games, Steam, 游戏"),
        e("book.fill", "Book", "书", "read, 阅读"),
        e("pencil", "Pencil", "铅笔", "write, edit, 写"),
        e("paintbrush.fill", "Paintbrush", "画笔", "paint, 画"),
        e("camera.fill", "Camera", "相机", "photo, 拍照"),
        e("photo", "Photo", "照片", "picture, image, 图片"),
        e("link", "Link", "链接", "url"),
        e("checkmark.circle.fill", "Checkmark", "勾号", "done, ok, 完成"),
        e("xmark.circle.fill", "Cross", "叉号", "close, 关闭"),
        e("exclamationmark.triangle.fill", "Warning", "警告", "alert, 注意"),
        e("info.circle.fill", "Info", "信息", "about, 关于"),
        e("arrow.up", "Up arrow", "上箭头", "upload, 上传"),
        e("arrow.down", "Down arrow", "下箭头", "download, 下载"),
        e("arrow.up.arrow.down", "Up and down arrows", "上下箭头", "network, 网速"),
        e("chart.bar.fill", "Bar chart", "柱状图", "stats, 统计"),
        e("chart.xyaxis.line", "Line chart", "曲线图", "graph, 曲线"),
    ]

    /// The entry of a symbol name: exactly, else its base without `.fill`, `.circle`, `.square` and similar endings
    /// ("cpu.fill" → Chip).
    public static func entry(for symbol: String) -> Entry? {
        let name = symbol.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return nil }
        if let found = all.first(where: { $0.symbol == name }) { return found }
        let base = baseName(name)
        return all.first { baseName($0.symbol) == base }
    }

    /// A symbol name without the endings that only change its drawing.
    static func baseName(_ symbol: String) -> String {
        let endings: Set<String> = ["fill", "circle", "square", "slash", "badge", "rectangle", "inverse", "2", "3",
                                    "100", "75", "50", "25", "0", "max", "medium", "low", "high", "left", "right"]
        var parts = symbol.split(separator: ".").map(String.init)
        while parts.count > 1, let last = parts.last, endings.contains(last) { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    /// The everyday name of a symbol ("Laptop"); a name the index does not have, in words ("Arrow triangle").
    public static func name(of symbol: String, chinese: Bool) -> String {
        if let e = entry(for: symbol) { return e.name(chinese: chinese) }
        let words = baseName(symbol.lowercased()).split(separator: ".").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The symbols `query` finds (every word in a name, a keyword or the code name, either language), best first:
    /// names that start with the query, then names that contain it, then keywords and code names.
    public static func search(_ query: String) -> [Entry] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }
        guard !terms.isEmpty else { return all }
        var found: [(Int, Int, Entry)] = []
        for (i, e) in all.enumerated() {
            let names = [fold(e.english), fold(e.chinese)]
            let others = e.keywords.map(fold) + [fold(e.symbol)]
            var score = 0
            var ok = true
            for t in terms {
                if names.contains(where: { $0.hasPrefix(t) || $0.split(separator: " ").contains { $0.hasPrefix(t) } }) {
                    score += 0
                } else if names.contains(where: { $0.contains(t) }) {
                    score += 1
                } else if others.contains(where: { $0.contains(t) }) {
                    score += 2
                } else {
                    ok = false
                    break
                }
            }
            if ok { found.append((score, i, e)) }
        }
        return found.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
