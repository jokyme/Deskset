import AppKit
import DesksetCore

enum ImageDrawValueSelfTests {
    private static let formats = [(scale: 1, bgra: false), (scale: 1, bgra: true),
                                  (scale: 2, bgra: false), (scale: 2, bgra: true)]

    static func run(_ t: AppTestRunner) {
        imageTests(t)
        barTests(t)
        emptyTests(t)
    }

    private static func imageTests(_ t: AppTestRunner) {
        t.suite("Runtime: image lowering: processed, masked, tiled and sliced values outlive their meters") {
            let images = try fixtures(t)
            let cases = [
                ("fit", "Card.png", "PreserveAspectRatio=1\nMacDecodeSize=Drawn\nImageCrop=-4,-2,128,84\n"),
                ("exif", "CardExif6.jpg", "PreserveAspectRatio=2\nUseExifOrientation=1\n"),
                ("mask", "Card.png", "MaskImageName=\(images.appendingPathComponent("Mask.png").path)\n"
                    + "MaskImageFlip=Horizontal\nMaskImageRotate=90\nTile=1\nScaleMargins=8,8,8,8\n"),
                ("tile", "Tile.png", "Tile=1\nImageRotate=90\n"),
                ("nine-slice", "Frame9.png", "PreserveAspectRatio=0\nScaleMargins=8,8,8,8\nImageRotate=90\n")
            ]
            for (name, file, options) in cases {
                weak var releasedSkin: Skin?
                weak var releasedMeter: ImageMeter?
                let frozen = try autoreleasepool { () throws -> (draw: ImageDraw, pixels: [Data]) in
                    let (skin, host) = try MediaUITests.bareSkin(t, """
                    [Rainmeter]
                    Update=-1
                    [File]
                    Measure=String
                    String=\(file)
                    [Picture]
                    Meter=Image
                    MeasureName=File
                    ImageName=%1
                    ImagePath=\(images.path)
                    X=12.25
                    Y=11.5
                    W=\(name == "fit" ? 34 : 88)
                    H=\(name == "fit" ? 30 : 60)
                    Padding=4,3,2,1
                    ImageTint=180,240,210,190
                    ImageFlip=Vertical
                    \(options)
                    """)
                    defer { withExtendedLifetime(host) { skin.close() } }
                    skin.update()
                    guard let meter = skin.meter(named: "Picture") as? ImageMeter else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    releasedSkin = skin
                    releasedMeter = meter
                    let draw = meter.lower()
                    let before = try formats.map { format in
                        let picture = try pixels(format) { SkinRenderer.drawImage(draw, $0) }
                        t.check(picture.contains { $0 != 0 }, "\(name): the image paints pixels")
                        #if DEBUG
                        let reference = try pixels(format) { LegacySkinRenderer.drawImage(meter, $0) }
                        t.check(picture == reference, "\(name) \(format): the frozen renderer's pixels")
                        #endif
                        return picture
                    }
                    skin.perform(Bang(name: "setoption", args: ["File", "String", "Card.png"]))
                    for (key, value) in [("X", "35"), ("Y", "23"), ("W", "72"), ("H", "50"),
                                         ("ImageTint", "240,80,160,120"), ("ImageFlip", "Horizontal"),
                                         ("ImageRotate", "20"), ("MaskImageName", ""), ("Tile", "0"),
                                         ("ScaleMargins", "2,3,4,5"), ("PreserveAspectRatio", "0"),
                                         ("MacDecodeSize", "File")] {
                        skin.perform(Bang(name: "setoption", args: ["Picture", key, value]))
                    }
                    skin.update()
                    let changed = meter.lower()
                    t.check(changed != draw, "\(name): later measure, options and layout produce another value")
                    for (index, format) in formats.enumerated() {
                        let kept = try pixels(format) { SkinRenderer.drawImage(draw, $0) }
                        let next = try pixels(format) { SkinRenderer.drawImage(changed, $0) }
                        t.check(kept == before[index], "\(name): the captured image ignores the next update")
                        t.check(next != before[index], "\(name): the next value changes the image")
                        #if DEBUG
                        let reference = try pixels(format) { LegacySkinRenderer.drawImage(meter, $0) }
                        t.check(next == reference, "\(name): updated drawing still matches the frozen renderer")
                        #endif
                    }
                    return (draw, before)
                }
                t.check(releasedSkin == nil && releasedMeter == nil, "\(name): the image retains no owner")
                for (index, format) in formats.enumerated() {
                    let picture = try pixels(format) { SkinRenderer.drawImage(frozen.draw, $0) }
                    t.check(picture == frozen.pixels[index], "\(name): the captured image draws after its owner is released")
                }
            }
        }
    }

