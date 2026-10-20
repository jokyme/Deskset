import AppKit
import DesksetCore

enum HistogramImageSelfTests {
    static func run(_ t: AppTestRunner) {
        rotations(t)
        reveal(t)
        matrices(t)
        fallbacks(t)
        capturedOptions(t)
    }

    private static func rotations(_ t: AppTestRunner) {
        t.suite("App: Histogram image options: quarter turns and image flips have independent pixels") {
            // The 8x4 source has a red left half and a blue right half. These are expected screen colors,
            // not a second invocation of the image transformation being tested.
            let cases: [(angle: Int, flip: String, size: [Double], first: [Int], second: [Int])] = [
                (90, "None", [4, 8], red, blue),
                (-90, "None", [4, 8], blue, red),
                (180, "None", [8, 4], blue, red),
                (90, "Horizontal", [4, 8], blue, red),
                (90, "Both", [4, 8], blue, red),
                (180, "Both", [8, 4], red, blue),
            ]
            for test in cases {
                guard let loaded = try load(t, options: """
                    PrimaryImageRotate=\(test.angle)
                    PrimaryImageFlip=\(test.flip)
                    """) else { return t.check(false, "rotation fixture loads") }
                defer { withExtendedLifetime(loaded.host) { loaded.skin.close() } }
                guard let meter = loaded.skin.meter(named: "Graph") as? HistogramMeter else {
                    return t.check(false, "histogram loads")
                }
                fill(loaded.skin, meter)
                t.equal([meter.contentFrame.width, meter.contentFrame.height], test.size)
                for format in formats {
                    let picture = try bitmap(meter.lower(), format)
                    let first = (x: 5, y: 5)
                    let second = test.size[0] == 4 ? (x: 5, y: 10) : (x: 10, y: 5)
                    check(t, picture.pixel(first.x, first.y), test.first, "\(test.angle) / \(test.flip): first half")
                    check(t, picture.pixel(second.x, second.y), test.second, "\(test.angle) / \(test.flip): second half")
                    check(t, picture.pixel(3, 5), clear, "the image stays inside the meter")
                }
            }
        }
    }

    private static func reveal(_ t: AppTestRunner) {
        t.suite("App: Histogram image options: reveal clips the rotated image in final graph coordinates") {
            let cases: [(options: String, visible: (Int, Int), hidden: (Int, Int), color: [Int])] = [
                ("", (5, 10), (5, 5), blue),
                ("Flip=1", (5, 5), (5, 10), red),
                ("GraphStart=Left", (5, 10), (5, 5), blue),
                ("GraphOrientation=Horizontal", (5, 10), (7, 10), blue),
                ("GraphOrientation=Horizontal\nFlip=1", (7, 10), (5, 10), blue),
            ]
            for test in cases {
                guard let loaded = try load(t, options: "PrimaryImageRotate=90\n\(test.options)", primary: 50),
                      let meter = loaded.skin.meter(named: "Graph") as? HistogramMeter else {
                    return t.check(false, "reveal fixture loads")
                }
                defer { withExtendedLifetime(loaded.host) { loaded.skin.close() } }
                fill(loaded.skin, meter)
                for format in formats {
                    let picture = try bitmap(meter.lower(), format)
                    check(t, picture.pixel(test.visible.0, test.visible.1), test.color, "visible region: \(test.options)")
                    check(t, picture.pixel(test.hidden.0, test.hidden.1), clear, "hidden region: \(test.options)")
                }
            }
        }
    }

