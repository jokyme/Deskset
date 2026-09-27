import Foundation

// Web, trash, the widget itself, options and maths.

extension CatalogData {
    static let otherNamespaces: [NamespaceSpec] = [webNamespace, trashNamespace, widgetNamespace, optionsNamespace, mathNamespace]

    static func webEvery(_ en: String = "How often to read it again, at least 1min", _ zh: String = "隔多久重新读取，最短 1min") -> ParamSpec {
        arg("every", .duration, def: "10min", range: 60...86_400, en, zh)
    }

    static func webAddress() -> ParamSpec {
        pos("url", .string, role: .webAddress, source: .literalOrOption, preview: #""https://example.com/data.json""#,
            "The address; its host must be in info's network list", "网址；域名要写在 info 的 network 列表里")
    }

    static let webNamespace = namespace("web", "Web", "网络数据", [
        dataFunction("json", "JSON from the web", "网上的 JSON", [sig(webAddress(), webEvery())], .json,
                     cadence: .argument(label: "every", default: 600),
                     lower: nativeKernel("webJSON", ["URL": argument(), "every": argument("every")]),
                     doc: doc("Reads JSON from the web; fields by name, built-ins as calls (.count())", "从网上读取 JSON；按名字取字段",
                              #"Text("{web.json("https://api.example.com/v1/stats").visitors}")"#,
                              [measure("WebParser").approx("reads JSON as text with patterns")],
                              keywords: ["WebParser", "json", "api", "fetch", "rest", "网络数据"], rank: 50)),
        dataFunction("text", "Text from a web page", "网页文字", [sig(webAddress(), webEvery())], .string,
                     cadence: .argument(label: "every", default: 600),
                     lower: .measure(type: "WebParser", options: ["URL": argument()], field: nil),
                     doc: doc("Reads a page as text; use .match(pattern) to pick parts", "读取网页文字，用 .match 取出其中一段",
                              ##"Text(web.text("https://example.com").match(#"<title>(.*)</title>"#).item(1))"##,
                              [measure("WebParser", "URL"), measure("WebParser", "RegExp"), measure("WebParser", "StringIndex")],
                              keywords: ["WebParser", "URL", "RegExp", "html", "page", "scrape", "网页"], rank: 40)),
        dataFunction("feed", "News feed", "订阅源", [sig(webAddress(), webEvery())], r("Feed"),
                     cadence: .argument(label: "every", default: 600),
                     lower: nativeKernel("webFeed", ["URL": argument(), "every": argument("every")]),
                     doc: doc("Reads an RSS or Atom feed", "读取 RSS / Atom 订阅",
                              #"for item in web.feed("https://example.com/feed").items.first(5) { Text(item.title) }"#,
                              [measure("WebParser").approx("feed skins read RSS with patterns")],
                              keywords: ["WebParser", "rss", "atom", "feed", "news", "订阅"], rank: 40)),
        dataFunction("image", "Picture from the web", "网络图片", [sig(webAddress(), webEvery())], .imageSource,
                     cadence: .argument(label: "every", default: 600),
                     lower: .measure(type: "WebParser", options: ["URL": argument(), "Download": .literal("1")], field: nil),
                     doc: doc("A picture from the web", "网络图片", #"Image(web.image("https://example.com/cam.jpg")).imageMode(.fill)"#,
                              [measure("WebParser", "Download", "1")],
                              keywords: ["Download", "WebParser", "image url", "webcam", "remote image", "网络图片"], rank: 30)),
    ], doc: doc("Data from web addresses listed in info's network", "从 info 的 network 里列出的网址读取数据",
                #"Text("{web.json("https://api.example.com/v1/stats").visitors}")"#, [measure("WebParser")],
                keywords: ["WebParser", "web", "internet", "http", "网络"], rank: 45))

    static func recycle(_ type: String) -> DataLowering { pluginKernel("RecycleManager", ["RecycleType": type]) }

