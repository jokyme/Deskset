import Foundation

// Modifiers. Flags as in the listings: I inherited by Text, Label and Icon; S allowed in styles; H allowed inside
// `.hover` / `.pressed`; C accepts `if:`; R repeatable. "all" is every view component except `Spacer`.

extension CatalogData {
    /// The order the editor inserts modifiers in (their `sortKey`): style; text; pictures, icons, shapes and meters;
    /// size and position; appearance; transforms; states; interaction; timing; the rest.
    static let modifierOrder: [String] = [
        "style",
        "font", "bold", "italic", "color", "align", "uppercase", "lowercase", "titleCase", "lines", "digits", "outline",
        "underline", "strikethrough", "letterSpacing", "lineSpacing",
        "imageMode", "tint", "grayscale", "flip", "keepEdges", "crop", "iconColors", "iconEffect", "fill", "stroke", "track",
        "width", "height", "size", "padding", "position", "offset", "margin",
        "background", "rounded", "border", "shadow", "opacity", "blur", "clip",
        "rotate", "scale",
        "hover", "pressed", "animate", "appear", "hidden",
        "tooltip", "cursor", "onClick", "onDoubleClick", "onRightClick", "onMouseEnter", "onMouseLeave", "onScroll", "onDrag",
        "onDrop", "onSubmit", "menu",
        "every", "when", "onChange", "onLoad", "onWake",
        "name", "voiceOver", "rainmeter",
        "help",
    ]

    static func mod(_ name: String, _ group: ModifierGroup, _ titleEn: String, _ titleZh: String, _ signatures: [Signature],
                    _ appliesTo: ElementKindSet, _ flags: String, context: ModifierContext = .view,
                    layer: BoxLayer = .none, facets: [FacetID] = [], fixed: [FacetID: String] = [:], soft: Bool = false,
                    repeatable: Repeatable? = nil, block: BlockKind = .none, event: EventSpec? = nil,
                    timing: TimingSpec? = nil, card: InspectorCard, doc: Doc) -> ModifierSpec {
        let sortKey = (modifierOrder.firstIndex(of: name) ?? modifierOrder.count) + 1
        var paramFacets: [FacetID] = []
        for s in signatures { for p in s.params { for f in p.facets where !paramFacets.contains(f) { paramFacets.append(f) } } }
        var all = facets
        for f in paramFacets + fixed.keys.sorted() where !all.contains(f) { all.append(f) }
        return ModifierSpec(name: name, group: group, title: L(titleEn, titleZh), signatures: signatures,
                            appliesTo: appliesTo, context: context, boxLayer: layer, facets: all, fixedValues: fixed,
                            softFacets: soft, inheritable: flags.contains("I"), allowedInStyle: flags.contains("S"),
                            allowedInState: flags.contains("H"), acceptsCondition: flags.contains("C"),
                            repeatable: repeatable ?? (flags.contains("R") ? .yes : .no), block: block, event: event,
                            timing: timing, inspectorCard: card, sortKey: sortKey, doc: doc)
    }

    /// The sides of `.padding`, `.margin` and `.keepEdges`: all, horizontal, vertical, then one per side; a side beats
    /// an axis beats all.
    static func sides(_ prefix: String) -> Signature {
        func f(_ side: String) -> FacetID { FacetID("\(prefix).\(side)") }
        return sig(
            pos("all", .length, required: false, facets: [f("top"), f("bottom"), f("left"), f("right")], preview: "8",
                "All four sides", "四条边"),
            arg("horizontal", .length, facets: [f("left"), f("right")], specificity: 1, "Left and right", "左右两边"),
            arg("vertical", .length, facets: [f("top"), f("bottom")], specificity: 1, "Top and bottom", "上下两边"),
            arg("top", .length, facets: [f("top")], specificity: 2, "The top side", "上边"),
            arg("bottom", .length, facets: [f("bottom")], specificity: 2, "The bottom side", "下边"),
            arg("left", .length, facets: [f("left")], specificity: 2, "The left side", "左边"),
            arg("right", .length, facets: [f("right")], specificity: 2, "The right side", "右边"))
    }

    static let pictureKinds = ElementKindSet.of(.image)
    static let symbolKinds = ElementKindSet.of(.icon, .label)
    static let fontKinds = ElementKindSet([.text, .label, .icon, .button, .input]).union(.containers)
    static let textKinds = ElementKindSet.textLike
    static let colorKinds = ElementKindSet([.text, .label, .icon, .progress, .gauge, .graph, .divider]).union(.containers)
    static let alignKinds = ElementKindSet([.text, .label, .icon]).union(.containers)
    static let digitsKinds = ElementKindSet([.text, .label]).union(.containers)
    static let allViews = ElementKindSet.all
    static let pointerEvent = "Event"

    static let modifiers: [ModifierSpec] = sizeModifiers + appearanceModifiers + shapeModifiers + textModifiers
        + pictureModifiers + transformModifiers + stateModifiers + interactionModifiers + timingModifiers + reuseModifiers