    private static func matrices(_ t: AppTestRunner) {
        t.suite("App: Histogram image options: three matrices override tint and opacity in each graph part") {
            guard let loaded = try load(t, options: """
                PrimaryColorMatrix1=0;1;0;0;0
                PrimaryImageTint=0,0,0,0
                PrimaryImageAlpha=0
                SecondaryImage=Red.png
                SecondaryColorMatrix1=0;0;1;0;0
                SecondaryImageTint=0,0,0,0
                SecondaryImageAlpha=0
                BothImage=Red.png
                BothImageColorMatrix1=1;1;0;0;0
                BothImageTint=0,0,0,0
                BothImageAlpha=0
                """, primary: 75, secondary: 25, file: "Red.png"),
                  let meter = loaded.skin.meter(named: "Graph") as? HistogramMeter else {
                return t.check(false, "three-image fixture loads")
            }
            defer { withExtendedLifetime(loaded.host) { loaded.skin.close() } }
            fill(loaded.skin, meter)
            loaded.skin.execute("[!SetOption P Formula 25][!SetOption S Formula 75]"
                                + "[!UpdateMeasure P][!UpdateMeasure S][!UpdateMeter Graph]", from: nil)
            for format in formats {
                let picture = try bitmap(meter.lower(), format)
                check(t, picture.pixel(10, 7), green, "the preceding column exposes the primary-only image")
                check(t, picture.pixel(11, 7), blue, "the latest column exposes the secondary-only image")
                check(t, picture.pixel(10, 11), [255, 255, 0, 255], "overlap uses BothImageColorMatrixN")
                check(t, picture.pixel(11, 11), [255, 255, 0, 255], "overlap remains opaque despite ImageAlpha=0")
                check(t, picture.pixel(11, 4), clear, "a matrix does not fill unrevealed graph pixels")
            }
            loaded.skin.execute("[!SetOption Graph PrimaryColorMatrix4 \"0;0;0;0.5;0\"]"
                                + "[!UpdateMeter Graph]", from: nil)
            for format in formats {
                let picture = try bitmap(meter.lower(), format)
                check(t, picture.pixel(9, 7), [0, 128, 0, 128], "matrix alpha is premultiplied", tolerance: 1)
            }
        }
    }

    private static func fallbacks(_ t: AppTestRunner) {
        t.suite("App: Histogram image options: crop precedes rotation and invalid images retain their fallback") {
            let cases: [(file: String, options: String, expected: [Int])] = [
                ("Bands.png", "PrimaryImageCrop=0,0,4,4\nPrimaryImageRotate=90", red),
                ("Bands.png", "PrimaryImageCrop=40,40,4,4\nPrimaryImageRotate=90", clear),
                ("Bands.png", "PrimaryImageRotate=90\nPrimaryImageAlpha=0", clear),
                ("missing.png", "PrimaryImageRotate=90\nW=4\nH=4", green),
            ]
            for test in cases {
                guard let loaded = try load(t, options: "PrimaryColor=0,255,0\n\(test.options)", file: test.file),
                      let meter = loaded.skin.meter(named: "Graph") as? HistogramMeter else {
                    return t.check(false, "crop/fallback fixture loads")
                }
                defer { withExtendedLifetime(loaded.host) { loaded.skin.close() } }
                fill(loaded.skin, meter)
                for format in formats {
                    check(t, try bitmap(meter.lower(), format).pixel(5, 5), test.expected, test.options)
                }
            }
        }
    }

    private static func capturedOptions(_ t: AppTestRunner) {
        t.suite("App: Histogram image options: dynamic changes preserve captured values after a cold cache and owner release") {
            var captured: HistogramDraw?
            var expected: [Data] = []
            weak var releasedSkin: Skin?
            weak var releasedMeter: HistogramMeter?
            try autoreleasepool {
                guard let loaded = try load(t, options: """
                    PrimaryImageRotate=90
                    PrimaryColorMatrix1=0;1;0;0;0
                    """, file: "Red.png"),
                      let meter = loaded.skin.meter(named: "Graph") as? HistogramMeter else {
                    return t.check(false, "dynamic fixture loads")
                }
                releasedSkin = loaded.skin
                releasedMeter = meter
                defer { withExtendedLifetime(loaded.host) { loaded.skin.close() } }
                fill(loaded.skin, meter)
                let value = meter.lower()
                captured = value
                expected = try formats.map { try bitmap(value, $0).bytes }
                for format in formats { check(t, try bitmap(value, format).pixel(5, 5), green, "initial matrix") }
                loaded.skin.execute("[!SetOption Graph PrimaryImageRotate 180]"
                                    + "[!SetOption Graph PrimaryColorMatrix1 \"0;0;1;0;0\"]"
                                    + "[!UpdateMeter Graph]", from: nil)
                let changed = meter.lower()
                t.check(changed != value, "rotation and matrix are captured draw inputs")
                for (index, format) in formats.enumerated() {
                    let next = try bitmap(changed, format)
                    check(t, next.pixel(5, 5), blue, "the changed matrix is visible")
                    t.check(next.bytes != expected[index], "new options change pixels")
                    t.equal(try bitmap(value, format).bytes, expected[index], "older options are unchanged")
                }
            }
            t.check(releasedSkin == nil && releasedMeter == nil, "drawing values retain no engine owner")
            guard let captured else { return t.check(false, "a drawing value was captured") }
            Images.purge()
            for (index, format) in formats.enumerated() {
                t.equal(try bitmap(captured, format).bytes, expected[index], "a cold cache replays captured image options")
            }
        }
    }