    static let trashNamespace = namespace("trash", "Trash", "废纸篓", main: "count", [
        field("count", "Items in the Trash", "废纸篓里的项目数", .plainNumber, cadence: .eventAndPeriodic(seconds: 60),
              lower: recycle("Count"),
              doc: doc("Items in the Trash", "废纸篓里的项目数", #"Text("{trash.count} items")"#,
                       [plugin("RecycleManager", "RecycleType", "Count")],
                       keywords: ["Count", "RecycleManager", "trash", "bin", "items", "废纸篓"], rank: 30)),
        field("size", "Size of the Trash", "废纸篓的大小", .bytes, base: 1000, cadence: .eventAndPeriodic(seconds: 60),
              lower: recycle("Size"),
              doc: doc("How much the items in the Trash take", "废纸篓里的项目占多少空间", #"Text("{trash.size}")"#,
                       [plugin("RecycleManager", "RecycleType", "Size")],
                       keywords: ["Size", "RecycleManager", "trash size", "bin size", "废纸篓大小"], rank: 25)),
        dataAction("open", "Open the Trash", "打开废纸篓", command: "OpenBin",
                   doc: doc("Opens the Trash", "打开废纸篓", ".onClick { trash.open() }",
                            [bang("!CommandMeasure", "RecycleManager OpenBin").approx("sent to a RecycleManager measure")],
                            keywords: ["OpenBin", "open trash", "打开废纸篓"], rank: 25)),
        dataAction("empty", "Empty the Trash", "清倒废纸篓", userOnly: true, command: "EmptyBin",
                   doc: doc("Empties the Trash (Finder asks first)", "清倒废纸篓（Finder 会先确认）", ".onClick { trash.empty() }",
                            [bang("!CommandMeasure", "RecycleManager EmptyBin").approx("sent to a RecycleManager measure")],
                            keywords: ["EmptyBin", "empty trash", "clear bin", "清倒废纸篓"], rank: 25)),
    ], doc: doc("The Trash", "废纸篓", #"Text("{trash.count} items")"#, [plugin("RecycleManager")],
                keywords: ["RecycleManager", "trash", "recycle bin", "废纸篓"], rank: 30))

    static let widgetNamespace = namespace("widget", "This widget", "这个组件", main: "size", [
        field("size", "Widget size", "组件尺寸", r("Size"), cadence: .event, sync: true, lower: nativeKernel("widget", field: "size"),
              doc: doc("The widget's current size and preset; compared with a preset it compares the preset", "组件当前的尺寸和档位",
                       #"Text("Details").hidden(if: widget.size == .small)"#,
                       [variable("CURRENTCONFIGWIDTH"), variable("CURRENTCONFIGHEIGHT")],
                       keywords: ["CURRENTCONFIGWIDTH", "CURRENTCONFIGHEIGHT", "size", "widget size", "dimensions", "尺寸"],
                       rank: 45)),
        dataAction("reload", "Reload the widget", "重新载入组件", command: "Refresh",
                   doc: doc("Starts the widget again; variables go back to their initial values", "重新载入组件，变量回到初始值",
                            ".onClick { widget.reload() }", [bang("!Refresh")],
                            keywords: ["Refresh", "reload", "restart", "reset", "重新载入"], rank: 30)),
        dataAction("openOptions", "Open the options", "打开选项面板", command: "OpenOptions",
                   doc: doc("Opens this widget's Options panel", "打开这个组件的选项面板", ".onDoubleClick { widget.openOptions() }",
                            keywords: ["settings", "preferences", "options", "选项"], rank: 30)),
        dataAction("edit", "Edit the widget", "编辑组件", command: "Edit",
                   doc: doc("Opens this widget in the editor", "用编辑器打开这个组件", ".onClick { widget.edit() }", [bang("!EditSkin")],
                            keywords: ["EditSkin", "edit", "editor", "编辑"], rank: 20)),
    ], doc: doc("The widget itself: its size and what it can do", "组件自己：尺寸和能做的事", ".onClick { widget.reload() }",
                keywords: ["widget", "skin", "组件"], rank: 40))

