import Foundation

// Global functions and actions. Pure functions can be used anywhere an expression can; actions only in the blocks
// of events and timing modifiers; `random` only in actions and `variable` initializers.

extension CatalogData {
    static func function(_ name: String, _ en: String, _ zh: String, _ signatures: [Signature], pure: Bool = true,
                         onlyInActions: Bool = false, twin: String? = nil, data: MemberSpec? = nil,
                         permission: String? = nil, doc: Doc) -> FunctionSpec {
        FunctionSpec(name: name, kind: .function, title: L(en, zh), signatures: signatures, permission: permission,
                     pure: pure, onlyInActions: onlyInActions, actionTwin: twin, data: data, doc: doc)
    }

    static func action(_ name: String, _ en: String, _ zh: String, _ signatures: [Signature], userOnly: Bool = false,
                       block: Bool = false, permission: String? = nil, doc: Doc) -> FunctionSpec {
        FunctionSpec(name: name, kind: .action, title: L(en, zh), signatures: signatures, permission: permission,
                     userInitiatedOnly: userOnly, takesActionBlock: block, pure: false, onlyInActions: true, doc: doc)
    }

    static func number(_ name: String = "x", _ en: String = "A number", _ zh: String = "一个数") -> ParamSpec {
        pos(name, .anyNumber, preview: "1", en, zh)
    }

    static func elementTarget() -> ParamSpec {
        pos("element", .oneOf([.elementName, .string]), role: .elementName, preview: "details",
            "An element's name, written bare, or text that names one", "元素的名字（不加引号），或写着元素名字的文字")
    }

    static let functions: [FunctionSpec] = pureFunctions + actions + dataFunctions

