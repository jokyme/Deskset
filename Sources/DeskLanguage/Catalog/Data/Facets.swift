import Foundation

// Facets: the individual properties an element has, as the editor's generated pages show them (section, label,
// control, presets, how prominent) and as messages name them. A facet's id is its modifier's name, then the
// parameter's internal name; facets of one modifier are shown together.

extension CatalogData {
    static func facet(_ id: FacetID, _ type: DeskType, _ nameEn: String, _ nameZh: String, _ section: InspectorCard,
                      _ labelEn: String, _ labelZh: String, _ control: PageControl, _ level: PageLevel = .more,
                      presets: [PagePreset] = [], long: String? = nil, inherit: Bool = false, unit: String? = nil,
                      range: ClosedRange<Double>? = nil, rm: [RainmeterMapping] = []) -> FacetSpec {
        FacetSpec(id: id, valueType: type, displayName: L(nameEn, nameZh), inheritable: inherit,
                  page: page(section, labelEn, labelZh, control, level, presets: presets, long: long),
                  unit: unit ?? displayUnit(of: type), range: range, rainmeter: rm)
    }

    static let facets: [FacetSpec] = sizeFacets + boxFacets + paintFacets + textFacets + pictureFacets + otherFacets

    static let lengthPresets = numbers(["0", "4", "8", "12", "16"])
    static let sizePresets = [preset(".fit", "Fit the content", "跟随内容"), preset(".fill", "Fill", "填满")]
        + numbers(["24", "100", "200"])
    static let pivotPresets = [preset(".center", "Center", "中心"), preset(".topLeft", "Top left", "左上角"),
                               preset(".bottom", "Bottom", "下边")]
    static let colorPresets = [preset(".text", "Text", "文字色"), preset(".dim", "Dim", "淡色"),
                               preset(".accent", "Accent", "强调色"), preset(".white", "White", "白色")]

    static let sizeFacets: [FacetSpec] = [
        facet("width", .lengthSpec, "the width", "宽度", .layout, "Width", "宽", .numberField, .essential,
              presets: sizePresets, rm: [anyMeter("W")]),
        facet("width.min", .length, "the least width", "最小宽度", .layout, "Least width", "最小宽度", .numberField),
        facet("width.max", .length, "the most width", "最大宽度", .layout, "Most width", "最大宽度", .numberField,
              rm: [meter("String", "ClipStringW")]),
        facet("height", .lengthSpec, "the height", "高度", .layout, "Height", "高", .numberField, .essential,
              presets: sizePresets, rm: [anyMeter("H")]),
        facet("height.min", .length, "the least height", "最小高度", .layout, "Least height", "最小高度", .numberField),
        facet("height.max", .length, "the most height", "最大高度", .layout, "Most height", "最大高度", .numberField,
              rm: [meter("String", "ClipStringH")]),
        facet("position.x", .length, "the position across", "横向位置", .layout, "X", "X", .numberField, .essential,
              rm: [anyMeter("X")]),
        facet("position.y", .length, "the position down", "纵向位置", .layout, "Y", "Y", .numberField, .essential,
              rm: [anyMeter("Y")]),
        facet("position.anchor", e("Alignment"), "the point placed at x and y", "对准位置的点", .layout, "Placed by its",
              "对准的点", .alignmentGrid, rm: [meter("String", "StringAlign")]),
        facet("offset.x", .length, "the shift across", "横向偏移", .layout, "Shift right", "向右偏移", .numberField),
        facet("offset.y", .length, "the shift down", "纵向偏移", .layout, "Shift down", "向下偏移", .numberField),
        facet("hidden", .bool, "whether it is hidden", "是否隐藏", .layout, "Hidden", "隐藏", .toggle, rm: [anyMeter("Hidden")]),
        facet("name", .elementName, "the element's name", "元素的名字", .layout, "Name", "名字", .textField,
              long: "temperatureTomorrow"),
        facet("clip", .bool, "whether it cuts off what sticks out", "是否裁掉超出的部分", .layout, "Clip to the box",
              "裁掉超出的部分", .toggle, rm: [anyMeter("Container")]),
        facet("rotate", .angle, "the rotation", "旋转角度", .layout, "Rotation", "旋转", .numberField,
              presets: numbers(["0", "45", "90", "180"]), rm: [meter("String", "Angle"), meter("Image", "ImageRotate")]),
        facet("rotate.pivot", e("Alignment"), "the point it turns around", "旋转中心", .layout, "Turns around", "旋转中心",
              .alignmentGrid, presets: pivotPresets),
        facet("scale", .oneOf([.percent, .plainNumber]), "the scale", "缩放比例", .layout, "Scale", "缩放", .numberField,
              presets: numbers(["90%", "100%", "110%"]), unit: "%"),
        facet("scale.pivot", e("Alignment"), "the point it grows from", "缩放中心", .layout, "Grows from", "缩放中心",
              .alignmentGrid, presets: pivotPresets),
    ]

