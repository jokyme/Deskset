import Foundation

// How messages name things: every type, dimension, facet, component, preset and grammar slot, in both languages,
// never with an id. Diagnostics insert these for their `{expected}`, `{actual}`, `{type}`, `{facet}`, `{what}`,
// `{component}`, `{parent}`, `{child}`, `{place}`, `{preset}` and `{candidates}` placeholders. A type's row also gives
// the plural used after "a list of" ("a list of days of a month" / "一组月历里的日子").
//
// Ids: `dimension:<Dimension>`, `type:<kind>`, `enum:<id>` (and `enum:local` for a Picker's own choices, with
// `{name}` the option), `record:<id>`, `facet:<FacetID>` (from the facet table), `component:<name>`,
// `preset:<SizePreset case>`, `slot:<grammar slot>`, `content:<what a block holds>`, `construct:<kind of code>`,
// `place:<where code is written>`, `kind:<kind of value>` (what a control was given instead of a binding).

extension CatalogData {
    static func dn(_ id: String, _ en: String, _ zh: String, plural: (String, String)? = nil) -> DisplayNameSpec {
        DisplayNameSpec(id: id, name: L(en, zh), plural: plural.map { L($0.0, $0.1) })
    }

    static let displayNames: [DisplayNameSpec] = dimensionNames + typeNames + enumNames + recordNames + facetNames
        + componentNames + presetNames + slotNames + contentNames + constructNames + placeNames + kindNames

    static let dimensionNames: [DisplayNameSpec] = [
        dn("dimension:plain", "a number", "数字", plural: ("numbers", "数字")),
        dn("dimension:length", "a length in points, such as `12`", "长度（单位是点），比如 `12`", plural: ("lengths", "长度")),
        dn("dimension:time", "a time, such as `2s` or `500ms`", "时间，比如 `2s`、`500ms`", plural: ("times", "时间")),
        dn("dimension:percent", "a percentage, such as `50%`", "百分比，比如 `50%`", plural: ("percentages", "百分比")),
        dn("dimension:bytes", "an amount of data, such as `2GB`", "数据量，比如 `2GB`", plural: ("amounts of data", "数据量")),
        dn("dimension:bytesPerSecond", "a data speed, such as `1MB/s`", "网速，比如 `1MB/s`", plural: ("data speeds", "网速")),
        dn("dimension:temperature", "a temperature, such as `30°C`", "温度，比如 `30°C`", plural: ("temperatures", "温度")),
        dn("dimension:temperatureDelta", "a difference of temperatures, such as `5°C`", "温差，比如 `5°C`",
           plural: ("differences of temperatures", "温差")),
        dn("dimension:power", "a power, such as `15W`", "功率，比如 `15W`", plural: ("powers", "功率")),
        dn("dimension:frequency", "a frequency, such as `3GHz`", "频率，比如 `3GHz`", plural: ("frequencies", "频率")),
        dn("dimension:angle", "an angle, such as `90°`", "角度，比如 `90°`", plural: ("angles", "角度")),
        dn("dimension:rpm", "a fan speed, such as `1200rpm`", "风扇转速，比如 `1200rpm`", plural: ("fan speeds", "风扇转速")),
        dn("dimension:voltage", "a voltage, such as `1.2V`", "电压，比如 `1.2V`", plural: ("voltages", "电压")),
        dn("dimension:current", "a current, such as `2A`", "电流，比如 `2A`", plural: ("currents", "电流")),
        dn("dimension:speed", "a speed, such as `20km/h`", "速度，比如 `20km/h`", plural: ("speeds", "速度")),
        dn("dimension:rainfall", "an amount of rain, such as `5mm`", "降水量，比如 `5mm`", plural: ("amounts of rain", "降水量")),
        dn("dimension:pressure", "an air pressure, such as `1013hPa`", "气压，比如 `1013hPa`", plural: ("air pressures", "气压")),
    ]

