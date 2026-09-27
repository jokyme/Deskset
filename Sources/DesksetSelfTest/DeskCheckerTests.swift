import Foundation
@testable import DeskLanguage

// The checker (the language specification §4, §6, §8, §9.1 "Desk: checker …"): DESK-DESIGN §7's examples with their
// messages in both languages, the acceptance examples of DESK-DESIGN §5.1 and §5.3, and the rules of §4 one by one.

/// The type of the first interpolation's expression in `Text("{…}")`.
func deskInterpolationType(_ expression: String, declarations: String = "", options: String = "", info: String = "",
                           context: CheckContext = CheckContext()) -> (type: SemType?, ids: [String]) {
    let text = "info { name: \"T\"\(info) }\n\(options)\nwidget {\n\(declarations)\n    Text(\"{\(expression)}\")\n}\n"
    let checked = deskCheck(text, context: context)
    var found: PositionedNode?
    var stack = [checked.tree.rootNode]
    while let node = stack.popLast(), found == nil {
        if node.kind == .interpolation { found = InterpolationSyntax(unchecked: node).value.node; break }
        stack += node.childNodes.reversed()
    }
    guard let valueNode = found else { return (nil, checked.diagnostics.map(\.id.rawValue)) }
    return (checked.types[checked.tree.id(of: valueNode)], checked.diagnostics.map(\.id.rawValue))
}

/// The ids a snippet produces (wrapped in a widget with a name).
func deskIDs(of snippet: String, context: CheckContext = CheckContext()) -> [String] {
    deskCheck("info { name: \"T\" }\n" + snippet, context: context).diagnostics.map(\.id.rawValue)
}

