import AppKit
import DesksetCore

enum GraphDrawValueSelfTests {
    static func run(_ t: AppTestRunner) {
        capturedValues(t)
        historyVersions(t)
        imageValues(t)
        emptyValues(t)
    }

    private static func capturedValues(_ t: AppTestRunner) {
        t.suite("Runtime: graph lowering: history, ranges and paint survive updates and owner release") {
            var captured: [Value] = []
            var expected: [[Data?]] = []
            weak var releasedSkin: Skin?
            weak var releasedMeter: Meter?
            weak var releasedMeasure: Measure?
            autoreleasepool {
                guard let loaded = SkinDrawingSelfTests.load(t, fixture, "graph-values"),
                      let line = loaded.skin.meter(named: "Line") as? LineMeter,
                      let histogram = loaded.skin.meter(named: "Histogram") as? HistogramMeter else {
                    return t.check(false, "the graph fixture loads")
                }
                let skin = loaded.skin
                releasedSkin = skin
                releasedMeter = line
                releasedMeasure = skin.measure(named: "A")
                defer { withExtendedLifetime(loaded.host) { skin.close() } }
                for _ in 0..<11 { skin.update() }
                let firstLine = line.lower(), firstHistogram = histogram.lower()
                captured = sendable([.line(firstLine), .histogram(firstHistogram)])
                t.equal(line.lower(), firstLine, "lowering again does not invent a new revision")
                t.equal(histogram.lower(), firstHistogram)
                t.check(!firstLine.lines[1].isBound && firstLine.lines[2].isBound, "binding gaps stay in place")
                t.check(!firstLine.markerCoordinates.isEmpty && firstLine.transformStrokeFixed,
                        "markers and fixed transformed strokes are captured")
                t.equal(firstLine.lines[0].history.count, 12)
                expected = [check(t, captured[0], reference: line, "initial line"),
                            check(t, captured[1], reference: histogram, "initial histogram")]
                t.check(expected.allSatisfy { $0.allSatisfy(hasPixels) }, "both graphs paint visible pixels")

                let generation = histogram.drawGeneration
                skin.execute("[!SetOption A MinValue -40][!SetOption A MaxValue 240][!UpdateMeasure A][!Redraw]",
                             from: nil)
                let ranged = histogram.lower()
                t.equal(histogram.drawGeneration, generation, "a measure-only update leaves the meter untouched")
                t.equal(ranged.primary.history, firstHistogram.primary.history, "the same raw history is reused")
                t.check(ranged != firstHistogram, "the current measure range is a separate drawing input")
                t.equal(line.lower(), firstLine, "Line keeps its range until its next meter update")
                let rangePixels = check(t, .histogram(ranged), reference: histogram, "range-only histogram")
                t.check(rangePixels != expected[1], "changing only the range changes the histogram's pixels")
                t.equal(pictures(captured[1]), expected[1], "an older range remains frozen")

                skin.execute("[!SetOption Line AutoScale 1][!SetOption Line AntiAlias 1]"
                             + "[!SetOption Line GraphOrientation Horizontal][!SetOption Line GraphStart Left]"
                             + "[!SetOption Line Flip 1][!SetOption Line LineColor 220,40,90,170]"
                             + "[!SetOption Line LineWidth 1.5][!SetOption Line Scale 7]"
                             + "[!SetOption Line W 52][!SetOption Line H 28]"
                             + "[!SetOption Line TransformationMatrix \"0.9,0.2,-0.1,1.1,5,3\"]"
                             + "[!SetOption Histogram AutoScale 1][!SetOption Histogram AntiAlias 1]"
                             + "[!SetOption Histogram GraphOrientation Horizontal]"
                             + "[!SetOption Histogram GraphStart Left][!SetOption Histogram Flip 1]"
                             + "[!SetOption Histogram BothColor 30,80,240,150]"
                             + "[!UpdateMeter *][!Redraw]", from: nil)
                let changedLine = line.lower(), changedHistogram = histogram.lower()
                t.check(changedLine != firstLine && changedHistogram != firstHistogram,
                        "new samples, geometry and paint produce new values")
                t.check(changedLine.autoScale && changedHistogram.autoScale)
                t.equal(changedLine.fraction(line: 0, age: 0), line.fraction(line: 0, age: 0),
                        "AutoScale keeps ignoring Scale")
                _ = check(t, .line(changedLine), reference: line, "changed line")
                _ = check(t, .histogram(changedHistogram), reference: histogram, "changed histogram")
                for i in captured.indices { t.equal(pictures(captured[i]), expected[i], "old values stay unchanged") }
            }
            t.check(releasedSkin == nil && releasedMeter == nil && releasedMeasure == nil,
                    "captured values retain no skin, meter or measure")
            for i in captured.indices {
                Images.purge()
                t.equal(pictures(captured[i]), expected[i], "a fresh drawing context works after owner release")
            }
        }
    }