    static let typeNames: [DisplayNameSpec] = [
        dn("type:anyNumber", "a number", "数字", plural: ("numbers", "数字")),
        dn("type:fraction", "a percentage or a number from 0 to 1", "百分比，或 0 到 1 之间的数",
           plural: ("percentages or numbers from 0 to 1", "百分比或 0 到 1 之间的数")),
        dn("type:string", "text in quotes", "带引号的文字", plural: ("texts", "文字")),
        dn("type:bool", "yes or no (`true` or `false`)", "是或否（`true` 或 `false`）", plural: ("yes-or-no values", "是/否值")),
        dn("type:color", "a color, such as `.red` or `\"#FF6B00\"`", "颜色，比如 `.red` 或 `\"#FF6B00\"`", plural: ("colors", "颜色")),
        dn("type:paint", "a color, a gradient or `.glass`", "颜色、渐变或 `.glass`", plural: ("colors or gradients", "颜色或渐变")),
        dn("type:date", "a date and time", "日期和时间", plural: ("dates", "日期")),
        dn("type:json", "data read from the web", "从网上读来的数据", plural: ("data read from the web", "从网上读来的数据")),
        dn("type:secret", "a secret option", "密钥选项", plural: ("secret options", "密钥选项")),
        dn("type:size", "the widget's size", "组件的尺寸", plural: ("sizes", "尺寸")),
        dn("type:symbolName", "an SF Symbol name, such as `\"wifi\"`", "SF 符号名，比如 `\"wifi\"`",
           plural: ("SF Symbol names", "SF 符号名")),
        dn("type:imageSource", "a picture", "图片", plural: ("pictures", "图片")),
        dn("type:fontFamily", "a font name, such as `\"PingFang SC\"`", "字体名，比如 `\"PingFang SC\"`", plural: ("font names", "字体名")),
        dn("type:folderPath", "a folder", "文件夹", plural: ("folders", "文件夹")),
        dn("type:lengthSpec", "a length, `.fit` or `.fill`", "长度、`.fit` 或 `.fill`", plural: ("lengths", "长度")),
        dn("type:list", "a list of {element}", "一组{element}", plural: ("lists", "列表")),
        dn("type:binding", "a value it can change: a `variable`, a `saved` value, an option or adjustable data",
           "它能修改的值：variable、saved、选项或可调的数据", plural: ("values it can change", "它能修改的值")),
        dn("type:oneOf", "one of several kinds of value", "几种值之一", plural: ("values", "值")),
        dn("type:any", "a value", "一个值", plural: ("values", "值")),
        dn("type:styleRef", "one of your styles, written without a dot", "自己定义的样式（前面不加点）", plural: ("styles", "样式")),
        dn("type:elementName", "the name of an element, written without quotes", "元素的名字（不加引号）",
           plural: ("names of elements", "元素的名字")),
    ]

