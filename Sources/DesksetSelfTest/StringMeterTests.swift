import Foundation
@testable import DesksetCore

func runStringMeterTests(_ t: TestRunner) {
    runStringMeterReviewTests(t)
    func stringMeter(_ skin: Skin, _ name: String) -> StringMeter? { skin.meter(named: name) as? StringMeter }
    func style(_ skin: Skin, _ name: String) -> TextStyle { stringMeter(skin, name)?.style ?? TextStyle() }
    func frame(_ skin: Skin, _ name: String) -> SkinRect { skin.meter(named: name)?.frame ?? SkinRect(x: -1) }

    /// Host whose text is 10 pt per character and 20 pt per line; with a wrap width, whole characters are
    /// wrapped greedily (enough to test sizing rules without real fonts). Records every request.
    final class WrapHost: FakeHost {
        var requests: [(text: String, style: TextStyle, wrap: Double?)] = []
        override init() {
            super.init()
            textSizer = { [unowned self] text, style, wrap in
                self.requests.append((text, style, wrap))
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                var width = 0.0, count = 0.0
                for line in lines {
                    let w = Double(line.count) * 10
                    if let wrap, wrap > 0 {
                        let rows = max(ceil(w / wrap), 1)
                        width = max(width, min(w, wrap))
                        count += rows
                    } else {
                        width = max(width, w)
                        count += 1
                    }
                }
                return text.isEmpty ? (0, 0) : (width, count * 20)
            }
        }
    }

    t.suite("StringMeter: Text, %N, Prefix and Postfix") {
        let (skin, _) = try makeSkin(t, """
        [M1]
        Measure=String
        String=one
        [M2]
        Measure=String
        String=two
        [MPercent]
        Measure=String
        String=100%1
        [Calc]
        Measure=Calc
        Formula=7

        [Default]
        Meter=String
        MeasureName=M1
        [Two]
        Meter=String
        MeasureName=M1
        MeasureName2=M2
        Text=%2 then %1, %12 and %3 and 50%
        [NoRescan]
        Meter=String
        MeasureName=MPercent
        MeasureName2=M2
        Text=[%1|%2]
        [Missing]
        Meter=String
        MeasureName=NoSuchMeasure
        MeasureName2=M2
        Text=a%1b%2
        [MissingDefault]
        Meter=String
        MeasureName2=M2
        [Literal]
        Meter=String
        Text=%1 stays
        [Affixes]
        Meter=String
        MeasureName=Calc
        Prefix=<
        Postfix=" >"
        Text=v=%1
        [Empty]
        Meter=String
        """)
        skin.update()
        t.equal(text(skin, "Default"), "one", "Text defaults to %1")
        t.equal(text(skin, "Two"), "two then one, one2 and %3 and 50%")
        t.equal(text(skin, "NoRescan"), "[100%1|two]", "measure values are not scanned for %N")
        t.equal(text(skin, "Missing"), "abtwo", "unknown measure → empty, indices keep their numbers")
        t.equal(text(skin, "MissingDefault"), "")
        t.equal(text(skin, "Literal"), "%1 stays")
        t.equal(text(skin, "Affixes"), "<v=7 >")
        t.equal(text(skin, "Empty"), "")
        t.equal(frame(skin, "Empty"), SkinRect(), "empty string has no size")
    }

    t.suite("StringMeter: %N substitution helper") {
        let values = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L"]
        func sub(_ s: String, _ count: Int) -> String {
            StringMeter.substitute(s, count: count) { $0 <= values.count ? values[$0 - 1] : nil }
        }
        t.equal(sub("%1%2", 2), "AB")
        t.equal(sub("%12", 12), "L")
        t.equal(sub("%12", 2), "A2")
        t.equal(sub("%0 %", 3), "%0 %")
        t.equal(sub("100%", 3), "100%")
        t.equal(sub("%%1", 1), "%A")
        t.equal(sub("%1😀%2", 2), "A😀B")
    }

    t.suite("StringMeter: number formatting options") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Dec=2
        [Big]
        Measure=Calc
        Formula=1536
        [Half]
        Measure=Calc
        Formula=25
        MaxValue=200

        [Plain]
        Meter=String
        MeasureName=Big
        [Decimals]
        Meter=String
        MeasureName=Big
        NumOfDecimals=(#Dec# + 1)
        [Scaled]
        Meter=String
        MeasureName=Big
        Scale=1000.0
        [ScaledInt]
        Meter=String
        MeasureName=Big
        Scale=(500*2)
        [Auto1]
        Meter=String
        MeasureName=Big
        AutoScale=1
        Text=%1B
        [Auto2]
        Meter=String
        MeasureName=Big
        AutoScale=2
        NumOfDecimals=2
        [Auto1k]
        Meter=String
        MeasureName=Half
        AutoScale=1k
        NumOfDecimals=3
        [Percent]
        Meter=String
        MeasureName=Half
        Percentual=1
        [PercentDecimals]
        Meter=String
        MeasureName=Half
        Percentual=1
        NumOfDecimals=1
        """)
        skin.update()
        t.equal(text(skin, "Plain"), "1536")
        t.equal(text(skin, "Decimals"), "1536.000", "NumOfDecimals accepts formulas")
        t.equal(text(skin, "Scaled"), "1.5", "a Scale with a decimal point shows decimals")
        t.equal(text(skin, "ScaledInt"), "2", "Scale accepts formulas")
        t.equal(text(skin, "Auto1"), "1.5 kB")
        t.equal(text(skin, "Auto2"), "1.54 k")
        t.equal(text(skin, "Auto1k"), "0.024 k")
        t.equal(text(skin, "Percent"), "12")
        t.equal(text(skin, "PercentDecimals"), "12.5", "NumOfDecimals works with Percentual")
    }

    t.suite("StringMeter: StringCase and TrailingSpaces") {
        let (skin, _) = try makeSkin(t, """
        [Upper]
        Meter=String
        Text=Straße up
        StringCase=UPPER
        [Lower]
        Meter=String
        Text=MiXeD Case
        StringCase=lower
        [Proper]
        Meter=String
        Text=hello wORLD (don't) 3rd-party
        StringCase=Proper
        [None]
        Meter=String
        Text=As Is
        StringCase=None
        [Trimmed]
        Meter=String
        Text="   spaced   "
        [Kept]
        Meter=String
        Text="   spaced   "
        TrailingSpaces=1
        [AffixSpaces]
        Meter=String
        Prefix="CPU: "
        Text="  42  "
        """)
        skin.update()
        t.equal(text(skin, "Upper"), "STRASSE UP", "whole-string case may change the length")
        t.equal(text(skin, "Lower"), "mixed case")
        t.equal(text(skin, "Proper"), "Hello World (Don't) 3rd-party")
        t.equal(text(skin, "None"), "As Is")
        t.equal(text(skin, "Trimmed"), "spaced", "TrailingSpaces=0 trims the Text option")
        t.equal(text(skin, "Kept"), "   spaced   ")
        t.check(style(skin, "Kept").trailingSpaces)
        t.check(!style(skin, "Trimmed").trailingSpaces)
        t.equal(text(skin, "AffixSpaces"), "CPU: 42", "Prefix keeps its quoted space")
    }

    t.suite("StringMeter: case helpers") {
        t.equal(StringMeter.applyCase(.upper, to: "straße", preserveLength: true), "STRAßE",
                "length-preserving: ß kept")
        t.equal(StringMeter.applyCase(.proper, to: "the QUICK  fox\tjumps", preserveLength: true),
                "The Quick  Fox\tJumps")
        t.equal(StringMeter.applyCase(.sentence, to: "hELLO there. how ARE you? fine! ok", preserveLength: true),
                "Hello there. How are you? Fine! Ok")
        t.equal(StringMeter.applyCase(.sentence, to: "v1.5 is out", preserveLength: true), "V1.5 is out")
        t.equal(StringMeter.applyCase(.lower, to: "ÀÉÎ", preserveLength: true), "àéî")
    }

    t.suite("StringMeter: font and effect options") {
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        AccurateText=1
        [Variables]
        Size=12
        [Defaults]
        Meter=String
        Text=x
        [Custom]
        Meter=String
        Text=x
        FontFace=  Segoe UI
        FontSize=(#Size# / 2 + 0.5)
        FontColor=FF000080
        FontWeight=650.4
        StringStyle=BoldItalic
        StringEffect=Border
        FontEffectColor=1,2,3,4
        Angle=(PI/2)
        AntiAlias=1
        [EmptyFace]
        Meter=String
        Text=x
        FontFace=
        FontSize=-3
        FontWeight=5000
        StringStyle=italic
        StringEffect=shadow
        [Huge]
        Meter=String
        Text=x
        FontSize=(10**300)
        FontWeight=0
        Angle=(10**300)
        [Garbage]
        Meter=String
        Text=x
        FontSize=abc
        StringStyle=Wavy
        StringEffect=Glow
        """)
        skin.update()
        let d = style(skin, "Defaults")
        t.equal(d.fontFace, "Arial")
        t.close(d.fontSize, 10)
        t.equal(d.fontWeight, nil)
        t.check(!d.bold && !d.italic)
        t.equal(d.color, RGBA.black)
        t.equal(d.effect, .none)
        t.equal(d.effectColor, RGBA.black)
        t.equal(d.horizontalAlign, .left)
        t.equal(d.verticalAlign, .top)
        t.equal(d.clip, 0)
        t.close(d.angle, 0)
        t.check(!d.antiAlias)
        t.check(d.accurateText, "AccurateText comes from [Rainmeter]")

        let c = style(skin, "Custom")
        t.equal(c.fontFace, "Segoe UI")
        t.close(c.fontSize, 6.5)
        t.equal(c.color, RGBA(r: 255, g: 0, b: 0, a: 128))
        t.equal(c.fontWeight, 650)
        t.check(c.bold && c.italic)
        t.equal(c.effect, .border)
        t.equal(c.effectColor, RGBA(r: 1, g: 2, b: 3, a: 4))
        t.close(c.angle, Double.pi / 2)
        t.check(c.antiAlias)

        let e = style(skin, "EmptyFace")
        t.equal(e.fontFace, "Arial", "empty FontFace → Arial")
        t.close(e.fontSize, 0, "negative FontSize → 0 (invisible)")
        t.equal(e.fontWeight, 999)
        t.check(e.italic && !e.bold)
        t.equal(e.effect, .shadow)

        let h = style(skin, "Huge")
        t.close(h.fontSize, StringMeter.maximumFontSize)
        t.equal(h.fontWeight, 1)
        t.check(h.angle.isFinite && abs(h.angle) < 2 * Double.pi)

        let g = style(skin, "Garbage")
        t.close(g.fontSize, 10, "unparseable FontSize → default")
        t.check(!g.bold && !g.italic)
        t.equal(g.effect, .none)
    }

    t.suite("StringMeter: StringAlign values") {
        let cases: [(String, HorizontalTextAlign, VerticalTextAlign)] = [
            ("Left", .left, .top), ("Right", .right, .top), ("Center", .center, .top),
            ("LeftTop", .left, .top), ("RightTop", .right, .top), ("CenterTop", .center, .top),
            ("LeftCenter", .left, .center), ("RightCenter", .right, .center), ("CenterCenter", .center, .center),
            ("LeftBottom", .left, .bottom), ("RightBottom", .right, .bottom), ("CenterBottom", .center, .bottom),
            ("centercenter", .center, .center), (" Right Bottom ", .right, .bottom), ("", .left, .top),
            ("Middle", .left, .top), ("RightMiddle", .right, .top),
        ]
        for (raw, h, v) in cases {
            let parsed = StringMeter.parseAlign(raw)
            t.equal(parsed.horizontal, h, "horizontal of \(raw)")
            t.equal(parsed.vertical, v, "vertical of \(raw)")
        }
    }

    t.suite("StringMeter: StringAlign anchors the meter box") {
        // Default FakeHost metrics: 7 pt per character, 14 pt per line → "abcd" is 28×14.
        let (skin, _) = try makeSkin(t, """
        [S]
        X=100
        Y=50
        Text=abcd
        [LT]
        Meter=String
        MeterStyle=S
        [CT]
        Meter=String
        MeterStyle=S
        StringAlign=Center
        [RT]
        Meter=String
        MeterStyle=S
        StringAlign=Right
        [LC]
        Meter=String
        MeterStyle=S
        StringAlign=LeftCenter
        [CC]
        Meter=String
        MeterStyle=S
        StringAlign=CenterCenter
        [RC]
        Meter=String
        MeterStyle=S
        StringAlign=RightCenter
        [LB]
        Meter=String
        MeterStyle=S
        StringAlign=LeftBottom
        [CB]
        Meter=String
        MeterStyle=S
        StringAlign=CenterBottom
        [RB]
        Meter=String
        MeterStyle=S
        StringAlign=RightBottom
        [BoxCC]
        Meter=String
        X=50
        Y=50
        W=100
        H=100
        StringAlign=CenterCenter
        Text=abcd
        [BoxRB]
        Meter=String
        X=200
        Y=100
        W=60
        H=40
        StringAlign=RightBottom
        Text=abcd
        [Padded]
        Meter=String
        X=100
        Y=100
        Padding=1,2,3,4
        StringAlign=RightBottom
        Text=abcd
        [NextR]
        Meter=String
        X=5R
        Y=0r
        Text=ab
        """)
        skin.update()
        t.equal(frame(skin, "LT"), SkinRect(x: 100, y: 50, width: 28, height: 14))
        t.equal(frame(skin, "CT"), SkinRect(x: 86, y: 50, width: 28, height: 14))
        t.equal(frame(skin, "RT"), SkinRect(x: 72, y: 50, width: 28, height: 14))
        t.equal(frame(skin, "LC"), SkinRect(x: 100, y: 43, width: 28, height: 14))
        t.equal(frame(skin, "CC"), SkinRect(x: 86, y: 43, width: 28, height: 14))
        t.equal(frame(skin, "RC"), SkinRect(x: 72, y: 43, width: 28, height: 14))
        t.equal(frame(skin, "LB"), SkinRect(x: 100, y: 36, width: 28, height: 14))
        t.equal(frame(skin, "CB"), SkinRect(x: 86, y: 36, width: 28, height: 14))
        t.equal(frame(skin, "RB"), SkinRect(x: 72, y: 36, width: 28, height: 14))
        // Manual: "to CenterCenter align a string within a meter with a width and height of 100, set X=50, Y=50".
        t.equal(frame(skin, "BoxCC"), SkinRect(x: 0, y: 0, width: 100, height: 100))
        t.equal(frame(skin, "BoxRB"), SkinRect(x: 140, y: 60, width: 60, height: 40))
        t.equal(frame(skin, "Padded"), SkinRect(x: 68, y: 80, width: 32, height: 20))
        t.equal(stringMeter(skin, "Padded")?.contentFrame, SkinRect(x: 69, y: 82, width: 28, height: 14))
        // r / R follow the previous meter's anchor (X=100, Y=100), R adds its W (padding included): 100 + 32 + 5.
        t.equal(frame(skin, "NextR"), SkinRect(x: 137, y: 100, width: 14, height: 14), "R follows the anchor + W")
        let anchor = stringMeter(skin, "CC")?.anchorPoint
        t.close(anchor?.x ?? -1, 100)
        t.close(anchor?.y ?? -1, 50)
        let boxAnchor = stringMeter(skin, "BoxRB")?.anchorPoint
        t.close(boxAnchor?.x ?? -1, 200)
        t.close(boxAnchor?.y ?? -1, 100)
    }

    t.suite("StringMeter: ClipString modes and sizes") {
        let host = WrapHost()
        let (skin, _) = try makeSkin(t, """
        [Clip0]
        Meter=String
        W=50
        Text=abcdefghij
        [Clip1NoW]
        Meter=String
        ClipString=1
        Text=abcdefghij
        [Clip1W]
        Meter=String
        W=50
        ClipString=1
        Text=abcdefghij
        [Clip1WH]
        Meter=String
        W=50
        H=40
        ClipString=1
        Text=abcdefghij
        [Clip2W]
        Meter=String
        W=50
        ClipString=2
        Text=abcdefghij
        [Clip2WH]
        Meter=String
        W=50
        H=30
        ClipString=2
        ClipStringH=10
        Text=abcdefghij
        [Clip2Max]
        Meter=String
        ClipString=2
        ClipStringW=40
        ClipStringH=50
        Text=abcdefghijklmnop
        [Clip2Short]
        Meter=String
        ClipString=2
        ClipStringW=400
        ClipStringH=500
        Text=abc
        [Clip2Free]
        Meter=String
        ClipString=2
        Text=abcdefghij
        [Clip2Ignored]
        Meter=String
        ClipString=2
        W=30
        ClipStringW=80
        Text=abcdefghij
        [Clip2Bad]
        Meter=String
        ClipString=2
        ClipStringW=-5
        ClipStringH=0
        Text=abcdefghij
        [Clip3]
        Meter=String
        ClipString=3
        W=10
        Text=abc
        """, host: host)
        skin.update()
        t.equal(style(skin, "Clip0").clip, 0)
        t.equal(frame(skin, "Clip0"), SkinRect(width: 50, height: 20))
        t.equal(style(skin, "Clip1NoW").clip, 0, "ClipString=1 without W has nothing to clip to")
        t.equal(frame(skin, "Clip1NoW"), SkinRect(width: 100, height: 20))
        t.equal(style(skin, "Clip1W").clip, 1)
        t.check(!style(skin, "Clip1W").wrap, "without H: one line, ellipsis")
        t.equal(frame(skin, "Clip1W"), SkinRect(width: 50, height: 20))
        t.check(style(skin, "Clip1WH").wrap, "with H: wraps")
        t.check(style(skin, "Clip1WH").breakLongWords)
        t.equal(frame(skin, "Clip1WH"), SkinRect(width: 50, height: 40))
        t.equal(style(skin, "Clip2W").clip, 2)
        t.check(style(skin, "Clip2W").wrap && !style(skin, "Clip2W").breakLongWords)
        t.equal(frame(skin, "Clip2W"), SkinRect(width: 50, height: 40), "grows in height")
        t.equal(frame(skin, "Clip2WH"), SkinRect(width: 50, height: 30), "H wins over ClipStringH")
        t.equal(frame(skin, "Clip2Max"), SkinRect(width: 40, height: 50), "limited by ClipStringW / ClipStringH")
        t.equal(frame(skin, "Clip2Short"), SkinRect(width: 30, height: 20), "shrinks to the text")
        t.check(!style(skin, "Clip2Free").wrap)
        t.equal(frame(skin, "Clip2Free"), SkinRect(width: 100, height: 20))
        t.equal(frame(skin, "Clip2Ignored"), SkinRect(width: 30, height: 80), "ClipStringW is ignored when W is set")
        t.equal(frame(skin, "Clip2Bad"), SkinRect(width: 100, height: 20), "non-positive limits are ignored")
        t.equal(style(skin, "Clip3").clip, 0)
        let wraps = host.requests.filter { $0.text == "abcdefghijklmnop" }.map(\.wrap)
        t.check(wraps.contains(40), "measured with the maximum width")
    }

    t.suite("StringMeter: style reaches the host measurement") {
        let host = WrapHost()
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        AccurateText=0
        [M]
        Meter=String
        FontFace=Tahoma
        FontSize=14
        Text=hello
        InlineSetting=Color | 255,0,0
        InlinePattern=l+
        """, host: host)
        skin.update()
        guard let request = host.requests.last else { return t.check(false, "no measurement") }
        t.equal(request.text, "hello")
        t.equal(request.style.fontFace, "Tahoma")
        t.close(request.style.fontSize, 14)
        t.check(!request.style.accurateText)
        t.equal(request.style.inlineSpans, [InlineSpan(location: 2, length: 2, setting: .color(RGBA(r: 255, g: 0, b: 0)))])
        t.close(TextStyle.pixelSize(points: 12), 16)
        t.close(TextStyle.gdiPaddingFactor, 1.0 / 6.0)
    }

    t.suite("StringMeter: InlineSetting parsing") {
        t.equal(InlineSetting.parse("Face | Segoe Script"), .face("Segoe Script"))
        t.equal(InlineSetting.parse("face|\"Courier New\""), .face("Courier New"))
        t.equal(InlineSetting.parse("Face |"), nil)
        t.equal(InlineSetting.parse("Size | 12.5"), .size(12.5))
        t.equal(InlineSetting.parse("SIZE | (6*2)"), .size(12))
        t.equal(InlineSetting.parse("Size | 0"), nil, "Size 0 is ignored")
        t.equal(InlineSetting.parse("Size | -4"), nil)
        t.equal(InlineSetting.parse("Size | 99999"), .size(InlineSetting.maximumSize))
        t.equal(InlineSetting.parse("Color | 255,97,97,255"), .color(RGBA(r: 255, g: 97, b: 97)))
        t.equal(InlineSetting.parse("Color | FF000080"), .color(RGBA(r: 255, g: 0, b: 0, a: 128)))
        t.equal(InlineSetting.parse("Color | nope"), nil)
        t.equal(InlineSetting.parse("Weight | 700"), .weight(700))
        t.equal(InlineSetting.parse("Weight | 2000"), .weight(999))
        t.equal(InlineSetting.parse("Weight | 0"), .weight(1))
        t.equal(InlineSetting.parse("Case | Sentence"), .textCase(.sentence))
        t.equal(InlineSetting.parse("Case | upper"), .textCase(.upper))
        t.equal(InlineSetting.parse("Case | Title"), nil)
        t.equal(InlineSetting.parse("CharacterSpacing | 2 | 2"),
                .characterSpacing(leading: 2, trailing: 2, minimumAdvance: 0))
        t.equal(InlineSetting.parse("CharacterSpacing | * | -1.5 | 8"),
                .characterSpacing(leading: 0, trailing: -1.5, minimumAdvance: 8))
        t.equal(InlineSetting.parse("Italic"), .italic)
        t.equal(InlineSetting.parse("oblique"), .oblique)
        t.equal(InlineSetting.parse("Underline"), .underline)
        t.equal(InlineSetting.parse("StrikeThrough"), .strikethrough)
        t.equal(InlineSetting.parse("Shadow | 2 | 2 | 3.5 | 150,150,150,200"),
                .shadow(offsetX: 2, offsetY: 2, blur: 3.5, color: RGBA(r: 150, g: 150, b: 150, a: 200)))
        t.equal(InlineSetting.parse("Shadow | -1"), .shadow(offsetX: -1, offsetY: 0, blur: 0, color: .black))
        t.equal(InlineSetting.parse("Stretch | 3"), .stretch(3))
        t.equal(InlineSetting.parse("Stretch | 12"), .stretch(9))
        t.equal(InlineSetting.parse("Typography | smcp"), .typography(feature: "smcp", value: 1))
        t.equal(InlineSetting.parse("Typography | ss02 | 0"), .typography(feature: "ss02", value: 0))
        t.equal(InlineSetting.parse("Typography | toolong"), nil)
        t.equal(InlineSetting.parse("None"), InlineSetting.none)
        t.equal(InlineSetting.parse("Sparkle | 3"), nil)
        t.equal(InlineSetting.parse(""), nil)

        let g = InlineSetting.parse("GradientColor | 180 | 255,0,0,255 ; 0.0 | 0,255,0,255 ; 0.5 | 0,0,255,255 ; 1.0")
        t.equal(g, .gradient(InlineGradient(angle: 180, stops: [
            GradientStop(color: RGBA(r: 255, g: 0, b: 0), position: 0),
            GradientStop(color: RGBA(r: 0, g: 255, b: 0), position: 0.5),
            GradientStop(color: RGBA(r: 0, g: 0, b: 255), position: 1),
        ])))
        let g1 = InlineSetting.parse("GradientColor1 | -90 | 0,0,0 ; 0.8 | 255,255,255 ; 0.2 | 9,9,9")
        t.equal(g1, .gradient(InlineGradient(angle: 270, stops: [
            GradientStop(color: RGBA(r: 255, g: 255, b: 255), position: 0.2),
            GradientStop(color: RGBA(r: 0, g: 0, b: 0), position: 0.8),
            GradientStop(color: RGBA(r: 9, g: 9, b: 9), position: 1),
        ], linearGamma: true)), "sorted, missing last position = 1, GradientColor1 = linear gamma")
        let spread = InlineSetting.parse("GradientColor | 45.5 | 1,1,1 | 2,2,2 | 3,3,3")
        t.equal(spread, .gradient(InlineGradient(angle: 45.5, stops: [
            GradientStop(color: RGBA(r: 1, g: 1, b: 1), position: 0),
            GradientStop(color: RGBA(r: 2, g: 2, b: 2), position: 0.5),
            GradientStop(color: RGBA(r: 3, g: 3, b: 3), position: 1),
        ])))
        t.equal(InlineSetting.parse("GradientColor | 90 | 1,1,1 ; 0"), nil, "needs two colors")
        t.equal(InlineSetting.parse("GradientColor | x | 1,1,1 | 2,2,2"), nil)
    }

    t.suite("StringMeter: InlinePattern matching") {
        let (skin, host) = try makeSkin(t, """
        [MeasureText]
        Measure=String
        String=This is a test string with 123 and 456.#CRLF#colors like red and blue.

        [M]
        Meter=String
        MeasureName=MeasureText
        InlineSetting=Weight | 700
        InlinePattern=^(.*) is
        InlineSetting2=Size | 17
        InlinePattern2=(\\d\\d\\d)
        InlineSetting3=Underline
        InlinePattern3=test string
        InlineSetting4=Color | 255,0,0
        InlinePattern4=colors like (.*) and (.*)\\.
        InlineSetting5=Italic
        InlineSetting6=Oblique
        InlinePattern6=
        InlineSetting7=None
        InlinePattern7=.*
        InlineSetting8=Strikethrough
        InlinePattern8=(unclosed
        InlineSetting9=Bogus | 1
        InlineSetting10=Underline
        InlinePattern10=blue
        InlineSetting12=Underline
        """)
        skin.update()
        let spans = style(skin, "M").inlineSpans
        func ranges(_ setting: InlineSetting) -> [String] {
            let ns = text(skin, "M") as NSString
            return spans.filter { $0.setting == setting }
                .map { ns.substring(with: NSRange(location: $0.location, length: $0.length)) }
        }
        t.equal(ranges(.weight(700)), ["This"], "capture group only")
        t.equal(ranges(.size(17)), ["123", "456"], "every match")
        t.equal(ranges(.underline), ["test string", "blue"], "whole match without groups; numbering stops at a gap")
        t.equal(ranges(.color(RGBA(r: 255, g: 0, b: 0))), ["red", "blue"], "each capture group")
        t.equal(ranges(.italic), ["This is a test string with 123 and 456.", "colors like red and blue."],
                "default pattern .* covers every line")
        t.equal(ranges(.oblique).count, 2, "empty InlinePattern = .*")
        t.equal(ranges(.strikethrough), [], "invalid pattern → nothing")
        t.check(host.logs.contains { $0.contains("InlinePattern") && $0.contains("(unclosed") }, "invalid pattern logged")
        t.check(host.logs.contains { $0.contains("InlineSetting9") }, "unsupported setting logged")
        t.equal(spans.map(\.setting).filter { $0 == InlineSetting.none }.count, 0)
    }

    t.suite("StringMeter: inline Case and ordering") {
        let (skin, _) = try makeSkin(t, """
        [M]
        Meter=String
        Text=straße STAYS lower then shout
        InlineSetting=Case | Upper
        InlinePattern=^(\\S+)
        InlineSetting2=Case | Lower
        InlinePattern2=STAYS
        InlineSetting3=Color | 0,255,0
        InlinePattern3=shout
        InlineSetting4=Case | Upper
        InlinePattern4=shout
        [Sentence]
        Meter=String
        Text=first. SECOND sentence! third
        StringCase=Lower
        InlineSetting=Case | Sentence
        """)
        skin.update()
        t.equal(text(skin, "M"), "STRAßE stays lower then SHOUT", "length-preserving inline case")
        let span = style(skin, "M").inlineSpans.first
        t.equal(span?.location, 24)
        t.equal(span?.length, 5)
        t.equal(text(skin, "Sentence"), "First. Second sentence! Third", "applied after StringCase")
    }

    t.suite("StringMeter: InlineSetting numbering and dynamic changes") {
        let (skin, _) = try makeSkin(t, """
        [M]
        Meter=String
        Text=abc
        InlineSetting=None
        InlineSetting2=Underline
        InlineSetting3=Italic
        [NoFirst]
        Meter=String
        Text=abc
        InlineSetting2=Underline
        """)
        skin.update()
        t.equal(style(skin, "M").inlineSpans.map(\.setting), [.underline, .italic])
        t.equal(style(skin, "NoFirst").inlineSpans, [],
                "the numbering starts at InlineSetting: InlineSetting2 alone follows a gap (review fix)")
        skin.perform(Bang(name: "setoption", args: ["M", "InlineSetting2", "None"]))
        skin.update()
        t.equal(style(skin, "M").inlineSpans.map(\.setting), [.italic], "None switches a setting off")
        skin.perform(Bang(name: "setoption", args: ["M", "InlineSetting2", ""]))
        skin.update()
        t.equal(style(skin, "M").inlineSpans.map(\.setting), [], "an empty InlineSetting2 ends the list")
        skin.perform(Bang(name: "setoption", args: ["M", "InlineSetting2", "Size | 20"]))
        skin.perform(Bang(name: "setoption", args: ["M", "InlinePattern2", "^$"]))
        skin.update()
        t.equal(style(skin, "M").inlineSpans.map(\.setting), [.italic], "^$ matches nothing")
        skin.perform(Bang(name: "setoption", args: ["M", "Text", "xyz"]))
        skin.perform(Bang(name: "setoption", args: ["M", "InlinePattern2", "y"]))
        skin.update()
        t.equal(style(skin, "M").inlineSpans, [InlineSpan(location: 1, length: 1, setting: .size(20)),
                                               InlineSpan(location: 0, length: 3, setting: .italic)])
        // Removing the first one: "all subsequent ones will be ignored".
        skin.perform(Bang(name: "setoption", args: ["M", "InlineSetting", ""]))
        skin.update()
        t.equal(style(skin, "M").inlineSpans, [], "removing InlineSetting ends the list (review fix)")
    }

    t.suite("StringMeter: robustness") {
        let long = String(repeating: "0123456789", count: 5000)
        let (skin, _) = try makeSkin(t, """
        [Long]
        Measure=String
        String=\(long)
        [M]
        Meter=String
        MeasureName=Long
        InlineSetting=Underline
        InlinePattern=(\\d)
        [Weird]
        Meter=String
        Text=%99999999999999999999 %-1 %
        ClipString=2
        ClipStringW=(1/0)
        W=(-5)
        H=(10**400)
        Angle=(0/0)
        [Catastrophic]
        Meter=String
        Text=aaaaaaaaaaaaaaaaaaaaaaaaaaaa!
        InlineSetting=Underline
        InlinePattern=(a|a)*b
        """)
        skin.update()
        t.equal(text(skin, "M").utf16.count, StringMeter.maximumTextLength)
        t.equal(style(skin, "M").inlineSpans.count, StringMeter.maximumInlineSpans)
        t.equal(text(skin, "Weird"), "%99999999999999999999 %-1 %")
        t.close(style(skin, "Weird").angle, 0)
        t.equal(style(skin, "Catastrophic").inlineSpans, [])
    }

    t.suite("StringMeter: TestSkins/String fixtures load cleanly") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestSkins/String")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return t.check(false, "TestSkins/String missing at \(root.path)")
        }
        var count = 0
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "ini" {
            let host = FakeHost()
            let config = url.deletingLastPathComponent().path.dropFirst(root.deletingLastPathComponent().path.count + 1)
            let skin = Skin(config: config.replacingOccurrences(of: "/", with: "\\"), fileURL: url,
                            skinsDirectory: root.deletingLastPathComponent(), system: FakeSystem(), host: host)
            try skin.load()
            skin.update()
            skin.update()
            t.equal(skin.issues, [], url.lastPathComponent)
            t.equal(host.logs.filter { !$0.hasPrefix("Debug") }, [], url.lastPathComponent)
            t.check(skin.meters.contains { $0 is StringMeter }, url.lastPathComponent)
            count += 1
            withExtendedLifetime(host) {}
        }
        t.check(count >= 6, "found \(count) fixtures")
    }
}

// MARK: - Adversarial review (feat/string-review)

func runStringMeterReviewTests(_ t: TestRunner) {
    func stringMeter(_ skin: Skin, _ name: String) -> StringMeter? { skin.meter(named: name) as? StringMeter }

    t.suite("StringMeter review: an empty Text is not set") {
        // Manual (!SetOption guide): setting an option to "" removes it, so the default applies again — for
        // Text that is "the value of the measure" when MeasureName is given.
        let (skin, _) = try makeSkin(t, """
        [M1]
        Measure=String
        String=measured
        [EmptyText]
        Meter=String
        MeasureName=M1
        Text=
        [QuotedEmpty]
        Meter=String
        MeasureName=M1
        Text=""
        [Affixed]
        Meter=String
        MeasureName=M1
        Prefix=<
        Text=
        Postfix=>
        [NoMeasure]
        Meter=String
        Text=
        [Removed]
        Meter=String
        MeasureName=M1
        Text=custom %1
        """)
        skin.update()
        t.equal(text(skin, "EmptyText"), "measured")
        t.equal(text(skin, "QuotedEmpty"), "measured")
        t.equal(text(skin, "Affixed"), "<measured>")
        t.equal(text(skin, "NoMeasure"), "")
        t.equal(text(skin, "Removed"), "custom measured")
        skin.perform(Bang(name: "setoption", args: ["Removed", "Text", ""]))
        skin.update()
        t.equal(text(skin, "Removed"), "measured", "!SetOption Text \"\" shows the measure again")
    }

    t.suite("StringMeter review: ClipString=2 word boundaries") {
        /// Applies the rule the way the renderer does: `suggest(line)` stands for the typesetter's suggestion.
        func lines(_ text: String, suggest: Int) -> [String] {
            let units = Array(text.utf16)
            var out: [String] = []
            var start = 0
            while start < units.count, out.count < 100 {
                let count = TextWrapRules.wordBoundaryBreak(units, start: start, count: min(suggest, units.count - start))
                out.append(String(decoding: units[start..<(start + count)], as: UTF16.self))
                start += count
            }
            return out
        }
        // Latin: only after spaces / tabs; a long word stays whole.
        t.equal(lines("hello world again", suggest: 8), ["hello ", "world ", "again"])
        t.equal(lines("ab Supercalifragilistic x", suggest: 6), ["ab ", "Supercalifragilistic ", "x"])
        t.equal(lines("tab\tseparated", suggest: 5), ["tab\t", "separated"])
        t.equal(lines("3rd-party stuff", suggest: 4), ["3rd-party ", "stuff"], "no break after a hyphen")
        t.equal(lines("line\nbreak", suggest: 3), ["line\n", "break"])
        // CJK: characters are words, so the typesetter's break is kept (a sentence still wraps).
        t.equal(lines("中文字体测试", suggest: 2), ["中文", "字体", "测试"])
        t.equal(lines("日本語のテキスト", suggest: 3), ["日本語", "のテキ", "スト"])
        // A Latin word followed by ideographs breaks before them rather than being clipped.
        t.equal(lines("中文abcdefgh", suggest: 5), ["中文", "abcdefgh"])
        t.equal(lines("abcdefgh中文", suggest: 5), ["abcdefgh", "中文"])
        // Supplementary ideographs (surrogate pairs) are never split.
        let ext = "\u{20000}\u{20001}\u{20002}"
        for line in lines("abcdef" + ext, suggest: 7) { t.check(!line.unicodeScalars.contains { $0.value == 0xFFFD }) }
        t.equal(lines("abcdef" + ext, suggest: 7).joined(), "abcdef" + ext)
        // Closing punctuation does not start a line when the rule has to move the break.
        let units = Array("中文。abcdefgh".utf16)
        t.check(!TextWrapRules.isBoundary(units, 2), "no break before 。")
        t.check(TextWrapRules.isBoundary(units, 3), "break after 。 before a Latin word")
        // Hostile arguments never trap.
        t.equal(TextWrapRules.wordBoundaryBreak([], start: 0, count: 1), 1)
        t.equal(TextWrapRules.wordBoundaryBreak(Array("ab".utf16), start: 1, count: 99), 1)
    }

    t.suite("StringMeter review: invalid dynamic patterns are logged a bounded number of times") {
        let (skin, host) = try makeSkin(t, """
        [Counter]
        Measure=Calc
        Formula=Counter + 1
        [M]
        Meter=String
        Text=abc
        DynamicVariables=1
        InlineSetting=Underline
        InlinePattern=([Counter]
        """)
        for _ in 0..<150 { skin.update() }
        let logged = host.logs.filter { $0.contains("invalid InlinePattern") }.count
        t.check(logged > 0 && logged <= 64, "logged \(logged) times")
        t.equal(stringMeter(skin, "M")?.style.inlineSpans, [])
    }

    t.suite("StringMeter review: unsupported InlineSetting is logged once") {
        let (skin, host) = try makeSkin(t, """
        [M]
        Meter=String
        Text=abc
        DynamicVariables=1
        InlineSetting=Sparkle | 3
        InlineSetting2=Size | 0
        InlineSetting3=Underline
        """)
        for _ in 0..<20 { skin.update() }
        t.equal(host.logs.filter { $0.contains("InlineSetting=") }.count, 1)
        t.equal(host.logs.filter { $0.contains("InlineSetting2=") }.count, 1)
        t.equal(stringMeter(skin, "M")?.style.inlineSpans.map(\.setting), [.underline], "the others still apply")
    }

    t.suite("StringMeter review: tab interval") {
        var style = TextStyle()
        style.fontSize = 12
        t.close(style.tabInterval, 64, "DirectWrite default: 4 × the font size (16 px)")
    }

    t.suite("StringMeter review: text length is bounded in UTF-16 units") {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 40_000)
        let emoji = String(repeating: "😀", count: 20_000)
        let (skin, _) = try makeSkin(t, """
        [Z]
        Measure=String
        String=\(zalgo)
        [E]
        Measure=String
        String=\(emoji)
        [MZ]
        Meter=String
        MeasureName=Z
        [ME]
        Meter=String
        MeasureName=E
        """)
        skin.update()
        let z = text(skin, "MZ"), e = text(skin, "ME")
        t.check(z.utf16.count <= StringMeter.maximumTextLength, "combining marks: \(z.utf16.count)")
        t.check(z.utf16.count > StringMeter.maximumTextLength - 2)
        t.check(e.utf16.count <= StringMeter.maximumTextLength, "emoji: \(e.utf16.count)")
        t.equal(e.utf16.count % 2, 0, "surrogate pairs are never split")
        t.check(e.unicodeScalars.allSatisfy { $0 == "😀" })
    }
}