    private static func historyVersions(_ t: AppTestRunner) {
        t.suite("Runtime: graph lowering: direct updates, slots and transferred histories have distinct revisions") {
            guard let first = SkinDrawingSelfTests.load(t, fixture, "graph-revisions-a"),
                  let second = SkinDrawingSelfTests.load(t, fixture, "graph-revisions-b"),
                  let line = first.skin.meter(named: "Line") as? LineMeter,
                  let histogram = first.skin.meter(named: "Histogram") as? HistogramMeter,
                  let otherLine = second.skin.meter(named: "Line") as? LineMeter,
                  let otherHistogram = second.skin.meter(named: "Histogram") as? HistogramMeter else {
                return t.check(false, "the graph revision fixtures load")
            }
            defer {
                withExtendedLifetime((first.host, second.host)) { first.skin.close(); second.skin.close() }
            }
            let oldLine = line.lower(), oldHistogram = histogram.lower()
            t.check(oldLine.lines[0].history != oldLine.lines[2].history,
                    "different line slots with equal revision counts are distinct")
            t.check(oldHistogram.primary.history != oldHistogram.secondary.history,
                    "the primary and secondary histories have distinct slots")
            t.equal(line.drawGeneration, otherLine.drawGeneration)
            t.equal(histogram.drawGeneration, otherHistogram.drawGeneration)
            t.check(oldLine != otherLine.lower() && oldHistogram != otherHistogram.lower(),
                    "separate owners never reuse each other's history stamps")

            let lineGeneration = line.drawGeneration, histogramGeneration = histogram.drawGeneration
            first.skin.execute("[!SetOption A Formula 80][!UpdateMeasure A]", from: nil)
            line.updateMeter()
            histogram.updateMeter()
            t.equal(line.drawGeneration, lineGeneration, "direct update does not rely on Skin's generation bump")
            t.equal(histogram.drawGeneration, histogramGeneration)
            t.check(line.lower().lines[0].history != oldLine.lines[0].history,
                    "direct Line updates advance the history revision")
            t.check(histogram.lower().primary.history != oldHistogram.primary.history,
                    "direct Histogram updates advance the history revision")
            t.equal(oldLine.lines[0].history.count, 1, "copy-on-write leaves the old buffer intact")
            t.equal(oldHistogram.primary.history.count, 1)

            second.skin.execute("[!SetOption A Formula 20][!UpdateMeasure A]", from: nil)
            otherLine.updateMeter()
            otherHistogram.updateMeter()
            let beforeLine = line.lower(), beforeHistogram = histogram.lower()
            t.equal(line.drawGeneration, otherLine.drawGeneration)
            t.equal(histogram.drawGeneration, otherHistogram.drawGeneration)
            t.check(beforeLine != otherLine.lower() && beforeHistogram != otherHistogram.lower(),
                    "owners at the same generation with different samples are unequal")
            t.equal(beforeLine.lines[0].history.count, otherLine.lower().lines[0].history.count)
            t.equal(beforeHistogram.primary.history.count, otherHistogram.lower().primary.history.count)
            t.check(beforeLine.lines[0].history.value(age: 0) != otherLine.lower().lines[0].history.value(age: 0),
                    "the equal-count source has different data")
            let oldLinePixels = pictures(.line(beforeLine)), oldHistogramPixels = pictures(.histogram(beforeHistogram))
            first.skin.takeGraphs(from: second.skin)
            let takenLine = line.lower(), takenHistogram = histogram.lower()
            t.check(takenLine.lines[0].history != beforeLine.lines[0].history,
                    "TakeGraphs invalidates equal-count histories from another owner")
            t.check(takenHistogram.primary.history != beforeHistogram.primary.history)
            t.equal(takenLine.lines[0].history.value(age: 0), otherLine.lower().lines[0].history.value(age: 0))
            t.equal(takenHistogram.primary.history.value(age: 0), otherHistogram.lower().primary.history.value(age: 0))
            _ = check(t, .line(takenLine), reference: line, "transferred line")
            _ = check(t, .histogram(takenHistogram), reference: histogram, "transferred histogram")
            t.equal(pictures(.line(beforeLine)), oldLinePixels, "taking another buffer leaves the old value intact")
            t.equal(pictures(.histogram(beforeHistogram)), oldHistogramPixels)
        }
    }