    static let enumNames: [DisplayNameSpec] = [
        dn("enum:Alignment", "a position in a box, such as `.topLeft`", "框里的位置，比如 `.topLeft`",
           plural: ("positions in a box", "框里的位置")),
        dn("enum:HAlign", "a text alignment: `.left`, `.center` or `.right`", "文字对齐：`.left`、`.center` 或 `.right`",
           plural: ("text alignments", "文字对齐方式")),
        dn("enum:VAlign", "a vertical alignment: `.top`, `.center`, `.bottom` or `.baseline`",
           "竖向对齐：`.top`、`.center`、`.bottom` 或 `.baseline`", plural: ("vertical alignments", "竖向对齐方式")),
        dn("enum:Axis", "a scroll direction: `.vertical` or `.horizontal`", "滚动方向：`.vertical` 或 `.horizontal`",
           plural: ("scroll directions", "滚动方向")),
        dn("enum:Direction", "a direction: `.right`, `.left`, `.up` or `.down`", "方向：`.right`、`.left`、`.up` 或 `.down`",
           plural: ("directions", "方向")),
        dn("enum:ScrollDirection", "a scrolling direction, such as `.up`", "滚动的方向，比如 `.up`",
           plural: ("scrolling directions", "滚动的方向")),
        dn("enum:LengthKeyword", "`.fit` or `.fill`", "`.fit` 或 `.fill`", plural: ("size keywords", "尺寸关键字")),
        dn("enum:SizePreset", "a widget size: `.small`, `.medium`, `.large` or `.fit`",
           "组件尺寸：`.small`、`.medium`、`.large` 或 `.fit`", plural: ("widget sizes", "组件尺寸")),
        dn("enum:Category", "a library category, such as `.time`", "小组件库的分类，比如 `.time`", plural: ("categories", "分类")),
        dn("enum:WindowLevel", "a window level: `.desktop`, `.normal` or `.onTop`", "窗口层级：`.desktop`、`.normal` 或 `.onTop`",
           plural: ("window levels", "窗口层级")),
        dn("enum:FontPreset", "a text style, such as `.caption`", "文字预设，比如 `.caption`", plural: ("text styles", "文字预设")),
        dn("enum:Weight", "a font weight, such as `.semibold`", "字重，比如 `.semibold`", plural: ("font weights", "字重")),
        dn("enum:FontDesign", "a font design, such as `.rounded`", "字体设计，比如 `.rounded`", plural: ("font designs", "字体设计")),
        dn("enum:Digits", "a digit style: `.equalWidth` or `.normal`", "数字样式：`.equalWidth` 或 `.normal`",
           plural: ("digit styles", "数字样式")),
        dn("enum:RadiusKeyword", "`.full` (half the shorter side)", "`.full`（较短边的一半）", plural: ("corner keywords", "圆角关键字")),
        dn("enum:ImageMode", "a picture fill: `.fit`, `.fill`, `.stretch` or `.tile`",
           "图片填充方式：`.fit`、`.fill`、`.stretch` 或 `.tile`", plural: ("picture fills", "图片填充方式")),
        dn("enum:Flip", "a mirroring: `.horizontal`, `.vertical` or `.both`", "翻转方式：`.horizontal`、`.vertical` 或 `.both`",
           plural: ("mirrorings", "翻转方式")),
        dn("enum:IconColors", "a symbol coloring, such as `.multicolor`", "符号上色方式，比如 `.multicolor`",
           plural: ("symbol colorings", "符号上色方式")),
        dn("enum:IconEffect", "a symbol animation, such as `.pulse`", "符号动效，比如 `.pulse`", plural: ("symbol animations", "符号动效")),
        dn("enum:GaugeShape", "a gauge shape: `.ring`, `.arc`, `.pie` or `.needle`", "仪表形状：`.ring`、`.arc`、`.pie` 或 `.needle`",
           plural: ("gauge shapes", "仪表形状")),
        dn("enum:GraphShape", "a graph shape: `.line`, `.area` or `.bars`", "曲线图样式：`.line`、`.area` 或 `.bars`",
           plural: ("graph shapes", "曲线图样式")),
        dn("enum:Animation", "an animation curve, such as `.spring`", "动画曲线，比如 `.spring`", plural: ("animation curves", "动画曲线")),
        dn("enum:Transition", "a transition, such as `.fade`", "过渡方式，比如 `.fade`", plural: ("transitions", "过渡方式")),
        dn("enum:Cursor", "a pointer shape, such as `.hand`", "指针形状，比如 `.hand`", plural: ("pointer shapes", "指针形状")),
        dn("enum:Permission", "a permission, such as `.music`", "权限，比如 `.music`", plural: ("permissions", "权限")),
        dn("enum:Weekday", "a day of the week, such as `.monday`", "星期几，比如 `.monday`", plural: ("days of the week", "星期几")),
        dn("enum:MemoryPressure", "a memory pressure: `.normal`, `.warning` or `.critical`",
           "内存压力：`.normal`、`.warning` 或 `.critical`", plural: ("memory pressures", "内存压力")),
        dn("enum:WeatherStatus", "a weather status, such as `.ready`", "天气数据状态，比如 `.ready`",
           plural: ("weather statuses", "天气数据状态")),
        dn("enum:SunState", "a sun state: `.normal`, `.midnightSun` or `.polarNight`", "太阳状态：`.normal`、`.midnightSun` 或 `.polarNight`",
           plural: ("sun states", "太阳状态")),
        dn("enum:FileSort", "a file order, such as `.date`", "文件排序方式，比如 `.date`", plural: ("file orders", "文件排序方式")),
        dn("enum:Feature", "a feature, such as `.liquidGlass`", "能力，比如 `.liquidGlass`", plural: ("features", "能力")),
        dn("enum:ByteUnit", "a data unit, such as `.gb`", "数据量单位，比如 `.gb`", plural: ("data units", "数据量单位")),
        dn("enum:TemperatureUnit", "a temperature unit, such as `.celsius`", "温度单位，比如 `.celsius`",
           plural: ("temperature units", "温度单位")),
        dn("enum:FrequencyUnit", "a frequency unit: `.auto`, `.mhz` or `.ghz`", "频率单位：`.auto`、`.mhz` 或 `.ghz`",
           plural: ("frequency units", "频率单位")),
        dn("enum:UnitStyle", "a unit style: `.none`, `.short` or `.full`", "单位样式：`.none`、`.short` 或 `.full`",
           plural: ("unit styles", "单位样式")),
        dn("enum:DurationStyle", "a duration style: `.full`, `.short` or `.clock`", "时长样式：`.full`、`.short` 或 `.clock`",
           plural: ("duration styles", "时长样式")),
        dn("enum:DatePreset", "a date format, such as `.weekday`", "日期格式，比如 `.weekday`", plural: ("date formats", "日期格式")),
        dn("enum:local", "one of the choices of `options.{name}`", "`options.{name}` 的可选项之一",
           plural: ("choices of `options.{name}`", "`options.{name}` 的可选项")),
    ]