    private static func barTests(_ t: AppTestRunner) {
        t.suite("Runtime: image lowering: Bar captures measure geometry and host dimensions before drawing") {
            let images = try fixtures(t)
            for image in [false, true] {
                for vertical in [false, true] {
                    let name = "\(image ? "image" : "color") \(vertical ? "vertical" : "horizontal")"
                    weak var releasedSkin: Skin?
                    weak var releasedMeter: BarMeter?
                    weak var releasedHost: ImageHost?
                    let frozen = try autoreleasepool { () throws -> (draw: BarDraw, pixels: [Data]) in
                        let file = images.appendingPathComponent(vertical ? "BarV.png" : "BarH.png").path
                        let (skin, render) = try MediaUITests.bareSkin(t, """
                        [Rainmeter]
                        Update=-1
                        [Level]
                        Measure=Calc
                        Formula=35
                        MinValue=0
                        MaxValue=100
                        [Bar]
                        Meter=Bar
                        MeasureName=Level
                        X=12.5
                        Y=11.25
                        W=100
                        H=80
                        Padding=3,2,4,1
                        BarOrientation=\(vertical ? "Vertical" : "Horizontal")
                        BarImage=\(image ? file : "")
                        BarBorder=4
                        BarColor=80,170,220,180
                        ImageTint=180,240,210,190
                        ImageFlip=Vertical
                        ImageRotate=90
                        """)
                        let host = ImageHost(render)
                        skin.host = host
                        defer { withExtendedLifetime(host) { skin.close() } }
                        skin.update()
                        guard let meter = skin.meter(named: "Bar") as? BarMeter else {
                            throw CocoaError(.coderInvalidValue)
                        }
                        releasedSkin = skin
                        releasedMeter = meter
                        releasedHost = host
                        host.queries = 0
                        let draw = meter.lower()
                        t.check(image ? host.queries > 0 : host.queries == 0,
                                "\(name): image-size queries happen while the value is captured")
                        let before = try formats.map { format in
                            let count = host.queries
                            let picture = try pixels(format) { SkinRenderer.drawBar(draw, $0) }
                            t.equal(host.queries, count, "drawing does not query the host")
                            t.check(picture.contains { $0 != 0 }, "\(name): the bar paints pixels")
                            #if DEBUG
                            let reference = try pixels(format) { LegacySkinRenderer.drawBar(meter, $0) }
                            t.check(picture == reference, "\(name) \(format): the frozen renderer's pixels")
                            #endif
                            return picture
                        }
                        skin.perform(Bang(name: "setoption", args: ["Level", "Formula", "82"]))
                        for (key, value) in [("X", "22"), ("Y", "20"), ("Flip", "1"), ("BarBorder", "2"),
                                             ("BarColor", "220,80,130,120"), ("ImageTint", "240,80,160,120"),
                                             ("ImageRotate", "0")] {
                            skin.perform(Bang(name: "setoption", args: ["Bar", key, value]))
                        }
                        skin.update()
                        let changed = meter.lower()
                        t.check(changed != draw, "\(name): changed fill and options produce another value")
                        for (index, format) in formats.enumerated() {
                            let count = host.queries
                            let kept = try pixels(format) { SkinRenderer.drawBar(draw, $0) }
                            let next = try pixels(format) { SkinRenderer.drawBar(changed, $0) }
                            t.equal(host.queries, count, "neither captured value queries its host")
                            t.check(kept == before[index], "\(name): the captured fill ignores later updates")
                            t.check(next != before[index], "\(name): the next value changes the fill")
                            #if DEBUG
                            let reference = try pixels(format) { LegacySkinRenderer.drawBar(meter, $0) }
                            t.check(next == reference, "\(name): updated drawing still matches the frozen renderer")
                            #endif
                        }
                        if image {
                            host.available = false
                            let unavailable = meter.lower()
                            let count = host.queries
                            for (index, format) in formats.enumerated() {
                                let empty = try pixels(format) { SkinRenderer.drawBar(unavailable, $0) }
                                let kept = try pixels(format) { SkinRenderer.drawBar(draw, $0) }
                                t.check(empty.allSatisfy { $0 == 0 }, "missing image dimensions produce an empty new bar")
                                t.check(kept == before[index], "the old bar keeps the dimensions it captured")
                            }
                            t.equal(host.queries, count, "drawing does not retry unavailable host dimensions")
                        }
                        return (draw, before)
                    }
                    t.check(releasedSkin == nil && releasedMeter == nil && releasedHost == nil,
                            "\(name): the value retains no skin, meter or image host")
                    for (index, format) in formats.enumerated() {
                        let picture = try pixels(format) { SkinRenderer.drawBar(frozen.draw, $0) }
                        t.check(picture == frozen.pixels[index], "\(name): the captured bar draws after its owner is released")
                    }
                }
            }
        }
    }