func runDeskCheckerTests(_ t: TestRunner) {
    t.suite("Desk: checker — DESK-DESIGN §7 examples and their messages") {
        // (code, id, English message, Chinese message)
        let cases: [(String, String, String, String)] = [
            ("widget { Text(\"A\").colour(.red) }", "DK3001",
             "There's no `.colour`. Did you mean `.color`?", "没有 `.colour`，是不是想写 `.color`？"),
            ("widget { Text(“CPU”) }", "DK1001",
             "These are Chinese quotation marks; use straight quotes `\"`.", "这里用了中文引号，要换成英文的 `\"`。"),
            ("widget { Text(\"A\").font(caption) }", "DK3010",
             "Built-in names start with a dot: `.caption`.", "内置的名字前面要加点：`.caption`。"),
            ("options { weekStart = Picker(\"Week starts on\", [.sunday, .monday]) }\nwidget { Text(weekStart) }", "DK3011",
             "`weekStart` is an option; write `options.weekStart`.", "`weekStart` 是选项，要写成 `options.weekStart`。"),
            ("widget { Text(\"A\").padding(\"18px\") }", "DK4012",
             "Lengths are plain numbers in points: `18`.", "长度直接写数字，单位是点：`18`。"),
            ("widget { Text(\"{cpuu.usage}\") }", "DK3002",
             "There's no `cpuu`. Did you mean `cpu`?", "没有 `cpuu`，是不是想写 `cpu`？"),
            ("widget { Text(\"A\").color(.red).color(.blue) }", "DK5001",
             "`.color` is written twice; keep one. To change it when something is true, write `.color(…, if: …)`.",
             "`.color` 写了两次，只能留一个。想按条件变化，写 `.color(…, if: …)`。"),
            ("info { network: [\"x.com\"] }\nwidget { Progress(web.json(\"https://x.com/a\").count) }", "DK4020",
             "This value has no known range, so the progress bar doesn't know what full is: add `total:`.",
             "这个值没有已知的范围，进度条不知道满格是多少：加上 `total:`。"),
            ("widget {\n    Column {\n        Row {\n            Text(\"A\")\n        .padding(14)\n    }\n}", "DK2001",
             "The `{` of `Row {` on line 4 has no matching `}`.", "第 4 行 `Row {` 的 `{` 没有配对的 `}`。"),
            ("widget { if cpu.usage > 1 && battery.charging { Text(\"A\") } }", "DK9001",
             "Desk writes `and`: `cpu.usage > 1 and battery.charging`.", "Desk 里写 `and`：`cpu.usage > 1 and battery.charging`。"),
            ("widget { VStack { Text(\"A\") } }", "DK9101",
             "This is SwiftUI; in Desk write `Column`.", "这是 SwiftUI 的写法；Desk 里写 `Column`。"),
            ("widget {\n    Text(\"A\")\n    FontColor=255,255,255\n}", "DK9301",
             "This is Rainmeter; in Desk write `.color(\"#FFFFFF\")`.", "这是 Rainmeter 的写法；Desk 里写 `.color(\"#FFFFFF\")`。"),
            ("widget {\n    <div>\n    Text(\"A\")\n}", "DK9201",
             "This is HTML; in Desk use `Column { … }` or `Row { … }`.", "这是 HTML；Desk 里用`Column { … }` 或 `Row { … }`。"),
            ("widget {\n    Text(\"A\")\n    flex-direction: row;\n}", "DK9202",
             "This is CSS; in Desk write `Row { … }`.", "这是 CSS；Desk 里写 `Row { … }`。"),
            ("widget { Text(\"{music.title}\") }", "DK8101",
             "This widget reads and controls what's playing, so it needs `permissions: [.music]` in `info`.",
             "这个组件要读取和控制正在播放的音乐，需要在 `info` 里加上 `permissions: [.music]`。"),
            ("info { network: [\"x.com\"], permissions: [.music] }\nwidget { Text(\"{web.json(\"https://x.com/?q={music.title}\").a}\") }", "DK8201",
             "Background web addresses can't contain live data, so your information isn't sent anywhere; write the address out, or take it from an option.",
             "后台联网的地址里不能放实时数据，免得把你的信息发出去；地址要写死，或者来自选项。"),
            ("widget {\n    Column {\n        Freeform { Text(\"A\").name(title) }\n        Freeform { Text(\"B\").position(x: title.right) }\n    }\n}", "DK6002",
             "You can only refer to elements in the same Freeform: `title` is in another container.",
             "只能引用同一个自由容器里的元素：`title` 在另一个容器里。"),
        ]
        for (code, id, en, zh) in cases {
            let text = code.hasPrefix("info {") ? code.replacingOccurrences(of: "info { ", with: "info { name: \"T\", ") : "info { name: \"T\" }\n" + code
            let checked = deskCheck(text)
            let matching = checked.diagnostics.filter { $0.id.rawValue == id }
            t.equal(matching.count, 1, "\(id): \(checked.diagnostics.map(\.id.rawValue))")
            t.equal(checked.diagnostics.map(\.id.rawValue), [id], "\(id) alone")
            if let d = matching.first {
                t.equal(d.message(in: .english), en, "\(id) English")
                t.equal(d.message(in: .simplifiedChinese), zh, "\(id) Chinese")
            }
        }
        // Content that does not fit (with the layout pass).
        var context = CheckContext()
        context.layout = DeskFakeLayout()
        let tall = "info { name: \"T\", size: .small }\nwidget {\n    Column {\n" + String(repeating: "        Text(\"A\").font(40)\n", count: 4) + "    }\n}"
        let checked = deskCheck(tall, context: context)
        t.equal(checked.diagnostics.map(\.id.rawValue), ["DK6101"])
        if let d = checked.diagnostics.first {
            t.check(d.message(in: .english).hasPrefix("The content is about "), d.message(in: .english))
            t.check(d.message(in: .english).contains("pt taller than the small size: use `size: .large`"), d.message(in: .english))
            t.check(d.message(in: .simplifiedChinese).hasPrefix("内容比小号高了约 "), d.message(in: .simplifiedChinese))
        }
    }

    t.suite("Desk: acceptance — DESK-DESIGN §5.1 and §5.3") {
        for name in ["CPU", "MonthView"] {
            let url = deskFixtures.appendingPathComponent("Acceptance/\(name).desk")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { t.check(false, "missing \(name)"); continue }
            let tree = Desk.parse(text, file: DeskFileID(path: "\(name).desk"))
            let checked = Desk.check(tree)
            t.equal(checked.diagnostics.map(\.id.rawValue), [], "\(name): no diagnostics of any severity")
            t.equal(Desk.format(tree).count, 0, "\(name): canonical style")
            t.equal(checked.requirements.permissions, [], "\(name): no permission")
            t.equal(checked.requirements.hosts, [], "\(name): no host")
            t.equal(checked.requirements.minimumAppVersion, AppVersion.deskFirstRelease, "\(name): minimum 1.0")
        }
        // §5.1: names and types (Appendix B.1).
        let cpuText = try String(contentsOf: deskFixtures.appendingPathComponent("Acceptance/CPU.desk"), encoding: .utf8)
        let cpu = Desk.check(Desk.parse(cpuText, fileName: "CPU.desk"))
        let cases = cpu.symbols.values.compactMap { symbol -> String? in
            if case .enumCase(let type, let c) = symbol { return "\(c):\(type)" }
            return nil
        }
        for expected in ["small:SizePreset", "left:HAlign", "caption:FontPreset", "largeNumber:FontPreset", "dim:Color", "glass:Paint"] {
            t.check(cases.contains(expected), "CPU: \(expected) in \(cases.sorted())")
        }
        let usage = cpu.dataUses.filter { $0.memberPath == "cpu.usage" }
        t.equal(usage.count, 2, "CPU: cpu.usage read twice")
        t.check(usage.allSatisfy { $0.usage == .display }, "CPU: cpu.usage is display data")
        let percentTypes = cpu.types.values.filter { $0.type == .number(.percent) && $0.range == .fixed(0...100) }
        t.check(!percentTypes.isEmpty, "CPU: cpu.usage is a percentage from 0 to 100")
        t.equal(cpu.elements.values.filter { $0.isRoot }.map(\.component), ["Column"], "CPU: the Column is the root")

        // §5.3: Weekday, the local variables, precedence of the day cells (Appendix B.2).
        let monthText = try String(contentsOf: deskFixtures.appendingPathComponent("Acceptance/MonthView.desk"), encoding: .utf8)
        let month = Desk.check(Desk.parse(monthText, fileName: "MonthView.desk"))
        t.equal(month.options["weekStart"]?.type, .enumeration("Weekday"), "weekStart is a Weekday")
        t.equal(month.options["weekStart"]?.localEnum, nil, "no local enum")
        t.equal(month.options["highlight"]?.type, .color, "highlight is a color")
        let monthUse = month.dataUses.filter { $0.memberPath == "calendar.month" }
        t.equal(monthUse.map(\.usage), [.logic], "calendar.month drives logic (a computed value)")
        t.equal(monthUse.first?.arguments.count, 2, "calendar.month is keyed by its two arguments")
        t.equal(Set(month.loopIdentities.values), ["position", "date"], "weekday names by position, days by date")
        guard let cell = month.elements.values.first(where: { $0.facets["hidden"] != nil }) else {
            t.check(false, "the day cell")
            return
        }
        t.equal(cell.component, "Text")
        func key(_ c: Candidate?) -> String {
            guard let c else { return "none" }
            return "\(c.condition == nil ? 0 : 1),\(c.level)"
        }
        t.equal(cell.facets["font.size"]?.map(key), ["1,2", "0,2"], "font.size: todayCell (conditional) before dateCell")
        t.equal(cell.facets["font.weight"]?.map(key), ["1,2"], "font.weight: only todayCell")
        t.equal(cell.facets["color"]?.map(key), ["1,2"], "color: todayCell's white")
        t.equal(cell.facets["width"]?.map(key), ["1,2", "0,2"], "width: todayCell 24 before dateCell 28")
        t.equal(cell.facets["background"]?.map(key), ["1,2"], "background: todayCell")
        t.equal(cell.facets["hidden"]?.map(key), ["1,3"], "hidden: its own, conditional")
        if case .style(let name, _, _)? = cell.facets["width"]?.first?.origin { t.equal(name, "todayCell") }
        // The title's hover color and the arrows' style.
        let title = month.elements.values.first { $0.facets["font.size"]?.first?.fixedValue == "15" }
        t.check(title?.facets["color"]?.first?.condition == .hover, "the title's color while hovered")
        // Translations: every key is used.
        t.equal(month.translations.languages["zh-Hans"]?.count, 4)
    }

    t.suite("Desk: checker — scopes and names") {
        // Own names win over built-in values; a loop variable may reuse a data name (info DK3029 at a declaration).
        t.equal(deskIDs(of: "widget { Column { for disk in disks { Text(disk.name) } } }"), ["DK3029"])
        t.equal(deskIDs(of: "widget {\n    variable open = false\n    Text(\"{open}\").onClick { open(\"Calendar\") }\n}"), [])
        t.equal(deskIDs(of: "widget {\n    computed max = 5\n    Text(\"{max(max, 2)}\")\n}"), [])
        // Clashes between own names.
        t.equal(deskIDs(of: "widget {\n    variable title = 0\n    Text(\"{title}\").name(title)\n}"), ["DK3014"])
        t.equal(deskIDs(of: "widget {\n    variable d = 0\n    Column {\n        for d in disks { Text(d.name) }\n        Text(\"{d}\")\n    }\n}"), ["DK3014"])
        // A style or option may share a declaration's name.
        t.equal(deskIDs(of: "options { page = Toggle(\"Page\") }\nwidget {\n    variable page = 0\n    Text(\"{page}\").hidden(if: options.page).style(page)\n}\nstyle page { .bold() }"), [])
        // Reserved words and block words.
        t.equal(deskIDs(of: "widget { Column { for event in disks { Text(\"A\") } } }"), ["DK3015"])
        t.equal(deskIDs(of: "options { style = Picker(\"Style\", [\"a\", \"b\"]) }\nwidget { Text(options.style) }"), [])
        // `event` only in pointer events.
        t.equal(deskIDs(of: "widget { Text(\"A\").onClick { log(\"{event.x}\") } }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").onLoad { log(\"{event.x}\") } }"), ["DK3024"])
        // Initializers run in order; computed values may read later names.
        t.equal(deskIDs(of: "widget {\n    computed total = count * 2\n    variable count = 0\n    Text(\"{total}\")\n}"), [])
        t.equal(deskIDs(of: "widget {\n    variable total = count * 2\n    variable count = 0\n    Text(\"{total}\")\n}"), ["DK3031"])
        // Namespaces are not values; members one level down.
        t.equal(deskIDs(of: "widget { Text(time) }"), ["DK3037"])
        let deeper = deskCheck("info { name: \"T\" }\nwidget { Text(\"{weather.temperature}\") }")
        t.equal(deeper.diagnostics.map(\.id.rawValue), ["DK3003"])
        t.equal(deeper.diagnostics.first?.message(in: .english), "`weather` has no `temperature`. Did you mean `weather.now.temperature`?")
        t.equal(deskCheck("info { name: \"T\" }\nwidget { Text(\"{time.hour}\") }").diagnostics.first?.message(in: .english),
                "`time` has no `hour`. Did you mean `time.now.hour`?")
    }

    t.suite("Desk: checker — implicit members, qualified cases and local enums") {
        t.equal(deskIDs(of: "widget {\n    variable side = .left\n    Text(\"A\").align(side)\n}"), [], "settled by its use: HAlign")
        t.equal(deskIDs(of: "widget {\n    variable side = .left\n    Text(\"{side}\")\n}"), ["DK3018"])
        t.equal(deskIDs(of: "widget {\n    variable side = HAlign.left\n    Text(\"{side}\")\n}"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").color(Color.text).background(Paint.glass) }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").color(.text.opacity(50%)) }"), [], "a chain's base takes the chain's type")
        // Local enums: named after the option; their cases anywhere.
        let theme = "options { theme = Picker(\"Theme\", [.light, .dark, .sepia]) }\n"
        let checked = deskCheck("info { name: \"T\" }\n" + theme + "widget {\n    saved lastTheme = .sepia\n    Text(\"{lastTheme}\").hidden(if: options.theme == .dark or options.theme == Theme.light)\n}")
        t.equal(checked.diagnostics.map(\.id.rawValue), [])
        t.equal(checked.options["theme"]?.localEnum, "Theme")
        t.equal(checked.options["theme"]?.type, .enumeration("Theme"))
        // A local enum named like a catalog type gets `Choice`.
        let grid = deskCheck("info { name: \"T\" }\noptions { grid = Picker(\"Grid\", [.tight, .loose]) }\nwidget { Text(\"{options.grid}\") }")
        t.equal(grid.options["grid"]?.localEnum, "GridChoice")
        // Several catalog types have every choice: a local enum, with DK3032.
        let side = deskCheck("info { name: \"T\" }\noptions { side = Picker(\"Side\", [.left, .right]) }\nwidget { Text(\"{options.side}\") }")
        t.equal(side.diagnostics.map(\.id.rawValue), ["DK3032"])
        // Uses decide the Picker's type; a choice that is not a case of it is DK3005.
        let decided = deskCheck("info { name: \"T\" }\noptions { side = Picker(\"Side\", [.left, .right]) }\nwidget { Text(\"A\").align(options.side) }")
        t.equal(decided.diagnostics.map(\.id.rawValue), [])
        t.equal(decided.options["side"]?.type, .enumeration("HAlign"))
        t.equal(deskIDs(of: "info { name: \"T\" }\noptions { size = Picker(\"Size\", [.small, .large, .huge]) }\nwidget { Text(\"A\").hidden(if: widget.size == options.size) }").filter { $0 != "DK2016" }, ["DK3005"])
    }

    t.suite("Desk: checker — optional positional values and label mix-ups") {
        t.equal(deskIDs(of: "widget { Text(\"A\").font(20, .rounded) }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").font(20, .mono, .bold) }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").font(\"Futura\", .bold) }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").font(20, .bold, .semibold) }"), ["DK4004"], "the weight given twice")
        // An extra value that fits one label: the label is added.
        let hidden = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").hidden(not battery.charging) }")
        t.equal(hidden.diagnostics.map(\.id.rawValue), ["DK4003"])
        t.equal(hidden.diagnostics.first?.fixIts.first.map { TextEdit.apply($0.edits, to: hidden.tree.text) },
                "info { name: \"T\" }\nwidget { Text(\"A\").hidden(if: not battery.charging) }")
        t.equal(deskIDs(of: "widget { Grid(7) { Text(\"A\") } }"), ["DK4003"])
        t.equal(deskIDs(of: "widget { Text(\"{round(cpu.usage, 1)}\") }"), ["DK4003"])
        t.equal(deskIDs(of: "widget { Text(\"A\").border(.gray, 2) }"), ["DK4003"])
        t.equal(deskIDs(of: "options { days = Slider(\"Days\", 1...14) }\nwidget { Text(\"{options.days}\") }"), ["DK4003"])
        // Labels on positional parameters are removed.
        let size = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").size(width: 28, height: 24) }")
        t.equal(size.diagnostics.map(\.id.rawValue), ["DK3006"], "one diagnostic for the call")
        t.equal(size.diagnostics.first?.message(in: .english), "`.size` has no `width:`. It takes its values without labels: `.size(28, 24)`.")
        // `else:` becomes a plain value and the conditional one.
        let elseLabel = deskCheck("info { name: \"T\" }\nwidget {\n    variable hot = false\n    Text(\"A\").color(.red, if: hot, else: .green)\n}")
        t.equal(elseLabel.diagnostics.map(\.id.rawValue), ["DK3006"])
        t.check(elseLabel.diagnostics.first?.message(in: .english).contains(".color(.green).color(.red, if: hot)") == true,
                elseLabel.diagnostics.first?.message(in: .english) ?? "")
        // A modifier that would set nothing.
        t.equal(deskIDs(of: "widget { Text(\"A\").padding() }"), ["DK4002"])
        t.equal(deskIDs(of: "widget { Line(cpu.usage) }"), ["DK4003"])
    }

    t.suite("Desk: checker — the unit algebra, row by row (§4.4.2)") {
        let context = "options { due = DatePicker(\"Due\") }"
        func type(_ expression: String) -> String {
            let (semType, all) = deskInterpolationType(expression, options: context)
            let ids = all.filter { $0 != "DK3022" }
            if !ids.isEmpty { return ids.joined(separator: ",") }
            return semType.map { "\($0.type)" } ?? "?"
        }
        t.equal(type("time.now + 1h"), "Date", "row 1")
        t.equal(type("1h + time.now"), "Date", "row 1")
        t.equal(type("time.now - 1h"), "Date", "row 1")
        t.equal(type("options.due - time.now"), "Duration", "row 2")
        t.equal(type("sensors.cpuTemperature - sensors.gpuTemperature"), "Number(temperatureDelta)", "row 3")
        t.equal(type("sensors.gpuTemperature + 18°F"), "Number(temperature)", "row 4")
        t.equal(type("sensors.gpuTemperature - 5°C"), "Number(temperature)", "row 4")
        t.equal(type("sensors.cpuTemperature + sensors.gpuTemperature"), "DK4010", "row 5")
        t.equal(type("memory.used + 2GB"), "Bytes", "row 6")
        t.equal(type("cpu.usage + 5"), "Percent", "row 6: a plain literal adopts")
        t.equal(type("cpu.usage + memory.used"), "DK4010", "row 6")
        t.equal(type("cpu.usage * 2"), "Percent", "row 7")
        t.equal(type("50% * memory.total"), "Bytes", "row 8")
        t.equal(type("cpu.usage * 360°"), "Angle", "row 8")
        t.equal(type("memory.used / 2"), "Bytes", "row 9")
        t.equal(type("memory.used / memory.total"), "Number", "row 10")
        t.equal(type("memory.used / 2s"), "Rate", "row 11")
        t.equal(type("network.download * 2s"), "Bytes", "row 11")
        t.equal(type("memory.used / network.download"), "Duration", "row 11")
        t.equal(type("cpu.usage * cpu.usage"), "DK4010", "row 12")
        t.equal(type("-cpu.usage"), "Percent", "prefix minus")
        t.equal(type("round(memory.used)"), "Bytes", "round keeps the dimension")
        t.equal(type("max(cpu.usage, 5)"), "Percent", "max: the common dimension")
        // Comparisons.
        t.equal(deskIDs(of: "widget { Text(\"A\").hidden(if: cpu.usage > 80) }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").hidden(if: sensors.cpuTemperature > 80) }"), ["DK4011"])
        t.equal(deskIDs(of: "widget { Text(\"A\").hidden(if: sensors.cpuTemperature > 80°C) }"), [])
        t.equal(deskCheck("info { name: \"T\", permissions: [.systemAudio] }\nwidget { Text(\"A\").hidden(if: audio.level > 50%) }").diagnostics.map(\.id.rawValue), [])
        t.equal(deskCheck("info { name: \"T\", permissions: [.systemAudio] }\nwidget { Text(\"A\").hidden(if: audio.level > 50) }").diagnostics.map(\.id.rawValue), ["DK4013"])
        // DK4044 for conversions written by hand.
        t.equal(deskIDs(of: "widget { Text(\"{cpu.usage / 100}\") }"), ["DK4044"])
    }

    t.suite("Desk: checker — conversions and DK4011 through declarations and options") {
        t.equal(deskIDs(of: "widget { Text(\"A\").every(500) { log(\"x\") } }"), ["DK4011"])
        let delay = deskCheck("info { name: \"T\" }\nwidget {\n    variable delay = 500\n    Text(\"A\").onClick { after(delay) { log(\"x\") } }\n}")
        t.equal(delay.diagnostics.map(\.id.rawValue), ["DK4011"])
        t.equal(delay.diagnostics.first?.fixIts.first?.title(in: .english), "Write `500ms`")
        t.equal(delay.diagnostics.first?.message(in: .english), "`500` needs a unit here: `500ms` is 500 milliseconds, `500s` is about 8 minutes.")
        let interval = deskCheck("info { name: \"T\" }\noptions { interval = Stepper(\"Update every\", min: 100, max: 5000, default: 1000) }\nwidget { Text(\"A\").every(options.interval) { log(\"x\") } }")
        t.equal(interval.diagnostics.map(\.id.rawValue), ["DK4011", "DK4011", "DK4011"])
        let alert = deskCheck("info { name: \"T\" }\noptions { alert = Slider(\"Alert above\", min: 50, max: 100) }\nwidget { Text(\"A\").hidden(if: cpu.usage > options.alert) }")
        t.equal(alert.diagnostics.map(\.id.rawValue), [])
        t.equal(alert.options["alert"]?.type, .number(.percent), "settled by use")
        let peak = deskCheck("info { name: \"T\" }\nwidget {\n    variable peak = 0\n    Text(\"{peak}\").every(1s) { peak = max(peak, cpu.usage) }\n}")
        t.equal(peak.diagnostics.map(\.id.rawValue), [])
        // Byte literals take the base of the data they meet.
        t.equal(deskIDs(of: "widget {\n    computed low = 2GB\n    Text(\"A\").hidden(if: memory.free < low)\n}"), [])
        t.equal(deskIDs(of: "widget { Progress(memory.used, total: 16GB) }"), [])
        // Mix-ups with targeted fix-its.
        let width = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").width(100%) }")
        t.equal(width.diagnostics.map(\.id.rawValue), ["DK4001"])
        t.equal(width.diagnostics.first?.fixIts.first?.title(in: .english), "Change to `.fill`")
        t.equal(deskIDs(of: "widget { Text(\"A\").hidden(if: 1) }"), ["DK4001"])
        t.equal(deskIDs(of: "widget { Text(\"A\").rotate(cpu.usage) }"), ["DK4001"])
        t.equal(deskIDs(of: "widget { Text(\"A\").rotate(45) }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").rotate(time.now.second * 6°) }"), [])
        t.equal(deskIDs(of: "widget {\n    computed a = memory.used / memory.total\n    Text(\"A\").rotate(a)\n}"), ["DK4011"])
        t.equal(deskIDs(of: "widget {\n    variable a = 3\n    Text(\"A\").rotate(a)\n}"), [], "settled as an angle")
        t.equal(deskIDs(of: "widget { Text(\"A\").color(\"255,255,255\") }"), ["DK4016"])
        t.equal(deskIDs(of: "widget { Text(\"A\").color(255, 255, 255) }"), ["DK4003"])
        let version = deskCheck("info { name: \"T\", version: 1.0 }\nwidget { Text(\"A\") }")
        t.equal(version.diagnostics.map(\.id.rawValue), ["DK4001"])
        t.equal(version.diagnostics.first?.fixIts.first?.titleKey, "addQuotes")
    }

    t.suite("Desk: checker — precedence, soft presets and inheritance") {
        // Soft presets: `.bold()` wins the weight of `.font(.headline)`; two hard values collide.
        t.equal(deskIDs(of: "widget { Text(\"A\").font(.headline).bold() }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").font(13, .semibold).bold() }"), ["DK5002"])
        t.equal(deskIDs(of: "widget { Text(\"A\").size(28, 24).width(30) }"), ["DK5002"])
        // Conditional copies are no duplicates.
        t.equal(deskIDs(of: "widget { Text(\"A\").color(.dim).color(.red, if: cpu.usage > 80) }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").onScroll { log(\"a\") }.onScroll(.up) { log(\"b\") } }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").onScroll(.up) { log(\"a\") }.onScroll(.up) { log(\"b\") } }"), ["DK5001"])
        // The three worked cases of §4.8.5.
        let link = deskCheck("info { name: \"T\" }\nwidget { Text(\"Month\").style(link).color(.dim) }\nstyle link { .hover { .color(.accent) } }")
        t.equal(link.diagnostics.map(\.id.rawValue), [])
        let text = link.elements.values.first { $0.component == "Text" }
        t.equal(text?.facets["color"]?.first?.condition, .hover, "the style's hover beats the element's own base color")
        t.equal(text?.facets["color"]?.map(\.level), [2, 3])
        let later = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").style(base).style(accent) }\nstyle base { .color(.dim) }\nstyle accent { .color(.accent) }")
        if case .style(let name, _, _)? = later.elements.values.first?.facets["color"]?.first?.origin { t.equal(name, "accent", "the later style wins") }
        let own = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").style(card) }\nstyle base { .color(.dim) }\nstyle card { .color(.text).style(base) }")
        t.equal(own.diagnostics.map(\.id.rawValue), [])
        if case .style(let name, _, _)? = own.elements.values.first?.facets["color"]?.first?.origin {
            t.equal(name, "card", "a style's own modifiers beat the styles it includes")
        }
        // Inheritance through a container with only a conditional candidate.
        let inherit = deskCheck("info { name: \"T\" }\nwidget {\n    variable alert = false\n    Column {\n        Column { Text(\"CPU\") }.color(.red, if: alert)\n    }\n    .color(.dim)\n    .onClick { alert = not alert }\n}")
        t.equal(inherit.diagnostics.map(\.id.rawValue), [])
        let cpuText = inherit.elements.values.first { $0.component == "Text" }
        t.check(cpuText?.inherits.contains("color") == true, "the text inherits its color")
        let inner = inherit.elements.values.first { $0.component == "Column" && !$0.isRoot }
        t.check(inner?.inherits.contains("color") == true, "the inner Column's otherwise is inherited")
        t.equal(inner?.facets["color"]?.first?.condition.map { _ in 1 }, 1)
    }

    t.suite("Desk: checker — styles and options") {
        t.equal(deskIDs(of: "widget { Text(\"A\").style(s) }\nstyle s { .hidden(if: cpu.usage > 5) }"), [])
        t.equal(deskIDs(of: "widget {\n    variable page = 0\n    Text(\"{page}\").style(s)\n}\nstyle s { .hidden(if: page > 0) }"), ["DK5007"])
        t.equal(deskIDs(of: "widget { Text(\"A\").style(s) }\nstyle s { .name(x) }"), ["DK5008"])
        t.equal(deskIDs(of: "widget { Text(\"A\").hover { .style(s) } }\nstyle s { .hover { .bold() } }"), ["DK5009"])
        t.equal(deskIDs(of: "widget { Rectangle().style(s) }\nstyle s { .uppercase() }"), ["DK5005"])
        // Options.
        t.equal(deskIDs(of: "options { Toggle(\"Show seconds\") }\nwidget { Text(\"A\") }"), ["DK8013"])
        let noName = deskCheck("info { name: \"T\" }\noptions { Toggle(\"Show seconds\") }\nwidget { Text(\"A\") }")
        t.equal(noName.diagnostics.first?.fixIts.first.map { TextEdit.apply($0.edits, to: noName.tree.text) },
                "info { name: \"T\" }\noptions { showSeconds = Toggle(\"Show seconds\") }\nwidget { Text(\"A\") }")
        t.equal(deskIDs(of: "options { FontColor = ColorPicker(\"Text color\") }\nwidget { Text(\"A\").color(options.FontColor) }"), ["DK3016"])
        t.equal(deskIDs(of: "options { a = Toggle(\"A\"); b = Toggle(\"B\").hidden(if: options.a) }\nwidget { Text(\"A\").hidden(if: options.a or options.b) }"), [])
        t.equal(deskIDs(of: "options { a = Toggle(\"A\").visible(if: true) }\nwidget { Text(\"A\").hidden(if: options.a) }"), ["DK9108"])
    }

    t.suite("Desk: checker — declarations, events, timing and reactivity") {
        t.equal(deskIDs(of: "widget {\n    saved start = time.now\n    Text(\"{start}\")\n}"), ["DK4035"])
        t.equal(deskIDs(of: "widget {\n    saved note = \"\"\n    Text(note)\n}"), [])
        let used = deskCheck("info { name: \"T\" }\nwidget {\n    variable used = memory.used\n    Text(\"{used}\")\n}")
        t.equal(used.diagnostics.map(\.id.rawValue), ["DK4046"])
        t.equal(used.diagnostics.first?.severity, .warning, "never assigned: a warning")
        let assigned = deskCheck("info { name: \"T\" }\nwidget {\n    variable used = memory.used\n    Text(\"{used}\").onClick { used = memory.used }\n}")
        t.equal(assigned.diagnostics.first?.severity, .info, "assigned later: a tip")
        // User-initiated actions.
        t.equal(deskIDs(of: "widget { Text(\"A\").onClick { after(1s) { open(\"Calendar\") } } }"), [])
        t.equal(deskIDs(of: "widget { Text(\"A\").onClick { after(5s) { open(\"Calendar\") } } }"), ["DK7006"])
        t.equal(deskIDs(of: "widget { Text(\"A\").onMouseEnter { copy(\"x\") } }"), ["DK7006"])
        t.equal(deskIDs(of: "widget { Text(\"A\").menu { Item(\"Open\").onClick { open(\"Calendar\") } } }"), [])
        // Assignments.
        let playing = deskCheck("info { name: \"T\", permissions: [.music] }\nwidget { Text(\"A\").onClick { music.playing = true } }")
        t.equal(playing.diagnostics.map(\.id.rawValue), ["DK4006"])
        t.equal(playing.diagnostics.first?.fixIts.first?.edits.first?.replacement, "music.play()")
        t.equal(deskIDs(of: "widget { Text(\"A\").onClick { volume.level = 50% } }"), [])
        t.equal(deskIDs(of: "widget { Column { for d in disks { Text(d.name).onClick { d = 1 } } } }"), ["DK4006"])
        // Reactions in document order, with what they read.
        let reactions = deskCheck("info { name: \"T\" }\nwidget {\n    variable n = 0\n    Text(\"{n}\")\n        .when(cpu.usage > 90) { n = n + 1 }\n        .every(1s) { n = n + 1 }\n}")
        t.equal(reactions.reactions.map(\.kind), [.when, .every])
        t.check(reactions.reactions.first?.dependencies.contains(.data("cpu.usage")) == true)
        t.equal(reactions.reactions.last?.interval, 1)
        t.equal(reactions.dataUses.first { $0.memberPath == "cpu.usage" }?.usage, .logic, "a .when condition is logic")
        // Data read only inside an action is read on demand.
        let onDemand = deskCheck("info { name: \"T\", permissions: [.location] }\nwidget { Text(\"A\").onClick { copy(wifi.name) } }")
        t.equal(onDemand.diagnostics.map(\.id.rawValue), [])
        t.equal(onDemand.dataUses.first?.usage, .onDemand)
        // Element count and for nesting.
        t.equal(deskIDs(of: "widget { Column { for a in 1...100 { for b in 1...100 { Text(\"{a}{b}\") } } } }"), ["DK8501"])
    }

    t.suite("Desk: checker — requirements and versions") {
        let music = deskCheck("info { name: \"T\", permissions: [.music] }\nwidget { Text(music.title).onClick { music.next() } }")
        t.equal(music.diagnostics.map(\.id.rawValue), [])
        t.equal(music.requirements.permissions, ["music"])
        // The add fix-it edits info.
        let missing = deskCheck("info { name: \"T\" }\nwidget { Text(music.title) }")
        let fixed = missing.diagnostics.first?.fixIts.first.map { TextEdit.apply($0.edits, to: missing.tree.text) }
        t.equal(fixed.map { deskCheck($0).diagnostics.map(\.id.rawValue) }, [])
        // A file for a newer Deskset: DK3023 before any suggestion.
        let newer = deskCheck("info { name: \"T\", requires: \"9.0\" }\nwidget { Text(\"A\").colr(.red) }")
        t.equal(newer.diagnostics.map(\.id.rawValue), ["DK3023"])
        t.equal(newer.diagnostics.first?.fixIts.count, 0)
        // Checking for an older Deskset.
        var future = CheckContext(catalog: deskFutureCatalog(), appVersion: AppVersion(major: 1, minor: 2))
        let sparkle = deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").sparkle(2) }", context: future)
        t.equal(sparkle.diagnostics.map(\.id.rawValue), [])
        t.equal(sparkle.requirements.minimumAppVersion, AppVersion(major: 1, minor: 2))
        future.targetAppVersion = .deskFirstRelease
        t.equal(deskCheck("info { name: \"T\" }\nwidget { Text(\"A\").sparkle(2) }", context: future).diagnostics.map(\.id.rawValue), ["DK8302"])
        t.equal(deskCheck("info { name: \"T\", deskVersion: 2 }\nwidget { Txt(\"A\") }").diagnostics.map(\.id.rawValue), ["DK8301"],
                "a newer language version is the only diagnostic")
    }

    t.suite("Desk: checker — packages") {
        let package = Desk.parse("package { name: \"P\" }\noptions { accent = ColorPicker(\"Accent\") }\nstyle card { .padding(8) }\nstyle unused { .bold() }",
                                 file: DeskFileID(path: "package.desk"))
        let widget = Desk.parse("info { name: \"W\" }\nwidget { Text(\"A\").color(options.accent).style(card) }", file: DeskFileID(path: "W.desk"))
        let results = Desk.checkFolder(package: package, widgets: [widget])
        t.equal(results[DeskFileID(path: "W.desk")]?.diagnostics.map(\.id.rawValue), [])
        t.equal(results[DeskFileID(path: "package.desk")]?.diagnostics.map(\.id.rawValue), ["DK3021"], "the unused package style, once")
    }
}