    static let recordNames: [DisplayNameSpec] = [
        dn("record:Weather", "the weather at a place", "某地的天气", plural: ("weathers", "天气")),
        dn("record:Sun", "the sun at a place", "某地的太阳", plural: ("suns", "太阳数据")),
        dn("record:MonthGrid", "a month from `calendar.month`", "`calendar.month` 给出的一个月", plural: ("months", "月份")),
        dn("record:DayCell", "a day of a month", "月历里的日子", plural: ("days of a month", "月历里的日子")),
        dn("record:CalendarEvent", "a calendar event", "日程", plural: ("calendar events", "日程")),
        dn("record:CPUCore", "a processor core", "处理器核心", plural: ("processor cores", "处理器核心")),
        dn("record:Disk", "a disk", "磁盘", plural: ("disks", "磁盘")),
        dn("record:NetworkInterface", "a network interface", "网络接口", plural: ("network interfaces", "网络接口")),
        dn("record:App", "an app", "App", plural: ("apps", "App")),
        dn("record:WeatherNow", "the weather now", "现在的天气", plural: ("weather readings", "天气数据")),
        dn("record:HourForecast", "an hour's forecast", "逐小时预报", plural: ("hourly forecasts", "逐小时预报")),
        dn("record:DayForecast", "a day's forecast", "逐日预报", plural: ("daily forecasts", "逐日预报")),
        dn("record:Fan", "a fan", "风扇", plural: ("fans", "风扇")),
        dn("record:Feed", "a web feed", "订阅源", plural: ("web feeds", "订阅源")),
        dn("record:FeedItem", "an item of a web feed", "订阅条目", plural: ("items of a web feed", "订阅条目")),
        dn("record:FileItem", "a file", "文件", plural: ("files", "文件")),
        dn("record:FolderInfo", "a folder's size and counts", "文件夹信息", plural: ("folder summaries", "文件夹信息")),
        dn("record:CommandResult", "the result of a command", "命令结果", plural: ("command results", "命令结果")),
        dn("record:Size", "the widget's size", "组件的尺寸", plural: ("sizes", "尺寸")),
        dn("record:Event", "what happened in an event (`event`)", "事件信息（`event`）", plural: ("events", "事件信息")),
    ]

    /// One row per facet, from the facet table (its `displayName`), so the two never disagree.
    static let facetNames: [DisplayNameSpec] = facets.map {
        DisplayNameSpec(id: "facet:\($0.id.rawValue)", name: $0.displayName)
    }