    private typealias Loaded = (skin: Skin, host: RenderHost, folder: URL)
    private static let formats = [(scale: 1, bgra: false), (scale: 1, bgra: true),
                                  (scale: 2, bgra: false), (scale: 2, bgra: true)]
    private static let red = [255, 0, 0, 255]
    private static let green = [0, 255, 0, 255]
    private static let blue = [0, 0, 255, 255]
    private static let clear = [0, 0, 0, 0]

    private static func load(_ t: AppTestRunner, options: String, primary: Int = 100,
                             secondary: Int? = nil, file: String = "Bands.png") throws -> Loaded? {
        let second = secondary.map { "[S]\nMeasure=Calc\nFormula=\($0)\nMaxValue=100\n" } ?? ""
        let ini = """
            [Rainmeter]
            Update=-1
            [P]
            Measure=Calc
            Formula=\(primary)
            MaxValue=100
            \(second)
            [Graph]
            Meter=Histogram
            MeasureName=P
            \(secondary == nil ? "" : "MeasureName2=S")
            X=4
            Y=4
            PrimaryImage=\(file)
            DynamicVariables=1
            \(options)
            """
        return SkinDrawingSelfTests.load(t, ini, files: ["Bands.png": try bands(),
            "Red.png": SkinDrawingSelfTests.png(8, 8, RGBA(r: 255, g: 0, b: 0))], "histogram-image-options")
    }

    private static func fill(_ skin: Skin, _ meter: HistogramMeter) {
        for _ in 0..<max(1, meter.historyLength) { skin.update() }
    }

    private static func bands() throws -> Data {
        guard let canvas = Images.bitmapContext(width: 8, height: 4) else { throw CocoaError(.coderInvalidValue) }
        canvas.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        canvas.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 4, y: 0, width: 4, height: 4))
        guard let image = canvas.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.coderInvalidValue)
        }
        return png
    }

    private static func check(_ t: AppTestRunner, _ actual: [Int], _ expected: [Int], _ message: String,
                              tolerance: Int = 0) {
        t.check(zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance },
                "\(message): expected \(expected), received \(actual)")
    }

    private static func bitmap(_ drawing: HistogramDraw, _ format: (scale: Int, bgra: Bool)) throws -> Bitmap {
        let picture = try Bitmap(scale: format.scale, bgra: format.bgra)
        SkinRenderer.drawHistogram(drawing, picture.canvas, SkinRenderContext())
        return picture
    }

    private struct Bitmap {
        let canvas: CGContext
        let scale: Int
        let bgra: Bool

        init(scale: Int, bgra: Bool) throws {
            self.scale = scale
            self.bgra = bgra
            let info = bgra ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                : CGImageAlphaInfo.premultipliedLast.rawValue
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let canvas = CGContext(data: nil, width: 24 * scale, height: 24 * scale, bitsPerComponent: 8,
                    bytesPerRow: 96 * scale, space: space, bitmapInfo: info) else {
                throw CocoaError(.coderInvalidValue)
            }
            self.canvas = canvas
            canvas.clear(CGRect(x: 0, y: 0, width: 24 * scale, height: 24 * scale))
            canvas.translateBy(x: 0, y: CGFloat(24 * scale))
            canvas.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            canvas.interpolationQuality = .none
        }

        var bytes: Data { Data(bytes: canvas.data!, count: canvas.bytesPerRow * canvas.height) }

        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let p = canvas.data!.assumingMemoryBound(to: UInt8.self) + y * scale * canvas.bytesPerRow + x * scale * 4
            return [Int(p[bgra ? 2 : 0]), Int(p[1]), Int(p[bgra ? 0 : 2]), Int(p[3])]
        }
    }
}
