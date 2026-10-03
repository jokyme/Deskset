#if DEBUG
import AppKit
import DesksetCore

enum SpriteDrawSelfTests {
    private static let formats = [(1, false), (1, true), (2, false), (2, true)]

    static func run(_ t: AppTestRunner) {
        t.suite("Runtime: sprite lowering: Button captures its strip geometry and pressed symbol opacity") {
            for mode in ["horizontal", "vertical", "symbol"] {
                weak var released: Skin?
                let captured = try autoreleasepool { () throws -> (SpriteDraw, [Data]) in
                    let path = t.temporaryDirectory("button-value").appendingPathComponent("strip.png")
                    try strip(frames: 3, horizontal: mode != "vertical").write(to: path)
                    let (skin, host) = try MediaUITests.bareSkin(t, """
                    [Rainmeter]
                    Update=-1
                    [Button]
                    Meter=Button
                    ButtonImage=\(mode == "symbol" ? "sf:power.circle.fill" : path.path)
                    X=12
                    Y=10
                    Padding=2,3,4,5
                    ImageFlip=Horizontal
                    ImageTint=180,230,90,192
                    MacSymbolSize=24
                    """)
                    released = skin
                    defer { skin.close(); withExtendedLifetime(host) {} }
                    skin.update()
                    guard let meter = skin.meter(named: "Button") as? ButtonMeter else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    let normal = meter.lower()
                    let before = try compare(normal, t) { LegacySkinRenderer.drawButton(meter, $0) }
                    t.equal(normal.cells.count, 1)
                    t.equal(normal.opacity, 1)
                    let content = meter.contentFrame
                    var hit: SkinPoint?
                    search: for row in 0..<Int(content.height) {
                        for column in 0..<Int(content.width) {
                            let point = SkinPoint(x: content.x + Double(column) + 0.5,
                                                  y: content.y + Double(row) + 0.5)
                            if meter.hitTest(x: point.x, y: point.y) { hit = point; break search }
                        }
                    }
                    guard let hit else { throw CocoaError(.coderInvalidValue) }
                    let x = hit.x, y = hit.y
                    meter.mouseHover(inside: true, x: x, y: y)
                    t.equal(meter.state, .hover)
                    let hover = meter.lower()
                    _ = try compare(hover, t) { LegacySkinRenderer.drawButton(meter, $0) }
                    _ = meter.handleMouse(.leftDown, x: x, y: y)
                    t.equal(meter.state, .pressed)
                    let pressed = meter.lower()
                    t.equal(pressed.opacity, mode == "symbol" ? 0.5 : 1)
                    let pressedPixels = try compare(pressed, t) { LegacySkinRenderer.drawButton(meter, $0) }
                    t.check(pressed != normal && pressedPixels != before, "the pressed drawing captures its changed state")
                    skin.execute("[!SetOption Button X 28][!SetOption Button Y 24]"
                                 + "[!SetOption Button ImageTint 80,100,240,128][!UpdateMeter Button][!Redraw]", from: nil)
                    let changed = meter.lower()
                    let changedPixels = try compare(changed, t) { LegacySkinRenderer.drawButton(meter, $0) }
                    t.check(changed != pressed && changedPixels != pressedPixels, "the next frame uses the new options")
                    try unchanged(normal, before, t)
                    try unchanged(pressed, pressedPixels, t)
                    return (normal, before)
                }
                t.check(released == nil, "the sprite does not retain its button's skin")
                Images.purge()
                try unchanged(captured.0, captured.1, t)
            }
        }

        t.suite("Runtime: sprite lowering: Bitmap captures selected frames and digit placement") {
            for extended in [false, true] {
                weak var released: Skin?
                let captured = try autoreleasepool { () throws -> (SpriteDraw, [Data]) in
                    let path = t.temporaryDirectory("bitmap-value").appendingPathComponent("digits.png")
                    try strip(frames: 10).write(to: path)
                    let (skin, host) = try MediaUITests.bareSkin(t, """
                    [Rainmeter]
                    Update=-1
                    [Variables]
                    Value=32
                    [Value]
                    Measure=Calc
                    Formula=#Value#
                    MinValue=0
                    MaxValue=100
                    DynamicVariables=1
                    [Bitmap]
                    Meter=Bitmap
                    MeasureName=Value
                    BitmapImage=\(path.path)
                    BitmapFrames=10
                    BitmapExtend=\(extended ? 1 : 0)
                    BitmapDigits=3
                    BitmapAlign=Center
                    BitmapSeparation=2
                    X=42
                    Y=12
                    ImageFlip=Vertical
                    ImageTint=120,230,200,160
                    """)
                    released = skin
                    defer { skin.close(); withExtendedLifetime(host) {} }
                    skin.update()
                    guard let meter = skin.meter(named: "Bitmap") as? BitmapMeter else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    let value = meter.lower()
                    t.equal(value.cells.count, extended ? 3 : 1)
                    let before = try compare(value, t) { LegacySkinRenderer.drawBitmap(meter, $0) }
                    skin.setVariable("Value", "87")
                    skin.execute("[!SetOption Bitmap Y 28][!SetOption Bitmap BitmapSeparation 4]"
                                 + "[!SetOption Bitmap ImageTint 240,100,80,224][!Update]", from: nil)
                    let changed = meter.lower()
                    let after = try compare(changed, t) { LegacySkinRenderer.drawBitmap(meter, $0) }
                    t.check(changed != value && after != before, "updated values and placement select another drawing")
                    try unchanged(value, before, t)
                    return (value, before)
                }
                t.check(released == nil, "the sprite does not retain its bitmap's skin")
                Images.purge()
                try unchanged(captured.0, captured.1, t)
            }
        }

        t.suite("Runtime: sprite lowering: Bitmap transition snapshots outlive their timers") {
            let folder = t.temporaryDirectory("bitmap-transition-value")
            let image = folder.appendingPathComponent("frames.png"), ini = folder.appendingPathComponent("Skin.ini")
            try strip(frames: 9).write(to: image)
            try """
            [Rainmeter]
            Update=-1
            TransitionUpdate=100
            [Variables]
            Value=5
            [Value]
            Measure=Calc
            Formula=#Value#
            MinValue=0
            MaxValue=100
            DynamicVariables=1
            [Bitmap]
            Meter=Bitmap
            MeasureName=Value
            BitmapImage=\(image.path)
            BitmapFrames=9
            BitmapTransitionFrames=2
            X=10
            Y=10
            """.write(to: ini, atomically: true, encoding: .utf8)
            weak var released: Skin?
            let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_000_000),
                                                timeZone: TimeZone(secondsFromGMT: 0)!)
            let frames = try autoreleasepool { () throws -> [(SpriteDraw, [Data])] in
                let host = RenderHost()
                let skin = Skin(config: "Transition", fileURL: ini, skinsDirectory: folder,
                                system: SystemMonitor.shared, host: host)
                skin.executor = executor
                skin.skinClock = executor.clock
                released = skin
                defer { skin.close(); withExtendedLifetime(host) {} }
                try skin.load()
                skin.update()
                guard let meter = skin.meter(named: "Bitmap") as? BitmapMeter else {
                    throw CocoaError(.coderInvalidValue)
                }
                var result: [(SpriteDraw, [Data])] = []
                func capture(_ expectedFrame: Int) throws {
                    t.equal(meter.displayedFrames, [expectedFrame])
                    let value = meter.lower()
                    let picture = try compare(value, t) { LegacySkinRenderer.drawBitmap(meter, $0) }
                    result.append((value, picture))
                }
                try capture(0)
                skin.setVariable("Value", "85")
                skin.update()
                try capture(1)
                executor.advance(by: 0.1)
                try capture(2)
                executor.advance(by: 0.1)
                try capture(6)
                // Unload with another transition still waiting: its captured in-between frame is independent of
                // the timer being cancelled when the skin closes.
                skin.setVariable("Value", "5")
                skin.update()
                try capture(7)
                for frame in result { try unchanged(frame.0, frame.1, t) }
                return result
            }
            t.check(released == nil, "the transition and captured sprites keep no skin alive")
            executor.advance(by: 1)
            Images.purge()
            for frame in frames { try unchanged(frame.0, frame.1, t) }
        }

        t.suite("Runtime: sprite lowering: missing strip images produce empty drawings") {
            let (skin, host) = try MediaUITests.bareSkin(t, """
            [Rainmeter]
            Update=-1
            [Button]
            Meter=Button
            ButtonImage=missing.png
            [Bitmap]
            Meter=Bitmap
            BitmapImage=missing.png
            """)
            defer { skin.close(); withExtendedLifetime(host) {} }
            skin.update()
            guard let button = skin.meter(named: "Button") as? ButtonMeter,
                  let bitmap = skin.meter(named: "Bitmap") as? BitmapMeter else {
                throw CocoaError(.coderInvalidValue)
            }
            for value in [button.lower(), bitmap.lower(), SpriteDraw(path: nil, options: ImageOptions(), cells: [])] {
                t.check(value.cells.isEmpty, "the unavailable image has no drawable frames")
                for format in formats {
                    let picture = try pixels(scale: format.0, bgra: format.1) { SkinRenderer.drawSprite(value, $0) }
                    t.check(picture.allSatisfy { $0 == 0 }, "empty sprites paint no pixels")
                }
            }
        }
    }

    private static func compare(_ value: SpriteDraw, _ t: AppTestRunner,
                                reference: (CGContext) -> Void) throws -> [Data] {
        try formats.map { scale, bgra in
            let picture = try pixels(scale: scale, bgra: bgra) { SkinRenderer.drawSprite(value, $0) }
            let frozen = try pixels(scale: scale, bgra: bgra, reference)
            t.check(picture.contains { $0 != 0 }, "the sprite paints visible pixels")
            t.equal(picture, frozen, "the captured sprite preserves the frozen pixels at \(scale)x, BGRA=\(bgra)")
            return picture
        }
    }

    private static func unchanged(_ value: SpriteDraw, _ expected: [Data], _ t: AppTestRunner) throws {
        for (index, format) in formats.enumerated() {
            let picture = try pixels(scale: format.0, bgra: format.1) { SkinRenderer.drawSprite(value, $0) }
            t.equal(picture, expected[index], "a captured frame stays the same after updates or owner release")
        }
    }

    private static func pixels(scale: Int, bgra: Bool, _ draw: (CGContext) -> Void) throws -> Data {
        let side = 80 * scale
        let info = bgra ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                        : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info), let bytes = ctx.data else {
            throw CocoaError(.featureUnsupported)
        }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        draw(ctx)
        var result = Data(capacity: side * side * 4)
        for row in 0..<side {
            result.append(bytes.advanced(by: row * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: side * 4)
        }
        return result
    }

    /// An original strip with a distinct, opaque color and corner in each frame.
    private static func strip(frames: Int, horizontal: Bool = true) throws -> Data {
        let width = horizontal ? frames * 12 : 12, height = horizontal ? 12 : frames * 12
        guard let canvas = Images.bitmapContext(width: width, height: height) else {
            throw CocoaError(.featureUnsupported)
        }
        for index in 0..<frames {
            let x = horizontal ? index * 12 : 0, y = horizontal ? 0 : index * 12
            canvas.setFillColor(RGBA(r: Double(30 + index * 19), g: Double(230 - index * 17),
                                    b: Double(40 + index * 21), a: 255).cgColor)
            canvas.fill(CGRect(x: x, y: y, width: 12, height: 12))
            canvas.setFillColor(RGBA.white.cgColor)
            canvas.fill(CGRect(x: x, y: y, width: 4, height: 3))
        }
        guard let image = canvas.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.featureUnsupported)
        }
        return png
    }
}
#endif