    static func sideFacets(_ prefix: String, _ nameEn: String, _ nameZh: String, _ section: InspectorCard,
                           _ level: PageLevel, rm: [RainmeterMapping]) -> [FacetSpec] {
        [("top", "top", "上"), ("bottom", "bottom", "下"), ("left", "left", "左"), ("right", "right", "右")].map { side in
            facet(FacetID("\(prefix).\(side.0)"), .length, "the \(nameEn) at the \(side.1)", "\(side.2)边的\(nameZh)", section,
                  side.1.prefix(1).uppercased() + side.1.dropFirst(), side.2, .insets, level,
                  presets: lengthPresets, rm: rm)
        }
    }

    static let boxFacets: [FacetSpec] =
        sideFacets("padding", "space", "内边距", .layout, .essential, rm: [anyMeter("Padding")])
        + sideFacets("margin", "outside space", "外边距", .layout, .more, rm: [])
        + [
            facet("background", .paint, "the background", "背景", .appearance, "Background", "背景", .colorWell, .essential,
                  presets: [preset(".glass", "Glass", "玻璃"), preset(".clearGlass", "Clear glass", "透明玻璃"),
                            preset(".clear", "None", "无")],
                  rm: [anyMeter("SolidColor"), anyMeter("MacGlass"), skin("BackgroundMode")]),
            facet("background.tint", .color, "the glass tint", "玻璃着色", .appearance, "Glass tint", "玻璃着色", .colorWell,
                  rm: [anyMeter("MacGlassTint")]),
            facet("background.image", .imageSource, "the background picture", "背景图片", .appearance, "Background picture",
                  "背景图片", .imagePicker, rm: [skin("Background")]),
            facet("background.mode", e("ImageMode"), "how the background picture fills the box", "背景图片的填充方式",
                  .appearance, "Picture fill", "图片填充方式", .segmented, rm: [skin("BackgroundMode")]),
            facet("rounded.topLeft", .oneOf([.length, e("RadiusKeyword")]), "the top left corner radius", "左上角圆角",
                  .appearance, "Top left", "左上", .insets, .essential,
                  presets: numbers(["0", "8", "12", "26"]) + [preset(".full", "Round", "全圆")],
                  rm: [anyMeter("MacGlassCornerRadius")]),
            facet("rounded.topRight", .oneOf([.length, e("RadiusKeyword")]), "the top right corner radius", "右上角圆角",
                  .appearance, "Top right", "右上", .insets, .essential, rm: [anyMeter("MacGlassCornerRadius")]),
            facet("rounded.bottomLeft", .oneOf([.length, e("RadiusKeyword")]), "the bottom left corner radius", "左下角圆角",
                  .appearance, "Bottom left", "左下", .insets, .essential, rm: [anyMeter("MacGlassCornerRadius")]),
            facet("rounded.bottomRight", .oneOf([.length, e("RadiusKeyword")]), "the bottom right corner radius", "右下角圆角",
                  .appearance, "Bottom right", "右下", .insets, .essential, rm: [anyMeter("MacGlassCornerRadius")]),
            facet("border.color", .color, "the border color", "边框颜色", .appearance, "Border", "边框", .colorWell,
                  rm: [anyMeter("BevelType")]),
            facet("border.width", .length, "the border width", "边框粗细", .appearance, "Border width", "边框粗细", .numberField,
                  presets: numbers(["1", "2", "3"])),
            facet("shadow.color", .color, "the shadow color", "阴影颜色", .appearance, "Shadow", "阴影", .colorWell,
                  rm: [meter("String", "FontEffectColor")]),
            facet("shadow.radius", .length, "the shadow softness", "阴影柔和度", .appearance, "Shadow softness", "阴影柔和度",
                  .numberField, presets: numbers(["2", "4", "8"])),
            facet("shadow.x", .length, "the shadow's shift across", "阴影横向偏移", .appearance, "Shadow right", "阴影右移",
                  .numberField),
            facet("shadow.y", .length, "the shadow's shift down", "阴影纵向偏移", .appearance, "Shadow down", "阴影下移",
                  .numberField),
            facet("opacity", .fraction, "the opacity", "不透明度", .appearance, "Opacity", "不透明度", .slider,
                  presets: numbers(["30%", "60%", "100%"]), rm: [meter("Image", "ImageAlpha")]),
            facet("blur", .length, "the blur", "模糊程度", .appearance, "Blur", "模糊", .numberField,
                  presets: numbers(["2", "5", "10"]), range: 0...100),
        ]