    private static func imageValues(_ t: AppTestRunner) {
        t.suite("Runtime: graph lowering: histogram image options survive a cold cache and owner release") {
            var captured: Value?
            var expected: [Data?] = []
            weak var released: Skin?
            autoreleasepool {
                let ini = fixture + """

                [Pictures]
                Meter=Histogram
                MeasureName=A
                MeasureName2=B
                X=10.5
                Y=12.5
                PrimaryImage=Graph.png
                PrimaryImageCrop=2,3,40,32
                PrimaryGreyScale=1
                PrimaryImageTint=40,190,230,180
                PrimaryImageFlip=Horizontal
                SecondaryImage=Graph.png
                SecondaryImageCrop=-42,-34,40,32,3
                SecondaryImageAlpha=140
                SecondaryImageFlip=Vertical
                BothImage=Graph.png
                BothImageCrop=-20,-16,40,32,5
                BothImageTint=220,100,20,160
                BothImageFlip=Both
                """
                guard let loaded = SkinDrawingSelfTests.load(t, ini, files: ["Graph.png": image()], "graph-images"),
                      let meter = loaded.skin.meter(named: "Pictures") as? HistogramMeter else {
                    return t.check(false, "the histogram image fixture loads")
                }
                released = loaded.skin
                defer { withExtendedLifetime(loaded.host) { loaded.skin.close() } }
                for _ in 0..<11 { loaded.skin.update() }
                let value = Value.histogram(meter.lower())
                captured = value
                expected = check(t, value, reference: meter, "histogram images")
                t.check(expected.allSatisfy(hasPixels), "images paint actual pixels")
                let parts = (0..<meter.historyLength).map { meter.columnRects(age: $0) }
                t.check(parts.contains { $0.primary.width * $0.primary.height > 0 }
                        && parts.contains { $0.secondary.width * $0.secondary.height > 0 }
                        && parts.contains { $0.both.width * $0.both.height > 0 }, "all three image parts are exercised")
                loaded.skin.execute("[!SetOption Pictures AntiAlias 1][!SetOption Pictures PrimaryGreyScale 0]"
                                    + "[!SetOption Pictures PrimaryImageAlpha 80]"
                                    + "[!SetOption Pictures BothImageFlip None][!UpdateMeter Pictures][!Redraw]", from: nil)
                let changed = check(t, .histogram(meter.lower()), reference: meter, "changed image options")
                t.check(changed != expected, "changing image options changes the new drawing")
                t.equal(pictures(value), expected, "the old image options remain frozen")
            }
            t.check(released == nil, "histogram image values do not keep their owner alive")
            guard let captured else { return t.check(false, "the image value was captured") }
            Images.purge()
            t.equal(pictures(captured), expected, "cold image and crop caches can draw after the owner is gone")
        }
    }

    private static func emptyValues(_ t: AppTestRunner) {
        t.suite("Runtime: graph lowering: empty histories, zero samples and missing images keep their drawing") {
            guard let loaded = SkinDrawingSelfTests.load(t, """
            [Rainmeter]
            Update=-1
            [Zero]
            Measure=Calc
            Formula=0
            MaxValue=100
            [Some]
            Measure=Calc
            Formula=50
            MaxValue=100
            [ZeroLine]
            Meter=Line
            MeasureName=Zero
            X=10.5
            Y=12.5
            W=20
            H=20
            [Dot]
            Meter=Line
            MeasureName=Zero
            X=10
            Y=10
            W=1
            H=10
            LineWidth=3
            [NoLine]
            Meter=Line
            LineCount=0
            W=20
            H=20
            [NoHistory]
            Meter=Line
            MeasureName=Zero
            W=0
            H=20
            [NoStroke]
            Meter=Line
            MeasureName=Some
            W=20
            H=20
            LineWidth=0
            [ZeroHistogram]
            Meter=Histogram
            MeasureName=Zero
            W=20
            H=20
            [Missing]
            Meter=Histogram
            MeasureName=Unknown
            W=20
            H=20
            PrimaryImage=absent.png
            [Fallback]
            Meter=Histogram
            MeasureName=Some
            W=20
            H=20
            PrimaryImage=absent.png
            [EmptyHistogram]
            Meter=Histogram
            MeasureName=Zero
            W=20
            H=0
            """, "graph-empty") else { return t.check(false, "the empty fixture loads") }
            defer { withExtendedLifetime(loaded.host) { loaded.skin.close() } }
            for name in ["ZeroLine", "Dot", "NoLine", "NoHistory", "NoStroke", "ZeroHistogram", "Missing",
                         "Fallback", "EmptyHistogram"] {
                guard let meter = loaded.skin.meter(named: name), let value = Value(meter) else {
                    t.check(false, "\(name) loads")
                    continue
                }
                let output = check(t, value, reference: meter, name)
                t.check(output.allSatisfy { hasPixels($0) == ["ZeroLine", "Dot", "Fallback"].contains(name) },
                        "\(name) keeps its expected visible or empty result")
            }
        }
    }

