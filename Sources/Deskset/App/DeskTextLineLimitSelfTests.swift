import AppKit
import CoreText
import DeskLanguage
import DesksetCore
import DesksetDraw

enum DeskTextLineLimitSelfTests {
    private typealias S = DeskConditionalTestSupport
    private enum Failure: Error { case fixture(String) }

    private final class NativeFonts: FontResolving {
        var generation = 0
        var multiplier: CGFloat = 1
        func registerFolder(_ folder: String) {}
        func resolve(_ request: FontRequest) -> DesksetDraw.ResolvedFont {
            DesksetDraw.ResolvedFont(font: CTFontCreateWithName(request.face as CFString, request.size * multiplier, nil),
                         syntheticBold: false, characterMap: nil, slant: 0, lineMetrics: nil)
        }
    }

    private static func style(_ limit: Int?, points: Double = 16) -> TextStyle {
        var value = TextStyle()
        value.fontFace = "Helvetica"
        value.fontSize = points * 0.75
        value.color = RGBA(r: 32, g: 64, b: 128)
        value.accurateText = true; value.antiAlias = true
        value.maximumLines = limit
        return value
    }

    private static func bitmap(scale: Int, _ draw: (CGContext) -> Void) throws -> Data {
        let width = 256 * scale, height = 192 * scale
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: SkinFrameProducer.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let bytes = context.data else {
            throw Failure.fixture("bitmap")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        _ = DrawTarget.prepareOwnedBitmap(context, glass: .none)
        draw(context)
        return Data(bytes: bytes, count: context.bytesPerRow * height)
    }

    private static func drawing(_ text: String, style: TextStyle, width: Double, height: Double) -> TextDraw {
        let frame = SkinRect(x: 12, y: 8, width: width, height: height)
        return TextDraw(text: text, style: style, frame: frame, contentFrame: frame, anchor: SkinPoint(x: 12, y: 8))
    }

    private static func pixels(_ value: TextDraw, scale: Int, context: DrawContext) throws -> Data {
        try bitmap(scale: scale) {
            DesksetDraw.DrawExecutor.draw([.text(value)], in: $0, context: context, cycle: 1,
                                         target: DrawTarget.capture($0, glass: .none))
        }
    }

    private static func attributed(_ text: String, font: CTFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
    }

    private static func metrics(_ line: CTLine, fallback: CTFont) -> (ascent: CGFloat, height: CGFloat) {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        if ascent + descent <= 0 {
            ascent = CTFontGetAscent(fallback); descent = CTFontGetDescent(fallback); leading = CTFontGetLeading(fallback)
        }
        return (ascent, ascent + max(descent, 0) + max(leading, 0))
    }

    private static func advance(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
    }

    private static func nativePixels(_ line: CTLine, ascent: CGFloat, width: CGFloat, scale: Int) throws -> Data {
        try bitmap(scale: scale) { destination in
            destination.clip(to: CGRect(x: 12, y: 0, width: width, height: 192))
            destination.setShouldAntialias(true)
            destination.setFillColor(CGColor(srgbRed: 32.0 / 255, green: 64.0 / 255, blue: 128.0 / 255, alpha: 1))
            destination.setTextDrawingMode(.fill)
            destination.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            destination.textPosition = CGPoint(x: 12, y: 8 + ascent)
            CTLineDraw(line, destination)
        }
    }

    private static func checkHorizontalInk(_ t: AppTestRunner, _ bytes: Data, scale: Int, width: CGFloat) {
        let first = Int(floor(12 * CGFloat(scale))), last = Int(ceil((12 + width) * CGFloat(scale)))
        var escaped = 0
        for y in 0..<(192 * scale) {
            for x in 0..<(256 * scale) where x < first || x >= last {
                if bytes[(y * 256 * scale + x) * 4 + 3] != 0 { escaped += 1 }
            }
        }
        t.equal(escaped, 0, "finite line width also bounds actual horizontal pixels")
    }

    static func run(_ t: AppTestRunner) {
        singleLine(t)
        multipleLines(t)
        legacyAndCache(t)
        preview(t)
    }

    private static func singleLine(_ t: AppTestRunner) {
        t.suite("Desk: text line limits: one line matches native truncation and finite widths contain glyphs") {
            let text = "ChargingUntilFullABCDEFGHIJKLMNOPQRSTUVWXYZ"
            let fonts = NativeFonts(), context = DrawContext(fonts: fonts)
            var input = style(1); input.wrap = true
            let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            let full = CTLineCreateWithAttributedString(attributed(text, font: font))
            let token = CTLineCreateWithAttributedString(attributed("…", font: font))
            for width in [CGFloat(138), 53.25, 1, 0] {
                let layout = context.text.layout(text, style: input, wrapWidth: width, cycle: 1)
                let native = width < advance(token) ? nil : CTLineCreateTruncatedLine(full, Double(width), .end, token)
                let line = native ?? CTLineCreateWithAttributedString(attributed("", font: font))
                let expectedMetrics = metrics(line, fallback: font)
                t.equal(layout.lines.count, 1)
                t.equal(layout.attributed.string, text, "shaping keeps the original source")
                t.close(layout.size.width, Double(min(ceil(max(advance(line), 0) - 0.001), width)))
                t.close(layout.size.height, Double(ceil(expectedMetrics.height - 0.001)))
                let value = drawing(text, style: input, width: Double(width), height: layout.size.height)
                for scale in [1, 2] {
                    let actual = try pixels(value, scale: scale, context: context)
                    let expected = try nativePixels(line, ascent: expectedMetrics.ascent, width: width, scale: scale)
                    t.equal(actual, expected, "independent CTLine end truncation at \(width)pt, \(scale)x")
                    checkHorizontalInk(t, actual, scale: scale, width: width)
                    if width <= 1 { t.check(actual.allSatisfy { $0 == 0 }, "a token that cannot fit leaves no glyphs") }
                    else { t.check(actual.contains { $0 != 0 }) }
                }
            }
            let word = CTLineCreateWithAttributedString(attributed("Status", font: font))
            let withToken = CTLineCreateWithAttributedString(attributed("Status…", font: font))
            let boundaries = [("Status\nHidden paragraph", advance(withToken) - 0.25),
                              ("Status\nHidden paragraph", advance(word) + 1),
                              ("Status followed by more words", advance(withToken) - 0.25)]
            for (text, width) in boundaries {
                let paragraph = String(text.prefix { $0 != "\n" }) + "…"
                let nativeSource = CTLineCreateWithAttributedString(attributed(paragraph, font: font))
                guard let expected = CTLineCreateTruncatedLine(nativeSource, Double(width), .end, token) else {
                    throw Failure.fixture("boundary has room for a native ellipsis")
                }
                let layout = context.text.layout(text, style: input, wrapWidth: width, cycle: 1)
                let value = drawing(text, style: input, width: Double(width), height: layout.size.height)
                let expectedMetrics = metrics(expected, fallback: font)
                t.close(layout.textWidth, advance(expected))
                t.check(layout.size.width <= Double(width))
                t.close(layout.size.height, Double(ceil(expectedMetrics.height - 0.001)))
                for scale in [1, 2] {
                    let actual = try pixels(value, scale: scale, context: context)
                    t.equal(actual, try nativePixels(expected, ascent: expectedMetrics.ascent, width: width, scale: scale),
                            "a near-fit token still truncates; omitted hard lines always retain an ellipsis")
                    t.check(actual.contains { $0 != 0 }, "a quarter-point overflow cannot blank a line that can be shortened")
                    t.check(actual != (try nativePixels(word, ascent: metrics(word, fallback: font).ascent, width: width, scale: scale)),
                            "fitting the original word is not permission to omit its required token")
                }
            }
            let edges: [(String, String, CGFloat)] = [("中文😀中文", "Helvetica", 10.25),
                                                      ("ffffffffff", "Helvetica-Oblique", 30.25)]
            for (text, face, width) in edges {
                var input = style(2); input.fontFace = face; input.wrap = true
                let layout = context.text.layout(text, style: input, wrapWidth: width, cycle: 1)
                t.check(layout.size.width <= Double(width) && layout.size.height > 0)
                for scale in [1, 2] {
                    let actual = try pixels(drawing(text, style: input, width: Double(width), height: layout.size.height),
                                            scale: scale, context: context)
                    checkHorizontalInk(t, actual, scale: scale, width: width)
                }
            }
        }
    }

    private static func multipleLines(_ t: AppTestRunner) {
        t.suite("Desk: text line limits: hard breaks and mixed font runs share selected metrics and preserve full UTF16") {
            let full = "One\n中文 😀 73\nThird\nHiddenWWWWWWWWWWWWWWWWWWWW"
            let literal = "One\n中文 😀 73\nThird…"
            var input = style(3)
            let middle = (full as NSString).range(of: "中文 😀 73"), number = (full as NSString).range(of: "73")
            let hidden = (full as NSString).range(of: "HiddenWWWWWWWWWWWWWWWWWWWW")
            input.inlineSpans = [
                InlineSpan(location: middle.location, length: middle.length, setting: .size(27 * 0.75)),
                InlineSpan(location: number.location, length: number.length, setting: .typography(feature: "tnum", value: 1)),
                InlineSpan(location: hidden.location, length: hidden.length, setting: .size(40 * 0.75))
            ]
            let context = DrawContext(fonts: NativeFonts())
            let layout = context.text.layout(full, style: input, wrapWidth: nil, cycle: 1)
            var referenceStyle = input; referenceStyle.maximumLines = nil
            let reference = context.text.layout(literal, style: referenceStyle, wrapWidth: nil, cycle: 1)
            t.equal(layout.lines.count, 3); t.equal(layout.attributed.string, full)
            t.equal(layout.attributed.length, full.utf16.count)
            t.close(layout.size.width, reference.size.width); t.close(layout.size.height, reference.size.height)
            t.check(layout.lines[1].ascent > layout.lines[0].ascent, "the second line has its own native fallback/run metrics")
            let summed = layout.lines.reduce(CGFloat(0)) { $0 + $1.ascent + $1.descent + $1.leading }
            t.close(layout.size.height, Double(ceil(summed - 0.001)))
            t.check(layout.size.height > Double(ceil(3 * (layout.lines[0].ascent + layout.lines[0].descent + layout.lines[0].leading))))
            let value = drawing(full, style: input, width: layout.size.width, height: layout.size.height)
            t.equal(value.text, full); t.equal(value.style.inlineSpans, input.inlineSpans)
            for scale in [1, 2] {
                let expected = drawing(literal, style: referenceStyle, width: reference.size.width, height: reference.size.height)
                t.equal(try pixels(value, scale: scale, context: context), try pixels(expected, scale: scale, context: context),
                        "explicit four-to-three lines match the independently written visible text")
            }
            var wrapped = input; wrapped.wrap = true; wrapped.inlineSpans = []
            let paragraph = "First 中文 👩🏽‍💻 second third fourth fifth sixth seventh eighth ninth"
            let soft = context.text.layout(paragraph, style: wrapped, wrapWidth: 87.25, cycle: 1)
            var unlimited = wrapped; unlimited.maximumLines = nil
            let complete = context.text.layout(paragraph, style: unlimited, wrapWidth: 87.25, cycle: 1)
            t.equal(soft.lines.count, 3); t.check(complete.lines.count > 3)
            t.equal(soft.attributed.string, paragraph)
            for i in 0..<2 {
                t.close(soft.lines[i].ascent, complete.lines[i].ascent)
                t.close(soft.lines[i].descent, complete.lines[i].descent)
                t.close(soft.lines[i].leading, complete.lines[i].leading)
            }
            for scale in [1, 2] {
                let actual = try pixels(drawing(paragraph, style: wrapped, width: 87.25, height: soft.size.height),
                                        scale: scale, context: context)
                let all = try pixels(drawing(paragraph, style: unlimited, width: 87.25, height: complete.size.height),
                                     scale: scale, context: context)
                let firstTwo = complete.lines.prefix(2).reduce(CGFloat(8)) { $0 + $1.ascent + $1.descent + $1.leading }
                let unchangedBytes = Int(floor(firstTwo * CGFloat(scale))) * 256 * scale * 4
                t.equal(actual.prefix(unchangedBytes), all.prefix(unchangedBytes), "lines before the final one keep their pixels")
                checkHorizontalInk(t, actual, scale: scale, width: 87.25)
                t.check(actual.contains { $0 != 0 })
            }
        }
    }

    private static func legacyAndCache(_ t: AppTestRunner) {
        t.suite("Desk: text line limits: cache identity and nil legacy clipping remain independent") {
            let fonts = NativeFonts(), cache = TextLayoutCache(fonts: fonts)
            let text = "First\nSecond\nThird\nFourth"
            var input = style(nil)
            let full = cache.layout(text, style: input, wrapWidth: nil, cycle: 1)
            input.maximumLines = 1
            let one = cache.layout(text, style: input, wrapWidth: nil, cycle: 1)
            input.maximumLines = 3
            let three = cache.layout(text, style: input, wrapWidth: nil, cycle: 1)
            t.check(full !== one && one !== three); t.equal(one.lines.count, 1); t.equal(three.lines.count, 3)
            input.maximumLines = nil
            t.check(cache.layout(text, style: input, wrapWidth: nil, cycle: 1) === full)
            let oldSize = one.size
            input.maximumLines = 1; fonts.multiplier = 1.5; fonts.generation += 1
            let renewed = cache.layout(text, style: input, wrapWidth: nil, cycle: 1)
            t.check(renewed !== one && renewed.size.height > oldSize.height)
            t.close(one.size.width, oldSize.width); t.close(one.size.height, oldSize.height)
            #if DEBUG
            guard let fixture = SkinDrawingSelfTests.load(t, """
            [Rainmeter]
            Update=-1
            AccurateText=1
            [Single]
            Meter=String
            Text=An ordinary long legacy sentence ending outside the width
            FontFace=Helvetica
            FontSize=12
            W=138
            ClipString=1
            AntiAlias=1
            [Wrapped]
            Meter=String
            Text=An ordinary long legacy sentence that wraps across several lines
            FontFace=Helvetica
            FontSize=12
            W=88
            H=38
            ClipString=1
            AntiAlias=1
            [Auto]
            Meter=String
            Text=中文 legacywordthatisverylong and several further words
            FontFace=Helvetica
            FontSize=12
            W=88
            H=38
            ClipString=2
            AntiAlias=1
            """, "line-limit-legacy") else { throw Failure.fixture("legacy INI") }
            defer { withExtendedLifetime(fixture.host) { fixture.skin.close() } }
            let context = SkinRenderContext()
            for meter in fixture.skin.meters.compactMap({ $0 as? StringMeter }) {
                t.equal(meter.style.maximumLines, nil)
                for scale in [1, 2] {
                    let actual = try bitmap(scale: scale) { SkinRenderer.drawString(meter.lower(), $0, context, cycle: 1) }
                    let original = try bitmap(scale: scale) {
                        LegacySkinRenderer.drawString(meter, $0, LegacySkinRenderContext.of(fixture.skin))
                    }
                    t.equal(actual, original, "nil line limit preserves \(meter.name) ClipString pixels")
                }
            }
            #endif
        }
    }

    private final class RecipeView: NSView {
        let item: TextDraw
        let context = DrawContext(fonts: AppFontResolver())
        override var isFlipped: Bool { true }
        init(_ item: TextDraw, bounds: NSRect) {
            self.item = item
            super.init(frame: NSRect(origin: .zero, size: bounds.size)); self.bounds = bounds
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let target = NSGraphicsContext.current?.cgContext else { return }
            DesksetDraw.DrawExecutor.draw([.text(item)], in: target, context: context, cycle: 1,
                                         target: DrawTarget.capture(target, glass: .none))
        }
    }

    private static func preview(_ t: AppTestRunner) {
        t.suite("Desk: text line limits: preview options remeasure negative text while actions and labels keep the full value") {
            let source = #"""
            options {
                size = Slider("Size", min: 8pt, max: 30pt, default: 11pt)
                body = Input("Body", default: "One\nTwo\nThird\nHidden long fourth line")
            }
            widget { Freeform {
                Text(options.body).font(options.size).color("#204080").width(138).lines(3)
                    .position(x: -9, y: -4).name(status).voiceOver(options.body).onClick { copy(options.body) }
            } }
            """#
            let file = DeskFileID(path: "TextLines.desk")
            let service = DeskLanguageService(openFile: file, files: [file: source])
            guard !service.snapshot.diagnostics.contains(where: { $0.severity == .error }) else {
                throw Failure.fixture("checker: \(service.snapshot.diagnostics)")
            }
            let time = try S.clock()
            let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
                dateLocale: { Locale(identifier: "en_US") }, preferredLanguages: { ["en"] }, system: S.System(),
                presentsTooltips: false, presentsMenus: false, presentsOptions: false) {
                    $0.file == file && $0.generation == service.snapshot.generation && service.snapshot.isChecked
                }
            let window = NSWindow(contentViewController: preview)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView?.layoutSubtreeIfNeeded()
            t.atSuiteEnd { preview.close(); window.close(); time.runUntilIdle() }
            preview.show(service.snapshot, readError: nil); preview.setVisible(true)
            let process = ProcessInfo.processInfo
            let temporary = process.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory
            let screenshots = temporary.appendingPathComponent("DeskTextLines-\(process.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
            let cases = [(11.0, "One\nTwo\nThird\nHidden long fourth line", "One\nTwo\nThird…"),
                         (24.0, "甲\n😀\n73\nHidden long fourth line", "甲\n😀\n73…"), (11.0, "Short", "Short")]
            var previous: Data?
            for (index, item) in cases.enumerated() {
                let (points, full, visible) = item
                if index > 0 {
                    let old = try preview.optionsSnapshot()
                    var values = old.values.values
                    values["size"] = .number(.init(points, dimension: .length)); values["body"] = .string(full)
                    var replies: [Result<ProgramOptionsSnapshot, Error>] = []
                    preview.updateOptions(.init(values: values), expectedRevision: old.revision) { replies.append($0) }
                    t.equal(replies.count, 1)
                    guard let reply = replies.first else { throw Failure.fixture("option completion") }
                    t.equal(try reply.get().revision, old.revision + 1)
                }
                t.equal(preview.state, .ready)
                let element = try S.element(preview.scene, "status")
                guard case .text(let draw)? = element.items.first else { throw Failure.fixture("text recipe") }
                t.equal(draw.text, full); t.equal(draw.style.maximumLines, 3)
                t.equal(element.accessibilityLabel, full, "the accepted label is not the shortened glyph string")
                t.close(element.frame.x, -9); t.close(element.frame.y, -4); t.close(element.frame.width, 138)
                var ordinary = draw.style; ordinary.maximumLines = nil
                let context = DrawContext(fonts: AppFontResolver())
                let measured = context.text.layout(visible, style: ordinary, wrapWidth: nil, cycle: 1)
                t.close(element.frame.height, measured.size.height, "selected native lines determine fit height")
                let expected = TextDraw(text: visible, style: ordinary, frame: draw.frame,
                                        contentFrame: draw.contentFrame, anchor: draw.anchor)
                let reference = RecipeView(expected, bounds: preview.canvas.bounds)
                for scale in [1, 2] {
                    let image = try S.paint(preview.canvas, scale: scale)
                    let actual = try S.bytes(image)
                    t.equal(actual, try S.bytes(S.paint(reference, scale: scale)), "literal visible text at \(scale)x")
                    if index < 2 {
                        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                            throw Failure.fixture("offscreen preview PNG")
                        }
                        let file = screenshots.appendingPathComponent("preview-\(index + 1)-\(scale)x.png")
                        try png.write(to: file)
                        print("Offscreen Desk text lines PNG: \(file.path)")
                    }
                    if scale == 1 {
                        if let previous { t.check(actual != previous, "accepted option changes replace real pixels") }
                        previous = actual
                    }
                }
                let point = NSPoint(x: element.frame.x + element.frame.width / 2,
                                    y: element.frame.y + element.frame.height / 2)
                t.equal(preview.scene?.hitMap.entries.first(where: { $0.elementID == element.id })?.elementID, element.id)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: preview.canvas.convert(point, to: nil),
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 1, clickCount: 1, pressure: 1) else { throw Failure.fixture("mouse event") }
                    if type == .leftMouseDown { preview.canvas.mouseDown(with: event) }
                    else { preview.canvas.mouseUp(with: event) }
                }
                t.equal(preview.recordedEffects.last, .copy(full), "preview copy keeps all hidden lines")
                t.equal(preview.recordedEffects.count, index + 1)
            }
            t.equal(service.snapshot.text, source)
            preview.close(); let generation = preview.scene?.generation
            time.advance(by: 2); t.equal(preview.scene?.generation, generation)
        }
    }
}