    static let paintFacets: [FacetSpec] = [
        facet("fill", .paint, "the fill", "填充", .appearance, "Fill", "填充", .colorWell, .essential, presets: colorPresets,
              rm: [meter("Shape", "Shape")]),
        facet("stroke", .paint, "the outline color", "描边颜色", .appearance, "Outline", "描边", .colorWell, .essential,
              rm: [meter("Shape", "Shape")]),
        facet("stroke.width", .length, "the outline width", "描边粗细", .appearance, "Outline width", "描边粗细", .numberField,
              presets: numbers(["1", "2", "4"])),
        facet("stroke.dash", list(.length), "the dashes", "虚线", .appearance, "Dashes", "虚线", .textField),
        facet("color", .color, "the color", "颜色", .text, "Color", "颜色", .colorWell, .essential, presets: colorPresets,
              inherit: true,
              rm: [meter("String", "FontColor"), meter("Bar", "BarColor"), meter("Line", "LineColor"),
                   meter("Histogram", "PrimaryColor")]),
        facet("track", .color, "the color of the empty part", "轨道颜色", .appearance, "Track", "轨道", .colorWell, .essential,
              presets: [preset(".faint", "Faint", "很淡"), preset(".separator", "Separator", "分隔线色")],
              rm: [meter("Bar", "SolidColor")]),
    ]