    static let componentNames: [DisplayNameSpec] = [
        dn("component:Column", "the column", "竖排"), dn("component:Row", "the row", "横排"),
        dn("component:Grid", "the grid", "网格"), dn("component:Freeform", "the free layout", "自由摆放容器"),
        dn("component:Scroll", "the scroll area", "滚动区域"), dn("component:Spacer", "the spacer", "弹性空白"),
        dn("component:Divider", "the divider", "分隔线"), dn("component:Text", "the text", "文字"),
        dn("component:Label", "the label", "图标文字"), dn("component:Icon", "the symbol", "符号"),
        dn("component:Image", "the picture", "图片"), dn("component:Progress", "the progress bar", "进度条"),
        dn("component:Gauge", "the gauge", "圆环"), dn("component:Graph", "the graph", "曲线图"),
        dn("component:Rectangle", "the rectangle", "矩形"), dn("component:Circle", "the circle", "圆形"),
        dn("component:Ellipse", "the ellipse", "椭圆"), dn("component:Capsule", "the capsule", "胶囊形"),
        dn("component:Line", "the line", "直线"), dn("component:Arc", "the arc", "弧"),
        dn("component:Path", "the path", "路径"), dn("component:Button", "the button", "按钮"),
        dn("component:Toggle", "the switch", "开关"), dn("component:Slider", "the slider", "滑块"),
        dn("component:Input", "the text field", "输入框"), dn("component:Item", "the menu item", "菜单项"),
        dn("component:Menu", "the submenu", "子菜单"),
    ]

    static let presetNames: [DisplayNameSpec] = [
        dn("preset:small", "the small size", "小号"), dn("preset:medium", "the medium size", "中号"),
        dn("preset:large", "the large size", "大号"), dn("preset:fit", "a size that follows the content", "跟随内容的尺寸"),
    ]

    /// Grammar slots, for "Expected {expected} here" (DK2005). The parser reports them by id, without the catalog.
    static let slotNames: [DisplayNameSpec] = [
        dn("slot:expression", "a value", "一个值"),
        dn("slot:modifier", "a modifier, such as `.font(…)`", "修饰符，比如 `.font(…)`"),
        dn("slot:label", "a name followed by `:`", "名字加冒号"),
        dn("slot:closingBrace", "`}`", "`}`"), dn("slot:openingBrace", "`{`", "`{`"),
        dn("slot:closingParen", "`)`", "`)`"), dn("slot:openingParen", "`(`", "`(`"),
        dn("slot:closingBracket", "`]`", "`]`"), dn("slot:colon", "`:`", "`:`"), dn("slot:comma", "`,`", "`,`"),
        dn("slot:equals", "`=`", "`=`"), dn("slot:in", "`in`", "`in`"), dn("slot:quote", "`\"`", "`\"`"),
        dn("slot:name", "a name", "一个名字"),
        dn("slot:declarationName", "a name for the value, such as `page`", "值的名字，比如 `page`"),
        dn("slot:loopVariable", "a name for each item, such as `day`", "每一项的名字，比如 `day`"),
        dn("slot:styleName", "the style's name, such as `todayCell`", "样式的名字，比如 `todayCell`"),
        dn("slot:memberName", "a name after the dot", "点后面的名字"),
        dn("slot:string", "text in quotes", "带引号的文字"),
        dn("slot:number", "a number", "一个数字"),
        dn("slot:condition", "a condition, such as `cpu.usage > 80`", "条件，比如 `cpu.usage > 80`"),
        dn("slot:list", "a list in `[ ]`", "写在 `[ ]` 里的列表"),
        dn("slot:block", "a block in `{ }`", "写在 `{ }` 里的内容"),
        dn("slot:argument", "a value, or a name with `:` and a value", "一个值，或名字加冒号再加值"),
        dn("slot:statement", "an element, a declaration or an action", "元素、声明或动作"),
        dn("slot:element", "an element, such as `Text(\"…\")`", "元素，比如 `Text(\"…\")`"),
        dn("slot:action", "an action, such as `page = page + 1`", "动作，比如 `page = page + 1`"),
        dn("slot:field", "a field, such as `name: \"CPU\"`", "字段，比如 `name: \"CPU\"`"),
        dn("slot:control", "an option control, such as `Toggle(\"…\")`", "选项控件，比如 `Toggle(\"…\")`"),
        dn("slot:translation", "a translation, such as `\"CPU\": \"处理器\"`", "翻译，比如 `\"CPU\": \"处理器\"`"),
        dn("slot:languageTag", "a language, such as `\"zh-Hans\"`", "语言，比如 `\"zh-Hans\"`"),
        dn("slot:topLevelBlock", "`info`, `options`, `widget`, `style` or `translations`",
           "`info`、`options`、`widget`、`style` 或 `translations`"),
        dn("slot:operand", "a value after the operator", "运算符后面的值"),
    ]

