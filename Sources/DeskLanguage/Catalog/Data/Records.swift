import Foundation

// Records: the structured values data gives (a month, a day, a disk, the weather). Their fields update with the data
// the record comes from.

extension CatalogData {
    /// A record's field.
    static func rf(_ name: String, _ en: String, _ zh: String, _ type: DeskType, _ docEn: String, _ docZh: String,
                   _ example: String, rm: [RainmeterMapping] = [], keywords: [String] = [], range: RangeSpec = .none,
                   base: Int? = nil, format: FormatDefault? = nil, max: MaxCount? = nil, permission: String? = nil,
                   mac: Bool = false, rank: Int = 30) -> MemberSpec {
        field(name, en, zh, type, range: range, max: max, base: base, format: format, permission: permission,
              doc: doc(docEn, docZh, example, rm, keywords: keywords, mac: mac, rank: rank))
    }

    static func record(_ id: String, identity: String? = nil, _ fields: [MemberSpec], _ en: String, _ zh: String,
                       _ example: String, rm: [RainmeterMapping] = [], mac: Bool = false) -> RecordSpec {
        RecordSpec(id: id, fields: fields, identityField: identity, doc: doc(en, zh, example, rm, mac: mac))
    }

    static let records: [RecordSpec] = [
        monthGrid, dayCell, calendarEvent, cpuCore, diskRecord, networkInterface, appRecord,
        record("Weather", weatherFields(automatic: false), "The weather at a place — now, today, the next hours and days",
               "天气；weather 和 weather.at(…) 都是它", #"Text("{weather.at("Oslo").now.temperature}")"#,
               rm: [plugin("MacWeather").noted("Deskset")], mac: true),
        record("Sun", sunFields(automatic: false), "The sun at a place on a day", "太阳；sun、sun.at(…)、sun.day(…) 都是它",
               #"Text("{sun.day(1).sunrise}")"#, rm: [plugin("MacSun").noted("Deskset")], mac: true),
        weatherNow, hourForecast, dayForecast, fanRecord, feedRecord, feedItem, fileItem, folderInfo, commandResult, sizeRecord,
        eventRecord,
    ]

    static let monthGrid = record("MonthGrid", [
        rf("title", "Month title", "月份标题", .string, "The month's title, such as \"September 2026\"", "月份标题，例如“2026年9月”",
           "Text(month.title)", keywords: ["title", "month name", "header", "月份"], rank: 60),
        rf("year", "Year", "年份", .plainNumber, "The year", "年份", #"Text("{month.year}")"#, keywords: ["year", "年"]),
        rf("month", "Month number", "月份数字", .plainNumber, "The month's number, 1 to 12", "月份数字，1 到 12",
           #"Text("{month.month}")"#, keywords: ["month number", "月"]),
        rf("weekdays", "Weekday names", "星期名", list(.string), "Seven short weekday names, in the week's order",
           "7 个简短的星期名，按每周的顺序", "for name in month.weekdays { Text(name) }", keywords: ["weekdays", "day names", "星期"],
           max: .fixed(7), rank: 50),
        rf("days", "Days", "日期格子", list(r("DayCell")), "42 days: six weeks, starting in the week of the 1st",
           "42 个格子：六周，从 1 号所在的那一周开始", #"for day in month.days { Text("{day.number}") }"#,
           keywords: ["days", "cells", "dates", "日期"], max: .fixed(42), rank: 60),
    ], "A month from calendar.month: title, weekday names, 42 days", "月历：标题、年、月、7 个星期名、42 个格子",
        "Text(month.title)", rm: [measure("Time").approx("skins compute the grid with Time and Calc measures")])

    static let dayCell = record("DayCell", identity: "date", [
        rf("number", "Day number", "日期数字", .plainNumber, "The day of the month", "几号",
           #"for day in month.days { Text("{day.number}") }"#, keywords: ["day", "date number", "日"], rank: 60),
        rf("date", "Date", "日期", .date, "The day's date", "这一天的日期",
           #"for day in month.days { Text("{day.date, format: "d MMM"}") }"#, keywords: ["date", "日期"]),
        rf("inMonth", "In this month", "是否本月", .bool, "Whether the day belongs to the month shown", "是否属于显示的月份",
           #"for day in month.days { Text("{day.number}").hidden(if: not day.inMonth) }"#,
           keywords: ["in month", "current month", "本月"], rank: 50),
        rf("isToday", "Today", "是否今天", .bool, "Whether the day is today", "是否是今天",
           #"for day in month.days { Text("{day.number}").bold(if: day.isToday) }"#, keywords: ["today", "is today", "今天"],
           rank: 55),
        rf("isWeekend", "Weekend", "是否周末", .bool, "Whether the day is a weekend day", "是否是周末",
           #"for day in month.days { Text("{day.number}").color(.dim, if: day.isWeekend) }"#,
           keywords: ["weekend", "saturday", "sunday", "周末"]),
        rf("weekday", "Weekday", "星期几", e("Weekday"), "The day of the week", "星期几",
           #"for day in month.days { Text("{day.weekday}") }"#, keywords: ["weekday", "day of week", "星期"]),
        rf("lunar", "Chinese calendar day", "农历", .string, "The Chinese calendar day when the Mac uses Chinese, else empty",
           "Mac 用中文时是农历日期，否则为空", "for day in month.days { Text(day.lunar) }",
           keywords: ["lunar", "chinese calendar", "农历"], mac: true),
    ], "A day of a month", "日历格子：日期数字、日期、是否本月、是否今天、是否周末、星期、农历",
        #"for day in month.days { Text("{day.number}") }"#)

    static let calendarEvent = record("CalendarEvent", identity: "id", [
        rf("id", "Event id", "日程 id", .string, "An id that stays the same for the event", "日程不变的 id",
           "for e in calendar.events(days: 3) { Text(e.id) }", keywords: ["id", "identifier"], rank: 5),
        rf("title", "Event title", "日程标题", .string, "The event's title", "日程的标题",
           "for e in calendar.events(days: 3) { Text(e.title) }", keywords: ["title", "name", "summary", "标题"], rank: 60),
        rf("calendar", "Calendar name", "日历名称", .string, "The calendar it is in", "所在的日历",
           "for e in calendar.events(days: 3) { Text(e.calendar) }", keywords: ["calendar", "日历"]),
        rf("location", "Event location", "地点", .string, "Where it takes place", "地点",
           "for e in calendar.events(days: 3) { Text(e.location) }", keywords: ["location", "place", "where", "地点"]),
        rf("start", "Start", "开始时间", .date, "When it starts", "开始时间",
           #"for e in calendar.events(days: 3) { Text("{e.start, format: .time}") }"#, keywords: ["start", "begins", "开始"]),
        rf("end", "End", "结束时间", .date, "When it ends", "结束时间",
           #"for e in calendar.events(days: 3) { Text("{e.end, format: .time}") }"#, keywords: ["end", "finishes", "结束"]),
        rf("allDay", "All day", "全天", .bool, "Whether it lasts all day", "是否是全天日程",
           #"for e in calendar.events(days: 3) { Text(e.title).italic(if: e.allDay) }"#, keywords: ["all day", "全天"]),
        rf("color", "Calendar color", "日历颜色", .color, "The calendar's color", "所在日历的颜色",
           "for e in calendar.events(days: 3) { Circle().size(6).fill(e.color) }", keywords: ["color", "颜色"]),
    ], "An event from Calendar", "日程", "for e in calendar.events(days: 3) { Text(e.title) }", mac: true)

    static let cpuCore = record("CPUCore", identity: "number", [
        rf("number", "Core number", "核心编号", .plainNumber, "The core's number, from 1", "核心的编号，从 1 开始",
           #"for c in cpu.cores { Text("{c.number}") }"#, keywords: ["number", "index", "编号"]),
        rf("usage", "Core usage", "核心占用率", .percent, "How busy the core is", "这个核心的占用率",
           "for c in cpu.cores { Progress(c.usage) }", rm: [measure("CPU", "Processor").noted("Processor=n")],
           keywords: ["Processor", "load", "usage", "占用率"], range: .fixed(0...100), rank: 60),
    ], "A processor core", "处理器核心", "for c in cpu.cores { Progress(c.usage) }", rm: [measure("CPU")])

    static let diskRecord = record("Disk", identity: "path", [
        rf("name", "Disk name", "磁盘名称", .string, "The disk's name", "磁盘名称", "for d in disks { Text(d.name) }",
           rm: [measure("FreeDiskSpace", "Label", "1")], keywords: ["Label", "name", "volume name", "名称"], rank: 50),
        rf("path", "Disk location", "磁盘位置", .string, "The disk's mount point", "磁盘的挂载位置", "for d in disks { Text(d.path) }",
           rm: [measure("FreeDiskSpace", "Drive")], keywords: ["Drive", "mount point", "path", "位置"]),
        rf("free", "Free space", "剩余空间", .bytes, "Free space on the disk", "剩余空间", #"for d in disks { Text("{d.free}") }"#,
           rm: [measure("FreeDiskSpace")], keywords: ["FreeDiskSpace", "free", "available", "剩余"], range: .member("total"),
           base: 1000, rank: 50),
        rf("used", "Space used", "已用空间", .bytes, "Space used on the disk", "已用空间", "for d in disks { Progress(d.used) }",
           rm: [measure("FreeDiskSpace", "InvertMeasure", "1")], keywords: ["InvertMeasure", "used", "已用"], range: .member("total"),
           base: 1000, rank: 50),
        rf("total", "Disk size", "总空间", .bytes, "The disk's size", "总空间", #"for d in disks { Text("{d.total}") }"#,
           rm: [measure("FreeDiskSpace", "Total", "1")], keywords: ["Total", "size", "capacity", "总空间"], base: 1000),
        rf("usage", "Disk usage", "占用率", .percent, "Use as a percentage", "占用率", #"for d in disks { Text("{d.usage}%") }"#,
           keywords: ["usage", "percent", "占用率"], range: .fixed(0...100)),
        rf("removable", "Removable", "可移除", .bool, "Whether it can be ejected", "是否可移除",
           "for d in disks { Text(d.name).hidden(if: not d.removable) }", rm: [measure("FreeDiskSpace", "Type", "1").approx()],
           keywords: ["Type", "removable", "external", "可移除"]),
    ], "A disk (volume)", "磁盘", "for d in disks { Text(d.name) }", rm: [measure("FreeDiskSpace")])

    static let networkInterface = record("NetworkInterface", identity: "name", [
        rf("name", "Interface name", "接口名称", .string, "The interface's name, such as \"en0\"", "接口的名字，比如 \"en0\"",
           #"Text(network.interface("en0").name)"#, rm: [measure("NetIn", "Interface")], keywords: ["Interface", "name", "名称"]),
        rf("download", "Download speed", "下载速度", .rate, "Current download speed", "当前下载速度",
           #"Text("{network.interface("en0").download}")"#, rm: [measure("NetIn")], keywords: ["NetIn", "download", "下载"],
           range: .observed, base: 1000, rank: 50),
        rf("upload", "Upload speed", "上传速度", .rate, "Current upload speed", "当前上传速度",
           #"Text("{network.interface("en0").upload}")"#, rm: [measure("NetOut")], keywords: ["NetOut", "upload", "上传"],
           range: .observed, base: 1000),
        rf("total", "Network speed", "合计速度", .rate, "Download and upload combined", "下载和上传的合计",
           #"Text("{network.interface("en0").total}")"#, rm: [measure("NetTotal")], keywords: ["NetTotal", "total", "合计"],
           range: .observed, base: 1000),
        rf("downloaded", "Data received", "已接收", .bytes, "Received since the Mac started", "开机以来收到的数据量",
           #"Text("{network.interface("en0").downloaded}")"#, rm: [measure("NetIn", "Cumulative", "1")],
           keywords: ["Cumulative", "received", "已接收"], range: .observed, base: 1000),
        rf("uploaded", "Data sent", "已发送", .bytes, "Sent since the Mac started", "开机以来发出的数据量",
           #"Text("{network.interface("en0").uploaded}")"#, rm: [measure("NetOut", "Cumulative", "1")],
           keywords: ["Cumulative", "sent", "已发送"], range: .observed, base: 1000),
    ], "One network interface", "网络接口", #"Text("{network.interface("en0").download}")"#, rm: [measure("NetIn")])

    static let appRecord = record("App", identity: "bundleId", [
        rf("name", "App name", "App 名称", .string, "The app's name", "App 的名字", "Text(apps.frontmost.name)",
           keywords: ["name", "app name", "名称"], rank: 50),
        rf("bundleId", "Bundle id", "App 标识符", .string, "The app's bundle identifier", "App 的标识符",
           "Text(apps.frontmost.bundleId)", keywords: ["bundle id", "identifier", "标识符"], rank: 10),
        rf("fullScreen", "Full screen", "是否全屏", .bool, "Whether the app is full screen", "App 是否全屏",
           ".hidden(if: apps.frontmost.fullScreen)", rm: [plugin("IsFullScreen")],
           keywords: ["IsFullScreen", "full screen", "fullscreen", "全屏"]),
        rf("windowTitle", "Window title", "窗口标题", .string, "The front window's title; needs .accessibility",
           "最前面窗口的标题；需要 .accessibility", "Text(apps.frontmost.windowTitle)", rm: [plugin("GetActiveTitle")],
           keywords: ["GetActiveTitle", "window title", "title", "窗口标题"], permission: "accessibility"),
    ], "An app", "App", "Text(apps.frontmost.name)", mac: true)

    /// The fields of a weather sample (now, an hour, most of a day).
    static func weatherSampleFields(_ base: String, feelsLike: Bool = true) -> [MemberSpec] {
        func ex(_ member: String, _ text: String = "") -> String {
            base == "weather.now" ? #"Text("{weather.now.\#(member)}\#(text)")"#
                : #"for h in weather.hourly.first(6) { Text("{h.\#(member)}\#(text)") }"#
        }
        var fields: [MemberSpec] = [
            rf("temperature", "Temperature", "气温", .temperature, "The temperature", "气温", ex("temperature"),
               rm: [macWeather("Temperature")], keywords: ["Temperature", "temp", "temperature", "degrees", "气温", "温度"],
               mac: true, rank: 80),
        ]
        if feelsLike {
            fields.append(rf("feelsLike", "Feels like", "体感温度", .temperature, "How warm it feels", "体感温度", ex("feelsLike"),
                             rm: [macWeather("FeelsLike")], keywords: ["FeelsLike", "feels like", "apparent", "体感"], mac: true))
        }
        fields += [
            rf("dewPoint", "Dew point", "露点", .temperature, "The dew point", "露点", ex("dewPoint"), rm: [macWeather("DewPoint")],
               keywords: ["DewPoint", "dew point", "露点"], mac: true, rank: 10),
            rf("condition", "Conditions", "天气状况", .string, "The conditions in words, in the display language", "天气状况的文字",
               ex("condition"), rm: [macWeather("Condition")], keywords: ["Condition", "summary", "sky", "天气"], mac: true, rank: 60),
            rf("conditionCode", "Condition code", "天气代码", .string, "MET Norway's code for the conditions", "挪威气象局的天气代码",
               ex("conditionCode"), rm: [macWeather("SymbolCode")], keywords: ["SymbolCode", "code", "天气代码"], mac: true, rank: 5),
            rf("symbol", "Weather symbol", "天气图标", .symbolName, "An SF Symbol for the conditions", "天气的 SF 符号",
               base == "weather.now" ? "Icon(weather.now.symbol)" : "for h in weather.hourly.first(6) { Icon(h.symbol) }",
               rm: [macWeather("Symbol")], keywords: ["Symbol", "icon", "weather icon", "图标"], mac: true, rank: 60),
            rf("isDaylight", "Daylight", "是否白天", .bool, "Whether the sun is up there", "那里是否是白天",
               base == "weather.now" ? #"Icon("moon.fill").hidden(if: weather.now.isDaylight)"#
                   : #"for h in weather.hourly.first(6) { Icon("moon.fill").hidden(if: h.isDaylight) }"#,
               rm: [macWeather("IsDaylight")], keywords: ["IsDaylight", "day", "night", "白天"], mac: true, rank: 15),
            rf("humidity", "Humidity", "湿度", .percent, "Relative humidity", "相对湿度", ex("humidity", "%"),
               rm: [macWeather("Humidity")], keywords: ["Humidity", "humidity", "湿度"], range: .fixed(0...100), mac: true, rank: 35),
            rf("cloudCover", "Cloud cover", "云量", .percent, "How much of the sky is cloudy", "云量", ex("cloudCover", "%"),
               rm: [macWeather("CloudCover")], keywords: ["CloudCover", "clouds", "云量"], range: .fixed(0...100), mac: true, rank: 15),
            rf("fog", "Fog", "雾", .percent, "How foggy it is", "雾的程度", ex("fog", "%"), rm: [macWeather("Fog")],
               keywords: ["Fog", "fog", "mist", "雾"], range: .fixed(0...100), mac: true, rank: 5),
            rf("chanceOfRain", "Chance of rain", "降水概率", .percent, "The chance of rain", "降水概率", ex("chanceOfRain", "%"),
               rm: [macWeather("PrecipitationChance")], keywords: ["PrecipitationChance", "rain", "precipitation chance", "降水概率"],
               range: .fixed(0...100), mac: true, rank: 45),
            rf("chanceOfThunder", "Chance of thunder", "雷暴概率", .percent, "The chance of thunder", "雷暴概率",
               ex("chanceOfThunder", "%"), rm: [macWeather("ThunderChance")], keywords: ["ThunderChance", "thunder", "雷暴"],
               range: .fixed(0...100), mac: true, rank: 10),
            rf("pressure", "Air pressure", "气压", .pressure, "The air pressure", "气压", ex("pressure"), rm: [macWeather("Pressure")],
               keywords: ["Pressure", "air pressure", "barometer", "气压"], mac: true, rank: 20),
            rf("uvIndex", "UV index", "紫外线指数", .plainNumber, "The UV index", "紫外线指数", ex("uvIndex"), rm: [macWeather("UVIndex")],
               keywords: ["UVIndex", "uv", "sun index", "紫外线"], mac: true, rank: 20),
            rf("wind", "Wind speed", "风速", .speed, "The wind speed", "风速", ex("wind"), rm: [macWeather("WindSpeed")],
               keywords: ["WindSpeed", "wind", "wind speed", "风速"], mac: true, rank: 35),
            rf("gust", "Wind gusts", "阵风", .speed, "The speed of gusts", "阵风风速", ex("gust"), rm: [macWeather("WindGust")],
               keywords: ["WindGust", "gusts", "阵风"], mac: true, rank: 10),
            rf("windDirection", "Wind direction", "风向", .angle, "Where the wind comes from, in degrees", "风从哪个方向来（角度）",
               ex("windDirection"), rm: [macWeather("WindDirection")], keywords: ["WindDirection", "wind direction", "风向"],
               mac: true, rank: 15),
            rf("windFrom", "Wind from", "风向文字", .string, "Where the wind comes from, such as \"NW\"", "风向，比如 \"NW\"",
               ex("windFrom"), rm: [macWeather("WindCardinal")], keywords: ["WindCardinal", "cardinal", "风向"], mac: true, rank: 15),
            rf("beaufort", "Wind force", "风力等级", .plainNumber, "The wind force on the Beaufort scale", "蒲福风级",
               ex("beaufort"), rm: [macWeather("Beaufort")], keywords: ["Beaufort", "wind force", "风力"], mac: true, rank: 10),
            rf("precipitation", "Rain amount", "降水量", .rainfall, "Rain in the next hour", "未来一小时的降水量",
               ex("precipitation"), rm: [macWeather("Precipitation")], keywords: ["Precipitation", "rain amount", "rainfall", "降水量"],
               mac: true, rank: 25),
            rf("temperatureColor", "Temperature color", "温度颜色", .color, "A color for the temperature, from cold blue to hot red",
               "按温度变化的颜色，从冷蓝到热红",
               base == "weather.now" ? #"Text("{weather.now.temperature}").color(weather.now.temperatureColor)"#
                   : #"for h in weather.hourly.first(6) { Text("{h.temperature}").color(h.temperatureColor) }"#,
               rm: [macWeather("TemperatureColor")], keywords: ["TemperatureColor", "temperature color", "温度颜色"], mac: true,
               rank: 20),
        ]
        return fields
    }

    static let weatherNow = record("WeatherNow", weatherSampleFields("weather.now"), "The weather now", "当前天气",
                                   #"Text("{weather.now.temperature}")"#, rm: [plugin("MacWeather").noted("Deskset")], mac: true)

    static let hourForecast = record("HourForecast", identity: "time", [
        rf("time", "Hour", "时间", .date, "The hour it is for", "对应的时间", #"for h in weather.hourly.first(6) { Text("{h.time}") }"#,
           rm: [macWeather("Time")], keywords: ["Time", "hour", "time", "时间"], mac: true, rank: 50),
    ] + weatherSampleFields("weather.hourly", feelsLike: false), "The forecast for an hour", "逐小时预报",
        #"for h in weather.hourly.first(6) { Text("{h.temperature}") }"#, rm: [plugin("MacWeather", "Hour").noted("Deskset")],
        mac: true)

    static func dayField(_ name: String, _ en: String, _ zh: String, _ type: DeskType, _ docEn: String, _ docZh: String,
                         _ rmType: String, keywords: [String], range: RangeSpec = .none, text: String = "", rank: Int = 20) -> MemberSpec {
        rf(name, en, zh, type, docEn, docZh, #"for d in weather.daily.first(5) { Text("{d.\#(name)}\#(text)") }"#,
           rm: [macWeather(rmType)], keywords: [rmType] + keywords, range: range, mac: true, rank: rank)
    }

    static let dayForecast = record("DayForecast", identity: "date", [
        dayField("date", "Day", "日期", .date, "The day it is for", "对应的日期", "Time", keywords: ["date", "day", "日期"], rank: 50),
        dayField("high", "High", "最高气温", .temperature, "The day's highest temperature", "最高气温", "High",
                 keywords: ["high", "max", "maximum", "最高"], rank: 60),
        dayField("low", "Low", "最低气温", .temperature, "The day's lowest temperature", "最低气温", "Low",
                 keywords: ["low", "min", "minimum", "最低"], rank: 60),
        dayField("condition", "Conditions", "天气状况", .string, "The day's conditions in words", "天气状况", "Condition",
                 keywords: ["summary", "天气"], rank: 45),
        dayField("conditionCode", "Condition code", "天气代码", .string, "MET Norway's code for the conditions", "天气代码",
                 "SymbolCode", keywords: ["code", "天气代码"], rank: 5),
        rf("symbol", "Weather symbol", "天气图标", .symbolName, "An SF Symbol for the day", "当天天气的 SF 符号",
           "for d in weather.daily.first(5) { Icon(d.symbol) }", rm: [macWeather("Symbol")],
           keywords: ["Symbol", "icon", "图标"], mac: true, rank: 55),
        dayField("uvIndex", "UV index", "紫外线指数", .plainNumber, "The day's highest UV index", "当天最高紫外线指数", "UVIndex",
                 keywords: ["uv", "紫外线"]),
        dayField("wind", "Wind speed", "风速", .speed, "The day's strongest wind", "当天最大风速", "WindSpeed", keywords: ["wind", "风速"]),
        dayField("gust", "Wind gusts", "阵风", .speed, "The day's strongest gusts", "当天最大阵风", "WindGust", keywords: ["gusts", "阵风"]),
        dayField("beaufort", "Wind force", "风力等级", .plainNumber, "The day's highest wind force", "当天最大风力等级", "Beaufort",
                 keywords: ["wind force", "风力"]),
        dayField("precipitation", "Rain amount", "降水量", .rainfall, "The day's total rain", "当天总降水量", "Precipitation",
                 keywords: ["rain", "rainfall", "降水量"], rank: 25),
        dayField("chanceOfRain", "Chance of rain", "降水概率", .percent, "The day's chance of rain", "当天降水概率",
                 "PrecipitationChance", keywords: ["rain chance", "降水概率"], range: .fixed(0...100), text: "%", rank: 40),
        dayField("chanceOfThunder", "Chance of thunder", "雷暴概率", .percent, "The day's chance of thunder", "当天雷暴概率",
                 "ThunderChance", keywords: ["thunder", "雷暴"], range: .fixed(0...100), text: "%", rank: 10),
        rf("temperatureColor", "Temperature color", "温度颜色", .color, "A color for the day's high", "按最高气温变化的颜色",
           #"for d in weather.daily.first(5) { Text("{d.high}").color(d.temperatureColor) }"#,
           rm: [macWeather("TemperatureColor")], keywords: ["TemperatureColor", "temperature color", "温度颜色"], mac: true, rank: 15),
        dayField("sunrise", "Sunrise", "日出", .date, "The day's sunrise", "当天日出时间", "Sunrise", keywords: ["sunrise", "日出"]),
        dayField("sunset", "Sunset", "日落", .date, "The day's sunset", "当天日落时间", "Sunset", keywords: ["sunset", "日落"]),
        dayField("solarNoon", "Solar noon", "正午", .date, "The day's solar noon", "当天正午", "SolarNoon", keywords: ["noon", "正午"],
                 rank: 5),
        dayField("dayLength", "Length of the day", "白昼长度", .duration, "How long the sun is up", "白昼长度", "DayLength",
                 keywords: ["day length", "白昼长度"], rank: 10),
    ], "The forecast for a day", "逐日预报", #"for d in weather.daily.first(5) { Text("{d.high}") }"#,
        rm: [plugin("MacWeather", "Day").noted("Deskset")], mac: true)

    static let fanRecord = record("Fan", [
        rf("speed", "Fan speed", "转速", .rpm, "The fan's speed", "风扇转速", #"Text("{sensors.fan(1).speed}")"#,
           rm: [plugin("MacSensors", "Sensor").noted("fan.n")], keywords: ["MacSensors", "speed", "rpm", "转速"], range: .member("maximum"),
           mac: true, rank: 50),
        rf("minimum", "Lowest speed", "最低转速", .rpm, "The fan's lowest speed", "风扇最低转速", #"Text("{sensors.fan(1).minimum}")"#,
           rm: [plugin("MacSensors", "Sensor").noted("fan.n.min")], keywords: ["MacSensors", "min", "minimum", "最低转速"], mac: true),
        rf("maximum", "Highest speed", "最高转速", .rpm, "The fan's highest speed", "风扇最高转速", #"Text("{sensors.fan(1).maximum}")"#,
           rm: [plugin("MacSensors", "Sensor").noted("fan.n.max")], keywords: ["MacSensors", "max", "maximum", "最高转速"], mac: true),
        rf("target", "Target speed", "目标转速", .rpm, "The speed the fan is heading for", "风扇的目标转速",
           #"Text("{sensors.fan(1).target}")"#, rm: [plugin("MacSensors", "Sensor").noted("fan.n.target")],
           keywords: ["MacSensors", "target", "目标转速"], mac: true),
    ], "A fan", "风扇", "Progress(sensors.fan(1).speed)", rm: [plugin("MacSensors")], mac: true)

    static let feedRecord = record("Feed", [
        rf("title", "Feed title", "订阅源标题", .string, "The feed's title", "订阅源的标题",
           #"Text(web.feed("https://example.com/feed").title)"#, keywords: ["title", "name", "标题"]),
        rf("items", "Feed items", "订阅条目", list(r("FeedItem")), "The feed's items, newest first", "订阅条目，最新的在前",
           #"for item in web.feed("https://example.com/feed").items.first(5) { Text(item.title) }"#,
           keywords: ["items", "entries", "articles", "posts", "条目"], max: .fixed(100), rank: 50),
    ], "An RSS or Atom feed", "订阅源", #"Text(web.feed("https://example.com/feed").title)"#)

    static let feedItem = record("FeedItem", identity: "link", [
        rf("title", "Item title", "条目标题", .string, "The item's title", "条目的标题",
           #"for item in web.feed("https://example.com/feed").items.first(5) { Text(item.title) }"#,
           keywords: ["title", "headline", "标题"], rank: 50),
        rf("link", "Item link", "条目链接", .string, "The item's web address", "条目的网址",
           #"for item in web.feed("https://example.com/feed").items.first(5) { Text(item.title).onClick { open(item.link) } }"#,
           keywords: ["link", "url", "href", "链接"]),
        rf("summary", "Item summary", "条目摘要", .string, "The item's summary as plain text", "条目的摘要（纯文字）",
           #"for item in web.feed("https://example.com/feed").items.first(5) { Text(item.summary).lines(2) }"#,
           keywords: ["summary", "description", "excerpt", "摘要"]),
        rf("date", "Item date", "发布时间", .date, "When the item was published", "发布时间",
           #"for item in web.feed("https://example.com/feed").items.first(5) { Text("{item.date}") }"#,
           keywords: ["date", "published", "pubDate", "发布时间"]),
        rf("image", "Item picture", "条目图片", .imageSource, "The item's picture, if it has one", "条目的图片（如果有）",
           #"for item in web.feed("https://example.com/feed").items.first(5) { Image(item.image).size(40) }"#,
           keywords: ["image", "thumbnail", "picture", "图片"]),
    ], "An item of a feed", "订阅条目", #"for item in web.feed("https://example.com/feed").items.first(5) { Text(item.title) }"#)

    static let fileItem = record("FileItem", identity: "path", [
        rf("name", "File name", "文件名", .string, "The file's name", "文件名", "for f in files(options.folder) { Text(f.name) }",
           rm: [plugin("FileView", "Type", "FileName")], keywords: ["FileName", "name", "filename", "文件名"], rank: 50),
        rf("path", "File path", "文件路径", .string, "The file's full path", "文件的完整路径",
           "for f in files(options.folder) { Text(f.name).onClick { open(f.path) } }", rm: [plugin("FileView", "Type", "FilePath")],
           keywords: ["FilePath", "path", "路径"]),
        rf("kind", "File kind", "文件种类", .string, "The file's kind, as Finder shows it", "文件种类（和访达里一样）",
           "for f in files(options.folder) { Text(f.kind) }", rm: [plugin("FileView", "Type", "FileType")],
           keywords: ["FileType", "type", "kind", "种类"]),
        rf("size", "File size", "文件大小", .bytes, "The file's size", "文件大小", #"for f in files(options.folder) { Text("{f.size}") }"#,
           rm: [plugin("FileView", "Type", "FileSize")], keywords: ["FileSize", "size", "大小"], base: 1000),
        rf("modified", "Modified", "修改时间", .date, "When the file was last changed", "上次修改的时间",
           #"for f in files(options.folder) { Text("{f.modified}") }"#, rm: [plugin("FileView", "Type", "FileDate")],
           keywords: ["FileDate", "modified", "date", "修改时间"]),
        rf("isFolder", "Is a folder", "是否文件夹", .bool, "Whether it is a folder", "是否是文件夹",
           #"for f in files(options.folder) { Icon("folder").hidden(if: not f.isFolder) }"#, keywords: ["folder", "directory", "文件夹"]),
        rf("icon", "File icon", "文件图标", .imageSource, "The file's icon", "文件的图标",
           "for f in files(options.folder) { Image(f.icon).size(16) }", rm: [plugin("FileView", "Type", "Icon")],
           keywords: ["Icon", "icon", "图标"]),
    ], "A file in a folder", "文件", "for f in files(options.folder) { Text(f.name) }", rm: [plugin("FileView")])

    static let folderInfo = record("FolderInfo", [
        rf("size", "Folder size", "文件夹大小", .bytes, "How much the folder takes", "文件夹占用的空间",
           #"Text("{folder(options.folder).size}")"#, rm: [plugin("FolderInfo", "InfoType", "FolderSize")],
           keywords: ["FolderSize", "size", "大小"], base: 1000, rank: 50),
        rf("fileCount", "Files", "文件数", .plainNumber, "How many files it holds", "文件个数",
           #"Text("{folder(options.folder).fileCount} files")"#, rm: [plugin("FolderInfo", "InfoType", "FileCount")],
           keywords: ["FileCount", "files", "count", "文件数"]),
        rf("folderCount", "Folders", "子文件夹数", .plainNumber, "How many folders it holds", "子文件夹个数",
           #"Text("{folder(options.folder).folderCount} folders")"#, rm: [plugin("FolderInfo", "InfoType", "FolderCount")],
           keywords: ["FolderCount", "folders", "subfolders", "文件夹数"]),
    ], "A folder's size and counts", "文件夹信息", #"Text("{folder(options.folder).size}")"#, rm: [plugin("FolderInfo")])

    static let commandResult = record("CommandResult", [
        rf("output", "Output", "输出", .string, "What the command printed", "命令的输出",
           #"Text(command("~/bin/usage.sh", every: 1min).output)"#, keywords: ["output", "stdout", "result", "输出"], rank: 50),
        rf("lines", "Output lines", "输出的各行", list(.string), "The output, line by line", "按行拆开的输出",
           #"for line in command("~/bin/usage.sh", every: 1min).lines { Text(line) }"#, keywords: ["lines", "rows", "各行"],
           max: .fixed(1_000)),
        rf("number", "Output number", "输出的数字", .plainNumber, "The number the output starts with", "输出开头的数字",
           #"Progress(command("~/bin/usage.sh", every: 1min).number, total: 100)"#, keywords: ["number", "value", "数字"]),
        rf("json", "Output JSON", "输出的 JSON", .json, "The output read as JSON", "把输出当作 JSON",
           #"Text("{command("~/bin/usage.sh", every: 1min).json.count}")"#, keywords: ["json", "parse", "JSON"]),
        rf("exitCode", "Exit code", "退出码", .plainNumber, "The command's exit status", "命令的退出状态",
           #"Text("{command("~/bin/usage.sh", every: 1min).exitCode}")"#, keywords: ["exit code", "status", "退出码"], rank: 10),
        rf("running", "Running", "是否在运行", .bool, "Whether the command is still running", "命令是否还在运行",
           #"Icon("hourglass").hidden(if: not command("~/bin/usage.sh", every: 1min).running)"#, keywords: ["running", "busy", "运行中"],
           rank: 10),
        rf("error", "Error output", "错误输出", .string, "What the command printed as errors", "命令输出的错误",
           #"Text(command("~/bin/usage.sh", every: 1min).error)"#, keywords: ["error", "stderr", "错误"], rank: 10),
    ], "What a command printed", "命令结果", #"Text(command("~/bin/usage.sh", every: 1min).output)"#,
        rm: [plugin("RunCommand")])

    static let sizeRecord = record("Size", [
        rf("width", "Width", "宽度", .length, "The widget's width", "组件的宽度", #"Text("{widget.size.width}")"#,
           rm: [variable("CURRENTCONFIGWIDTH")], keywords: ["CURRENTCONFIGWIDTH", "width", "宽度"]),
        rf("height", "Height", "高度", .length, "The widget's height", "组件的高度", #"Text("{widget.size.height}")"#,
           rm: [variable("CURRENTCONFIGHEIGHT")], keywords: ["CURRENTCONFIGHEIGHT", "height", "高度"]),
        rf("preset", "Size preset", "尺寸档位", e("SizePreset"), "Small, medium, large or fit", "小号、中号、大号或跟随内容",
           #"Text("Details").hidden(if: widget.size.preset == .small)"#, keywords: ["preset", "size class", "档位"]),
    ], "The widget's size", "尺寸", #"Text("{widget.size.width}")"#)

    static let eventRecord = record("Event", [
        rf("x", "Pointer x", "指针 x", .length, "Points from the element's left edge", "离元素左边的距离（点）",
           #".onClick { log("{event.x}") }"#, rm: [variable("MouseX").noted("$MouseX$")], keywords: ["MouseX", "x", "mouse x"]),
        rf("y", "Pointer y", "指针 y", .length, "Points from the element's top edge", "离元素上边的距离（点）",
           #".onClick { log("{event.y}") }"#, rm: [variable("MouseY").noted("$MouseY$")], keywords: ["MouseY", "y", "mouse y"]),
        rf("xPercent", "Pointer x in percent", "指针 x（百分比）", .percent, "How far across the element, in percent",
           "在元素上横向的位置（百分比）", ".onDrag { volume.level = event.xPercent }", rm: [variable("MouseX:%").noted("$MouseX:%$")],
           keywords: ["MouseX:%", "x percent", "horizontal position"], range: .fixed(0...100), rank: 40),
        rf("yPercent", "Pointer y in percent", "指针 y（百分比）", .percent, "How far down the element, in percent",
           "在元素上纵向的位置（百分比）", #".onDrag { log("{event.yPercent}") }"#, rm: [variable("MouseY:%").noted("$MouseY:%$")],
           keywords: ["MouseY:%", "y percent", "vertical position"], range: .fixed(0...100)),
        rf("dx", "Dragged across", "横向拖动距离", .length, "Points dragged across since the press", "按下后横向拖动了多少点",
           #".onDrag { log("{event.dx}") }"#, keywords: ["dx", "delta x", "translation"]),
        rf("dy", "Dragged down", "纵向拖动距离", .length, "Points dragged down since the press", "按下后纵向拖动了多少点",
           #".onDrag { log("{event.dy}") }"#, keywords: ["dy", "delta y"]),
        rf("direction", "Scroll direction", "滚动方向", e("ScrollDirection"), "Which way the wheel or trackpad went", "滚轮或触控板的方向",
           ".onScroll { if event.direction == .up { page = page - 1 } }", keywords: ["direction", "wheel direction", "方向"]),
        rf("files", "Dropped files", "拖入的文件", list(.string), "The paths of files dropped on it", "拖到它上面的文件的路径",
           ".onDrop { for path in event.files { log(path) } }", keywords: ["files", "paths", "dropped files", "文件"]),
        rf("text", "Dropped text", "拖入的文字", .string, "Text dropped on it", "拖到它上面的文字", ".onDrop { copy(event.text) }",
           keywords: ["text", "dropped text", "文字"]),
    ], "What just happened: available as `event` in pointer events", "事件信息：在指针事件里用 `event` 读取",
        #".onClick { log("{event.x}") }"#)
}