    static let textFacets: [FacetSpec] = [
        facet("font.family", .fontFamily, "the font", "字体", .text, "Font", "字体", .fontMenu, .essential, inherit: true,
              rm: [meter("String", "FontFace")]),
        facet("font.size", .length, "the text size", "字号", .text, "Size", "字号", .numberField, .essential,
              presets: numbers(["11", "13", "15", "20", "26", "34"]), inherit: true, range: 1...1000,
              rm: [meter("String", "FontSize")]),
        facet("font.weight", e("Weight"), "the font weight", "字重", .text, "Weight", "字重", .popup, .essential,
              presets: [preset(".regular", "Regular", "常规"), preset(".medium", "Medium", "中等"),
                        preset(".semibold", "Semibold", "半粗"), preset(".bold", "Bold", "粗体")],
              inherit: true, rm: [meter("String", "FontWeight"), meter("String", "StringStyle")]),
        facet("font.italic", .bool, "whether the text is italic", "是否斜体", .text, "Italic", "斜体", .toggle, inherit: true,
              rm: [meter("String", "StringStyle", "Italic")]),
        facet("font.design", e("FontDesign"), "the font design", "字体设计", .text, "Design", "设计", .segmented,
              presets: [preset(".standard", "Standard", "标准"), preset(".rounded", "Rounded", "圆体"),
                        preset(".mono", "Monospaced", "等宽"), preset(".serif", "Serif", "衬线")], inherit: true),
        facet("digits", e("Digits"), "the digit style", "数字样式", .text, "Equal-width digits", "等宽数字", .segmented,
              presets: [preset(".equalWidth", "Equal width", "等宽"), preset(".normal", "Normal", "普通")], inherit: true,
              rm: [meter("String", "InlineSetting", "Typography")]),
        facet("align", e("HAlign"), "the text alignment", "文字对齐", .text, "Alignment", "对齐", .segmented, .essential,
              presets: alignPresets, inherit: true, rm: [meter("String", "StringAlign")]),
        facet("textCase", .string, "the capitals", "大小写", .text, "Capitals", "大小写", .segmented,
              presets: [preset("", "As typed", "原样"), preset(".uppercase()", "UPPERCASE", "全部大写"),
                        preset(".lowercase()", "lowercase", "全部小写"), preset(".titleCase()", "Title Case", "首字母大写")],
              rm: [meter("String", "StringCase")]),
        facet("lines", .plainNumber, "the number of lines", "行数", .text, "Lines", "行数", .numberField,
              presets: numbers(["1", "2", "3"]), range: 1...1000, rm: [meter("String", "ClipString")]),
        facet("outline.color", .color, "the outline around the letters", "文字描边颜色", .text, "Letter outline",
              "文字描边", .colorWell, rm: [meter("String", "StringEffect", "Border"), meter("String", "FontEffectColor")]),
        facet("outline.width", .length, "the width of the letters' outline", "文字描边粗细", .text, "Outline width", "描边粗细",
              .numberField),
        facet("underline", .bool, "whether the text is underlined", "是否有下划线", .text, "Underline", "下划线", .toggle,
              rm: [meter("String", "InlineSetting", "Underline")]),
        facet("underline.color", .color, "the underline color", "下划线颜色", .text, "Underline color", "下划线颜色", .colorWell),
        facet("strikethrough", .bool, "whether the text is struck through", "是否有删除线", .text, "Strikethrough", "删除线",
              .toggle, rm: [meter("String", "InlineSetting", "Strikethrough")]),
        facet("strikethrough.color", .color, "the strikethrough color", "删除线颜色", .text, "Strikethrough color", "删除线颜色",
              .colorWell),
        facet("letterSpacing", .length, "the letter spacing", "字距", .text, "Letter spacing", "字距", .numberField,
              presets: numbers(["0", "0.5", "1", "2"]), rm: [meter("String", "InlineSetting", "CharacterSpacing")]),
        facet("lineSpacing", .length, "the line spacing", "行距", .text, "Line spacing", "行距", .numberField,
              presets: numbers(["0", "2", "4", "8"])),
    ]