    static let optionsNamespace = namespace("options", "Options", "选项", dynamic: true, [],
        doc: doc("The user's option values, declared in options { }", "用户设置的选项值（在 options { } 里声明）",
                 ".color(options.highlight)", [variable().noted("#Variable# of [Variables]")],
                 keywords: ["Variables", "settings", "preferences", "config", "选项", "设置"], rank: 80))

    static func mathFunction(_ name: String, _ en: String, _ zh: String, _ params: [ParamSpec], _ result: DeskType,
                             docText: (String, String), example: String, rm: [RainmeterMapping], keywords: [String]) -> MemberSpec {
        dataFunction(name, en, zh, [Signature(params: params, result: .fixed(result))], result, cadence: .once, sync: true,
                     lower: .derived("math.\(name)"),
                     doc: doc(docText.0, docText.1, example, rm, keywords: keywords, rank: 20))
    }

    static func calc(_ function: String) -> RainmeterMapping { measure("Calc", "Formula").noted(function) }

    static func angleArg() -> ParamSpec {
        pos("angle", .angle, preview: "45", "An angle: a plain number is degrees; other plain values need * 1° or * 1rad",
            "角度：直接写的数字按度算；其他数要写明 * 1° 或 * 1rad")
    }

    static func plainArg(_ name: String = "x") -> ParamSpec { pos(name, .plainNumber, preview: "1", "A number", "一个数") }