    static let pureFunctions: [FunctionSpec] = [
        function("round", "Round", "四舍五入", [sig(number(), arg("decimals", .plainNumber, def: "0", range: 0...10, whole: true,
                                                                  "How many decimals to keep", "保留几位小数"),
                                                  result: .sameAs(param: "x"))],
                 doc: doc("Rounds, halves away from zero", "四舍五入", #"Text("{round(cpu.usage / 10)}")"#, [calc("Round", "Round(x, n)")],
                          keywords: ["Round", "round", "rounding", "四舍五入"], rank: 60)),
        function("floor", "Round down", "向下取整", [sig(number(), result: .sameAs(param: "x"))],
                 doc: doc("Rounds down", "向下取整", #"Text("{floor(uptime / 1h)}")"#, [calc("Floor")],
                          keywords: ["Floor", "floor", "round down", "向下取整"], rank: 35)),
        function("ceil", "Round up", "向上取整", [sig(number(), result: .sameAs(param: "x"))],
                 doc: doc("Rounds up", "向上取整", #"Text("{ceil(cpu.usage)}")"#, [calc("Ceil")],
                          keywords: ["Ceil", "ceil", "ceiling", "round up", "向上取整"], rank: 30)),
        function("abs", "Absolute value", "绝对值", [sig(number(), result: .sameAs(param: "x"))],
                 doc: doc("The value without its sign", "绝对值", #"Text("{abs(sensors.cpuTemperature - sensors.gpuTemperature)}")"#,
                          [calc("Abs")], keywords: ["Abs", "abs", "absolute", "绝对值"], rank: 30)),
        function("min", "Smallest", "最小", [sig(pos("values", .anyNumber, variadic: true, preview: "1, 2", "Numbers to compare",
                                                   "要比较的数"), result: .commonOf(["values"]))],
                 doc: doc("The smallest of the values", "最小值", #"Text("{min(cpu.usage, 90%)}")"#, [calc("Min")],
                          keywords: ["Min", "min", "minimum", "smallest", "最小"], rank: 40)),
        function("max", "Largest", "最大", [sig(pos("values", .anyNumber, variadic: true, preview: "1, 2", "Numbers to compare",
                                                  "要比较的数"), result: .commonOf(["values"]))],
                 doc: doc("The largest of the values", "最大值", #"Text("{max(cpu.usage, memory.usage)}%")"#, [calc("Max")],
                          keywords: ["Max", "max", "maximum", "largest", "最大"], rank: 40)),
        function("clamp", "Keep in range", "限制在范围内", [sig(
            number(), arg("min", .anyNumber, required: true, sameAs: "x", preview: "0", "The lowest it may be", "最小值"),
            arg("max", .anyNumber, required: true, sameAs: "x", preview: "3", "The highest it may be", "最大值"),
            result: .commonOf(["x", "min", "max"]))],
                 doc: doc("Keeps x between min and max", "限制在范围内", #"Text("{clamp(page, min: 0, max: 3)}")"#, [calc("Clamp")],
                          keywords: ["Clamp", "clamp", "limit", "constrain", "限制"], rank: 30)),
        function("sqrt", "Square root", "平方根", [sig(pos("x", .plainNumber, preview: "2", "A number", "一个数"),
                                                    result: .fixed(.plainNumber))],
                 doc: doc("The square root", "平方根", #"Text("{sqrt(2)}")"#, [calc("Sqrt")],
                          keywords: ["Sqrt", "sqrt", "square root", "平方根"], rank: 20)),
        function("random", "Random number", "随机数", [sig(
            pos("low", .plainNumber, whole: true, preview: "1", "The lowest", "最小"),
            pos("high", .plainNumber, whole: true, preview: "6", "The highest", "最大"), result: .fixed(.plainNumber))],
                 pure: false, onlyInActions: true,
                 doc: doc("A random whole number from low to high; actions and variable initializers only", "随机整数（只能用在动作和 variable 初始值里）",
                          ".onClick { dice = random(1, 6) }",
                          [measure("Calc", "Formula", "Random"), measure("Calc", "LowBound"), measure("Calc", "HighBound")],
                          keywords: ["Random", "random", "rand", "dice", "随机"], rank: 30)),
        function("rgb", "Color from red, green, blue", "红绿蓝颜色", [sig(
            pos("red", .plainNumber, range: 0...255, preview: "255", "Red, 0 to 255", "红，0 到 255"),
            pos("green", .plainNumber, range: 0...255, preview: "107", "Green, 0 to 255", "绿，0 到 255"),
            pos("blue", .plainNumber, range: 0...255, preview: "0", "Blue, 0 to 255", "蓝，0 到 255"),
            pos("opacity", .fraction, required: false, def: "100%", "How opaque, 0% to 100%", "不透明度，0% 到 100%"),
            result: .fixed(.color))],
                 doc: doc("A color from red, green, blue", "用红绿蓝数值写颜色", ".color(rgb(255, 107, 0))",
                          [meter("String", "FontColor").approx("colors written R,G,B,A")],
                          keywords: ["FontColor", "rgb", "rgba", "color", "颜色"], rank: 45)),
        function("color", "Color from text", "文字转颜色", [sig(pos("hex", .string, preview: ##""#FF6B00""##,
                                                                   "Text such as \"#FF6B00\"", "比如 \"#FF6B00\" 的文字"),
                                                               result: .fixed(.color))],
                 doc: doc("A color from text at run time (missing if invalid)", "运行时把文字转成颜色",
                          #".color(color(web.json("https://example.com/c").hex))"#,
                          keywords: ["hex", "parse color", "颜色"], rank: 20)),
        function("gradient", "Gradient", "渐变", [sig(
            pos("colors", .color, variadic: true, preview: ".blue, .purple", "The colors, from start to end", "从头到尾的颜色"),
            arg("angle", .angle, def: "180", "0 runs toward the top, 90 toward the right, 180 toward the bottom",
                "0 向上、90 向右、180 向下"),
            result: .fixed(.paint))],
                 doc: doc("A linear gradient; 0 runs toward the top, 90 toward the right, 180 toward the bottom", "线性渐变；角度 0 向上、90 向右、180 向下",
                          ".background(gradient(.blue, .purple))",
                          [anyMeter("SolidColor2"), anyMeter("GradientAngle"), meter("Shape", "Shape").noted("LinearGradient")],
                          keywords: ["SolidColor2", "GradientAngle", "linear-gradient", "gradient", "渐变"], rank: 40)),
        function("radialGradient", "Radial gradient", "径向渐变", [sig(
            pos("colors", .color, variadic: true, preview: ".white, .clear", "The colors, from the center out", "从中心往外的颜色"),
            result: .fixed(.paint))],
                 doc: doc("A radial gradient from the center", "从中心向外的渐变", "Circle().fill(radialGradient(.white, .clear))",
                          [meter("Shape", "Shape").noted("RadialGradient")],
                          keywords: ["radial-gradient", "RadialGradient", "radial", "径向渐变"], rank: 20)),
        function("supports", "Supports", "是否支持", [sig(pos("feature", e("Feature"), preview: ".liquidGlass",
                                                            "A feature such as .liquidGlass", "某个能力，比如 .liquidGlass"),
                                                        result: .fixed(.bool))],
                 doc: doc("Whether this Mac has a feature", "这台 Mac 是否支持某个能力", ".background(.glass, if: supports(.liquidGlass))",
                          keywords: ["available", "#available", "feature detection", "supports", "支持"], rank: 20)),
    ]