    /// What a block holds, for "`{name}` needs `{ … }` holding {what}" (DK2011) and DK2037.
    static let contentNames: [DisplayNameSpec] = [
        dn("content:actions", "actions, such as `page = page + 1`", "动作，比如 `page = page + 1`"),
        dn("content:views", "elements, such as `Text(\"…\")`", "元素，比如 `Text(\"…\")`"),
        dn("content:modifiers", "modifiers, such as `.color(.accent)`", "修饰符，比如 `.color(.accent)`"),
        dn("content:menuItems", "menu items, such as `Item(\"…\")`", "菜单项，比如 `Item(\"…\")`"),
        dn("content:optionItems", "options, such as `showSeconds = Toggle(\"…\")`", "选项，比如 `showSeconds = Toggle(\"…\")`"),
    ]

    /// Kinds of code, for "{what} can't be written in {place}" (DK2014).
    static let constructNames: [DisplayNameSpec] = [
        dn("construct:infoBlock", "an `info { }` block", "`info { }` 块"),
        dn("construct:packageBlock", "a `package { }` block", "`package { }` 块"),
        dn("construct:optionsBlock", "an `options { }` block", "`options { }` 块"),
        dn("construct:widgetBlock", "a `widget { }` block", "`widget { }` 块"),
        dn("construct:translationsBlock", "a `translations { }` block", "`translations { }` 块"),
        dn("construct:style", "a style", "样式"),
        dn("construct:component", "a `component`", "`component`"),
        dn("construct:field", "a field such as `name:`", "`name:` 这样的字段"),
        dn("construct:declaration", "a declaration", "声明"),
        dn("construct:element", "an element", "元素"),
        dn("construct:action", "an action", "动作"),
        dn("construct:modifier", "a modifier", "修饰符"),
        dn("construct:option", "an option", "选项"),
        dn("construct:section", "a section of options", "选项分组"),
        dn("construct:translation", "a translation", "翻译"),
    ]

    /// Where code is written, for DK2014 `{place}` and DK5010 `{parent}`.
    static let placeNames: [DisplayNameSpec] = [
        dn("place:topLevel", "the top level of the file", "文件的最外层"),
        dn("place:widget", "`widget { }`", "`widget { }`"),
        dn("place:info", "`info { }`", "`info { }`"),
        dn("place:package", "`package { }`", "`package { }`"),
        dn("place:options", "`options { }`", "`options { }`"),
        dn("place:translations", "`translations { }`", "`translations { }`"),
        dn("place:style", "a style", "样式"),
        dn("place:actions", "an event block such as `.onClick { }`", "`.onClick { }` 这样的事件"),
        dn("place:state", "`.hover { }` or `.pressed { }`", "`.hover { }` 或 `.pressed { }`"),
        dn("place:menu", "a right-click menu", "右键菜单"),
        dn("place:packageFile", "`package.desk`", "`package.desk`"),
    ]

    /// What a control was given instead of a value it can change (DK4007 `{kind}`).
    static let kindNames: [DisplayNameSpec] = [
        dn("kind:comparison", "a comparison", "一个比较"),
        dn("kind:literal", "a fixed value", "一个写死的值"),
        dn("kind:computed", "a `computed` value, which is worked out", "computed 值（是算出来的）"),
        dn("kind:loopVariable", "an item of a `for` loop", "`for` 循环里的一项"),
        dn("kind:readOnlyData", "data that can't be changed", "不能修改的数据"),
        dn("kind:expression", "a calculation", "一个计算结果"),
        dn("kind:event", "the event's information (`event`)", "事件信息（`event`）"),
    ]
}
