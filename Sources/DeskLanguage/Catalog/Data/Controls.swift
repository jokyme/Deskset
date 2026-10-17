import Foundation

// Option controls: what a widget lets people adjust in its Options panel. Used only in `options { }` and
// `Section { }`; every control's first value is its label, and the option is named with `=`.

extension CatalogData {
    static func control(_ name: String, _ titleEn: String, _ titleZh: String, _ signatures: [Signature],
                        _ valueType: ControlValueType, _ panel: PanelControl, block: BlockKind = .none,
                        doc: Doc) -> ControlSpec {
        ControlSpec(name: name, title: L(titleEn, titleZh), signatures: signatures, valueType: valueType, panel: panel,
                    block: block, doc: doc)
    }

    /// Every control's first value: its label, shown in the panel and translated.
    static func controlLabel(_ en: String = "The label shown in the Options panel",
                             _ zh: String = "显示在选项面板里的说明") -> ParamSpec {
        pos("label", .string, role: .display, translatable: true, preview: #""Show seconds""#, en, zh)
    }

    static let variableValue = variable().approx("a value of [Variables] that the skin's menus change with !WriteKeyValue")

    static let controls: [ControlSpec] = [
        control("Picker", "Choice", "单选", [sig(
            controlLabel(),
            pos("choices", list(.any), preview: "[.sunday, .monday]", "The choices: built-in names, text, numbers or `Choice(value, \"Label\")`",
                "可选项：内置名字、文字、数字，或 `Choice(value, \"Label\")`"),
            arg("default", .any, system: .firstChoice, "The choice it starts with", "开始时选中的一项"))],
                .fromChoices, .segmentedOrMenu,
                doc: doc("Choose one of several", "从几项里选一项",
                         #"weekStart = Picker("Week starts on", [.sunday, .monday], default: .sunday)"#,
                         [variableValue, bang("!WriteKeyValue")],
                         keywords: ["Variables", "Dropdown", "Select", "Menu", "Segmented", "choice", "下拉菜单", "选择", "单选"],
                         rank: 80)),
        control("Toggle", "On or off", "开关", [sig(
            controlLabel(),
            arg("default", .bool, def: "false", "Whether it starts on", "开始时是否打开"))],
                .fixed(.bool), .toggle,
                doc: doc("On or off", "开关", #"showSeconds = Toggle("Show seconds")"#, [variableValue],
                         keywords: ["Variables", "Switch", "Checkbox", "Bool", "开关", "复选框"], rank: 80)),
        control("Slider", "Slider", "滑块", [sig(
            controlLabel(),
            arg("min", .anyNumber, required: true, preview: "0", "The lowest value", "最小值"),
            arg("max", .anyNumber, required: true, sameAs: "min", preview: "100", "The highest value", "最大值"),
            arg("step", .anyNumber, sameAs: "min", "The size of one step", "每一步的大小"),
            arg("default", .anyNumber, defParam: "min", sameAs: "min", "The value it starts with", "开始时的值"))],
                .dimensionOf(param: "min"), .slider,
                doc: doc("A number in a range", "在范围里选一个数",
                         #"speed = Slider("Speed", min: 1s, max: 10s, default: 2s)"#, [variableValue],
                         keywords: ["Variables", "Range", "slider", "滑块"], rank: 60)),
        control("Stepper", "Stepper", "步进器", [sig(
            controlLabel(),
            arg("min", .anyNumber, required: true, preview: "1", "The lowest value", "最小值"),
            arg("max", .anyNumber, required: true, sameAs: "min", preview: "10", "The highest value", "最大值"),
            arg("step", .anyNumber, def: "1", sameAs: "min", "The size of one step", "每一步的大小"),
            arg("default", .anyNumber, defParam: "min", sameAs: "min", "The value it starts with", "开始时的值"))],
                .dimensionOf(param: "min"), .stepper,
                doc: doc("A number changed step by step", "用加减按钮调的数字",
                         #"days = Stepper("Days", min: 1, max: 14, default: 7)"#, [variableValue],
                         keywords: ["Variables", "NumberField", "number", "counter", "步进器", "数字"], rank: 50)),
        control("Input", "Text", "文字", [sig(
            controlLabel(),
            arg("default", .string, def: #""""#, "The text it starts with", "开始时的文字"),
            arg("placeholder", .string, def: #""""#, role: .display, translatable: true, "Shown in the empty field",
                "输入框为空时显示的提示"))],
                .fixed(.string), .textField,
                doc: doc("A short text", "一行文字", #"city = Input("City", default: "Oslo")"#, [variableValue],
                         keywords: ["Variables", "TextField", "Text", "String", "输入框", "文字"], rank: 65)),
        control("Secret", "Secret", "密钥", [sig(controlLabel())],
                .fixed(.secret), .secureField,
                doc: doc("A password or API key", "密码或 API 密钥，存进钥匙串", #"apiKey = Secret("API key")"#,
                         keywords: ["Password", "SecureField", "API key", "token", "密码", "密钥"], mac: true, rank: 40)),
        control("ColorPicker", "Color", "颜色", [sig(
            controlLabel(),
            arg("default", .color, system: .accent, "The color it starts with", "开始时的颜色"))],
                .fixed(.color), .colorWell,
                doc: doc("A color", "颜色", #"highlight = ColorPicker("Highlight color", default: .accent)"#,
                         [variable().approx("a color variable of [Variables]")],
                         keywords: ["Variables", "Color", "ColorWell", "colour", "颜色", "取色器"], rank: 75)),
        control("FontPicker", "Font", "字体", [sig(
            controlLabel(),
            arg("default", .fontFamily, system: .systemFont, "The font it starts with", "开始时的字体"))],
                .fixed(.fontFamily), .fontMenu,
                doc: doc("A font", "字体", #"face = FontPicker("Font")"#,
                         [variable().approx("a FontFace variable of [Variables]")],
                         keywords: ["Variables", "FontFace", "font", "typeface", "字体"], rank: 50)),
        control("ImagePicker", "Picture", "图片", [sig(controlLabel())],
                .fixed(.imageSource), .imageChooser,
                doc: doc("A picture", "图片", #"photo = ImagePicker("Photo")"#,
                         [variable().approx("a picture path variable of [Variables]")],
                         keywords: ["Variables", "image", "photo", "picture", "图片", "照片"], rank: 40)),
        control("FolderPicker", "Folder", "文件夹", [sig(controlLabel())],
                .fixed(.folderPath), .folderChooser,
                doc: doc("A folder", "文件夹", #"folder = FolderPicker("Folder")"#,
                         [variable().approx("a folder path variable of [Variables]")],
                         keywords: ["Variables", "folder", "directory", "path", "文件夹", "目录"], mac: true, rank: 40)),
        control("DatePicker", "Date", "日期", [sig(
            controlLabel(),
            arg("default", .date, system: .today, "The date it starts with", "开始时的日期"))],
                .fixed(.date), .datePicker,
                doc: doc("A date", "日期", #"due = DatePicker("Count down to")"#,
                         keywords: ["date", "calendar", "day", "日期"], rank: 40)),
        control("Section", "Section", "分组", [sig(
            pos("title", .string, role: .display, translatable: true, preview: #""Colors""#, "The group's title",
                "分组的标题"))],
                .none, .section, block: .optionItems,
                doc: doc("Groups options under a title", "给选项分组", #"Section("Colors") { highlight = ColorPicker("Highlight") }"#,
                         keywords: ["group", "section", "header", "分组", "小节"], rank: 45,
                         context: ExampleContext(placement: .optionItem, parent: .options, replaces: ["highlight"]))),
        control("Choice", "Choice with a label", "带显示名的选项", [sig(
            pos("value", .any, preview: ".mono", "The value the option takes", "选项的值"),
            pos("label", .string, role: .display, translatable: true, preview: #""One color""#,
                "How the Options panel shows it", "在选项面板里显示的名字"))],
                .none, .choice,
                doc: doc("A choice with its own label", "带显示名的选项",
                         #"look = Picker("Look", [Choice(.mono, "One color"), Choice(.full, "Full color")])"#,
                         keywords: ["option", "choice", "item", "选项"], rank: 35)),
    ]
}