    static let pictureFacets: [FacetSpec] = [
        facet("imageMode", e("ImageMode"), "how the picture fills its box", "图片的填充方式", .appearance, "Fill the box by",
              "填充方式", .segmented, .essential,
              presets: [preset(".fit", "Fit", "完整放入"), preset(".fill", "Fill", "铺满"), preset(".stretch", "Stretch", "拉伸"),
                        preset(".tile", "Tile", "平铺")],
              rm: [meter("Image", "PreserveAspectRatio"), meter("Image", "Tile")]),
        facet("tint", .color, "the picture's tint", "图片着色", .appearance, "Tint", "着色", .colorWell,
              rm: [meter("Image", "ImageTint")]),
        facet("grayscale", .bool, "whether the picture is gray", "是否黑白", .appearance, "Grayscale", "黑白", .toggle,
              rm: [meter("Image", "Greyscale")]),
        facet("flip", e("Flip"), "the mirroring", "翻转", .appearance, "Flip", "翻转", .segmented,
              presets: [preset(".horizontal", "Horizontal", "水平"), preset(".vertical", "Vertical", "竖直"),
                        preset(".both", "Both", "两个方向")],
              rm: [meter("Image", "ImageFlip")]),
    ] + sideFacets("keepEdges", "fixed edge", "不拉伸的边", .appearance, .more, rm: [meter("Image", "ScaleMargins")]) + [
        facet("crop.x", .length, "the left edge of the part shown", "显示部分的左边", .appearance, "Crop left", "裁剪左边",
              .numberField, rm: [meter("Image", "ImageCrop")]),
        facet("crop.y", .length, "the top edge of the part shown", "显示部分的上边", .appearance, "Crop top", "裁剪上边",
              .numberField, rm: [meter("Image", "ImageCrop")]),
        facet("crop.width", .length, "the width of the part shown", "显示部分的宽度", .appearance, "Crop width", "裁剪宽度",
              .numberField, rm: [meter("Image", "ImageCrop")]),
        facet("crop.height", .length, "the height of the part shown", "显示部分的高度", .appearance, "Crop height", "裁剪高度",
              .numberField, rm: [meter("Image", "ImageCrop")]),
        facet("iconColors", e("IconColors"), "the symbol's colors", "符号的颜色", .appearance, "Symbol colors", "符号颜色",
              .segmented, .essential,
              presets: [preset(".monochrome", "One color", "一种颜色"), preset(".hierarchical", "Shades", "深浅"),
                        preset(".multicolor", "Its own colors", "自己的颜色")],
              rm: [meter("Image", "MacSymbolRendering")]),
        facet("iconEffect", e("IconEffect"), "the symbol's animation", "符号动效", .appearance, "Effect", "动效", .popup,
              presets: [preset(".pulse", "Pulse", "脉动"), preset(".bounce", "Bounce", "弹跳"),
                        preset(".breathe", "Breathe", "呼吸")]),
    ]

    static let otherFacets: [FacetSpec] = [
        facet("animate", e("Animation"), "the animation", "动画方式", .appearance, "Animation", "动画", .segmented,
              presets: [preset(".smooth", "Smooth", "平滑"), preset(".spring", "Spring", "弹性"), preset(".linear", "Linear", "匀速")],
              rm: [plugin("ActionTimer")]),
        facet("animate.duration", .duration, "the animation time", "动画时长", .appearance, "Animation time", "动画时长",
              .numberField, presets: numbers(["150ms", "250ms", "500ms"]), unit: "ms"),
        facet("appear", e("Transition"), "how it comes and goes", "出现和消失的方式", .appearance, "Appears by", "出现方式",
              .segmented, presets: [preset(".fade", "Fading", "淡入淡出"), preset(".scale", "Growing", "缩放"),
                                    preset(".slide", "Sliding", "滑入")],
              rm: [bang("!ShowFade"), bang("!HideFade")]),
        facet("tooltip", .string, "the tooltip", "提示", .interaction, "Tooltip", "提示", .textField,
              long: #""Back to today, Wednesday 30 September""#, rm: [anyMeter("ToolTipText")]),
        facet("tooltip.title", .string, "the tooltip title", "提示标题", .interaction, "Tooltip title", "提示标题", .textField,
              rm: [anyMeter("ToolTipTitle")]),
        facet("cursor", e("Cursor"), "the pointer shape", "指针样子", .interaction, "Pointer", "指针", .popup,
              presets: [preset(".arrow", "Arrow", "箭头"), preset(".hand", "Pointing hand", "手形")],
              rm: [anyMeter("MouseActionCursorName")]),
        facet("voiceOver", .string, "what VoiceOver says", "旁白朗读的内容", .interaction, "VoiceOver says", "旁白朗读",
              .textField, long: #""Next month: October 2026""#),
        facet("help", .string, "the help line", "说明", .content, "Help", "说明", .textField,
              long: #""The color of the arrows and of today's circle""#),
    ]
}