    private static func emptyTests(_ t: AppTestRunner) {
        t.suite("Runtime: image lowering: empty images and bars stay empty") {
            let images = try fixtures(t)
            let (skin, host) = try MediaUITests.bareSkin(t, """
            [Rainmeter]
            Update=-1
            [Image]
            Meter=Image
            ImagePath=\(images.path)
            W=40
            H=30
            [Level]
            Measure=Calc
            Formula=0
            MinValue=0
            MaxValue=100
            [Bar]
            Meter=Bar
            MeasureName=Level
            W=40
            H=30
            BarColor=255,100,20
            """)
            defer { withExtendedLifetime(host) { skin.close() } }
            guard let image = skin.meter(named: "Image") as? ImageMeter,
                  let bar = skin.meter(named: "Bar") as? BarMeter else { throw CocoaError(.coderInvalidValue) }
            for narrow in [false, true] {
                if narrow {
                    skin.perform(Bang(name: "setoption", args: ["Image", "ImageName", "Card.png"]))
                    skin.perform(Bang(name: "setoption", args: ["Image", "W", "0"]))
                    skin.perform(Bang(name: "setoption", args: ["Level", "Formula", "100"]))
                    skin.perform(Bang(name: "setoption", args: ["Bar", "H", "0"]))
                }
                skin.update()
                let imageDraw = image.lower(), barDraw = bar.lower()
                for format in formats {
                    let picture = try pixels(format) { SkinRenderer.drawImage(imageDraw, $0) }
                    let fill = try pixels(format) { SkinRenderer.drawBar(barDraw, $0) }
                    t.check(picture.allSatisfy { $0 == 0 }, narrow ? "zero-width image" : "empty image path")
                    t.check(fill.allSatisfy { $0 == 0 }, narrow ? "zero-height bar" : "zero fill")
                    #if DEBUG
                    let referenceImage = try pixels(format) { LegacySkinRenderer.drawImage(image, $0) }
                    let referenceBar = try pixels(format) { LegacySkinRenderer.drawBar(bar, $0) }
                    t.check(picture == referenceImage && fill == referenceBar, "empty drawing matches the frozen renderer")
                    #endif
                }
            }
        }
    }

    /// Only original repository fixtures are copied into the test's temporary folder.
    private static func fixtures(_ t: AppTestRunner) throws -> URL {
        guard let source = Paths.repositoryFolder("TestSkins/Image/ImageMeters/@Resources/Images") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = t.temporaryDirectory("image-draw-values")
        for file in ["Card.png", "CardExif6.jpg", "Tile.png", "Frame9.png", "Mask.png", "BarH.png", "BarV.png"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(file),
                                             to: folder.appendingPathComponent(file))
        }
        return folder
    }

    /// Copy only active bytes; bitmap row padding is not image content.
    private static func pixels(_ format: (scale: Int, bgra: Bool), _ draw: (CGContext) -> Void) throws -> Data {
        let width = 180 * format.scale, height = 180 * format.scale
        let info = format.bgra
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info), let data = ctx.data else {
            throw CocoaError(.featureUnsupported)
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(format.scale), y: -CGFloat(format.scale))
        draw(ctx)
        var result = Data(capacity: width * height * 4)
        for row in 0..<height {
            result.append(data.advanced(by: row * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return result
    }

    private final class ImageHost: SkinHost, SkinImageQueries {
        let render: RenderHost
        var queries = 0
        var available = true

        init(_ render: RenderHost) { self.render = render }

        func skinNeedsDisplay(_ skin: Skin) {}
        func skin(_ skin: Skin, handle bang: Bang) -> Bool { true }
        func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {}
        func skin(_ skin: Skin, execute target: String, arguments: [String]) {}
        func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {}
        func textSize(_ text: String, style: TextStyle, wrapWidth: Double?,
                      for skin: Skin) -> (width: Double, height: Double) {
            render.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
        }
        func imageSize(atPath path: String) -> (width: Double, height: Double)? {
            queries += 1
            return available ? render.imageSize(atPath: path) : nil
        }
        func imageExifOrientation(atPath path: String) -> Int { render.imageExifOrientation(atPath: path) }
        func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
            render.imagePixelAlpha(atPath: path, x: x, y: y, exifOriented: exifOriented)
        }
        func environment(for skin: Skin) -> SkinEnvironment { render.environment(for: skin) }
    }
}