    static let actions: [FunctionSpec] = [
        action("open", "Open", "打开", [sig(pos("target", .string, preview: #""Activity Monitor""#,
                                                "An app name or bundle id, a web address, a file or folder path",
                                                "App 名称或标识符、网址、文件或文件夹路径"))],
               userOnly: true,
               doc: doc("Opens an app, a web page, a file or a folder", "打开 App、网页、文件或文件夹", #".onClick { open("Activity Monitor") }"#,
                        [bang(nil, "[\"…\"] actions"), bang("!Execute")],
                        keywords: ["Execute", "launch", "open url", "run app", "打开"], rank: 70)),
        action("copy", "Copy", "复制", [sig(pos("text", .string, role: .display, preview: #""Hello""#, "What to copy", "要复制的文字"))],
               userOnly: true,
               doc: doc("Copies text to the clipboard", "复制文字", ".onClick { copy(system.name) }", [bang("!SetClip")],
                        keywords: ["SetClip", "clipboard", "copy", "pasteboard", "复制"], rank: 40)),
        action("notify", "Notify", "发送通知", [sig(
            pos("title", .string, role: .display, translatable: true, preview: #""Battery low""#, "The notification's title", "通知的标题"),
            pos("message", .string, required: false, def: #""""#, role: .display, translatable: true, "A second line", "第二行文字"))],
               permission: "notifications",
               doc: doc("Shows a system notification (at most one a minute per widget)", "发一条系统通知（每个组件每分钟最多一条）",
                        #".when(battery.level < 20%) { notify("Battery low") }"#,
                        keywords: ["notification", "alert", "notify", "toast", "通知"], mac: true, rank: 45)),
        action("show", "Show", "显示", [sig(elementTarget())],
               doc: doc("Shows a named element; it keeps its space", "显示起了名字的元素；位置保留", ".onMouseEnter { show(details) }",
                        [bang("!ShowMeter")], keywords: ["ShowMeter", "show", "unhide", "reveal", "显示"], rank: 55)),
        action("hide", "Hide", "隐藏", [sig(elementTarget())],
               doc: doc("Hides a named element; it keeps its space", "隐藏起了名字的元素；位置保留", ".onMouseLeave { hide(details) }",
                        [bang("!HideMeter")], keywords: ["HideMeter", "hide", "conceal", "隐藏"], rank: 55)),
        action("showOrHide", "Show or hide", "显示或隐藏", [sig(elementTarget())],
               doc: doc("Shows a named element when it is hidden, hides it when it is shown", "在显示和隐藏之间切换起了名字的元素",
                        ".onClick { showOrHide(details) }", [bang("!ToggleMeter")],
                        keywords: ["ToggleMeter", "toggle", "toggle visibility", "切换显示"], rank: 45)),
        action("log", "Log", "写日志", [sig(pos("message", .string, role: .display, preview: #""clicked""#, "What to write",
                                               "要写的内容"))],
               doc: doc("Writes to the widget's log, shown in the editor", "写入组件日志（编辑器里能看到）", #".onClick { log("clicked") }"#,
                        [bang("!Log")], keywords: ["Log", "print", "console", "debug", "日志"], rank: 25)),
        action("run", "Run a command", "运行命令", [sig(
            pos("command", .string, role: .command, source: .literalOrOption, preview: #""open -a Calculator""#,
                "The command; option values reach it as separate arguments", "命令；选项的值作为独立参数传入"))],
               userOnly: true, permission: "commands",
               doc: doc("Runs a command; its output is ignored. Option values in it reach the command as separate arguments, never as command text",
                        "运行一条命令，不用输出；命令里的选项值作为独立参数传入，不会变成命令文字", #".onClick { run("open -a Calculator") }"#,
                        [plugin("RunCommand"), commandMeasure("RunCommand", "Run")],
                        keywords: ["RunCommand", "shell", "exec", "execute", "terminal", "运行命令"], rank: 30)),
        action("after", "After a delay", "等一会儿再做", [sig(
            pos("delay", .duration, range: 0...86_400, preview: "2s", "How long to wait, up to 24 hours", "等多久，最长 24 小时"))],
               block: true,
               doc: doc("Waits, then runs the block; loop variables and event keep their values from when it was scheduled", "等一会儿再执行",
                        ".onClick { show(toast); after(2s) { hide(toast) } }", [bang("!Delay")],
                        keywords: ["Delay", "delay", "setTimeout", "wait", "later", "延迟"], rank: 35)),
    ]

    static let dataFunctions: [FunctionSpec] = [
        function("files", "Files in a folder", "文件夹里的文件", [sig(
            pos("folder", .string, role: .folderPath, source: .literalOrOption, preview: "options.folder",
                "The folder, written out or chosen in the options", "文件夹：写死，或在选项里选"),
            arg("sort", e("FileSort"), def: ".name", "The order", "排序方式"),
            arg("limit", .plainNumber, def: "100", range: 1...1_000, whole: true, "At most this many files", "最多列出多少个"),
            arg("showHidden", .bool, def: "false", "Also list hidden files", "是否列出隐藏文件"),
            result: .fixed(list(r("FileItem"))))],
                 data: field("files", "Files in a folder", "文件夹里的文件", list(r("FileItem")), max: .argument("limit"),
                             cadence: .event, permission: "files",
                             lower: nativeKernel("files", ["Path": argument(), "Sort": argument("sort"), "Limit": argument("limit"),
                                                           "ShowHidden": argument("showHidden")]),
                             doc: doc("Files in a folder", "文件夹里的文件", "for f in files(options.folder) { Text(f.name) }",
                                      [plugin("FileView")], keywords: ["FileView", "files", "folder listing", "文件"])),
                 permission: "files",
                 doc: doc("Files in a folder", "文件夹里的文件", "for f in files(options.folder) { Text(f.name) }", [plugin("FileView")],
                          keywords: ["FileView", "files", "ls", "directory listing", "list files", "文件"], rank: 35)),
        function("folder", "Folder size", "文件夹大小", [sig(
            pos("path", .string, role: .folderPath, source: .literalOrOption, preview: "options.folder",
                "The folder, written out or chosen in the options", "文件夹：写死，或在选项里选"),
            result: .fixed(r("FolderInfo")))],
                 data: field("folder", "Folder size", "文件夹大小", r("FolderInfo"), cadence: .eventAndPeriodic(seconds: 60),
                             permission: "files",
                             lower: .measure(type: "Plugin", options: ["Plugin": .literal("FolderInfo"), "Folder": argument()],
                                             field: nil),
                             doc: doc("A folder's size and counts", "文件夹的大小和文件数", #"Text("{folder(options.folder).size}")"#,
                                      [plugin("FolderInfo")], keywords: ["FolderInfo", "folder size", "文件夹大小"])),
                 permission: "files",
                 doc: doc("A folder's size and counts", "文件夹的大小和文件数", #"Text("{folder(options.folder).size}")"#,
                          [plugin("FolderInfo")], keywords: ["FolderInfo", "folder size", "du", "文件夹大小"], rank: 25)),
        function("command", "Command output", "命令输出", [sig(
            pos("command", .string, role: .command, source: .literalOrOption, preview: #""~/bin/usage.sh""#,
                "The command; option values reach it as separate arguments", "命令；选项的值作为独立参数传入"),
            arg("every", .duration, def: "1min", range: 1...86_400, "How often to run it, at least 1s", "隔多久运行一次，最短 1s"),
            arg("timeout", .duration, def: "10s", range: 0...60, "Stop it after this long, at most 60s", "运行超过多久就停下，最长 60s"),
            result: .fixed(r("CommandResult")))],
                 twin: "run",
                 data: field("command", "Command output", "命令输出", r("CommandResult"),
                             cadence: .argument(label: "every", default: 60), permission: "commands",
                             lower: .measure(type: "Plugin", options: ["Plugin": .literal("RunCommand"), "Parameter": argument(),
                                                                       "Timeout": argument("timeout")], field: nil),
                             doc: doc("Runs a command and uses its output", "运行一条命令，把输出当数据",
                                      #"Text(command("~/bin/usage.sh", every: 1min).output)"#, [plugin("RunCommand")],
                                      keywords: ["RunCommand", "shell", "script", "命令"])),
                 permission: "commands",
                 doc: doc("Runs a command and uses its output (Übersicht-style scripts work as they are); option values reach it as separate arguments, never as command text",
                          "运行一条命令，把输出当数据；选项的值作为独立参数传入，不会变成命令文字",
                          #"Text(command("~/bin/usage.sh", every: 1min).output)"#, [plugin("RunCommand")],
                          keywords: ["RunCommand", "shell", "script", "exec", "Übersicht", "命令"], rank: 30)),
    ]
}
