import AppKit
import DesksetCore

enum TextDrawSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("Runtime: text lowering: captured text draws after its skin changes and is released") {
            var captured: TextDraw?
            var expected: [String: Data] = [:]
            weak var released: Skin?
            let context = SkinRenderContext()
            autoreleasepool {
                guard let loaded = SkinDrawingSelfTests.load(t, """
                [Rainmeter]
                Update=-1
                AccurateText=1
                [Value]
                Measure=String
                String=Captured text with enough words to wrap
                [Title]
                Meter=String
                MeasureName=Value
                X=150
                Y=100
                W=180
                H=80
                Padding=7,3,11,5
                FontSize=18
                FontColor=20,80,180,230
                StringAlign=CenterCenter
                ClipString=1
                Angle=0.2
                StringEffect=Border
                FontEffectColor=220,40,70,160
                InlineSetting=Color | 30,180,80,255
                InlinePattern=Captured
                InlineSetting2=Shadow | 1 | 3 | 4 | 0,0,0,200
                InlinePattern2=text
                """, "text-value"), let meter = loaded.skin.meter(named: "Title") as? StringMeter else {
                    return t.check(false, "the text fixture loads")
                }
                let skin = loaded.skin
                released = skin
                defer { withExtendedLifetime(loaded.host) { skin.close() } }
                let value = meter.lower()
                captured = value
                t.equal(value.text, "Captured text with enough words to wrap")
                t.equal(value.anchor, SkinPoint(x: 150, y: 100))
                t.check(value.contentFrame != value.frame && !value.style.inlineSpans.isEmpty,
                        "padding and resolved inline styles are part of the captured input")
                for scale in [1, 2] {
                    for bgra in [false, true] {
                        let key = "\(scale)-\(bgra)"
                        let before = pixels(scale: scale, bgra: bgra) { canvas in
                            SkinRenderer.drawString(value, canvas, context, cycle: skin.updateCount)
                        }
                        t.check(before?.contains { $0 != 0 } == true, "the captured text paints pixels")
                        expected[key] = before
                        #if DEBUG
                        let reference = pixels(scale: scale, bgra: bgra) { canvas in
                            LegacySkinRenderer.drawString(meter, canvas, LegacySkinRenderContext.of(skin))
                        }
                        t.equal(before, reference, "the lowered input preserves the frozen text drawing at \(key)")
                        #endif
                    }
                }
                skin.execute("[!SetOption Value String \"Updated text\"][!UpdateMeasure Value]"
                             + "[!SetOption Title FontSize 11][!SetOption Title FontColor 230,40,20,255]"
                             + "[!SetOption Title X 80][!SetOption Title Y 60][!SetOption Title Angle -0.15]"
                             + "[!SetOption Title ClipString 2][!SetOption Title Padding 1,2,3,4]"
                             + "[!SetOption Title InlineSetting \"Color | 180,30,140,255\"]"
                             + "[!UpdateMeter Title][!Redraw]", from: nil)
                let changed = meter.lower()
                t.equal(changed.text, "Updated text")
                t.check(changed != value, "updated content, style and layout make another value")
                for scale in [1, 2] {
                    for bgra in [false, true] {
                        let key = "\(scale)-\(bgra)"
                        let after = pixels(scale: scale, bgra: bgra) { canvas in
                            SkinRenderer.drawString(changed, canvas, context, cycle: skin.updateCount)
                        }
                        t.check(after != nil && after != expected[key], "the new value draws its new text at \(key)")
                        let old = pixels(scale: scale, bgra: bgra) { canvas in
                            SkinRenderer.drawString(value, canvas, context, cycle: skin.updateCount + 10)
                        }
                        t.equal(old, expected[key], "later updates and cache cycles leave the old drawing unchanged")
                    }
                }
            }
            t.check(released == nil, "the drawing and its context keep no skin alive")
            guard let captured else { return t.check(false, "the value was captured") }
            let fresh = SkinRenderContext()
            for scale in [1, 2] {
                for bgra in [false, true] {
                    let key = "\(scale)-\(bgra)"
                    let picture = pixels(scale: scale, bgra: bgra) { canvas in
                        SkinRenderer.drawString(captured, canvas, context, cycle: 100)
                    }
                    t.equal(picture, expected[key], "the captured value draws after its owner is gone at \(key)")
                    let rebuilt = pixels(scale: scale, bgra: bgra) { canvas in
                        SkinRenderer.drawString(captured, canvas, fresh, cycle: 100)
                    }
                    t.equal(rebuilt, expected[key], "a new layout cache draws the value without its owner at \(key)")
                }
            }
        }
    }

    /// Copy only active pixel bytes; CoreGraphics may pad the rows of a bitmap context.
    private static func pixels(scale: Int, bgra: Bool, _ draw: (CGContext) -> Void) -> Data? {
        let width = 320 * scale, height = 220 * scale
        let info = bgra
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: space, bitmapInfo: info),
              let bytes = canvas.data else { return nil }
        canvas.clear(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        draw(canvas)
        var result = Data(capacity: width * height * 4)
        for row in 0..<height {
            result.append(bytes.advanced(by: row * canvas.bytesPerRow).assumingMemoryBound(to: UInt8.self),
                          count: width * 4)
        }
        return result
    }
}