    private enum Value: Equatable, Sendable {
        case line(LineDraw)
        case histogram(HistogramDraw)

        init?(_ meter: Meter) {
            if let line = meter as? LineMeter { self = .line(line.lower()) }
            else if let histogram = meter as? HistogramMeter { self = .histogram(histogram.lower()) }
            else { return nil }
        }

        var matrix: [Double]? {
            if case .line(let value) = self { return value.transformationMatrix }
            return nil
        }

        func draw(_ canvas: CGContext, _ context: SkinRenderContext) {
            switch self {
            case .line(let value): SkinRenderer.drawLine(value, canvas)
            case .histogram(let value): SkinRenderer.drawHistogram(value, canvas, context)
            }
        }
    }

    private static func sendable<T: Sendable>(_ value: T) -> T { value }
    private static func hasPixels(_ bytes: Data?) -> Bool { bytes?.contains { $0 != 0 } == true }
    private static let formats = [(1, false), (1, true), (2, false), (2, true)]

    private static func pictures(_ value: Value) -> [Data?] {
        let context = SkinRenderContext()
        return formats.map { scale, bgra in
            pixels(scale: scale, bgra: bgra, matrix: value.matrix) { value.draw($0, context) }
        }
    }

    @discardableResult
    private static func check(_ t: AppTestRunner, _ value: Value, reference: Meter, _ label: String) -> [Data?] {
        Images.purge()
        #if DEBUG
        LegacyImages.purge()
        #endif
        let actual = pictures(value)
        for (index, format) in formats.enumerated() {
            let (scale, bgra) = format
            t.check(actual[index] != nil, "\(label): bitmap at \(scale)x BGRA=\(bgra)")
            #if DEBUG
            let legacy = pixels(scale: scale, bgra: bgra, matrix: reference.transformationMatrix) { canvas in
                if let line = reference as? LineMeter { LegacySkinRenderer.drawLine(line, canvas) }
                if let histogram = reference as? HistogramMeter {
                    LegacySkinRenderer.drawHistogram(histogram, canvas, LegacySkinRenderContext.of(reference.skin))
                }
            }
            t.equal(actual[index], legacy, "\(label): exact frozen pixels at \(scale)x BGRA=\(bgra)")
            #endif
        }
        return actual
    }

    /// Copy only active pixels, excluding bitmap row padding.
    private static func pixels(scale: Int, bgra: Bool, matrix: [Double]?, _ draw: (CGContext) -> Void) -> Data? {
        let width = 160 * scale, height = 140 * scale
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
        if let m = matrix {
            canvas.concatenate(CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]))
        }
        draw(canvas)
        var result = Data(capacity: width * height * 4)
        for row in 0..<height {
            result.append(bytes.advanced(by: row * canvas.bytesPerRow).assumingMemoryBound(to: UInt8.self),
                          count: width * 4)
        }
        return result
    }

    private static func image() -> Data {
        guard let canvas = Images.bitmapContext(width: 64, height: 48) else { return Data() }
        canvas.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.4, alpha: 0.8))
        canvas.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        canvas.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 0.6))
        canvas.fill(CGRect(x: 3, y: 5, width: 29, height: 31))
        canvas.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        canvas.fill(CGRect(x: 39, y: 28, width: 17, height: 11))
        guard let image = canvas.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    private static let fixture = """
    [Rainmeter]
    Update=-1
    [A]
    Measure=Calc
    Formula=Counter * 7 - 10
    MinValue=-20
    MaxValue=100
    [B]
    Measure=Calc
    Formula=90 - Counter * 5
    MinValue=0
    MaxValue=120
    [Line]
    Meter=Line
    LineCount=3
    MeasureName=A
    MeasureName2=Unknown
    MeasureName3=B
    X=10.5
    Y=12.25
    W=37.5
    H=53.5
    Padding=3,2,4,5
    LineColor=30,120,220,210
    LineColor2=255,0,255
    LineColor3=220,100,30,160
    Scale=1.4
    Scale3=0.5
    LineWidth=2
    HorizontalLines=1
    HorizontalLineColor=150,180,200,100
    TransformStroke=Fixed
    TransformationMatrix=1.2,0.15,0.2,0.9,8,3
    [Histogram]
    Meter=Histogram
    MeasureName=A
    MeasureName2=B
    X=10.5
    Y=12.25
    W=37.5
    H=53.5
    Padding=3,2,4,5
    PrimaryColor=30,160,100,210
    SecondaryColor=220,70,40,170
    BothColor=150,90,200,190
    """
}
