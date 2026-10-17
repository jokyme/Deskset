import Foundation

// Enums and presets (written with a leading dot: `.sunday`, `.caption`), and the named colors and paints.

extension CatalogData {
    static func enumeration(_ id: String, _ cases: [EnumCaseSpec], _ en: String, _ zh: String, _ example: String,
                            rm: [RainmeterMapping] = [], keywords: [String] = [], macOS: Int? = nil) -> EnumSpec {
        EnumSpec(id: id, cases: cases, doc: doc(en, zh, example, rm, keywords: keywords, macOS: macOS))
    }

    static func c(_ name: String, _ en: String, _ zh: String, foreign: [String] = [], keywords: [String] = [],
                  facets: [FacetID: FacetValue] = [:], rank: Int = 50, macOS: Int? = nil) -> EnumCaseSpec {
        EnumCaseSpec(name: name, title: L(en, zh), foreignSpellings: foreign, keywords: keywords, facetValues: facets,
                     rank: rank, since: v1, minimumMacOS: macOS)
    }

    static func fontPreset(_ name: String, _ en: String, _ zh: String, size: Int, weight: String, design: String? = nil,
                           equalWidth: Bool = false, rank: Int) -> EnumCaseSpec {
        var facets: [FacetID: FacetValue] = ["font.family": FacetValue(#""System""#), "font.size": FacetValue(String(size)),
                                             "font.weight": FacetValue(weight), "font.design": FacetValue(design ?? ".standard")]
        if equalWidth { facets["digits"] = FacetValue(".equalWidth") }
        return c(name, en, zh, keywords: [name.lowercased()], facets: facets, rank: rank)
    }

    static let enums: [EnumSpec] = layoutEnums + textEnums + pictureEnums + dataEnums + formatEnums

    static let layoutEnums: [EnumSpec] = [
        enumeration("Alignment", [
            c("topLeft", "Top left", "左上", foreign: ["topLeading"], keywords: ["LeftTop", "top left"]),
            c("top", "Top", "上", keywords: ["CenterTop", "top center"]),
            c("topRight", "Top right", "右上", foreign: ["topTrailing"], keywords: ["RightTop", "top right"]),
            c("left", "Left", "左", foreign: ["leading"], keywords: ["LeftCenter"]),
            c("center", "Center", "中间", keywords: ["CenterCenter", "middle"]),
            c("right", "Right", "右", foreign: ["trailing"], keywords: ["RightCenter"]),
            c("bottomLeft", "Bottom left", "左下", foreign: ["bottomLeading"], keywords: ["LeftBottom", "bottom left"]),
            c("bottom", "Bottom", "下", keywords: ["CenterBottom", "bottom center"]),
            c("bottomRight", "Bottom right", "右下", foreign: ["bottomTrailing"], keywords: ["RightBottom", "bottom right"]),
        ], "One of the nine positions in a box", "框里的九个位置之一", "Freeform(align: .topLeft) { Text(\"A\") }",
            rm: [meter("String", "StringAlign")], keywords: ["StringAlign", "anchor", "position"]),
        enumeration("HAlign", [
            c("left", "Left", "左", foreign: ["leading"], keywords: ["Left", "start"], rank: 60),
            c("center", "Center", "居中", keywords: ["Center", "middle"], rank: 60),
            c("right", "Right", "右", foreign: ["trailing"], keywords: ["Right", "end"], rank: 60),
        ], "A text alignment: left, center or right", "文字对齐：左、中、右", ".align(.right)",
            rm: [meter("String", "StringAlign")], keywords: ["StringAlign", "text alignment"]),
        enumeration("VAlign", [
            c("top", "Top", "上"), c("center", "Center", "居中", keywords: ["middle"]), c("bottom", "Bottom", "下"),
            c("baseline", "Baseline", "基线", foreign: ["firstTextBaseline"]),
        ], "How elements of a row line up top to bottom", "横排里的元素竖向怎么对齐", "Row(align: .top) { Text(\"A\"); Text(\"B\") }"),
        enumeration("Axis", [c("vertical", "Up and down", "上下"), c("horizontal", "Sideways", "左右")],
                    "A scroll direction", "滚动方向", "Scroll(.horizontal) { Text(\"A long line\") }"),
        enumeration("Direction", [
            c("right", "Right", "向右"), c("left", "Left", "向左"), c("up", "Up", "向上", keywords: ["Vertical"]),
            c("down", "Down", "向下"),
        ], "The direction a bar fills toward", "进度条的填充方向", "Progress(cpu.usage, fills: .up)",
            rm: [meter("Bar", "BarOrientation"), meter("Bar", "Flip")], keywords: ["BarOrientation"]),
        enumeration("ScrollDirection", [
            c("up", "Up", "向上"), c("down", "Down", "向下"), c("left", "Left", "向左"), c("right", "Right", "向右"),
        ], "A direction of scrolling", "滚动的方向", ".onScroll(.down) { page = page + 1 }",
            rm: [anyMeter("MouseScrollUpAction")]),
        enumeration("LengthKeyword", [
            c("fit", "Fit the content", "跟随内容", keywords: ["auto", "wrap content", "intrinsic"], rank: 60),
            c("fill", "Fill", "填满", foreign: ["infinity"], keywords: ["maxWidth", "stretch", "100%", "match parent"], rank: 60),
        ], "A size that follows the content (.fit) or takes all the room (.fill)", "跟随内容（.fit）或撑满（.fill）的尺寸",
            ".width(.fill)"),
        enumeration("SizePreset", [
            c("small", "Small", "小号", rank: 70), c("medium", "Medium", "中号", rank: 60), c("large", "Large", "大号", rank: 50),
            c("fit", "Fit the content", "跟随内容", rank: 40),
        ], "A widget size: small 170 × 170, medium 356 × 170, large 356 × 356, or fit the content",
            "组件尺寸：小号 170 × 170、中号 356 × 170、大号 356 × 356，或跟随内容", "size: .small",
            rm: [skin("SkinWidth"), skin("SkinHeight")], keywords: ["SkinWidth", "SkinHeight"]),
        enumeration("Category", [
            c("time", "Time", "时间"), c("system", "System", "系统"), c("media", "Media", "媒体"), c("weather", "Weather", "天气"),
            c("productivity", "Productivity", "效率"), c("developer", "Developer", "开发"), c("other", "Other", "其他"),
        ], "Where a widget appears in the library", "组件在小组件库里的分类", "category: .time"),
        enumeration("WindowLevel", [
            c("desktop", "On the desktop", "在桌面上", keywords: ["-2", "bottom"]),
            c("normal", "Normal", "普通", keywords: ["0"]),
            c("onTop", "Always in front", "浮在最前", keywords: ["1", "2", "topmost", "floating"]),
        ], "Where the widget's window sits", "组件窗口的层级", "level: .normal",
            rm: [skin("DefaultAlwaysOnTop")], keywords: ["DefaultAlwaysOnTop", "AlwaysOnTop", "z-order"]),
    ]

    static let textEnums: [EnumSpec] = [
        enumeration("FontPreset", [
            fontPreset("largeTitle", "Large title", "大标题", size: 26, weight: ".bold", rank: 60),
            fontPreset("title", "Title", "标题", size: 20, weight: ".semibold", rank: 65),
            fontPreset("headline", "Headline", "小标题", size: 15, weight: ".semibold", rank: 75),
            fontPreset("body", "Body", "正文", size: 13, weight: ".regular", rank: 70),
            fontPreset("callout", "Callout", "标注", size: 12, weight: ".regular", rank: 40),
            fontPreset("caption", "Caption", "说明文字", size: 11, weight: ".medium", rank: 75),
            fontPreset("footnote", "Footnote", "脚注", size: 10, weight: ".regular", rank: 45),
            fontPreset("largeNumber", "Large number", "大数字", size: 34, weight: ".semibold", design: ".rounded",
                       equalWidth: true, rank: 70),
            fontPreset("number", "Number", "数字", size: 22, weight: ".semibold", design: ".rounded", equalWidth: true, rank: 55),
        ], "A text style: a size, weight and design that fit together", "文字预设：搭配好的字号、字重和设计", ".font(.headline)",
            keywords: ["text style", "typography"]),
        enumeration("Weight", [
            c("ultralight", "Ultralight", "极细", foreign: ["ultraLight"], keywords: ["100"], rank: 20),
            c("thin", "Thin", "纤细", keywords: ["200"], rank: 30),
            c("light", "Light", "细体", keywords: ["300"], rank: 40),
            c("regular", "Regular", "常规", keywords: ["400", "normal"], rank: 60),
            c("medium", "Medium", "中等", keywords: ["500"], rank: 55),
            c("semibold", "Semibold", "半粗", keywords: ["600", "demibold"], rank: 60),
            c("bold", "Bold", "粗体", keywords: ["700"], rank: 65),
            c("heavy", "Heavy", "特粗", keywords: ["800", "extrabold"], rank: 30),
            c("black", "Black", "最粗", keywords: ["900"], rank: 20),
        ], "How heavy letters are", "字重", ".font(13, .semibold)", rm: [meter("String", "FontWeight")],
            keywords: ["FontWeight", "font weight"]),
        enumeration("FontDesign", [
            c("standard", "Standard", "标准", foreign: ["default"], rank: 50),
            c("rounded", "Rounded", "圆体", rank: 50),
            c("mono", "Monospaced", "等宽", foreign: ["monospaced"], keywords: ["monospace", "code"], rank: 40),
            c("serif", "Serif", "衬线", rank: 40),
        ], "The system font's designs", "系统字体的设计", ".font(20, .rounded)"),
        enumeration("Digits", [
            c("equalWidth", "Equal width", "等宽", foreign: ["tabular", "fixedWidth", "monospaced"], keywords: ["tabular-nums"],
              rank: 60),
            c("normal", "Normal", "普通", foreign: ["proportional"], rank: 40),
        ], "Whether digits take equal widths", "数字是否等宽", ".digits(.equalWidth)",
            rm: [meter("String", "InlineSetting", "Typography")], keywords: ["InlineSetting", "Typography"]),
        enumeration("RadiusKeyword", [
            c("full", "Round", "全圆", keywords: ["pill", "circle", "capsule", "9999"], rank: 60),
        ], "Half the shorter side: a pill or a circle", "较短边的一半：胶囊或圆形", ".rounded(.full)"),
    ]

    static let pictureEnums: [EnumSpec] = [
        enumeration("ImageMode", [
            c("fit", "Fit", "完整放入", foreign: ["contain", "inside", "scaledToFit"], keywords: ["1", "aspect fit"], rank: 60),
            c("fill", "Fill", "铺满", foreign: ["cover", "scaledToFill"], keywords: ["2", "aspect fill"], rank: 60),
            c("stretch", "Stretch", "拉伸", keywords: ["0", "scale to fill"], rank: 40),
            c("tile", "Tile", "平铺", keywords: ["repeat", "Tile"], rank: 30),
        ], "How a picture fills its box: all of it inside, covering and cropping, stretched, or tiled",
            "图片怎么放进框里：完整放入、铺满裁切、拉伸、平铺", ".imageMode(.fill)",
            rm: [meter("Image", "PreserveAspectRatio"), meter("Image", "Tile")], keywords: ["PreserveAspectRatio"]),
        enumeration("Flip", [
            c("horizontal", "Horizontal", "水平"), c("vertical", "Vertical", "竖直"), c("both", "Both", "两个方向"),
        ], "Which way a picture is mirrored", "图片怎么翻转", ".flip(.horizontal)", rm: [meter("Image", "ImageFlip")]),
        enumeration("IconColors", [
            c("monochrome", "One color", "一种颜色", keywords: ["Monochrome", "single color"], rank: 50),
            c("hierarchical", "Shades of one color", "同色深浅", keywords: ["Hierarchical"], rank: 40),
            c("multicolor", "Its own colors", "自己的颜色", keywords: ["Multicolor", "colorful"], rank: 45),
        ], "How an SF Symbol is colored", "SF 符号怎么上色", ".iconColors(.multicolor)",
            rm: [meter("Image", "MacSymbolRendering")], keywords: ["MacSymbolRendering"]),
        enumeration("IconEffect", [
            c("pulse", "Pulse", "脉动", rank: 50, macOS: 14),
            c("bounce", "Bounce", "弹跳", rank: 50, macOS: 14),
            c("breathe", "Breathe", "呼吸", rank: 40, macOS: 15),
            c("wiggle", "Wiggle", "摇摆", rank: 30, macOS: 15),
            c("rotate", "Rotate", "旋转", rank: 30, macOS: 15),
        ], "A repeating SF Symbols animation", "循环播放的 SF 符号动效", ".iconEffect(.pulse)", macOS: 14),
        enumeration("GaugeShape", [
            c("ring", "Ring", "圆环", keywords: ["donut", "circle"], rank: 60), c("arc", "Arc", "弧", keywords: ["semicircle"]),
            c("pie", "Pie", "饼", keywords: ["Solid"]), c("needle", "Needle", "指针", keywords: ["Rotator", "hand", "dial"]),
        ], "The shape of a gauge; a ring starts at 0 and sweeps 360, an arc starts at −135 and sweeps 270",
            "仪表的形状；圆环从 0 转 360 度，弧从 −135 转 270 度", "Gauge(cpu.usage, shape: .arc)",
            rm: [meter("Roundline", "Solid")]),
        enumeration("GraphShape", [
            c("line", "Line", "曲线", rank: 60), c("area", "Area", "面积", rank: 50),
            c("bars", "Bars", "柱状", foreign: ["histogram"], keywords: ["Histogram", "columns"], rank: 45),
        ], "How a graph is drawn", "曲线图的画法", "Graph(network.download, shape: .area)", rm: [meter("Histogram")]),
        enumeration("Animation", [
            c("smooth", "Smooth", "平滑", foreign: ["easeInOut", "default"], rank: 60), c("spring", "Spring", "弹性", rank: 50),
            c("linear", "Linear", "匀速", rank: 40),
        ], "How changes move", "变化的方式", ".animate(.spring)"),
        enumeration("Transition", [
            c("fade", "Fade", "淡入淡出", foreign: ["opacity"], rank: 60), c("scale", "Grow", "缩放", rank: 45),
            c("slide", "Slide", "滑入", foreign: ["move"], rank: 45),
        ], "How an element comes and goes", "元素出现和消失的方式", ".appear(.fade)"),
        enumeration("Cursor", [
            c("arrow", "Arrow", "箭头", keywords: ["default", "pointer"], rank: 40),
            c("hand", "Pointing hand", "手形", keywords: ["HAND", "pointer", "link"], rank: 60),
            c("text", "Text", "文本", keywords: ["TEXT", "ibeam"], rank: 30),
            c("crosshair", "Crosshair", "十字", keywords: ["CROSS"], rank: 20),
            c("notAllowed", "Not allowed", "禁止", keywords: ["NO"], rank: 20),
            c("resizeUpDown", "Resize up and down", "上下调整", keywords: ["SIZE_NS", "ns-resize"], rank: 15),
            c("resizeLeftRight", "Resize left and right", "左右调整", keywords: ["SIZE_WE", "ew-resize"], rank: 15),
        ], "The pointer's shape", "鼠标指针的样子", ".cursor(.hand)",
            rm: [anyMeter("MouseActionCursorName")], keywords: ["MouseActionCursorName"]),
    ]

    static let dataEnums: [EnumSpec] = [
        enumeration("Permission", [
            c("music", "Music", "音乐"), c("location", "Location", "位置"), c("calendar", "Calendar", "日历"),
            c("microphone", "Microphone", "麦克风"), c("systemAudio", "System audio", "系统声音"),
            c("commands", "Commands", "运行命令"), c("notifications", "Notifications", "通知"), c("files", "Files", "文件"),
            c("accessibility", "Accessibility", "辅助功能"),
        ], "A capability the user must allow", "需要用户同意的能力", "permissions: [.music]"),
        enumeration("Weekday", [
            c("sunday", "Sunday", "星期日", keywords: ["sun"]), c("monday", "Monday", "星期一", keywords: ["mon"]),
            c("tuesday", "Tuesday", "星期二", keywords: ["tue"]), c("wednesday", "Wednesday", "星期三", keywords: ["wed"]),
            c("thursday", "Thursday", "星期四", keywords: ["thu"]), c("friday", "Friday", "星期五", keywords: ["fri"]),
            c("saturday", "Saturday", "星期六", keywords: ["sat"]),
        ], "A day of the week; titles come from the system", "星期几；名称由系统给出", "computed month = calendar.month(weekStart: .monday)"),
        enumeration("MemoryPressure", [
            c("normal", "Normal", "正常"), c("warning", "Warning", "偏高"), c("critical", "Critical", "严重"),
        ], "How hard the Mac is working to find memory", "Mac 找内存的吃力程度", ".color(.red, if: memory.pressure == .critical)"),
        enumeration("WeatherStatus", [
            c("ready", "Ready", "就绪"), c("loading", "Loading", "加载中"), c("stale", "Out of date", "数据过时"),
            c("noLocation", "No location", "没有位置"), c("placeNotFound", "Place not found", "找不到地点"),
            c("locationDenied", "Location not allowed", "定位未获允许"), c("locationUnavailable", "Location unavailable", "无法定位"),
            c("notCovered", "Not covered", "不在服务范围"), c("refused", "Refused", "被拒绝"),
            c("rateLimited", "Too many requests", "请求太多"), c("offline", "Offline", "离线"),
            c("turnedOff", "Turned off", "已关闭"), c("preview", "Preview", "预览"),
            c("tooManyPlaces", "Too many places", "地点太多"),
        ], "The state of the weather data", "天气数据的状态", ".hidden(if: weather.status == .ready)",
            rm: [plugin("MacWeather", "Type", "Status")]),
        enumeration("SunState", [
            c("normal", "Normal", "正常"), c("midnightSun", "Midnight sun", "极昼"), c("polarNight", "Polar night", "极夜"),
        ], "Whether the sun rises and sets", "太阳是否正常升落", ".hidden(if: sun.state == .normal)",
            rm: [plugin("MacSun", "Type", "SunState")]),
        enumeration("FileSort", [
            c("name", "Name", "名称", keywords: ["Name"]), c("size", "Size", "大小", keywords: ["Size"]),
            c("date", "Date", "日期", keywords: ["Date"]), c("kind", "Kind", "种类", keywords: ["Type"]),
        ], "How files are sorted", "文件的排序方式", "for f in files(options.folder, sort: .date) { Text(f.name) }",
            rm: [plugin("FileView", "SortType")]),
        enumeration("Feature", [
            c("liquidGlass", "Liquid Glass", "液态玻璃", macOS: 26), c("symbolEffects", "Symbol effects", "符号动效", macOS: 14),
            c("sensors", "Sensors", "传感器"),
        ], "Something this Mac may or may not have", "这台 Mac 可能有也可能没有的能力", ".background(.glass, if: supports(.liquidGlass))"),
    ]

    static let formatEnums: [EnumSpec] = [
        enumeration("ByteUnit", [
            c("auto", "Best unit", "自动"), c("bytes", "Bytes", "字节"), c("kb", "KB", "KB"), c("mb", "MB", "MB"),
            c("gb", "GB", "GB"), c("tb", "TB", "TB"), c("kib", "KiB", "KiB"), c("mib", "MiB", "MiB"), c("gib", "GiB", "GiB"),
            c("tib", "TiB", "TiB"),
        ], "The unit an amount of data is shown in", "数据量显示用的单位", #"Text("{memory.used, unit: .gb}")"#,
            rm: [meter("String", "AutoScale")]),
        enumeration("TemperatureUnit", [
            c("auto", "As on this Mac", "跟随系统"), c("celsius", "°C", "°C"), c("fahrenheit", "°F", "°F"), c("kelvin", "K", "K"),
        ], "The unit a temperature is shown in", "温度显示用的单位", #"Text("{sensors.cpuTemperature, unit: .fahrenheit}")"#),
        enumeration("FrequencyUnit", [c("auto", "Best unit", "自动"), c("mhz", "MHz", "MHz"), c("ghz", "GHz", "GHz")],
                    "The unit a frequency is shown in", "频率显示用的单位", #"Text("{sensors.cpuClock, unit: .ghz}")"#),
        enumeration("UnitStyle", [
            c("none", "Number only", "只有数字"), c("short", "Short", "简短"), c("full", "Full", "完整"),
        ], "How much of the unit is shown", "单位显示多少", #"Text("{sensors.cpuTemperature, unitStyle: .full}")"#),
        enumeration("DurationStyle", [
            c("full", "Full", "完整", keywords: ["3 days 4 hours"]), c("short", "Short", "简短", keywords: ["3d 4h"]),
            c("clock", "Clock", "时钟", keywords: ["76:04:12"]),
        ], "How a duration is written", "时长的写法", #"Text("{uptime, style: .short}")"#, rm: [measure("Uptime", "Format")]),
        enumeration("DatePreset", [
            c("time", "Time", "时间"), c("date", "Date", "日期"), c("dateTime", "Date and time", "日期和时间"),
            c("weekday", "Weekday", "星期几"), c("shortWeekday", "Short weekday", "星期几（简写）"), c("month", "Month", "月份"),
            c("shortMonth", "Short month", "月份（简写）"), c("year", "Year", "年份"), c("relative", "Relative", "相对时间"),
        ], "A date format preset", "日期格式预设", #"Text("{time.now, format: .weekday}")"#, rm: [measure("Time", "Format")]),
    ]

    // MARK: Named values

    static func namedColor(_ name: String, _ en: String, _ zh: String, _ docEn: String, _ docZh: String,
                           rm: [RainmeterMapping] = [], keywords: [String] = [], rank: Int = 40) -> NamedValueSpec {
        NamedValueSpec(type: "Color", name: name, title: L(en, zh), keywords: keywords, rank: rank,
                       doc: doc(docEn, docZh, ".color(.\(name))", rm, keywords: keywords, rank: rank))
    }

    static func systemColor(_ name: String, _ en: String, _ zh: String, keywords: [String] = [], rank: Int = 40) -> NamedValueSpec {
        namedColor(name, en, zh, "The system's \(en.lowercased()), adapting to light and dark", "系统的\(zh)，随浅色和深色变化",
                   keywords: keywords, rank: rank)
    }

    static let namedValues: [NamedValueSpec] = [
        namedColor("accent", "Accent", "强调色", "The accent color the user chose in System Settings", "用户在系统设置里选的强调色",
                   rm: [variable("MACACCENTCOLOR").noted("Deskset")], keywords: ["MACACCENTCOLOR", "tint", "highlight", "brand", "强调色"],
                   rank: 90),
        namedColor("text", "Text", "文字色", "The color of text: primary label", "文字的颜色（主要文字）",
                   rm: [variable("MACLABELCOLOR").noted("Deskset")], keywords: ["MACLABELCOLOR", "primary", "label", "foreground", "文字色"],
                   rank: 85),
        namedColor("dim", "Dim", "淡色", "A dimmer text color: secondary label", "更淡的文字颜色（次要文字）",
                   rm: [variable("MACSECONDARYLABELCOLOR").noted("Deskset")],
                   keywords: ["MACSECONDARYLABELCOLOR", "secondary", "muted", "subtle", "淡色"], rank: 80),
        namedColor("faint", "Faint", "很淡", "A faint text color: tertiary label", "很淡的文字颜色（第三级文字）",
                   rm: [variable("MACTERTIARYLABELCOLOR").noted("Deskset")],
                   keywords: ["MACTERTIARYLABELCOLOR", "tertiary", "placeholder", "很淡"], rank: 55),
        namedColor("separator", "Separator", "分隔线色", "The color of separator lines", "分隔线的颜色",
                   rm: [variable("MACSEPARATORCOLOR").noted("Deskset")], keywords: ["MACSEPARATORCOLOR", "divider", "border", "分隔线"],
                   rank: 45),
        systemColor("red", "Red", "红色", rank: 70), systemColor("orange", "Orange", "橙色", rank: 60),
        systemColor("yellow", "Yellow", "黄色", rank: 55), systemColor("green", "Green", "绿色", rank: 65),
        systemColor("mint", "Mint", "薄荷绿"), systemColor("teal", "Teal", "蓝绿色"), systemColor("cyan", "Cyan", "青色"),
        systemColor("blue", "Blue", "蓝色", rank: 65), systemColor("indigo", "Indigo", "靛蓝色"),
        systemColor("purple", "Purple", "紫色", rank: 50), systemColor("pink", "Pink", "粉色"), systemColor("brown", "Brown", "棕色"),
        systemColor("gray", "Gray", "灰色", keywords: ["grey"], rank: 50),
        namedColor("white", "White", "白色", "White", "白色", rank: 70),
        namedColor("black", "Black", "黑色", "Black", "黑色", rank: 60),
        namedColor("clear", "Clear", "透明", "No color at all", "完全透明", keywords: ["transparent", "none", "透明"], rank: 50),
        NamedValueSpec(type: "Paint", name: "glass", title: L("Glass", "玻璃"), keywords: ["blur", "frosted", "material", "MacGlass"],
                       rank: 85,
                       doc: doc("Liquid Glass on macOS 26, a blur material before; only in .background", "macOS 26 上是液态玻璃，之前是毛玻璃；只能用于 .background",
                                ".background(.glass)", [anyMeter("MacGlass", "Regular"), plugin("FrostedGlass")],
                                keywords: ["MacGlass", "FrostedGlass", "blur", "frosted", "material", "acrylic", "玻璃", "毛玻璃"],
                                mac: true, rank: 85)),
        NamedValueSpec(type: "Paint", name: "clearGlass", title: L("Clear glass", "透明玻璃"), keywords: ["clear glass", "MacGlass"],
                       rank: 50,
                       doc: doc("A clearer glass that shows more of what is behind it", "更透明的玻璃，能看到更多后面的内容",
                                ".background(.clearGlass)", [anyMeter("MacGlass", "Clear")],
                                keywords: ["MacGlass", "clear glass", "transparent glass", "透明玻璃"], mac: true, rank: 50)),
    ]
}