    static let mathNamespace = namespace("math", "Maths", "数学", [
        mathFunction("sin", "Sine", "正弦", [angleArg()], .plainNumber, docText: ("The sine of an angle", "正弦"),
                     example: #"Text("{math.sin(45)}")"#, rm: [calc("Sin (radians)")], keywords: ["Sin", "sine", "正弦"]),
        mathFunction("cos", "Cosine", "余弦", [angleArg()], .plainNumber, docText: ("The cosine of an angle", "余弦"),
                     example: #"Text("{math.cos(45)}")"#, rm: [calc("Cos (radians)")], keywords: ["Cos", "cosine", "余弦"]),
        mathFunction("tan", "Tangent", "正切", [angleArg()], .plainNumber, docText: ("The tangent of an angle", "正切"),
                     example: #"Text("{math.tan(45)}")"#, rm: [calc("Tan (radians)")], keywords: ["Tan", "tangent", "正切"]),
        mathFunction("asin", "Arcsine", "反正弦", [plainArg()], .angle, docText: ("The angle whose sine is x", "反正弦"),
                     example: #"Text("{math.asin(0.5)}")"#, rm: [calc("Asin")], keywords: ["Asin", "arcsine", "反正弦"]),
        mathFunction("acos", "Arccosine", "反余弦", [plainArg()], .angle, docText: ("The angle whose cosine is x", "反余弦"),
                     example: #"Text("{math.acos(0.5)}")"#, rm: [calc("Acos")], keywords: ["Acos", "arccosine", "反余弦"]),
        mathFunction("atan", "Arctangent", "反正切", [plainArg()], .angle, docText: ("The angle whose tangent is x", "反正切"),
                     example: #"Text("{math.atan(1)}")"#, rm: [calc("Atan")], keywords: ["Atan", "arctangent", "反正切"]),
        mathFunction("atan2", "Angle of a point", "点的角度", [plainArg("y"), plainArg("x")], .angle,
                     docText: ("The angle of the point x, y", "点 x、y 的角度"), example: #"Text("{math.atan2(1, 1)}")"#,
                     rm: [calc("Atan2")], keywords: ["Atan2", "atan2", "angle", "角度"]),
        mathFunction("exp", "Exponential", "指数", [plainArg()], .plainNumber, docText: ("e to the power x", "e 的 x 次方"),
                     example: #"Text("{math.exp(1)}")"#, rm: [calc("Exp")], keywords: ["Exp", "exponential", "指数"]),
        mathFunction("ln", "Natural logarithm", "自然对数", [plainArg()], .plainNumber, docText: ("The natural logarithm", "自然对数"),
                     example: #"Text("{math.ln(10)}")"#, rm: [calc("Ln")], keywords: ["Ln", "natural log", "自然对数"]),
        mathFunction("log10", "Logarithm", "常用对数", [plainArg()], .plainNumber, docText: ("The base-10 logarithm", "以 10 为底的对数"),
                     example: #"Text("{math.log10(1000)}")"#, rm: [calc("Log")], keywords: ["Log", "log", "logarithm", "对数"]),
        mathFunction("power", "Power", "乘方", [plainArg("a"), plainArg("b")], .plainNumber, docText: ("a to the power b", "a 的 b 次方"),
                     example: #"Text("{math.power(2, 10)}")"#, rm: [calc("**")], keywords: ["pow", "power", "exponent", "乘方"]),
        mathFunction("sign", "Sign", "符号", [plainArg()], .plainNumber, docText: ("-1, 0 or 1 by the sign of x", "按 x 的正负返回 -1、0 或 1"),
                     example: #"Text("{math.sign(-5)}")"#, rm: [calc("Sgn")], keywords: ["Sgn", "sign", "符号"]),
        mathFunction("frac", "Fraction part", "小数部分", [plainArg()], .plainNumber, docText: ("The part after the point", "小数部分"),
                     example: #"Text("{math.frac(2.5)}")"#, rm: [calc("Frac")], keywords: ["Frac", "fraction", "小数部分"]),
        mathFunction("trunc", "Whole part", "整数部分", [plainArg()], .plainNumber, docText: ("The part before the point", "整数部分"),
                     example: #"Text("{math.trunc(2.5)}")"#, rm: [calc("Trunc")], keywords: ["Trunc", "truncate", "整数部分"]),
        field("pi", "Pi", "圆周率", .plainNumber, cadence: .once, sync: true, lower: .derived("3.141592653589793"),
              doc: doc("The constant π; as an angle, write math.pi * 1rad (= 180°)", "常数 π；当角度用时写 math.pi * 1rad",
                       #"Text("{math.pi}")"#, [calc("PI")], keywords: ["PI", "pi", "π", "圆周率"], rank: 20)),
        field("e", "e", "自然常数", .plainNumber, cadence: .once, sync: true, lower: .derived("2.718281828459045"),
              doc: doc("The constant e", "常数 e", #"Text("{math.e}")"#, [calc("E")], keywords: ["E", "euler", "自然常数"], rank: 10)),
        mathFunction("bitAnd", "Bitwise and", "按位与", [plainArg("a"), plainArg("b")], .plainNumber,
                     docText: ("The bits set in both whole numbers", "两个整数都为 1 的位"), example: #"Text("{math.bitAnd(flags, 4)}")"#,
                     rm: [calc("&")], keywords: ["and", "bitand", "&", "按位与"]),
        mathFunction("bitOr", "Bitwise or", "按位或", [plainArg("a"), plainArg("b")], .plainNumber,
                     docText: ("The bits set in either whole number", "任一个整数为 1 的位"), example: #"Text("{math.bitOr(flags, 4)}")"#,
                     rm: [calc("|")], keywords: ["or", "bitor", "|", "按位或"]),
        mathFunction("bitXor", "Bitwise exclusive or", "按位异或", [plainArg("a"), plainArg("b")], .plainNumber,
                     docText: ("The bits set in exactly one of the whole numbers", "只在一个整数里为 1 的位"),
                     example: #"Text("{math.bitXor(flags, 4)}")"#, rm: [calc("^")], keywords: ["xor", "bitxor", "^", "按位异或"]),
        mathFunction("bitNot", "Bitwise not", "按位取反", [plainArg("a")], .plainNumber,
                     docText: ("The whole number with every bit flipped", "每一位都取反的整数"), example: #"Text("{math.bitNot(flags)}")"#,
                     rm: [calc("~")], keywords: ["not", "bitnot", "~", "按位取反"]),
    ], doc: doc("Other maths: trigonometry, logarithms, powers, bit operations", "其他数学函数：三角、对数、乘方、按位运算",
                #"Text("{math.power(2, 10)}")"#, [measure("Calc", "Formula")], keywords: ["Calc", "math", "maths", "数学"],
                rank: 25))
}