    static let sizeModifiers: [ModifierSpec] = [
        mod("width", .sizeAndPosition, "Width", "宽度", [sig(
            pos("value", .lengthSpec, facets: ["width"], preview: "120", "A number, .fit or .fill", "数字、.fit 或 .fill"),
            arg("min", .length, facets: ["width.min"], "The least width", "最小宽度"),
            arg("max", .length, facets: ["width.max"], "The most width", "最大宽度"))],
            allViews, "SHC", card: .layout,
            doc: doc("Width: a number, .fit (follow the content) or .fill (take all the room)",
                     "宽度：数字、.fit（跟随内容）或 .fill（撑满）", ".width(120)",
                     [anyMeter("W"), meter("String", "ClipStringW")],
                     keywords: ["W", "ClipStringW", "frame", "width", "minWidth", "maxWidth", "宽", "宽度"], rank: 90)),
        mod("height", .sizeAndPosition, "Height", "高度", [sig(
            pos("value", .lengthSpec, facets: ["height"], preview: "40", "A number, .fit or .fill", "数字、.fit 或 .fill"),
            arg("min", .length, facets: ["height.min"], "The least height", "最小高度"),
            arg("max", .length, facets: ["height.max"], "The most height", "最大高度"))],
            allViews, "SHC", card: .layout,
            doc: doc("Height, like .width", "高度，同 .width", ".height(.fill)",
                     [anyMeter("H"), meter("String", "ClipStringH")],
                     keywords: ["H", "ClipStringH", "height", "minHeight", "maxHeight", "高", "高度"], rank: 88)),
        mod("size", .sizeAndPosition, "Size", "尺寸", [
            sig(pos("width", .lengthSpec, facets: ["width"], preview: "28", "The width", "宽度"),
                pos("height", .lengthSpec, facets: ["height"], preview: "24", "The height", "高度")),
            sig(pos("side", .length, facets: ["width", "height"], preview: "24", "Width and height: a square", "宽和高：正方形"))],
            allViews, "SHC", card: .layout,
            doc: doc("Width and height together; one number makes a square", "同时设宽高；一个数就是正方形", ".size(28, 24)",
                     [anyMeter("W"), anyMeter("H")],
                     keywords: ["W", "H", "frame", "size", "dimensions", "尺寸", "大小"], rank: 92)),
        mod("padding", .sizeAndPosition, "Padding", "内边距", [sides("padding")],
            allViews, "SHC", layer: .padding, card: .layout,
            doc: doc("Space inside the box, around the content; give at least one value", "内边距：盒子里、内容四周的空白；至少写一个值",
                     ".padding(14, top: 8)", [anyMeter("Padding")],
                     keywords: ["Padding", "padding", "inset", "inner space", "内边距", "留白"], rank: 90)),
        mod("margin", .sizeAndPosition, "Margin", "外边距", [sides("margin")],
            allViews, "SHC", layer: .margin, card: .layout,
            doc: doc("Space outside the box", "外边距：盒子外面的空白", ".margin(top: 4)",
                     keywords: ["margin", "outer space", "外边距"], rank: 60)),
        mod("position", .sizeAndPosition, "Position", "位置", [sig(
            arg("x", .length, def: "0", facets: ["position.x"], "Across, from the Freeform's left edge", "横向，从自由容器的左边算起"),
            arg("y", .length, def: "0", facets: ["position.y"], "Down, from the Freeform's top edge", "纵向，从自由容器的上边算起"),
            arg("anchor", e("Alignment"), def: ".topLeft", facets: ["position.anchor"],
                "The point of the element placed at x, y", "元素的哪个点放在 x、y"))],
            allViews, "C", card: .layout,
            doc: doc("Puts the element at x, y in its Freeform; x and y may use siblings' edges", "在自由容器里放到 x、y；可以引用兄弟元素的边",
                     ".position(x: title.right + 4, y: title.top)",
                     [anyMeter("X").noted("including r and R"), anyMeter("Y").noted("including r and R"),
                      meter("String", "StringAlign").noted("as the anchor")],
                     keywords: ["X", "Y", "StringAlign", "absolute", "left", "top", "coordinates", "位置", "坐标"], rank: 70,
                     context: ExampleContext(placement: .modifiers, parent: .freeform,
                                             siblings: [#"Text("A").name(title).position(x: 10, y: 10)"#],
                                             replaces: ["title"]))),
        mod("offset", .sizeAndPosition, "Offset", "偏移", [sig(
            arg("x", .length, def: "0", facets: ["offset.x"], "How far right it moves", "向右挪多少"),
            arg("y", .length, def: "0", facets: ["offset.y"], "How far down it moves", "向下挪多少"))],
            allViews, "SHC", layer: .transform, card: .layout,
            doc: doc("Moves how it looks without changing the layout", "只挪动显示位置，不影响排版", ".offset(y: -2)",
                     keywords: ["offset", "translate", "nudge", "shift", "偏移", "挪动"], rank: 45)),
        mod("hidden", .sizeAndPosition, "Hidden", "隐藏", [sig(
            arg("if", .bool, name: "condition", def: "true", facets: ["hidden"], role: .condition,
                "Hidden while this is true", "条件成立时隐藏"))],
            ElementKindSet.all.union(.of(.spacer)), "SCR", context: .both, card: .layout,
            doc: doc("Hides it but keeps its space; show, hide and showOrHide override it", "隐藏但保留位置；show/hide/showOrHide 可以改；也能用在选项上",
                     ".hidden(if: page > 0)", [anyMeter("Hidden"), bang("!ShowMeter"), bang("!HideMeter")],
                     keywords: ["Hidden", "hide", "visible", "visibility", "display none", "隐藏", "显示"], rank: 75)),
        mod("name", .sizeAndPosition, "Name", "名字", [sig(
            pos("name", .elementName, facets: ["name"], role: .declaresElementName, preview: "title",
                "An own name, written without quotes", "自己起的名字，不加引号"))],
            allViews, "", card: .layout,
            doc: doc("Names the element for show, hide and showOrHide and for positions", "给元素起名（不加引号），供 show/hide/showOrHide 和定位引用",
                     ".name(title)", [anyMeter().noted("the meter's section name, with a small first letter")],
                     keywords: ["id", "name", "identifier", "ref", "名字", "名称"], rank: 55)),
        mod("clip", .sizeAndPosition, "Clip", "裁切", [sig()], ElementKindSet.containers.union(.of(.image)), "SC",
            layer: .clip, fixed: ["clip": "true"], card: .layout,
            doc: doc("Cuts off what sticks out of the box and its rounded corners", "裁掉超出盒子和圆角的部分（图片加 .rounded 已经自动裁切）",
                     #"Freeform { Image("photo.png") }.rounded(12).clip()"#, [anyMeter("Container").approx()],
                     keywords: ["Container", "clip", "clipped", "overflow hidden", "mask", "裁切", "遮罩"], rank: 40)),
    ]

    static let appearanceModifiers: [ModifierSpec] = [
        mod("background", .appearance, "Background", "背景", [
            sig(pos("paint", .paint, facets: ["background"], preview: ".glass", "A color, a gradient, .glass or .clearGlass",
                    "颜色、渐变、.glass 或 .clearGlass"),
                arg("tint", .color, facets: ["background.tint"], "A color the glass leans toward", "玻璃偏向的颜色")),
            sig(arg("image", .imageSource, required: true, facets: ["background.image"], preview: #""paper.png""#,
                    "A picture that fills the box", "铺满盒子的图片"),
                arg("mode", e("ImageMode"), def: ".fill", facets: ["background.mode"], "How the picture fills the box",
                    "图片怎么铺满盒子"))],
            allViews, "SHC", layer: .background, card: .appearance,
            doc: doc("Fills the box: a color, a gradient, .glass / .clearGlass, or a picture", "背景：颜色、渐变、玻璃或图片",
                     ".background(.glass)",
                     [anyMeter("SolidColor"), anyMeter("SolidColor2"), anyMeter("GradientAngle"), anyMeter("MacGlass"),
                      anyMeter("MacGlassTint"), skin("BackgroundMode"), skin("Background"), plugin("FrostedGlass")],
                     keywords: ["SolidColor", "MacGlass", "BackgroundMode", "FrostedGlass", "background", "bg", "backgroundColor",
                                "glass", "material", "背景", "背景色", "玻璃"], mac: true, rank: 95)),
        mod("rounded", .appearance, "Corner radius", "圆角", [sig(
            pos("radius", .oneOf([.length, e("RadiusKeyword")]), required: false,
                facets: ["rounded.topLeft", "rounded.topRight", "rounded.bottomLeft", "rounded.bottomRight"], preview: "12",
                "Every corner: a number, or .full for a pill or circle", "所有角：数字，或 .full（胶囊或圆形）"),
            arg("topLeft", .length, facets: ["rounded.topLeft"], specificity: 2, "The top left corner", "左上角"),
            arg("topRight", .length, facets: ["rounded.topRight"], specificity: 2, "The top right corner", "右上角"),
            arg("bottomLeft", .length, facets: ["rounded.bottomLeft"], specificity: 2, "The bottom left corner", "左下角"),
            arg("bottomRight", .length, facets: ["rounded.bottomRight"], specificity: 2, "The bottom right corner", "右下角"))],
            allViews, "SHC", layer: .background, card: .appearance,
            doc: doc("Rounds the corners; .full makes a pill or circle; a picture is rounded too", "圆角；.full 是胶囊或圆形；图片本身也会变圆角",
                     ".rounded(26)", [meter("Shape", "Shape").noted("Rectangle radii"), anyMeter("MacGlassCornerRadius")],
                     keywords: ["MacGlassCornerRadius", "cornerRadius", "borderRadius", "corner", "radius", "round", "rounded", "圆角"],
                     rank: 85)),
        mod("border", .appearance, "Border", "边框", [sig(
            pos("color", .color, facets: ["border.color"], preview: ".separator", "The line's color", "边框的颜色"),
            arg("width", .length, def: "1", facets: ["border.width"], "The line's width", "边框的粗细"))],
            allViews, "SHC", layer: .border, card: .appearance,
            doc: doc("A line along the inside of the box", "边框（沿盒子内侧）", ".border(.separator)",
                     [meter("Shape", "Shape").noted("Stroke on a Rectangle"), anyMeter("BevelType").approx()],
                     keywords: ["BevelType", "border", "outline", "stroke", "边框", "描边"], rank: 60)),
        mod("shadow", .appearance, "Shadow", "阴影", [sig(
            arg("color", .color, def: "Color.black.opacity(25%)", facets: ["shadow.color"], "The shadow's color", "阴影的颜色"),
            arg("radius", .length, def: "4", facets: ["shadow.radius"], "How soft it is", "阴影的柔和程度"),
            arg("x", .length, def: "0", facets: ["shadow.x"], "How far right it falls", "向右偏多少"),
            arg("y", .length, def: "2", facets: ["shadow.y"], "How far down it falls", "向下偏多少"))],
            allViews, "SHC", layer: .shadow, card: .appearance,
            doc: doc("A soft shadow; text without a background casts its own shadow", "阴影；没有背景的文字就是文字阴影",
                     ".shadow(radius: 8)", [meter("String", "StringEffect", "Shadow"), meter("String", "FontEffectColor")],
                     keywords: ["StringEffect", "Shadow", "shadow", "dropShadow", "boxShadow", "textShadow", "阴影"], rank: 60)),
        mod("opacity", .appearance, "Opacity", "不透明度", [sig(
            pos("value", .fraction, facets: ["opacity"], preview: "60%", "From 0% (invisible) to 100%", "从 0%（看不见）到 100%"))],
            allViews, "SHC", card: .appearance,
            doc: doc("How see-through the whole element is", "整个元素的透明度", ".opacity(60%)",
                     [meter("Image", "ImageAlpha").noted("and the alpha of colors")],
                     keywords: ["ImageAlpha", "alpha", "opacity", "transparency", "transparent", "透明", "不透明度"], rank: 70)),
        mod("blur", .appearance, "Blur", "模糊", [sig(
            pos("radius", .length, range: 0...100, facets: ["blur"], preview: "2", "How strong the blur is", "模糊的程度"))],
            allViews, "SHC", card: .appearance,
            doc: doc("Blurs the element", "模糊", ".blur(2)", keywords: ["blur", "gaussian", "frosted", "模糊"], rank: 35)),
    ]

    static let shapeModifiers: [ModifierSpec] = [
        mod("fill", .shapesAndMeters, "Fill", "填充", [sig(
            pos("paint", .paint, facets: ["fill"], preview: ".accent", "A color or a gradient", "颜色或渐变"))],
            ElementKindSet.shapes.union(.of(.graph)), "SHC", card: .appearance,
            doc: doc("Paints the inside of a shape (a graph's area)", "填充形状内部（曲线下的面积）", "Circle().size(8).fill(.green)",
                     [meter("Shape", "Shape").noted("Fill Color, Fill LinearGradient, Fill RadialGradient")],
                     keywords: ["Shape", "fill", "fillColor", "填充"], rank: 70)),
        mod("stroke", .shapesAndMeters, "Stroke", "描边", [sig(
            pos("paint", .paint, facets: ["stroke"], preview: ".accent", "A color or a gradient", "颜色或渐变"),
            arg("width", .length, def: "1", facets: ["stroke.width"], "The line's width", "线的粗细"),
            arg("dash", list(.length), facets: ["stroke.dash"], "Dash and gap lengths, repeated", "虚线的线段和间隔长度，循环使用"))],
            .shapes, "SHC", card: .appearance,
            doc: doc("Draws the outline", "描边", ".stroke(.accent, width: 4)",
                     [meter("Shape", "Shape").noted("Stroke, StrokeWidth, StrokeDashes")],
                     keywords: ["Shape", "stroke", "outline", "border", "lineWidth", "描边", "轮廓"], rank: 60,
                     context: ExampleContext(placement: .modifiers, attachTo: .circle))),
        mod("color", .shapesAndMeters, "Color", "颜色", [
            sig(pos("color", .color, facets: ["color"], preview: ".accent", "The color", "颜色")),
            sig(arg("light", .color, required: true, facets: ["color"], "In light mode", "浅色模式下"),
                arg("dark", .color, required: true, facets: ["color"], "In dark mode", "深色模式下"))],
            colorKinds, "ISHC", card: .text,
            doc: doc("The main color: text, icon, bar or line", "主色：文字、图标、进度条或曲线", ".color(.dim)",
                     [meter("String", "FontColor"), meter("Bar", "BarColor"), meter("Line", "LineColor"),
                      meter("Histogram", "PrimaryColor"), meter("Image", "ImageTint").noted("of sf: pictures")],
                     keywords: ["FontColor", "BarColor", "LineColor", "PrimaryColor", "foregroundColor", "foregroundStyle",
                                "textColor", "fontColor", "colour", "fg", "颜色", "字色"], rank: 98)),
        mod("track", .shapesAndMeters, "Track", "轨道颜色", [sig(
            pos("color", .color, facets: ["track"], preview: ".faint", "The color of the empty part", "空的那部分的颜色"))],
            .of(.progress, .gauge), "SHC", card: .appearance,
            doc: doc("Color of the empty part", "空的那部分（轨道）的颜色", "Progress(cpu.usage).track(.faint)",
                     [meter("Bar", "SolidColor")],
                     keywords: ["SolidColor", "track", "trackColor", "empty part", "background", "轨道"], rank: 50)),
    ]

    static let textModifiers: [ModifierSpec] = [
        mod("font", .text, "Font", "字体", [
            sig(pos("preset", e("FontPreset"), facets: ["font.family", "font.size", "font.weight", "font.design", "digits"],
                    preview: ".headline", "A text style such as .headline", "文字预设，比如 .headline")),
            sig(pos("size", .length, facets: ["font.size"], preview: "13", "The size in points", "字号（点）",
                    rm: [meter("String", "FontSize").noted("Rainmeter sizes are 4/3 as large")]),
                pos("weight", e("Weight"), required: false, facets: ["font.weight"], "How heavy the letters are", "字重",
                    rm: [meter("String", "FontWeight")]),
                pos("design", e("FontDesign"), required: false, facets: ["font.design"], "The system font's design", "系统字体的设计")),
            sig(pos("family", .fontFamily, facets: ["font.family"], preview: #""PingFang SC""#, "A font's name", "字体的名字",
                    rm: [meter("String", "FontFace")]),
                pos("size", .length, required: false, facets: ["font.size"], "The size in points", "字号（点）"),
                pos("weight", e("Weight"), required: false, facets: ["font.weight"], "How heavy the letters are", "字重"))],
            fontKinds, "ISHC", soft: true, card: .text,
            doc: doc("Font: a preset; a size with a weight and/or a design, in any order; or a named font",
                     "字体：预设；字号加字重和/或设计（顺序不限）；或指定字体", ".font(13, .semibold)",
                     [meter("String", "FontFace"), meter("String", "FontSize").noted("Rainmeter sizes are 4/3 as large"),
                      meter("String", "FontWeight"), meter("String", "StringStyle")],
                     keywords: ["FontFace", "FontSize", "FontWeight", "fontSize", "fontFamily", "typeface", "text style", "字体", "字号"],
                     rank: 97)),
        mod("bold", .text, "Bold", "粗体", [sig()], fontKinds, "ISHC", fixed: ["font.weight": ".bold"], card: .text,
            doc: doc("Bold", "粗体", ".bold()", [meter("String", "StringStyle", "Bold"), meter("String", "FontWeight", "700")],
                     keywords: ["Bold", "StringStyle", "bold", "fontWeight", "strong", "粗体", "加粗"], rank: 80)),
        mod("italic", .text, "Italic", "斜体", [sig()], fontKinds, "ISHC", fixed: ["font.italic": "true"], card: .text,
            doc: doc("Italic", "斜体", ".italic()", [meter("String", "StringStyle", "Italic")],
                     keywords: ["Italic", "StringStyle", "italic", "oblique", "em", "斜体"], rank: 55)),
        mod("align", .text, "Alignment", "对齐", [sig(
            pos("alignment", e("HAlign"), facets: ["align"], preview: ".right", ".left, .center or .right", ".left、.center 或 .right"))],
            alignKinds, "ISHC", card: .text,
            doc: doc("Where the text sits in its box and how its lines line up", "文字在框里的位置和各行的对齐", ".align(.right)",
                     [meter("String", "StringAlign").partial("the horizontal part")],
                     keywords: ["StringAlign", "textAlign", "alignment", "justify", "multilineTextAlignment", "对齐"], rank: 80)),
        mod("uppercase", .text, "All capitals", "全部大写", [sig()], textKinds, "SHC", fixed: ["textCase": "upper"], card: .text,
            doc: doc("CAPITAL LETTERS", "全部大写", ".uppercase()", [meter("String", "StringCase", "Upper")],
                     keywords: ["Upper", "StringCase", "uppercase", "capitals", "caps", "allCaps", "textTransform", "大写"], rank: 55)),
        mod("lowercase", .text, "All small letters", "全部小写", [sig()], textKinds, "SHC", fixed: ["textCase": "lower"], card: .text,
            doc: doc("small letters", "全部小写", ".lowercase()", [meter("String", "StringCase", "Lower")],
                     keywords: ["Lower", "StringCase", "lowercase", "小写"], rank: 35)),
        mod("titleCase", .text, "Title case", "首字母大写", [sig()], textKinds, "SHC", fixed: ["textCase": "title"], card: .text,
            doc: doc("Capitalizes Each Word", "每个词首字母大写", ".titleCase()", [meter("String", "StringCase", "Proper")],
                     keywords: ["Proper", "StringCase", "capitalize", "titleCase", "首字母大写"], rank: 30)),
        mod("lines", .text, "Lines", "行数", [sig(
            pos("max", .plainNumber, range: 1...1000, whole: true, facets: ["lines"], preview: "1", "At most this many lines",
                "最多几行"))],
            textKinds, "SHC", card: .text,
            doc: doc("At most this many lines; the last ends with “…”", "最多几行，最后一行用“…”结尾", ".lines(1)",
                     [meter("String", "ClipString", "1"), meter("String", "ClipStringH").noted("with ClipString=2")],
                     keywords: ["ClipString", "lineLimit", "maxLines", "truncate", "ellipsis", "行数", "截断"], rank: 55)),
        mod("digits", .text, "Digits", "数字样式", [sig(
            pos("style", e("Digits"), facets: ["digits"], preview: ".equalWidth", ".equalWidth or .normal", ".equalWidth 或 .normal"))],
            digitsKinds, "ISHC", card: .text,
            doc: doc("Equal-width digits keep numbers from jumping", "等宽数字，数字变化时不跳动", ".digits(.equalWidth)",
                     [meter("String", "InlineSetting", "Typography").approx()],
                     keywords: ["Typography", "InlineSetting", "monospacedDigit", "tabular", "tabular-nums", "equal width digits", "等宽数字"],
                     rank: 45)),
        mod("outline", .text, "Outline", "文字描边", [sig(
            pos("color", .color, facets: ["outline.color"], preview: ".black", "The outline's color", "描边的颜色"),
            arg("width", .length, def: "1", facets: ["outline.width"], "The outline's width", "描边的粗细"))],
            textKinds, "SHC", card: .text,
            doc: doc("A line around each letter", "文字描边", ".outline(.black)",
                     [meter("String", "StringEffect", "Border"), meter("String", "FontEffectColor")],
                     keywords: ["StringEffect", "Border", "textStroke", "stroke", "outline", "描边", "文字描边"], rank: 35)),
        mod("underline", .text, "Underline", "下划线", [sig(
            pos("color", .color, required: false, facets: ["underline.color"], "The line's color; the text's when left out",
                "线的颜色；不写就和文字同色"))],
            textKinds, "SHC", fixed: ["underline": "true"], card: .text,
            doc: doc("Underlines the text", "下划线", ".underline()", [meter("String", "InlineSetting", "Underline")],
                     keywords: ["Underline", "InlineSetting", "underline", "textDecoration", "下划线"], rank: 35)),
        mod("strikethrough", .text, "Strikethrough", "删除线", [sig(
            pos("color", .color, required: false, facets: ["strikethrough.color"], "The line's color; the text's when left out",
                "线的颜色；不写就和文字同色"))],
            textKinds, "SHC", fixed: ["strikethrough": "true"], card: .text,
            doc: doc("Strikes through the text", "删除线", ".strikethrough()", [meter("String", "InlineSetting", "Strikethrough")],
                     keywords: ["Strikethrough", "InlineSetting", "strike", "lineThrough", "删除线"], rank: 25)),
        mod("letterSpacing", .text, "Letter spacing", "字距", [sig(
            pos("amount", .length, facets: ["letterSpacing"], preview: "1", "Extra space between letters", "字母之间多出的空间"))],
            textKinds, "SHC", card: .text,
            doc: doc("Extra space between letters", "字距", ".letterSpacing(1)", [meter("String", "InlineSetting", "CharacterSpacing")],
                     keywords: ["CharacterSpacing", "InlineSetting", "tracking", "kerning", "letterSpacing", "字距"], rank: 30)),
        mod("lineSpacing", .text, "Line spacing", "行距", [sig(
            pos("amount", .length, facets: ["lineSpacing"], preview: "4", "Extra space between lines", "行与行之间多出的空间"))],
            .of(.text), "SHC", card: .text,
            doc: doc("Extra space between lines", "行距", ".lineSpacing(4)",
                     keywords: ["lineHeight", "leading", "lineSpacing", "行距", "行高"], rank: 30)),
    ]

    static let pictureModifiers: [ModifierSpec] = [
        mod("imageMode", .picturesAndIcons, "Picture fill", "图片填充方式", [sig(
            pos("mode", e("ImageMode"), required: false, def: ".fit", facets: ["imageMode"], preview: ".fill",
                ".fit, .fill, .stretch or .tile", ".fit、.fill、.stretch 或 .tile"))],
            pictureKinds, "SHC", card: .appearance,
            doc: doc("How a picture fills its box: fit (all of it inside), fill (cover, cropping), stretch, tile",
                     "图片怎么放进框里：完整放入、铺满裁切、拉伸、平铺（与 Figma 的叫法一致）", ".imageMode(.fill)",
                     [meter("Image", "PreserveAspectRatio"), meter("Image", "Tile")],
                     keywords: ["PreserveAspectRatio", "Tile", "fit", "fill", "contentMode", "objectFit", "aspectRatio",
                                "scaledToFit", "scaledToFill", "填充方式"], rank: 55,
                     context: ExampleContext(placement: .modifiers, attachTo: .image))),
        mod("tint", .picturesAndIcons, "Tint", "着色", [sig(
            pos("color", .color, facets: ["tint"], preview: ".accent", "The color to multiply with", "相乘的颜色"))],
            pictureKinds, "SHC", card: .appearance,
            doc: doc("Multiplies the picture's colors (icons use .color)", "给图片着色（相乘）；图标用 .color", ".tint(.accent)",
                     [meter("Image", "ImageTint")], keywords: ["ImageTint", "tint", "colorize", "colorMultiply", "着色"], rank: 35,
                     context: ExampleContext(placement: .modifiers, attachTo: .image))),
        mod("grayscale", .picturesAndIcons, "Grayscale", "黑白", [sig()], pictureKinds, "SHC", fixed: ["grayscale": "true"],
            card: .appearance,
            doc: doc("Shows the picture in gray", "黑白显示", ".grayscale()", [meter("Image", "Greyscale")],
                     keywords: ["Greyscale", "grayscale", "greyscale", "monochrome", "desaturate", "黑白", "灰度"], rank: 30,
                     context: ExampleContext(placement: .modifiers, attachTo: .image))),
        mod("flip", .picturesAndIcons, "Flip", "翻转", [sig(
            pos("direction", e("Flip"), facets: ["flip"], preview: ".horizontal", ".horizontal, .vertical or .both",
                ".horizontal、.vertical 或 .both"))],
            .of(.image, .icon), "SHC", card: .appearance,
            doc: doc("Mirrors it", "翻转", ".flip(.horizontal)", [meter("Image", "ImageFlip")],
                     keywords: ["ImageFlip", "flip", "mirror", "reflect", "翻转", "镜像"], rank: 30,
                     context: ExampleContext(placement: .modifiers, attachTo: .image))),
        mod("keepEdges", .picturesAndIcons, "Fixed edges", "九宫格", [sides("keepEdges")],
            pictureKinds, "SHC", card: .appearance,
            doc: doc("Stretches only the middle; edges this wide keep their shape", "九宫格：这么宽的边不拉伸，只拉伸中间",
                     ".keepEdges(12)", [meter("Image", "ScaleMargins")],
                     keywords: ["ScaleMargins", "nine slice", "9-slice", "capInsets", "borderImage", "九宫格"], rank: 20,
                     context: ExampleContext(placement: .modifiers, attachTo: .image))),
        mod("crop", .picturesAndIcons, "Crop", "裁剪", [sig(
            arg("x", .length, def: "0", facets: ["crop.x"], "The left edge of the part shown", "显示部分的左边"),
            arg("y", .length, def: "0", facets: ["crop.y"], "The top edge of the part shown", "显示部分的上边"),
            arg("width", .length, required: true, facets: ["crop.width"], preview: "32", "The width of the part shown", "显示部分的宽度"),
            arg("height", .length, required: true, facets: ["crop.height"], preview: "32", "The height of the part shown",
                "显示部分的高度"))],
            pictureKinds, "SHC", card: .appearance,
            doc: doc("Shows only part of the picture", "只显示图片的一部分", ".crop(width: 32, height: 32)",
                     [meter("Image", "ImageCrop")], keywords: ["ImageCrop", "crop", "clip rect", "sprite", "裁剪"], rank: 25,
                     context: ExampleContext(placement: .modifiers, attachTo: .image))),
        mod("iconColors", .picturesAndIcons, "Symbol colors", "符号颜色", [sig(
            pos("mode", e("IconColors"), facets: ["iconColors"], preview: ".multicolor", ".monochrome, .hierarchical or .multicolor",
                ".monochrome、.hierarchical 或 .multicolor"))],
            symbolKinds, "SHC", card: .appearance,
            doc: doc("One color, shades of it, or the symbol's own colors", "单色、同色深浅，或符号自己的颜色", ".iconColors(.multicolor)",
                     [meter("Image", "MacSymbolRendering").noted("Deskset extension")],
                     keywords: ["MacSymbolRendering", "symbolRenderingMode", "multicolor", "hierarchical", "palette", "符号颜色"],
                     mac: true, rank: 30, context: ExampleContext(placement: .modifiers, attachTo: .icon))),
        mod("iconEffect", .picturesAndIcons, "Symbol effect", "符号动效", [sig(
            pos("effect", e("IconEffect"), facets: ["iconEffect"], preview: ".pulse", "The animation", "动效"))],
            symbolKinds, "SC", card: .appearance,
            doc: doc("A repeating SF Symbols animation (macOS 14 and later; nothing on older systems)", "系统图标动效（循环；macOS 14 起）",
                     ".iconEffect(.pulse)", keywords: ["symbolEffect", "animation", "bounce", "pulse", "动效"], mac: true, macOS: 14,
                     rank: 25, context: ExampleContext(placement: .modifiers, attachTo: .icon))),
    ]

    static let transformModifiers: [ModifierSpec] = [
        mod("rotate", .transforms, "Rotation", "旋转", [sig(
            pos("angle", .angle, facets: ["rotate"], preview: "45", "Clockwise, in degrees", "顺时针的角度"),
            arg("pivot", e("Alignment"), def: ".center", facets: ["rotate.pivot"], "The point it turns around", "绕着哪个点转"))],
            allViews, "SHC", layer: .transform, card: .layout,
            doc: doc("Turns it clockwise; layout is unchanged", "顺时针旋转，不影响排版", ".rotate(time.now.second * 6°)",
                     [meter("String", "Angle"), meter("Image", "ImageRotate"), meter("Rotator"), meter("Shape", "Shape").noted("Rotate")],
                     keywords: ["Angle", "ImageRotate", "Rotator", "rotation", "rotationEffect", "turn", "旋转"], rank: 45)),
        mod("scale", .transforms, "Scale", "缩放", [sig(
            pos("factor", .oneOf([.percent, .plainNumber]), facets: ["scale"], preview: "96%", "A percentage, or a plain factor",
                "百分比，或倍数"),
            arg("pivot", e("Alignment"), def: ".center", facets: ["scale.pivot"], "The point it grows from", "从哪个点缩放"))],
            allViews, "SHC", layer: .transform, card: .layout,
            doc: doc("Makes it bigger or smaller; layout is unchanged", "放大缩小，不影响排版", ".scale(96%)",
                     [meter("Shape", "Shape").noted("Scale")],
                     keywords: ["Shape", "scale", "scaleEffect", "zoom", "grow", "缩放"], rank: 40)),
    ]

    static let stateModifiers: [ModifierSpec] = [
        mod("hover", .statesAndAnimation, "While pointed at", "悬停时", [sig()], allViews, "S", block: .modifiers(required: true),
            card: .interaction,
            doc: doc("How it looks while the pointer is over it", "鼠标悬停时的样子", ".hover { .color(.accent) }",
                     [anyMeter("MouseOverAction").approx("paired MouseOverAction and MouseLeaveAction with !SetOption"),
                      anyMeter("MouseLeaveAction"), bang("!SetOption")],
                     keywords: ["MouseOverAction", "hover", "onHover", "mouse over", "hovered", "悬停"], rank: 70)),
        mod("pressed", .statesAndAnimation, "While pressed", "按下时", [sig()], allViews, "S", block: .modifiers(required: true),
            card: .interaction,
            doc: doc("How it looks while it is being pressed", "按下时的样子", ".pressed { .scale(96%) }",
                     [meter("Button").approx("the pressed frame of a Button meter")],
                     keywords: ["Button", "pressed", "active", "tap state", "按下"], rank: 45)),
        mod("animate", .statesAndAnimation, "Animation", "动画", [sig(
            pos("curve", e("Animation"), required: false, def: ".smooth", facets: ["animate"], "How the change moves", "变化的方式"),
            arg("duration", .duration, def: "250ms", facets: ["animate.duration"], "How long a change takes", "变化用多长时间"))],
            allViews, "S", card: .appearance,
            doc: doc("Animates changes to how it looks", "外观变化时带动画", ".animate(.spring)",
                     [plugin("ActionTimer").approx("fades driven by ActionTimer")],
                     keywords: ["ActionTimer", "animation", "transition", "ease", "动画"], rank: 45)),
        mod("appear", .statesAndAnimation, "Appear and disappear", "出现和消失", [sig(
            pos("transition", e("Transition"), required: false, def: ".fade", facets: ["appear"], "How it comes and goes", "出现和消失的方式"))],
            allViews, "S", card: .appearance,
            doc: doc("How it comes and goes: when the widget opens, when if or for adds or removes it, on show, hide or showOrHide, and when .hidden changes",
                     "出现和消失的过渡：组件打开、被 if/for 加入或移除、show/hide 和 .hidden 变化时", ".appear(.fade)",
                     [bang("!ShowFade").approx("the whole window"), bang("!HideFade").approx("the whole window")],
                     keywords: ["ShowFade", "HideFade", "transition", "fade in", "fade out", "出现", "淡入"], rank: 40)),
    ]

    static func onEvent(_ name: String, _ titleEn: String, _ titleZh: String, _ runtimeEvent: String, user: Bool,
                        record: String?, applies: ElementKindSet = allViews, params: [ParamSpec] = [],
                        repeatable: Repeatable? = nil, doc: Doc) -> ModifierSpec {
        mod(name, .interaction, titleEn, titleZh, [Signature(params: params)], applies, "", repeatable: repeatable,
            block: .actions(required: true), event: EventSpec(runtimeEvent: runtimeEvent, userInitiated: user, eventRecord: record),
            card: .interaction, doc: doc)
    }

    static let interactionModifiers: [ModifierSpec] = [
        onEvent("onClick", "When clicked", "点按时", "leftMouseUp", user: true, record: pointerEvent,
                applies: ElementKindSet.all.union(.of(.item)),
                doc: doc("Runs when it is clicked", "点击时执行", ".onClick { monthsFromNow = 0 }", [anyMeter("LeftMouseUpAction")],
                         keywords: ["LeftMouseUpAction", "onTap", "onPress", "onTapGesture", "click", "tap", "点击", "点按"], rank: 95)),
        onEvent("onDoubleClick", "When double-clicked", "连按时", "leftMouseDoubleClick", user: true, record: pointerEvent,
                doc: doc("Runs on a double click", "双击时执行", ".onDoubleClick { widget.openOptions() }",
                         [anyMeter("LeftMouseDoubleClickAction")],
                         keywords: ["LeftMouseDoubleClickAction", "double tap", "dblclick", "doubleClick", "双击", "连按"], rank: 50)),
        onEvent("onRightClick", "When right-clicked", "右键点按时", "rightMouseUp", user: true, record: pointerEvent,
                doc: doc("Runs on a right click (or Control-click) instead of the menu", "右键（或按住 Control 点按）时执行，代替右键菜单",
                         ".onRightClick { music.next() }", [anyMeter("RightMouseUpAction")],
                         keywords: ["RightMouseUpAction", "contextmenu", "secondary click", "rightClick", "右键"], rank: 40)),
        onEvent("onMouseEnter", "When the pointer arrives", "鼠标移入时", "mouseOver", user: false, record: nil,
                doc: doc("Runs when the pointer moves onto it", "鼠标移进来时执行", ".onMouseEnter { show(details) }",
                         [anyMeter("MouseOverAction")],
                         keywords: ["MouseOverAction", "onHover", "mouseenter", "onEnter", "鼠标移入"], rank: 45)),
        onEvent("onMouseLeave", "When the pointer leaves", "鼠标移出时", "mouseLeave", user: false, record: nil,
                doc: doc("Runs when the pointer leaves it", "鼠标移出去时执行", ".onMouseLeave { hide(details) }",
                         [anyMeter("MouseLeaveAction")],
                         keywords: ["MouseLeaveAction", "mouseleave", "onLeave", "鼠标移出"], rank: 40)),
        onEvent("onScroll", "When scrolled", "滚动时", "scroll", user: true, record: pointerEvent,
                params: [pos("direction", e("ScrollDirection"), required: false, preview: ".up",
                             "Only this direction; a direction's own block replaces the general one for it",
                             "只响应这个方向；写了方向的优先于不写方向的")],
                repeatable: .perArgument(0),
                doc: doc("Runs on scrolling over it, in any or one direction", "在它上面滚动时执行（可限定方向；限定方向的优先）",
                         ".onScroll(.up) { page = page - 1 }",
                         [anyMeter("MouseScrollUpAction"), anyMeter("MouseScrollDownAction"), anyMeter("MouseScrollLeftAction"),
                          anyMeter("MouseScrollRightAction")],
                         keywords: ["MouseScrollUpAction", "MouseScrollDownAction", "wheel", "scroll", "onWheel", "滚动"], rank: 40)),
        onEvent("onDrag", "While dragged", "拖动时", "drag", user: true, record: pointerEvent,
                doc: doc("Runs repeatedly while dragging on it; event.xPercent tells where", "在它上面拖动时持续执行；event.xPercent 是位置",
                         ".onDrag { volume.level = event.xPercent }",
                         [plugin("Mouse", "LeftMouseDragAction"), plugin("Slider", "DragAction")],
                         keywords: ["LeftMouseDragAction", "DragAction", "drag", "pan", "onPan", "拖动"], rank: 35)),
        onEvent("onDrop", "When something is dropped", "拖放到上面时", "drop", user: true, record: pointerEvent,
                doc: doc("Runs when files or text are dropped on it", "把文件或文字拖到它上面时执行", ".onDrop { copy(event.text) }",
                         keywords: ["drop", "onDrop", "dragAndDrop", "拖放"], mac: true, rank: 25)),
        onEvent("onSubmit", "When Return is pressed", "按回车时", "submit", user: true, record: nil, applies: .of(.input),
                doc: doc("Runs when Return is pressed in the field", "在输入框里按回车时执行", "Input(options.city).onSubmit { weather.refresh() }",
                         [plugin("InputText", "Command1")],
                         keywords: ["Command1", "InputText", "submit", "onCommit", "return", "enter", "回车"], mac: true, rank: 30)),
        mod("tooltip", .interaction, "Tooltip", "提示", [sig(
            pos("text", .string, facets: ["tooltip"], role: .display, translatable: true, preview: #""Back to today""#,
                "The tooltip's text", "提示的文字"),
            arg("title", .string, facets: ["tooltip.title"], role: .display, translatable: true, "A bold first line", "粗体的第一行"))],
            allViews, "SHC", card: .interaction,
            doc: doc("Text shown when the pointer rests on it", "鼠标停留时显示的提示", #".tooltip("Back to today")"#,
                     [anyMeter("ToolTipText"), anyMeter("ToolTipTitle")],
                     keywords: ["ToolTipText", "ToolTipTitle", "help", "title", "hint", "tooltip", "提示", "工具提示"], rank: 55)),
        mod("menu", .interaction, "Menu items", "右键菜单项", [sig()], allViews, "", block: .menuItems(required: true),
            card: .interaction,
            doc: doc("Adds items to the right-click menu", "往右键菜单里加菜单项",
                     #".menu { Item("Open Calendar").onClick { open("Calendar") } }"#,
                     [skin("ContextTitle"), skin("ContextAction")],
                     keywords: ["ContextTitle", "ContextAction", "contextMenu", "right-click menu", "右键菜单"], rank: 50)),
        mod("cursor", .interaction, "Pointer", "指针", [sig(
            pos("cursor", e("Cursor"), facets: ["cursor"], preview: ".hand", "The pointer's shape", "指针的样子"))],
            allViews, "SHC", card: .interaction,
            doc: doc("The pointer's shape over it", "鼠标指针的样子", ".cursor(.hand)",
                     [anyMeter("MouseActionCursor"), anyMeter("MouseActionCursorName")],
                     keywords: ["MouseActionCursor", "MouseActionCursorName", "cursor", "pointer", "指针", "光标"], rank: 30)),
    ]

    static func timingModifier(_ name: String, _ titleEn: String, _ titleZh: String, _ timing: TimingSpec,
                               params: [ParamSpec] = [], doc: Doc) -> ModifierSpec {
        mod(name, .timing, titleEn, titleZh, [Signature(params: params)], allViews, "", block: .actions(required: true),
            timing: timing, card: .interaction, doc: doc)
    }

    static let timingModifiers: [ModifierSpec] = [
        timingModifier("every", "Every so often", "每隔一段时间", .every(minimumSeconds: 0.016),
                       params: [pos("interval", .duration, range: 0.016...86_400, preview: "1s", "How often, at least 16ms",
                                    "隔多久执行一次，最短 16ms")],
                       doc: doc("Runs every interval while it is shown", "元素存在期间，每隔一段时间执行", ".every(1s) { seconds = seconds + 1 }",
                                [measure("Loop"), skin("Update"), skin("OnUpdateAction"), plugin("ActionTimer").approx()],
                                keywords: ["Loop", "Update", "OnUpdateAction", "ActionTimer", "timer", "interval", "setInterval",
                                           "onReceive", "定时", "每隔"], rank: 65)),
        timingModifier("when", "When it becomes true", "条件成立时", .when,
                       params: [pos("condition", .bool, role: .condition, preview: "battery.level < 20%", "The condition", "条件")],
                       doc: doc("Runs once each time the condition becomes true", "条件每次变成真时执行一次",
                                #".when(battery.level < 20%) { notify("Battery low") }"#,
                                [anyMeasure("IfCondition"), anyMeasure("IfTrueAction"),
                                 anyMeasure("IfFalseAction").noted("as .when(not …)"), anyMeasure("IfAboveValue"),
                                 anyMeasure("IfBelowValue"), anyMeasure("IfEqualValue"), anyMeasure("IfMatch")],
                                keywords: ["IfCondition", "IfTrueAction", "IfAboveValue", "IfBelowValue", "IfMatch", "trigger",
                                           "condition", "watch", "条件"], rank: 60)),
        timingModifier("onChange", "When the value changes", "值变化时", .onChange,
                       params: [arg("of", .any, required: true, preview: "music.title", "The value to watch", "要观察的值")],
                       doc: doc("Runs after the value changes", "值变化后执行", ".onChange(of: music.title) { plays = plays + 1 }",
                                [anyMeasure("OnChangeAction")], keywords: ["OnChangeAction", "onChange", "watch", "changed", "变化"],
                                rank: 45)),
        timingModifier("onLoad", "When it appears", "出现时", .onLoad,
                       doc: doc("Runs when it appears; on the outermost element, when the widget opens", "出现时执行；最外层元素上就是组件打开时",
                                ".onLoad { page = 0 }", [skin("OnRefreshAction")],
                                keywords: ["OnRefreshAction", "onAppear", "task", "mounted", "onLoad", "init", "加载", "出现时"], rank: 45)),
        timingModifier("onWake", "When the Mac wakes", "唤醒时", .onWake,
                       doc: doc("Runs when the Mac wakes from sleep", "Mac 从睡眠唤醒时执行", ".onWake { weather.refresh() }",
                                [skin("OnWakeAction")], keywords: ["OnWakeAction", "wake", "resume", "唤醒"], rank: 25)),
    ]

    static let reuseModifiers: [ModifierSpec] = [
        mod("style", .reuse, "Style", "样式", [sig(
            pos("name", .styleRef, role: .styleRef, preview: "todayCell", "One of your styles, written without a dot",
                "自己定义的样式，前面不加点"),
            arg("if", .bool, name: "condition", role: .condition, "Only while this is true", "只在条件成立时"))],
            allViews, "SHR", card: .appearance,
            doc: doc("Applies one of your styles; later styles win", "套用自己定义的样式；后写的优先", ".style(todayCell, if: page == 0)",
                     [anyMeter("MeterStyle")], keywords: ["MeterStyle", "class", "className", "style", "样式"], rank: 75,
                     context: ExampleContext(placement: .modifiers, declarations: ["style todayCell { .bold().color(.accent) }"]))),
        mod("voiceOver", .reuse, "VoiceOver", "旁白", [sig(
            pos("text", .string, facets: ["voiceOver"], role: .display, translatable: true, preview: #""Next month""#,
                "What VoiceOver says", "旁白朗读的内容"))],
            allViews, "SC", card: .interaction,
            doc: doc("What VoiceOver says for it", "旁白朗读的内容", #".voiceOver("Next month")"#,
                     keywords: ["accessibilityLabel", "aria-label", "VoiceOver", "screen reader", "旁白", "朗读"], rank: 25)),
        mod("rainmeter", .reuse, "Rainmeter detail", "Rainmeter 细节", [sig(
            pos("option", .string, source: .literal, preview: #""AntiAlias""#, "A Rainmeter option Deskset's renderer keeps",
                "Deskset 的绘制代码能保留的 Rainmeter 选项"),
            pos("value", .string, source: .literal, preview: #""0""#, "Its value, as the skin wrote it", "它的值，照皮肤里的写法"))],
            allViews, "R", card: .appearance,
            doc: doc("A Rainmeter-only detail kept by conversion and drawn by Deskset's renderer", "转换时保留下来、由 Deskset 的绘制代码实现的 Rainmeter 专有细节",
                     #".rainmeter("AntiAlias", "0")"#, [anyMeter("AntiAlias"), skin("AccurateText")],
                     keywords: ["AntiAlias", "AccurateText", "compatibility", "compat", "兼容"], rank: 10,
                     context: ExampleContext(placement: .modifiers, convertedFile: true))),
        mod("help", .reuse, "Help", "说明", [sig(
            pos("text", .string, facets: ["help"], role: .display, translatable: true, preview: #""Used for the arrows""#,
                "A line of help under the option", "选项下面的一行说明"))],
            ElementKindSet(), "", context: .option, card: .content,
            doc: doc("A line of help under the option", "选项下面的一行说明", #".help("Used for the arrows")"#,
                     keywords: ["help", "description", "hint", "subtitle", "说明"], rank: 30,
                     context: ExampleContext(placement: .modifiers, parent: .options))),
    ]
}
